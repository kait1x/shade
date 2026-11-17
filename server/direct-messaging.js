'use strict';
const crypto = require('node:crypto');
const MAX_PAYLOAD_BYTES = 10 * 1024 * 1024;
const MAX_QUEUE_BYTES = 30 * 1024 * 1024;
const TTL = 7 * 24 * 60 * 60 * 1000;
const MAX_RECEIPTS = 10000;

// One serialized transaction queue for ALL sockets. Queues and receipts are saved
// in a single atomic snapshot, before any ACK, notification or delivery.
function createDirectMessaging({ io, users, onlineUsers, offlineBuffer,
  encrypt, decrypt, persist, push, receipts, blocked = () => false, bridged = () => false }) {
  let tail = Promise.resolve();
  const serial = task => {
    const next = tail.then(task);
    tail = next.catch(() => {});
    return next;
  };
  const unwrap = value => value?.s ? decrypt(value) : value;
  const keyOf = (from, id) => `${from}:${id}`;
  const emitTo = (username, event, data) => {
    const target = onlineUsers.get(username);
    if (target) io.to(target).emit(event, data);
  };
  const active = socket => socket.username && onlineUsers.get(socket.username) === socket.id;
  const fail = (socket, ack, error) => {
    if (typeof ack === 'function') ack({ ok: false, error });
    else socket.emit('error', { message: error });
  };
  async function transaction(change) {
    const previousQueues = new Map([...offlineBuffer].map(([user, queue]) => [user, [...queue]]));
    const previousReceipts = new Map(receipts);
    try {
      change();
      if (await persist() === false) throw new Error('Server storage unavailable; try later');
    } catch (error) {
      offlineBuffer.clear(); previousQueues.forEach((v, k) => offlineBuffer.set(k, v));
      receipts.clear(); previousReceipts.forEach((v, k) => receipts.set(k, v));
      throw error;
    }
  }
  function prune() {
    const cutoff = Date.now() - TTL;
    for (const [key, receipt] of receipts) if (receipt.timestamp < cutoff) receipts.delete(key);
    for (const [user, queue] of offlineBuffer) {
      const remaining = queue.filter(value => (unwrap(value)?.timestamp || 0) >= cutoff);
      if (remaining.length) offlineBuffer.set(user, remaining); else offlineBuffer.delete(user);
    }
  }
  function restoreLegacyReceipt(from, to, id) {
    const key = keyOf(from, id);
    let receipt = receipts.get(key);
    if (!receipt) {
      const envelope = (offlineBuffer.get(to) || []).map(unwrap).find(item => item?.from === from && item.id === id);
      if (envelope) {
        receipt = { from, to, id, digest: crypto.createHash('sha256').update(envelope.data).digest('hex'), timestamp: envelope.timestamp, status: 'sent' };
        receipts.set(key, receipt);
      }
    }
    return receipt;
  }
  function attach(socket) {
    const on = (event, handler) => socket.on(event, (payload, ack) => {
      serial(async () => {
        if (!active(socket)) return fail(socket, ack, 'Authentication required');
        await handler(payload, ack);
      }).catch(() => fail(socket, ack, 'Server storage unavailable; try later'));
    });
    on('message', async (payload, ack) => {
      const from = socket.username;
      if (!payload || typeof payload.to !== 'string' || typeof payload.data !== 'string') return fail(socket, ack, 'Invalid message');
      const to = payload.to.toLowerCase().trim(), id = payload.id;
      if (!users.has(to) || to === from) return fail(socket, ack, 'Unknown recipient');
      // v2-migrated SENDERS must use v2. Migrated RECIPIENTS keep receiving
      // v1 ciphertext through the one-way legacy inbox bridge: the envelope
      // is encrypted to the same immutable root RSA, so E2EE is unchanged.
      // The v2 process confirms delivery via the bridge-ack file; until then
      // the queue holds the ciphertext (bounded, TTL-pruned, explicit full).
      if (blocked(from)) return fail(socket, ack, 'upgrade_required');
      const toBridged = bridged(to);
      if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{16,80}$/.test(id)) return fail(socket, ack, 'Invalid message ID');
      if (Buffer.byteLength(payload.data) > MAX_PAYLOAD_BYTES) return fail(socket, ack, 'Payload too large (max 10 MiB)');
      try {
        const parsed = JSON.parse(payload.data);
        if (!parsed || typeof parsed.k !== 'string' || !parsed.k || typeof parsed.d !== 'string' || !parsed.d) throw Error();
      } catch { return fail(socket, ack, 'Invalid encrypted payload'); }
      const digest = crypto.createHash('sha256').update(payload.data).digest('hex');
      const old = restoreLegacyReceipt(from, to, id);
      if (old && old.timestamp >= Date.now() - TTL) {
        if (old.to !== to || old.digest !== digest) return fail(socket, ack, 'Message ID conflict');
        if (typeof ack === 'function') ack({ ok: true, id, status: old.status });
        return;
      }
      const envelope = { id, from, data: payload.data, timestamp: Date.now() };
      let full = false;
      await transaction(() => {
        prune();
        const queue = offlineBuffer.get(to) || [];
        const queued = encrypt(envelope);
        const bytes = queue.reduce((sum, value) => sum + Buffer.byteLength(JSON.stringify(value)), 0);
        full = receipts.size >= MAX_RECEIPTS || queue.length >= 200 || bytes + Buffer.byteLength(JSON.stringify(queued)) > MAX_QUEUE_BYTES;
        if (full) return;
        offlineBuffer.set(to, [...queue, queued]);
        receipts.set(keyOf(from, id), { from, to, id, digest, timestamp: envelope.timestamp, status: 'sent' });
      });
      if (full) return fail(socket, ack, 'Server or recipient queue is full; try later');
      if (!toBridged) emitTo(to, 'message', envelope);
      // v1 push is kept for bridged recipients: the updated Android app still
      // holds its v1 FCM token and the wake notification drives a bridge sync.
      // (PWA relies on foreground/reconnect/polling sync; a dedicated v2 wake
      // push for bridge arrivals is a follow-up — documented limitation.)
      if (!onlineUsers.has(to)) Promise.resolve(push(to, from)).catch(() => {});
      if (typeof ack === 'function') ack({ ok: true, id, status: 'sent' });
    });
    const acknowledge = status => async (payload, ack) => {
      if (!payload || typeof payload.from !== 'string' || !Array.isArray(payload.msgIds)) return fail(socket, ack, 'Invalid receipt');
      const ids = [...new Set(payload.msgIds)].filter(id => typeof id === 'string').slice(0, 200);
      const updates = [];
      await transaction(() => {
        for (const id of ids) {
          const receipt = restoreLegacyReceipt(payload.from, socket.username, id);
          if (!receipt || receipt.to !== socket.username || receipt.deletedAt) continue;
          const next = { ...receipt, status: receipt.status === 'read' ? 'read' : status };
          receipts.set(keyOf(payload.from, id), next);
          updates.push({ msgId: id, status: next.status, from: socket.username });
        }
        const accepted = new Set(updates.map(value => value.msgId));
        offlineBuffer.set(socket.username, (offlineBuffer.get(socket.username) || []).filter(value => {
          const item = unwrap(value);
          return !item || item.from !== payload.from || !accepted.has(item.id);
        }));
      });
      for (const update of updates) emitTo(payload.from, 'messageStatus', update);
      if (typeof ack === 'function') ack({ ok: true, msgIds: updates.map(value => value.msgId) });
    };
    on('delivered', acknowledge('delivered'));
    on('read', acknowledge('read'));
    on('deleteMessage', async (payload, ack) => {
      if (!payload?.forEveryone || typeof payload.to !== 'string' || typeof payload.msgId !== 'string') return fail(socket, ack, 'Invalid deletion');
      const receipt = restoreLegacyReceipt(socket.username, payload.to, payload.msgId);
      if (!receipt || receipt.to !== payload.to) return fail(socket, ack, 'Message not found');
      await transaction(() => {
        receipts.set(keyOf(socket.username, payload.msgId), { ...receipt, deletedAt: Date.now() });
        offlineBuffer.set(payload.to, (offlineBuffer.get(payload.to) || []).filter(value => {
          const item = unwrap(value);
          return item?.id !== payload.msgId || item.from !== socket.username;
        }));
      });
      emitTo(payload.to, 'messageDeleted', { msgId: payload.msgId, from: socket.username });
      if (typeof ack === 'function') ack({ ok: true });
    });
  }
  return {
    attach,
    // Bridge-ack ingestion: the v2 process exports ACK tombstones for migrated
    // accounts (additive file, v1 is the ONLY writer of v1 storage). Confirmed
    // ciphertext leaves the v1 queue and the sender sees delivered/read status.
    // Idempotent: refs already pruned are a no-op; deleted receipts stay deleted.
    bridgeAck: entries => serial(async () => {
      const updates = [];
      let pruned = 0;
      await transaction(() => {
        for (const { account, acked, read } of entries) {
          const ackedSet = new Set(acked), readSet = new Set(read || []);
          const queue = offlineBuffer.get(account) || [];
          if (!queue.length) continue;
          const remaining = queue.filter(value => {
            const item = unwrap(value);
            if (!item) return true;
            if (!ackedSet.has(keyOf(item.from, item.id))) return true;
            pruned++;
            const receipt = receipts.get(keyOf(item.from, item.id));
            if (receipt && !receipt.deletedAt) {
              const status = readSet.has(keyOf(item.from, item.id)) ? 'read'
                : (receipt.status === 'read' ? 'read' : 'delivered');
              if (receipt.status !== status) {
                receipts.set(keyOf(item.from, item.id), { ...receipt, status });
                updates.push({ msgId: item.id, status, from: account, sender: item.from });
              }
            }
            return false;
          });
          if (remaining.length) offlineBuffer.set(account, remaining); else offlineBuffer.delete(account);
        }
      });
      for (const u of updates) emitTo(u.sender, 'messageStatus', { msgId: u.msgId, status: u.status, from: u.from });
      return { pruned, statuses: updates.length };
    }),
    sweep: () => serial(() => transaction(prune)),
    replay: socket => serial(() => {
      if (!active(socket)) return;
      for (const value of offlineBuffer.get(socket.username) || []) {
        const message = unwrap(value);
        if (message && message.timestamp >= Date.now() - TTL) socket.emit('message', message);
      }
      for (const receipt of receipts.values()) {
        if (receipt.timestamp < Date.now() - TTL) continue;
        if (receipt.from === socket.username) socket.emit('messageStatus', { msgId: receipt.id, from: receipt.to, status: receipt.status });
        if (receipt.to === socket.username && receipt.deletedAt) socket.emit('messageDeleted', { msgId: receipt.id, from: receipt.from });
      }
    }),
  };
}
module.exports = { createDirectMessaging };

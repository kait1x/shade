// Protocol model. server.js intentionally does NOT import it; alpha.mjs uses
// the separate isolated HTTP/Socket.IO adapter.
// No production data is read or changed. A real adapter must reuse encrypted,
// atomic server storage and introduce separate device-scoped transport routes.
import { createPublicKey, randomBytes } from 'node:crypto';
import { check, hash, manifestText, deviceId,
  pairingText, pairingTextV2, requestText, verify, verifyMessage, messageText, verifyGenesis, verifyHistory } from '../../client/web/protocol/device-v2.mjs';

export const operationDigest = (operation, body = null) => hash(JSON.stringify([operation, body]));
export const messageRef = m => `${m.from}:${m.deviceId}:${m.id}`;
export function legacyRoot(pem) {
  const key = createPublicKey(pem);
  // Normalization must not prevent old accounts from staying on v1. The v2
  // validators separately enforce RSA-4096 before any enrollment or message.
  check(key.asymmetricKeyType === 'rsa', 'Unsupported legacy root type');
  return key.export({ type: 'spki', format: 'der' }).toString('base64');
}

export async function createDeviceRegistry({ users, persist, snapshot, clock = Date.now, verifyGoogle, pairingV1 = true }) {
  check(users instanceof Map && typeof persist === 'function');
  // Additive snapshot: never rewrite users, legacy messages, tokens or keys.
  let state = { format: 2, accounts: {}, queues: {}, receipts: {}, receiptAt: {}, delivery: {}, stickers: {}, retractions: {}, pushSubscriptions: {}, historyStaging: {} };
  const initialAccounts = [];
  for (const [account, user] of users) {
    check(/^[a-z0-9_]{3,32}$/.test(account), 'Invalid legacy account');
    initialAccounts.push([account, { root: legacyRoot(user.publicKey), legacy: true,
      googleSub: user.googleSub || null, genesis: null, history: [], retired: [] }]);
  }
  state.accounts = Object.fromEntries(initialAccounts);
  if (snapshot) {
    check(snapshot.format === 2 && snapshot.accounts && snapshot.queues && snapshot.receipts, 'Invalid snapshot');
    check(snapshot.stickers === undefined || (snapshot.stickers && typeof snapshot.stickers === 'object' && !Array.isArray(snapshot.stickers)), 'Invalid stickers snapshot');
    for (const [account, record] of Object.entries(snapshot.accounts)) {
      if (Object.hasOwn(state.accounts, account)) {
        check(state.accounts[account].root === record.root && record.legacy === true, 'Snapshot root substitution');
      } else check(record.legacy === false && typeof record.googleSub === 'string' && record.genesis, 'Invalid new account snapshot');
      check(Array.isArray(record.history) && Array.isArray(record.retired));
      if (record.history.length) {
        check(record.genesis && record.genesis.legacy === record.legacy, 'Missing or inconsistent account genesis');
        check(record.history.at(-1).issuedAt <= clock() + 30000, 'Snapshot directory is from the future');
        await verifyHistory(record.history, record.root, null, record.history.at(-1).issuedAt, record.genesis);
      } else check(!record.genesis, 'Genesis without directory');
      let previous = '', revision = 0;
      const retired = new Set();
      let previousDevices = [];
      for (const m of record.history) {
        check(m.account === account && m.revision === ++revision && m.previous === previous, 'Invalid saved history');
        previous = await hash(manifestText(m));
        for (const d of previousDevices) if (!m.devices.some(next => next.id === d.id)) retired.add(d.id);
        for (const d of m.devices) check(!retired.has(d.id), 'Revoked device resurrected');
        previousDevices = m.devices;
      }
      check(JSON.stringify([...retired].sort()) === JSON.stringify([...record.retired].sort()), 'Invalid revocation tombstones');
    }
    // Missing accounts would silently erase device enrollments: fail closed.
    check([...users.keys()].every(account => Object.hasOwn(snapshot.accounts, account)), 'Incomplete migration snapshot');
    state = structuredClone(snapshot);
    state.delivery ||= {};
    state.stickers ||= {};
    state.retractions ||= {};
    state.pushSubscriptions ||= {};
    state.receiptAt ||= {};
    state.historyStaging ||= {};
    // Legacy-снапшоты без меток времени receipt: консервативно stamps временем
    // загрузки (старые квитанции живут ещё TTL от загрузки, не исчезают сразу).
    for (const key of Object.keys(state.receipts)) {
      if (!Object.hasOwn(state.receiptAt, key)) state.receiptAt[key] = clock();
    }
  }
  const challenges = new Map();
  let tail = Promise.resolve();
  const serial = work => {
    const task = tail.then(work); tail = task.catch(() => {}); return task;
  };
  const recordOf = (s, account) => Object.hasOwn(s.accounts, account) ? s.accounts[account] : undefined;
  const current = (s, account) => recordOf(s, account)?.history.at(-1);
  const active = (s, account, id) => current(s, account)?.devices.find(d => d.id === id);
  const transaction = async work => {
    const next = structuredClone(state);
    const value = await work(next);
    check(await persist(structuredClone(next)) !== false, 'Persistence failed');
    state = next; // ACK/state visible only after durable save.
    return value;
  };
  async function authenticate(auth, operation) {
    check(auth && typeof auth === 'object', 'Device proof required');
    const challenge = challenges.get(auth.nonce);
    challenges.delete(auth.nonce); // Failed proofs also consume the nonce.
    check(challenge && challenge.account === auth.account && challenge.id === auth.id &&
      challenge.operation === operation && challenge.expiresAt > clock(), 'Invalid or replayed challenge');
    const d = active(state, auth.account, auth.id);
    check(d, 'Revoked or unknown device');
    check(await verify(requestText(auth.account, auth.id, auth.nonce, operation), auth.proof, d.signingKey), 'Invalid device proof');
  }
  return {
    exportSnapshot: () => structuredClone(state),
    // Generic serialized transaction for adapter-owned sections (stickers/
    // profiles). Single writer: persist happens before state is visible.
    updateState: work => serial(() => transaction(async next => { await work(next); })),
    accountForGoogle: sub => Object.entries(state.accounts).find(([, r]) => r.googleSub === sub)?.[0] || null,
    list: () => Object.entries(state.accounts).filter(([, r]) => r.history.length)
      .map(([account]) => ({ account })),
    authorize: (auth, operation) => serial(() => authenticate(auth, operation)),
    directory: account => {
      const record = recordOf(state, account); check(record, 'Unknown account');
      return { root: record.root, genesis: structuredClone(record.genesis), history: structuredClone(record.history),
        rotation: record.rotation ? structuredClone(record.rotation) : null };
    },
    // The first device can be any platform. Google verifies account ownership;
    // genesis + the complete roster are signed by that device, not the relay.
    register: ({ genesis, manifest, googleIdToken, proofs = [] }) => serial(() => transaction(async next => {
      check(typeof verifyGoogle === 'function', 'Google verifier not configured');
      check(manifest.account === genesis.account, 'Registration account mismatch');
      check(!recordOf(next, genesis.account) && !genesis.legacy, 'Account already exists or invalid genesis');
      const profile = await verifyGoogle(googleIdToken);
      check(profile && typeof profile.googleSub === 'string' && profile.googleSub.length > 0, 'Verified Google account required');
      check(!Object.values(next.accounts).some(r => r.googleSub === profile.googleSub), 'Google account already registered; link a device');
      check(genesis.createdAt <= clock() + 30000 && genesis.createdAt >= clock() - 300000, 'Stale registration');
      const record = { root: genesis.firstDevice.signingKey, legacy: false, googleSub: profile.googleSub,
        genesis: structuredClone(genesis), history: [], retired: [] };
      await verifyGenesis(genesis, record.root);
      Object.defineProperty(next.accounts, genesis.account, { value: record, enumerable: true, writable: true, configurable: true });
      return update(next, manifest, proofs);
    })),
    install: (manifest, proofs = [], genesis = null) => serial(() => transaction(async next => {
      const record = recordOf(next, manifest.account); check(record, 'Unknown account');
      if (!record.genesis) {
        check(record.legacy && genesis?.legacy && genesis.account === manifest.account, 'Legacy migration genesis required');
        await verifyGenesis(genesis, record.root);
        record.genesis = structuredClone(genesis);
      } else if (genesis) check(await hash(JSON.stringify(genesis)) === await hash(JSON.stringify(record.genesis)), 'Genesis is immutable');
      return update(next, manifest, proofs);
    })),
    challenge(account, id, operation) {
      for (const [key, value] of challenges) if (value.expiresAt <= clock()) challenges.delete(key);
      check(active(state, account, id), 'Revoked or unknown device');
      check(/^[a-f0-9]{64}$/.test(operation) && challenges.size < 1000, 'Invalid operation or challenge limit');
      // Per-account quota: one account cannot exhaust the global capacity.
      let perAccount = 0;
      for (const value of challenges.values()) if (value.account === account) perAccount++;
      check(perAccount < 100, 'Challenge quota reached');
      const nonce = randomBytes(32).toString('hex');
      challenges.set(nonce, { account, id, operation, expiresAt: clock() + 60000 });
      return nonce;
    },
    send: (message, auth) => serial(async () => {
      const digest = await hash(messageText(message));
      await authenticate(auth, await operationDigest('send', digest));
      check(auth.account === message.from && auth.id === message.deviceId, 'Wrong sending device');
      return transaction(async next => {
        const receiptKey = `${message.from}:${message.deviceId}:${message.id}`;
        const previous = next.receipts[receiptKey];
        // A lost HTTP response can be retried after directory renewal. Proof
        // still requires a currently authorized device; ciphertext is immutable.
        if (previous) { check(previous === digest, 'Message ID conflict'); return { accepted: true, duplicate: true }; }
        const sender = current(next, message.from), recipient = current(next, message.to);
        check(sender && recipient, 'Both accounts must opt into v2');
        check(sender.expiresAt > clock() && recipient.expiresAt > clock(), 'Expired directory lease');
        await verifyMessage(message, sender, recipient, clock());
        check(Object.keys(next.receipts).length < 10000, 'Receipt capacity reached');
        for (const e of message.envelopes) {
          const key = `${e.account}:${e.deviceId}`;
          const queue = next.queues[key] ||= [];
          check(queue.length < 200 && JSON.stringify(queue).length + JSON.stringify(message).length <= 8 * 1024 * 1024, 'Device queue full');
          // Повторная доставка того же id не плодит копии в очереди (дедуп на
          // сервере, независимо от окна receipts).
          if (!queue.some(q => q.id === message.id)) queue.push(structuredClone(message));
        }
        next.receipts[receiptKey] = digest;
        next.receiptAt[receiptKey] = clock();
        next.delivery[receiptKey] = { from: message.from, devices: message.envelopes
          .filter(e => e.account === message.to).map(e => ({ account: e.account, id: e.deviceId, acknowledgedAt: null })) };
        return { accepted: true, duplicate: false };
      });
    }),
    // history.transfer (SYNC_PLAN §5.2): per-device staging E2EE-пакетов истории
    // между устройствами ОДНОГО аккаунта. Сервер хранит ciphertext как есть и
    // никогда не расшифровывает; в receipts/очереди сообщений не учитывается.
    historyTransfer: (body, auth) => serial(() => transaction(async next => {
      await authenticate(auth, await operationDigest('history.transfer', body));
      check(body && typeof body.to === 'string' && Array.isArray(body.packages) && body.packages.length <= 50, 'Invalid transfer body');
      check(active(next, auth.account, auth.id), 'Revoked or unknown sender device');
      check(active(next, auth.account, body.to), 'Revoked or unknown target device');
      const key = `${auth.account}:${body.to}`;
      const staging = next.historyStaging[key] ||= { packages: [], bytes: 0 };
      check(staging.packages.length < 2000, 'History staging capacity reached');
      let added = 0;
      for (const p of body.packages) {
        check(p && typeof p.id === 'string' && /^[a-f0-9]{64}$/.test(p.id) &&
          Number.isSafeInteger(p.seq) && p.seq >= 1 &&
          typeof p.payload === 'string' && p.payload.length <= 87384, 'Invalid history package');
        if (staging.packages.some(q => q.id === p.id)) continue; // идемпотентный ретрай
        check(staging.bytes + p.payload.length <= 64 * 1024 * 1024, 'History staging volume reached');
        staging.packages.push({ id: p.id, seq: p.seq, payload: p.payload });
        staging.bytes += p.payload.length;
        added++;
      }
      staging.packages.sort((a, b) => a.seq - b.seq);
      return { added, duplicate: body.packages.length - added };
    })),
    historyFetch: (body, auth) => serial(async () => {
      await authenticate(auth, await operationDigest('history.fetch', body));
      const since = Number.isSafeInteger(body?.since) ? body.since : 0;
      const staging = state.historyStaging[`${auth.account}:${auth.id}`];
      const packages = (staging?.packages || []).filter(p => p.seq > since).slice(0, 50);
      return { packages: structuredClone(packages), cursor: packages.at(-1)?.seq ?? since };
    }),
    historyAck: (body, auth) => serial(() => transaction(async next => {
      await authenticate(auth, await operationDigest('history.ack', body));
      check(Array.isArray(body?.ids) && body.ids.length <= 200, 'Invalid ack body');
      const key = `${auth.account}:${auth.id}`;
      const staging = next.historyStaging[key];
      if (!staging) return { acked: 0 };
      const ids = new Set(body.ids);
      const kept = staging.packages.filter(p => !ids.has(p.id));
      const acked = staging.packages.length - kept.length;
      if (kept.length) {
        staging.packages = kept;
        staging.bytes = kept.reduce((s, p) => s + p.payload.length, 0);
      } else delete next.historyStaging[key];
      return { acked };
    })),
    // Pruning старых квитанций: окно дедупа = TTL очередей (7 дней); иначе
    // глобальный cap 10000 исчерпывается навсегда (SYNC_PLAN §5.3).
    pruneReceipts: () => serial(() => transaction(async next => {
      const cutoff = clock() - 7 * 24 * 60 * 60 * 1000;
      let pruned = 0;
      for (const [key, at] of Object.entries(next.receiptAt || {})) {
        if (at <= cutoff) {
          delete next.receipts[key]; delete next.receiptAt[key]; delete next.delivery[key];
          pruned++;
        }
      }
      return pruned;
    })),
    fetch: auth => serial(async () => {
      await authenticate(auth, await operationDigest('fetch'));
      const own = current(state, auth.account);
      check(own.expiresAt > clock(), 'Expired directory lease');
      return (state.queues[`${auth.account}:${auth.id}`] || []).filter(m => active(state, m.from, m.deviceId))
        .map(message => ({ message: structuredClone(message),
          senderHistory: structuredClone(state.accounts[message.from].history),
          recipientHistory: structuredClone(state.accounts[message.to].history) }));
    }),
    acknowledge: (refs, auth) => serial(async () => {
      check(Array.isArray(refs) && refs.length <= 200 && refs.every(ref => typeof ref === 'string' &&
        /^[a-z0-9_]{3,32}:(primary|[a-f0-9]{64}):[a-f0-9]{64}$/.test(ref)));
      await authenticate(auth, await operationDigest('ack', refs));
      return transaction(next => {
        const key = `${auth.account}:${auth.id}`;
        const before = next.queues[key] || [];
        for (const m of before) if (refs.includes(messageRef(m))) {
          const delivered = next.delivery[messageRef(m)]?.devices
            .find(d => d.account === auth.account && d.id === auth.id);
          if (delivered) delivered.acknowledgedAt ||= clock();
        }
        next.queues[key] = before.filter(m => !refs.includes(messageRef(m)));
        return { acknowledged: before.length - next.queues[key].length };
      });
    }),
    status: (refs, auth) => serial(async () => {
      check(Array.isArray(refs) && refs.length <= 200 && refs.every(r => typeof r === 'string'));
      await authenticate(auth, await operationDigest('status', refs));
      return Object.fromEntries(refs.map(ref => [ref, state.delivery[ref]?.from === auth.account
        ? structuredClone(state.delivery[ref].devices) : []]));
    }),
    // Read-ACK (contract C5): recipient-device-only, idempotent, projected to
    // the sender through status. Never reveals whether an unknown ref exists.
    read: (refs, auth) => serial(async () => {
      check(Array.isArray(refs) && refs.length <= 200 && refs.every(ref => typeof ref === 'string' &&
        /^[a-z0-9_]{3,32}:(primary|[a-f0-9]{64}):[a-f0-9]{64}$/.test(ref)), 'Invalid read refs');
      await authenticate(auth, await operationDigest('read', refs));
      return transaction(next => {
        let read = 0;
        for (const ref of refs) {
          const device = next.delivery[ref]?.devices?.find(d => d.account === auth.account && d.id === auth.id);
          if (device && !device.readAt) { device.readAt = clock(); read++; }
        }
        return { read };
      });
    }),
    // Delete-for-all (contract C3): sender-only, idempotent, purges offline
    // queues and leaves a bounded tombstone for already-delivered copies.
    retract: (refs, auth) => serial(async () => {
      check(Array.isArray(refs) && refs.length <= 200 && refs.every(ref => typeof ref === 'string' &&
        /^[a-z0-9_]{3,32}:(primary|[a-f0-9]{64}):[a-f0-9]{64}$/.test(ref)), 'Invalid retraction refs');
      await authenticate(auth, await operationDigest('retract', refs));
      check(refs.every(ref => ref.split(':')[0] === auth.account), 'Only the sender can retract');
      return transaction(next => {
        const now = clock();
        for (const [ref, t] of Object.entries(next.retractions)) {
          if (t.deletedAt <= now - 7 * 24 * 60 * 60 * 1000) delete next.retractions[ref];
        }
        let retracted = 0;
        let ownTombstones = 0;
        for (const t of Object.values(next.retractions)) if (t.from === auth.account) ownTombstones++;
        for (const ref of refs) {
          if (next.retractions[ref]) continue;
          // Only actually-sent messages get tombstones: unknown refs are a
          // no-op, so a valid device cannot exhaust the cap with fabricated refs.
          if (!next.receipts[ref]) continue;
          check(ownTombstones < 2000, 'Retraction quota reached');
          check(Object.keys(next.retractions).length < 10000, 'Retraction capacity reached');
          next.retractions[ref] = { from: auth.account, deletedAt: now };
          ownTombstones++;
          retracted++;
        }
        const refSet = new Set(refs);
        for (const [key, queue] of Object.entries(next.queues)) {
          next.queues[key] = queue.filter(m => !refSet.has(messageRef(m)));
        }
        return { retracted };
      });
    }),
    // Tombstones are visible only to the sender account and recipient devices.
    retractions: (body, auth) => serial(async () => {
      const since = body?.since ?? 0;
      check(Number.isSafeInteger(since) && since >= 0, 'Invalid cursor');
      await authenticate(auth, await operationDigest('retractions', body ?? null));
      const out = [];
      for (const [ref, t] of Object.entries(state.retractions)) {
        if (t.deletedAt <= since) continue;
        const recipient = state.delivery[ref]?.devices?.some(d => d.account === auth.account && d.id === auth.id);
        if (t.from === auth.account || recipient) out.push({ ref, deletedAt: t.deletedAt, from: t.from });
        if (out.length >= 500) break;
      }
      return { retractions: out };
    }),
    // Web Push subscriptions (contract C6): one per device, encrypted at rest
    // inside the snapshot, bound to the authenticated account/device.
    pushSubscribe: (auth, subscription) => serial(() => transaction(next => {
      const key = `${auth.account}:${auth.id}`;
      check(Object.hasOwn(next.pushSubscriptions, key) ||
        Object.keys(next.pushSubscriptions).length < 10000, 'Push capacity reached');
      next.pushSubscriptions[key] = { ...subscription, createdAt: clock() };
      return { subscribed: true };
    })),
    pushUnsubscribe: auth => serial(() => transaction(next => {
      delete next.pushSubscriptions[`${auth.account}:${auth.id}`];
      return { subscribed: false };
    })),
    pushSubscription: (account, id) => state.pushSubscriptions[`${account}:${id}`]
      ? structuredClone(state.pushSubscriptions[`${account}:${id}`]) : null,
    dropPushSubscription: (account, id) => serial(() => transaction(next => {
      delete next.pushSubscriptions[`${account}:${id}`];
    })),
    assertLegacyAllowed(account) {
      check(!current(state, account), 'Client upgrade required: account uses device protocol v2');
    },
  };

  async function update(next, manifest, proofs) {
      const record = recordOf(next, manifest.account); check(record?.genesis, 'Account genesis required');
      const old = current(next, manifest.account);
      check(manifest.revision === (old?.revision || 0) + 1 &&
        manifest.previous === (old ? await hash(manifestText(old)) : ''), 'Stale directory update');
      check(!old || manifest.issuedAt >= old.issuedAt, 'Directory clock rollback');
      const verified = await verifyHistory([...record.history, manifest], record.root, null, clock(), record.genesis);
      const digest = verified.digest;
      check(record.history.length < 4096, 'Directory history limit; upgrade required');
      for (const d of manifest.devices) {
        check(!record.retired.includes(d.id), 'Revoked device ID cannot be reused');
        if (d.id === 'primary' || old?.devices.some(previous => previous.id === d.id)) continue;
        const proof = proofs.find(p => p.id === d.id);
        check(proof && proof.expiresAt > clock() && proof.expiresAt <= clock() + 300000, 'Fresh pairing proof required');
        check(d.id === await deviceId(d.encryptionKey, d.signingKey));
        if (proof.pairingVersion === 2) {
          // Challenge-bound proof: the signature must cover the challenge the
          // trusted device displayed. A v1 signature here fails (downgrade).
          check(typeof proof.challenge === 'string' && /^[a-f0-9]{30}$/.test(proof.challenge), 'Invalid pairing challenge');
          check(await verify(pairingTextV2(manifest.account, d, proof.nonce, proof.expiresAt, proof.challenge),
            proof.signature, d.signingKey), 'Invalid pairing possession proof');
        } else {
          check(proof.pairingVersion === undefined && proof.challenge === undefined, 'Invalid pairing proof version');
          // Cutoff applies to roster growth (the pairing approval UX). Genesis
          // enrollment has no trusted-device challenge and keeps v1 proofs.
          check(pairingV1 || !old, 'Pairing v1 proofs are disabled; update the client');
          check(await verify(pairingText(manifest.account, d, proof.nonce, proof.expiresAt),
            proof.signature, d.signingKey), 'Invalid pairing possession proof');
        }
      }
      for (const d of old?.devices || []) {
        if (!manifest.devices.some(next => next.id === d.id)) record.retired.push(d.id);
      }
      record.history.push(structuredClone(manifest));
      // Drop undelivered ciphertext for revoked recipients and revoked senders.
      for (const [key, queue] of Object.entries(next.queues)) {
        next.queues[key] = queue.filter(m => active(next, key.split(':')[0], key.split(':')[1]) && active(next, m.from, m.deviceId));
      }
      // Revoked devices lose their push subscriptions too.
      for (const key of Object.keys(next.pushSubscriptions)) {
        const [account, id] = key.split(':');
        if (account === manifest.account && !manifest.devices.some(d => d.id === id)) {
          delete next.pushSubscriptions[key];
        }
      }
      return { revision: manifest.revision, digest };
  }
}

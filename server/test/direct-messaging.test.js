'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createDirectMessaging } = require('../direct-messaging');

function fixture() {
  const offlineBuffer = new Map(), receipts = new Map(), events = [];
  let failSave = false, saved;
  const onlineUsers = new Map([['alice', 'a'], ['bob', 'b']]);
  const manager = createDirectMessaging({
    io: { to: username => ({ emit: (event, payload) => events.push({ username, event, payload }) }) },
    users: new Map([['alice', {}], ['bob', {}], ['carol', {}]]), onlineUsers,
    offlineBuffer, receipts, encrypt: value => value, decrypt: value => value, push: () => {},
    persist: async () => {
      await new Promise(resolve => setImmediate(resolve));
      if (failSave) return false;
      saved = JSON.stringify({ queues: [...offlineBuffer], receipts: [...receipts] });
      return true;
    },
  });
  const socket = (username, id) => {
    const handlers = new Map();
    const value = { username, id, on: (event, handler) => handlers.set(event, handler), emit: (event, payload) => events.push({ username: id, event, payload }) };
    manager.attach(value);
    value.request = (event, payload) => new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(Error('No ACK')), 1500);
      handlers.get(event)(payload, result => { clearTimeout(timeout); resolve(result); });
    });
    return value;
  };
  return { manager, offlineBuffer, receipts, onlineUsers, events, socket,
    setFailure: value => { failSave = value; }, saved: () => saved };
}
const message = { to: 'bob', id: 'valid-test-message-0001', data: JSON.stringify({ k: 'test-key', d: 'test-ciphertext' }) };

test('failed durable write rolls back both queue and receipt; retry delivers exactly once', async () => {
  const f = fixture(), alice = f.socket('alice', 'a');
  f.setFailure(true);
  assert.equal((await alice.request('message', message)).ok, false);
  assert.equal(f.receipts.size, 0); assert.equal(f.offlineBuffer.size, 0); assert.equal(f.events.length, 0);
  f.setFailure(false);
  const result = await Promise.all([alice.request('message', message), alice.request('message', message)]);
  assert.ok(result.every(item => item.ok));
  assert.equal(f.events.filter(event => event.event === 'message').length, 1);
  assert.equal(new Map(JSON.parse(f.saved()).receipts).size, 1);
});

test('failed read write does not lose pending delivery or send a false read status', async () => {
  const f = fixture(), alice = f.socket('alice', 'a'), bob = f.socket('bob', 'b');
  await alice.request('message', message); f.events.length = 0;
  f.setFailure(true);
  assert.equal((await bob.request('read', { from: 'alice', msgIds: [message.id] })).ok, false);
  assert.equal(f.receipts.get('alice:' + message.id).status, 'sent');
  assert.equal(f.offlineBuffer.get('bob').length, 1); assert.equal(f.events.length, 0);
  f.setFailure(false);
  assert.equal((await bob.request('read', { from: 'alice', msgIds: [message.id] })).ok, true);
  assert.equal(f.offlineBuffer.get('bob').length, 0);
});

test('only recipient can acknowledge or remove queued messages', async () => {
  const f = fixture(), alice = f.socket('alice', 'a');
  f.onlineUsers.set('carol', 'c'); const carol = f.socket('carol', 'c');
  await alice.request('message', message);
  const forged = await carol.request('read', { from: 'alice', msgIds: [message.id] });
  assert.deepEqual(forged.msgIds, []);
  assert.equal(f.receipts.get('alice:' + message.id).status, 'sent');
  assert.equal(f.offlineBuffer.get('bob').length, 1);
});

test('failed deletion preserves receipt and queue for a safe retry', async () => {
  const f = fixture(), alice = f.socket('alice', 'a');
  await alice.request('message', message);
  f.setFailure(true);
  assert.equal((await alice.request('deleteMessage', { to: 'bob', msgId: message.id, forEveryone: true })).ok, false);
  assert.equal(f.receipts.get('alice:' + message.id).deletedAt, undefined);
  assert.equal(f.offlineBuffer.get('bob').length, 1);
});

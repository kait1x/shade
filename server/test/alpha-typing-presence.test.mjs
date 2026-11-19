// Typing/presence (contract C2): relationship-gated, in-memory, throttled,
// multi-device online semantics, no content, stranger privacy.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { io } from 'socket.io-client';
import { fixture, identity, register, operation, proof } from './helpers/alpha-fixture.mjs';
import { sealMessage } from '../../client/web/device_crypto.mjs';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-presence-'));
}
const connect = async (f, who, cookie) => {
  const socket = io(f.origin, { autoConnect: false, transports: ['websocket'],
    extraHeaders: { Cookie: cookie }, auth: await proof(f, who, cookie, 'socket') });
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve); socket.once('connect_error', reject); socket.connect();
  });
  return socket;
};
const once = (socket, event, timeout = 4000) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(Error(`timeout waiting ${event}`)), timeout);
  socket.once(event, data => { clearTimeout(timer); resolve(data); });
});
const sawEvent = (socket, event, ms = 400) => new Promise(resolve => {
  let got = false;
  const handler = () => { got = true; };
  socket.on(event, handler);
  setTimeout(() => { socket.off(event, handler); resolve(got); }, ms);
});

test('typing and presence are relationship-gated, throttled and multi-device aware', async () => {
  const dataDir = await tempDir(), storageSecret = randomBytes(32).toString('hex');
  const f = await fixture({ dataDir, storageSecret });
  const alice = await identity('alice_typing'), bob = await identity('bob_typing');
  const carol = await identity('carol_stranger');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  const cc = await f.login('synthetic-carol');
  await register(f, alice, ac); await register(f, bob, bc); await register(f, carol, cc);
  let aliceSock, bobSock, carolSock, aliceSock2;
  try {
    // No relationship yet: watch/typing must not leak anything.
    aliceSock = await connect(f, alice, ac);
    bobSock = await connect(f, bob, bc);
    bobSock.emit('watch', { peer: 'alice_typing' });
    assert.equal(await sawEvent(bobSock, 'presence'), false);
    aliceSock.emit('typing', { peer: 'bob_typing' });
    assert.equal(await sawEvent(bobSock, 'typing'), false);

    // Establish a relationship with a real E2EE message.
    const m = await sealMessage('hi', [alice.manifest], [bob.manifest], alice.session,
      { senderRoot: alice.vault.signingKey, recipientRoot: bob.vault.signingKey,
        senderGenesis: alice.genesis, recipientGenesis: bob.genesis });
    assert.equal((await operation(f, alice, ac, 'send', m)).result.accepted, true);

    bobSock.emit('watch', { peer: 'alice_typing' });
    const onlineEvent = await once(bobSock, 'presence');
    assert.equal(onlineEvent.account, 'alice_typing');
    assert.equal(onlineEvent.online, true);
    assert.ok(Number.isFinite(onlineEvent.lastSeen) && onlineEvent.lastSeen > 0);
    aliceSock.emit('typing', { peer: 'bob_typing' });
    const typing = await once(bobSock, 'typing');
    assert.equal(typing.account, 'alice_typing');
    assert.ok(typing.until > Date.now());
    // 2s throttle: an immediate second typing is suppressed.
    aliceSock.emit('typing', { peer: 'bob_typing' });
    assert.equal(await sawEvent(bobSock, 'typing'), false);

    // Stranger without a relationship gets no presence and delivers no typing.
    carolSock = await connect(f, carol, cc);
    carolSock.emit('watch', { peer: 'bob_typing' });
    assert.equal(await sawEvent(carolSock, 'presence'), false);
    carolSock.emit('typing', { peer: 'bob_typing' });
    assert.equal(await sawEvent(bobSock, 'typing'), false);
    // Malformed payloads are ignored.
    aliceSock.emit('typing', { peer: 42 });
    aliceSock.emit('watch', null);
    assert.equal(await sawEvent(bobSock, 'typing'), false);

    // Multi-device: online until the LAST socket of the account disconnects.
    aliceSock2 = await connect(f, alice, ac);
    await sawEvent(bobSock, 'presence', 300); // drain the online broadcast
    aliceSock.disconnect();
    assert.equal(await sawEvent(bobSock, 'presence'), false); // still online via sock2
    aliceSock2.disconnect();
    const offlineEvent = await once(bobSock, 'presence');
    assert.equal(offlineEvent.account, 'alice_typing');
    assert.equal(offlineEvent.online, false);
    assert.ok(offlineEvent.lastSeen > 0); // recorded at disconnect
  } finally {
    aliceSock?.disconnect(); bobSock?.disconnect(); carolSock?.disconnect(); aliceSock2?.disconnect();
    await f.close();
  }

  // Relations survive restart (derived from the encrypted delivery snapshot).
  const f2 = await fixture({ dataDir, storageSecret });
  let a2, b2;
  try {
    const ac2 = await f2.login('synthetic-alice'), bc2 = await f2.login('synthetic-bob');
    a2 = await connect(f2, alice, ac2);
    b2 = await connect(f2, bob, bc2);
    b2.emit('watch', { peer: 'alice_typing' });
    const reconnected = await once(b2, 'presence');
    assert.equal(reconnected.account, 'alice_typing');
    assert.equal(reconnected.online, true);
    assert.ok(Number.isFinite(reconnected.lastSeen));
    a2.emit('typing', { peer: 'bob_typing' });
    assert.equal((await once(b2, 'typing')).account, 'alice_typing');
  } finally { a2?.disconnect(); b2?.disconnect(); await f2.close(); }
});

test('lastSeen is persisted and served honestly while the peer is offline', async () => {
  const dataDir = await tempDir(), storageSecret = randomBytes(32).toString('hex');
  const f = await fixture({ dataDir, storageSecret });
  const alice = await identity('alice_seen'), bob = await identity('bob_seen');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  await register(f, alice, ac); await register(f, bob, bc);
  let aliceSock, bobSock;
  try {
    aliceSock = await connect(f, alice, ac);
    bobSock = await connect(f, bob, bc);
    const m = await sealMessage('hi', [alice.manifest], [bob.manifest], alice.session,
      { senderRoot: alice.vault.signingKey, recipientRoot: bob.vault.signingKey,
        senderGenesis: alice.genesis, recipientGenesis: bob.genesis });
    assert.equal((await operation(f, alice, ac, 'send', m)).result.accepted, true);
    bobSock.emit('watch', { peer: 'alice_seen' });
    await once(bobSock, 'presence'); // online:true with lastSeen
    const offlineAt = Date.now();
    aliceSock.disconnect();
    const gone = await once(bobSock, 'presence');
    assert.equal(gone.online, false);
    assert.ok(gone.lastSeen >= offlineAt - 1000);
  } finally { aliceSock?.disconnect(); bobSock?.disconnect(); await f.close(); }

  // Restart: lastSeen is restored from the encrypted presence file, while
  // "online" stays socket-derived (false — the peer has not connected yet).
  const f2 = await fixture({ dataDir, storageSecret });
  let b2;
  try {
    const bc2 = await f2.login('synthetic-bob');
    b2 = await connect(f2, bob, bc2);
    b2.emit('watch', { peer: 'alice_seen' });
    const restored = await once(b2, 'presence');
    assert.equal(restored.account, 'alice_seen');
    assert.equal(restored.online, false);
    assert.ok(restored.lastSeen > 0, 'lastSeen must survive restart');
  } finally { b2?.disconnect(); await f2.close(); }
});
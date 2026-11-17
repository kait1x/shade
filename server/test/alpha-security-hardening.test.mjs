// Security hardening regressions (independent review follow-up):
// per-device ACK isolation, status authorship, challenge quotas, fail-closed
// Origin on native Google login, push host allowlist, per-pair typing throttle.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { io } from 'socket.io-client';
import { fixture, identity, register, operation, proof } from './helpers/alpha-fixture.mjs';
import { sealMessage } from '../../client/web/device_crypto.mjs';
import { messageRef } from '../multidevice/registry.mjs';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-hardening-'));
}
const sendText = async (f, from, to, cookie, text) => {
  const m = await sealMessage(text, [from.manifest], [to.manifest], from.session,
    { senderRoot: from.vault.signingKey, recipientRoot: to.vault.signingKey,
      senderGenesis: from.genesis, recipientGenesis: to.genesis });
  assert.equal((await operation(f, from, cookie, 'send', m)).result.accepted, true);
  return messageRef(m);
};
const connect = async (f, who, cookie) => {
  const socket = io(f.origin, { autoConnect: false, transports: ['websocket'],
    extraHeaders: { Cookie: cookie }, auth: await proof(f, who, cookie, 'socket') });
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve); socket.once('connect_error', reject); socket.connect();
  });
  return socket;
};
const once = (socket, event, timeout = 4000) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(Error(`timeout ${event}`)), timeout);
  socket.once(event, data => { clearTimeout(timer); resolve(data); });
});
const sawEvent = (socket, event, ms = 400) => new Promise(resolve => {
  let got = false;
  const handler = () => { got = true; };
  socket.on(event, handler);
  setTimeout(() => { socket.off(event, handler); resolve(got); }, ms);
});

test('ACK and status are device-scoped; strangers cannot touch other conversations', async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  try {
    const alice = await identity('alice_hard'), bob = await identity('bob_hard');
    const carol = await identity('carol_hard');
    const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
    const cc = await f.login('synthetic-carol');
    await register(f, alice, ac); await register(f, bob, bc); await register(f, carol, cc);
    const ref = await sendText(f, alice, bob, ac, 'for bob only');
    // Carol ACKs a ref she was never a recipient of: no-op, bob keeps the message.
    assert.equal((await operation(f, carol, cc, 'ack', [ref])).result.acknowledged, 0);
    const bobInbox = (await operation(f, bob, bc, 'fetch')).result;
    assert.equal(bobInbox.length, 1);
    // Carol cannot read delivery metadata of alice→bob via status.
    assert.deepEqual((await operation(f, carol, cc, 'status', [ref])).result[ref], []);
    // Bob (recipient, not sender) also gets no delivery list.
    assert.deepEqual((await operation(f, bob, bc, 'status', [ref])).result[ref], []);
    // Carol cannot mark read on a message she never received.
    assert.equal((await operation(f, carol, cc, 'read', [ref])).result.read, 0);
    // Challenge quota is per-account: alice exhausts hers, bob is unaffected.
    const operationHex = 'ab'.repeat(32);
    for (let i = 0; i < 100; i++) {
      const reply = await f.request('/api/v2/challenge',
        { account: 'alice_hard', id: alice.session.id, operation: operationHex }, ac);
      assert.equal(reply.response.status, 200);
    }
    assert.equal((await f.request('/api/v2/challenge',
      { account: 'alice_hard', id: alice.session.id, operation: operationHex }, ac)).response.status, 400);
    assert.equal((await f.request('/api/v2/challenge',
      { account: 'bob_hard', id: bob.session.id, operation: operationHex }, bc)).response.status, 200);
  } finally { await f.close(); }
});

test('native Google login fails closed without a matching Origin', async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'),
    clientId: 'test-client', clientSecret: 'test-secret',
    verifyGoogle: async (token, _audience, expectedNonce) =>
      ({ sub: token, email: 'x@test.invalid', email_verified: true, nonce: expectedNonce }) });
  try {
    // Raw fetch without Origin (bypasses the fixture's same-origin header).
    const response = await fetch(f.origin + '/api/v2/session/google', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ idToken: 'synthetic-origin-test' }) });
    assert.equal(response.status, 400);
    // Mismatched Origin is rejected by the /api middleware.
    const evil = await fetch(f.origin + '/api/v2/session/google', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' },
      body: JSON.stringify({ idToken: 'synthetic-origin-test' }) });
    assert.equal(evil.status, 403);
    // Correct Origin succeeds.
    assert.equal((await f.loginToken('synthetic-origin-test')).length > 0, true);
  } finally { await f.close(); }
});

test('push host allowlist restricts endpoints when configured', async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'),
    vapidKeys: { publicKey: 'BPpublic', privateKey: 'priv' },
    pushSender: async () => {}, pushAllowedHosts: ['push.example.com'] });
  try {
    const bob = await identity('bob_pushhard');
    const bc = await f.login('synthetic-bob');
    await register(f, bob, bc);
    const keys = { p256dh: 'BPkeyBase64UrlValue', auth: 'authBase64Url' };
    assert.equal((await operation(f, bob, bc, 'push.subscribe',
      { endpoint: 'https://other.example.com/x', keys })).response.status, 400);
    assert.equal((await operation(f, bob, bc, 'push.subscribe',
      { endpoint: 'https://push.example.com/x', keys })).result.subscribed, true);
  } finally { await f.close(); }
});

test('typing throttle is per-pair, not per-account', async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  const alice = await identity('alice_type'), bob = await identity('bob_type');
  const carol = await identity('carol_type');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  const cc = await f.login('synthetic-carol');
  await register(f, alice, ac); await register(f, bob, bc); await register(f, carol, cc);
  let as, bs, cs;
  try {
    await sendText(f, alice, bob, ac, 'rel1');
    await sendText(f, alice, carol, ac, 'rel2');
    as = await connect(f, alice, ac); bs = await connect(f, bob, bc); cs = await connect(f, carol, cc);
    as.emit('typing', { peer: 'bob_type' });
    assert.equal((await once(bs, 'typing')).account, 'alice_type');
    // Same instant, different peer: must NOT be muted by the bob throttle.
    as.emit('typing', { peer: 'carol_type' });
    assert.equal((await once(cs, 'typing')).account, 'alice_type');
    // Same pair again within 2s: suppressed.
    as.emit('typing', { peer: 'bob_type' });
    assert.equal(await sawEvent(bs, 'typing'), false);
  } finally { as?.disconnect(); bs?.disconnect(); cs?.disconnect(); await f.close(); }
});
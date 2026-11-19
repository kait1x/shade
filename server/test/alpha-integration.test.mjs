// Cross-feature integration (B9): the full PWA backend surface over real
// HTTP/WSS in one lifecycle — devices, profiles, stickers, self-chat,
// presence, read receipts, retract, media chunks, push, revocation, restart.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { io } from 'socket.io-client';
import { fixture, identity, register, operation, proof, stickers } from './helpers/alpha-fixture.mjs';
import * as c from '../../client/web/device_crypto.mjs';
import { sign, requestText, hash, messageText } from '../../client/web/protocol/device-v2.mjs';
import { messageRef } from '../multidevice/registry.mjs';

const require = createRequire(import.meta.url);
const sharp = require('sharp');
const webPush = require('web-push');
async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-integration-'));
}
const trustAB = (a, b) => ({ senderRoot: a.vault.signingKey, recipientRoot: b.vault.signingKey,
  senderGenesis: a.genesis, recipientGenesis: b.genesis });

test('full device-v2 PWA lifecycle integrates every backend feature', async () => {
  const dataDir = await tempDir(), storageSecret = randomBytes(32).toString('hex');
  const vapidKeys = webPush.generateVAPIDKeys();
  const pushes = [];
  const pushSender = async (sub, payload) => { pushes.push({ sub, payload }); };
  const f = await fixture({ dataDir, storageSecret, vapidKeys, pushSender });
  const alice = await identity('alice_int'), bob = await identity('bob_int');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  await register(f, alice, ac); await register(f, bob, bc);
  const deviceProof = async (who, session, cookie, op, body = null) => {
    const digest = await hash(JSON.stringify([op, op === 'send' ? await hash(messageText(body)) : body]));
    const ch = await f.request('/api/v2/challenge', { account: who.session.account, id: session.id, operation: digest }, cookie);
    return { account: who.session.account, id: session.id, nonce: ch.result.nonce,
      proof: await sign(requestText(who.session.account, session.id, ch.result.nonce, digest), session.signing) };
  };
  let aliceSock, bobSock;
  try {
    // Profiles + stickers (B1/B2).
    await stickers(f, alice, ac, 'PUT', '/profile/name', { displayName: 'Alice' });
    const image = (await sharp({ create: { width: 12, height: 12, channels: 3, background: '#00ff00' } }).png().toBuffer()).toString('base64');
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image, frame: 'silver', revision: 0 })).result.revision, 1);
    assert.equal((await stickers(f, bob, bc, 'GET', '/user/alice_int/avatar')).result.displayName, 'Alice');
    const gift = await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'bob_int', stickerId: 'comet', note: 'integration', requestId: 'int'.padEnd(16, 'g') });
    const giftId = gift.result.giftId;
    await stickers(f, bob, bc, 'PUT', '/stickers/wall',
      { wall: [{ giftId, xNorm: .25, yNorm: .75, scale: 1, rotation: 0, zIndex: 1 }], revision: 0 });

    // Second device for alice (B9 pairing), then self-chat across both (B3).
    const vault2 = await c.createVault('alice_int', 'synthetic second integration passphrase');
    const session2 = await c.unlockVault(vault2, 'synthetic second integration passphrase');
    const manifest2 = await c.approveDevices(alice.genesis, [alice.manifest],
      [...alice.manifest.devices, c.descriptor(vault2)], alice.session);
    assert.equal((await operation(f, alice, ac, 'install',
      { manifest: manifest2, proofs: [await c.pairingProof(vault2, session2)], genesis: alice.genesis })).result.revision, 2);
    const selfNote = await c.sealMessage('моя заметка', [alice.manifest, manifest2], [alice.manifest, manifest2],
      alice.session, trustAB(alice, alice));
    assert.equal(selfNote.envelopes.length, 2);
    await operation(f, alice, ac, 'send', selfNote);
    const a2Inbox = (await f.request('/api/v2/operation',
      { op: 'fetch', auth: await deviceProof(alice, session2, ac, 'fetch') }, ac)).result;
    const selfBundle = a2Inbox.find(b => b.message.id === selfNote.id);
    assert.equal(await c.openMessage(selfBundle, session2, trustAB(alice, alice)), 'моя заметка');

    // Cross message with the ZCODE reply payload, read receipt (B7).
    const replyPayload = JSON.stringify({ shade: 1, t: 'ответ bob', r: { ref: messageRef(selfNote), from: 'alice_int', text: 'моя заметка' } });
    const cross = await c.sealMessage(replyPayload, [alice.manifest, manifest2], [bob.manifest], alice.session, trustAB(alice, bob));
    await operation(f, alice, ac, 'send', cross);
    const crossRef = messageRef(cross);
    const bobInbox = (await operation(f, bob, bc, 'fetch')).result;
    const bobBundle = bobInbox.find(b => b.message.id === cross.id);
    const decoded = JSON.parse(await c.openMessage(bobBundle, bob.session, trustAB(alice, bob)));
    assert.equal(decoded.t, 'ответ bob');
    assert.equal(decoded.r.ref, messageRef(selfNote));
    await operation(f, bob, bc, 'ack', [crossRef]);
    assert.equal((await operation(f, bob, bc, 'read', [crossRef])).result.read, 1);
    assert.equal(typeof (await operation(f, alice, ac, 'status', [crossRef])).result[crossRef][0].readAt, 'number');

    // Typing/presence over real sockets (B4).
    aliceSock = io(f.origin, { autoConnect: false, transports: ['websocket'], extraHeaders: { Cookie: ac }, auth: await proof(f, alice, ac, 'socket') });
    bobSock = io(f.origin, { autoConnect: false, transports: ['websocket'], extraHeaders: { Cookie: bc }, auth: await proof(f, bob, bc, 'socket') });
    await Promise.all([aliceSock, bobSock].map(s => new Promise((res, rej) => { s.once('connect', res); s.once('connect_error', rej); s.connect(); })));
    bobSock.emit('watch', { peer: 'alice_int' });
    const presence = await new Promise((res, rej) => { const t = setTimeout(() => rej(Error('presence timeout')), 4000); bobSock.once('presence', d => { clearTimeout(t); res(d); }); });
    // Presence carries the restart-safe lastSeen hint alongside live liveness.
    assert.equal(presence.account, 'alice_int');
    assert.equal(presence.online, true);
    assert.ok(Number.isFinite(presence.lastSeen) && presence.lastSeen > 0);
    aliceSock.emit('typing', { peer: 'bob_int' });
    const typing = await new Promise((res, rej) => { const t = setTimeout(() => rej(Error('typing timeout')), 4000); bobSock.once('typing', d => { clearTimeout(t); res(d); }); });
    assert.equal(typing.account, 'alice_int');

    // Retract the cross message (B5); tombstone reaches bob.
    assert.equal((await operation(f, alice, ac, 'retract', [crossRef])).result.retracted, 1);
    assert.ok((await operation(f, bob, bc, 'retractions', { since: 0 })).result.retractions.some(t => t.ref === crossRef));

    // Media chunks (B6) + push wake (B8).
    await operation(f, bob, bc, 'push.subscribe',
      { endpoint: 'https://push.example.com/int/bob', keys: { p256dh: 'BPintKeyValueBase64UrlExample1234567890', auth: 'intAuthBase64Url' } });
    const blob = randomBytes(70 * 1024);
    const chunks = [blob.subarray(0, 32768), blob.subarray(32768, 65536), blob.subarray(65536)];
    for (let index = 0; index < chunks.length; index++) {
      const payload = JSON.stringify({ shade: 1, m: { id: 'intmedia', mime: 'image/jpeg', index, total: 3, chunk: chunks[index].toString('base64') } });
      const m = await c.sealMessage(payload, [alice.manifest, manifest2], [bob.manifest], alice.session, trustAB(alice, bob));
      await operation(f, alice, ac, 'send', m);
    }
    assert.equal(pushes.length, 3);
    assert.ok(pushes.every(p => p.payload.type === 'wake' && Object.keys(p.payload).length === 1));
    const mediaInbox = (await operation(f, bob, bc, 'fetch')).result;
    const parts = [];
    for (const bundle of mediaInbox) {
      const parsed = JSON.parse(await c.openMessage(bundle, bob.session, trustAB(alice, bob)));
      parts[parsed.m.index] = Buffer.from(parsed.m.chunk, 'base64');
    }
    assert.equal(createHash('sha256').update(Buffer.concat(parts)).digest('hex'),
      createHash('sha256').update(blob).digest('hex'));

    // Revoke alice's second device (B9): push subscriptions pruned, fanout shrinks.
    await f.request('/api/v2/operation', { op: 'push.subscribe',
      body: { endpoint: 'https://push.example.com/int/a2', keys: { p256dh: 'BPintKeyValueBase64UrlExample1234567890', auth: 'intAuthBase64Url' } },
      auth: await deviceProof(alice, session2, ac, 'push.subscribe',
        { endpoint: 'https://push.example.com/int/a2', keys: { p256dh: 'BPintKeyValueBase64UrlExample1234567890', auth: 'intAuthBase64Url' } }) }, ac);
    assert.ok(f.registry.pushSubscription('alice_int', session2.id));
    const manifest3 = await c.approveDevices(alice.genesis, [alice.manifest, manifest2],
      [alice.manifest.devices[0]], alice.session);
    assert.equal((await operation(f, alice, ac, 'install', { manifest: manifest3, proofs: [], genesis: alice.genesis })).result.revision, 3);
    assert.equal(f.registry.pushSubscription('alice_int', session2.id), null);
    const afterRevoke = await c.sealMessage('после отзыва', [alice.manifest, manifest2, manifest3], [bob.manifest], alice.session, trustAB(alice, bob));
    assert.equal(afterRevoke.envelopes.length, 2);
    assert.equal((await operation(f, alice, ac, 'send', afterRevoke)).result.accepted, true);
  } finally {
    aliceSock?.disconnect(); bobSock?.disconnect();
    await f.close();
  }

  // Restart: every feature's state survives in the encrypted snapshot.
  const f2 = await fixture({ dataDir, storageSecret, vapidKeys, pushSender });
  try {
    const ac2 = await f2.login('synthetic-alice'), bc2 = await f2.login('synthetic-bob');
    assert.equal((await stickers(f2, bob, bc2, 'GET', '/stickers/inventory')).result.inventory.length, 1);
    assert.equal((await stickers(f2, bob, bc2, 'GET', '/stickers/inventory')).result.wall.length, 1);
    assert.equal((await stickers(f2, alice, ac2, 'GET', '/user/alice_int/avatar')).result.displayName, 'Alice');
    assert.ok((await operation(f2, bob, bc2, 'retractions', { since: 0 })).result.retractions.length >= 1);
    const pushesBefore = pushes.length;
    const aliceDir = (await operation(f2, alice, ac2, 'directory', 'alice_int')).result;
    const m = await c.sealMessage('после рестарта', aliceDir.history, [bob.manifest], alice.session, trustAB(alice, bob));
    await operation(f2, alice, ac2, 'send', m);
    assert.equal(pushes.length, pushesBefore + 1);
  } finally { await f2.close(); }
});
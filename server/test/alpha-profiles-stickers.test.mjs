// device-v2 profiles & stickers via the safe v1 adapter: device-proof auth,
// CAS/idempotency, validation, privacy, limits and restart persistence.
// Synthetic identities only; production storage is never touched.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes, generateKeyPairSync } from 'node:crypto';
import { createRequire } from 'node:module';
import { fixture, identity, register, stickers } from './helpers/alpha-fixture.mjs';
import { sign, requestText } from '../../client/web/protocol/device-v2.mjs';
import { stickersOperation } from '../multidevice/v2-stickers.mjs';

const require = createRequire(import.meta.url);
const sharp = require('sharp');
const png = async () => (await sharp({ create: { width: 16, height: 16, channels: 3,
  background: '#ff0000' } }).png().toBuffer()).toString('base64');

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-stickers-'));
}
async function setup() {
  const dataDir = await tempDir(), storageSecret = randomBytes(32).toString('hex');
  const legacy = generateKeyPairSync('rsa', { modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
  const legacyUsers = new Map([['legacy_only', { publicKey: legacy.publicKey, googleSub: 'synthetic-legacy' }]]);
  const f = await fixture({ dataDir, storageSecret, legacyUsers });
  const alice = await identity('alice_v2'), bob = await identity('bob_v2');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  await register(f, alice, ac); await register(f, bob, bc);
  return { f, alice, bob, ac, bc, dataDir, storageSecret, legacyUsers };
}

test('gift reads complete while a registry write is pending', async () => {
  const { f, alice, bob, ac, bc } = await setup();
  const entered = Promise.withResolvers();
  const releaseWrite = Promise.withResolvers();
  const pendingWrite = f.registry.updateState(async () => {
    entered.resolve();
    await releaseWrite.promise;
  });
  let timeout;
  try {
    await entered.promise;
    const reads = await Promise.race([
      Promise.all([
        stickers(f, alice, ac, 'GET', '/stickers/inventory'),
        stickers(f, bob, bc, 'GET', '/user/alice_v2/stickers'),
      ]),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error('Gift reads waited for the pending write')), 3000);
      }),
    ]);
    for (const { response, result } of reads) {
      assert.equal(response.status, 200);
      assert.deepEqual(result.inventory, []);
      assert.deepEqual(result.wall, []);
    }
  } finally {
    clearTimeout(timeout);
    releaseWrite.resolve();
    try { await pendingWrite; } finally { await f.close(); }
  }
});

test('profiles: displayName, avatar validation, CAS, idempotent uploads, auth binding', async () => {
  const { f, alice, bob, ac, bc } = await setup();
  try {
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/name', { displayName: 'Alice' })).result.displayName, 'Alice');
    const seen = await stickers(f, bob, bc, 'GET', '/user/alice_v2/avatar');
    assert.equal(seen.result.displayName, 'Alice');
    assert.equal(seen.result.image, null);
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/name', { displayName: 'x'.repeat(65) })).response.status, 400);
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/name', { displayName: '  ' })).response.status, 400);

    const image = await png();
    const first = await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image, frame: 'silver', revision: 0 });
    assert.equal(first.response.status, 200);
    assert.equal(first.result.revision, 1);
    assert.equal(first.result.frame, 'silver');
    assert.ok(first.result.image && first.result.image !== image); // re-encoded, metadata stripped
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image, frame: 'silver', revision: 0 })).response.status, 409);
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image, frame: 'gold', revision: 1 })).response.status, 400);
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image: '!!!', frame: 'none', revision: 1 })).response.status, 400);
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/avatar',
      { image: Buffer.from('not an image').toString('base64'), frame: 'none', revision: 1 })).response.status, 400);

    // uploadId idempotency: same request retries safely, conflicts reject.
    const uploadId = 'u'.repeat(20);
    const up = await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image, frame: 'minimal', revision: 1, uploadId });
    assert.equal(up.result.revision, 2);
    const retry = await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image, frame: 'minimal', revision: 1, uploadId });
    assert.equal(retry.response.status, 200);
    assert.equal(retry.result.revision, 2);
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/avatar', { image, frame: 'none', revision: 1, uploadId })).response.status, 409);

    // Chunked upload: ordered assembly, idempotent tail, out-of-order reject.
    const chunkId = 'c'.repeat(20), half = Math.floor(image.length / 2);
    const p1 = await stickers(f, alice, ac, 'POST', '/profile/avatar/chunk',
      { uploadId: chunkId, offset: 0, total: image.length, chunk: image.slice(0, half), frame: 'graphite', revision: 2 });
    assert.equal(p1.result.complete, false);
    const p2body = { uploadId: chunkId, offset: half, total: image.length, chunk: image.slice(half), frame: 'graphite', revision: 2 };
    const p2 = await stickers(f, alice, ac, 'POST', '/profile/avatar/chunk', p2body);
    assert.equal(p2.result.complete, true);
    assert.equal(p2.result.profile.revision, 3);
    assert.equal((await stickers(f, alice, ac, 'POST', '/profile/avatar/chunk', p2body)).result.profile.revision, 3);
    assert.equal((await stickers(f, alice, ac, 'POST', '/profile/avatar/chunk',
      { uploadId: 'd'.repeat(20), offset: 5, total: image.length, chunk: image.slice(5, 10), frame: 'none', revision: 3 })).response.status, 409);

    // Another account sees the public profile but not private state.
    const bobView = await stickers(f, bob, bc, 'GET', '/user/alice_v2/avatar');
    assert.ok(bobView.result.image);
    assert.equal(bobView.result.frame, 'graphite');
    assert.equal((await stickers(f, bob, bc, 'GET', '/user/bob_v2/avatar')).result.image, null);

    // Auth: missing proof, replayed nonce, wrong operation, cross-account.
    assert.equal((await f.request('/api/v2/stickers/inventory', undefined, ac)).response.status, 401);
    const operation = await stickersOperation('GET', '/stickers/inventory');
    const ch = await f.request('/api/v2/challenge', { account: 'alice_v2', id: alice.session.id, operation }, ac);
    const auth = { account: 'alice_v2', id: alice.session.id, nonce: ch.result.nonce,
      proof: await sign(requestText('alice_v2', alice.session.id, ch.result.nonce, operation), alice.session.signing) };
    const headers = { 'x-device-auth': JSON.stringify(auth) };
    assert.equal((await f.request('/api/v2/stickers/inventory', undefined, ac, headers)).response.status, 200);
    assert.equal((await f.request('/api/v2/stickers/inventory', undefined, ac, headers)).response.status, 401);
    assert.equal((await f.request('/api/v2/stickers/inventory', undefined, bc, headers)).response.status, 401);
    const nameOp = await stickersOperation('PUT', '/profile/name', { displayName: 'Mallory' });
    const ch2 = await f.request('/api/v2/challenge', { account: 'alice_v2', id: alice.session.id, operation: nameOp }, ac);
    const auth2 = { account: 'alice_v2', id: alice.session.id, nonce: ch2.result.nonce,
      proof: await sign(requestText('alice_v2', alice.session.id, ch2.result.nonce, nameOp), alice.session.signing) };
    assert.equal((await f.request('/api/v2/stickers/inventory', undefined, ac,
      { 'x-device-auth': JSON.stringify(auth2) })).response.status, 401);
  } finally { await f.close(); }
});

test('stickers: gift idempotency and limits, wall CAS, privacy, restart persistence', async () => {
  const { f, alice, bob, ac, bc, dataDir, storageSecret, legacyUsers } = await setup();
  try {
    const inv0 = await stickers(f, alice, ac, 'GET', '/stickers/inventory');
    assert.deepEqual(inv0.result, { inventory: [], wall: [], revision: 0 });
    await stickers(f, alice, ac, 'PUT', '/profile/name', { displayName: 'Alice' });
    const image = await png();
    assert.equal((await stickers(f, alice, ac, 'PUT', '/profile/avatar',
      { image, frame: 'silver', revision: 0 })).result.revision, 1);
    for (const retiredGift of ['orbit', 'moth', 'comet', 'ghost']) {
      assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift', {
        toUsername: 'bob_v2', stickerId: retiredGift, note: '', requestId: 'retired'.padEnd(16, 'x'),
      })).response.status, 400);
    }

    const requestId = 'g'.repeat(16);
    const gift = await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'bob_v2', stickerId: 'flowers', note: 'hi', requestId });
    assert.equal(gift.response.status, 200);
    const giftId = gift.result.giftId;
    assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'bob_v2', stickerId: 'flowers', note: 'hi', requestId })).result.giftId, giftId);
    assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'bob_v2', stickerId: 'flowers', note: 'changed', requestId })).response.status, 409);
    assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'bob_v2', stickerId: 'dragon', note: '', requestId: 'h'.repeat(16) })).response.status, 400);
    assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'alice_v2', stickerId: 'flowers', note: '', requestId: 'i'.repeat(16) })).response.status, 400);
    assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'legacy_only', stickerId: 'flowers', note: '', requestId: 'j'.repeat(16) })).response.status, 404);
    assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'bob_v2', stickerId: 'flowers', note: 'x'.repeat(241), requestId: 'k'.repeat(16) })).response.status, 400);
    // 8 gifts/min cap (1 already sent): 7 more ok, 9th rejected.
    for (let n = 0; n < 7; n++) {
      assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
        { toUsername: 'bob_v2', stickerId: 'flowers', note: '', requestId: `rate${n}`.padEnd(16, 'r') })).response.status, 200);
    }
    assert.equal((await stickers(f, alice, ac, 'POST', '/stickers/gift',
      { toUsername: 'bob_v2', stickerId: 'flowers', note: '', requestId: 'rate'.padEnd(16, 'x') })).response.status, 429);

    const bobInv = await stickers(f, bob, bc, 'GET', '/stickers/inventory');
    assert.equal(bobInv.result.inventory.length, 8);
    assert.equal(bobInv.result.inventory[0].fromUsername, 'alice_v2');
    const placement = { giftId, xNorm: .5, yNorm: .5, scale: 1, rotation: 0, zIndex: 0 };
    assert.equal((await stickers(f, bob, bc, 'PUT', '/stickers/wall', { wall: [placement], revision: 0 })).result.revision, 1);
    assert.equal((await stickers(f, bob, bc, 'PUT', '/stickers/wall', { wall: [placement], revision: 0 })).response.status, 409);
    assert.equal((await stickers(f, bob, bc, 'PUT', '/stickers/wall',
      { wall: [{ ...placement, giftId: 'not-owned' }], revision: 1 })).response.status, 400);
    assert.equal((await stickers(f, bob, bc, 'PUT', '/stickers/wall',
      { wall: [placement, placement], revision: 1 })).response.status, 400);
    assert.equal((await stickers(f, bob, bc, 'PUT', '/stickers/wall',
      { wall: [{ ...placement, xNorm: 1.5 }], revision: 1 })).response.status, 400);
    // Alice cannot place bob's gift on her own wall.
    assert.equal((await stickers(f, alice, ac, 'PUT', '/stickers/wall', { wall: [placement], revision: 0 })).response.status, 400);
    // Public view exposes only giftId/stickerId of the inventory.
    const publicView = await stickers(f, alice, ac, 'GET', '/user/bob_v2/stickers');
    assert.deepEqual(publicView.result.inventory[0], { giftId, stickerId: 'flowers' });
    assert.equal(publicView.result.wall.length, 1);
  } finally { await f.close(); }

  // Restart: encrypted snapshot restores profiles, inventory and wall.
  const f2 = await fixture({ dataDir, storageSecret, legacyUsers });
  try {
    const ac2 = await f2.login('synthetic-alice'), bc2 = await f2.login('synthetic-bob');
    assert.equal((await f2.request('/api/v2/stickers/inventory', undefined, bc2)).response.status, 401);
    const inv = await stickers(f2, bob, bc2, 'GET', '/stickers/inventory');
    assert.equal(inv.result.inventory.length, 8);
    assert.equal(inv.result.wall.length, 1);
    assert.equal(inv.result.revision, 1);
    const profile = await stickers(f2, alice, ac2, 'GET', '/user/alice_v2/avatar');
    assert.equal(profile.result.displayName, 'Alice');
    assert.equal(profile.result.revision, 1);
    assert.equal(profile.result.frame, 'silver');
    assert.ok(profile.result.image);
  } finally { await f2.close(); }
});
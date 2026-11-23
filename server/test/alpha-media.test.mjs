// Media chunking (contract C4): the existing signed device-v2 envelope carries
// opaque ciphertext, so photos travel as multiple ≤64KiB plaintext chunks.
// This proves the real server path: limits, fanout, ordering-independent
// reassembly, and rejection of oversized envelopes. Metadata stripping and
// reassembly are client responsibilities (documented for ZCODE).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import { fixture, identity, register, operation, proof } from './helpers/alpha-fixture.mjs';
import { sealMessage, openMessage } from '../../client/web/device_crypto.mjs';
import { hash, messageText } from '../../client/web/protocol/device-v2.mjs';

const CHUNK_RAW = 32768; // base64 + JSON wrapper stays under the 64KiB limit
async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-media-'));
}
const trust = (a, b) => ({ senderRoot: a.vault.signingKey, recipientRoot: b.vault.signingKey,
  senderGenesis: a.genesis, recipientGenesis: b.genesis });

test('300KB media round-trips through chunked E2EE messages; oversized envelopes reject', async () => {
  const dataDir = await tempDir();
  const checkpointDir = path.join(dataDir, 'checkpoints');
  const f = await fixture({ dataDir, checkpointDir, storageSecret: randomBytes(32).toString('hex') });
  try {
    const alice = await identity('alice_media'), bob = await identity('bob_media');
    const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
    await register(f, alice, ac); await register(f, bob, bc);

    const photo = randomBytes(300 * 1024); // synthetic stand-in for a stripped JPEG
    const mediaId = randomBytes(16).toString('hex');
    const total = Math.ceil(photo.length / CHUNK_RAW);
    const refs = [];
    const messages = [];
    for (let index = 0; index < total; index++) {
      const chunk = photo.subarray(index * CHUNK_RAW, (index + 1) * CHUNK_RAW).toString('base64');
      const payload = JSON.stringify({ shade: 1, m: { id: mediaId, mime: 'image/jpeg', index, total, chunk } });
      assert.ok(Buffer.byteLength(payload) <= 65536);
      const m = await sealMessage(payload, [alice.manifest], [bob.manifest], alice.session, trust(alice, bob));
      messages.push(m);
      refs.push(`${m.from}:${m.deviceId}:${m.id}`);
    }
    assert.equal(total, 10);
    const send = async body => {
      const digests = await Promise.all(body.map(m => hash(messageText(m))));
      const auth = await proof(f, alice, ac, 'send.batch', digests);
      return f.request('/api/v2/operation', { op: 'send.batch', body, auth }, ac);
    };
    const invalid = structuredClone(messages[1]);
    invalid.signature = (invalid.signature[0] === 'A' ? 'B' : 'A') + invalid.signature.slice(1);
    const checkpoints = (await fs.readdir(checkpointDir)).length;
    assert.equal((await send([messages[0], invalid])).response.status, 400);
    assert.deepEqual((await operation(f, bob, bc, 'fetch')).result, []);
    assert.equal((await send(messages.slice(0, 8))).result.accepted, true);
    assert.equal((await send(messages.slice(8))).result.accepted, true);
    assert.equal((await send(messages.slice(0, 8))).result.duplicate, true);
    assert.equal((await fs.readdir(checkpointDir)).length, checkpoints + 2);

    // Receiver reassembles by media id/index, independent of delivery order.
    const inbox = (await operation(f, bob, bc, 'fetch')).result;
    assert.equal(inbox.length, total);
    const parts = new Array(total);
    for (const bundle of inbox.reverse()) {
      const plaintext = await openMessage(bundle, bob.session, trust(alice, bob));
      const parsed = JSON.parse(plaintext);
      assert.equal(parsed.shade, 1);
      assert.equal(parsed.m.id, mediaId);
      parts[parsed.m.index] = Buffer.from(parsed.m.chunk, 'base64');
    }
    const assembled = Buffer.concat(parts);
    assert.equal(createHash('sha256').update(assembled).digest('hex'),
      createHash('sha256').update(photo).digest('hex'));
    await operation(f, bob, bc, 'ack', refs);

    // Client-side limit: a single >64KiB plaintext cannot be sealed.
    const tooBig = JSON.stringify({ shade: 1, m: { id: mediaId, mime: 'image/jpeg', index: 0, total: 1,
      chunk: randomBytes(60000).toString('base64') } });
    await assert.rejects(() => sealMessage(tooBig, [alice.manifest], [bob.manifest], alice.session, trust(alice, bob)),
      /Text too large/);

    // Server-side limit: an envelope with oversized ciphertext is rejected.
    const m = await sealMessage('small', [alice.manifest], [bob.manifest], alice.session, trust(alice, bob));
    const oversized = { ...m, envelopes: m.envelopes.map(e => ({ ...e,
      payload: { k: e.payload.k, d: 'A'.repeat(100001) } })) };
    // messageText itself rejects d > 100000 base64 chars.
    assert.throws(() => messageText(oversized));
  } finally { await f.close(); }
});

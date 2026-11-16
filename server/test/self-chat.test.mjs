// Self-chat («Избранное») over the real alpha HTTP adapter: correct fanout
// semantics for one roster, per-device ACK, and negative shape/auth cases.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fixture, identity, register, operation } from './helpers/alpha-fixture.mjs';
import * as c from '../../client/web/device_crypto.mjs';
import { messageText, verifyMessage, hash, manifestText, sign, requestText } from '../../client/web/protocol/device-v2.mjs';
import { messageRef } from '../multidevice/registry.mjs';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-self-'));
}
const trustOf = who => ({ senderRoot: who.vault.signingKey, recipientRoot: who.vault.signingKey,
  senderGenesis: who.genesis, recipientGenesis: who.genesis });

test('self-chat fans out to every own device, ACKs per device, rejects malformed fanout', async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  try {
    const alice = await identity('alice_self');
    const ac = await f.login('synthetic-alice');
    await register(f, alice, ac);

    // One device: a single envelope is valid for self-chat.
    const text = 'Заметка себе 🔐';
    const m1 = await c.sealMessage(text, [alice.manifest], [alice.manifest], alice.session, trustOf(alice));
    assert.equal(m1.envelopes.length, 1);
    assert.equal((await operation(f, alice, ac, 'send', m1)).result.accepted, true);
    const inbox = (await operation(f, alice, ac, 'fetch')).result;
    const bundle = inbox.find(b => b.message.id === m1.id);
    assert.equal(await c.openMessage(bundle, alice.session, trustOf(alice)), text);
    const ref1 = messageRef(m1);
    assert.equal((await operation(f, alice, ac, 'ack', [ref1])).result.acknowledged, 1);
    const status = (await operation(f, alice, ac, 'status', [ref1])).result;
    assert.equal(typeof status[ref1][0].acknowledgedAt, 'number');

    // Add a second device; self-chat must reach both with independent ciphertext.
    const second = await c.createVault('alice_self', 'synthetic second device passphrase');
    const secondSession = await c.unlockVault(second, 'synthetic second device passphrase');
    const manifest2 = await c.approveDevices(alice.genesis, [alice.manifest],
      [...alice.manifest.devices, c.descriptor(second)], alice.session);
    const install = await operation(f, alice, ac, 'install',
      { manifest: manifest2, proofs: [await c.pairingProof(second, secondSession)], genesis: alice.genesis });
    assert.equal(install.result.revision, 2);
    const text2 = 'Вторая заметка на два устройства';
    const m2 = await c.sealMessage(text2, [alice.manifest, manifest2], [alice.manifest, manifest2],
      alice.session, { senderRoot: alice.vault.signingKey, recipientRoot: alice.vault.signingKey,
        senderGenesis: alice.genesis, recipientGenesis: alice.genesis });
    assert.equal(m2.envelopes.length, 2);
    assert.notEqual(m2.envelopes[0].payload.d, m2.envelopes[1].payload.d);
    assert.equal((await operation(f, alice, ac, 'send', m2)).result.accepted, true);
    // Second device fetches and decrypts its own envelope with its own proof.
    const secondProof = async (op, body = null) => {
      const operationDigest = await hash(JSON.stringify([op, op === 'send' ? await hash(messageText(body)) : body]));
      const challenge = await f.request('/api/v2/challenge',
        { account: 'alice_self', id: secondSession.id, operation: operationDigest }, ac);
      return { account: 'alice_self', id: secondSession.id, nonce: challenge.result.nonce,
        proof: await sign(requestText('alice_self', secondSession.id, challenge.result.nonce, operationDigest), secondSession.signing) };
    };
    const inbox2 = (await f.request('/api/v2/operation',
      { op: 'fetch', auth: await secondProof('fetch') }, ac)).result;
    const bundle2 = inbox2.find(b => b.message.id === m2.id);
    assert.equal(await c.openMessage(bundle2, secondSession, trustOf(alice)), text2);
    const ref2 = messageRef(m2);
    await f.request('/api/v2/operation', { op: 'ack', body: [ref2], auth: await secondProof('ack', [ref2]) }, ac);
    await operation(f, alice, ac, 'ack', [ref2]);
    const status2 = (await operation(f, alice, ac, 'status', [ref2])).result;
    assert.equal(status2[ref2].length, 2);
    assert.ok(status2[ref2].every(d => typeof d.acknowledgedAt === 'number'));

    // Negative: missing / extra / duplicated envelopes and mismatched self tips.
    const base = await c.sealMessage('neg', [alice.manifest, manifest2], [alice.manifest, manifest2],
      alice.session, trustOf(alice));
    const missing = { ...base, envelopes: base.envelopes.slice(0, 1) };
    missing.signature = await sign(messageText(missing), alice.session.signing);
    assert.equal((await operation(f, alice, ac, 'send', missing)).response.status, 400);
    // Duplicate envelope targets are rejected by the canonical shape itself.
    const extra = { ...base, envelopes: [...base.envelopes, base.envelopes[0]] };
    assert.throws(() => messageText(extra), /Duplicate or unordered recipients/);
    const staleTip = { ...base, toRevision: 1, toDigest: await hash(manifestText(alice.manifest)) };
    staleTip.signature = await sign(messageText(staleTip), alice.session.signing);
    // 'Stale device directory' maps to 409 in the alpha error handler.
    assert.equal((await operation(f, alice, ac, 'send', staleTip)).response.status, 409);
    // verifyMessage directly: self with different revisions must fail even if signed.
    await assert.rejects(() => verifyMessage(staleTip, manifest2, manifest2), /Stale device directory/);
    // Ordinary cross-account messages keep the old canonical text (regression).
    const bob = await identity('bob_self');
    const bc = await f.login('synthetic-bob');
    await register(f, bob, bc);
    const cross = await c.sealMessage('cross', [alice.manifest, manifest2], [bob.manifest], alice.session,
      { senderRoot: alice.vault.signingKey, recipientRoot: bob.vault.signingKey,
        senderGenesis: alice.genesis, recipientGenesis: bob.genesis });
    assert.equal(cross.envelopes.length, 3);
    assert.equal((await operation(f, alice, ac, 'send', cross)).result.accepted, true);
  } finally { await f.close(); }
});
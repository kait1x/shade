// Delete-for-all (contract C3): sender authorization, offline queue purge,
// idempotency, participant-only tombstones, limits and restart persistence.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fixture, identity, register, operation } from './helpers/alpha-fixture.mjs';
import { sealMessage } from '../../client/web/device_crypto.mjs';
import { messageRef } from '../multidevice/registry.mjs';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-retract-'));
}
const sendText = async (f, from, to, cookie, text) => {
  const m = await sealMessage(text, [from.manifest], [to.manifest], from.session,
    { senderRoot: from.vault.signingKey, recipientRoot: to.vault.signingKey,
      senderGenesis: from.genesis, recipientGenesis: to.genesis });
  assert.equal((await operation(f, from, cookie, 'send', m)).result.accepted, true);
  return messageRef(m);
};

test('retract purges offline queues, is sender-only and idempotent, tombstones are private', async () => {
  const dataDir = await tempDir(), storageSecret = randomBytes(32).toString('hex');
  const f = await fixture({ dataDir, storageSecret });
  const alice = await identity('alice_retract'), bob = await identity('bob_retract');
  const carol = await identity('carol_retract');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  const cc = await f.login('synthetic-carol');
  await register(f, alice, ac); await register(f, bob, bc); await register(f, carol, cc);
  try {
    // Offline recipient: two queued messages, both retracted before delivery.
    const ref1 = await sendText(f, alice, bob, ac, 'offline 1');
    const ref2 = await sendText(f, alice, bob, ac, 'offline 2');
    assert.equal((await operation(f, alice, ac, 'retract', [ref1, ref2])).result.retracted, 2);
    assert.deepEqual((await operation(f, bob, bc, 'fetch')).result, []);
    const bobTomb = (await operation(f, bob, bc, 'retractions', { since: 0 })).result.retractions;
    assert.deepEqual(bobTomb.map(t => t.ref).sort(), [ref1, ref2].sort());
    // Idempotent retry.
    assert.equal((await operation(f, alice, ac, 'retract', [ref1, ref2])).result.retracted, 0);

    // Delivered-then-acked message: tombstone still reaches the recipient.
    const ref3 = await sendText(f, alice, bob, ac, 'delivered');
    const inbox = (await operation(f, bob, bc, 'fetch')).result;
    assert.equal(inbox.length, 1);
    await operation(f, bob, bc, 'ack', [ref3]);
    await operation(f, alice, ac, 'retract', [ref3]);
    const since = bobTomb[0].deletedAt;
    const newer = (await operation(f, bob, bc, 'retractions', { since })).result.retractions;
    assert.ok(newer.some(t => t.ref === ref3));
    // Sender sees own tombstones; a stranger sees nothing.
    assert.ok((await operation(f, alice, ac, 'retractions', { since: 0 })).result.retractions.length >= 3);
    assert.deepEqual((await operation(f, carol, cc, 'retractions', { since: 0 })).result.retractions, []);

    // Authorization: only the sender may retract; malformed/oversized reject.
    assert.equal((await operation(f, bob, bc, 'retract', [ref3])).response.status, 400);
    assert.equal((await operation(f, alice, ac, 'retract', ['bad-ref'])).response.status, 400);
    assert.equal((await operation(f, alice, ac, 'retract',
      Array.from({ length: 201 }, () => ref1))).response.status, 400);
    // Unknown ref is a no-op (idempotent), not an error.
    const unknown = `alice_retract:primary:${'ab'.repeat(32)}`;
    assert.equal((await operation(f, alice, ac, 'retract', [unknown])).result.retracted, 1);
  } finally { await f.close(); }

  // Tombstones survive restart via the encrypted snapshot. Bob sees the three
  // messages he participated in; the never-sent ref is visible to alice only.
  const f2 = await fixture({ dataDir, storageSecret });
  try {
    const bc2 = await f2.login('synthetic-bob');
    const tomb = (await operation(f2, bob, bc2, 'retractions', { since: 0 })).result.retractions;
    assert.equal(tomb.length, 3);
    const ac2 = await f2.login('synthetic-alice');
    assert.equal((await operation(f2, alice, ac2, 'retractions', { since: 0 })).result.retractions.length, 4);
  } finally { await f2.close(); }
});
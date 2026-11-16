// Read-ACK (contract C5): recipient-device authorization, idempotency,
// sender projection via status, privacy for strangers, restart persistence.
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
  return fs.mkdtemp(path.join(build, 'alpha-read-'));
}

test('read receipts are recipient-only, idempotent and visible to the sender', async () => {
  const dataDir = await tempDir(), storageSecret = randomBytes(32).toString('hex');
  const f = await fixture({ dataDir, storageSecret });
  const alice = await identity('alice_read'), bob = await identity('bob_read');
  const carol = await identity('carol_read');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  const cc = await f.login('synthetic-carol');
  await register(f, alice, ac); await register(f, bob, bc); await register(f, carol, cc);
  let ref;
  try {
    const m = await sealMessage('read me', [alice.manifest], [bob.manifest], alice.session,
      { senderRoot: alice.vault.signingKey, recipientRoot: bob.vault.signingKey,
        senderGenesis: alice.genesis, recipientGenesis: bob.genesis });
    ref = messageRef(m);
    await operation(f, alice, ac, 'send', m);
    await operation(f, bob, bc, 'fetch');
    await operation(f, bob, bc, 'ack', [ref]);

    const before = (await operation(f, alice, ac, 'status', [ref])).result[ref][0];
    assert.equal(typeof before.acknowledgedAt, 'number');
    assert.equal(before.readAt, undefined);

    assert.equal((await operation(f, bob, bc, 'read', [ref])).result.read, 1);
    assert.equal((await operation(f, bob, bc, 'read', [ref])).result.read, 0);
    const after = (await operation(f, alice, ac, 'status', [ref])).result[ref][0];
    assert.equal(typeof after.readAt, 'number');

    // Stranger and sender cannot forge a recipient read; unknown ref is a no-op.
    assert.equal((await operation(f, carol, cc, 'read', [ref])).result.read, 0);
    assert.equal((await operation(f, alice, ac, 'read', [ref])).result.read, 0);
    assert.equal((await operation(f, bob, bc, 'read', [`bob_read:primary:${'ab'.repeat(32)}`])).result.read, 0);
    assert.equal((await operation(f, bob, bc, 'read', ['bad'])).response.status, 400);
    // Sender still cannot see another account's delivery list.
    assert.deepEqual((await operation(f, carol, cc, 'status', [ref])).result[ref], []);
  } finally { await f.close(); }

  const f2 = await fixture({ dataDir, storageSecret });
  try {
    const ac2 = await f2.login('synthetic-alice');
    const device = (await operation(f2, alice, ac2, 'status', [ref])).result[ref][0];
    assert.equal(typeof device.readAt, 'number');
  } finally { await f2.close(); }
});
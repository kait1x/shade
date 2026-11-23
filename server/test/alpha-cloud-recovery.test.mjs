
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fixture, operation } from './helpers/alpha-fixture.mjs';
import * as c from '../../client/web/device_crypto.mjs';

async function identity(account, phrase) {
  const devicePhrase = 'synthetic browser vault passphrase';
  const vault = await c.createVault(account, devicePhrase);
  const session = await c.unlockVault(vault, devicePhrase);
  await assert.rejects(c.createRecoveryBackup(account, vault.signingKey, phrase.slice(0, -1)),
    /independent recovery password/);
  const pending = await c.createRecoveryBackup(account, vault.signingKey, phrase);
  const genesis = await c.createGenesis(vault, session, pending.publicKey);
  const backup = await c.finalizeRecoveryBackup(pending, phrase, genesis);
  const manifest = await c.approveDevices(genesis, [], [c.descriptor(vault)], session);
  const proofs = [await c.pairingProof(vault, session)];
  return { session, genesis, backup, registration: { genesis, manifest, proofs } };
}

test('cloud recovery is durable, account-scoped, and requires a device signature for backfill', async t => {
  const dataDir = await fs.mkdtemp(path.join(tmpdir(), 'shade-cloud-'));
  const options = { dataDir, storageSecret: randomBytes(32).toString('hex') };
  let f = await fixture(options);
  t.after(async () => {
    try { await f?.close(); } finally { await fs.rm(dataDir, { recursive: true, force: true }); }
  });
  const phrase = 'CobaltMaples';
  const alice = await identity('cloud_alice', phrase);
  const bob = await identity('cloud_bob', phrase);
  const a = await f.login('synthetic-cloud-alice');
  const b = await f.login('synthetic-cloud-bob');
  const endpoint = '/api/v2/recovery-backup';

  assert.equal((await f.request(endpoint)).response.status, 401);
  assert.equal((await f.request(endpoint, undefined, a)).response.status, 403);
  assert.equal((await f.request('/api/v2/register', {
    ...alice.registration, recoveryBackup: { ...alice.backup, phrase },
  }, a)).response.status, 400);
  assert.equal((await f.request('/api/v2/register', {
    ...alice.registration, recoveryBackup: alice.backup,
  }, a)).response.status, 200);
  assert.equal((await f.request('/api/v2/register', bob.registration, b)).response.status, 200);
  assert.deepEqual((await f.request(endpoint + '?account=cloud_alice', undefined, b)).result, { package: null });
  const downloaded = await f.request(endpoint, undefined, a);
  assert.equal(downloaded.response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(downloaded.result.package, { backup: alice.backup, genesis: alice.genesis });
  assert.equal((await c.unlockRecoveryBackup(downloaded.result.package.backup, phrase,
    downloaded.result.package.genesis)).signing.extractable, false);
  assert.equal((await f.request('/api/v2/operation', {
    op: 'recovery.backup', body: bob.backup,
  }, b)).response.status, 400);
  assert.equal((await operation(f, bob, b, 'recovery.backup', alice.backup)).response.status, 400);
  assert.equal((await operation(f, bob, b, 'recovery.backup', bob.backup)).response.status, 200);
  assert.equal((await operation(f, bob, b, 'recovery.backup', bob.backup)).response.status, 200);
  await f.close();
  f = null;
  f = await fixture(options);
  const next = await f.login('synthetic-cloud-bob');
  assert.deepEqual((await f.request(endpoint, undefined, next)).result.package,
    { backup: bob.backup, genesis: bob.genesis });
});

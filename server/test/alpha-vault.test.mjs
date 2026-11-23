import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { alphaStore } from '../multidevice/alpha-store.mjs';
import { createVault, unlockVault, createRecoveryBackup, finalizeRecoveryBackup, unlockRecoveryBackup,
  createGenesis, rebindPendingBackup } from '../../client/web/device_crypto.mjs';

test('pending registration renewal retains device/recovery RSA and binds the downloaded package to the fresh genesis', async () => {
  const phrase = 'synthetic pending device phrase';
  const recoveryPhrase = 'synthetic independent offline recovery phrase';
  const vault = await createVault('pending_user',phrase), session = await unlockVault(vault,phrase);
  let backup = await createRecoveryBackup(vault.account,vault.signingKey,recoveryPhrase);
  const before = await createGenesis(vault,session,backup.publicKey,Date.now()-600000);
  backup = await finalizeRecoveryBackup(backup,recoveryPhrase,before);
  const after = await createGenesis(vault,session,backup.publicKey);
  await assert.rejects(rebindPendingBackup(backup,'wrong password',before,after));
  const rebound = await rebindPendingBackup(backup,recoveryPhrase,before,after);
  assert.deepEqual(before.firstDevice,after.firstDevice);
  assert.equal(rebound.publicKey,backup.publicKey);
  assert.notEqual(rebound.genesisDigest,backup.genesisDigest);
  assert.equal((await unlockRecoveryBackup(rebound,recoveryPhrase,after)).signing.extractable,false);
  await assert.rejects(unlockRecoveryBackup(backup,recoveryPhrase,after));
});

test('alpha store fails closed on concurrent writer, wrong secret and a legacy directory', async () => {
  await fs.mkdir(path.resolve('build'),{recursive:true});
  const directory = await fs.mkdtemp(path.resolve('build/alpha-store-'));
  const secret = randomBytes(32).toString('hex');
  const store = await alphaStore(directory,secret);
  try {
    await store.save({synthetic:'private metadata'});
    await assert.rejects(alphaStore(directory,secret),/EEXIST/);
    assert.deepEqual(await store.load(),{synthetic:'private metadata'});
    assert.ok(!(await fs.readFile(path.join(directory,'device-v2.enc'),'utf8')).includes('private metadata'));
  } finally { await store.close(); }
  const wrong = await alphaStore(directory,randomBytes(32).toString('hex'));
  try { await assert.rejects(wrong.load()); } finally { await wrong.close(); }
  const legacy = await fs.mkdtemp(path.resolve('build/alpha-legacy-denied-'));
  await fs.writeFile(path.join(legacy,'users.json'),'synthetic legacy sentinel');
  await assert.rejects(alphaStore(legacy,secret),/legacy\/production/);
});


test('rolling checkpoint retains the previous atomic snapshot', async () => {
  await fs.mkdir('build', { recursive: true });
  const root = await fs.mkdtemp(path.join(process.cwd(), 'build', 'alpha-checkpoint-'));
  const dir = path.join(root, 'state');
  const checkpoints = path.join(root, 'checkpoints');
  const store = await alphaStore(dir, 'synthetic local checkpoint retention secret', { checkpointDir: checkpoints });
  try {
    await store.save({ generation: 1 });
    const [first] = await fs.readdir(checkpoints);
    const savedPath = path.join(checkpoints, first);
    const currentPath = path.join(dir, 'device-v2.enc');
    assert.equal((await fs.stat(savedPath)).ino, (await fs.stat(currentPath)).ino);
    const oldBytes = await fs.readFile(savedPath);
    await store.save({ generation: 2 });
    assert.deepEqual(await store.load(), { generation: 2 });
    assert.deepEqual(await fs.readFile(savedPath), oldBytes);
    assert.notDeepEqual(await fs.readFile(currentPath), oldBytes);
  } finally {
    await store.close();
    await fs.rm(root, { recursive: true, force: true });
  }
});

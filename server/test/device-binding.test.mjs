// WebAuthn PRF device binding: an OPTIONAL unlock factor over an unchanged
// vault format. The cryptographic scheme (PBKDF2 600k / AES-GCM / identity AAD)
// is never altered — the PRF output merely supplies the existing passphrase
// input. These tests pin: PRF-shaped passphrases, binding metadata compat,
// pre-binding vault compatibility and recovery-package independence from the
// device binding (lost passkey/iCloud/device never affects the recovery key).
import 'fake-indexeddb/auto';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createVault, unlockVault, saveVault, loadVault, listVaults,
  createRecoveryBackup, finalizeRecoveryBackup, unlockRecoveryBackup, createGenesis } from '../../client/web/device_crypto.mjs';
import { generateRecoveryPhrase } from '../../client/web/device_binding.mjs';

const PRF_SHAPE = /^[A-Za-z0-9_-]{43}$/; // base64url of 32 PRF bytes, as device_binding.mjs derives
const prfStylePassphrase = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Buffer.from(bytes).toString('base64url');
};
const LEGACY_FIELDS = 'account,ciphertext,encryptionKey,id,iv,salt,signingKey,version';

test('PRF-shaped passphrase encrypts/decrypts a vault through the unchanged scheme', async () => {
  const passphrase = prfStylePassphrase();
  assert.match(passphrase, PRF_SHAPE);
  const vault = await createVault('prf_style', passphrase);
  assert.equal(vault.version, 2);
  const session = await unlockVault(vault, passphrase);
  assert.equal(session.account, 'prf_style');
  // A wrong passphrase must never decrypt: WebCrypto surfaces OperationError.
  await assert.rejects(() => unlockVault(vault, prfStylePassphrase()),
    error => error.name === 'OperationError' || /identity|Invalid|vault/i.test(error.message));
});

test('binding metadata rides on the vault record without touching the ciphertext', async () => {
  const passphrase = prfStylePassphrase();
  const vault = await createVault('bound_user', passphrase);
  const ciphertext = vault.ciphertext;
  vault.binding = { method: 'prf', credentialId: 'cIdB64==', salt: 's4ltB64==' };
  await saveVault(vault);
  const stored = await loadVault(vault.id);
  assert.equal(stored.binding.method, 'prf');
  assert.equal(stored.ciphertext, ciphertext); // metadata only, never re-encrypted
  const session = await unlockVault(stored, passphrase); // extra field tolerated
  assert.equal(session.account, 'bound_user');
  const all = await listVaults();
  assert.ok(all.some(v => v.id === vault.id && v.binding?.method === 'prf')); // unlock-method detection
});

test('pre-binding vault record set is still accepted and unlockable', async () => {
  const passphrase = 'legacy browser device passphrase';
  const vault = await createVault('legacy_user', passphrase);
  delete vault.binding; // exact legacy field set, as saved by earlier releases
  assert.equal(Object.keys(vault).sort().join(','), LEGACY_FIELDS);
  await saveVault(vault);
  const session = await unlockVault(await loadVault(vault.id), passphrase);
  assert.equal(session.account, 'legacy_user');
});

test('auto recovery phrase is word-based, long enough and independent of the device binding', async () => {
  const passphrase = prfStylePassphrase();
  const vault = await createVault('recovery_user', passphrase);
  const session = await unlockVault(vault, passphrase);
  const phrase = generateRecoveryPhrase();
  assert.equal(phrase.split(' ').length, 8);
  assert.ok(phrase.length >= 24);
  assert.notEqual(phrase, generateRecoveryPhrase());
  const backup = await createRecoveryBackup('recovery_user', vault.signingKey, phrase);
  const genesis = await createGenesis(vault, session, backup.publicKey);
  const finalized = await finalizeRecoveryBackup(backup, phrase, genesis);
  const recovered = await unlockRecoveryBackup(finalized, phrase, genesis);
  assert.equal(recovered.account, 'recovery_user');
  // Factor independence: the PRF passphrase must NOT open the recovery package.
  await assert.rejects(() => unlockRecoveryBackup(finalized, passphrase, genesis),
    error => error.name === 'OperationError' || /identity|Invalid|Recovery/i.test(error.message));
});

test('lost passkey: recovery package restores identity on a new device without the vault', async () => {
  const passphrase = prfStylePassphrase(); // exists only inside the lost authenticator
  const vault = await createVault('lost_passkey', passphrase);
  const session = await unlockVault(vault, passphrase);
  const phrase = generateRecoveryPhrase();
  const backup = await createRecoveryBackup('lost_passkey', vault.signingKey, phrase);
  const genesis = await createGenesis(vault, session, backup.publicKey);
  const finalized = await finalizeRecoveryBackup(backup, phrase, genesis);
  // The offline package file, exactly as downloadBackup() writes it.
  const packageJson = JSON.parse(JSON.stringify({ backup: finalized, genesis }));
  // The original vault is unreachable without the passkey (simulated loss):
  await assert.rejects(() => unlockVault(vault, 'wrong guess phrase here!!'),
    error => error.name === 'OperationError');
  // A new device rebuilds the recovery signing key from the package + phrase.
  const recovered = await unlockRecoveryBackup(packageJson.backup, phrase, packageJson.genesis);
  assert.equal(recovered.id, 'recovery');
  assert.equal(recovered.account, 'lost_passkey');
  // The recovery key is independent of the (unreachable) device keys.
  assert.notEqual(recovered.signing.algorithm.modulusLength, undefined);
  const { sign, verify } = await import('../../client/web/protocol/device-v2.mjs');
  const probe = 'recovery probe';
  assert.ok(await verify(probe, await sign(probe, recovered.signing), finalized.publicKey));
});

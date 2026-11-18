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
import { generateRecoveryPhrase, createDeviceBinding, unlockDeviceBinding,
  bindingErrorText } from '../../client/web/device_binding.mjs';

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

// ---- WebAuthn mock harness -------------------------------------------------
// Emulates a PRF-capable platform authenticator strictly enough to pin the
// wire format: the eval input MUST carry `first` (AuthenticationExtensions
// PRFValues), a bare BufferSource makes Chromium reject the call with
// "Required member is undefined" before any authenticator round-trip.
const CHROMIUM_MISSING_FIRST =
  "Failed to execute 'get' on 'CredentialsContainer': Failed to read the 'first' property from 'AuthenticationExtensionsPRFValues': Required member is undefined";

function installWebAuthnMock({ mode } = {}) {
  const calls = { create: [], get: [] };
  let credentialId = null;
  const mock = {
    credentials: {
      async create(options) {
        calls.create.push(options);
        credentialId = crypto.getRandomValues(new Uint8Array(32)).buffer;
        return { rawId: credentialId };
      },
      async get(options) {
        calls.get.push(options);
        if (mode === 'browser-typeerror') throw new TypeError(CHROMIUM_MISSING_FIRST);
        const first = options.publicKey.extensions?.prf?.eval?.first;
        if (!(first instanceof ArrayBuffer || first instanceof Uint8Array) || first.byteLength === 0) {
          throw new TypeError(CHROMIUM_MISSING_FIRST);
        }
        if (mode === 'empty-results') return { getClientExtensionResults: () => ({ prf: {} }) };
        if (mode === 'missing-first-result') {
          return { getClientExtensionResults: () => ({ prf: { results: {} } }) };
        }
        const output = await crypto.subtle.digest('SHA-256',
          new Uint8Array([...new Uint8Array(first), ...new Uint8Array(credentialId)]));
        return { getClientExtensionResults: () => ({ prf: { results: { first: output } } }) };
      },
    },
  };
  const previous = { navigator: Object.getOwnPropertyDescriptor(globalThis, 'navigator'),
    location: Object.getOwnPropertyDescriptor(globalThis, 'location') };
  Object.defineProperty(globalThis, 'navigator', { value: mock, configurable: true });
  Object.defineProperty(globalThis, 'location', { value: { hostname: 'localhost' }, configurable: true });
  return {
    calls,
    restore() {
      if (previous.navigator) Object.defineProperty(globalThis, 'navigator', previous.navigator);
      else delete globalThis.navigator;
      if (previous.location) Object.defineProperty(globalThis, 'location', previous.location);
      else delete globalThis.location;
    },
  };
}

test('spec-format PRF eval: setup uses {first: salt} and re-unlock derives the identical passphrase', async () => {
  const mock = installWebAuthnMock();
  try {
    const { binding, passphrase } = await createDeviceBinding('prf_flow_user');
    assert.equal(binding.method, 'prf');
    assert.match(passphrase, PRF_SHAPE);
    // The registration evaluation carried the salt as the `first` member...
    const setupFirst = mock.calls.get[0].publicKey.extensions.prf.eval.first;
    assert.ok(setupFirst.byteLength === 16, 'eval.first is the 16-byte salt');
    assert.equal(Buffer.from(setupFirst).toString('base64'), binding.salt); // b64() keeps standard padding
    // ...and "closing the app + unlocking again" re-evaluates the SAME bytes.
    const unlockPassphrase = await unlockDeviceBinding(binding);
    assert.equal(mock.calls.get.length, 2);
    const unlockFirst = mock.calls.get[1].publicKey.extensions.prf.eval.first;
    assert.deepEqual(Buffer.from(unlockFirst), Buffer.from(setupFirst));
    assert.equal(unlockPassphrase, passphrase); // deterministic re-derivation
    assert.equal(mock.calls.get[1].publicKey.rpId, 'localhost');
  } finally { mock.restore(); }
});

test('regression: Chromium missing-first TypeError maps to honest prf_unavailable, never the raw error', async () => {
  const mock = installWebAuthnMock({ mode: 'browser-typeerror' });
  try {
    await assert.rejects(() => createDeviceBinding('prf_regression'),
      error => error.message === 'prf_unavailable');
    const mapped = bindingErrorText({ message: 'prf_unavailable' });
    assert.ok(mapped && mapped.includes('PRF'));
    assert.ok(!mapped.includes('Failed to execute'));
  } finally { mock.restore(); }
});

test('authenticators without PRF results surface the phrase fallback, not a crash', async () => {
  for (const mode of ['empty-results', 'missing-first-result']) {
    const mock = installWebAuthnMock({ mode });
    try {
      await assert.rejects(() => createDeviceBinding('prf_no_results'),
        error => error.message === 'prf_unavailable');
    } finally { mock.restore(); }
  }
});

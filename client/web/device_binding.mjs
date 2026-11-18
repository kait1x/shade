import { b64, unb64, check } from './protocol/device-v2.mjs';
import { RECOVERY_WORDS } from './recovery-words.mjs';

// Device binding replaces the invented device passphrase with a secret bound
// to this device's platform authenticator (WebAuthn PRF extension, Safari 18+,
// Chrome 118+). Security model is unchanged: the vault ciphertext format and
// its PBKDF2/AES-GCM guarantees stay exactly the same — the PRF output merely
// becomes the passphrase input, so passphrase vaults keep unlocking forever.
// The PRF secret itself never leaves the authenticator and is never persisted;
// only the non-secret credential id and evaluation salt are stored as metadata.

const toB64Url = bytes => b64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

export async function platformAuthenticatorAvailable() {
  try {
    if (typeof window.PublicKeyCredential === 'undefined' || !window.isSecureContext) return false;
    if (PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable) {
      return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    }
    return false;
  } catch { return false; }
}

// Deterministic passphrase for (credential, salt): one PRF evaluation at
// registration and the identical evaluation at every unlock. userVerification
// stays required, so the biometric/device-passcode gate is part of the secret.
async function prfPassphrase(credentialId, salt) {
  const assertion = await navigator.credentials.get({ publicKey: {
    challenge: crypto.getRandomValues(new Uint8Array(32)),
    rpId: location.hostname,
    allowCredentials: [{ id: credentialId, type: 'public-key' }],
    userVerification: 'required', timeout: 60000,
    extensions: { prf: { eval: salt } },
  } });
  const first = assertion.getClientExtensionResults()?.prf?.results?.first;
  if (!(first instanceof ArrayBuffer) || first.byteLength < 32) throw Error('prf_unavailable');
  return toB64Url(new Uint8Array(first));
}

// Creates a discoverable platform passkey for the Shade origin, then derives
// the vault passphrase from its PRF output. Two authenticator prompts is the
// standard PRF onboarding (create, then evaluate); both are user-gesture driven.
export async function createDeviceBinding(account) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const credential = await navigator.credentials.create({ publicKey: {
    challenge: crypto.getRandomValues(new Uint8Array(32)),
    rp: { id: location.hostname, name: 'Shade' },
    user: { id: crypto.getRandomValues(new Uint8Array(16)), name: account, displayName: account },
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
    authenticatorSelection: { authenticatorAttachment: 'platform',
      residentKey: 'required', userVerification: 'required' },
    timeout: 60000,
    extensions: { prf: {} },
  } });
  const passphrase = await prfPassphrase(credential.rawId, salt);
  return { binding: { method: 'prf', credentialId: b64(new Uint8Array(credential.rawId)), salt: b64(salt) }, passphrase };
}

export async function unlockDeviceBinding(binding) {
  check(binding?.method === 'prf' && typeof binding.credentialId === 'string' &&
    typeof binding.salt === 'string' && Object.keys(binding).sort().join(',') === 'credentialId,method,salt',
    'Некорректная привязка устройства');
  return prfPassphrase(unb64(binding.credentialId, 4096), unb64(binding.salt, 32));
}

// User-facing text for the handful of WebAuthn failure modes; everything else
// surfaces verbatim. The phrase fallback remains available after any failure.
export function bindingErrorText(error) {
  if (error?.name === 'NotAllowedError') return 'Защита устройства не подтверждена. Попробуйте снова или используйте фразу устройства.';
  if (error?.name === 'InvalidStateError') return 'Ключ защиты для этого аккаунта уже существует на устройстве.';
  if (error?.name === 'SecurityError') return 'Защита устройства недоступна для этого происхождения. Используйте фразу устройства.';
  if (error?.message === 'prf_unavailable') return 'Аутентификатор не поддерживает вывод ключа (PRF). Используйте фразу устройства.';
  return null;
}

// Offline recovery phrase: 8 EFF-large words (~103 bits), generated locally.
// The user never invents it — the screen shows it once for writing down.
export function generateRecoveryPhrase() {
  const limit = Math.floor(0x100000000 / RECOVERY_WORDS.length) * RECOVERY_WORDS.length;
  const buffer = crypto.getRandomValues(new Uint32Array(16));
  let index = 0;
  const words = [];
  while (words.length < 8) {
    if (index >= buffer.length) { crypto.getRandomValues(buffer); index = 0; }
    const value = buffer[index++];
    if (value < limit) words.push(RECOVERY_WORDS[value % RECOVERY_WORDS.length]);
  }
  return words.join(' ');
}

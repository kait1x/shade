import { b64, unb64, check, deviceId, publicKey, textBytes, sign, hash,
  manifestText, messageText, verifyMessage, verifyHistory, genesisText, fingerprint, pairingText } from './protocol/device-v2.mjs';

const RSA = { modulusLength: 4096, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' };
const ITERATIONS = 600000;
const random = n => crypto.getRandomValues(new Uint8Array(n));
const decode = bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes);

async function wrappingKey(passphrase, salt) {
  const password = textBytes(passphrase);
  try {
    const base = await crypto.subtle.importKey('raw', password, 'PBKDF2', false, ['deriveKey']);
    return await crypto.subtle.deriveKey({ name: 'PBKDF2', hash: 'SHA-256',
      iterations: ITERATIONS, salt }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  } finally { password.fill(0); }
}
function vaultAAD(vault) {
  return textBytes(JSON.stringify(['shade-vault:v2', vault.account, vault.id,
    vault.encryptionKey, vault.signingKey, ITERATIONS]));
}
async function importPrivate(bytes, name, usage) {
  const key = await crypto.subtle.importKey('pkcs8', bytes, { name, hash: 'SHA-256' }, false, [usage]);
  check(key.algorithm.modulusLength === 4096, 'Unsupported vault key');
  return key;
}
// A strong, user-supplied passphrase is required. Neither it nor unwrapped
// PKCS8 bytes are persisted. Unlocked keys are non-extractable and memory-only.
export async function createVault(account, passphrase) {
  check(/^[a-z0-9_]{3,32}$/.test(account));
  check(typeof passphrase === 'string' && passphrase.length >= 16, 'Use a strong passphrase of at least 16 characters');
  const encryption = await crypto.subtle.generateKey({ name: 'RSA-OAEP', ...RSA }, true, ['encrypt', 'decrypt']);
  const signing = await crypto.subtle.generateKey({ name: 'RSA-PSS', ...RSA }, true, ['sign', 'verify']);
  const encryptionKey = b64(await crypto.subtle.exportKey('spki', encryption.publicKey));
  const signingKey = b64(await crypto.subtle.exportKey('spki', signing.publicKey));
  const salt = random(16), iv = random(12);
  const vault = { version: 2, account, id: await deviceId(encryptionKey, signingKey),
    encryptionKey, signingKey, salt: b64(salt), iv: b64(iv), ciphertext: '' };
  const encBytes = new Uint8Array(await crypto.subtle.exportKey('pkcs8', encryption.privateKey));
  const sigBytes = new Uint8Array(await crypto.subtle.exportKey('pkcs8', signing.privateKey));
  const plaintext = textBytes(JSON.stringify([b64(encBytes), b64(sigBytes)]));
  try {
    vault.ciphertext = b64(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
      additionalData: vaultAAD(vault) }, await wrappingKey(passphrase, salt), plaintext));
    return vault;
  } finally { encBytes.fill(0); sigBytes.fill(0); plaintext.fill(0); }
}
export async function unlockVault(vault, passphrase) {
  check(vault?.version === 2 && /^[a-z0-9_]{3,32}$/.test(vault.account));
  check(vault.id === await deviceId(vault.encryptionKey, vault.signingKey), 'Vault identity mismatch');
  const salt = unb64(vault.salt, 32), iv = unb64(vault.iv, 24);
  check(salt.length === 16 && iv.length === 12);
  const key = await wrappingKey(passphrase, salt);
  let plaintext;
  const privateBytes = [];
  try {
    plaintext = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv,
      additionalData: vaultAAD(vault) }, key, unb64(vault.ciphertext, 20000)));
    const parts = JSON.parse(decode(plaintext));
    check(Array.isArray(parts) && parts.length === 2);
    privateBytes.push(...parts.map(p => unb64(p, 8000)));
    const encryption = await importPrivate(privateBytes[0], 'RSA-OAEP', 'decrypt');
    const signing = await importPrivate(privateBytes[1], 'RSA-PSS', 'sign');
    // Validate private/public association without exporting the unlocked keys.
    const probe = b64(random(32));
    const challenge = await crypto.subtle.encrypt({ name: 'RSA-OAEP' },
      await publicKey(vault.encryptionKey, 'RSA-OAEP', 'encrypt'), textBytes(probe));
    check(decode(await crypto.subtle.decrypt({ name: 'RSA-OAEP' }, encryption, challenge)) === probe);
    const { verify } = await import('./protocol/device-v2.mjs');
    check(await verify(probe, await sign(probe, signing), vault.signingKey));
    return { encryption, signing, storage: key, id: vault.id, account: vault.account };
  } finally {
    plaintext?.fill(0); privateBytes.forEach(bytes => bytes.fill(0));
  }
}
export function descriptor(vault) {
  return { id: vault.id, encryptionKey: vault.encryptionKey, signingKey: vault.signingKey };
}
export async function createRecoveryBackup(account, anchor, passphrase) {
  check(typeof passphrase === 'string' && passphrase.length >= 24, 'Use a strong independent recovery passphrase (24+ characters)');
  check(/^[a-z0-9_]{3,32}$/.test(account));
  const pair = await crypto.subtle.generateKey({ name: 'RSA-PSS', ...RSA }, true, ['sign', 'verify']);
  const publicKey = b64(await crypto.subtle.exportKey('spki', pair.publicKey));
  const salt = random(16), iv = random(12), rootFingerprint = await fingerprint(anchor);
  const aad = textBytes(JSON.stringify(['shade-recovery:v2', account, rootFingerprint, publicKey]));
  const bytes = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  try {
    return { version: 2, account, rootFingerprint, publicKey, salt: b64(salt), iv: b64(iv),
      ciphertext: b64(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad },
        await wrappingKey(passphrase, salt), bytes)) };
  } finally { bytes.fill(0); }
}
export async function unlockRecoveryBackup(backup, passphrase, genesis) {
  check(backup?.version === 2 && backup.account === genesis.account && backup.publicKey === genesis.recoveryKey &&
    backup.rootFingerprint === await fingerprint(genesis.firstDevice.signingKey), 'Recovery identity mismatch');
  check(backup.genesisDigest === await hash(genesisText(genesis)), 'Recovery backup must pin the exact account genesis');
  const salt = unb64(backup.salt, 32), iv = unb64(backup.iv, 24);
  check(salt.length === 16 && iv.length === 12);
  const aad = textBytes(JSON.stringify(['shade-recovery:v2', backup.account, backup.rootFingerprint, backup.publicKey, backup.genesisDigest]));
  const bytes = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv, additionalData: aad },
    await wrappingKey(passphrase, salt), unb64(backup.ciphertext, 8000)));
  try {
    const key = await importPrivate(bytes, 'RSA-PSS', 'sign');
    const { verify } = await import('./protocol/device-v2.mjs');
    const probe = b64(random(32)); check(await verify(probe, await sign(probe, key), backup.publicKey));
    return { account: backup.account, id: 'recovery', signing: key };
  } finally { bytes.fill(0); }
}
// Finalize + save this package offline before registration. The backup contains
// only the independent recovery key, never a device's private identity key.
export async function finalizeRecoveryBackup(backup, passphrase, genesis) {
  const { verifyGenesis } = await import('./protocol/device-v2.mjs');
  await verifyGenesis(genesis, genesis.firstDevice.signingKey);
  check(!backup.genesisDigest && backup.account === genesis.account && backup.publicKey === genesis.recoveryKey &&
    backup.rootFingerprint === await fingerprint(genesis.firstDevice.signingKey), 'Wrong recovery package');
  const salt = unb64(backup.salt, 32);
  const key = await wrappingKey(passphrase, salt);
  const oldAAD = textBytes(JSON.stringify(['shade-recovery:v2', backup.account, backup.rootFingerprint, backup.publicKey]));
  const bytes = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(backup.iv, 24), additionalData: oldAAD },
    key, unb64(backup.ciphertext, 8000)));
  const genesisDigest = await hash(genesisText(genesis)), iv = random(12);
  const aad = textBytes(JSON.stringify(['shade-recovery:v2', backup.account, backup.rootFingerprint, backup.publicKey, genesisDigest]));
  try {
    return { ...backup, genesisDigest, iv: b64(iv),
      ciphertext: b64(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad }, key, bytes)) };
  } finally { bytes.fill(0); }
}
// Only for a locally pending registration, before an account exists remotely.
// Rebinds the SAME recovery key when the freshness window has elapsed.
export async function rebindPendingBackup(backup, passphrase, previous, genesis) {
  await unlockRecoveryBackup(backup, passphrase, previous);
  const { verifyGenesis } = await import('./protocol/device-v2.mjs');
  await verifyGenesis(genesis, genesis.firstDevice.signingKey);
  check(genesis.account === previous.account && genesis.recoveryKey === previous.recoveryKey &&
    JSON.stringify(genesis.firstDevice) === JSON.stringify(previous.firstDevice), 'Pending keys changed');
  const key = await wrappingKey(passphrase, unb64(backup.salt, 32));
  const aad = digest => textBytes(JSON.stringify(['shade-recovery:v2', backup.account,
    backup.rootFingerprint, backup.publicKey, digest]));
  const bytes = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(backup.iv,24),
    additionalData: aad(backup.genesisDigest) }, key, unb64(backup.ciphertext,8000)));
  const genesisDigest = await hash(genesisText(genesis)), iv = random(12);
  try {
    return { ...backup, genesisDigest, iv:b64(iv), ciphertext:b64(await crypto.subtle.encrypt({name:'AES-GCM',iv,
      additionalData:aad(genesisDigest)},key,bytes)) };
  } finally { bytes.fill(0); }
}
export async function createGenesis(vault, session, recoveryKey, now = Date.now()) {
  check(vault.account === session.account && vault.id === session.id);
  const g = { version: 2, account: vault.account, nonce: Array.from(random(32), b => b.toString(16).padStart(2, '0')).join(''),
    createdAt: now, legacy: false, firstDevice: descriptor(vault), recoveryKey, signature: '' };
  g.signature = await sign(genesisText(g), session.signing);
  return g;
}
// The UI must confirm the exact descriptor fingerprints via QR before calling
// this method. Server/Google identity alone must never trigger an approval.
export async function approveDevices(genesis, history, devices, session, checkpoint, now = Date.now()) {
  const root = genesis.firstDevice.signingKey;
  if (history.length) await verifyHistory(history, root, checkpoint, history.at(-1).issuedAt, genesis);
  const previous = history.at(-1);
  const m = { account: genesis.account, rootFingerprint: await fingerprint(root),
    revision: (previous?.revision || 0) + 1, previous: previous ? await hash(manifestText(previous)) : '',
    issuedAt: now, expiresAt: now + 86400000, signer: session.id,
    devices: [...devices].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0), signature: '' };
  check(session.account === genesis.account, 'Wrong approving account');
  m.signature = await sign(manifestText(m), session.signing);
  await verifyHistory([...history, m], root, null, now, genesis);
  return m;
}
export async function pairingProof(vault, session, now = Date.now()) {
  check(vault.account === session.account && vault.id === session.id);
  const nonce = Array.from(random(32), b => b.toString(16).padStart(2, '0')).join('');
  const expiresAt = now + 60000;
  return { id: session.id, nonce, expiresAt,
    signature: await sign(pairingText(vault.account, descriptor(vault), nonce, expiresAt), session.signing) };
}
// Ciphertext compatible with CryptoService RSA-4096 OAEP-SHA256/AES-GCM v2.
export async function encryptLegacy(text, recipientSPKI) {
  const bytes = textBytes(text); check(bytes.length <= 65536, 'Text too large');
  const raw = random(32), nonce = random(12);
  const envelope = new Uint8Array(45); envelope[0] = 2;
  envelope.set(raw, 1); envelope.set(nonce, 33);
  try {
    const aes = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt']);
    return { k: b64(await crypto.subtle.encrypt({ name: 'RSA-OAEP' },
      await publicKey(recipientSPKI, 'RSA-OAEP', 'encrypt'), textBytes(b64(envelope)))),
    d: b64(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, bytes)) };
  } finally { raw.fill(0); envelope.fill(0); bytes.fill(0); }
}
export async function decryptLegacy(payload, encryptionKey) {
  const envelope = unb64(decode(await crypto.subtle.decrypt({ name: 'RSA-OAEP' },
    encryptionKey, unb64(payload.k, 1024))), 128);
  check(envelope.length === 45 && envelope[0] === 2, 'Invalid encryption envelope');
  try {
    const aes = await crypto.subtle.importKey('raw', envelope.slice(1, 33), 'AES-GCM', false, ['decrypt']);
    return decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: envelope.slice(33) }, aes, unb64(payload.d, 100000)));
  } finally { envelope.fill(0); }
}
// Roots MUST be pinned independently of the untrusted relay, e.g. QR on Android.
// Returned checkpoints must be stored encrypted/atomically by a future adapter.
export async function sealMessage(text, senderHistory, recipientHistory, session, trust, now = Date.now()) {
  check(trust.senderGenesis && trust.recipientGenesis, 'Pinned account genesis required');
  await verifyHistory(senderHistory, trust.senderRoot, trust.senderCheckpoint, now, trust.senderGenesis);
  await verifyHistory(recipientHistory, trust.recipientRoot, trust.recipientCheckpoint, now, trust.recipientGenesis);
  const sender = senderHistory.at(-1), recipient = recipientHistory.at(-1);
  check(sender.account === session.account && sender.devices.some(d => d.id === session.id));
  const envelopes = [];
  for (const roster of [sender, recipient]) {
    for (const d of roster.devices) envelopes.push({ account: roster.account, deviceId: d.id, payload: await encryptLegacy(text, d.encryptionKey) });
  }
  envelopes.sort((a, b) => `${a.account}:${a.deviceId}` < `${b.account}:${b.deviceId}` ? -1 : 1);
  const m = { version: 2, id: Array.from(random(32), b => b.toString(16).padStart(2, '0')).join(''),
    from: sender.account, deviceId: session.id, to: recipient.account,
    fromRevision: sender.revision, toRevision: recipient.revision,
    fromDigest: await hash(manifestText(sender)), toDigest: await hash(manifestText(recipient)),
    createdAt: now, envelopes, signature: '' };
  m.signature = await sign(messageText(m), session.signing);
  return m;
}
// Consumer must persist replay IDs and ciphertext atomically before ACK. No
// plaintext history is stored here. Old queued envelopes need verified history.
export async function openMessage(bundle, session, trust) {
  const { message: m, senderHistory, recipientHistory } = bundle;
  check(trust.senderGenesis && trust.recipientGenesis, 'Pinned account genesis required');
  await verifyHistory(senderHistory, trust.senderRoot, trust.senderCheckpoint, Date.now(), trust.senderGenesis);
  await verifyHistory(recipientHistory, trust.recipientRoot, trust.recipientCheckpoint, Date.now(), trust.recipientGenesis);
  check(m.to === session.account || m.from === session.account, 'Wrong recipient');
  check(senderHistory.at(-1).devices.some(d => d.id === m.deviceId), 'Sender device has been revoked');
  const ownHistory = session.account === m.from ? senderHistory : recipientHistory;
  check(ownHistory.at(-1).devices.some(d => d.id === session.id), 'Recipient device has been revoked');
  const sender = senderHistory[m.fromRevision - 1], recipient = recipientHistory[m.toRevision - 1];
  check(sender && recipient, 'Missing historical directory');
  check(sender.issuedAt <= m.createdAt && sender.expiresAt > m.createdAt &&
    recipient.issuedAt <= m.createdAt && recipient.expiresAt > m.createdAt, 'Message outside directory lease');
  await verifyMessage(m, sender, recipient);
  const e = m.envelopes.find(item => item.account === session.account && item.deviceId === session.id);
  check(e, 'Device is not a recipient');
  return decryptLegacy(e.payload, session.encryption);
}
export async function encryptRecord(session, recordId, value) {
  check(typeof recordId === 'string' && recordId.length > 0 && recordId.length < 200);
  const iv = random(12);
  const aad = textBytes(JSON.stringify(['shade-local:v2', session.account, session.id, recordId]));
  return { iv: b64(iv), ciphertext: b64(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
    additionalData: aad }, session.storage, textBytes(JSON.stringify(value)))) };
}
export async function decryptRecord(session, recordId, record) {
  const aad = textBytes(JSON.stringify(['shade-local:v2', session.account, session.id, recordId]));
  return JSON.parse(decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(record.iv, 24),
    additionalData: aad }, session.storage, unb64(record.ciphertext, 32 * 1024 * 1024))));
}

async function database() {
  check(typeof indexedDB !== 'undefined', 'IndexedDB unavailable; do not generate a replacement identity');
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('shade-device-v2', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('vaults', { keyPath: 'id' });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error('Encrypted browser storage unavailable'));
    request.onblocked = () => reject(new Error('Close other Shade tabs to open storage'));
  });
}
export async function saveVault(vault) {
  check(vault && Object.keys(vault).sort().join(',') === 'account,ciphertext,encryptionKey,id,iv,salt,signingKey,version', 'Unexpected vault fields');
  check(vault.version === 2 && typeof vault.account === 'string' && /^[a-z0-9_]{3,32}$/.test(vault.account) &&
    vault.id === await deviceId(vault.encryptionKey, vault.signingKey), 'Invalid vault identity');
  check(unb64(vault.salt, 32).length === 16 && unb64(vault.iv, 24).length === 12 &&
    unb64(vault.ciphertext, 20000).length >= 16, 'Invalid encrypted vault');
  const db = await database();
  try {
    await new Promise((resolve, reject) => {
      const tx = db.transaction('vaults', 'readwrite');
      tx.objectStore('vaults').add(vault); // Never overwrite or regenerate an existing identity.
      tx.oncomplete = resolve;
      tx.onabort = () => reject(new Error('Vault already exists or storage is unavailable'));
      tx.onerror = () => {}; // The transaction's abort is the authoritative result.
    });
  } finally { db.close(); }
}
export async function loadVault(id) {
  const db = await database();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction('vaults', 'readonly');
      const request = tx.objectStore('vaults').get(id);
      tx.oncomplete = () => resolve(request.result ?? null);
      tx.onabort = () => reject(new Error('Cannot read encrypted vault'));
    });
  } finally { db.close(); }
}
export async function listVaults() {
  const db = await database();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction('vaults', 'readonly');
      const request = tx.objectStore('vaults').getAll();
      tx.oncomplete = () => resolve(request.result);
      tx.onabort = () => reject(new Error('Cannot list encrypted vaults'));
    });
  } finally { db.close(); }
}

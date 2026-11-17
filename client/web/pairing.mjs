import { check, ACCOUNT, DEVICE, b64, unb64, deviceId, publicKey, fingerprint,
  pairingText, sign, verify, verifyGenesis } from './protocol/device-v2.mjs';

// Second-device pairing payloads. The transport between the two devices is an
// ordinary clipboard/text channel, so every block is self-contained, versioned
// and verified against cryptography instead of transport trust:
// - offer (new device -> trusted device): the exact pairing proof the server
//   later re-verifies in registry.update(), plus a challenge echo bound to a
//   fresh one-time code shown only on the trusted screen (anti-phishing).
// - confirmation (trusted device -> new device): a routing hint only. The
//   enrolling device never trusts clipboard chain data: after its device
//   session opens, it fetches the full directory itself and verifies it
//   against the pinned genesis.
const utf8 = new TextEncoder();
const OFFER_PREFIX = 'shade-pair-v1:';
const CONFIRM_PREFIX = 'shade-pair-confirm-v1:';
// Server accepts a pairing proof with expiresAt in (now, now + 300000].
// Four minutes leaves a realistic clipboard round trip.
export const OFFER_TTL_MS = 240000;
// One-time challenge code shown on the trusted device; the offer must echo it.
export const CHALLENGE_TTL_MS = 5 * 60000;
const CHALLENGE_BYTES = 15; // 120 bits -> exactly 24 Crockford base32 chars.
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // No I/L/O/U ambiguity.
const b64url = value => b64(utf8.encode(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
function fromB64url(value, prefix) {
  check(typeof value === 'string' && value.startsWith(prefix), 'Неверный формат кода подключения');
  const body = value.slice(prefix.length).replace(/-/g, '+').replace(/_/g, '/');
  const padded = body + '='.repeat((4 - body.length % 4) % 4);
  return new TextDecoder('utf-8', { fatal: true }).decode(unb64(padded, 64 * 1024));
}
const bytesToHex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');

// One-time challenge (trusted device): typed or copied to the new device.
// Memory-only on the trusted side; expires with the pairing dialog.
export function createPairingChallenge(now = Date.now()) {
  const bytes = crypto.getRandomValues(new Uint8Array(CHALLENGE_BYTES));
  let bits = 0, value = 0, chars = '';
  for (const byte of bytes) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { chars += ALPHABET[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  const code = (chars.match(/.{6}/g) || []).join('-');
  return { nonce: bytesToHex(bytes), expiresAt: now + CHALLENGE_TTL_MS, code };
}
export function decodeChallenge(text) {
  check(typeof text === 'string', 'Введите код подключения');
  const normalized = text.toUpperCase().replace(/[^0-9A-Z]/g, '')
    .replace(/I/g, '1').replace(/L/g, '1').replace(/O/g, '0');
  check(normalized.length === 24, 'Код подключения состоит из 24 символов');
  let bytes = [], bits = 0, value = 0;
  for (const char of normalized) {
    const index = ALPHABET.indexOf(char);
    check(index >= 0, 'В коде подключения недопустимый символ');
    value = (value << 5) | index; bits += 5;
    if (bits >= 8) { bytes.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  check(bytes.length === CHALLENGE_BYTES && bits < 8, 'Некорректный код подключения');
  return bytesToHex(bytes);
}
function offerFields(offer) {
  check(offer && typeof offer === 'object' && !Array.isArray(offer) &&
    Object.keys(offer).sort().join(',') === 'account,challenge,device,expiresAt,nonce,signature,v', 'Неверный формат запроса подключения');
  check(offer.v === 1 && typeof offer.account === 'string' && ACCOUNT.test(offer.account) &&
    typeof offer.challenge === 'string' && /^[a-f0-9]{30}$/.test(offer.challenge) &&
    typeof offer.nonce === 'string' && /^[a-f0-9]{64}$/.test(offer.nonce) &&
    Number.isSafeInteger(offer.expiresAt) && typeof offer.signature === 'string', 'Неверный формат запроса подключения');
  const d = offer.device;
  check(d && typeof d === 'object' && !Array.isArray(d) &&
    Object.keys(d).sort().join(',') === 'encryptionKey,id,signingKey' &&
    typeof d.id === 'string' && DEVICE.test(d.id) && d.id !== 'primary', 'Неверный дескриптор устройства');
  unb64(d.encryptionKey, 2048); unb64(d.signingKey, 2048); unb64(offer.signature, 1024);
  return offer;
}
function tipFields(tip) {
  check(tip && typeof tip === 'object' && !Array.isArray(tip) &&
    Object.keys(tip).sort().join(',') ===
    'account,devices,expiresAt,issuedAt,previous,revision,rootFingerprint,signature,signer', 'Неверный формат подтверждения');
  check(Array.isArray(tip.devices) && tip.devices.length >= 1 && tip.devices.length <= 8, 'Неверный ростер подтверждения');
  for (const d of tip.devices) {
    check(d && Object.keys(d).sort().join(',') === 'encryptionKey,id,signingKey' &&
      typeof d.id === 'string' && DEVICE.test(d.id), 'Неверный ростер подтверждения');
    unb64(d.encryptionKey, 2048); unb64(d.signingKey, 2048);
  }
  return tip;
}
// New device: build the signed offer. The device keys must already exist
// locally (durable vault); nothing is sent to the relay at this point.
// `signing` is the unlocked non-extractable signing CryptoKey of this device.
export async function buildPairingOffer({ account, device, signing, challenge, now = Date.now(), ttlMs = OFFER_TTL_MS }) {
  check(typeof account === 'string' && ACCOUNT.test(account), 'Некорректный аккаунт');
  check(typeof challenge === 'string' && /^[a-f0-9]{30}$/.test(challenge), 'Введите действующий код подключения');
  const nonce = bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
  const expiresAt = now + ttlMs;
  check(expiresAt <= now + 300000, 'Срок запроса подключения превышает допустимый');
  const offer = { v: 1, account, device, challenge, nonce, expiresAt, signature: '' };
  offer.signature = await sign(pairingText(account, device, nonce, expiresAt), signing);
  return offer;
}
export function encodeOffer(offer) { return OFFER_PREFIX + b64url(JSON.stringify(offerFields(offer))); }
export function decodeOffer(text) { return offerFields(JSON.parse(fromB64url(text, OFFER_PREFIX))); }
// Trusted device: full verification before showing the confirmation screen.
// Throws on every mismatch so the UI can surface the concrete reason.
export async function verifyPairingOffer(offer, { account, challenge, now = Date.now() }) {
  offerFields(offer);
  check(offer.account === account, 'Запрос привязан к другому аккаунту');
  check(offer.challenge === challenge, 'Код подключения не совпадает. Сгенерируйте новый на этом устройстве.');
  check(offer.expiresAt > now, 'Срок запроса истёк. Создайте запрос на новом устройстве заново.');
  check(offer.expiresAt <= now + 300000, 'Срок запроса превышает допустимый');
  const d = offer.device;
  check(d.id === await deviceId(d.encryptionKey, d.signingKey), 'Идентификатор устройства не совпадает с ключами');
  await publicKey(d.encryptionKey, 'RSA-OAEP', 'encrypt'); // Enforces RSA-4096, e=65537.
  await publicKey(d.signingKey, 'RSA-PSS', 'verify');
  check(await verify(pairingText(account, d, offer.nonce, offer.expiresAt), offer.signature, d.signingKey),
    'Подпись устройства недействительна');
  return d;
}
// Trusted device: the confirmation handed back to the new device. It carries
// the pinned genesis (self-authenticating) and the new roster tip as a hint;
// the enrolling device re-verifies everything from the server directory.
export function buildPairingConfirmation({ account, genesis, tip }) {
  tipFields(tip);
  check(typeof account === 'string' && ACCOUNT.test(account) && genesis &&
    genesis.account === account && typeof genesis.recoveryKey === 'string', 'Неверные данные аккаунта');
  return { v: 1, account, genesis, tip };
}
export function encodeConfirmation(confirmation) { return CONFIRM_PREFIX + b64url(JSON.stringify(confirmation)); }
export function decodeConfirmation(text) {
  const value = JSON.parse(fromB64url(text, CONFIRM_PREFIX));
  check(value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join(',') === 'account,genesis,tip,v' && value.v === 1, 'Неверный формат подтверждения');
  tipFields(value.tip);
  return value;
}
// New device: verify the confirmation's genesis and that the tip at least
// claims this device's membership. The authoritative chain verification runs
// in completePairing against the server directory AFTER the session opens.
export async function verifyPairingConfirmation(confirmation, { account, deviceId: ownId, now = Date.now() }) {
  check(confirmation.account === account, 'Подтверждение привязано к другому аккаунту');
  const genesis = confirmation.genesis;
  check(genesis && typeof genesis === 'object' && genesis.account === account, 'Неверный формат подтверждения');
  const root = genesis.firstDevice.signingKey;
  const genesisDigest = await verifyGenesis(genesis, root);
  const tip = confirmation.tip;
  check(tip.account === account && tip.rootFingerprint === await fingerprint(root),
    'Каталог подтверждения не совпадает с genesis');
  check(tip.expiresAt > now, 'Срок каталога подтверждения истёк. Запросите подтверждение заново.');
  check(tip.devices.some(d => d.id === ownId), 'Устройство отсутствует в подтверждённом ростере');
  return { genesis, tip, root, genesisDigest };
}

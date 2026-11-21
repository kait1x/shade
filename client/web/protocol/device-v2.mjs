// device-v2.mjs — протокол устройств Shade v2 (веб-клиент).
// Аккаунт = genesis + цепочка подписанных манифестов (директория устройств);
// у каждого устройства пара RSA-4096 ключей (шифрование/подпись), манифесты
// подписаны RSA-PSS и живут ограниченное время (lease). Корень доверия
// закрепляется отпечатком при первом контакте — подмена ключей выявляется.
// Local protocol candidate. Not wired to production auth or messaging.
const utf8 = new TextEncoder();
// Лимиты и форматы протокола: максимум устройств, срок аренды манифеста (24 ч),
// имя аккаунта и допустимые идентификаторы устройств ('primary' или хэш ключей).
export const MAX_DEVICES = 8;
export const MAX_LEASE_MS = 24 * 60 * 60 * 1000;
export const ACCOUNT = /^[a-z0-9_]{3,32}$/;
export const DEVICE = /^(primary|[a-f0-9]{64})$/;
const B64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
// Инвариант протокола: неверные данные на границе доверия — исключение,
// а не «мягкая» деградация.
export function check(value, reason = 'Invalid protocol data') {
  if (!value) throw new Error(reason);
}
// Base64-кодирование и декодирование: unb64 проверяет формат и размер,
// отклоняя пустые и слишком длинные значения.
export function b64(bytes) {
  return btoa(Array.from(new Uint8Array(bytes), b => String.fromCharCode(b)).join(''));
}
export function unb64(value, max = 1024 * 1024) {
  check(typeof value === 'string' && value.length > 0 && value.length <= max && B64.test(value));
  return Uint8Array.from(atob(value), c => c.charCodeAt(0));
}
// Текст → байты UTF-8 для хэширования.
export const textBytes = value => utf8.encode(value);
// Same pre-encoding convention as existing CryptoService.signData/verifySignature.
export const signatureBytes = value => utf8.encode(b64(utf8.encode(value)));
// SHA-256 строки в hex — базовый примитив для digest'ов структур протокола.
export async function hash(value) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', utf8.encode(value))),
    b => b.toString(16).padStart(2, '0')).join('');
}
// Отпечаток ключа (SHA-256 от SPKI-байтов): им закрепляют корень доверия.
export async function fingerprint(spki) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', unb64(spki, 2048))),
    b => b.toString(16).padStart(2, '0')).join('');
}
// id устройства = SHA-256 пары его ключей: идентификатор нельзя подделать,
// не сменив ключи.
export async function deviceId(encryptionKey, signingKey) {
  return hash(JSON.stringify([encryptionKey, signingKey]));
}
// Импорт SPKI-ключа с жёсткой проверкой: только RSA-4096, экспонента 65537
// и ровно одно разрешённое использование.
export async function publicKey(spki, algorithm, usage) {
  const key = await crypto.subtle.importKey('spki', unb64(spki, 2048),
    { name: algorithm, hash: 'SHA-256' }, false, [usage]);
  check(key.algorithm.modulusLength === 4096 && b64(key.algorithm.publicExponent) === 'AQAB', 'Unsupported RSA key');
  return key;
}
// Проверка подписи RSA-PSS (SHA-256, соль 32 байта). Ошибка формата/импорта
// трактуется как «подпись неверна», а не как аварийное исключение.
export async function verify(text, signature, spki) {
  try {
    return await crypto.subtle.verify({ name: 'RSA-PSS', saltLength: 32 },
      await publicKey(spki, 'RSA-PSS', 'verify'), unb64(signature, 1024), signatureBytes(text));
  } catch { return false; }
}
// Подпись RSA-PSS приватным ключом устройства (SHA-256, соль 32 байта) —
// параметры совпадают с verify() и мобильным клиентом.
export async function sign(text, key) {
  return b64(await crypto.subtle.sign({ name: 'RSA-PSS', saltLength: 32 }, key, signatureBytes(text)));
}
// Строгая форма структуры: ровно ожидаемый набор полей — лишние поля
// запрещены, чтобы подписанный текст нельзя было «дополнить».
function fields(value, names) {
  check(value && typeof value === 'object' && !Array.isArray(value));
  check(Object.keys(value).sort().join(',') === [...names].sort().join(','), 'Unexpected fields');
}
// Список устройств: 1..MAX_DEVICES, строго по возрастанию id, без дублей.
// Канонический порядок делает текст манифеста воспроизводимым для подписи.
function devicesShape(devices) {
  check(Array.isArray(devices) && devices.length >= 1 && devices.length <= MAX_DEVICES);
  let previous = '';
  for (const d of devices) {
    fields(d, ['id', 'encryptionKey', 'signingKey']);
    check(typeof d.id === 'string' && DEVICE.test(d.id) && d.id > previous, 'Duplicate or unordered devices');
    unb64(d.encryptionKey, 2048); unb64(d.signingKey, 2048);
    previous = d.id;
  }
}
// Канонический текст манифеста устройств: именно эта строка подписывается
// и хэшируется. Поля сначала строго валидируются — изменение формы
// сломало бы подпись и было бы замечено.
export function manifestText(m) {
  fields(m, ['account', 'rootFingerprint', 'revision', 'previous', 'issuedAt', 'expiresAt', 'devices', 'signer', 'signature']);
  check(typeof m.account === 'string' && ACCOUNT.test(m.account) &&
    typeof m.rootFingerprint === 'string' && /^[a-f0-9]{64}$/.test(m.rootFingerprint));
  check(Number.isSafeInteger(m.revision) && m.revision >= 1);
  check(m.previous === '' || /^[a-f0-9]{64}$/.test(m.previous));
  check(Number.isSafeInteger(m.issuedAt) && Number.isSafeInteger(m.expiresAt));
  check(typeof m.signer === 'string' && (DEVICE.test(m.signer) || m.signer === 'recovery'));
  devicesShape(m.devices);
  return JSON.stringify(['shade-devices:v2', m.account, m.rootFingerprint, m.revision,
    m.previous, m.issuedAt, m.expiresAt, m.signer, m.devices.map(d => [d.id, d.encryptionKey, d.signingKey])]);
}
// Проверка одного манифеста: соответствие корню доверия, срок аренды,
// неизменность primary-идентичности, уникальность ключей устройств,
// корректность RSA-ключей и подпись авторитета (корень, устройство или
// recovery-ключ). Возвращает digest — звено цепочки истории.
export async function verifyManifest(m, trustedRoot, now = Date.now(), authority = trustedRoot) {
  const text = manifestText(m);
  check(m.rootFingerprint === await fingerprint(trustedRoot), 'Root identity changed');
  check(m.issuedAt <= now + 30000 && m.expiresAt > now && m.expiresAt > m.issuedAt &&
    m.expiresAt - m.issuedAt <= MAX_LEASE_MS, 'Expired or invalid directory lease');
  const primary = m.devices.find(d => d.id === 'primary');
  if (primary) check(primary.encryptionKey === trustedRoot && primary.signingKey === trustedRoot, 'Primary identity changed');
  const usedKeys = new Set(primary ? [trustedRoot] : []);
  for (const d of m.devices) {
    if (d.id !== 'primary') {
      check(d.id === await deviceId(d.encryptionKey, d.signingKey), 'Device ID/key mismatch');
      check(d.encryptionKey !== d.signingKey && !usedKeys.has(d.encryptionKey) && !usedKeys.has(d.signingKey), 'Device key reuse');
      usedKeys.add(d.encryptionKey); usedKeys.add(d.signingKey);
    }
    await publicKey(d.encryptionKey, 'RSA-OAEP', 'encrypt');
    await publicKey(d.signingKey, 'RSA-PSS', 'verify');
  }
  check(await verify(text, m.signature, authority), 'Invalid root approval');
  return hash(text);
}
// Pin the root out of band on first contact. Persist this checkpoint encrypted.
// Принятие манифеста: сверка с закреплённым checkpoint запрещает откат
// истории (rollback) и развилку (fork) при одинаковой ревизии.
export async function acceptManifest(m, trustedRoot, checkpoint, now = Date.now()) {
  const digest = await verifyManifest(m, trustedRoot, now);
  if (checkpoint) {
    check(m.account === checkpoint.account && m.rootFingerprint === checkpoint.rootFingerprint, 'Wrong directory identity');
    check(m.revision >= checkpoint.revision, 'Directory rollback');
    if (m.revision === checkpoint.revision) check(digest === checkpoint.digest, 'Directory fork');
    else check(m.revision === checkpoint.revision + 1 && m.previous === checkpoint.digest, 'Missing directory history');
  }
  return { account: m.account, rootFingerprint: m.rootFingerprint, revision: m.revision, digest };
}
// Проверка всей истории манифестов: непрерывность цепочки (revision, previous,
// монотонность issuedAt), права подписанта каждого шага (устройство из
// предыдущего манифеста либо recovery-ключ), запрет «воскрешения» отозванных
// устройств и сверка с закреплённым checkpoint.
export async function verifyHistory(history, trustedRoot, checkpoint, now = Date.now(), genesis = null) {
  const genesisDigest = genesis ? await verifyGenesis(genesis, trustedRoot) : null;
  check(Array.isArray(history) && history.length >= 1 && history.length <= 4096, 'Invalid directory history');
  let previous = '', issuedAt = 0, pinned;
  const retired = new Set();
  const retiredKeys = new Set();
  let oldDevices = [];
  for (let index = 0; index < history.length; index++) {
    const m = history[index];
    check(m.revision === index + 1 && m.previous === previous && m.issuedAt >= issuedAt &&
      m.account === history[0].account, 'Broken directory chain');
    let authority = trustedRoot;
    if (genesis) {
      check(m.account === genesis.account, 'Wrong genesis account');
      const signer = m.signer;
      if (index === 0) check(signer === genesis.firstDevice.id, 'Genesis signer must be the first device');
      const device = index === 0 ? genesis.firstDevice : history[index - 1].devices.find(d => d.id === signer);
      authority = signer === 'recovery' && index > 0 ? genesis.recoveryKey : device?.signingKey;
      check(authority && (signer === 'recovery' || device.id === signer), 'Revoked or unauthorized directory signer');
      if (index === 0) check(m.devices.some(d => d.id === genesis.firstDevice.id) && m.issuedAt >= genesis.createdAt, 'First device missing or invalid genesis time');
    } else check((m.signer ?? 'primary') === 'primary', 'Genesis required for delegated signer');
    previous = await verifyManifest(m, trustedRoot, m.issuedAt, authority);
    for (const d of oldDevices) if (!m.devices.some(next => next.id === d.id)) {
      retired.add(d.id); retiredKeys.add(d.encryptionKey); retiredKeys.add(d.signingKey);
    }
    for (const d of m.devices) {
      check(!retired.has(d.id) && !retiredKeys.has(d.encryptionKey) && !retiredKeys.has(d.signingKey), 'Revoked device resurrected');
      if (genesis) check(d.encryptionKey !== genesis.recoveryKey && d.signingKey !== genesis.recoveryKey, 'Recovery key cannot be a device key');
    }
    oldDevices = m.devices; issuedAt = m.issuedAt;
    if (m.revision === checkpoint?.revision) pinned = previous;
  }
  const latest = history.at(-1);
  check(latest.issuedAt <= now + 30000 && latest.expiresAt > now, 'Expired directory lease');
  if (checkpoint) {
    check(checkpoint.account === latest.account && checkpoint.rootFingerprint === latest.rootFingerprint &&
      latest.revision >= checkpoint.revision && pinned === checkpoint.digest &&
      (!genesis || checkpoint.genesisDigest === genesisDigest), 'Directory rollback or fork');
  }
  return { account: latest.account, rootFingerprint: latest.rootFingerprint, revision: latest.revision, digest: previous, genesisDigest };
}
// Канонический текст genesis — первичной записи аккаунта: первое устройство,
// независимый recovery-ключ, nonce и время создания.
export function genesisText(g) {
  fields(g, ['version', 'account', 'nonce', 'createdAt', 'legacy', 'firstDevice', 'recoveryKey', 'signature']);
  check(g.version === 2 && typeof g.account === 'string' && ACCOUNT.test(g.account) &&
    typeof g.nonce === 'string' && /^[a-f0-9]{64}$/.test(g.nonce) && Number.isSafeInteger(g.createdAt) && typeof g.legacy === 'boolean');
  devicesShape([g.firstDevice]); unb64(g.recoveryKey, 2048);
  return JSON.stringify(['shade-account:v2', g.account, g.nonce, g.createdAt, g.legacy,
    [g.firstDevice.id, g.firstDevice.encryptionKey, g.firstDevice.signingKey], g.recoveryKey]);
}
// Проверка genesis: подпись обязана стоять корневым ключом; первый ключ —
// либо legacy-идентичность, либо пара независимых ключей; recovery-ключ
// не совпадает с ключами устройства. Возвращает digest genesis.
export async function verifyGenesis(g, trustedRoot) {
  const text = genesisText(g), d = g.firstDevice;
  check(d.signingKey === trustedRoot, 'Genesis anchor substitution');
  if (g.legacy) check(d.id === 'primary' && d.encryptionKey === trustedRoot, 'Legacy identity changed');
  else check(d.id === await deviceId(d.encryptionKey, d.signingKey) && d.encryptionKey !== d.signingKey, 'Invalid first device');
  check(g.recoveryKey !== d.encryptionKey && g.recoveryKey !== d.signingKey, 'Recovery must use an independent key');
  await publicKey(d.encryptionKey, 'RSA-OAEP', 'encrypt');
  await publicKey(g.recoveryKey, 'RSA-PSS', 'verify');
  check(await verify(text, g.signature, trustedRoot), 'Invalid genesis signature');
  return hash(text);
}
// Канонический текст pairing-заявки нового устройства: id и пара ключей,
// nonce и срок. Заявка ограничена по времени — переиграть её позже нельзя.
export function pairingText(account, d, nonce, expiresAt) {
  check(typeof account === 'string' && ACCOUNT.test(account) && typeof nonce === 'string' &&
    /^[a-f0-9]{64}$/.test(nonce) && Number.isSafeInteger(expiresAt));
  check(DEVICE.test(d.id) && d.id !== 'primary');
  return JSON.stringify(['shade-pair:v2', account, d.id, d.encryptionKey, d.signingKey, nonce, expiresAt]);
}
// Канонический текст запроса операции: подписывается устройством вместе
// с nonce, выданным сервером как challenge, — повтор запроса невозможен.
export function requestText(account, id, nonce, operation) {
  check(typeof account === 'string' && ACCOUNT.test(account) && typeof id === 'string' && DEVICE.test(id) &&
    typeof nonce === 'string' && /^[a-f0-9]{64}$/.test(nonce) && typeof operation === 'string' && /^[a-f0-9]{64}$/.test(operation));
  return JSON.stringify(['shade-request:v2', account, id, nonce, operation]);
}
// Канонический текст сообщения. Оно фиксирует ревизии и digest'ы директорий
// обеих сторон и несёт конверты для ВСЕХ устройств отправителя и получателя:
// полноту fanout можно проверить по подписанным директориям.
export function messageText(m) {
  fields(m, ['version', 'id', 'from', 'deviceId', 'to', 'fromRevision', 'toRevision',
    'fromDigest', 'toDigest', 'createdAt', 'envelopes', 'signature']);
  check(m.version === 2 && typeof m.id === 'string' && /^[a-f0-9]{64}$/.test(m.id) &&
    typeof m.from === 'string' && typeof m.to === 'string' && ACCOUNT.test(m.from) &&
    ACCOUNT.test(m.to) && m.from !== m.to && typeof m.deviceId === 'string' && DEVICE.test(m.deviceId));
  check([m.fromRevision, m.toRevision].every(n => Number.isSafeInteger(n) && n >= 1) && Number.isSafeInteger(m.createdAt));
  check(/^[a-f0-9]{64}$/.test(m.fromDigest) && /^[a-f0-9]{64}$/.test(m.toDigest));
  check(Array.isArray(m.envelopes) && m.envelopes.length >= 2 && m.envelopes.length <= MAX_DEVICES * 2);
  let previous = '';
  for (const e of m.envelopes) {
    fields(e, ['account', 'deviceId', 'payload']); fields(e.payload, ['k', 'd']);
    const target = `${e.account}:${e.deviceId}`;
    check(typeof e.account === 'string' && ACCOUNT.test(e.account) && typeof e.deviceId === 'string' &&
      DEVICE.test(e.deviceId) && target > previous, 'Duplicate or unordered recipients');
    check(unb64(e.payload.k, 1024).length === 512);
    check(unb64(e.payload.d, 100000).length >= 16);
    previous = target;
  }
  return JSON.stringify(['shade-message:v2', m.id, m.from, m.deviceId, m.to,
    m.fromRevision, m.toRevision, m.fromDigest, m.toDigest, m.createdAt,
    m.envelopes.map(e => [e.account, e.deviceId, e.payload.k, e.payload.d])]);
}
// Проверка входящего сообщения: совпадение аккаунтов, актуальность директорий
// (ревизии и digest'ы), свежесть метки времени, существование устройства
// отправителя, полный fanout конвертов и подпись ключом устройства.
export async function verifyMessage(m, sender, recipient, now = Date.now()) {
  const text = messageText(m);
  check(m.from === sender.account && m.to === recipient.account, 'Wrong accounts');
  check(m.fromRevision === sender.revision && m.toRevision === recipient.revision &&
    m.fromDigest === await hash(manifestText(sender)) && m.toDigest === await hash(manifestText(recipient)), 'Stale device directory');
  check(m.createdAt <= now + 30000 && m.createdAt >= now - 7 * 24 * 60 * 60 * 1000, 'Expired message');
  const device = sender.devices.find(d => d.id === m.deviceId);
  check(device, 'Revoked or unknown sender device');
  const expected = [sender, recipient].flatMap(roster => roster.devices.map(d => `${roster.account}:${d.id}`)).sort();
  check(JSON.stringify(m.envelopes.map(e => `${e.account}:${e.deviceId}`)) === JSON.stringify(expected), 'Incomplete recipient fanout');
  check(await verify(text, m.signature, device.signingKey), 'Invalid device message signature');
  return hash(text);
}

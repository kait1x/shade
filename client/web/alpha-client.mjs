// alpha-client.mjs — веб-клиент Shade (PWA): связывает шифрованный vault
// (IndexedDB, WebCrypto) с сервером протокола device-v2. Сообщения шифруются
// только на устройстве: сервер видит лишь подписанные протокольные структуры
// и конверты, ключи и расшифрованная история не покидают браузер.
import * as c from './device_crypto.mjs';
import { b64, unb64, check, hash, sign, requestText, messageText, verifyHistory, genesisText } from './protocol/device-v2.mjs';
import { readState, writeState, refreshDurability } from './alpha-storage.mjs';
import { createPairingChallenge, decodeChallenge, buildPairingOffer, encodeOffer, decodeOffer,
  verifyPairingOffer, buildPairingConfirmation, encodeConfirmation, decodeConfirmation,
  verifyPairingConfirmation } from './pairing.mjs';

// VAPID applicationServerKey conversion (base64url -> Uint8Array).
function urlBase64ToUint8Array(value) {
  const padding = '='.repeat((4 - value.length % 4) % 4);
  const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  return Uint8Array.from(raw, ch => ch.charCodeAt(0));
}
const pushKeyB64Url = (sub, name) => btoa(String.fromCharCode(...new Uint8Array(sub.getKey(name))))
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// ref — уникальный ключ сообщения в локальной истории; digest — хэш операции
// (имя + тело), который подписывается при доказательстве запроса.
export const ref = m => `${m.from}:${m.deviceId}:${m.id}`;
export const digest = (op, body = null) => hash(JSON.stringify([op, body]));
// Alpha wire payload agreement (opaque to the signed device-v2 envelope):
// plain text stays plain text; a reply adds {"shade":1,"t","r":{ref,from,text}};
// media chunks (contract C4) add {"shade":1,"m":{id,mime,index,total,chunk}}.
// Old histories without the marker keep rendering as plain text.
const REPLY_PREVIEW_LIMIT = 2000;
const SEND_BATCH_LIMIT = 8;
const SEND_BATCH_BYTES = 1536 * 1024;
const MEDIA_CHUNK_BYTES = 32768;
export const voiceMime = mime => /^audio\/(webm|ogg|mp4|aac|wav|mpeg)$/i.test(mime);
function encodePayload(text, reply) {
  check(typeof reply.ref === 'string' && reply.ref.length <= 200 &&
    typeof reply.from === 'string' && typeof reply.text === 'string' && reply.text.length > 0,
    'Некорректное сообщение для ответа');
  return JSON.stringify({ shade: 1, t: text, r: { ref: reply.ref, from: reply.from,
    text: reply.text.slice(0, REPLY_PREVIEW_LIMIT) } });
}
function decodePayload(payload) {
  try {
    const parsed = JSON.parse(payload);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && parsed.shade === 1) {
      if (parsed.m && typeof parsed.m === 'object' &&
        typeof parsed.m.id === 'string' && typeof parsed.m.mime === 'string' &&
        Number.isSafeInteger(parsed.m.index) && Number.isSafeInteger(parsed.m.total) &&
        parsed.m.index >= 0 && parsed.m.index < parsed.m.total && parsed.m.total <= 64 &&
        typeof parsed.m.chunk === 'string' && parsed.m.chunk.length <= 43692) {
        return { media: parsed.m };
      }
      if (typeof parsed.t === 'string' &&
        (parsed.r === null || parsed.r === undefined || (typeof parsed.r === 'object' &&
          typeof parsed.r.ref === 'string' && typeof parsed.r.from === 'string' &&
          typeof parsed.r.text === 'string'))) {
        return { text: parsed.t, reply: parsed.r ? { ref: parsed.r.ref, from: parsed.r.from,
          text: parsed.r.text } : null };
      }
    }
  } catch { /* JSON-like plain text renders unchanged. */ }
  return { text: payload, reply: null };
}
function mergeDeviceProgress(previous, updates) {
  const merged = new Map(previous.map(device => [`${device.account}:${device.id}`, device]));
  for (const device of updates) {
    const key = `${device.account}:${device.id}`;
    const current = merged.get(key);
    merged.set(key, {
      ...device,
      acknowledgedAt: Math.max(current?.acknowledgedAt ?? 0, device.acknowledgedAt ?? 0) || null,
      readAt: Math.max(current?.readAt ?? 0, device.readAt ?? 0) || null,
    });
  }
  return [...merged.values()];
}

// Доступ к закреплённой директории контакта в локальном состоянии.
const contact = (state, account) => Object.hasOwn(state.contacts, account) ? state.contacts[account] : null;
const putContact = (state, account, value) => Object.defineProperty(state.contacts, account,
  { value, enumerable: true, configurable: true, writable: true });
// pageController отменяет все сетевые запросы при закрытии/перезагрузке вкладки,
// чтобы синхронизация не мешала выгрузке страницы.
let pageController = new AbortController();
const departing = () => pageController.abort();
window.addEventListener('beforeunload', departing);
window.addEventListener('pagehide', departing);
window.addEventListener('pageshow', event => { if (event.persisted) pageController = new AbortController(); });
// Единственная точка HTTP-доступа: same-origin куки, запрет кэша,
// таймаут 20 с и отмена запроса при закрытии страницы.
export async function api(route, body, options = {}) {
  if (!navigator.onLine) throw Error('Нет сети');
  if (pageController.signal.aborted) throw Error('Страница закрывается');
  const controller = new AbortController(), abort = () => controller.abort();
  pageController.signal.addEventListener('abort', abort, {once:true});
  const timeout = setTimeout(abort, options.timeoutMs ?? 20000);
  try {
    const hasBody = body !== undefined;
    const response = await fetch(route, { credentials: 'same-origin', cache: 'no-store',
      method: options.method || (hasBody ? 'POST' : 'GET'),
      headers: { ...(options.headers || {}), ...(hasBody ? { 'Content-Type': 'application/json' } : {}) },
      ...(hasBody ? { body: JSON.stringify(body) } : {}),
      signal: controller.signal });
    let result;
    try { result = await response.json(); }
    catch {
      // Non-JSON failure bodies (e.g. the relay's text/html 429) must not
      // masquerade as an outage: name the real condition when it is known.
      throw Error(response.status === 429
        ? 'Слишком много запросов. Подождите около минуты и повторите.'
        : 'Сервер недоступен. Попробуйте позже.');
    }
    if (!response.ok) {
      const error = Error(result.error || 'Ошибка сервера'); error.status = response.status; throw error;
    }
    return result;
  } finally {
    clearTimeout(timeout); pageController.signal.removeEventListener('abort',abort);
  }
}
// Основной клиент: владеет vault (ключи) и локальным состоянием (контакты,
// сообщения, outbox). Все мутации состояния сериализуются через exclusive(),
// поэтому параллельные sync не конкурируют за запись в IndexedDB.
export class AlphaClient extends EventTarget {
  constructor() {
    // Состояние появляется позже — через prepare()/load(), конструктор только
    // готовит обработчики жизненного цикла страницы и сети.
    super(); this.tail = Promise.resolve(); this.connected = false; this.stopped = false;
    this.queueRetryAt = new Map();
    this.foreground = () => { if (!document.hidden) this.sync().catch(() => {}); };
    this.online = () => { this.socket?.connect(); this.sync().catch(() => {}); };
    this.offline = () => { this.socket?.disconnect(); this.connected = false; this.changed(); };
    // iPhone reliability: when the page is hidden or closed (app switcher,
    // Safari tab close), re-commit the current state and re-warm the deletion
    // journal so the platform flush has the freshest data before a kill.
    this.persistNow = () => {
      if (this.session && this.state && !this.stopped) {
        refreshDurability(this.session, this.state, this.revision).catch(() => {});
      }
    };
    this.hidden = () => { if (document.hidden) this.persistNow(); };
  }
  changed() { this.dispatchEvent(new Event('change')); }
  // Очередь критических секций: операция стартует только после завершения
  // предыдущей; ошибка не рвёт цепочку последующих операций.
  exclusive(work) {
    const task = this.tail.then(work); this.tail = task.catch(() => {}); return task;
  }
  // Запись состояния в шифрованный vault с текущей ревизией, затем уведомление UI.
  async save(next) {
    this.revision = await writeState(this.session, next, this.revision);
    this.state = next; this.changed();
  }
  // Разблокировка существующего vault: ключи расшифровываются в памяти по
  // passphrase, история устройства проверяется, но не пересоздаётся.
  async load(vault, passphrase) {
    this.vault = vault; this.session = await c.unlockVault(vault, passphrase);
    const saved = await readState(this.session);
    this.revision = saved.revision; this.state = saved.value;
    check(this.state, 'История устройства отсутствует. Новые ключи не созданы; нужно восстановление.');
    this.changed();
  }
  // Создание нового устройства: vault, genesis аккаунта и recovery-backup
  // (шифруется recovery-фразой). Identity сохраняется локально до каких-либо
  // отправки заявки — регистрация на сервере отдельный шаг register().
  async prepare(account, passphrase, recoveryPhrase, binding, { pinLength } = {}) {
    check(!(await c.listVaults()).some(v => v.account === account), 'На этом устройстве уже есть ключи аккаунта. Разблокируйте их.');
    check(pinLength === undefined || !binding, 'Choose a single device protection method');
    const vault = await c.createVault(account, passphrase, { pinLength });
    // Binding metadata (device_binding.mjs) rides on the vault record; the
    // ciphertext, AAD and unlock path stay byte-compatible with passphrase vaults.
    if (binding) vault.binding = binding;
    const session = await c.unlockVault(vault, passphrase);
    let backup = await c.createRecoveryBackup(account, vault.signingKey, recoveryPhrase);
    const { serverTime } = await api('/api/session');
    const now = serverTime ?? Date.now();
    const genesis = await c.createGenesis(vault, session, backup.publicKey, now);
    backup = await c.finalizeRecoveryBackup(backup, recoveryPhrase, genesis);
    const manifest = await c.approveDevices(genesis, [], [c.descriptor(vault)], session, null, now);
    this.vault = vault; this.session = session; this.revision = 0;
    // Identity and pending registration survive even if HTTP fails afterwards.
    await c.saveVault(vault);
    await this.save({ own: { root: vault.signingKey, genesis, history: [manifest] },
      contacts: {}, messages: [], outbox: [], pendingAck: [], backup, registered: false });
    return backup;
  }
  // Регистрация genesis на сервере. Genesis должен быть свежим (окно 4 минуты):
  // похищенный пакет нельзя зарегистрировать задним числом.
  async register({ recoveryPassword, replacePendingRecovery = false } = {}) {
    return this.exclusive(async () => {
      check(this.state && !this.state.registered, 'Регистрация уже завершена');
      const status = await api('/api/session');
      if (status.account === this.session.account) { await this.refreshOwn(); return; }
      check(status.authenticated, 'google_login_required');
      check(!status.account, 'Google уже привязан к другому аккаунту');
      // Renewal and submission share one serialized action. Sign the roster
      // and proof at a fresh server time after the local backup is rebound.
      let now = status.serverTime ?? Date.now();
      const previous = this.state.own.genesis;
      let genesis = previous, backup = this.state.backup;
      if (replacePendingRecovery) {
        backup = await c.createRecoveryBackup(this.vault.account, this.vault.signingKey, recoveryPassword);
        now = (await api('/api/session')).serverTime ?? Date.now();
        genesis = await c.createGenesis(this.vault, this.session, backup.publicKey, now);
        backup = await c.finalizeRecoveryBackup(backup, recoveryPassword, genesis);
      } else if (recoveryPassword !== undefined) {
        genesis = await c.createGenesis(this.vault, this.session, previous.recoveryKey, now);
        try {
          backup = await c.rebindPendingBackup(backup, recoveryPassword, previous, genesis);
        } catch (error) {
          if (error.name === 'OperationError') throw Error('registration_password_invalid');
          throw error;
        }
        now = (await api('/api/session')).serverTime ?? Date.now();
      }
      const { createdAt } = genesis;
      check(createdAt >= now - 240000 && createdAt <= now + 30000, 'stale_registration');
      const manifest = await c.approveDevices(genesis, [], [c.descriptor(this.vault)], this.session, null, now);
      await this.save({ ...this.state, own: { ...this.state.own, genesis, history: [manifest] }, backup });
      await api('/api/v2/register', { genesis, manifest,
        proofs: [await c.pairingProof(this.vault, this.session, now)], recoveryBackup: backup }, { timeoutMs: 60000 });
      const next = structuredClone(this.state); next.own.history = [manifest]; next.registered = true;
      await this.save(next);
    });
  }
  // Challenge-response: сервер выдаёт одноразовый nonce, устройство подписывает
  // его вместе с хэшем операции. Сервер убеждается, что запрос идёт от владельца
  // ключа, а повторное использование запроса невозможно.
  async proof(op, body = null) {
    const signedBody = op === 'send' ? await hash(messageText(body)) :
      op === 'send.batch' ? await Promise.all(body.map(message => hash(messageText(message)))) : body;
    const operation = await digest(op, signedBody);
    const { account, id } = this.session;
    // Backoff только на квоту challenge (120/мин): это дефицитный ресурс.
    // Глобальный /api-лимит НЕ ретраим здесь — повторы в насыщенный бакет
    // сами же его выжигают (death spiral); api() остаётся fail-fast.
    let nonce;
    for (let attempt = 0; ; attempt++) {
      try { ({ nonce } = await api('/api/v2/challenge', { account, id, operation })); break; }
      catch (error) {
        const limited = error?.status === 429 || /Слишком много запросов/.test(error?.message || '');
        if (!limited || attempt >= 3) throw error;
        await new Promise(resolve => setTimeout(resolve, 1500 * 2 ** attempt));
      }
    }
    return { account, id, nonce, proof: await sign(requestText(account, id, nonce, operation), this.session.signing) };
  }
  // Любая операция с сервером сопровождается доказательством владения ключом.
  async operation(op, body = null) {
    return api('/api/v2/operation', { op, body, auth: await this.proof(op, body) },
      { timeoutMs: 75000 });
  }
  // Проверка директории устройств: если для контакта уже закреплён отпечаток
  // (pin), любое изменение genesis/root блокирует работу — защита от подмены
  // ключей, в том числе со стороны скомпрометированного сервера.
  async verifyDirectory(directory, pinned) {
    check(directory?.genesis, 'Аккаунт ещё не поддерживает device-v2');
    if (pinned) check(await hash(genesisText(directory.genesis)) === pinned.checkpoint.genesisDigest &&
      directory.root === pinned.root, 'Ключи контакта изменились. Отправка заблокирована.');
    const checkpoint = await verifyHistory(directory.history, directory.root, pinned?.checkpoint, Date.now(), directory.genesis);
    return { ...directory, checkpoint };
  }
  // Сверка собственной директории с сервером: полная проверка цепочки
  // манифестов, продление lease при скором истечении, отказ при отзыве устройства.
  async refreshOwn() {
    const server = await api('/api/session');
    check(server.authenticated && server.account === this.session.account, 'google_login_required');
    const pinned = { ...this.state.own, checkpoint: await verifyHistory(this.state.own.history,
      this.state.own.root, null, this.state.own.history.at(-1).issuedAt, this.state.own.genesis) };
    // Accept an expired last lease only to verify/sign a renewal. Never use it
    // for encrypting a message or bypass the persisted chain checkpoint.
    const directory = server.directory;
    await verifyHistory(directory.history, pinned.root, pinned.checkpoint,
      directory.history.at(-1).issuedAt, pinned.genesis);
    check(directory.history.at(-1).devices.some(d => d.id === this.session.id), 'Устройство отозвано');
    if (directory.history.at(-1).expiresAt < Date.now() + 3600000) {
      const manifest = await c.approveDevices(pinned.genesis, directory.history,
        directory.history.at(-1).devices, this.session, pinned.checkpoint);
      try {
        await this.operation('install', { manifest });
        directory.history.push(manifest);
      } catch (error) {
        // CAS race (multi-device lease renewal): another device advanced the
        // directory between our fetch and install. The relay answers with the
        // distinct stale_directory code — refetch the fresh tip, rebuild the
        // renewal from it and retry once; converges instead of looping.
        if ((error.message || '') !== 'stale_directory') throw error;
        const fresh = await api('/api/session');
        check(fresh.authenticated && fresh.account === this.session.account, 'google_login_required');
        const fdir = fresh.directory;
        await verifyHistory(fdir.history, pinned.root, pinned.checkpoint,
          fdir.history.at(-1).issuedAt, pinned.genesis);
        const manifest2 = await c.approveDevices(pinned.genesis, fdir.history,
          fdir.history.at(-1).devices, this.session, pinned.checkpoint);
        await this.operation('install', { manifest: manifest2 });
        directory.history.push(manifest2);
      }
    }
    const own = await this.verifyDirectory(directory, pinned);
    if (!this.state.registered || JSON.stringify(own) !== JSON.stringify(this.state.own)) {
      await this.save({ ...this.state, own, registered: true });
    }
  }
  async users() { return this.operation('users'); }
  // history.transfer (SYNC_PLAN §5.2): записи истории шифруются ключом ЦЕЛЕВОГО
  // устройства (OAEP-конверт), сервер видит только ciphertext и не учитывает
  // пакеты в receipts/очередях. Id пакета детерминирован (record id + seq) —
  // повторная отправка идемпотентна; курсор и ack — на принимающей стороне.
  async transferHistory(toDevice, records, onProgress = () => {}) {
    const directory = await this.operation('directory', this.session.account);
    const target = directory.history.at(-1).devices.find(d => d.id === toDevice);
    check(target, 'Целевое устройство отсутствует в каталоге');
    let sent = 0;
    for (let start = 0; start < records.length; start += 50) {
      const batch = records.slice(start, start + 50);
      const packages = [];
      for (let i = 0; i < batch.length; i++) {
        const seq = start + i + 1;
        const payload = JSON.stringify(await c.encryptLegacy(JSON.stringify(batch[i]), target.encryptionKey));
        check(payload.length <= 87384, 'Запись истории слишком велика для переноса');
        packages.push({ id: await hash(JSON.stringify([batch[i].id ?? batch[i].ref, seq])), seq, payload });
      }
      await this.operation('history.transfer', { to: toDevice, packages });
      sent += batch.length;
      onProgress(sent, records.length);
    }
    return { sent };
  }
  // Android imports the same signed record format used between two phones.
  async transferSavedHistory(toDevice) {
    const account = this.session.account;
    const directory = await this.verifyDirectory(await this.operation('directory', account), this.state.own);
    const target = directory.history.at(-1).devices.find(d => d.id === toDevice);
    check(target && target.id !== this.session.id, 'Выберите другое подключённое устройство');
    const snapshot = this.state.messages.slice();
    let packages = [], sent = 0;
    const sendBatch = async () => {
      if (!packages.length) return;
      await this.operation('history.transfer', { to: toDevice, packages });
      packages = [];
    };
    const append = async (message, reference, plain) => {
      const [, , id] = reference.split(':');
      const mine = message.from === account;
      const status = message.status === 'retracted' ? 'retracted' : mine ? 'server' : 'received';
      const record = JSON.stringify({
        account, fromDevice: this.session.id, toDevice, ref: reference,
        peer: mine ? message.to : message.from, direction: mine ? 'out' : 'in',
        id, createdAt: message.createdAt, status, plain
      });
      const signature = await sign(`shade-history-v2:${record}`, this.session.signing);
      const payload = JSON.stringify(await c.encryptLegacy(JSON.stringify([record, signature]), target.encryptionKey));
      check(payload.length <= 87384, 'Сообщение превышает лимит переноса сервера');
      packages.push({ id: await hash(JSON.stringify([account, toDevice, reference, status])), seq: ++sent, payload });
      if (packages.length === 16) await sendBatch();
    };
    const liveRef = /^[a-z0-9_]{3,32}:(?:primary|[a-f0-9]{64}):[a-f0-9]{64}$/;
    let skipped = 0;
    for (const message of snapshot) {
      if (!['accepted', 'sent', 'received', 'retracted'].includes(message.status)) continue;
      if (message.media?.data && /^media:[a-f0-9]{32}$/.test(message.ref)) {
        const mediaId = message.ref.slice(6);
        const raw = atob(message.media.data);
        const total = Math.ceil(raw.length / 32768);
        for (let index = 0; index < total; index++) {
          const knownRef = message.chunkRefs?.[index];
          const reference = liveRef.test(knownRef) ? knownRef : `${message.from}:primary:${await hash(JSON.stringify([message.from, message.to, mediaId, index]))}`;
          const plain = JSON.stringify({ shade: 1, m: {
            id: mediaId, mime: message.media.mime || 'image/jpeg', index, total,
            chunk: btoa(raw.slice(index * 32768, (index + 1) * 32768))
          }});
          await append(message, reference, plain);
        }
      } else if (liveRef.test(message.ref)) {
        const plain = message.status === 'retracted' ? '' :
          message.reply ? encodePayload(message.text ?? '', message.reply) : message.text ?? '';
        // Leave room for JSON escaping, metadata and the device signature.
        if (new TextEncoder().encode(JSON.stringify(plain)).length > 63000) {
          skipped++;
          continue;
        }
        await append(message, message.ref, plain);
      }
    }
    await sendBatch();
    return { sent, skipped };
  }
  async fetchHistory(since = 0) { return this.operation('history.fetch', { since }); }
  async ackHistory(ids) { return this.operation('history.ack', { ids }); }
  // ── Когортная миграция диалога (D1, V2_COHORT_MIGRATION.md) ──────────────
  // Серверный per-dialog journal ведёт состояние v1_active → migration_pending
  // → transferring → v2_active; flip только после готовности ВСЕХ устройств
  // обеих сторон, переноса очередей и пустых outbox. UI-проводка (баннеры,
  // HOLD-очередь) — отдельная задача; здесь только подписанные операции.
  // Старт миграции диалога с собеседником (оба аккаунта должны быть enrolled).
  async dialogMigrationStart(peer) { return this.operation('dialog.migration.start', { peer }); }
  // Подтверждение готовности ВСЕХ устройств своего аккаунта по каталогу.
  // По умолчанию берётся полный текущий ростер своей директории.
  async dialogMigrationReady(peer, devices = null) {
    const roster = devices || this.state.own.history.at(-1).devices.map(d => d.id);
    return this.operation('dialog.migration.ready', { peer, devices: roster });
  }
  // Проекция состояния диалога для UI (ожидание собеседника/устройств, gate).
  async dialogMigrationStatus(peer) { return this.operation('dialog.migration.status', { peer }); }
  // Отмена до переключения: диалог возвращается в v1, journal сохраняется.
  async dialogMigrationAbort(peer) { return this.operation('dialog.migration.abort', { peer }); }
  // Откат после переключения (grace 14 дней): reverse-replay v2-сообщений в v1.
  async dialogMigrationRollback(peer) { return this.operation('dialog.migration.rollback', { peer }); }
  // Подписанный ack пустого outbox диалога — обязательное условие flip.
  async dialogMigrationOutboxEmpty(peer) { return this.operation('dialog.migration.outbox-empty', { peer }); }
  // Расшифровка принятого пакета истории локальным ключом устройства.
  async openHistoryPayload(payload) {
    return JSON.parse(await c.decryptLegacy(JSON.parse(payload), this.session.encryption));
  }
  // Запрос и проверка директории контакта; сервер обязан вернуть ровно
  // запрошенный аккаунт. Отметка доверия trust — локальное аддитивное поле:
  // сервер её не передаёт, поэтому переносим из закреплённого контакта.
  async inspectContact(account) {
    const pinned = contact(this.state, account);
    const directory = await this.verifyDirectory(await this.operation('directory', account), pinned);
    check(directory.genesis.account === account, 'Сервер вернул другой аккаунт');
    if (pinned?.trust) directory.trust = pinned.trust;
    return directory;
  }
  // Ручная сверка: директория сохраняется только если её genesis-отпечаток
  // совпал с введённым пользователем; доверие повышается до 'verified'.
  async pinContact(account, expectedDigest) {
    return this.exclusive(async () => {
      const directory = await this.inspectContact(account);
      check(directory.checkpoint.genesisDigest === expectedDigest, 'Отпечаток изменился');
      const next = structuredClone(this.state);
      putContact(next, account, { ...directory, trust: 'verified' });
      await this.save(next);
    });
  }
  // TOFU-закрепление при первом контакте: цепочка манифестов проверяется от
  // genesis, pin не требуется. Расхождение с уже закреплённым genesis/root
  // по-прежнему блокирует verifyDirectory — fail-closed защита не ослабляется.
  async tofuContact(account) {
    return this.exclusive(async () => {
      const directory = await this.inspectContact(account);
      const next = structuredClone(this.state);
      putContact(next, account, { ...directory, trust: directory.trust || 'tofu' });
      await this.save(next);
      return directory;
    });
  }
  // Снимки директорий обеих сторон для шифрования и расшифровки: sealMessage/
  // openMessage сверяют ключи только с этими закреплёнными корнями.
  trust(from, to, state = this.state) {
    const directory = account => account === this.session.account ? state.own : contact(state, account);
    const sender = directory(from), recipient = directory(to);
    check(sender && recipient, 'Контакт не закреплён. Найдите собеседника по никнейму или сверьте отпечаток.');
    return { senderRoot: sender.root, recipientRoot: recipient.root,
      senderGenesis: sender.genesis, recipientGenesis: recipient.genesis,
      senderCheckpoint: sender.checkpoint, recipientCheckpoint: recipient.checkpoint };
  }
  // Device-v2 profile/sticker adapter (B1/B2): the verified v1 business logic
  // mounted under /api/v2, authorized by Google session + one-time device
  // proof per request. operation = digest(['stickers', {method, path, body}])
  // over the parsed body the server will re-serialize; GET carries null.
  async adapterRequest(method, path, body = null) {
    const operation = await hash(JSON.stringify(['stickers', { method, path, body }]));
    const { account, id } = this.session;
    const { nonce } = await api('/api/v2/challenge', { account, id, operation });
    const proof = await sign(requestText(account, id, nonce, operation), this.session.signing);
    return api(`/api/v2${path}`, body === null ? undefined : body,
      { method, headers: { 'x-device-auth': JSON.stringify({ account, id, nonce, proof }) } });
  }
  // Cached projection of the self profile (digest-keyed avatar bytes travel
  // on demand); the source of truth is the v2 profile API. Runs inside the
  // exclusive queue: it writes state and must not race other writers (CAS).
  async loadProfile() {
    return this.exclusive(async () => {
      const data = await this.adapterRequest('GET', `/user/${encodeURIComponent(this.session.account)}/avatar`);
      const next = structuredClone(this.state);
      next.profile = {
        displayName: data.displayName || '',
        avatarImage: typeof data.image === 'string' ? data.image : null,
        avatarImageUrl: typeof data.imageUrl === 'string' ? data.imageUrl : null,
        avatarFrame: ['none', 'minimal', 'silver', 'graphite'].includes(data.frame) ? data.frame : 'none',
        avatarRevision: data.revision || 0,
        avatarDigest: await hash(typeof data.image === 'string' && data.image ? data.image : ''),
      };
      await this.save(next);
      return next.profile;
    });
  }
  async saveProfile(data) {
    return this.exclusive(async () => {
      let revision = this.state.profile?.avatarRevision ?? 0;
      if (data.displayName !== undefined) {
        check(typeof data.displayName === 'string' &&
          data.displayName.trim().length >= 1 && data.displayName.trim().length <= 64,
          'Имя должно содержать от 1 до 64 символов');
        await this.adapterRequest('PUT', '/profile/name', { displayName: data.displayName });
      }
      if (data.avatar !== undefined || data.frame !== undefined) {
        const frame = ['none', 'minimal', 'silver', 'graphite'].includes(data.frame)
          ? data.frame : (this.state.profile?.avatarFrame ?? 'none');
        let uploadId = null;
        if (data.avatar !== undefined && typeof data.avatar === 'string') {
          uploadId = Array.from(crypto.getRandomValues(new Uint8Array(16)),
            b => b.toString(16).padStart(2, '0')).join('');
          // Chunked staging: <=65536 base64 chars per request, strict order,
          // tail replay is idempotent (server contract B1). The FINAL chunk
          // commits server-side and returns the receipt; a PUT confirm with
          // the same uploadId but no image would trip the server's replay
          // digest guard (409), so the receipt is the commit result here.
          let receipt = null;
          for (let offset = 0; offset < data.avatar.length; offset += 65536) {
            receipt = await this.adapterRequest('POST', '/profile/avatar/chunk', {
              uploadId, offset, total: data.avatar.length,
              chunk: data.avatar.slice(offset, offset + 65536), frame, revision });
          }
          if (receipt?.profile?.revision) revision = receipt.profile.revision;
        } else {
          // Frame-only change or avatar removal: no staging, direct commit.
          await this.adapterRequest('PUT', '/profile/avatar', {
            image: data.avatar === undefined ? undefined : data.avatar, frame, revision });
        }
      }
      const next = structuredClone(this.state);
      const committed = await this.adapterRequest('GET', `/user/${encodeURIComponent(this.session.account)}/avatar`);
      next.profile = {
        displayName: committed.displayName || '',
        avatarImage: typeof committed.image === 'string' ? committed.image : null,
        avatarImageUrl: typeof committed.imageUrl === 'string' ? committed.imageUrl : null,
        avatarFrame: ['none', 'minimal', 'silver', 'graphite'].includes(committed.frame) ? committed.frame : 'none',
        avatarRevision: committed.revision || revision,
        avatarDigest: await hash(typeof committed.image === 'string' && committed.image ? committed.image : ''),
      };
      await this.save(next);
      return next.profile;
    });
  }
  // Stickers via the v2 adapter: real inventory, gifts, notes, wall revisions.
  async loadStickers(name, owner) {
    if (owner) return this.adapterRequest('GET', '/stickers/inventory');
    return this.adapterRequest('GET', `/user/${encodeURIComponent(name)}/stickers`);
  }
  async saveStickers(revision, wall) {
    return this.adapterRequest('PUT', '/stickers/wall', { wall, revision });
  }
  async giftSticker(to, art, note, requestId) {
    return this.adapterRequest('POST', '/stickers/gift', { toUsername: to, stickerId: art, note, requestId });
  }
  // Peer avatars resolve through the same v2 profile API; bytes are fetched on
  // demand and cached by digest so projections stay small.
  async peerProfile(account) {
    return this.adapterRequest('GET', `/user/${encodeURIComponent(account)}/avatar`);
  }
  // Отправка: sealMessage шифрует payload отдельно для каждого устройства
  // получателя (fanout конвертов) и подписывает от имени нашего устройства.
  // Сообщение сначала коммитится в локальный outbox — сетевой сбой его не теряет.
  async send(account, text, reply = null) {
    return this.exclusive(async () => {
      check(text.trim().length > 0, 'Введите сообщение');
      if (reply != null) check(reply.text.trim().length > 0, 'Некорректное сообщение для ответа');
      // Refresh directories while online; offline sends use a pinned, unexpired
      // roster. A stale signed outbox entry is retained and shown as blocked.
      if (navigator.onLine) {
        await this.refreshOwn();
        if (account !== this.session.account) {
          const next = structuredClone(this.state); putContact(next, account, await this.inspectContact(account)); await this.save(next);
        }
      }
      const m = await c.sealMessage(reply ? encodePayload(text, reply) : text,
        this.state.own.history, account === this.session.account
          ? this.state.own.history : contact(this.state, account)?.history,
        this.session, this.trust(this.session.account, account));
      const next = structuredClone(this.state);
      next.outbox.push(m); next.messages.push({ ref: ref(m), from: m.from, to: m.to, text, reply,
        createdAt: m.createdAt, status: 'queued', devices: [] });
      await this.save(next);
      if (navigator.onLine) this.scheduleSync();
      return m.id; // Local commit succeeded; keep retrying the exact ciphertext.
    });
  }
  // Local-only contact note, mirroring Android's per-contact note. Stored in
  // the encrypted state (unlike Android's plain SharedPreferences) and never
  // sent to the relay.
  async saveNote(account, text) {
    return this.exclusive(async () => {
      check(typeof account === 'string' && typeof text === 'string' &&
        text.trim().length <= 2000, 'Некорректная заметка');
      const next = structuredClone(this.state);
      next.notes = { ...(next.notes || {}) };
      const trimmed = text.trim();
      if (trimmed) next.notes[account] = trimmed; else delete next.notes[account];
      await this.save(next);
    });
  }
  // Local-only self profile: display name, avatar and frame live in the
  // Local-only removal, mirroring Android «Удалить у себя». A queued send is
  // cancelled; a fetched message is ACKed first so the relay queue cannot
  // redeliver it after deletion. Other devices keep their copy.
  async deleteLocal(messageRef) {
    return this.exclusive(async () => {
      check(typeof messageRef === 'string', 'Некорректное сообщение');
      const next = structuredClone(this.state);
      const message = next.messages.find(m => m.ref === messageRef);
      check(message, 'Сообщение не найдено');
      const pending = next.pendingAck.includes(messageRef);
      if (pending) await this.operation('ack', [messageRef]);
      next.pendingAck = next.pendingAck.filter(item => item !== messageRef);
      next.outbox = next.outbox.filter(m => ref(m) !== messageRef);
      next.messages = next.messages.filter(m => m.ref !== messageRef);
      await this.save(next);
    });
  }
  // Delete-for-all (contract C3): sender-authorized retract; the relay purges
  // undelivered copies and keeps a tombstone that hides delivered ones here.
  async retract(messageRef) {
    return this.exclusive(async () => {
      check(typeof messageRef === 'string', 'Некорректное сообщение');
      const next = structuredClone(this.state);
      const message = next.messages.find(m => m.ref === messageRef);
      check(message, 'Сообщение не найдено');
      check(message.from === this.session.account, 'Отзывать может только отправитель');
      const refs = message.mediaRefs || [messageRef];
      await this.operation('retract', refs);
      next.pendingAck = next.pendingAck.filter(item => !refs.includes(item));
      next.outbox = next.outbox.filter(m => !refs.includes(ref(m)));
      next.messages = next.messages.filter(m => m.ref !== messageRef);
      next.retractionSince = Math.max(next.retractionSince ?? 0, Date.now() - 1000);
      await this.save(next);
    });
  }
  // Read-ACK (contract C5): recipient-device op; the sender sees readAt via
  // the signed status projection. Local readAt prevents re-sending.
  async markRead(account, refs) {
    return this.exclusive(async () => {
      check(Array.isArray(refs) && refs.length >= 1 && refs.length <= 200, 'Некорректный список прочтения');
      await this.operation('read', refs);
      const next = structuredClone(this.state);
      for (const ref of refs) {
        const message = next.messages.find(m => m.ref === ref);
        if (message && message.from === account) message.readAt = Date.now();
      }
      await this.save(next);
    });
  }
  // Фото уходит пачкой подписанных E2EE-чанков; локально — собранное изображение и refs чанков.
  // Media (contract C4): the agreed codec `m` inside the signed opaque
  // envelope — {"shade":1,"m":{id,mime,index,total,chunk}}, 32768 raw bytes
  // per chunk, EXIF-free bytes arrive from the shared editor pipeline. Each
  // chunk is a real signed E2EE message; the UI shows one assembled record.
  async sendMedia(account, imageBase64, mime = 'image/jpeg') {
    return this.exclusive(async () => {
      check(typeof imageBase64 === 'string' && imageBase64.length > 4, 'Не удалось прочитать изображение');
      check(imageBase64.length <= 2796204, 'Изображение слишком большое');
      const raw = unb64(imageBase64, 2796204);
      const total = Math.ceil(raw.length / MEDIA_CHUNK_BYTES);
      check(raw.length >= 128 && raw.length <= 2097152, 'Изображение слишком большое');
      const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
        b => b.toString(16).padStart(2, '0')).join('');
      if (navigator.onLine) {
        await this.refreshOwn();
        if (account !== this.session.account) {
          const nx = structuredClone(this.state); putContact(nx, account, await this.inspectContact(account)); await this.save(nx);
        }
      }
      const messages = [];
      const createdAt = Date.now();
      const history = account === this.session.account ? this.state.own.history : contact(this.state, account)?.history;
      const trust = this.trust(this.session.account, account);
      for (let index = 0; index < total; index++) {
        const slice = raw.subarray(index * MEDIA_CHUNK_BYTES, (index + 1) * MEDIA_CHUNK_BYTES);
        const payload = JSON.stringify({ shade: 1, m: { id, mime, index, total, chunk: b64(slice) } });
        messages.push(await c.sealMessage(payload, this.state.own.history, history, this.session, trust));
      }
      // Commit the entire photo at once before the first network send.
      const next = structuredClone(this.state);
      next.outbox.push(...messages);
      next.messages.push({ ref: `media:${id}`, media: { mime, data: imageBase64 },
        from: this.session.account, to: account, createdAt, status: 'queued',
        devices: [], chunkRefs: messages.map(ref) });
      await this.save(next);
      if (navigator.onLine) this.scheduleSync();
      return id;
    });
  }
  // Typing/presence (contract C2): relay-gated by existing conversation;
  // client throttle mirrors the server's 2 s window. State stays in memory.
  sendTyping(peer) {
    if (!this.socket?.connected) return;
    const now = Date.now();
    if ((this.lastTypingSent?.get(peer) || 0) > now - 2000) return;
    (this.lastTypingSent ??= new Map()).set(peer, now);
    this.socket.emit('typing', { peer });
  }
  // Desired watch set survives disconnects: after reconnect (or a watch
  // requested while offline) every peer is re-watched on 'connect'.
  watchPeer(peer, watch) {
    if (typeof peer !== 'string' || peer === this.session?.account) return;
    if (watch) (this.watching ??= new Set()).add(peer); else this.watching?.delete(peer);
    if (!this.socket?.connected) return;
    this.socket.emit(watch ? 'watch' : 'unwatch', { peer });
  }
  // Device management (B9): revoke = install a manifest signed by this
  // device without the target in the roster. The relay purges its queues
  // and push subscription; IDs/keys can never come back.
  async revokeDevice(deviceId) {
    return this.exclusive(async () => {
      check(navigator.onLine, 'Нет сети');
      await this.refreshOwn();
      const tip = this.state.own.history.at(-1);
      check(tip.devices.some(d => d.id === deviceId), 'Устройство не найдено');
      const roster = tip.devices.filter(d => d.id !== deviceId);
      check(roster.length >= 1, 'Последнее устройство отозвать нельзя');
      const manifest = await c.approveDevices(this.state.own.genesis,
        this.state.own.history, roster, this.session, this.state.own.checkpoint);
      await this.operation('install', { manifest });
      await this.refreshOwn();
    });
  }
  // ── Second-device pairing ──────────────────────────────────────────────
  // Trusted side: a one-time challenge code shown on this screen. The offer
  // must echo it, so an offer crafted away from this screen is rejected
  // (anti-phishing binding). Memory-only; expires in 5 minutes.
  pairingChallenge() {
    const challenge = createPairingChallenge();
    this.pairing = challenge;
    return { code: challenge.code, expiresAt: challenge.expiresAt };
  }
  // Trusted side: verify a pasted offer without mutating anything. Returns
  // what the confirmation screen shows to the approving user.
  async reviewPairingOffer(text) {
    check(this.pairing && this.pairing.expiresAt > Date.now(),
      'Код подключения истёк. Сгенерируйте новый и создайте запрос заново.');
    const offer = decodeOffer(text);
    const device = await verifyPairingOffer(offer, { account: this.session.account, challenge: this.pairing.nonce });
    return { deviceId: device.id, offer, expiresAt: offer.expiresAt };
  }
  // Trusted side: approve = install a manifest signed by THIS device with the
  // newcomer in the roster. The offer carries the fresh pairing proof the
  // server re-verifies. Returns the confirmation text for the new device.
  async approvePairing(text) {
    return this.exclusive(async () => {
      check(navigator.onLine, 'Нет сети');
      const { offer } = await this.reviewPairingOffer(text);
      await this.refreshOwn();
      const tip = this.state.own.history.at(-1);
      check(!tip.devices.some(d => d.id === offer.device.id), 'Это устройство уже подключено');
      check(tip.devices.length < 8, 'Достигнут лимит 8 устройств');
      const manifest = await c.approveDevices(this.state.own.genesis, this.state.own.history,
        [...tip.devices, offer.device], this.session, this.state.own.checkpoint);
      // Only the fields the registry consumes. v2 offers carry the challenge
      // inside the signed proof (pairingTextV2); v1 keeps the legacy shape
      // during the transition window.
      const proofs = [{ id: offer.device.id, nonce: offer.nonce,
        expiresAt: offer.expiresAt, signature: offer.signature,
        ...(offer.v === 2 ? { challenge: offer.challenge, pairingVersion: 2 } : {}) }];
      await this.operation('install', { manifest, proofs });
      await this.refreshOwn();
      this.pairing = null; // One-time: a stolen approval screen cannot be reused.
      const confirmation = buildPairingConfirmation({ account: this.session.account,
        genesis: this.state.own.genesis, tip: this.state.own.history.at(-1) });
      return encodeConfirmation(confirmation);
    });
  }
  // New side: durable local keys BEFORE any approval. No state is written
  // until completePairing succeeds, so an abandoned attempt leaves nothing
  // server-side and the same keys can re-offer later.
  async preparePairingVault(account, passphrase) {
    return this.exclusive(async () => {
      check(!(await c.listVaults()).some(v => v.account === account), 'На этом устройстве уже есть ключи аккаунта. Разблокируйте их.');
      const vault = await c.createVault(account, passphrase);
      const session = await c.unlockVault(vault, passphrase);
      await c.saveVault(vault);
      this.vault = vault; this.session = session; this.state = null; this.revision = 0;
      this.changed();
      return vault.id;
    });
  }
  // New side: the signed offer for the trusted device (clipboard transport).
  async createPairingOffer(code) {
    check(this.session, 'Сначала создайте ключи устройства');
    const challenge = decodeChallenge(code);
    const offer = await buildPairingOffer({ account: this.session.account,
      device: c.descriptor(this.vault), signing: this.session.signing, challenge });
    return encodeOffer(offer);
  }
  // New side: finish enrollment. The confirmation is only a routing hint —
  // trust is built from the full server directory verified against the pinned
  // genesis right after the device session opens.
  async completePairing(text) {
    return this.exclusive(async () => {
      check(this.session, 'Ключи устройства не разблокированы');
      check(navigator.onLine, 'Нет сети');
      const confirmation = decodeConfirmation(text);
      const verified = await verifyPairingConfirmation(confirmation,
        { account: this.session.account, deviceId: this.session.id });
      // Sessionless bootstrap is allowed by the relay only for device-session.
      const operation = await digest('device-session');
      const { account, id } = this.session;
      const { nonce } = await api('/api/v2/challenge', { account, id, operation });
      await api('/api/v2/session/device', { account, id, nonce,
        proof: await sign(requestText(account, id, nonce, operation), this.session.signing) });
      // The relay's directory must be exactly the account the user approved.
      const directory = await this.operation('directory', account);
      check(await hash(genesisText(directory.genesis)) === verified.genesisDigest,
        'Каталог сервера не совпадает с подтверждённым аккаунтом');
      const own = await this.verifyDirectory(directory, null);
      check(own.history.at(-1).devices.some(d => d.id === this.session.id), 'Устройство отсутствует в каталоге сервера');
      this.revision = 0;
      await this.save({ own, contacts: {}, messages: [], outbox: [], pendingAck: [], registered: true });
      return { account, revision: own.checkpoint.revision };
    });
  }
  // ── Восстановление с recovery-пакетом (PRF_RECOVERY_BLOCKER §3) ─────────────
  // Все устройства аккаунта утрачены. Старые ключи устройства НЕ возвращаются:
  // создаётся новый vault, независимый recovery-ключ из пакета открывает
  // короткоживущую recovery-сессию, ростер заменяется манифестом signer:'recovery'
  // только с новым устройством, затем открывается обычная device-сессия.
  // Локальная фиксация — только после полного успеха на сервере: прерванная
  // попытка не оставляет ключей без состояния, повтор создаёт новые ключи.
  async recoverWithBackup(pkg, recoveryPhrase, { passphrase, binding }, onStep = () => {}) {
    return this.exclusive(async () => {
      check(navigator.onLine, 'Нет сети');
      const backup = pkg?.backup, genesis = pkg?.genesis;
      check(backup && genesis && typeof genesis === 'object' && !Array.isArray(genesis),
        'Неверный формат recovery-пакета');
      const account = genesis.account;
      check(typeof account === 'string' && /^[a-z0-9_]{3,32}$/.test(account),
        'Неверный аккаунт в recovery-пакете');
      // 1) Recovery-ключ: фраза расшифровывает пакет, привязанный к точному genesis.
      onStep('unlock');
      const recovery = await c.unlockRecoveryBackup(backup, recoveryPhrase, genesis);
      // 2) Новый vault с НОВЫМИ ключами устройства; формат vault не менялся.
      onStep('keys');
      const vault = await c.createVault(account, passphrase);
      if (binding) vault.binding = binding;
      const session = await c.unlockVault(vault, passphrase);
      // 3) Recovery-сессия: challenge → подпись recovery-ключом, привязанная к
      // genesisDigest, → вход. Сервер сверяет принесённый genesis с хранимым.
      onStep('session');
      const { nonce } = await api('/api/v2/session/recovery-challenge', { account });
      const operation = await digest('recovery-session', await hash(genesisText(genesis)));
      await api('/api/v2/session/recovery', { account, genesis, nonce,
        proof: await sign(requestText(account, 'primary', nonce, operation), recovery.signing) });
      // 4) Каталог через op directory: recovery-сессия разрешает только его и install.
      const directory = await api('/api/v2/operation',
        { op: 'directory', body: account, auth: { account } });
      check(await hash(genesisText(directory.genesis)) === await hash(genesisText(genesis)),
        'Genesis digest mismatch');
      // 5) Манифест revision+1 signer:'recovery': ростер только из нового устройства,
      // старые retire-ятся сервером. Possession proof — challenge-bound v2 с
      // self-generated challenge (как при обычном pairing, доверенное устройство не нужно).
      onStep('install');
      const manifest = await c.approveDevices(genesis, directory.history, [c.descriptor(vault)], recovery);
      const offer = await buildPairingOffer({ account, device: c.descriptor(vault),
        signing: session.signing, challenge: createPairingChallenge().nonce });
      const proofs = [{ id: offer.device.id, nonce: offer.nonce, expiresAt: offer.expiresAt,
        challenge: offer.challenge, pairingVersion: 2, signature: offer.signature }];
      await api('/api/v2/operation', { op: 'install', body: { manifest, proofs }, auth: { account } });
      // 6) Bootstrap обычной device-сессии нового устройства (sessionless challenge).
      onStep('bootstrap');
      const devOp = await digest('device-session');
      const { nonce: deviceNonce } = await api('/api/v2/challenge',
        { account, id: session.id, operation: devOp });
      await api('/api/v2/session/device', { account, id: session.id, nonce: deviceNonce,
        proof: await sign(requestText(account, session.id, deviceNonce, devOp), session.signing) });
      // 7) Каталог уже device-сессией: полная проверка цепочки, genesis и ростера.
      this.vault = vault; this.session = session;
      const fresh = await this.operation('directory', account);
      check(await hash(genesisText(fresh.genesis)) === await hash(genesisText(genesis)),
        'Каталог сервера не совпадает с recovery-пакетом');
      const own = await this.verifyDirectory(fresh, null);
      check(own.history.at(-1).devices.some(d => d.id === session.id),
        'Устройство отсутствует в каталоге сервера');
      // 8) Локальная фиксация после успеха: ключи + состояние. Recovery-пакет
      // сохраняется в состоянии — он по-прежнему действует (genesis неизменяем).
      await c.saveVault(vault);
      this.revision = 0;
      await this.save({ own, contacts: {}, messages: [], outbox: [], pendingAck: [],
        registered: true, backup });
      return { account, revision: own.checkpoint.revision };
    });
  }
  // Unlock for both normal and pending-pairing sessions: a vault without a
  // committed state is a pairing in progress, not a lost identity.
  async loadForPairing(vault, passphrase) {
    this.vault = vault;
    this.session = await c.unlockVault(vault, passphrase);
    const saved = await readState(this.session);
    this.revision = saved.revision;
    this.state = saved.value;
    this.changed();
    return { pending: !saved.value };
  }
  // Доставка outbox на сервер. 400/409 (конфликт/откат) переводят сообщение
  // в 'blocked'; прочие ошибки прерывают цикл: после неоднозначной отправки
  // ciphertext никогда не пересоздаётся, чтобы не задвоить сообщение.
  async flush(limit = Infinity) {
    let rejection;
    let accepted = 0, next;
    const textRefs = new Set(this.state.messages.filter(item => !item.chunkRefs).map(item => item.ref));
    const pending = [...this.state.outbox].sort((a, b) => Number(textRefs.has(ref(b))) - Number(textRefs.has(ref(a))));
    for (let i = 0; i < pending.length; i++) {
      const message = pending[i];
      if (accepted >= limit) break;
      if ((this.queueRetryAt.get(message.to) ?? 0) > Date.now()) continue;
      this.queueRetryAt.delete(message.to);
      try {
        let batch = [message];
        if (!textRefs.has(ref(message))) {
          let size = JSON.stringify(message).length;
          for (let j = i + 1; j < pending.length && batch.length < Math.min(SEND_BATCH_LIMIT, limit - accepted); j++) {
            const candidate = pending[j];
            if (candidate.to !== message.to || textRefs.has(ref(candidate))) break;
            size += JSON.stringify(candidate).length + 1;
            if (size > SEND_BATCH_BYTES) break;
            batch.push(candidate);
          }
        }
        if (batch.length > 1) {
          try { await this.operation('send.batch', batch); }
          catch (error) {
            // A rejected batch changes nothing. Try the front message alone
            // so the remaining queue space can still be used.
            if (![400, 409, 413].includes(error.status)) throw error;
            batch = [message];
            await this.operation('send', message);
          }
        } else await this.operation('send', message);
        next ??= structuredClone(this.state);
        i += batch.length - 1;
        accepted += batch.length;
        const acceptedRefs = new Set(batch.map(ref));
        next.outbox = next.outbox.filter(m => !acceptedRefs.has(ref(m)));
        // Агрегация media-статусов: у собранной записи нет собственного конверта,
        // её 'accepted' выводится из того, что все чанки покинули outbox.
        // Media chunk messages have no text record; the assembled display
        // record aggregates their statuses instead: it turns accepted once
        // every chunk left the outbox (relay acceptance, same as text).
        const queuedRefs = new Set(next.outbox.map(ref));
        for (const record of next.messages) {
          if (acceptedRefs.has(record.ref) ||
              (record.chunkRefs?.some(r => acceptedRefs.has(r)) && record.chunkRefs.every(r => !queuedRefs.has(r)))) {
            record.status = 'accepted';
          }
        }
      } catch (error) {
        if (error.message === 'device_queue_full') {
          this.queueRetryAt.set(message.to, Date.now() + 30000);
          rejection = error;
          continue;
        }
        if (error.status === 400 || error.status === 409) {
          const find = state => state.messages.find(m => m.ref === ref(message) || m.chunkRefs?.includes(ref(message)));
          const record = find(next ?? this.state);
          if (record && record.status !== 'blocked') {
            next ??= structuredClone(this.state);
            find(next).status = 'blocked';
          }
          rejection = error; continue;
        }
        // Never replace/re-encrypt a message after ambiguous acceptance.
        rejection = error;
        break;
      }
    }
    if (next) await this.save(next);
    if (accepted > 0 && this.state.outbox.length) this.scheduleSync();
    if (rejection) throw rejection;
  }
  // Полный цикл синхронизации: продление своей директории, доставка outbox,
  // разбор входящих пакетов (проверка подписей и цепочек обеих сторон,
  // сборка media-частей, tombstones отзыва), коммит состояния ДО отправки
  // ACK (иначе сбой потерял бы сообщения), затем пачки ACK и запрос статусов.
  sync() {
    return this.exclusive(async () => {
      if (this.stopped || !this.session || !this.state.registered || !navigator.onLine) return;
      try {
        await this.refreshOwn();
        // Free incoming queue space before retrying throttled peers, while
        // keeping normal sends and receipts in the same synchronization cycle.
        const inboxFirst = [...this.queueRetryAt.values()].some(at => at > Date.now());
        let sendError;
        if (!inboxFirst) {
          try { await this.flush(SEND_BATCH_LIMIT); } catch (error) { sendError = error; }
        }
        const bundles = await this.operation('fetch');
        let next = bundles.length ? structuredClone(this.state) : this.state;
        this.unverified = [];
        if (bundles.length) next.parts ??= {};
        for (const bundle of bundles) {
          const m = bundle.message, peer = m.from === this.session.account ? m.to : m.from;
          if (!contact(next, peer) && m.from !== m.to) {
            // TOFU для входящих: неизвестный отправитель закрепляется автоматически
            // (цепь проверяется от genesis), чтобы ответ не требовал ручной сверки.
            // Сбой проверки — честный пропуск сообщения, как раньше.
            try {
              const directory = await this.verifyDirectory(await this.operation('directory', peer), null);
              check(directory.genesis.account === peer, 'Сервер вернул другой аккаунт');
              putContact(next, peer, { ...directory, trust: 'tofu' });
            } catch { this.unverified.push(peer); continue; }
          }
          for (const [account, history] of [[m.from, bundle.senderHistory], [m.to, bundle.recipientHistory]]) {
            const own = account === this.session.account, pinned = own ? next.own : contact(next, account);
            const verified = await this.verifyDirectory({ ...pinned, history }, pinned);
            if (own) next.own = verified; else putContact(next, account, verified);
          }
          const payload = await c.openMessage(bundle, this.session, this.trust(m.from, m.to, next));
          const decoded = decodePayload(payload);
          if (decoded.media) {
            // Media chunk (contract C4): stage parts, assemble when complete;
            // every chunk ref is ACKed exactly like a text message.
            const slot = next.parts[decoded.media.id] ??= {
              mime: decoded.media.mime, total: decoded.media.total,
              from: m.from, to: m.to, createdAt: m.createdAt, chunks: {} };
            slot.chunks[decoded.media.index] = decoded.media.chunk;
            if (Object.keys(slot.chunks).length === slot.total) {
              const ordered = [];
              for (let index = 0; index < slot.total; index++) {
                const chunk = slot.chunks[index];
                check(typeof chunk === 'string', 'Потерян фрагмент изображения');
                ordered.push(chunk);
              }
              const bytes = new Uint8Array(ordered.reduce((sum, part) => sum + Math.floor(atob(part).length), 0));
              let position = 0;
              for (const part of ordered) {
                const raw = Uint8Array.from(atob(part), ch => ch.charCodeAt(0));
                bytes.set(raw, position); position += raw.length;
              }
              if (!next.messages.some(item => item.ref === `media:${decoded.media.id}`)) {
                next.messages.push({ ref: `media:${decoded.media.id}`,
                  media: { mime: slot.mime, data: b64(bytes) },
                  from: slot.from, to: slot.to, createdAt: slot.createdAt,
                  status: slot.from === this.session.account ? 'accepted' : 'received', devices: [] });
              }
              delete next.parts[decoded.media.id];
            }
            if (!next.pendingAck.includes(ref(m))) next.pendingAck.push(ref(m));
            continue;
          }
          if (!next.messages.some(item => item.ref === ref(m))) next.messages.push({ ref: ref(m), from: m.from, to: m.to,
            text: decoded.text, reply: decoded.reply, createdAt: m.createdAt,
            status: m.from === this.session.account ? 'accepted' : 'received', devices: [] });
          if (!next.pendingAck.includes(ref(m))) next.pendingAck.push(ref(m));
        }
        // Tombstones (contract C3): hide retracted messages behind a signed
        // cursor; only participant tombstones are ever returned by the relay.
        const retractionCursor = next.retractionSince ?? 0;
        const tombstones = await this.operation('retractions', { since: retractionCursor });
        if (tombstones.retractions?.length) {
          if (next === this.state) next = structuredClone(this.state);
          for (const tombstone of tombstones.retractions) {
            next.messages = next.messages.filter(item => item.ref !== tombstone.ref);
            next.outbox = next.outbox.filter(out => ref(out) !== tombstone.ref);
          }
          next.retractionSince = Math.max(retractionCursor,
            ...tombstones.retractions.map(item => item.deletedAt));
        }
        // Local ciphertext/history + replay IDs + checkpoints committed BEFORE ACK.
        if (next !== this.state) await this.save(next);
        while (this.state.pendingAck.length) {
          const batch = this.state.pendingAck.slice(0, 200);
          await this.operation('ack', batch);
          const committed = structuredClone(this.state);
          committed.pendingAck = committed.pendingAck.filter(ref => !batch.includes(ref)); await this.save(committed);
        }
        if (inboxFirst) {
          try { await this.flush(SEND_BATCH_LIMIT); } catch (error) { sendError = error; }
        }
        await this.refreshDelivery();
        if (sendError) throw sendError;
        this.lastError = ''; this.changed();
      } catch (error) { this.lastError = error.message; this.changed(); throw error; }
    });
  }
  async refreshDelivery() {
    const sent = this.state.messages.filter(item => item.from === this.session.account);
    const text = sent.filter(item => !item.chunkRefs && item.status !== 'queued' &&
      !(item.devices?.length && item.devices.every(device => device.readAt)));
    const media = sent.filter(item => item.chunkRefs?.length);
    // One signed request per batch of refs, including refs from different photos.
    const refs = [...new Set([...text.map(item => item.ref), ...media.flatMap(item => item.chunkRefs)])];
    if (!refs.length) return;
    const statuses = new Map();
    for (let index = 0; index < refs.length; index += 200) {
      const batch = await this.operation('status', refs.slice(index, index + 200));
      for (const [ref, devices] of Object.entries(batch)) statuses.set(ref, devices);
    }
    const changed = new Map();
    for (const item of [...text, ...media]) {
      const updates = (item.chunkRefs || [item.ref]).flatMap(ref => statuses.get(ref) || []);
      // Expired relay receipts or a partial status response cannot undo
      // confirmed progress already stored in this vault.
      const previous = item.devices || [];
      const devices = mergeDeviceProgress(previous, updates);
      if (JSON.stringify(devices) !== JSON.stringify(previous)) changed.set(item.ref, devices);
    }
    if (changed.size) {
      const messages = this.state.messages.map(item => changed.has(item.ref)
        ? { ...item, devices: changed.get(item.ref) } : item);
      await this.save({ ...this.state, messages });
    }
  }

  // Peer profile metadata (display name + avatar digest) fetched lazily and
  // cached in memory; the relay emits `profile` hints to invalidate.
  async peerMeta(account) {
    this.peerMetaCache ??= {};
    this.peerMetaDirty ??= new Set();
    const cached = this.peerMetaCache[account];
    if (cached && !this.peerMetaDirty.has(account) && Date.now() - cached.at < 300000) return cached;
    const data = await this.peerProfile(account);
    const meta = { name: data.displayName || '', digest: await hash(data.image || ''),
      frame: ['none', 'minimal', 'silver', 'graphite'].includes(data.frame) ? data.frame : 'none',
      image: typeof data.image === 'string' ? data.image : null,
      imageUrl: typeof data.imageUrl === 'string' ? data.imageUrl : null, at: Date.now() };
    this.peerMetaCache[account] = meta;
    this.peerMetaDirty.delete(account);
    return meta;
  }
  async peerAvatar(account) {
    const meta = await this.peerMeta(account);
    return { image: meta.image, imageUrl: meta.imageUrl, frame: meta.frame, name: meta.name };
  }
  scheduleSync() {
    if (this.stopped) return;
    this.syncRequested = true;
    if (this.syncTimer) return;
    // Socket hints can arrive in bursts (e.g. ACKs for photo chunks).
    const timer = setTimeout(async () => {
      this.syncRequested = false;
      try { await this.sync(); } catch { /* sync already reports failures */ }
      finally {
        if (this.syncTimer === timer) {
          this.syncTimer = null;
          if (this.syncRequested) this.scheduleSync();
        }
      }
    }, 1000);
    this.syncTimer = timer;
  }

  // Запуск клиента: первичная синхронизация, Socket.IO с доказательством
  // владения ключом в auth, переподключение с нарастающей задержкой,
  // периодический sync и реакции на visibility/online/offline.
  async start() {
    this.stopped = false;
    this.typingUntil = {};
    this.presence = {};
    this.watching = new Set();
    // Install reconnect handlers even when the first HTTP request cannot run.
    // This is essential after opening the PWA from its offline cache.
    try { if (navigator.onLine) await this.exclusive(() => this.refreshOwn()); }
    catch (error) { this.lastError = error.message; }
    this.socket = window.io({ autoConnect: false, transports: ['websocket'],
      auth: callback => this.proof('socket').then(callback).catch(() => callback({})),
      reconnection: true, reconnectionDelay: 1000, reconnectionDelayMax: 10000 });
    this.socket.on('connect', () => {
      this.connected = true;
      for (const peer of this.watching || []) this.socket.emit('watch', { peer });
      this.changed(); this.sync().catch(() => {});
    });
    this.socket.on('disconnect', () => { this.connected = false; this.changed(); });
    this.socket.on('connect_error', error => {
      this.connected = false; this.lastSocketError = error?.message || 'connect_error'; this.changed();
    });
    for (const event of ['inbox', 'receipts', 'retracted']) this.socket.on(event, () => this.scheduleSync());
    // Typing/presence (contract C2) and profile hints (B1) are hints only.
    this.socket.on('typing', data => {
      if (typeof data?.account !== 'string') return;
      this.typingUntil[data.account] = data.until; this.changed();
    });
    this.socket.on('presence', data => {
      if (typeof data?.account !== 'string') return;
      this.presence[data.account] = { online: Boolean(data.online), lastSeen: Number(data.lastSeen) || 0 };
      this.changed();
    });
    this.socket.on('profile', data => {
      this.peerMetaDirty ??= new Set();
      if (typeof data?.account === 'string') this.peerMetaDirty.add(data.account);
      this.changed();
      if (data?.account === this.session.account) this.loadProfile().catch(() => {});
    });
    if (navigator.onLine) this.socket.connect();
    this.timer = setInterval(() => this.scheduleSync(), 15000);
    document.addEventListener('visibilitychange', this.foreground); window.addEventListener('online', this.online);
    window.addEventListener('offline', this.offline);
    document.addEventListener('visibilitychange', this.hidden); window.addEventListener('pagehide', this.persistNow);
    await this.sync();
  }
  // Web Push (contract C6): wake-only notifications, never message content.
  // Chat fully works without push; every failure surfaces honestly.
  pushSupported() {
    return typeof navigator !== 'undefined' && 'serviceWorker' in navigator &&
      typeof window !== 'undefined' && 'PushManager' in window && window.isSecureContext;
  }
  pushStandalone() {
    return navigator.standalone === true ||
      (typeof window.matchMedia === 'function' && window.matchMedia('(display-mode: standalone)').matches);
  }
  async pushStatus() {
    if (!this.pushSupported()) return { supported: false, subscribed: false };
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    return { supported: true, subscribed: !!sub, permission: Notification.permission,
      standalone: this.pushStandalone() };
  }
  async enablePush() {
    check(this.pushSupported(), 'Push не поддерживается этим браузером. Чат работает без уведомлений.');
    if (/iPhone|iPad|iPod/.test(navigator.userAgent) && !this.pushStandalone()) {
      throw Error('На iPhone push работает только в установленном приложении (iOS 16.4+): Safari → Поделиться → На экран Домой.');
    }
    // Must stay within the user gesture: requestPermission before any await.
    const permission = await Notification.requestPermission();
    check(permission === 'granted', 'Уведомления запрещены. Чат работает без них; разрешите уведомления в настройках браузера.');
    const sessionInfo = await api('/api/session');
    check(sessionInfo.vapidPublicKey, 'Сервер не настроил Web Push (VAPID). Обратитесь к оператору.');
    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if (!sub) {
      sub = await reg.pushManager.subscribe({ userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(sessionInfo.vapidPublicKey) });
    }
    await this.operation('push.subscribe', { endpoint: sub.endpoint,
      keys: { p256dh: pushKeyB64Url(sub, 'p256dh'), auth: pushKeyB64Url(sub, 'auth') } });
    try { localStorage.setItem(`shade-push:${this.session.account}`, 'on'); } catch { /* optional */ }
    return { subscribed: true };
  }
  async disablePush() {
    try {
      if (this.pushSupported()) {
        const reg = await navigator.serviceWorker.ready;
        const sub = await reg.pushManager.getSubscription();
        if (sub) await sub.unsubscribe();
      }
    } catch { /* browser-side cleanup is best-effort */ }
    try { await this.operation('push.unsubscribe', null); } catch { /* device may be revoked already */ }
    try { localStorage.removeItem(`shade-push:${this.session.account}`); } catch { /* optional */ }
    return { subscribed: false };
  }
  // Silent re-subscription after unlock when the user previously enabled push
  // (permission already granted; no gesture needed). Never blocks the chat.
  async restorePush() {
    try {
      if (!this.pushSupported() || Notification.permission !== 'granted') return;
      if (localStorage.getItem(`shade-push:${this.session.account}`) !== 'on') return;
      const sessionInfo = await api('/api/session');
      if (!sessionInfo.vapidPublicKey) return;
      const reg = await navigator.serviceWorker.ready;
      let sub = await reg.pushManager.getSubscription();
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(sessionInfo.vapidPublicKey) });
      await this.operation('push.subscribe', { endpoint: sub.endpoint,
        keys: { p256dh: pushKeyB64Url(sub, 'p256dh'), auth: pushKeyB64Url(sub, 'auth') } });
    } catch { /* push is optional; chat works without it */ }
  }
  // Остановка: сокет, таймер и обработчики окна снимаются.
  stop() {
    this.stopped = true; this.socket?.disconnect(); clearInterval(this.timer);
    clearTimeout(this.syncTimer); this.syncTimer = null; this.syncRequested = false;
    document.removeEventListener('visibilitychange', this.foreground); window.removeEventListener('online', this.online);
    window.removeEventListener('offline', this.offline);
    document.removeEventListener('visibilitychange', this.hidden); window.removeEventListener('pagehide', this.persistNow);
  }
}

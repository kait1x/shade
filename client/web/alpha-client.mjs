import * as c from './device_crypto.mjs';
import { check, hash, sign, requestText, messageText, verifyHistory, genesisText } from './protocol/device-v2.mjs';
import { readState, writeState } from './alpha-storage.mjs';

export const ref = m => `${m.from}:${m.deviceId}:${m.id}`;
export const digest = (op, body = null) => hash(JSON.stringify([op, body]));
// Alpha wire payload agreement (opaque to the signed device-v2 envelope):
// plain text stays plain text; a reply adds {"shade":1,"t","r":{ref,from,text}}.
// Old histories without the marker keep rendering as plain text.
const REPLY_PREVIEW_LIMIT = 2000;
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
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) &&
      parsed.shade === 1 && typeof parsed.t === 'string' &&
      (parsed.r === null || parsed.r === undefined || (typeof parsed.r === 'object' &&
        typeof parsed.r.ref === 'string' && typeof parsed.r.from === 'string' &&
        typeof parsed.r.text === 'string'))) {
      return { text: parsed.t, reply: parsed.r ? { ref: parsed.r.ref, from: parsed.r.from,
        text: parsed.r.text } : null };
    }
  } catch { /* JSON-like plain text renders unchanged. */ }
  return { text: payload, reply: null };
}
const contact = (state, account) => Object.hasOwn(state.contacts, account) ? state.contacts[account] : null;
const putContact = (state, account, value) => Object.defineProperty(state.contacts, account,
  { value, enumerable: true, configurable: true, writable: true });
let pageController = new AbortController();
const departing = () => pageController.abort();
window.addEventListener('beforeunload', departing);
window.addEventListener('pagehide', departing);
window.addEventListener('pageshow', event => { if (event.persisted) pageController = new AbortController(); });
export async function api(route, body) {
  if (!navigator.onLine) throw Error('Нет сети');
  if (pageController.signal.aborted) throw Error('Страница закрывается');
  const controller = new AbortController(), abort = () => controller.abort();
  pageController.signal.addEventListener('abort', abort, {once:true});
  const timeout = setTimeout(abort, 20000);
  try {
    const response = await fetch(route, { credentials: 'same-origin', cache: 'no-store',
      ...(body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }),
      signal: controller.signal });
    let result;
    try { result = await response.json(); } catch { throw Error('Сервер недоступен. Попробуйте позже.'); }
    if (!response.ok) {
      const error = Error(result.error || 'Ошибка сервера'); error.status = response.status; throw error;
    }
    return result;
  } finally {
    clearTimeout(timeout); pageController.signal.removeEventListener('abort',abort);
  }
}
export class AlphaClient extends EventTarget {
  constructor() {
    super(); this.tail = Promise.resolve(); this.connected = false; this.stopped = false;
    this.foreground = () => { if (!document.hidden) this.sync().catch(() => {}); };
    this.online = () => { this.socket?.connect(); this.sync().catch(() => {}); };
    this.offline = () => { this.socket?.disconnect(); this.connected = false; this.changed(); };
  }
  changed() { this.dispatchEvent(new Event('change')); }
  exclusive(work) {
    const task = this.tail.then(work); this.tail = task.catch(() => {}); return task;
  }
  async save(next) {
    this.revision = await writeState(this.session, next, this.revision);
    this.state = next; this.changed();
  }
  async load(vault, passphrase) {
    this.vault = vault; this.session = await c.unlockVault(vault, passphrase);
    const saved = await readState(this.session);
    this.revision = saved.revision; this.state = saved.value;
    check(this.state, 'История устройства отсутствует. Новые ключи не созданы; нужно восстановление.');
    this.changed();
  }
  async prepare(account, passphrase, recoveryPhrase) {
    check(!(await c.listVaults()).some(v => v.account === account), 'На этом устройстве уже есть ключи аккаунта. Разблокируйте их.');
    const vault = await c.createVault(account, passphrase);
    const session = await c.unlockVault(vault, passphrase);
    let backup = await c.createRecoveryBackup(account, vault.signingKey, recoveryPhrase);
    const genesis = await c.createGenesis(vault, session, backup.publicKey);
    backup = await c.finalizeRecoveryBackup(backup, recoveryPhrase, genesis);
    const manifest = await c.approveDevices(genesis, [], [c.descriptor(vault)], session);
    this.vault = vault; this.session = session; this.revision = 0;
    // Identity and pending registration survive even if HTTP fails afterwards.
    await c.saveVault(vault);
    await this.save({ own: { root: vault.signingKey, genesis, history: [manifest] },
      contacts: {}, messages: [], outbox: [], pendingAck: [], backup, registered: false });
    return backup;
  }
  async register() {
    return this.exclusive(async () => {
      check(this.state && !this.state.registered, 'Регистрация уже завершена');
      const status = await api('/api/session');
      if (status.account === this.session.account) { await this.refreshOwn(); return; }
      check(!status.account, 'Google уже привязан к другому аккаунту');
      check(this.state.own.genesis.createdAt >= Date.now() - 240000,
        'Срок регистрации истёк. Обновите recovery-пакет ниже; ключи устройства сохранятся.');
      const manifest = await c.approveDevices(this.state.own.genesis, [], [c.descriptor(this.vault)], this.session);
      const pending = structuredClone(this.state); pending.own.history = [manifest]; await this.save(pending);
      await api('/api/v2/register', { genesis: this.state.own.genesis, manifest,
        proofs: [await c.pairingProof(this.vault, this.session)] });
      const next = structuredClone(this.state); next.own.history = [manifest]; next.registered = true;
      await this.save(next);
    });
  }
  async renewPending(recoveryPhrase) {
    return this.exclusive(async () => {
      check(!this.state.registered && !(await api('/api/session')).account, 'Аккаунт уже существует; genesis неизменяем');
      const genesis = await c.createGenesis(this.vault,this.session,this.state.own.genesis.recoveryKey);
      const backup = await c.rebindPendingBackup(this.state.backup,recoveryPhrase,this.state.own.genesis,genesis);
      const manifest = await c.approveDevices(genesis,[],[c.descriptor(this.vault)],this.session);
      const next = structuredClone(this.state); next.own = {root:this.vault.signingKey,genesis,history:[manifest]};
      next.backup = backup; await this.save(next);
    });
  }
  async proof(op, body = null) {
    const operation = await digest(op, op === 'send' ? await hash(messageText(body)) : body);
    const { account, id } = this.session;
    const { nonce } = await api('/api/v2/challenge', { account, id, operation });
    return { account, id, nonce, proof: await sign(requestText(account, id, nonce, operation), this.session.signing) };
  }
  async operation(op, body = null) {
    return api('/api/v2/operation', { op, body, auth: await this.proof(op, body) });
  }
  async verifyDirectory(directory, pinned) {
    check(directory?.genesis, 'Аккаунт ещё не поддерживает device-v2');
    if (pinned) check(await hash(genesisText(directory.genesis)) === pinned.checkpoint.genesisDigest &&
      directory.root === pinned.root, 'Ключи контакта изменились. Отправка заблокирована.');
    const checkpoint = await verifyHistory(directory.history, directory.root, pinned?.checkpoint, Date.now(), directory.genesis);
    return { ...directory, checkpoint };
  }
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
      await this.operation('install', { manifest }); directory.history.push(manifest);
    }
    const next = structuredClone(this.state); next.own = await this.verifyDirectory(directory, pinned); next.registered = true;
    await this.save(next);
  }
  async users() { return this.operation('users'); }
  async inspectContact(account) {
    const directory = await this.verifyDirectory(await this.operation('directory', account), contact(this.state, account));
    check(directory.genesis.account === account, 'Сервер вернул другой аккаунт');
    return directory;
  }
  async pinContact(account, expectedDigest) {
    return this.exclusive(async () => {
      const directory = await this.inspectContact(account);
      check(directory.checkpoint.genesisDigest === expectedDigest, 'Отпечаток изменился');
      const next = structuredClone(this.state); putContact(next, account, directory); await this.save(next);
    });
  }
  trust(from, to, state = this.state) {
    const directory = account => account === this.session.account ? state.own : contact(state, account);
    const sender = directory(from), recipient = directory(to);
    check(sender && recipient, 'Сначала сверьте отпечаток контакта');
    return { senderRoot: sender.root, recipientRoot: recipient.root,
      senderGenesis: sender.genesis, recipientGenesis: recipient.genesis,
      senderCheckpoint: sender.checkpoint, recipientCheckpoint: recipient.checkpoint };
  }
  async send(account, text, reply = null) {
    return this.exclusive(async () => {
      check(text.trim().length > 0, 'Введите сообщение');
      if (reply != null) check(reply.text.trim().length > 0, 'Некорректное сообщение для ответа');
      // Refresh directories while online; offline sends use a pinned, unexpired
      // roster. A stale signed outbox entry is retained and shown as blocked.
      if (navigator.onLine) {
        await this.refreshOwn();
        const next = structuredClone(this.state); putContact(next, account, await this.inspectContact(account)); await this.save(next);
      }
      const m = await c.sealMessage(reply ? encodePayload(text, reply) : text,
        this.state.own.history, contact(this.state, account)?.history,
        this.session, this.trust(this.session.account, account));
      const next = structuredClone(this.state);
      next.outbox.push(m); next.messages.push({ ref: ref(m), from: m.from, to: m.to, text, reply,
        createdAt: m.createdAt, status: 'queued', devices: [] });
      await this.save(next);
      if (navigator.onLine) {
        try { await this.flush(); } catch (error) { this.lastError = error.message; this.changed(); }
      }
      return m.id; // Local commit succeeded; keep retrying the exact ciphertext.
    });
  }
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
  async flush() {
    let rejection;
    for (const message of [...this.state.outbox]) {
      try {
        await this.operation('send', message);
        const next = structuredClone(this.state);
        next.outbox = next.outbox.filter(m => m.id !== message.id);
        next.messages.find(m => m.ref === ref(message)).status = 'accepted';
        await this.save(next);
      } catch (error) {
        if (error.status === 400 || error.status === 409) {
          const next = structuredClone(this.state);
          next.messages.find(m => m.ref === ref(message)).status = 'blocked'; await this.save(next);
          rejection = error; continue;
        }
        throw error; // Never replace/re-encrypt a message after ambiguous acceptance.
      }
    }
    if (rejection) throw rejection;
  }
  sync() {
    return this.exclusive(async () => {
      if (this.stopped || !this.session || !this.state.registered || !navigator.onLine) return;
      try {
        await this.refreshOwn();
        // Incoming fetch must continue even when an old outbox entry is blocked.
        let sendError;
        try { await this.flush(); } catch (error) { sendError = error; }
        const bundles = await this.operation('fetch');
        const next = structuredClone(this.state);
        this.unverified = [];
        for (const bundle of bundles) {
          const m = bundle.message, peer = m.from === this.session.account ? m.to : m.from;
          if (!contact(next, peer)) { this.unverified.push(peer); continue; }
          for (const [account, history] of [[m.from, bundle.senderHistory], [m.to, bundle.recipientHistory]]) {
            const own = account === this.session.account, pinned = own ? next.own : contact(next, account);
            const verified = await this.verifyDirectory({ ...pinned, history }, pinned);
            if (own) next.own = verified; else putContact(next, account, verified);
          }
          const payload = await c.openMessage(bundle, this.session, this.trust(m.from, m.to, next));
          const decoded = decodePayload(payload);
          if (!next.messages.some(item => item.ref === ref(m))) next.messages.push({ ref: ref(m), from: m.from, to: m.to,
            text: decoded.text, reply: decoded.reply, createdAt: m.createdAt,
            status: m.from === this.session.account ? 'accepted' : 'received', devices: [] });
          if (!next.pendingAck.includes(ref(m))) next.pendingAck.push(ref(m));
        }
        // Local ciphertext/history + replay IDs + checkpoints committed BEFORE ACK.
        await this.save(next);
        while (this.state.pendingAck.length) {
          const batch = this.state.pendingAck.slice(0, 200);
          await this.operation('ack', batch);
          const committed = structuredClone(this.state);
          committed.pendingAck = committed.pendingAck.filter(ref => !batch.includes(ref)); await this.save(committed);
        }
        const ownMessages = this.state.messages.filter(m => m.from === this.session.account && m.status !== 'queued');
        for (let index = 0; index < ownMessages.length; index += 200) {
          const statuses = await this.operation('status', ownMessages.slice(index, index + 200).map(m => m.ref));
          const committed = structuredClone(this.state);
          for (const item of committed.messages) if (statuses[item.ref]) item.devices = statuses[item.ref];
          await this.save(committed);
        }
        if (sendError) throw sendError;
        this.lastError = ''; this.changed();
      } catch (error) { this.lastError = error.message; this.changed(); throw error; }
    });
  }
  async start() {
    this.stopped = false;
    // Install reconnect handlers even when the first HTTP request cannot run.
    // This is essential after opening the PWA from its offline cache.
    try { if (navigator.onLine) await this.exclusive(() => this.refreshOwn()); }
    catch (error) { this.lastError = error.message; }
    this.socket = window.io({ autoConnect: false, transports: ['websocket'],
      auth: callback => this.proof('socket').then(callback).catch(() => callback({})),
      reconnection: true, reconnectionDelay: 1000, reconnectionDelayMax: 10000 });
    this.socket.on('connect', () => { this.connected = true; this.changed(); this.sync().catch(() => {}); });
    this.socket.on('disconnect', () => { this.connected = false; this.changed(); });
    this.socket.on('connect_error', () => { this.connected = false; this.changed(); });
    for (const event of ['inbox', 'receipts']) this.socket.on(event, () => this.sync().catch(() => {}));
    if (navigator.onLine) this.socket.connect();
    this.timer = setInterval(() => this.sync().catch(() => {}), 15000);
    document.addEventListener('visibilitychange', this.foreground); window.addEventListener('online', this.online);
    window.addEventListener('offline', this.offline);
    await this.sync();
  }
  stop() {
    this.stopped = true; this.socket?.disconnect(); clearInterval(this.timer);
    document.removeEventListener('visibilitychange', this.foreground); window.removeEventListener('online', this.online);
    window.removeEventListener('offline', this.offline);
  }
}

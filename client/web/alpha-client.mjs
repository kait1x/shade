import * as c from './device_crypto.mjs';
import { check, hash, sign, requestText, messageText, verifyHistory, genesisText } from './protocol/device-v2.mjs';
import { readState, writeState } from './alpha-storage.mjs';

// VAPID applicationServerKey conversion (base64url -> Uint8Array).
function urlBase64ToUint8Array(value) {
  const padding = '='.repeat((4 - value.length % 4) % 4);
  const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  return Uint8Array.from(raw, ch => ch.charCodeAt(0));
}
const pushKeyB64Url = (sub, name) => btoa(String.fromCharCode(...new Uint8Array(sub.getKey(name))))
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

export const ref = m => `${m.from}:${m.deviceId}:${m.id}`;
export const digest = (op, body = null) => hash(JSON.stringify([op, body]));
// Alpha wire payload agreement (opaque to the signed device-v2 envelope):
// plain text stays plain text; a reply adds {"shade":1,"t","r":{ref,from,text}};
// media chunks (contract C4) add {"shade":1,"m":{id,mime,index,total,chunk}}.
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
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && parsed.shade === 1) {
      if (parsed.m && typeof parsed.m === 'object' &&
        typeof parsed.m.id === 'string' && typeof parsed.m.mime === 'string' &&
        Number.isSafeInteger(parsed.m.index) && Number.isSafeInteger(parsed.m.total) &&
        typeof parsed.m.chunk === 'string') {
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
const contact = (state, account) => Object.hasOwn(state.contacts, account) ? state.contacts[account] : null;
const putContact = (state, account, value) => Object.defineProperty(state.contacts, account,
  { value, enumerable: true, configurable: true, writable: true });
let pageController = new AbortController();
const departing = () => pageController.abort();
window.addEventListener('beforeunload', departing);
window.addEventListener('pagehide', departing);
window.addEventListener('pageshow', event => { if (event.persisted) pageController = new AbortController(); });
export async function api(route, body, options = {}) {
  if (!navigator.onLine) throw Error('Нет сети');
  if (pageController.signal.aborted) throw Error('Страница закрывается');
  const controller = new AbortController(), abort = () => controller.abort();
  pageController.signal.addEventListener('abort', abort, {once:true});
  const timeout = setTimeout(abort, 20000);
  try {
    const hasBody = body !== undefined;
    const response = await fetch(route, { credentials: 'same-origin', cache: 'no-store',
      method: options.method || (hasBody ? 'POST' : 'GET'),
      headers: { ...(options.headers || {}), ...(hasBody ? { 'Content-Type': 'application/json' } : {}) },
      ...(hasBody ? { body: JSON.stringify(body) } : {}),
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
          // tail replay is idempotent (server contract B1).
          for (let offset = 0; offset < data.avatar.length; offset += 65536) {
            await this.adapterRequest('POST', '/profile/avatar/chunk', {
              uploadId, offset, total: data.avatar.length,
              chunk: data.avatar.slice(offset, offset + 65536), frame, revision });
          }
        }
        const committed = await this.adapterRequest('PUT', '/profile/avatar', {
          ...(uploadId ? { uploadId } : { image: data.avatar === undefined ? undefined : data.avatar }),
          frame, revision });
        revision = committed.revision;
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
      if (navigator.onLine) {
        try { await this.flush(); } catch (error) { this.lastError = error.message; this.changed(); }
      }
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
  // Media (contract C4): the agreed codec `m` inside the signed opaque
  // envelope — {"shade":1,"m":{id,mime,index,total,chunk}}, 32768 raw bytes
  // per chunk, EXIF-free bytes arrive from the shared editor pipeline. Each
  // chunk is a real signed E2EE message; the UI shows one assembled record.
  async sendMedia(account, imageBase64, mime = 'image/jpeg') {
    return this.exclusive(async () => {
      check(typeof imageBase64 === 'string' && imageBase64.length > 4, 'Не удалось прочитать изображение');
      const raw = Uint8Array.from(atob(imageBase64), ch => ch.charCodeAt(0));
      const total = Math.ceil(raw.length / 32768);
      check(raw.length >= 128 && raw.length <= 2097152, 'Изображение слишком большое');
      const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
        b => b.toString(16).padStart(2, '0')).join('');
      if (navigator.onLine) {
        await this.refreshOwn();
        if (account !== this.session.account) {
          const nx = structuredClone(this.state); putContact(nx, account, await this.inspectContact(account)); await this.save(nx);
        }
      }
      const next = structuredClone(this.state);
      const createdAt = Date.now();
      next.messages.push({ ref: `media:${id}`, media: { mime, data: imageBase64 },
        from: this.session.account, to: account, createdAt, status: 'queued',
        devices: [], chunkRefs: [] });
      await this.save(next);
      for (let index = 0; index < total; index++) {
        const slice = raw.subarray(index * 32768, Math.min((index + 1) * 32768, raw.length));
        let binary = '';
        for (const b of slice) binary += String.fromCharCode(b);
        const payload = JSON.stringify({ shade: 1, m: { id, mime, index, total, chunk: btoa(binary) } });
        const m = await c.sealMessage(payload, this.state.own.history,
          account === this.session.account ? this.state.own.history : contact(this.state, account)?.history,
          this.session, this.trust(this.session.account, account));
        const nx = structuredClone(this.state);
        nx.outbox.push(m);
        const display = nx.messages.find(item => item.ref === `media:${id}`);
        display.chunkRefs.push(ref(m));
        await this.save(nx);
        if (navigator.onLine) {
          try { await this.flush(); } catch (error) { this.lastError = error.message; this.changed(); }
        }
      }
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
  watchPeer(peer, watch) {
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
  async flush() {
    let rejection;
    for (const message of [...this.state.outbox]) {
      try {
        await this.operation('send', message);
        const next = structuredClone(this.state);
        next.outbox = next.outbox.filter(m => m.id !== message.id);
        // Media chunk messages have no text record; the assembled display
        // record aggregates their statuses instead.
        const record = next.messages.find(m => m.ref === ref(message));
        if (record) record.status = 'accepted';
        await this.save(next);
      } catch (error) {
        if (error.status === 400 || error.status === 409) {
          const next = structuredClone(this.state);
          const record = next.messages.find(m => m.ref === ref(message));
          if (record) record.status = 'blocked'; await this.save(next);
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
        next.parts ??= {};
        for (const bundle of bundles) {
          const m = bundle.message, peer = m.from === this.session.account ? m.to : m.from;
          if (!contact(next, peer) && m.from !== m.to) { this.unverified.push(peer); continue; }
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
              let binary = '';
              for (const b of bytes) binary += String.fromCharCode(b);
              if (!next.messages.some(item => item.ref === `media:${decoded.media.id}`)) {
                next.messages.push({ ref: `media:${decoded.media.id}`,
                  media: { mime: slot.mime, data: btoa(binary) },
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
          for (const tombstone of tombstones.retractions) {
            next.messages = next.messages.filter(item => item.ref !== tombstone.ref);
            next.outbox = next.outbox.filter(out => ref(out) !== tombstone.ref);
          }
          next.retractionSince = Math.max(retractionCursor,
            ...tombstones.retractions.map(item => item.deletedAt));
        }
        // Local ciphertext/history + replay IDs + checkpoints committed BEFORE ACK.
        await this.save(next);
        while (this.state.pendingAck.length) {
          const batch = this.state.pendingAck.slice(0, 200);
          await this.operation('ack', batch);
          const committed = structuredClone(this.state);
          committed.pendingAck = committed.pendingAck.filter(ref => !batch.includes(ref)); await this.save(committed);
        }
        // Sender-side delivery/read projection: media display records query
        // their chunk refs and aggregate per-device acknowledgements.
        const textMessages = this.state.messages.filter(m => m.from === this.session.account && m.status !== 'queued');
        const mediaRecords = this.state.messages.filter(m => m.from === this.session.account && m.chunkRefs?.length);
        for (let index = 0; index < textMessages.length; index += 200) {
          const statuses = await this.operation('status', textMessages.slice(index, index + 200).map(m => m.ref));
          const committed = structuredClone(this.state);
          for (const item of committed.messages) if (statuses[item.ref]) item.devices = statuses[item.ref];
          await this.save(committed);
        }
        for (const media of mediaRecords) {
          const statuses = await this.operation('status', media.chunkRefs);
          const merged = new Map();
          for (const ref of media.chunkRefs) {
            for (const device of statuses[ref] || []) {
              const current = merged.get(`${device.account}:${device.id}`) || device;
              merged.set(`${device.account}:${device.id}`, {
                ...current, acknowledgedAt: current.acknowledgedAt && device.acknowledgedAt
                  ? Math.max(current.acknowledgedAt, device.acknowledgedAt)
                  : (current.acknowledgedAt ?? device.acknowledgedAt ?? null),
                readAt: current.readAt && device.readAt
                  ? Math.max(current.readAt, device.readAt) : (current.readAt ?? device.readAt ?? null) });
            }
          }
          const committed = structuredClone(this.state);
          const display = committed.messages.find(item => item.ref === media.ref);
          if (display) display.devices = [...merged.values()];
          await this.save(committed);
        }
        if (sendError) throw sendError;
        this.lastError = ''; this.changed();
      } catch (error) { this.lastError = error.message; this.changed(); throw error; }
    });
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
  async start() {
    this.stopped = false;
    this.typingUntil = {};
    this.presence = {};
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
    for (const event of ['inbox', 'receipts', 'retracted']) this.socket.on(event, () => this.sync().catch(() => {}));
    // Typing/presence (contract C2) and profile hints (B1) are hints only.
    this.socket.on('typing', data => {
      if (typeof data?.account !== 'string') return;
      this.typingUntil[data.account] = data.until; this.changed();
    });
    this.socket.on('presence', data => {
      if (typeof data?.account !== 'string') return;
      this.presence[data.account] = Boolean(data.online); this.changed();
    });
    this.socket.on('profile', data => {
      this.peerMetaDirty ??= new Set();
      if (typeof data?.account === 'string') this.peerMetaDirty.add(data.account);
      this.changed();
      if (data?.account === this.session.account) this.loadProfile().catch(() => {});
    });
    if (navigator.onLine) this.socket.connect();
    this.timer = setInterval(() => this.sync().catch(() => {}), 15000);
    document.addEventListener('visibilitychange', this.foreground); window.addEventListener('online', this.online);
    window.addEventListener('offline', this.offline);
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
  stop() {
    this.stopped = true; this.socket?.disconnect(); clearInterval(this.timer);
    document.removeEventListener('visibilitychange', this.foreground); window.removeEventListener('online', this.online);
    window.removeEventListener('offline', this.offline);
  }
}

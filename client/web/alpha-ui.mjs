import { AlphaClient, api } from './alpha-client.mjs';
import { listVaults } from './device_crypto.mjs';
import { hash, genesisText } from './protocol/device-v2.mjs';

const root = document.querySelector('#root'), dialog = document.querySelector('#dialog');
const client = new AlphaClient();
// QA introspection: the page context can always reach whatever its own scripts
// hold; this only names the instance. CryptoKey material stays non-extractable.
window.__shadeClient = client;
const contact = account => client.state && Object.hasOwn(client.state.contacts, account) ? client.state.contacts[account] : null;
let selected = null, users = [], ready = false, actionTail = Promise.resolve(), noticeTimer, loggedIn = false;
function node(tag, text, className) { const n = document.createElement(tag); if (text !== undefined) n.textContent = text; if (className) n.className = className; return n; }
function notice(text) { const n = document.querySelector('#notice'); n.textContent = text; n.classList.add('visible'); clearTimeout(noticeTimer); noticeTimer = setTimeout(() => n.classList.remove('visible'), 9000); }
// Floating arrival toast for messages in chats that are not open, mirroring
// the Android in-app overlay. Clicking it opens that conversation.
let toastTimer;
function showToast(text, open) {
  const toast = document.querySelector('#toast');
  toast.textContent = text;
  toast.onclick = () => { hideToast(); open(); };
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(hideToast, 4000);
}
function hideToast() { clearTimeout(toastTimer); document.querySelector('#toast').hidden = true; }
const toastShown = new Map();
function announceIncoming() {
  if (!client.state || !client.session) return;
  let latest = null;
  for (const m of client.state.messages) {
    if (m.from === client.session.account || m.from === selected) continue;
    if (m.createdAt <= Math.max(ui.readUntil[m.from] ?? 0, toastShown.get(m.from) ?? 0)) continue;
    if (!latest || m.createdAt > latest.createdAt) latest = m;
  }
  if (!latest) return;
  toastShown.set(latest.from, latest.createdAt);
  showToast(`Новое сообщение от @${latest.from}`, () => {
    hideToast();
    selected = latest.from; ui.selected = selected; saveUi(); render();
    if (!contact(selected)) verifyContact(selected);
  });
}
const errors = { google_login_required: 'Сессия Google истекла. Войдите снова; ключи сохранены.',
  login_required: 'Сессия истекла. Войдите снова; ключи сохранены.',
  operation_rejected: 'Операция отклонена. Проверьте сеть, срок каталога и доступ устройства. Сообщение не отмечено доставленным.',
  account_requires_linking: 'Аккаунт уже существует. Нужна привязка доверенным устройством; новые ключи не назначены.' };
function action(work) {
  actionTail = actionTail.then(async () => {
    const buttons = [...root.querySelectorAll('button[type=submit]')]; buttons.forEach(b => b.disabled = true);
    try { await work(); } catch (error) { notice(errors[error.message] || error.message); }
    finally { buttons.forEach(b => b.disabled = false); }
  });
  return actionTail;
}
function showDialog(title, elements) {
  document.querySelector('#dialog-title').textContent = title;
  document.querySelector('#dialog-body').replaceChildren(...elements);
  if (!dialog.open) dialog.showModal();
}
function isStandalone() {
  return window.matchMedia('(display-mode: standalone)').matches ||
    window.matchMedia('(display-mode: window-controls-overlay)').matches ||
    navigator.standalone === true;
}
function installGuide() {
  if (isStandalone()) { notice('Shade уже установлен на этом устройстве.'); return; }
  if (deferredInstall) {
    const button = node('button', 'Установить', 'primary'); button.type = 'button';
    button.onclick = async () => {
      const event = deferredInstall; deferredInstall = null; dialog.close();
      event.prompt();
      const { outcome } = await event.userChoice;
      if (outcome === 'accepted') notice('Shade установлен.');
    };
    showDialog('Установить Shade', [node('p', 'Установить приложение Shade на это устройство?'), node('p', 'Ключи остаются в этом браузере. Не очищайте данные сайта. Перед установкой сохраните recovery-пакет. Установка PWA не переносит ключи из другого браузера.', 'muted'), button]);
    return;
  }
  showDialog('Установить Shade', [node('p', 'В Safari нажмите «Поделиться» → «На экран Домой» → «Добавить». Открывайте Shade с этой иконки.'), node('p', 'Ключи остаются в этом браузере. Не очищайте данные сайта. Перед установкой сохраните recovery-пакет. Установка PWA не переносит ключи из другого браузера.', 'muted')]);
}
// Chromium offers a real install flow; Safari needs the manual guide above.
let deferredInstall = null;
window.addEventListener('beforeinstallprompt', event => { event.preventDefault(); deferredInstall = event; });
window.addEventListener('appinstalled', () => { deferredInstall = null; notice('Shade установлен.'); });
function welcome(title, description) {
  const box = node('section', undefined, 'welcome'); box.append(node('h1', 'Shade'), node('p', 'WEB ALPHA 0.1', 'eyebrow'), node('h2', title), node('p', description, 'muted'));
  if (loggedIn) {
    const change = node('button', 'Сменить Google-аккаунт'); change.type = 'button';
    change.onclick = () => action(async () => { await client.disablePush().catch(() => {}); client.stop(); await api('/api/logout', {}); location.href = '/auth/google'; }); box.append(change);
  }
  root.replaceChildren(box); return box;
}
function input(form, title, name, type = 'text', minLength = 0) {
  const label = node('label', title), field = node('input'); field.name = name; field.type = type; field.required = true;
  if (minLength) field.minLength = minLength;
  field.autocomplete = type === 'password' ? 'current-password' : 'off'; label.append(field); form.append(label); return field;
}
function submit(form, text) { const button = node('button', text, 'primary'); button.type = 'submit'; form.append(button); }
function downloadBackup() {
  const blob = new Blob([JSON.stringify({ backup: client.state.backup, genesis: client.state.own.genesis }, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob), anchor = node('a'); anchor.href = url; anchor.download = `shade-recovery-${client.session.account}.json`; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 10000);
}
async function backupStep() {
  const box = welcome('Сохраните recovery-пакет', 'Пакет зашифрован отдельной фразой. Сохраните файл вне этого устройства и запишите фразу отдельно. Без пакета или другого доверенного устройства потерянные ключи не восстановить.');
  const download = node('button', 'Скачать recovery-пакет'); download.onclick = downloadBackup; box.append(download);
  const form = node('form'), checkLabel = node('label', 'Я сохранил пакет и recovery-фразу отдельно'), checkbox = node('input'); checkbox.type = 'checkbox'; checkbox.required = true; checkLabel.prepend(checkbox); form.append(checkLabel); submit(form, 'Завершить регистрацию'); box.append(form);
  form.onsubmit = event => { event.preventDefault(); action(async () => { await client.register(); await openApp(); }); };
  const renew = node('details'); renew.append(node('summary','Если регистрация прервалась или прошло больше 4 минут'));
  renew.append(node('p','Обновите пакет и скачайте его заново. Ключи устройства и recovery-ключ сохранятся. Это доступно только до регистрации аккаунта.','muted'));
  const renewForm = node('form'), recovery = input(renewForm,'Recovery-фраза','recovery','password',24); submit(renewForm,'Обновить пакет'); renew.append(renewForm); box.append(renew);
  renewForm.onsubmit = event => { event.preventDefault(); action(async () => { await client.renewPending(recovery.value); recovery.value = ''; await backupStep(); }); };
}
// This module still owns auth and AlphaClient. Flutter receives a read-only
// presentation projection; it never receives vaults, keys, backups or tokens.
let ui = { selected: null, positions: {}, readUntil: {} }, uiStorage;
function saveUi() { try { sessionStorage.setItem(uiStorage, JSON.stringify(ui)); } catch { /* Private browsing may deny UI preferences. */ } }
function updateViewport() {
  const viewport = window.visualViewport;
  document.documentElement.style.setProperty('--shade-height', `${viewport?.height || innerHeight}px`);
  document.documentElement.style.setProperty('--shade-top', `${viewport?.offsetTop || 0}px`);
}
window.visualViewport?.addEventListener('resize', updateViewport);
window.visualViewport?.addEventListener('scroll', updateViewport);
window.addEventListener('resize', updateViewport);
function render() {
  if (!ready || !window.shadeReceive) return;
  const accounts = [...new Set([...users.map(u => u.account), ...Object.keys(client.state.contacts),
    ...client.state.messages.flatMap(m => [m.from,m.to]), ...(client.unverified || [])])]
    .filter(a => a !== client.session.account);
  const connection = !navigator.onLine ? 'Нет сети · история сохранена' : client.lastError ?
    (errors[client.lastError] || 'Ошибка синхронизации · повтор через 15 секунд') :
    client.connected ? 'Подключено · E2EE' : 'Переподключение…';
  window.__lastProjection = { messages: (client.state.messages || []).length,
    firstMessage: client.state.messages?.[0] || null,
    selected, contacts: Object.keys(client.state.contacts || {}) };
  // Peer display names and avatar digests arrive through the v2 profile API;
  // metadata is fetched in the background once per account and cached.
  const meta = account => {
    const cached = client.peerMetaCache?.[account];
    if (!cached) {
      client.peerMeta(account).then(() => render()).catch(() => {});
      return {};
    }
    return { name: cached.name, avatarDigest: cached.digest, frame: cached.frame };
  };
  window.shadeReceive(JSON.stringify({
    account: client.session.account, selected, connection, connected: client.connected && navigator.onLine && !client.lastError,
    peers: [
      { account: client.session.account, favorites: true, pinned: true,
        name: 'Избранное', avatarDigest: client.state.profile?.avatarDigest || '' },
      ...accounts.map(account => ({ account, pinned: !!contact(account),
        unverified: (client.unverified || []).includes(account), ...meta(account) })),
    ],
    messages: client.state.messages.map(({ref,from,to,text,reply,createdAt,status,devices,media,readAt,chunkRefs}) =>
      ({ref,from,to,text,reply,createdAt,status,devices,media,readAt,
        chunkRefs: media && chunkRefs ? chunkRefs.length : undefined})),
    notes: client.state.notes ?? {},
    profile: {
      displayName: client.state.profile?.displayName || '',
      frame: client.state.profile?.avatarFrame || 'none',
      digest: client.state.profile?.avatarDigest || '',
      revision: client.state.profile?.avatarRevision || 0,
    },
    typing: client.typingUntil || {},
    presence: client.presence || {},
    devices: (client.state.own.history.at(-1)?.devices || []).map(({id}) => ({id, current:id === client.session.id})),
    positions: ui.positions, readUntil: ui.readUntil,
  }));
  announceIncoming();
}
async function openApp() {
  ready = true;
  uiStorage = `shade-ui:${client.vault.id}`;
  try {
    const saved = JSON.parse(sessionStorage.getItem(uiStorage));
    if (saved && typeof saved === 'object') ui = { selected: typeof saved.selected === 'string' ? saved.selected : null,
      positions: saved.positions || {}, readUntil: saved.readUntil || {} };
  } catch { /* UI preferences never prevent unlocking encrypted history. */ }
  selected = ui.selected;
  root.replaceChildren(node('div', undefined, 'flutter-host'));
  root.firstChild.id = 'flutter-host';
  const loading = node('p','Загрузка интерфейса Shade…','flutter-loading'); root.append(loading);
  document.body.classList.add('flutter-ready'); updateViewport();
  window.shadeAction = async (kind, raw = '{}') => {
    try {
      const data = JSON.parse(raw);
      switch (kind) {
        case 'ready': loading.remove(); render(); break;
        case 'select':
          selected = data.account; ui.selected = selected; saveUi(); render();
          client.watchPeer(selected, true);
          client.loadProfile().catch(() => {});
          if (!contact(selected) && selected !== client.session.account) verifyContact(selected); break;
        case 'back': selected = null; ui.selected = null; saveUi(); render();
          if (data.account) client.watchPeer(data.account, false); break;
        case 'typing': client.sendTyping(data.account); break;
        case 'read': {
          if (document.hidden || selected !== data.account) break;
          const previous = ui.readUntil[data.account] || 0;
          if (data.until > previous) {
            ui.readUntil[data.account] = data.until; saveUi();
            // Read-ACK (contract C5): the relay op runs on refs the read mark
            // covers; failures surface honestly without breaking the UI.
            const refs = client.state.messages
              .filter(m => m.from === data.account && m.createdAt <= data.until &&
                !m.readAt && m.status === 'received')
              .slice(-200).map(m => m.ref);
            if (refs.length) client.markRead(data.account, refs)
              .catch(e => notice(errors[e.message] || e.message));
            render();
          } break;
        }
        case 'position': ui.positions[data.account] = {offset:Math.max(0,data.offset),bottom:!!data.bottom}; saveUi(); break;
        case 'send': await client.send(data.account, data.text, data.reply || null); client.sync().catch(e => notice(errors[e.message] || e.message)); break;
        case 'sendMedia': await client.sendMedia(data.account, data.image, data.mime || 'image/jpeg'); client.sync().catch(e => notice(errors[e.message] || e.message)); break;
        case 'deleteLocal': await client.deleteLocal(data.ref); break;
        case 'retract': await client.retract(data.ref); break;
        case 'sync': await client.sync(); break;
        case 'note': await client.saveNote(data.account, data.text); break;
        case 'profile.save': await client.saveProfile(data); break;
        // The avatar image travels on demand, not in every projection.
        case 'profile.avatar': return JSON.stringify({ ok: true, data: { image: client.state.profile?.avatarImage || null } });
        case 'peer.avatar': return JSON.stringify({ ok: true, data: await client.peerAvatar(data.account) });
        case 'stickers.load': return JSON.stringify({ ok: true, data: await client.loadStickers(data.name, data.owner === true) });
        case 'stickers.save': return JSON.stringify({ ok: true, data: await client.saveStickers(data.revision, data.wall) });
        case 'stickers.gift': return JSON.stringify({ ok: true, data: await client.giftSticker(data.to, data.art, data.note, data.requestId) });
        case 'devices.revoke': await client.revokeDevice(data.id); break;
        case 'push.toggle': {
          // Push is optional: failures surface as an honest notice, never as
          // an unhandled action error (the chat must keep working).
          try {
            const status = await client.pushStatus();
            if (status.subscribed) { await client.disablePush(); notice('Уведомления выключены.'); }
            else { await client.enablePush(); notice('Уведомления включены · только сигнал, без текста сообщений.'); }
          } catch (e) { notice(errors[e.message] || e.message); }
          break;
        }
        case 'verify': verifyContact(data.account); break;
        case 'refresh': users = await client.users(); render(); break;
        case 'identity': showDialog('Ваш отпечаток', [node('p', '@' + client.session.account),
          node('code', await hash(genesisText(client.state.own.genesis))),
          node('p', 'Передайте этот отпечаток собеседнику через независимый доверенный канал.', 'muted')]); break;
        case 'backup': downloadBackup(); break;
        case 'install': installGuide(); break;
        case 'logout': await client.disablePush().catch(() => {}); client.stop(); await api('/api/logout', {}); location.reload(); break;
        default: throw Error('Неизвестное действие интерфейса');
      }
      return JSON.stringify({ok:true});
    } catch (error) {
      const message = errors[error.message] || error.message; notice(message);
      return JSON.stringify({ok:false,error:message});
    }
  };
  const script = node('script'); script.src = '/flutter-ui/flutter_bootstrap.js';
  script.onerror = () => notice('Не удалось загрузить Flutter UI. Проверьте сборку и соединение; ключи сохранены.');
  document.head.append(script);
  try { await client.start(); users = await client.users(); client.loadProfile().catch(() => {}); client.restorePush().catch(() => {}); render(); }
  catch (error) { notice(errors[error.message] || error.message); }
}
function verifyContact(account) {
  action(async () => {
    const directory = await client.inspectContact(account), fingerprint = directory.checkpoint.genesisDigest;
    const code = node('code', fingerprint), instructions = node('p', 'Собеседник должен открыть «Ключ» в своём Shade. Сравните отпечатки через независимый доверенный канал и введите его отпечаток ниже. Google и сервер не подтверждают ключи.');
    const field = node('input'); field.placeholder = '64 символа отпечатка собеседника'; field.autocomplete = 'off'; field.setAttribute('aria-label', 'Отпечаток собеседника');
    const button = node('button', 'Закрепить проверенный отпечаток'); button.type = 'button';
    button.onclick = () => action(async () => { if (field.value.replace(/\s/g, '').toLowerCase() !== fingerprint) throw Error('Отпечатки не совпадают');
      await client.pinContact(account, fingerprint); dialog.close(); render(); await client.sync(); });
    showDialog('@' + account, [instructions, code, field, button]);
  });
}
client.addEventListener('change', render);
window.addEventListener('offline', render); window.addEventListener('online', render);
window.addEventListener('pagehide', () => client.stop());
window.addEventListener('pageshow', event => { if (event.persisted && ready) client.start().catch(e => notice(e.message)); });

async function boot() {
  if (!window.isSecureContext || !crypto.subtle) throw Error('Для криптографии требуется HTTPS или localhost.');
  // iOS standalone PWA: the OAuth callback may have run in a different cookie
  // jar (in-app browser). The one-time fragment code establishes the session
  // in THIS jar. The fragment is cleared immediately and never sent anywhere.
  const fragment = new URLSearchParams(location.hash.slice(1));
  const handoff = fragment.get('shade_login');
  if (handoff) {
    history.replaceState(null, '', location.pathname + location.search);
    try { await api('/api/v2/session/handoff', { code: handoff }); }
    catch (error) { notice('Не удалось завершить вход: ' + error.message); }
  }
  let status;
  try { status = await api('/api/session'); }
  catch (error) {
    const local = await listVaults();
    if (navigator.onLine || !local.length) throw error;
    status = { authenticated: true, account: local[0].account, offline: true };
  }
  if (!status.authenticated) {
    const box = welcome('Личная переписка. На любом устройстве.', 'Google подтверждает ваш аккаунт. Криптографические ключи создаются и остаются в браузере. Для их разблокировки понадобится отдельная фраза.');
    if (status.googleConfigured) { const login = node('a', 'Войти через Google', 'button'); login.href = '/auth/google'; box.append(login); }
    else box.append(node('p', 'Google OAuth ещё не настроен администратором. Переписка требует входа.', 'card'));
    if (!isStandalone()) { const install = node('button', 'Установить Shade'); install.onclick = installGuide; box.append(install); }
    return;
  }
  loggedIn = !status.offline;
  const vaults = await listVaults();
  const matching = vaults.filter(v => v.account === status.account);
  if (status.account && !matching.length) {
    welcome('Нужна привязка устройства', 'Этот Google-аккаунт уже зарегистрирован, но в браузере нет его ключей. Откройте прежнее доверенное устройство. В этой альфе добавление устройства и восстановление через интерфейс ещё недоступны. Исходные RSA-ключи не заменены.'); return;
  }
  if (matching.length || (!status.account && vaults.length)) {
    const candidates = matching.length ? matching : vaults;
    const box = welcome('Разблокировать Shade', 'Фраза расшифровывает ключи и историю только в этом браузере. Сервер её не получает.');
    const form = node('form'), select = node('select'); select.setAttribute('aria-label','Локальное устройство');
    for (const v of candidates) { const option = node('option','@' + v.account); option.value = v.id; select.append(option); }
    form.append(select); const phrase = input(form, 'Фраза устройства', 'passphrase', 'password'); submit(form, 'Разблокировать'); box.append(form);
    form.onsubmit = event => { event.preventDefault(); action(async () => { await client.load(candidates.find(v => v.id === select.value), phrase.value); phrase.value = '';
      if (status.account) await openApp(); else await backupStep(); }); }; return;
  }
  const box = welcome('Создать аккаунт', 'Регистрация работает с iPhone и ПК. Используйте две разные сильные фразы: для устройства и для offline recovery-пакета.');
  const form = node('form'), account = input(form, 'Имя пользователя', 'account'); account.pattern = '[a-z0-9_]{3,32}'; account.maxLength = 32; account.autocapitalize = 'none';
  const phrase = input(form, 'Фраза устройства · от 16 символов', 'passphrase', 'password', 16); phrase.autocomplete = 'new-password';
  const confirm = input(form, 'Повторите фразу устройства', 'confirm', 'password', 16); confirm.autocomplete = 'new-password';
  const recovery = input(form, 'Отдельная recovery-фраза · от 24 символов', 'recovery', 'password', 24); recovery.autocomplete = 'new-password';
  submit(form, 'Создать ключи на этом устройстве'); box.append(form);
  form.onsubmit = event => { event.preventDefault(); action(async () => {
    if (phrase.value !== confirm.value) throw Error('Фразы устройства не совпадают');
    if (phrase.value === recovery.value) throw Error('Recovery-фраза должна отличаться');
    notice('Создание RSA-4096 ключей… Оставьте страницу открытой.');
    await client.prepare(account.value, phrase.value, recovery.value); phrase.value = ''; confirm.value = ''; recovery.value = ''; await backupStep();
  }); };
}
boot().catch(error => { welcome('Shade недоступен', errors[error.message] || error.message); });
if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('/alpha-sw.js', { updateViaCache: 'none' }).then(reg => {
    // A waiting worker means a newer offline shell exists. Never switch
    // automatically: the user explicitly reloads, keys and history untouched.
    const offerUpdate = () => {
      if (!navigator.serviceWorker.controller) return;
      const button = node('button', 'Перезагрузить и обновить', 'primary'); button.type = 'button';
      button.onclick = () => {
        // Reload only after the new worker actually takes control — an
        // immediate reload races skipWaiting and can leave the tab loading.
        let refreshing = false;
        navigator.serviceWorker.addEventListener('controllerchange', () => {
          if (!refreshing) { refreshing = true; location.reload(); }
        });
        if (reg.waiting) reg.waiting.postMessage('SKIP_WAITING');
        else location.reload();
      };
      showDialog('Доступно обновление Shade', [node('p', 'Новая версия приложения загружена. Перезагрузка применит её к офлайн-запуску; ключи и история не затрагиваются.'), button]);
    };
    if (reg.waiting) offerUpdate();
    reg.addEventListener('updatefound', () => {
      const worker = reg.installing;
      worker?.addEventListener('statechange', () => {
        if (worker.state === 'installed' && navigator.serviceWorker.controller) offerUpdate();
      });
    });
  }).catch(() => notice('Offline-запуск недоступен. Проверьте разрешения хранилища.'));
}

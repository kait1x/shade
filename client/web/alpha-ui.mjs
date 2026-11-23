import { AlphaClient, api } from './alpha-client.mjs';
import { listVaults, MIN_RECOVERY_PASSWORD_LENGTH, DEVICE_PIN_LENGTHS, validDevicePin } from './device_crypto.mjs';
import { mergeReadMarks, readReadMarks, saveReadMarks } from './alpha-storage.mjs';
import { hash, genesisText, check } from './protocol/device-v2.mjs';
import { createDeviceBinding, unlockDeviceBinding, platformAuthenticatorAvailable,
  bindingErrorText } from './device_binding.mjs';

const root = document.querySelector('#root'), dialog = document.querySelector('#dialog');
const client = new AlphaClient();
// QA introspection: the page context can always reach whatever its own scripts
// hold; this only names the instance. CryptoKey material stays non-extractable.
window.__shadeClient = client;
const contact = account => client.state && Object.hasOwn(client.state.contacts, account) ? client.state.contacts[account] : null;
let selected = null, users = [], ready = false, actionTail = Promise.resolve(), noticeTimer, loggedIn = false;
function node(tag, text, className) { const n = document.createElement(tag); if (text !== undefined) n.textContent = text; if (className) n.className = className; return n; }
function notice(text, ms = 9000) { const n = document.querySelector('#notice'); n.textContent = text; n.classList.add('visible'); clearTimeout(noticeTimer); noticeTimer = setTimeout(() => n.classList.remove('visible'), ms); }
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
    if (m.from === client.session.account || m.from === selected || m.readAt) continue;
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
  rate_limited: 'Слишком много запросов. Подождите немного и повторите.',
  operation_rejected: 'Операция отклонена. Проверьте сеть, срок каталога и доступ устройства. Сообщение не отмечено доставленным.',
  account_requires_linking: 'Аккаунт уже существует. Нужна привязка доверенным устройством; новые ключи не назначены.',
  // D1: честные HOLD-тексты когортной миграции. Сообщение остаётся в outbox
  // со статусом blocked; тихой отправки в несовместимое окружение нет.
  migration_pending: 'Миграция диалога в Shade v2 не завершена. Сообщение сохранено в очереди и будет отправлено после переключения.',
  migration_rolled_back: 'Диалог возвращён в Shade v1. Сообщение сохранено в очереди; отправка из этого приложения (v2) недоступна — используйте Shade v1.',
  peer_upgrade_required: 'Собеседник ещё не перешёл на Shade v2. Сообщение сохранено в очереди и будет доставлено после его перехода.',
  // Ответ реестра на запрос директории несуществующего аккаунта.
  'Unknown account': 'Никнейм не найден' };
// ── Когортная миграция диалога (D1, V2_COHORT_MIGRATION.md) ──────────────────
// Проекция per-dialog состояния и честные тексты. Кнопок управления миграцией
// в UI нет: управление через отдельные методы/экран позже; здесь только состояние.
const MIGRATION_HOLD_CODES = new Set(['migration_pending', 'migration_rolled_back']);
// peer → последняя подписанная проекция dialog.migration.status; {state:null}
// = диалог без journal (обычный чат, баннера нет).
const dialogRoutingCache = new Map();
const dialogRoutingFetchAt = new Map();
const dialogRoutingBusy = new Set();
// Баннер шапки чата по состоянию диалога. v1_active без rollback (abort или
// обычный диалог) → баннера нет: обычный чат не меняется.
export function migrationBannerText(record) {
  if (!record) return null;
  switch (record.state) {
    case 'migration_pending': return 'Ожидание собеседника/устройств…';
    case 'transferring': return 'Диалог переносится…';
    case 'v2_active': return 'Диалог в Shade v2';
    case 'v1_active': return record.rolledBackAt ? 'Диалог возвращён в v1' : null;
    default: return null;
  }
}
// Чистая проекция для render: баннер замещает connection/connected только
// онлайн и без реальных ошибок (сеть/сессия честнее баннера). null = прежнее
// поведение connection/connected без изменений.
export function migrationBannerProjection({ peer, account, routing, lastError, online }) {
  if (!peer || peer === account || !online) return null;
  const banner = migrationBannerText(routing);
  if (!banner) return null;
  if (lastError && !MIGRATION_HOLD_CODES.has(lastError)) return null;
  return { connection: banner, connected: false };
}
// Подписанный fetch состояния (авторитет — серверный journal, не socket-подсказка).
// Троттлинг 15 с — ритм sync; force при открытии чата и wake-подсказке сервера.
async function refreshDialogRouting(peer, force = false) {
  if (!peer || peer === client.session?.account || !client.state?.registered) return;
  if (dialogRoutingBusy.has(peer)) return;
  const now = Date.now();
  if (!force && now - (dialogRoutingFetchAt.get(peer) || 0) < 15000) return;
  // Force (открытие чата/wake) тоже троттлируется после первого fetch: иначе
  // быстрое переключение чатов выжигает квоту challenge и голодит socket-auth.
  if (force && dialogRoutingCache.has(peer) && now - (dialogRoutingFetchAt.get(peer) || 0) < 5000) return;
  dialogRoutingFetchAt.set(peer, now);
  dialogRoutingBusy.add(peer);
  try {
    const status = await client.dialogMigrationStatus(peer);
    dialogRoutingCache.set(peer, { state: status.state, revision: status.revision,
      rolledBackAt: status.rolledBackAt || null });
  } catch (error) {
    // dialog_not_found = диалог без journal (обычный чат). Сетевой сбой:
    // сохраняем последнее известное состояние, баннер не выдумываем.
    if (error.message === 'dialog_not_found') dialogRoutingCache.set(peer, { state: null });
    else return;
  } finally { dialogRoutingBusy.delete(peer); }
  render();
}
// Wake-подсказка сервера dialogRouting (уходит устройствам обоих участников):
// немедленный подписанный fetch. Socket пересоздаётся в start() — хук идемпотентен.
function hookDialogRouting() {
  const socket = client.socket;
  if (!socket || socket.__shadeRoutingHook) return;
  socket.__shadeRoutingHook = true;
  socket.on('dialogRouting', data => {
    if (typeof data?.peer === 'string') refreshDialogRouting(data.peer, true);
  });
}
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
    const button = node('button', 'Установить', 'btn primary'); button.type = 'button';
    button.onclick = async () => {
      const event = deferredInstall; deferredInstall = null; dialog.close();
      event.prompt();
      const { outcome } = await event.userChoice;
      if (outcome === 'accepted') notice('Shade установлен.');
    };
    showDialog('Установить Shade', [node('p', 'Установить приложение Shade на это устройство?'), node('p', 'Ключи остаются в этом браузере. Не очищайте данные сайта. Перед установкой сохраните recovery-пакет. Установка PWA не переносит ключи из другого браузера.', 'muted'), button]);
    return;
  }
  const manualGuide = platformName() === 'ios'
    ? 'В Safari нажмите «Поделиться» → «На экран Домой» → «Добавить». Открывайте Shade с этой иконки.'
    : platformName() === 'android'
      ? 'В Chrome на Android: меню ⋮ → «Установить приложение» или «Добавить на главный экран». Открывайте Shade с этой иконки.'
      : 'В Edge или Chrome нажмите значок установки в адресной строке → «Установить». Открывайте Shade с ярлыка.';
  showDialog('Установить Shade', [node('p', manualGuide), node('p', 'Ключи остаются в этом браузере. Не очищайте данные сайта. Перед установкой сохраните recovery-пакет. Установка PWA не переносит ключи из другого браузера.', 'muted')]);
}
// Chromium offers a real install flow; Safari needs the manual guide above.
let deferredInstall = null;
window.addEventListener('beforeinstallprompt', event => { event.preventDefault(); deferredInstall = event; });
window.addEventListener('appinstalled', () => { deferredInstall = null; notice('Shade установлен.'); });

// ---- Onboarding presentation ----------------------------------------------
// Visual language mirrors the Android WelcomeScreen (shade_theme.dart +
// welcome_screen.dart): the ghost mascot and the Google mark reuse the exact
// painter geometry of the native build. Auth DOM screens stay outside Flutter;
// the client never exposes vaults, keys, backups or tokens to the projection.
let ghostUid = 0;
function ghost(size) {
  const id = `shade-ghost-${++ghostUid}`;
  const span = node('span', undefined, 'ghost');
  span.setAttribute('aria-hidden', 'true');
  span.style.width = span.style.height = `${size}px`;
  span.innerHTML = `<svg viewBox="0 0 100 100" focusable="false"><defs><linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="15" y1="13" x2="89" y2="93"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e3e3e3"/></linearGradient></defs><g transform="translate(50 50) scale(0.82) translate(-53 -51.5)"><path fill="url(#${id})" d="M18 48C18 25 31 13 50 13C70 13 82 27 82 48C82 62 86 73 88 79C90 86 80 90 74 85L66 79C61 92 49 94 43 81C34 92 20 91 19 80C18 70 18 58 18 48Z"/><ellipse cx="37.5" cy="47" rx="5.5" ry="9" fill="#181818"/><ellipse cx="62.5" cy="45" rx="5.5" ry="9" fill="#181818"/><path d="M44 64Q51 70 58 62" fill="none" stroke="#181818" stroke-width="3.5" stroke-linecap="round"/></g></svg>`;
  return span;
}
// Google's four-colour G in the original 24-unit coordinate system, ported
// verbatim from the Android _GoogleMark CustomPainter (welcome_screen.dart).
const GOOGLE_MARK = `<svg viewBox="0 0 24 24" focusable="false" aria-hidden="true"><path fill="#4285f4" d="M21.6 12.23C21.6 11.52 21.54 10.84 21.42 10.18L12 10.18L12 14.05L17.38 14.05C17.15 15.3 16.44 16.36 15.38 17.07L15.38 19.58L18.61 19.58C20.5 17.84 21.6 15.28 21.6 12.23Z"/><path fill="#34a853" d="M12 22C14.7 22 16.96 21.1 18.61 19.58L15.38 17.07C14.48 17.67 13.33 18.04 12 18.04C9.39 18.04 7.18 16.28 6.39 13.91L3.05 13.91L3.05 16.5C4.7 19.76 8.09 22 12 22Z"/><path fill="#fbbc05" d="M6.39 13.91C6.19 13.31 6.07 12.67 6.07 12C6.07 11.33 6.19 10.69 6.39 10.09L6.39 7.5L3.05 7.5C2.38 8.85 2 10.38 2 12C2 13.62 2.38 15.15 3.05 16.5Z"/><path fill="#ea4335" d="M12 5.96C13.47 5.96 14.78 6.47 15.82 7.47L18.68 4.61C16.95 3 14.7 2 12 2C8.09 2 4.7 4.24 3.05 7.5L6.39 10.09C7.18 7.72 9.39 5.96 12 5.96Z"/></svg>`;
function spinner(size = 18) {
  const span = node('span', undefined, 'spin');
  span.setAttribute('aria-hidden', 'true');
  span.style.width = span.style.height = `${size}px`;
  return span;
}
// Inline progress line inside a card, mirroring the Android busy-button labels
// ('Подготавливаем хранилище…', 'Создаём RSA-4096 ключи…').
function showProgress(note, text) {
  note.replaceChildren(spinner(16), node('span', text));
  note.hidden = false;
}
function changeAccountButton() {
  const button = node('button', 'Сменить Google-аккаунт', 'btn-text');
  button.type = 'button';
  button.onclick = () => action(async () => { await client.disablePush().catch(() => {}); client.stop(); await api('/api/logout', {}); location.href = '/auth/google'; });
  return button;
}
function expander(summaryText, children) {
  const details = node('details', undefined, 'expain');
  details.append(node('summary', summaryText), ...children);
  return details;
}
// Common onboarding frame: brand row, optional medallion and title, the form
// card, fineprint and a quiet details expander.
function onboard({ title, subtitle, cardTitle, cardSubtitle, medallion = false, footer, details, children }) {
  const section = node('section', undefined, 'onboard enter');
  const inner = node('div', undefined, 'onboard-inner');
  const brand = node('div', undefined, 'brand');
  brand.append(ghost(30), node('span', 'shade', 'brand-name'));
  inner.append(brand);
  if (medallion) { const medallionEl = node('div', undefined, 'medallion'); medallionEl.append(ghost(100)); inner.append(medallionEl); }
  if (title) inner.append(node('h1', title));
  if (subtitle) inner.append(node('p', subtitle, 'subtitle'));
  const card = node('div', undefined, 'onboard-card');
  if (cardTitle) card.append(node('h2', cardTitle));
  if (cardSubtitle) card.append(node('p', cardSubtitle, 'card-sub'));
  card.append(...children);
  inner.append(card);
  if (footer) inner.append(node('p', footer, 'fineprint'));
  if (details) inner.append(details);
  section.append(inner);
  root.replaceChildren(section);
  return section;
}
function input(form, title, name, type = 'text', minLength = 0, options = {}) {
  const label = node('label', undefined, 'field');
  const box = node('span', undefined, 'field-box' + (options.prefix ? ' has-prefix' : ''));
  if (options.prefix) { const prefix = node('span', options.prefix, 'prefix'); prefix.setAttribute('aria-hidden', 'true'); box.append(prefix); }
  const field = node('input');
  field.name = name; field.type = type; field.required = true;
  if (minLength) field.minLength = minLength;
  if (options.placeholder) field.placeholder = options.placeholder;
  field.autocomplete = options.autocomplete || (type === 'password' ? 'current-password' : 'off');
  box.append(field);
  label.append(node('span', title, 'field-label'), box);
  form.append(label);
  return field;
}
function submit(form, text) { const button = node('button', text, 'btn primary'); button.type = 'submit'; form.append(button); return button; }
function downloadBackup() {
  const blob = new Blob([JSON.stringify({ backup: client.state.backup, genesis: client.state.own.genesis }, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob), anchor = node('a'); anchor.href = url; anchor.download = `shade-recovery-${client.session.account}.json`; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 10000);
}
function appleInstallStep() {
  const steps = node('ol', undefined, 'install-steps');
  for (const text of [
    'Откройте эту страницу в Safari.',
    'Нажмите «Поделиться» → «На экран Домой» → «Добавить».',
    'Откройте Shade с экрана «Домой» и войдите через Google.',
  ]) steps.append(node('li', text));
  onboard({
    medallion: true,
    title: 'Установите Shade',
    cardTitle: 'Откройте Shade как приложение',
    cardSubtitle: 'Для регистрации на iPhone и iPad сначала добавьте Shade на экран «Домой».',
    children: [steps],
    footer: 'Установка через Safari · без App Store',
  });
}
function welcomeStep(status) {
  const children = [];
  if (status.googleConfigured) {
    const login = node('a', undefined, 'btn google');
    login.href = '/auth/google';
    login.id = 'google-sign-in';
    const mark = node('span', undefined, 'mark'); mark.setAttribute('aria-hidden', 'true'); mark.innerHTML = GOOGLE_MARK;
    const label = node('span', 'Продолжить с Google', 'btn-label');
    login.append(mark, label);
    // Full-page redirect to Google; the busy state covers slow handoff networks.
    login.addEventListener('click', event => {
      if (login.classList.contains('busy')) { event.preventDefault(); return; }
      login.classList.add('busy');
      login.replaceChildren(spinner(18), node('span', 'Подключаем…', 'btn-label'));
    });
    children.push(login);
  } else {
    children.push(node('p', 'Google OAuth ещё не настроен администратором. Переписка требует входа.', 'card-error'));
  }
  if (!isStandalone()) {
    const install = node('button', 'Установить Shade', 'btn outline');
    install.type = 'button';
    install.onclick = installGuide;
    children.push(install);
  }
  onboard({
    medallion: true,
    title: 'Свои люди.\nЛичные разговоры.',
    subtitle: 'Место для ваших разговоров,\nфотографий и маленьких планов.',
    children,
    footer: 'Ключи и история остаются в этом браузере.\nСервер не видит содержание переписки.',
    details: expander('Как используется Google-аккаунт',
      [node('p', 'Google подтверждает имя, email и фото профиля. Shade не получает пароль Google. Шифрование переписки использует отдельные ключи на вашем устройстве.', 'expain-body')]),
  });
}
// The recovery password stays separate from this browser's vault protection.
function recoveryPasswordInput(form) {
  return input(form, `Пароль восстановления · от ${MIN_RECOVERY_PASSWORD_LENGTH} символов`,
    'recovery-password', 'password', MIN_RECOVERY_PASSWORD_LENGTH, { autocomplete: 'new-password' });
}

function passwordVisibility(form, fields) {
  const label = fields.length === 1 ? 'пароль' : 'пароли';
  const toggle = node('button', `Показать ${label}`, 'btn-text');
  toggle.type = 'button';
  toggle.setAttribute('aria-pressed', 'false');
  toggle.onclick = () => {
    const show = fields[0].type === 'password';
    for (const field of fields) field.type = show ? 'text' : 'password';
    toggle.setAttribute('aria-pressed', String(show));
    toggle.textContent = show ? `Скрыть ${label}` : `Показать ${label}`;
  };
  form.append(toggle);
}

function readRecoveryPassword(field) {
  const password = field.value;
  check(password.length >= MIN_RECOVERY_PASSWORD_LENGTH,
    `Пароль восстановления: минимум ${MIN_RECOVERY_PASSWORD_LENGTH} символов.`);
  check(password === password.trim().replace(/\s+/g, ' '),
    'Уберите пробелы с краёв и двойные пробелы.');
  return password;
}

function configurePinInput(field, length) {
  field.inputMode = length ? 'none' : 'text';
  if (length) {
    field.minLength = length;
    field.maxLength = length;
    field.pattern = `[0-9]{${length}}`;
  } else {
    for (const attribute of ['minlength', 'maxlength', 'pattern']) field.removeAttribute(attribute);
  }
}

function attachPinPad(field, onComplete) {
  const label = field.closest('label');
  const fieldBox = field.parentElement;
  const dots = node('span', undefined, 'pin-dots');
  dots.setAttribute('aria-hidden', 'true');
  fieldBox.append(dots);
  const feedback = node('p', undefined, 'pin-feedback');
  feedback.setAttribute('role', 'alert');
  feedback.hidden = true;
  const keypad = node('div', undefined, 'pin-keypad');
  keypad.setAttribute('role', 'group');
  keypad.setAttribute('aria-label', 'Цифровая клавиатура PIN');
  label.after(feedback, keypad);
  let length;
  let busy = false;
  const keys = [];
  let erase;

  function update() {
    for (let i = 0; i < dots.children.length; i++) {
      dots.children[i].classList.toggle('filled', i < field.value.length);
    }
    for (const key of keys) key.disabled = busy;
    erase.disabled = busy || !field.value;
  }

  function enter(value) {
    if (!length || busy) return;
    const sanitized = value.replace(/[^0-9]/g, '').slice(0, length);
    if (field.value !== sanitized) field.value = sanitized;
    feedback.hidden = true;
    field.removeAttribute('aria-invalid');
    update();
    if (field.value.length === length) onComplete?.();
  }

  function button(text, label, handle) {
    const key = node('button', text, 'pin-key');
    key.type = 'button';
    if (label) key.setAttribute('aria-label', label);
    key.onclick = handle;
    keypad.append(key);
    keys.push(key);
    return key;
  }

  for (let digit = 1; digit <= 9; digit++) {
    button(String(digit), null, () => enter(field.value + digit));
  }
  keypad.append(node('span', undefined, 'pin-spacer'));
  button('0', null, () => enter(field.value + '0'));
  erase = button('⌫', 'Удалить цифру', () => enter(field.value.slice(0, -1)));
  erase.classList.add('pin-erase');
  field.addEventListener('input', () => enter(field.value));
  keypad.addEventListener('keydown', event => {
    if (!length || event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === 'Backspace') {
      event.preventDefault();
      enter(field.value.slice(0, -1));
    } else if (/^[0-9]$/.test(event.key)) {
      event.preventDefault();
      enter(field.value + event.key);
    }
  });

  return {
    setLength(value) {
      length = value;
      field.value = '';
      configurePinInput(field, length);
      label.classList.toggle('pin-entry', Boolean(length));
      dots.hidden = keypad.hidden = !length;
      dots.replaceChildren(...Array.from({ length: length || 0 }, () => node('span', undefined, 'pin-dot')));
      feedback.hidden = true;
      field.removeAttribute('aria-invalid');
      update();
    },
    setBusy(value) {
      busy = value;
      field.readOnly = value;
      update();
    },
    showError(message) {
      field.value = '';
      field.setAttribute('aria-invalid', 'true');
      feedback.textContent = message;
      feedback.hidden = false;
      update();
    },
  };
}

function pinLengthInput(form) {
  const label = node('label', undefined, 'field');
  const select = node('select');
  select.name = 'pin-length';
  for (const length of DEVICE_PIN_LENGTHS) {
    const option = node('option', length === 4 ? '4 цифры' : '6 цифр');
    option.value = String(length);
    select.append(option);
  }
  select.value = '6';
  label.append(node('span', 'Длина PIN', 'field-label'), select);
  form.append(label);
  return select;
}

function registrationStep({ protection, initialNickname = '', initialPassword = '' }) {
  const useDeviceProtection = protection === 'system';
  const form = node('form');
  const nickname = input(form, 'Ваш никнейм', 'account', 'text', 0,
    { prefix: '@', placeholder: 'например, mira_22', autocomplete: 'username' });
  nickname.value = initialNickname;
  nickname.maxLength = 32;
  nickname.autocapitalize = 'none';
  nickname.spellcheck = false;
  nickname.setAttribute('enterkeyhint', 'next');
  const error = node('p', undefined, 'field-error');
  error.setAttribute('role', 'alert');
  error.hidden = true;
  form.append(error);

  const recovery = recoveryPasswordInput(form);
  recovery.value = initialPassword;
  const pinLength = protection === 'pin' ? pinLengthInput(form) : null;
  const phrase = useDeviceProtection ? null
    : input(form, pinLength ? 'PIN этого браузера' : 'Пароль этого браузера · от 16 символов',
      'passphrase', 'password', pinLength ? 0 : 16, { autocomplete: 'new-password' });
  const pinPad = pinLength ? attachPinPad(phrase) : null;
  if (pinPad) {
    pinPad.setLength(Number(pinLength.value));
    pinLength.onchange = () => pinPad.setLength(Number(pinLength.value));
  }
  passwordVisibility(form, phrase && !pinPad ? [recovery, phrase] : [recovery]);
  const note = node('p', undefined, 'gen-progress');
  note.hidden = true;
  submit(form, 'Создать аккаунт');

  const fallback = node('button', protection === 'pin' ? 'Использовать пароль браузера' : 'Использовать PIN', 'btn-text');
  fallback.type = 'button';
  function switchProtection(next) {
    registrationStep({
      protection: next, initialNickname: nickname.value, initialPassword: recovery.value,
    });
  }
  fallback.onclick = () => switchProtection(protection === 'pin' ? 'password' : 'pin');
  onboard({
    cardTitle: 'Создать аккаунт',
    cardSubtitle: useDeviceProtection
      ? 'Сохраните пароль восстановления. Для входа на этом устройстве Shade использует системную защиту.'
      : pinLength ? 'PIN открывает Shade в этом браузере даже без интернета. Сохраните пароль восстановления отдельно.'
        : 'Пароль браузера открывает Shade на этом устройстве. Отдельный пароль восстановления нужен при потере всех устройств.',
    children: [form, fallback, note, changeAccountButton()],
    footer: 'Shade автоматически сохранит зашифрованную копию аккаунта.',
  });

  const fieldBox = nickname.parentElement;
  nickname.addEventListener('input', () => {
    error.hidden = true;
    nickname.removeAttribute('aria-invalid');
    fieldBox.classList.remove('invalid');
  });
  form.onsubmit = event => {
    event.preventDefault();
    const account = nickname.value.trim().toLowerCase();
    if (!/^[a-z0-9_]{3,32}$/.test(account)) {
      error.textContent = 'От 3 до 32 символов: a–z, 0–9 и _';
      error.hidden = false;
      nickname.setAttribute('aria-invalid', 'true');
      fieldBox.classList.add('invalid');
      nickname.focus();
      return;
    }
    action(async () => {
      if (!form.isConnected) return;
      const password = readRecoveryPassword(recovery);
      let passphrase = phrase?.value;
      const length = pinLength ? Number(pinLength.value) : undefined;
      let binding;
      fallback.disabled = true;
      if (pinLength) pinLength.disabled = true;
      pinPad?.setBusy(true);
      try {
        if (useDeviceProtection) {
          showProgress(note, 'Подтвердите защиту устройства…');
          try { ({ binding, passphrase } = await createDeviceBinding(account)); }
          catch (error) {
            if (error.message === 'prf_unavailable') {
              switchProtection('pin');
              notice('Системная защита здесь недоступна. Задайте PIN браузера.');
              return;
            }
            throw Error(bindingErrorText(error) || error.message);
          }
        } else if (pinLength) {
          check(validDevicePin(passphrase, length), 'Введите PIN выбранной длины.');
        } else {
          check(passphrase !== password, 'Задайте отдельный пароль восстановления.');
        }
        showProgress(note, 'Создаём аккаунт…');
        await client.prepare(account, passphrase, password, binding, { pinLength: length });
        if (phrase) phrase.value = '';
        recovery.value = '';
        await finishRegistration(note, { newAccount: true });
      } finally {
        fallback.disabled = false;
        if (pinLength) pinLength.disabled = false;
        pinPad?.setBusy(false);
        note.hidden = true;
      }
    });
  };
}


async function finishRegistration(note, { newAccount = false } = {}) {
  showProgress(note, 'Подключаемся к Shade…');
  try { await client.register(); }
  catch (error) {
    if (newAccount) resumeRegistrationStep();
    throw error;
  }
  await openApp();
}

function resumeRegistrationStep() {
  const form = node('form');
  submit(form, 'Продолжить регистрацию');
  const note = node('p', undefined, 'gen-progress');
  note.hidden = true;
  const renewForm = node('form');
  const recovery = input(renewForm, 'Пароль или прежняя фраза восстановления',
    'recovery', 'password', MIN_RECOVERY_PASSWORD_LENGTH);
  submit(renewForm, 'Обновить и продолжить');
  const download = node('button', 'Скачать резервную копию', 'btn-text');
  download.type = 'button';
  download.onclick = downloadBackup;
  const renew = expander('Если срок регистрации истёк',
    [node('p', 'Введите пароль восстановления. Shade сохранит ключи этого устройства.', 'expain-body'), renewForm]);
  onboard({
    cardTitle: 'Продолжите регистрацию',
    cardSubtitle: 'Ключи уже сохранены в этом браузере.',
    children: [form, note, renew, download],
  });
  form.onsubmit = event => {
    event.preventDefault();
    action(async () => {
      if (!form.isConnected) return;
      try { await finishRegistration(note); }
      finally { note.hidden = true; }
    });
  };
  renewForm.onsubmit = event => {
    event.preventDefault();
    action(async () => {
      if (!renewForm.isConnected) return;
      showProgress(note, 'Обновляем данные регистрации…');
      try {
        await client.renewPending(recovery.value);
        recovery.value = '';
        await finishRegistration(note);
      } finally { note.hidden = true; }
    });
  };
}

function unlockStep(candidates, status) {
  const form = node('form');
  let select = null;
  if (candidates.length > 1) {
    select = node('select');
    select.setAttribute('aria-label', 'Локальное устройство');
    // После восстановления у аккаунта может быть два локальных vault
    // (утраченный и новый): короткий id различает их в списке.
    const counts = {};
    for (const v of candidates) counts[v.account] = (counts[v.account] || 0) + 1;
    for (const v of candidates) {
      const option = node('option', '@' + v.account + (counts[v.account] > 1 ? ` · ${v.id.slice(0, 8)}` : ''));
      option.value = v.id; select.append(option);
    }
    form.append(select);
  }
  const chosen = () => candidates.find(v => v.id === (select ? select.value : candidates[0].id));
  const phraseField = input(form, 'Пароль этого браузера', 'passphrase', 'password', 0, { autocomplete: 'current-password' });
  let unlocking = false;
  const pinPad = attachPinPad(phraseField, () => form.requestSubmit());
  const note = node('p', undefined, 'gen-progress');
  note.hidden = true;
  form.append(note);
  const unlock = submit(form, 'Разблокировать');
  // Точка входа в восстановление: ключи этого браузера могут быть утрачены
  // (PRF-vault без passkey, забытая фраза). Кнопка рабочая всегда, без dead-end.
  const unlockError = node('p', undefined, 'card-error');
  unlockError.hidden = true;
  unlockError.setAttribute('role', 'alert');
  const recovery = node('button', 'Восстановить доступ', 'btn outline');
  recovery.type = 'button';
  recovery.onclick = () => recoveryScreen();
  const hint = node('p', undefined, 'card-sub');
  const box = onboard({
    cardTitle: 'Разблокировать Shade',
    children: [hint, form, unlockError, recovery, changeAccountButton()],
  });
  box.classList.add('shade-unlock');
  const refresh = () => {
    const vault = chosen();
    const system = vault.binding?.method === 'prf';
    const pin = Boolean(vault.pinLength);
    phraseField.closest('label').hidden = system;
    phraseField.disabled = system;
    phraseField.required = !system;
    pinPad.setLength(vault.pinLength);
    unlock.hidden = pin;
    unlock.textContent = system ? 'Подтвердить на устройстве' : 'Разблокировать';
    box.classList.toggle('pin-lock', pin);
    phraseField.closest('label').querySelector('.field-label').textContent =
      pin ? 'PIN этого браузера' : 'Пароль этого браузера';
    hint.textContent = pin ? `Введите PIN для @${vault.account}`
      : system ? `Подтвердите вход в @${vault.account} системным способом.`
        : `Введите пароль или фразу, которую задали в этом браузере для @${vault.account}.`;
    unlockError.hidden = true;
    recovery.className = pin ? 'btn-text' : 'btn outline';
    recovery.textContent = pin ? 'Забыли PIN?' : 'Восстановить доступ';
  };
  if (select) select.addEventListener('change', refresh);
  refresh();
  form.onsubmit = event => {
    event.preventDefault();
    if (unlocking) return;
    unlocking = true;
    const vault = chosen();
    if (select) select.disabled = true;
    unlockError.hidden = true;
    if (vault.pinLength) {
      pinPad.setBusy(true);
      showProgress(note, 'Разблокируем Shade…');
    }
    action(async () => {
      let passphrase;
      if (vault.binding?.method === 'prf') {
        showProgress(note, 'Подтверждаем защиту устройства…');
        try { passphrase = await unlockDeviceBinding(vault.binding); }
        catch (error) {
          note.hidden = true;
          const canceled = error.name === 'NotAllowedError';
          unlockError.textContent = canceled
            ? 'Подтверждение не завершено. Попробуйте ещё раз.'
            : 'Системный ключ недоступен в этом браузере. Откройте Shade на исходном устройстве или восстановите доступ.';
          unlockError.hidden = false;
          if (!canceled) recovery.className = 'btn primary';
          return;
        }
      } else passphrase = phraseField.value;
      // loadForPairing also resumes an interrupted second-device pairing: a
      // vault without committed state is a pairing in progress, not a loss.
      let result;
      try { result = await client.loadForPairing(vault, passphrase); }
      catch (error) {
        if (error.name !== 'OperationError') throw error;
        if (vault.binding?.method === 'prf') {
          unlockError.textContent = 'Системный ключ не открыл хранилище. Попробуйте снова или восстановите доступ.';
          unlockError.hidden = false;
          recovery.className = 'btn primary';
        } else if (vault.pinLength) {
          pinPad.showError('Неверный PIN. Попробуйте ещё раз.');
        } else {
          unlockError.textContent = 'Пароль не подошёл. Попробуйте ещё раз.';
          unlockError.hidden = false;
        }
        return;
      }
      phraseField.value = '';
      if (result.pending) { pairingOfferStage(); return; }
      if (status.account) await openApp(); else resumeRegistrationStep();
    }).finally(() => {
      unlocking = false;
      if (select) select.disabled = false;
      if (vault.pinLength) {
        pinPad.setBusy(false);
        if (phraseField.hasAttribute('aria-invalid')) phraseField.focus({ preventScroll: true });
      }
      note.hidden = true;
    });
  };
}
function linkStep(account) {
  const pair = node('button', 'Подключить это устройство', 'btn primary'); pair.type = 'button';
  pair.onclick = () => pairingOnboarding(account);
  // Все устройства потеряны: recovery-пакет — единственный оставшийся актив,
  // поэтому вход в восстановление рабочий уже здесь, а не «появится позже».
  const recovery = node('button', 'Восстановить доступ', 'btn outline');
  recovery.type = 'button';
  recovery.onclick = () => recoveryScreen();
  onboard({
    cardTitle: 'Вход на новом устройстве',
    cardSubtitle: `Чтобы открыть @${account} в этом браузере, подтвердите подключение там, где Shade уже открыт.`,
    children: [pair, recovery, node('p', 'Если доступа к старым устройствам нет, используйте пароль восстановления. Он вернёт доступ к новым сообщениям.', 'muted'), changeAccountButton()],
  }).classList.add('shade-link');
}
function errorStep(message) {
  const retry = node('button', 'Обновить', 'btn outline');
  retry.type = 'button';
  retry.onclick = () => location.reload();
  onboard({ cardTitle: 'Shade недоступен', cardSubtitle: message, children: [retry] });
}
// ── Подключение второго устройства ────────────────────────────────────────
// Транспорт offer/confirmation — обычный буфер обмена между устройствами
// пользователя. Целостность подтверждается криптографией, а не каналом.
function copyArea(area, text) {
  return action(async () => {
    try { await navigator.clipboard.writeText(text); notice('Скопировано в буфер обмена.'); }
    catch { area.focus(); area.select(); notice('Скопируйте текст вручную (Ctrl+C).'); }
  });
}
// Доверенное устройство: код подключения → проверка запроса → одобрение.
function pairDeviceDialog() {
  const challenge = client.pairingChallenge();
  const expires = new Date(challenge.expiresAt).toLocaleTimeString();
  const code = node('code', challenge.code);
  const field = node('textarea'); field.rows = 6; field.autocomplete = 'off';
  field.setAttribute('aria-label', 'Запрос подключения с нового устройства');
  field.placeholder = 'Вставьте запрос подключения (shade-pair-v2:…)';
  const review = node('button', 'Проверить запрос', 'primary'); review.type = 'button';
  review.onclick = () => action(async () => {
    const reviewed = await client.reviewPairingOffer(field.value);
    const short = reviewed.deviceId.slice(0, 16).replace(/(.{4})/g, '$1 ').trim();
    const approve = node('button', 'Подтвердить устройство', 'primary'); approve.type = 'button';
    approve.onclick = () => action(async () => {
      const confirmation = await client.approvePairing(field.value);
      const out = node('textarea'); out.rows = 6; out.readOnly = true; out.value = confirmation;
      out.setAttribute('aria-label', 'Подтверждение подключения');
      const copy = node('button', 'Копировать подтверждение'); copy.type = 'button';
      copy.onclick = () => copyArea(out, confirmation);
      showDialog('Устройство подключено', [
        node('p', `Устройство ${short}… добавлено к аккаунту @${client.session.account}.`),
        node('p', 'Перенесите подтверждение на новое устройство и вставьте его там. Ключи и история остаются на устройствах; сервер их не получает.', 'muted'),
        out, copy]);
    });
    showDialog('Добавить устройство', [
      node('p', `Аккаунт: @${client.session.account}`),
      node('p', 'Отпечаток нового устройства:'),
      node('code', reviewed.deviceId),
      node('p', 'Сравните его с отпечатком, который показывает новое устройство на экране подключения: значения должны совпадать символ в символ. Не совпадают или устройство не ваше — НЕ подтверждайте. Подтверждение даёт устройству доступ ко всем будущим сообщениям аккаунта.', 'muted'),
      approve]);
  });
  showDialog('Добавить устройство', [
    node('p', 'Шаг 1. Код подключения (действует до ' + expires + '):'),
    code,
    node('p', 'Введите этот код на новом устройстве. Код — только для вашего устройства: он не даёт доступ сам по себе, но нужен для запроса подключения.', 'muted'),
    node('p', 'Шаг 2. Запрос подключения с нового устройства:'),
    field, review]);
}
// Новое устройство: шаг 2 — запрос и подтверждение (ключи уже созданы).
// initialCode — код, введённый на шаге 1: offer генерируется сразу, без
// повторного ввода. Пустой код (возобновление прерванного подключения)
// показывает форму ввода свежего кода.
function pairingOfferStage(initialCode = '') {
  const codeForm = node('form');
  const code = input(codeForm, 'Код подключения с доверенного устройства (4 группы по 6 символов)', 'challenge');
  code.autocapitalize = 'characters'; code.autocomplete = 'off';
  const show = node('button', 'Показать запрос подключения', 'primary'); show.type = 'submit';
  const offer = node('textarea'); offer.rows = 8; offer.readOnly = true; offer.hidden = true;
  offer.setAttribute('aria-label', 'Запрос подключения');
  const copy = node('button', 'Копировать запрос'); copy.type = 'button'; copy.hidden = true;
  let offerText = '';
  const generate = async value => {
    offerText = await client.createPairingOffer(value);
    offer.value = offerText; offer.hidden = false; copy.hidden = false;
    notice('Запрос создан. Перенесите его на доверенное устройство.');
  };
  codeForm.onsubmit = event => { event.preventDefault(); action(async () => { await generate(code.value); }); };
  copy.onclick = () => copyArea(offer, offerText);
  const confirmForm = node('form');
  const confirmation = node('textarea'); confirmation.rows = 8; confirmation.autocomplete = 'off';
  confirmation.setAttribute('aria-label', 'Подтверждение подключения');
  confirmation.placeholder = 'Вставьте подтверждение (shade-pair-confirm-v1:…)';
  submit(confirmForm, 'Завершить подключение');
  confirmForm.onsubmit = event => { event.preventDefault(); action(async () => {
    const result = await client.completePairing(confirmation.value);
    notice(`Устройство подключено к @${result.account}.`);
    await openApp();
  }); };
  confirmForm.prepend(confirmation);
  // Challenge-binding (pairingTextV2, offer shade-pair-v2:) now signs the
  // challenge echo, so a substituted offer fails signature verification.
  // The fingerprint comparison stays as defense-in-depth: the user can still
  // visually confirm WHICH device is being approved before confirming.
  const fpBox = node('div', undefined, 'phrase-box');
  fpBox.append(node('code', client.session.id));
  onboard({
    cardTitle: 'Подключение устройства · шаг 2 из 2',
    cardSubtitle: 'Покажите запрос подключения на доверенном устройстве и вставьте полученное подтверждение. Ключи уже созданы в этом браузере.',
    children: [node('span', 'Отпечаток этого устройства', 'field-label'), fpBox,
      node('p', 'Перед подтверждением сравните этот отпечаток с отпечатком на доверенном устройстве. Не совпадает — не подтверждайте подключение.', 'muted'),
      codeForm, offer, copy, confirmForm, changeAccountButton()],
  });
  if (initialCode) { codeForm.hidden = true; action(async () => { await generate(initialCode); }); }
}
// Новое устройство: шаг 1 — ключи и код подключения.
function pairingOnboarding(account) {
  const form = node('form');
  const code = input(form, 'Код подключения с доверенного устройства (4 группы по 6 символов)', 'challenge');
  code.autocapitalize = 'characters'; code.autocomplete = 'off';
  const phrase = input(form, 'Фраза устройства · от 16 символов', 'passphrase', 'password', 16); phrase.autocomplete = 'new-password';
  const confirm = input(form, 'Повторите фразу устройства', 'confirm', 'password', 16); confirm.autocomplete = 'new-password';
  submit(form, 'Создать ключи и показать запрос');
  form.onsubmit = event => { event.preventDefault(); action(async () => {
    if (phrase.value !== confirm.value) throw Error('Фразы устройства не совпадают');
    notice('Создание RSA-4096 ключей… Оставьте страницу открытой.');
    await client.preparePairingVault(account, phrase.value);
    pairingOfferStage(code.value);
    phrase.value = ''; confirm.value = '';
  }); };
  onboard({
    cardTitle: 'Подключить это устройство',
    cardSubtitle: 'Этот Google-аккаунт уже зарегистрирован в Shade. Ключи создаются локально и входят в аккаунт только после подтверждения на доверенном устройстве.',
    children: [form, changeAccountButton()],
  });
}
// ── Восстановление с recovery-пакетом (PRF_RECOVERY_BLOCKER §3) ─────────────
// Экран восстановления — Flutter-проекция (recovery_screen.dart): поля, шаги
// и ошибки рисует Flutter, криптография и сеть остаются в JS-ядре. Сам пакет
// и recovery-фраза не попадают в проекцию: пакет живёт в замыкании ниже,
// фраза передаётся только как payload действия и нигде не сохраняется.
let recoveryPackage = null, recoveryState = null, recoveryBusy = false;
let cloudRecoverySaved = false;
function projectRecovery(patch) {
  recoveryState = { ...(recoveryState || {}), ...patch };
  if (window.shadeReceive) window.shadeReceive(JSON.stringify({ mode: 'recovery', recovery: recoveryState }));
}
// Честные русские тексты ошибок восстановления: ни одна не замалчивается.
const recoveryErrors = {
  bad_package_json: 'Файл не похож на recovery-пакет Shade: не удалось разобрать JSON.',
  bad_package_shape: 'Файл не похож на recovery-пакет Shade: ожидается JSON с полями backup и genesis.',
  'Recovery identity mismatch': 'Recovery-пакет не соответствует аккаунту: ключ или отпечаток не совпадают. Возможно, файл повреждён или это чужой пакет.',
  'Recovery backup must pin the exact account genesis': 'Пакет не привязан к genesis аккаунта: он не завершён или подменён. Используйте пакет, скачанный при регистрации.',
  'Genesis digest mismatch': 'Genesis аккаунта на сервере не совпадает с пакетом. Восстановление остановлено; ключи не заменены.',
  'Recovery key mismatch': 'Recovery-ключ аккаунта на сервере не совпадает с пакетом. Восстановление остановлено; ключи не заменены.',
  'Invalid recovery proof': 'Сервер отклонил подпись recovery-ключа. Проверьте пакет и фразу.',
  'Invalid or replayed challenge': 'Challenge восстановления истёк или уже использован. Повторите попытку.',
  'Account is not enrolled': 'Аккаунт из пакета не найден на сервере.',
  'Invalid account': 'Некорректный аккаунт в recovery-пакете.',
  login_required: 'Recovery-сессия истекла. Повторите восстановление.',
  operation_rejected: 'Сервер отклонил операцию восстановления. Повторите попытку.',
  'Challenge quota reached': 'Слишком много запросов challenge. Подождите минуту и повторите.',
  'Recovery capacity reached': 'Сервер перегружен попытками восстановления. Повторите позже.',
  'Use a strong passphrase of at least 16 characters': 'Фраза устройства должна быть не короче 16 символов.',
  'Каталог сервера не совпадает с recovery-пакетом': 'Каталог сервера не совпадает с recovery-пакетом. Восстановление остановлено; ключи не заменены.',
  prf_unavailable: 'Аутентификатор не поддерживает вывод ключа (PRF). Выберите защиту фразой устройства.',
};
function recoveryErrorText(error) {
  const message = error?.message || String(error);
  if (error?.status === 429 || message === 'rate_limited') return 'Слишком много попыток, подожди час';
  if (message === 'Нет сети') return 'Нет сети. Подключитесь к интернету и повторите попытку.';
  if (message === 'Страница закрывается') return message;
  // Сбой AES-GCM при расшифровке пакета: неверная фраза либо битый ciphertext.
  if (error?.name === 'OperationError') return 'Неверная recovery-фраза или повреждённый пакет. Проверьте фразу и файл.';
  if (message === 'Invalid protocol data' || message === 'Unexpected fields' || message === 'Unsupported RSA key')
    return 'Recovery-пакет повреждён: данные не соответствуют формату Shade. Проверьте файл.';
  if (error?.name === 'AbortError' || /abort/i.test(message)) return 'Сервер не ответил вовремя. Повторите попытку.';
  if (/failed to fetch|load failed|networkerror/i.test(message)) return 'Сервер недоступен. Проверьте соединение и повторите попытку.';
  const binding = bindingErrorText(error);
  if (binding) return binding;
  if (recoveryErrors[message]) return recoveryErrors[message];
  if (message.startsWith('Recovery ')) return 'Сервер отклонил шаг восстановления. Повторите попытку; если ошибка повторяется, сообщите оператору.';
  return message;
}
// Выбор JSON-файла пакета: скрытый DOM input внутри жеста пользователя.
// Отмена выбора — не ошибка; содержимое читается только в JS-ядре.
function pickRecoveryFile() {
  return new Promise(resolve => {
    const input = node('input');
    input.type = 'file'; input.accept = '.json,application/json';
    input.style.display = 'none'; input.tabIndex = -1;
    input.setAttribute('aria-hidden', 'true');
    const done = file => { input.remove(); resolve(file); };
    input.addEventListener('change', () => done(input.files?.[0] || null), { once: true });
    input.addEventListener('cancel', () => done(null), { once: true });
    document.body.append(input);
    input.click();
  });
}
function recoveryScreen() {
  recoveryPackage = null; recoveryBusy = false;
  recoveryState = { step: 'form', busy: false, stepId: null, fileName: null,
    cloudLoading: true,
    packageAccount: null, prfAvailable: false, error: null };
  hostFlutter();
  const recoveryAction = async (kind, raw = '{}') => {
    try {
      const data = JSON.parse(raw);
      switch (kind) {
        case 'ready': {
          flutterReady(); projectRecovery({});
          const current = () => window.shadeAction === recoveryAction && recoveryState;
          api('/api/v2/recovery-backup')
            .then(({ package: pkg }) => {
              if (current() && pkg && !recoveryPackage && !recoveryBusy) {
                recoveryPackage = pkg;
                projectRecovery({ fileName: 'Резервная копия Shade', packageAccount: pkg.genesis.account });
              }
            })
            .catch(() => {}) // Local file import also works without a Google session.
            .finally(() => { if (current()) projectRecovery({ cloudLoading: false }); });
          platformAuthenticatorAvailable()
            .then(available => { if (recoveryState) projectRecovery({ prfAvailable: available }); })
            .catch(() => {});
          break;
        }
        case 'recovery.pick': {
          if (recoveryBusy) break;
          const file = await pickRecoveryFile();
          if (!file) break; // выбор отменён — экран не меняется
          check(file.size <= 1024 * 1024, 'bad_package_shape');
          let pkg;
          try { pkg = JSON.parse(await file.text()); } catch { throw Error('bad_package_json'); }
          check(pkg && typeof pkg === 'object' && !Array.isArray(pkg) && pkg.backup && pkg.genesis &&
            typeof pkg.genesis.account === 'string' && /^[a-z0-9_]{3,32}$/.test(pkg.genesis.account),
            'bad_package_shape');
          // Полная проверка формы genesis и полей пакета до ввода фразы:
          // битый/чужой файл отсекается сразу с честным текстом.
          try { genesisText(pkg.genesis); } catch { throw Error('bad_package_shape'); }
          check(pkg.backup.version === 2 && typeof pkg.backup.ciphertext === 'string' &&
            typeof pkg.backup.salt === 'string' && typeof pkg.backup.iv === 'string' &&
            typeof pkg.backup.publicKey === 'string' && typeof pkg.backup.rootFingerprint === 'string',
            'bad_package_shape');
          recoveryPackage = pkg;
          projectRecovery({ fileName: file.name, packageAccount: pkg.genesis.account, error: null });
          break;
        }
        case 'recovery.run': {
          if (recoveryBusy) break; // защита от повторного запуска
          check(recoveryPackage, 'Сначала выберите файл recovery-пакета.');
          const phrase = typeof data.recoveryPhrase === 'string' ? data.recoveryPhrase.trim().replace(/\s+/g, ' ') : '';
          check(phrase.length >= MIN_RECOVERY_PASSWORD_LENGTH,
            `Введите пароль восстановления (минимум ${MIN_RECOVERY_PASSWORD_LENGTH} символов).`);
          const protection = data.protection === 'prf' ? 'prf' : 'phrase';
          let passphrase, binding;
          if (protection === 'prf') {
            // WebAuthn-жест: создание привязки до длительной криптографии.
            projectRecovery({ busy: true, stepId: 'binding', error: null });
            try { ({ binding, passphrase } = await createDeviceBinding(recoveryPackage.genesis.account)); }
            catch (error) {
              if (error.message === 'prf_unavailable') {
                projectRecovery({ busy: false, stepId: null, prfAvailable: false,
                  error: recoveryErrors.prf_unavailable });
                break;
              }
              throw error;
            }
          } else {
            passphrase = typeof data.devicePassphrase === 'string' ? data.devicePassphrase : '';
            check(passphrase.length >= 16, 'Фраза устройства должна быть не короче 16 символов.');
          }
          recoveryBusy = true;
          projectRecovery({ busy: true, stepId: 'unlock', error: null });
          try {
            await client.recoverWithBackup(recoveryPackage, phrase, { passphrase, binding },
              stepId => projectRecovery({ stepId }));
            projectRecovery({ busy: false, stepId: null, step: 'done' });
          } finally { recoveryBusy = false; }
          break;
        }
        case 'recovery.finish':
          recoveryPackage = null; recoveryState = null;
          await openApp();
          break;
        case 'recovery.back': location.reload(); break;
        default: throw Error('Неизвестное действие интерфейса');
      }
      return JSON.stringify({ ok: true });
    } catch (error) {
      // Ошибка — часть проекции экрана, а не скрытый сбой действия.
      recoveryBusy = false;
      projectRecovery({ busy: false, stepId: null, error: recoveryErrorText(error) });
      return JSON.stringify({ ok: true });
    }
  };
  window.shadeAction = recoveryAction;
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
// Full-screen re-login prompt: the notice banner alone left users stuck —
// the vault (keys) stays on this device, only the browser session died.
function sessionOverlay(show) {
  let box = document.querySelector('#session-overlay');
  if (!show) { box?.remove(); return; }
  if (box) return;
  box = node('div', undefined, 'session-overlay'); box.id = 'session-overlay';
  const card = node('div', undefined, 'session-card');
  card.append(node('h3', 'Сессия истекла'),
    node('p', 'Ключи сохранены на этом устройстве. Войдите снова, чтобы продолжить переписку.'));
  const button = node('button', 'Войти через Google', 'btn primary');
  button.type = 'button';
  button.onclick = () => { window.location.assign('/auth/google'); };
  card.append(button);
  box.append(card);
  document.body.append(box);
}
function render() {
  if (!ready || !window.shadeReceive) return;
  hookDialogRouting();
  const accounts = [...new Set([...users.map(u => u.account), ...Object.keys(client.state.contacts),
    ...client.state.messages.flatMap(m => [m.from,m.to]), ...(client.unverified || [])])]
    .filter(a => a !== client.session.account);
  // D1: баннер миграции открытого диалога проецируется в существующий канал
  // connection/connected (Flutter-шапка чата показывает его без изменений UI).
  const migrationView = migrationBannerProjection({ peer: selected, account: client.session.account,
    routing: dialogRoutingCache.get(selected), lastError: client.lastError, online: navigator.onLine });
  const connection = migrationView ? migrationView.connection :
    !navigator.onLine ? 'Нет сети · история сохранена' : client.lastError ?
    (errors[client.lastError] || 'Ошибка синхронизации · повтор через 15 секунд') :
    client.connected ? 'Подключено · E2EE' : 'Переподключение…';
  const connected = migrationView ? false : client.connected && navigator.onLine && !client.lastError;
  sessionOverlay(client.lastError === 'google_login_required' || client.lastError === 'login_required');
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
    account: client.session.account, selected, connection, connected,
    // D1: аддитивная проекция per-dialog routing (подписанный fetch журнала).
    dialogRouting: Object.fromEntries([...dialogRoutingCache]
      .filter(([, record]) => record.state)
      .map(([peer, record]) => [peer, { state: record.state, revision: record.revision, rolledBackAt: record.rolledBackAt }])),
    peers: [
      { account: client.session.account, favorites: true, pinned: true,
        name: 'Избранное', avatarDigest: client.state.profile?.avatarDigest || '' },
      ...accounts.map(account => ({ account, pinned: !!contact(account),
        // TOFU-контакты (trust='tofu') получают бейдж «Ключ не сверен»;
        // старые контакты без поля trust считаются сверенными.
        unverified: (client.unverified || []).includes(account) || contact(account)?.trust === 'tofu',
        ...meta(account) })),
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
      canSaveRecovery: Boolean(client.state.backup && !client.state.own.genesis.legacy),
      cloudRecoverySaved,
    },
    typing: client.typingUntil || {},
    presence: client.presence || {},
    key: keyInfo,
    platform: platformName(),
    email: sessionEmail,
    devices: (client.state.own.history.at(-1)?.devices || []).map(({id}) =>
      ({id, current: id === client.session.id,
        name: id === client.session.id ? thisDeviceName() : undefined})),
    positions: ui.positions, readUntil: ui.readUntil,
  }));
  // Периодический подписанный fetch открытого диалога: wake-подсказки могут
  // потеряться, авторитет — серверный journal (троттлинг внутри refresh).
  if (selected && selected !== client.session.account) refreshDialogRouting(selected);
  announceIncoming();
}
// Own key presentation data (public material only): the identicon seed is
// sha256 over the SPKI public key (matching the Android key card) and the
// digest is the genesis fingerprint used for cross-device comparison.
let keyInfo = null, sessionEmail = null;
function platformName() {
  const ua = navigator.userAgent;
  const appleMobile = /iPhone|iPad|iPod/.test(ua) ||
    (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  return appleMobile ? 'ios' : /Android/.test(ua) ? 'android' : 'desktop';
}
function thisDeviceName() {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? 'Edge' : /OPR\//.test(ua) ? 'Opera'
    : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : 'Safari';
  const os = /iPhone|iPad|iPod/.test(ua) ? 'iOS' : /Android/.test(ua) ? 'Android'
    : /Windows/.test(ua) ? 'Windows' : /Mac/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : 'web';
  const short = String(client.session?.id || '').slice(0, 8);
  return `${browser} · ${os}${short ? ` · ${short}` : ''}`;
}
// Общий хостинг Flutter-проекции: используется и обычным входом (openApp),
// и экраном восстановления. Движок загружается один раз за жизнь страницы;
// переход recovery → чат меняет только проекцию и обработчик shadeAction.
let flutterHosted = false, flutterLoading = null;
function hostFlutter() {
  if (flutterHosted) return;
  flutterHosted = true;
  // Implicit Flutter view (attached to <body>): the embedded custom-host path
  // froze the view metrics when the mobile keyboard resized the page — the
  // composer ended up under the keyboard and typing was blind (staging 743f700).
  // The guard keeps a single engine load across recovery → chat transitions.
  root.hidden = true;
  flutterLoading = node('p', 'Загрузка интерфейса Shade…', 'flutter-loading');
  document.body.append(flutterLoading);
  document.body.classList.add('flutter-ready'); updateViewport();
  const script = node('script'); script.src = '/flutter-ui/flutter_bootstrap.js';
  script.onerror = () => {
    flutterHosted = false;
    if (recoveryState) {
      errorStep('Не удалось загрузить интерфейс восстановления. Проверьте соединение и обновите страницу.');
      return;
    }
    notice('Не удалось загрузить Flutter UI. Проверьте сборку и соединение; ключи сохранены.');
  };
  document.head.append(script);
}
function flutterReady() { flutterLoading?.remove(); flutterLoading = null; }
async function openApp() {
  api('/api/session').then(status => {
    if (status.account === client.session?.account && status.cloudRecoverySaved) {
      cloudRecoverySaved = true;
      render();
    }
  }).catch(() => {});
  ui = { selected: null, positions: {}, readUntil: {} };
  uiStorage = `shade-ui:${client.vault.id}`;
  try {
    const saved = JSON.parse(sessionStorage.getItem(uiStorage));
    if (saved && typeof saved === 'object') ui = { selected: typeof saved.selected === 'string' ? saved.selected : null,
      positions: saved.positions || {}, readUntil: saved.readUntil || {} };
  } catch { /* UI preferences never prevent unlocking encrypted history. */ }
  const confirmed = Object.create(null);
  for (const message of client.state.messages) {
    if (message.to !== client.session.account || !message.readAt) continue;
    confirmed[message.from] = Math.max(confirmed[message.from] ?? 0, message.createdAt);
  }
  const storedMarks = await readReadMarks(client.session).catch(() => ({}));
  ui.readUntil = mergeReadMarks(storedMarks, confirmed, ui.readUntil);
  saveReadMarks(client.session, ui.readUntil).catch(() => {});
  ready = true;
  selected = ui.selected;
  // Restored conversation resumes its presence watch (queued while offline).
  if (selected && selected !== client.session?.account) client.watchPeer(selected, true);
  hostFlutter();
  try {
    const spki = client.state.own.genesis?.firstDevice?.signingKey || '';
    const raw = Uint8Array.from(atob(spki), ch => ch.charCodeAt(0));
    const seed = new Uint8Array(await crypto.subtle.digest('SHA-256', raw));
    keyInfo = { seed: [...seed].map(b => b.toString(16).padStart(2, '0')).join(''),
      digest: await hash(genesisText(client.state.own.genesis)) };
  } catch { keyInfo = null; /* presentation data only */ }
  window.shadeAction = async (kind, raw = '{}') => {
    try {
      const data = JSON.parse(raw);
      switch (kind) {
        case 'ready': flutterReady(); render(); break;
        case 'select':
          selected = data.account; ui.selected = selected; saveUi(); render();
          client.watchPeer(selected, true);
          refreshDialogRouting(selected, true);
          client.loadProfile().catch(() => {});
          if (!contact(selected) && selected !== client.session.account) verifyContact(selected); break;
        case 'find': {
          // Новый разговор: цепь манифестов проверяется от genesis, контакт
          // закрепляется автоматически (TOFU); чат открыт, отправлять можно сразу.
          const account = String(data.account ?? '').trim().replace(/^@/, '').toLowerCase();
          if (!/^[a-z0-9_]{3,32}$/.test(account)) throw Error('Некорректный никнейм');
          if (account !== client.session.account) await client.tofuContact(account);
          selected = account; ui.selected = selected; saveUi(); render();
          client.watchPeer(selected, true);
          refreshDialogRouting(selected, true);
          client.loadProfile().catch(() => {});
          client.sync().catch(() => {});
          break;
        }
        case 'back': selected = null; ui.selected = null; saveUi(); render();
          if (data.account) client.watchPeer(data.account, false); break;
        case 'typing': client.sendTyping(data.account); break;
        case 'read': {
          if (document.hidden || selected !== data.account ||
              !/^[a-z0-9_]{3,32}$/.test(data.account) || !Number.isSafeInteger(data.until)) break;
          const previous = ui.readUntil[data.account] || 0;
          if (data.until > previous) {
            ui.readUntil[data.account] = data.until; saveUi();
            const saved = saveReadMarks(client.session, { [data.account]: data.until });
            // Read-ACK (contract C5): the relay op runs on refs the read mark
            // covers; failures surface honestly without breaking the UI.
            // Media display messages carry a local pseudo-ref (media:<id>):
            // their delivery is acknowledged through the chunk messages' own
            // refs, which the relay accepts, so they are filtered out here —
            // one pseudo-ref would otherwise reject the whole read batch.
            const refs = client.state.messages
              .filter(m => m.from === data.account && m.createdAt <= data.until &&
                !m.readAt && m.status === 'received')
              .map(m => m.ref)
              .filter(ref => /^[a-z0-9_]{3,32}:(primary|[a-f0-9]{64}):[a-f0-9]{64}$/.test(ref))
              .slice(-200);
            // A failed network receipt must not reset the local unread count.
            render();
            await saved.catch(() => {});
            if (refs.length) client.markRead(data.account, refs)
              .catch(e => notice(errors[e.message] || e.message));
          } break;
        }
        case 'position': ui.positions[data.account] = {offset:Math.max(0,data.offset),bottom:!!data.bottom}; saveUi(); break;
        case 'send': await client.send(data.account, data.text, data.reply || null);
          // 409 миграции: состояние диалога только что обнаружено/изменилось —
          // немедленный подписанный fetch для баннера (сообщение осталось в outbox).
          if (MIGRATION_HOLD_CODES.has(client.lastError)) refreshDialogRouting(data.account, true);
          client.sync().catch(e => notice(errors[e.message] || e.message)); break;
        case 'sendMedia': await client.sendMedia(data.account, data.image, data.mime || 'image/jpeg');
          if (MIGRATION_HOLD_CODES.has(client.lastError)) refreshDialogRouting(data.account, true);
          client.sync().catch(e => notice(errors[e.message] || e.message)); break;
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
        case 'history.send': {
          const { sent, skipped } = await client.transferSavedHistory(data.id);
          notice(sent
            ? `Подготовлено записей: ${sent}. На Android откройте «Устройства» → «Получить переписку».${skipped ? ` Пропущено слишком больших сообщений: ${skipped}.` : ''}`
            : skipped ? 'Сообщения превышают лимит переноса.' : 'Нет сохранённых сообщений для переноса.');
          break;
        }
        case 'devices.revoke': await client.revokeDevice(data.id); break;
        case 'devices.pair': pairDeviceDialog(); break;
        case 'push.toggle': {
          // Push is optional: failures surface as an honest notice, never as
          // an unhandled action error (the chat must keep working). Success
          // feedback is brief — a status confirmation, not a lingering banner.
          try {
            const status = await client.pushStatus();
            if (status.subscribed) { await client.disablePush(); notice('Уведомления выключены.', 3500); }
            else { await client.enablePush(); notice('Уведомления включены · только сигнал, без текста сообщений.', 3500); }
          } catch (e) { notice(errors[e.message] || e.message); }
          break;
        }
        case 'verify': verifyContact(data.account); break;
        case 'refresh': users = await client.users(); render(); break;
        case 'identity': {
          // Key card dialog, styled after the Android 'Мой ключ' sheet:
          // identicon from sha256(publicKey) + the genesis digest in grouped
          // hex. Whitespace is stripped on both sides when comparing, so the
          // grouping never changes the fingerprint value.
          const digest = await hash(genesisText(client.state.own.genesis));
          const canvas = document.createElement('canvas');
          canvas.width = 148; canvas.height = 148;
          canvas.setAttribute('aria-label', 'Идентикон ключа');
          canvas.style.cssText = 'width:148px;height:148px;border-radius:14px;display:block;margin:0 auto;background:#000';
          const palette = ['#2a2a2a', '#5c5c5c', '#9e9e9e', '#ededed'];
          const seed = keyInfo?.seed || digest;
          const g2d = canvas.getContext('2d');
          for (let i = 0; i < 64; i++) {
            const byte = parseInt(seed.slice(i >> 1, (i >> 1) + 2) || '0', 16);
            g2d.fillStyle = palette[byte & 3];
            g2d.fillRect((i % 8) * 18.5, (i >> 3) * 18.5, 18.5, 18.5);
          }
          const groups = (digest.toUpperCase().match(/.{1,4}/g) || []);
          const grouped = Array.from({length: (groups.length + 3) >> 2},
              (_, line) => groups.slice(line * 4, line * 4 + 4).join(' ')).join('\n');
          showDialog('Мой ключ', [node('p', '@' + client.session.account + ' · ваш ключ'),
            canvas, node('code', grouped),
            node('p', 'Покажите рисунок и полный код собеседнику и сравните через независимый доверенный канал.', 'muted')]);
          break;
        }
        case 'backup': downloadBackup(); break;
        case 'backup.cloud':
          check(client.state.backup, 'На этом устройстве нет резервной копии.');
          await client.operation('recovery.backup', client.state.backup);
          cloudRecoverySaved = true;
          render();
          notice('Зашифрованная копия сохранена на сервере Shade');
          break;
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
      await client.pinContact(account, fingerprint); dialog.close(); render();
      notice('Ключ собеседника сверен.', 3500); await client.sync(); });
    showDialog('@' + account, [instructions, code, field, button]);
  });
}
client.addEventListener('change', render);
window.addEventListener('offline', render); window.addEventListener('online', render);
window.addEventListener('pagehide', () => client.stop());
window.addEventListener('pageshow', event => { if (event.persisted && ready) client.start().catch(e => notice(e.message)); });

async function boot() {
  if (!window.isSecureContext || !crypto.subtle) throw Error('Для криптографии требуется HTTPS или localhost.');
  const installRequired = platformName() === 'ios' && !isStandalone();
  // Existing browser vaults can still be unlocked to export or link them.
  let vaults;
  if (installRequired) {
    vaults = await listVaults().catch(() => []);
    if (!vaults.length) { appleInstallStep(); return; }
  }
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
  // Surfaces automatically once the relay includes the Google email in
  // /api/session (server-side gap tracked for Qwen); absent until then.
  sessionEmail = typeof status.email === 'string' && status.email ? status.email : null;
  if (!status.authenticated) { welcomeStep(status); return; }
  loggedIn = !status.offline;
  vaults ??= await listVaults();
  const matching = vaults.filter(v => v.account === status.account);
  if (matching.length || (!status.account && vaults.length)) {
    unlockStep(matching.length ? matching : vaults, status);
    return;
  }
  if (installRequired) { appleInstallStep(); return; }
  if (status.account) { linkStep(status.account); return; }
  registrationStep({ protection: await platformAuthenticatorAvailable() ? 'system' : 'pin' });
}
boot().catch(error => errorStep(errors[error.message] || error.message));
if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('/alpha-sw.js', { updateViaCache: 'none' }).then(reg => {
    // A waiting worker means a newer offline shell exists. Never switch
    // automatically: the user explicitly reloads, keys and history untouched.
    const offerUpdate = () => {
      if (!navigator.serviceWorker.controller) return;
      const button = node('button', 'Перезагрузить и обновить', 'btn primary'); button.type = 'button';
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
// Экспорт для тестов проекции D1 (чистые функции и карта честных текстов);
// поведение страницы не меняется.
export { errors };

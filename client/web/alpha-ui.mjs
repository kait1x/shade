import { AlphaClient, api } from './alpha-client.mjs';
import { listVaults } from './device_crypto.mjs';
import { hash, genesisText } from './protocol/device-v2.mjs';
import { createDeviceBinding, unlockDeviceBinding, platformAuthenticatorAvailable,
  generateRecoveryPhrase, bindingErrorText } from './device_binding.mjs';

const root = document.querySelector('#root'), dialog = document.querySelector('#dialog');
const client = new AlphaClient();
// QA introspection: the page context can always reach whatever its own scripts
// hold; this only names the instance. CryptoKey material stays non-extractable.
window.__shadeClient = client;
const contact = account => client.state && Object.hasOwn(client.state.contacts, account) ? client.state.contacts[account] : null;
let selected = null, users = [], ready = false, actionTail = Promise.resolve(), noticeTimer, loggedIn = false;
// Registration draft shared by the onboarding steps (nickname → identity → recovery).
const draft = { account: '' };
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
  showDialog('Установить Shade', [node('p', 'В Safari нажмите «Поделиться» → «На экран Домой» → «Добавить». Открывайте Shade с этой иконки.'), node('p', 'Ключи остаются в этом браузере. Не очищайте данные сайта. Перед установкой сохраните recovery-пакет. Установка PWA не переносит ключи из другого браузера.', 'muted')]);
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
// card, step dots, fineprint and a quiet details expander.
function onboard({ title, subtitle, cardTitle, cardSubtitle, medallion = false, dots = 0, footer, details, children }) {
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
  if (dots) {
    const dotsEl = node('div', undefined, 'dots');
    dotsEl.setAttribute('role', 'img');
    dotsEl.setAttribute('aria-label', `Шаг ${dots} из 3`);
    for (let step = 1; step <= 3; step++) dotsEl.append(node('span', undefined, step === dots ? 'dot active' : 'dot'));
    inner.append(dotsEl);
  }
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
function nicknameStep() {
  const form = node('form');
  const nickname = input(form, 'Ваш никнейм', 'account', 'text', 0,
    { prefix: '@', placeholder: 'например, kait1x', autocomplete: 'off' });
  nickname.maxLength = 32;
  nickname.autocapitalize = 'none';
  nickname.spellcheck = false;
  nickname.setAttribute('enterkeyhint', 'next');
  const error = node('p', undefined, 'field-error');
  error.setAttribute('role', 'alert');
  error.hidden = true;
  form.append(error);
  submit(form, 'Продолжить');
  const box = onboard({
    cardTitle: 'Давайте познакомимся',
    cardSubtitle: 'По никнейму друзья смогут найти вас.',
    children: [form, changeAccountButton()],
    dots: 1,
    footer: 'Ключи и история остаются в этом браузере.',
  });
  const fieldBox = box.querySelector('.field-box');
  nickname.addEventListener('input', () => {
    error.hidden = true;
    nickname.removeAttribute('aria-invalid');
    fieldBox.classList.remove('invalid');
  });
  form.onsubmit = event => {
    event.preventDefault();
    const value = nickname.value.trim().toLowerCase();
    if (!/^[a-z0-9_]{3,32}$/.test(value)) {
      error.textContent = 'От 3 до 32 символов: a–z, 0–9 и _';
      error.hidden = false;
      nickname.setAttribute('aria-invalid', 'true');
      fieldBox.classList.add('invalid');
      nickname.focus();
      return;
    }
    draft.account = value;
    identityStep();
  };
}
// Identity step: keys are generated automatically. When the platform
// authenticator supports PRF, the device passphrase is derived from it and the
// user invents nothing; otherwise a single device passphrase is requested.
function identityStep() {
  platformAuthenticatorAvailable().then(available => available ? prfIdentityStep() : phraseIdentityStep(true));
}
function prfIdentityStep() {
  const form = node('form');
  const note = node('p', undefined, 'gen-progress');
  note.hidden = true;
  submit(form, 'Создать ключи и включить защиту');
  const fallbackLink = node('button', 'Использовать фразу устройства', 'btn-text');
  fallbackLink.type = 'button';
  fallbackLink.onclick = () => phraseIdentityStep(false);
  onboard({
    cardTitle: 'Создаём вашу идентичность',
    cardSubtitle: 'RSA-ключи создаются в этом браузере и защищаются биометрией устройства. Придумывать фразу не нужно.',
    children: [form, fallbackLink, note],
    dots: 2,
    footer: 'Сервер и Google не получают ключи шифрования.',
  });
  form.onsubmit = event => {
    event.preventDefault();
    action(async () => {
      showProgress(note, 'Подтверждаем защиту устройства…');
      let binding, passphrase;
      try { ({ binding, passphrase } = await createDeviceBinding(draft.account)); }
      catch (error) { note.hidden = true; throw Error(bindingErrorText(error) || `Не удалось настроить защиту устройства: ${error.message}`); }
      showProgress(note, 'Создаём RSA-4096 ключи… Оставьте страницу открытой.');
      const recoveryPhrase = generateRecoveryPhrase();
      await client.prepare(draft.account, passphrase, recoveryPhrase, binding);
      await backupStep(recoveryPhrase);
    });
  };
}
function phraseIdentityStep(auto) {
  const form = node('form');
  const phrase = input(form, 'Фраза устройства · от 16 символов', 'passphrase', 'password', 16, { autocomplete: 'new-password' });
  const confirm = input(form, 'Повторите фразу устройства', 'confirm', 'password', 16, { autocomplete: 'new-password' });
  const note = node('p', undefined, 'gen-progress');
  note.hidden = true;
  form.append(note);
  submit(form, 'Создать ключи на этом устройстве');
  onboard({
    cardTitle: 'Создаём вашу идентичность',
    cardSubtitle: auto
      ? 'Биометрическая защита недоступна в этом браузере. Придумайте фразу устройства — она шифрует ключи и историю только здесь.'
      : 'Фраза устройства шифрует ключи и историю в этом браузере. Сервер её не получает.',
    children: [form],
    dots: 2,
    footer: 'Recovery-фразу сгенерируем автоматически на следующем шаге.',
  });
  form.onsubmit = event => {
    event.preventDefault();
    action(async () => {
      if (phrase.value !== confirm.value) throw Error('Фразы устройства не совпадают');
      showProgress(note, 'Создаём RSA-4096 ключи… Оставьте страницу открытой.');
      const recoveryPhrase = generateRecoveryPhrase();
      await client.prepare(draft.account, phrase.value, recoveryPhrase);
      phrase.value = ''; confirm.value = '';
      await backupStep(recoveryPhrase);
    });
  };
}
function backupStep(recoveryPhrase) {
  const box = onboard({
    cardTitle: 'Сохраните recovery-пакет',
    cardSubtitle: 'Пакет зашифрован этой фразой. Сохраните файл вне устройства и запишите фразу отдельно. Без пакета или другого доверенного устройства потерянные ключи не восстановить.',
    children: [],
    dots: 3,
    footer: 'Пакет содержит только зашифрованный recovery-ключ. Приватные ключи устройства в него не входят.',
  });
  const card = box.querySelector('.onboard-card');
  if (recoveryPhrase) {
    card.append(node('span', 'Recovery-фраза · запишите её', 'field-label'));
    const phraseBox = node('div', undefined, 'phrase-box');
    phraseBox.append(node('code', recoveryPhrase));
    card.append(phraseBox);
    const copy = node('button', 'Скопировать фразу', 'btn outline');
    copy.type = 'button';
    copy.onclick = async () => {
      try { await navigator.clipboard.writeText(recoveryPhrase); notice('Recovery-фраза скопирована'); }
      catch { notice('Не удалось скопировать. Выделите фразу вручную.'); }
    };
    card.append(copy);
  }
  const download = node('button', 'Скачать recovery-пакет', 'btn outline');
  download.type = 'button';
  download.onclick = downloadBackup;
  const form = node('form');
  const checkLabel = node('label', undefined, 'check');
  const checkbox = node('input'); checkbox.type = 'checkbox'; checkbox.required = true;
  checkLabel.append(checkbox, node('span', 'Я сохранил пакет и recovery-фразу отдельно'));
  form.append(checkLabel);
  const finish = submit(form, 'Завершить регистрацию');
  card.append(download, form);
  const renew = node('details', undefined, 'expain');
  renew.append(node('summary', 'Если регистрация прервалась или прошло больше 4 минут'));
  renew.append(node('p', 'Обновите пакет и скачайте его заново. Ключи устройства и recovery-ключ сохранятся. Это доступно только до регистрации аккаунта.', 'expain-body'));
  const renewForm = node('form');
  const recovery = input(renewForm, 'Recovery-фраза', 'recovery', 'password', 24);
  submit(renewForm, 'Обновить пакет');
  renew.append(renewForm);
  card.append(renew);
  form.onsubmit = event => {
    event.preventDefault();
    action(async () => {
      finish.replaceChildren(spinner(18), node('span', 'Подключаемся к серверу…'));
      try { await client.register(); await openApp(); }
      finally { finish.textContent = 'Завершить регистрацию'; }
    });
  };
  renewForm.onsubmit = event => {
    event.preventDefault();
    action(async () => { await client.renewPending(recovery.value); recovery.value = ''; await backupStep(recoveryPhrase); });
  };
}
function unlockStep(candidates, status) {
  const form = node('form');
  let select = null;
  if (candidates.length > 1) {
    select = node('select');
    select.setAttribute('aria-label', 'Локальное устройство');
    for (const v of candidates) { const option = node('option', '@' + v.account); option.value = v.id; select.append(option); }
    form.append(select);
  }
  const chosen = () => candidates.find(v => v.id === (select ? select.value : candidates[0].id));
  const phraseField = input(form, 'Фраза устройства', 'passphrase', 'password', 0, { autocomplete: 'current-password' });
  const note = node('p', undefined, 'gen-progress');
  note.hidden = true;
  form.append(note);
  submit(form, 'Разблокировать');
  const box = onboard({
    cardTitle: 'Разблокировать Shade',
    cardSubtitle: 'Фраза расшифровывает ключи и историю только в этом браузере. Сервер её не получает.',
    children: [form, changeAccountButton()],
  });
  const card = box.querySelector('.onboard-card');
  const hint = node('p', undefined, 'card-sub');
  const refresh = () => {
    const vault = chosen();
    const byPhrase = vault.binding?.method !== 'prf';
    phraseField.closest('label').hidden = !byPhrase;
    phraseField.required = byPhrase;
    hint.textContent = byPhrase ? `Локальные ключи @${vault.account}` : 'Ключи @' + vault.account + ' защищены биометрией этого устройства.';
    card.insertBefore(hint, form);
  };
  if (select) select.addEventListener('change', refresh);
  refresh();
  form.onsubmit = event => {
    event.preventDefault();
    action(async () => {
      const vault = chosen();
      let passphrase;
      if (vault.binding?.method === 'prf') {
        showProgress(note, 'Подтверждаем защиту устройства…');
        passphrase = await unlockDeviceBinding(vault.binding);
      } else passphrase = phraseField.value;
      // loadForPairing also resumes an interrupted second-device pairing: a
      // vault without committed state is a pairing in progress, not a loss.
      const result = await client.loadForPairing(vault, passphrase);
      phraseField.value = '';
      if (result.pending) { pairingOfferStage(); return; }
      if (status.account) await openApp(); else await backupStep();
    });
  };
}
function linkStep(account) {
  const pair = node('button', 'Подключить это устройство', 'btn primary'); pair.type = 'button';
  pair.onclick = () => pairingOnboarding(account);
  onboard({
    cardTitle: 'Нужна привязка устройства',
    cardSubtitle: 'Этот Google-аккаунт уже зарегистрирован, но в этом браузере нет его ключей. Ключи создаются здесь и входят в аккаунт только после подтверждения на доверенном устройстве.',
    children: [pair, node('p', 'Восстановление после потери всех устройств появится позже; исходные RSA-ключи не заменяются.', 'muted'), changeAccountButton()],
  });
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
  field.placeholder = 'Вставьте запрос подключения (shade-pair-v1:…)';
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
      node('p', `Отпечаток нового устройства: ${reviewed.deviceId}`),
      node('p', 'Убедитесь, что это ВАШЕ новое устройство. Подтверждение даёт ему доступ ко всем будущим сообщениям аккаунта.', 'muted'),
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
  onboard({
    cardTitle: 'Подключение устройства · шаг 2 из 2',
    cardSubtitle: 'Покажите запрос подключения на доверенном устройстве и вставьте полученное подтверждение. Ключи уже созданы в этом браузере.',
    children: [codeForm, offer, copy, confirmForm, changeAccountButton()],
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
        case 'devices.pair': pairDeviceDialog(); break;
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
  if (!status.authenticated) { welcomeStep(status); return; }
  loggedIn = !status.offline;
  const vaults = await listVaults();
  const matching = vaults.filter(v => v.account === status.account);
  if (status.account && !matching.length) { linkStep(status.account); return; }
  if (matching.length || (!status.account && vaults.length)) {
    unlockStep(matching.length ? matching : vaults, status);
    return;
  }
  nicknameStep();
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

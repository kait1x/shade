const byId = id => document.getElementById(id);
const ui = Object.fromEntries([
  'connection', 'details', 'refresh', 'accounts', 'online', 'devices', 'queued',
  'query', 'online-only', 'notice', 'account-table', 'rows', 'results', 'previous', 'next',
].map(id => [id, byId(id)]));
const number = new Intl.NumberFormat('ru-RU');
const date = new Intl.DateTimeFormat('ru-RU', { dateStyle: 'short', timeStyle: 'short' });
let page = 1;
let pages = 1;
let loaded = false;
let currentRequest;
let debounce;

function cell(value) {
  const td = document.createElement('td');
  td.textContent = value;
  return td;
}

function render(data) {
  for (const key of ['accounts', 'online', 'devices', 'queued']) {
    ui[key].textContent = number.format(data[key]);
  }
  const minutes = Math.floor(data.uptime / 60);
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor(minutes / 60) % 24;
  const uptime = [days ? days + ' д' : '', hours ? hours + ' ч' : '', minutes % 60 + ' мин'].filter(Boolean).join(' ');
  ui.details.textContent = 'В работе ' + uptime + ' · обновлено ' + date.format(data.updatedAt);
  ui.rows.replaceChildren(...data.rows.map(account => {
    const tr = document.createElement('tr');
    const presence = cell('');
    const badge = document.createElement('span');
    badge.className = 'presence';
    badge.dataset.online = String(account.online);
    badge.textContent = account.online ? 'В сети' : 'Не в сети';
    presence.append(badge);
    tr.append(cell('@' + account.account), cell(number.format(account.devices)), presence,
      cell(account.lastSeen ? date.format(account.lastSeen) : '—'));
    return tr;
  }));
  ui['account-table'].hidden = data.rows.length === 0;
  ui.notice.hidden = data.rows.length > 0;
  ui.notice.textContent = 'Аккаунты не найдены.';
  ui.results.textContent = number.format(data.matches) + ' · страница ' + data.page + ' из ' + data.pages;
  page = data.page;
  pages = data.pages;
  ui.previous.disabled = page <= 1;
  ui.next.disabled = page >= pages;
}

async function load() {
  currentRequest?.abort();
  const controller = new AbortController();
  currentRequest = controller;
  ui.refresh.disabled = true;
  try {
    const params = new URLSearchParams({
      q: ui.query.value,
      online: ui['online-only'].checked ? '1' : '0',
      page: String(page),
    });
    const response = await fetch('/overview?' + params, { signal: controller.signal });
    if (!response.ok) throw new Error('Overview unavailable');
    const data = await response.json();
    if (currentRequest !== controller) return;
    render(data);
    loaded = true;
    ui.connection.textContent = 'Сервер в сети';
    ui.connection.dataset.online = 'true';
    delete ui.connection.dataset.error;
  } catch (error) {
    if (error.name === 'AbortError' || currentRequest !== controller) return;
    ui.connection.textContent = 'Связь прервана';
    ui.connection.dataset.error = 'true';
    delete ui.connection.dataset.online;
    if (!loaded) {
      ui.details.textContent = 'Состояние сервера недоступно';
      ui.notice.textContent = 'Проверьте SSH-туннель и нажмите «Обновить».';
    }
  } finally {
    if (currentRequest === controller) {
      currentRequest = null;
      ui.refresh.disabled = false;
    }
  }
}

function filter(delay) {
  page = 1;
  clearTimeout(debounce);
  debounce = setTimeout(load, delay);
}

ui.refresh.addEventListener('click', load);
ui.query.addEventListener('input', () => filter(180));
ui['online-only'].addEventListener('change', () => filter(0));
ui.previous.addEventListener('click', () => { if (page > 1) { page--; load(); } });
ui.next.addEventListener('click', () => { if (page < pages) { page++; load(); } });
setInterval(() => { if (!document.hidden && !currentRequest) load(); }, 15000);
load();

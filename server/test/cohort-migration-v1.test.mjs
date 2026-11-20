// Остаточная проводка когортной миграции D1 на стороне v1 (server.js) против
// РЕАЛЬНОГО v1-сервера в изолированном temp-каталоге (синтетический fixture
// формата at-rest). Production data/VPS не трогаются. Покрыто: per-dialog
// guard (v2_active диалог отклоняет v1-send, полный rollback снимает guard,
// смешанный аккаунт остаётся под guard, abort не снимает guard, регрессия
// отсутствия секции dialogs и файла), reverseReplay ingestion (без дублей,
// consumed-журнал, сохранение существующих очередей, честный лог невалидного
// файла без падения сервиса, персистентность дедупа после рестарта).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomBytes, privateDecrypt, createDecipheriv, constants, sign as nodeSign } from 'node:crypto';
import { io } from 'socket.io-client';
import { freePort } from './helpers/alpha-fixture.mjs';
import { buildV1Fixture, v1Seal } from './helpers/v1-fixture.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

async function tempDir(prefix) {
  const build = path.join(serverRoot, 'build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, prefix));
}
const signWith = (value, key) => nodeSign('sha256', Buffer.from(Buffer.from(value).toString('base64')),
  { key, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
// Тот же алгоритм, что decryptData нативного v1 CryptoService.
function openV1Payload(payloadJson, privateKey) {
  const { k, d } = JSON.parse(payloadJson);
  const envelope = Buffer.from(privateDecrypt({ key: privateKey,
    padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, Buffer.from(k, 'base64')).toString('utf8'), 'base64');
  const data = Buffer.from(d, 'base64');
  const decipher = createDecipheriv('aes-256-gcm', envelope.subarray(1, 33), envelope.subarray(33));
  decipher.setAuthTag(data.subarray(data.length - 16));
  return Buffer.concat([decipher.update(data.subarray(0, data.length - 16)), decipher.final()]).toString('utf8');
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function waitFor(predicate, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await sleep(200);
  }
  throw new Error(`timeout: ${what}`);
}
const exists = file => fs.stat(file).then(() => true, () => false);
const dialogKey = (a, b) => [a, b].sort().join('|');
const guardPayload = (accounts, dialogs) => ({ version: 1, updatedAt: Date.now(),
  accounts, ...(dialogs ? { dialogs } : {}) });
const dialogRecord = (state, extra = {}) => ({ state, revision: 1, flippedAt: null, rolledBackAt: null, ...extra });

// Поднимает реальный server.js с заданным окружением и ждёт готовности.
async function startV1({ dir, secret, env, logsRef }) {
  const port = await freePort();
  const child = spawn(process.execPath, ['server.js'], { cwd: serverRoot, windowsHide: true,
    env: { ...process.env, NODE_ENV: 'test', TLS_TERMINATED_BY_PROXY: '1',
      BIND_HOST: '127.0.0.1', PORT: String(port), DATA_DIR: dir, SESSION_SECRET: secret,
      DASHBOARD_PASS: randomBytes(24).toString('hex'), ALLOW_LEGACY_REGISTRATION: 'true', ...env } });
  child.stdout.on('data', d => { logsRef.text += d; });
  child.stderr.on('data', d => { logsRef.text += d; });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(Error(`startup failed: ${logsRef.text}`)), 20000);
    const poll = setInterval(() => {
      if (logsRef.text.includes(`server on :${port}`)) { clearTimeout(timeout); clearInterval(poll); resolve(); }
    }, 50);
    child.once('exit', code => { clearInterval(poll); clearTimeout(timeout); reject(Error(`exit ${code}: ${logsRef.text}`)); });
  });
  return { child, port, base: `http://127.0.0.1:${port}` };
}
async function stopV1(child) {
  if (child.exitCode === null) { const exit = new Promise(r => child.once('exit', r)); child.kill(); await exit; }
}

test('v1 per-dialog guard: v2_active отказ, полный rollback снимает, смешанный под guard, регрессии', { timeout: 180000 }, async t => {
  const dir = await tempDir('coh-v1-guard-');
  const guardFile = path.join(dir, 'v2-migration-guard.json');
  const secret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(dir, { secret, users: [
    { account: 'dlg_alice' }, { account: 'dlg_bob' }, { account: 'dlg_carol' }] });
  const logsRef = { text: '' };
  const { child, base } = await startV1({ dir, secret, env: { SHADE_V2_GUARD_FILE: guardFile }, logsRef });
  const sockets = [];
  t.after(async () => { sockets.forEach(s => s.disconnect()); await stopV1(child); });
  const request = async (route, body, headers = {}) => {
    const response = await fetch(base + route, { method: body ? 'POST' : 'GET',
      headers: { 'Content-Type': 'application/json', ...headers },
      ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, data: await response.json() };
  };
  async function register(account) {
    const pair = keys.get(account);
    const challenge = (await request('/auth/challenge', { username: account })).data.challenge;
    const body = { username: account, publicKey: pair.publicKey, signature: signWith(pair.publicKey, pair.privateKey),
      challenge, proof: signWith(`shade-register:v1:${account}:${challenge}`, pair.privateKey) };
    const result = await request('/register', body);
    assert.equal(result.status, 200, JSON.stringify(result.data));
    return { ...result.data, body };
  }
  const alice = await register('dlg_alice');
  const bob = await register('dlg_bob');
  const carol = await register('dlg_carol');
  // Переподключение по-честному: прежний сокет аккаунта закрывается (v1 grace-
  // механизм выдаёт новый токен через sessionRefreshed), throttling IP (500 мс)
  // выдерживается паузой; токен отслеживается между подключениями.
  const liveSockets = new Map();
  const currentTokens = new Map();
  const connect = async (account, token) => {
    const previous = liveSockets.get(account);
    if (previous?.connected) { previous.disconnect(); await sleep(600); }
    for (let attempt = 0; attempt < 6; attempt++) {
      const socket = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false });
      sockets.push(socket);
      await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('connect_error', reject); socket.connect(); });
      socket.on('sessionRefreshed', e => { currentTokens.set(account, e.token); });
      socket.emit('register', { username: account, token: currentTokens.get(account) || token });
      const outcome = await new Promise(resolve => {
        const timer = setTimeout(() => resolve('timeout'), 15000);
        socket.once('registered', () => { clearTimeout(timer); resolve('registered'); });
        socket.once('authError', e => { clearTimeout(timer); resolve(e.error); });
        socket.once('error', e => { clearTimeout(timer); resolve(`error:${e?.message || ''}`); });
        socket.once('disconnect', () => { clearTimeout(timer); resolve('disconnect'); });
      });
      if (outcome === 'registered' || outcome === 'upgrade_required') {
        liveSockets.set(account, socket);
        return { socket, outcome };
      }
      socket.disconnect();
      await sleep(700);
    }
    throw new Error(`connect failed: ${account}`);
  };
  const send = (socket, to, text) => {
    const id = randomBytes(16).toString('hex');
    const data = v1Seal(text, keys.get(to).publicKey);
    return new Promise((resolve, reject) =>
      socket.timeout(20000).emit('message', { to, id, data },
        (err, ack) => err ? reject(err) : resolve({ ...ack, id, data })));
  };
  const writeGuard = async payload => { await fs.writeFile(guardFile, JSON.stringify(payload)); await sleep(1300); };

  // Guard-файла нет: обычное поведение v1 (регрессия отсутствия файла).
  const bobConn = await connect('dlg_bob', bob.token);
  assert.equal(bobConn.outcome, 'registered');
  assert.equal((await send(bobConn.socket, 'dlg_alice', 'до миграции')).ok, true);

  // v2_active диалог alice|bob: оба участника под guard, v1-send отклоняется.
  await writeGuard(guardPayload({ dlg_alice: 'f'.repeat(64), dlg_bob: 'f'.repeat(64) },
    { [dialogKey('dlg_alice', 'dlg_bob')]: dialogRecord('v2_active', { flippedAt: Date.now() }) }));
  assert.equal((await connect('dlg_alice', alice.token)).outcome, 'upgrade_required');
  const refused = await send(bobConn.socket, 'dlg_alice', 'в v2-диалог');
  assert.equal(refused.ok, false);
  assert.equal(refused.error, 'upgrade_required');
  // HTTP-маршруты аккаунтного guard сохранены (reissue токена).
  const freshChallenge = (await request('/auth/challenge', { username: 'dlg_alice' })).data.challenge;
  const reissue = await request('/register', { ...alice.body, challenge: freshChallenge,
    proof: signWith(`shade-register:v1:dlg_alice:${freshChallenge}`, keys.get('dlg_alice').privateKey) });
  assert.equal(reissue.status, 403);
  assert.equal(reissue.data.error, 'upgrade_required');
  // Не-enrolled отправитель свободен: входящие v1→v2 мостятся как раньше.
  const carolConn = await connect('dlg_carol', carol.token);
  assert.equal(carolConn.outcome, 'registered');
  assert.equal((await send(carolConn.socket, 'dlg_alice', 'мост')).ok, true);

  // Fail-closed: аккаунт не listed в accounts, но диалог v2_active → v1-send запрещён.
  await writeGuard(guardPayload({}, { [dialogKey('dlg_alice', 'dlg_bob')]: dialogRecord('v2_active', { flippedAt: Date.now() }) }));
  assert.equal((await connect('dlg_alice', alice.token)).outcome, 'upgrade_required');
  assert.equal((await send(bobConn.socket, 'dlg_alice', 'fail-closed')).error, 'upgrade_required');

  // Смешанный аккаунт (v2_active + rollback-диалог) остаётся под guard:
  // гранулярность v1 — аккаунт (документированное ограничение).
  await writeGuard(guardPayload({ dlg_alice: 'f'.repeat(64) }, {
    [dialogKey('dlg_alice', 'dlg_bob')]: dialogRecord('v2_active', { flippedAt: Date.now() }),
    [dialogKey('dlg_alice', 'dlg_carol')]: dialogRecord('v1_active', { rolledBackAt: Date.now() }),
  }));
  assert.equal((await connect('dlg_alice', alice.token)).outcome, 'upgrade_required');

  // Полный rollback ВСЕХ диалогов снимает guard даже если accounts устарел.
  const rolledAt = Date.now();
  await writeGuard(guardPayload({ dlg_alice: 'f'.repeat(64), dlg_bob: 'f'.repeat(64) }, {
    [dialogKey('dlg_alice', 'dlg_bob')]: dialogRecord('v1_active', { rolledBackAt: rolledAt }),
    [dialogKey('dlg_alice', 'dlg_carol')]: dialogRecord('v1_active', { rolledBackAt: rolledAt }),
  }));
  const aliceBack = await connect('dlg_alice', alice.token);
  assert.equal(aliceBack.outcome, 'registered');
  assert.equal((await send(aliceBack.socket, 'dlg_bob', 'после отката')).ok, true);
  assert.equal((await send(bobConn.socket, 'dlg_alice', 'ответ после отката')).ok, true);

  // Abort (v1_active без rolledBackAt) НЕ снимает guard: аккаунт enrolled.
  await writeGuard(guardPayload({ dlg_alice: 'f'.repeat(64) },
    { [dialogKey('dlg_alice', 'dlg_bob')]: dialogRecord('v1_active') }));
  assert.equal((await connect('dlg_alice', alice.token)).outcome, 'upgrade_required');

  // Регрессия: секция dialogs отсутствует → прежнее аккаунтное поведение.
  await writeGuard(guardPayload({ dlg_alice: 'f'.repeat(64) }));
  assert.equal((await connect('dlg_alice', alice.token)).outcome, 'upgrade_required');
  assert.equal((await send(bobConn.socket, 'dlg_alice', 'без секции dialogs')).ok, true);

  // Удаление файла обратимо снимает guard (существующий механизм).
  await fs.rm(guardFile);
  await sleep(1300);
  const aliceFree = await connect('dlg_alice', alice.token);
  assert.equal(aliceFree.outcome, 'registered');
  assert.equal((await send(aliceFree.socket, 'dlg_bob', 'guard удалён')).ok, true);
  // Reverse-replay не настроен: никаких consumed-журналов и ошибок ingestion.
  assert.equal(await exists(path.join(dir, 'v2-migration-guard.json.consumed')), false);
  assert.ok(!logsRef.text.includes('[v2-replay]'), logsRef.text);
});

test('v1 reverseReplay ingestion: без дублей, consumed, очереди целы, невалидный файл — честный лог', { timeout: 240000 }, async t => {
  const dir = await tempDir('coh-v1-replay-');
  const replayFile = path.join(dir, 'v2-reverse-replay.json');
  const consumedFile = `${replayFile}.consumed`;
  const secret = randomBytes(32).toString('hex');
  const existingId = randomBytes(16).toString('hex');
  const { keys } = await buildV1Fixture(dir, { secret,
    users: [{ account: 'rpl_alice' }, { account: 'rpl_bob' }],
    messages: [{ to: 'rpl_bob', from: 'rpl_alice', id: existingId, text: 'до миграции' }] });
  const logsRef = { text: '' };
  let { child, base } = await startV1({ dir, secret, env: { SHADE_V2_REVERSE_REPLAY_FILE: replayFile }, logsRef });
  const sockets = [];
  t.after(async () => { sockets.forEach(s => s.disconnect()); await stopV1(child); });
  const request = async (route, body) => {
    const response = await fetch(base + route, { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return { status: response.status, data: await response.json() };
  };
  async function register(account) {
    const pair = keys.get(account);
    const challenge = (await request('/auth/challenge', { username: account })).data.challenge;
    const result = await request('/register', { username: account, publicKey: pair.publicKey,
      signature: signWith(pair.publicKey, pair.privateKey), challenge,
      proof: signWith(`shade-register:v1:${account}:${challenge}`, pair.privateKey) });
    assert.equal(result.status, 200, JSON.stringify(result.data));
    return result.data;
  }
  const alice = await register('rpl_alice');
  const bob = await register('rpl_bob');
  // Переподключение по-честному: прежний сокет закрывается, grace-токен
  // отслеживается (sessionRefreshed), throttling IP выдерживается паузой.
  const liveSockets = new Map();
  const currentTokens = new Map();
  const connect = async (account, token) => {
    const previous = liveSockets.get(account);
    if (previous?.connected) { previous.disconnect(); await sleep(600); }
    for (let attempt = 0; attempt < 6; attempt++) {
      const socket = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false });
      sockets.push(socket);
      const incoming = [];
      const statuses = [];
      socket.on('message', m => incoming.push(m));
      socket.on('messageStatus', s => statuses.push(s));
      await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('connect_error', reject); socket.connect(); });
      socket.on('sessionRefreshed', e => { currentTokens.set(account, e.token); });
      socket.emit('register', { username: account, token: currentTokens.get(account) || token });
      const outcome = await new Promise(resolve => {
        const timer = setTimeout(() => resolve('timeout'), 15000);
        socket.once('registered', () => { clearTimeout(timer); resolve('registered'); });
        socket.once('authError', e => { clearTimeout(timer); resolve(e.error); });
        socket.once('error', e => { clearTimeout(timer); resolve(`error:${e?.message || ''}`); });
        socket.once('disconnect', () => { clearTimeout(timer); resolve('disconnect'); });
      });
      if (outcome === 'registered') {
        liveSockets.set(account, socket);
        await sleep(400); // досылка очереди после registered
        return { socket, incoming, statuses };
      }
      socket.disconnect();
      await sleep(700);
    }
    throw new Error(`connect failed: ${account}`);
  };
  const entry = (from, to, text) => ({ id: randomBytes(16).toString('hex'), from,
    timestamp: Date.now(), data: v1Seal(text, keys.get(to).publicKey) });
  const writeExport = accounts => fs.writeFile(replayFile, JSON.stringify({ version: 1, updatedAt: Date.now(), accounts }));
  const waitConsumed = () => waitFor(async () => !(await exists(replayFile)) && (await exists(consumedFile)), 8000, 'replay consumed');

  // Файла нет: no-op, существующая очередь доставляется как обычно.
  await sleep(2500);
  assert.equal(await exists(consumedFile), false);
  assert.ok(!logsRef.text.includes('[v2-replay]'), logsRef.text);
  const bobConn = await connect('rpl_bob', bob.token);
  assert.deepEqual(bobConn.incoming.map(m => m.id), [existingId]);

  // Ingestion: пакеты ДОБАВЛЯЮТСЯ к существующей очереди (онлайн-доставка),
  // файл помечается consumed атомарным журналом.
  const e1 = entry('rpl_alice', 'rpl_bob', 'v2 период 1');
  const e2 = entry('rpl_alice', 'rpl_bob', 'v2 период 2');
  const e3 = entry('rpl_bob', 'rpl_alice', 'v2 период ответ');
  await writeExport({ rpl_bob: [e1, e2], rpl_alice: [e3] });
  await waitConsumed();
  await sleep(400);
  assert.deepEqual(bobConn.incoming.map(m => m.id).sort(), [existingId, e1.id, e2.id].sort());
  // Ciphertext проходит как есть: нативный v1-алгоритм расшифровывает пакет.
  const delivered1 = bobConn.incoming.find(m => m.id === e1.id);
  assert.equal(delivered1.data, e1.data);
  assert.equal(openV1Payload(delivered1.data, keys.get('rpl_bob').privateKey), 'v2 период 1');
  const ledger = JSON.parse(await fs.readFile(consumedFile, 'utf8'));
  assert.equal(ledger.version, 1);
  assert.equal(ledger.accounts.rpl_bob.length, 2);
  assert.equal(ledger.accounts.rpl_alice.length, 1);
  // Офлайн-получатель добирает пакет из очереди после подключения.
  const aliceConn = await connect('rpl_alice', alice.token);
  assert.deepEqual(aliceConn.incoming.map(m => m.id), [e3.id]);
  // Честный статус отправителя: квитанция 'sent' восстановлена из ingestion
  // (alice — отправитель e1/e2, статусы приходят ей при подключении).
  assert.ok(aliceConn.statuses.some(s => s.msgId === e1.id && s.status === 'sent'));

  // Повторный экспорт v2 (рестарт/повторный rollback): дедуп по id+from,
  // существующие очереди не удаляются и не дублируются.
  await writeExport({ rpl_bob: [e1, e2], rpl_alice: [e3] });
  await waitConsumed();
  await sleep(2600);
  assert.equal(bobConn.incoming.length, 3);
  assert.equal(aliceConn.incoming.length, 1);

  // Доставленные и подтверждённые пакеты не воскрешают повторные экспорты.
  const ack = (socket, from, msgIds) => new Promise((resolve, reject) =>
    socket.timeout(20000).emit('delivered', { from, msgIds }, (err, reply) => err ? reject(err) : resolve(reply)));
  await ack(bobConn.socket, 'rpl_alice', [existingId, e1.id, e2.id]);
  await ack(aliceConn.socket, 'rpl_bob', [e3.id]);
  await writeExport({ rpl_bob: [e1, e2], rpl_alice: [e3] });
  await waitConsumed();
  await sleep(2600);
  assert.equal(bobConn.incoming.length, 3);
  assert.equal(aliceConn.incoming.length, 1);

  // Рестарт v1: дедуп персистентен (журнал consumed + квитанции), очереди целы.
  // Сессии v1 живут в памяти — после рестарта токен перевыпускается register.
  bobConn.socket.disconnect();
  aliceConn.socket.disconnect();
  await stopV1(child);
  ({ child, base } = await startV1({ dir, secret, env: { SHADE_V2_REVERSE_REPLAY_FILE: replayFile }, logsRef }));
  const bobToken2 = (await register('rpl_bob')).token;
  await writeExport({ rpl_bob: [e1, e2], rpl_alice: [e3] });
  await waitConsumed();
  const bobRestart = await connect('rpl_bob', bobToken2);
  assert.deepEqual(bobRestart.incoming, []);

  // Невалидный JSON: честный лог, сервис жив, файл НЕ consumed.
  await fs.writeFile(replayFile, '{сломанный json');
  await sleep(2600);
  assert.equal(await exists(replayFile), true);
  assert.ok(logsRef.text.includes('[v2-replay] export invalid'), logsRef.text);
  const bobAlive = await connect('rpl_bob', bobToken2);
  assert.deepEqual(bobAlive.incoming, []);
  bobAlive.socket.disconnect();

  // Невалидная структура (version): fail-closed, ingestion нет.
  await fs.writeFile(replayFile, JSON.stringify({ version: 2, accounts: {} }));
  await sleep(2600);
  assert.equal(await exists(replayFile), true);

  // Восстановление: валидный экспорт с новым пакетом + неизвестный аккаунт
  // пропускается честно, известный — доставляется.
  const e4 = entry('rpl_alice', 'rpl_bob', 'после сбоя');
  const ghost = { id: randomBytes(16).toString('hex'), from: 'rpl_alice', timestamp: Date.now(),
    data: v1Seal('неизвестный', keys.get('rpl_bob').publicKey) };
  await writeExport({ ghost_user: [ghost], rpl_bob: [e4] });
  await waitConsumed();
  await sleep(400);
  assert.ok(logsRef.text.includes('unknown accounts skipped: ghost_user'), logsRef.text);
  const bobFinal = await connect('rpl_bob', bobToken2);
  assert.deepEqual(bobFinal.incoming.map(m => m.id), [e4.id]);
  assert.equal(openV1Payload(bobFinal.incoming[0].data, keys.get('rpl_bob').privateKey), 'после сбоя');
});
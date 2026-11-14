const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const net = require('node:net');
const { spawn, execFileSync } = require('node:child_process');
const { io } = require('../../server/node_modules/socket.io-client');

async function freePort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}
function once(socket, event) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { socket.off(event, listener); reject(Error(`Timed out: ${event}`)); }, 8000);
    function listener(value) { clearTimeout(timeout); resolve(value); }
    socket.once(event, listener);
  });
}
function encrypt(text, publicKey) {
  const key = crypto.randomBytes(32), nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const data = Buffer.concat([cipher.update(text), cipher.final(), cipher.getAuthTag()]);
  const envelope = Buffer.concat([Buffer.from([2]), key, nonce]).toString('base64');
  return JSON.stringify({ k: crypto.publicEncrypt({ key: publicKey, oaepHash: 'sha256' }, Buffer.from(envelope)).toString('base64'), d: data.toString('base64') });
}
function decrypt(payload, privateKey) {
  const { k, d } = JSON.parse(payload);
  const envelope = Buffer.from(crypto.privateDecrypt({ key: privateKey, oaepHash: 'sha256' }, Buffer.from(k, 'base64')).toString(), 'base64');
  const data = Buffer.from(d, 'base64');
  const cipher = crypto.createDecipheriv('aes-256-gcm', envelope.subarray(1, 33), envelope.subarray(33));
  cipher.setAuthTag(data.subarray(-16));
  return Buffer.concat([cipher.update(data.subarray(0, -16)), cipher.final()]).toString();
}

test('audit probes: reproduce authorization, persistence and refresh defects', { timeout: 60000 }, async t => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'shade-relay-test-'));
  const certs = path.join(temp, 'certs');
  execFileSync('python', [path.join(__dirname, '../../server/test/make-test-cert.py'), certs]);
  const tlsPort = await freePort(), redirectPort = await freePort();
  const base = `https://127.0.0.1:${tlsPort}`;
  const agent = new https.Agent({ ca: fs.readFileSync(path.join(certs, 'cert.pem')) });
  const sockets = [];
  let child, logs = '';
  const environment = { ...process.env, CERT_DIR: certs, DATA_DIR: path.join(temp, 'data'),
    HTTPS_PORT: String(tlsPort), HTTP_PORT: String(redirectPort), NODE_ENV: 'test',
    DASHBOARD_PASS: crypto.randomBytes(24).toString('hex'), SESSION_SECRET: crypto.randomBytes(32).toString('hex'),
    ALLOW_LEGACY_REGISTRATION: 'true', ENABLE_INSECURE_TEST_PORT: 'false' };
  async function start() {
    child = spawn(process.execPath, ['server.js'], { cwd: path.join(__dirname, '../../server'), env: environment, windowsHide: true });
    child.stdout.on('data', data => { logs += data; });
    child.stderr.on('data', data => { logs += data; });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(Error(`Server startup failed: ${logs}`)), 12000);
      const poll = setInterval(() => {
        if (logs.includes(`server on :${tlsPort}`)) { clearTimeout(timeout); clearInterval(poll); resolve(); }
      }, 50);
      child.once('exit', code => { clearInterval(poll); clearTimeout(timeout); reject(Error(`Server exit ${code}: ${logs}`)); });
    });
  }
  async function stop() {
    if (child.exitCode === null) { const exit = new Promise(resolve => child.once('exit', resolve)); child.kill(); await exit; }
  }
  t.after(async () => { t.diagnostic(logs); sockets.forEach(socket => socket.disconnect()); await stop(); agent.destroy(); });
  const request = (route, body, headers = {}) => new Promise((resolve, reject) => {
    const req = https.request(base + route, { agent, method: body ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json', ...headers } }, res => {
      let data = ''; res.on('data', value => data += value); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, data: JSON.parse(data) }));
    });
    req.setTimeout(1500, () => req.destroy(Error('PROBE_TIMEOUT'))); req.on('error', reject); if (body) req.write(JSON.stringify(body)); req.end();
  });
  function identity(username) {
    const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    return { username, ...keys };
  }
  async function register(user) {
    const challenge = (await request('/auth/challenge', { username: user.username })).data.challenge;
    const sign = value => crypto.sign('sha256', Buffer.from(Buffer.from(value).toString('base64')),
      { key: user.privateKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
    const body = { username: user.username, publicKey: user.publicKey, signature: sign(user.publicKey),
      challenge, proof: sign(`shade-register:v1:${user.username}:${challenge}`) };
    const result = await request('/register', body);
    assert.equal(result.status, 200, JSON.stringify(result.data));
    user.token = result.data.token;
    assert.equal((await request('/register', body)).status, 403, 'nonce replay must fail');
  }
  async function connect(user) {
    const socket = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false, ca: fs.readFileSync(path.join(certs, 'cert.pem')) });
    sockets.push(socket);
    const connected = once(socket, 'connect'); socket.connect(); await connected;
    const registered = once(socket, 'registered'); socket.emit('register', { username: user.username, token: user.token }); await registered;
    return socket;
  }
  const send = (socket, payload) => new Promise((resolve, reject) => socket.timeout(8000).emit('message', payload, (err, ack) => err ? reject(err) : resolve(ack)));
  await start();
  const alice = identity('alice'), bob = identity('bob'), carol = identity('carol');
  for (const user of [alice, bob, carol]) await register(user);
  let a = await connect(alice), b = await connect(bob), c = await connect(carol);
  const auth = user => ({ 'x-username': user.username, 'x-session-token': user.token });
  const result = {};
  // Queue and deliver once. After a restart no durable receipt remains.
  const id = crypto.randomUUID();
  const payload = { id, to: 'bob', data: encrypt('audit fixture', bob.publicKey) };
  const first = once(b, 'message'); await send(a, payload); await first;
  const status = once(a, 'messageStatus'); b.emit('delivered', { from: 'alice', msgIds: [id] }); await status;
  a.disconnect(); b.disconnect(); c.disconnect(); await stop(); logs = ''; await start();
  for (const user of [alice, bob, carol]) await register(user);
  a = await connect(alice); b = await connect(bob); c = await connect(carol);
  const replay = once(b, 'message');
  await send(a, payload);
  result.deliveredMessageReplayedAfterRestart = (await replay).id === id;
  // Receipts while the sender is offline are not replayed on reconnection.
  a.disconnect(); await new Promise(resolve => setTimeout(resolve, 600));
  b.emit('delivered', { from: 'alice', msgIds: [id] });
  b.emit('read', { from: 'alice', msgIds: [id] });
  await new Promise(resolve => setTimeout(resolve, 150));
  a = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false, ca: fs.readFileSync(path.join(certs, 'cert.pem')) });
  sockets.push(a);
  a.on('sessionRefreshed', data => { alice.token = data.token; });
  let receiptReplays = 0; a.on('messageStatus', () => receiptReplays++);
  const ac = once(a, 'connect'); a.connect(); await ac;
  const ar = once(a, 'registered'); a.emit('register', { username: 'alice', token: alice.token }); await ar;
  await new Promise(resolve => setTimeout(resolve, 200));
  result.offlineSenderReceiptNotReplayed = receiptReplays === 0;
  // Actual client sends only auth headers, no body identifying the user.
  const logout = await request('/logout', {}, auth(alice));
  result.normalLogoutStatus = logout.status;
  result.normalLogoutTokenStillValid = (await request('/user/bob', null, auth(alice))).status === 200;
  // An authenticated user can select a different account in the body.
  result.crossAccountLogoutStatus = (await request('/logout', { username: 'bob' }, auth(alice))).status;
  result.victimTokenInvalidated = (await request('/user/alice', null, auth(bob))).status === 403;
  // Groups have no sender-membership check.
  const group = await request('/group/create', { name: 'audit group', members: ['alice', 'bob'] }, auth(alice));
  const groupReceived = once(a, 'groupMessage');
  c.emit('groupMessage', { groupId: group.data.groupId, data: 'not-a-member' });
  result.nonMemberCanSendGroupMessage = (await groupReceived).from === 'carol';
  // Server-side admin logout must revoke the signed cookie too.
  const adminLogin = await request('/admin/login', {}, { authorization: 'Basic ' + Buffer.from('admin:' + environment.DASHBOARD_PASS).toString('base64') });
  const cookie = adminLogin.headers['set-cookie'][0].split(';')[0];
  await request('/admin/logout', {}, { cookie });
  result.adminCookieSurvivesLogout = (await request('/api/stats', null, { cookie })).status === 200;
  // Nested acquisition of a non-reentrant refresh mutex blocks even invalid tokens.
  try { await request('/refresh', { refreshToken: 'invalid-audit-token' }); result.refreshRequestHung = false; }
  catch (e) { result.refreshRequestHung = e.message === 'PROBE_TIMEOUT'; }
  fs.writeFileSync(path.join(__dirname, 'server-probe-results.json'), JSON.stringify(result, null, 2));
  console.log('AUDIT_OBSERVATIONS ' + JSON.stringify(result));
  for (const [name, actual] of Object.entries(result)) {
    if (name.endsWith('Status')) assert.equal(actual, 200, name);
    else assert.equal(actual, true, name);
  }
});

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const net = require('node:net');
const { spawn, execFileSync } = require('node:child_process');
const { io } = require('socket.io-client');

async function freePort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}
function once(socket, event) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { socket.off(event, listener); reject(Error(`Timed out: ${event}`)); }, 20000);
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

test('regressions: logout identity, admin revocation, refresh, durable receipts and disabled groups', { timeout: 60000 }, async t => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'shade-relay-test-'));
  const certs = path.join(temp, 'certs');
  execFileSync('python', [path.join(__dirname, 'make-test-cert.py'), certs]);
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
    child = spawn(process.execPath, ['server.js'], { cwd: path.join(__dirname, '..'), env: environment, windowsHide: true });
    child.stdout.on('data', data => { logs += data; });
    child.stderr.on('data', data => { logs += data; });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(Error(`Server startup failed: ${logs}`)), 45000);
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
  const request = (route, body, headers = {}, method = body ? 'POST' : 'GET') => new Promise((resolve, reject) => {
    const req = https.request(base + route, { agent, method, headers: { 'Content-Type': 'application/json', ...headers } }, res => {
      let data = ''; res.on('data', value => data += value); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, data: (() => { try { return JSON.parse(data); } catch { return {}; } })() }));
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
    user.refreshToken = result.data.refreshToken;
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
  assert.equal((await request('/refresh', null, {}, 'POST')).status, 400);
  assert.equal((await request('/auth/challenge', null, {}, 'POST')).status, 400);
  assert.equal((await request('/register', null, {}, 'POST')).status, 403);
  assert.equal((await request('/refresh', [])).status, 400);
  const alice = identity('alice'), bob = identity('bob'), carol = identity('carol');
  for (const user of [alice, bob, carol]) await register(user);
  const auth = user => ({ 'x-username': user.username, 'x-session-token': user.token });
  const fcmToken = 'test-fixture-fcm-token:123456789';
  assert.equal((await request('/fcm/register', { token: fcmToken, format: 'fcm-v1' }, auth(bob))).status, 200);
  assert.equal((await request('/fcm/register', { token: 'short', format: 'fcm-v1' }, auth(bob))).status, 400);
  assert.equal((await request('/fcm/unregister', { token: fcmToken })).status, 401);
  assert.equal((await request('/fcm/unregister', { token: fcmToken }, auth(bob))).status, 200);
  // Signed key binding is tied to the nickname, not just a reusable public key.
  const bundle = (await request('/user/bob', null, auth(alice))).data;
  assert.equal(bundle.serverSignatureVersion, 3);
  const master = (await request('/api/server/public-key')).data.publicKey;
  const verifyBundle = name => crypto.verify('sha256', Buffer.from(Buffer.from(`shade-user-key:v1:${name}:${bundle.publicKey}`).toString('base64')),
    { key: master, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }, Buffer.from(bundle.serverSignature, 'base64'));
  assert.equal(verifyBundle('bob'), true); assert.equal(verifyBundle('carol'), false);
  const invalid = await Promise.all([1, 2, 3].map(() => request('/refresh', { refreshToken: 'invalid-fixture' })));
  assert.ok(invalid.every(response => response.status === 403));
  const rotated = await request('/refresh', { refreshToken: alice.refreshToken });
  assert.equal(rotated.status, 200); alice.token = rotated.data.token;
  const replayRefresh = await request('/refresh', { refreshToken: alice.refreshToken });
  assert.equal(replayRefresh.status, 403);
  assert.equal((await request('/user/bob', null, auth(alice))).status, 403);
  await register(alice);
  let a = await connect(alice), b = await connect(bob), c = await connect(carol);
  // Avatar endpoints use the real TLS/session middleware and socket identity.
  assert.equal((await request('/user/alice/avatar')).status,401);
  b.emit('watchProfiles',['alice']);
  await new Promise(resolve=>setTimeout(resolve,100));
  const avatarEvent=once(b,'avatarUpdated');
  assert.equal((await request('/profile/avatar',{frame:'silver',revision:0},auth(alice),'PUT')).status,200);
  assert.equal((await avatarEvent).username,'alice');
  assert.equal((await request('/user/alice/avatar',null,auth(bob))).data.frame,'silver');
  const payload = { id: crypto.randomUUID(), to: 'bob', data: encrypt('durable receipt', bob.publicKey) };
  let duplicates = 0;
  const first = once(b, 'message'); assert.equal((await send(a, payload)).ok, true); await first;
  a.disconnect(); await new Promise(resolve => setTimeout(resolve, 600));
  // Read while the sender is offline, then restart the real server.
  const readAck = await new Promise(resolve => b.emit('read', { from: 'alice', msgIds: [payload.id] }, resolve));
  assert.equal(readAck.ok, true);
  b.disconnect(); c.disconnect(); await stop(); logs = ''; await start();
  for (const user of [alice, bob, carol]) await register(user);
  assert.equal((await request('/user/alice/avatar',null,auth(alice))).data.frame,'silver','avatar settings survive server restart');
  assert.equal(fs.readFileSync(path.join(temp,'data','stickers.json'),'utf8').includes('silver'),false,'profile settings stay encrypted at rest');
  a = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false, ca: fs.readFileSync(path.join(certs, 'cert.pem')) });
  sockets.push(a);
  const statusReplay = once(a, 'messageStatus'), connected = once(a, 'connect'); a.connect(); await connected;
  const registered = once(a, 'registered'); a.emit('register', { username: 'alice', token: alice.token }); await registered;
  assert.equal((await statusReplay).status, 'read');
  b = await connect(bob); c = await connect(carol);
  b.on('message', () => duplicates++);
  assert.equal((await send(a, payload)).status, 'read');
  assert.equal((await send(a, { ...payload, data: encrypt('different', bob.publicKey) })).ok, false);
  await new Promise(resolve => setTimeout(resolve, 150)); assert.equal(duplicates, 0);
  // Independent senders may use the same ID without corrupting the other receipt.
  const differentSender = { ...payload, data: encrypt('carol message', bob.publicKey) };
  const second = once(b, 'message'); assert.equal((await send(c, differentSender)).ok, true); assert.equal((await second).from, 'carol');
  assert.equal((await request('/group/create', { name: 'not-ready', members: ['alice', 'bob'] }, auth(alice))).status, 410);
  assert.equal((await request('/group/123', null, auth(alice))).status, 410);
  const groupAck = await new Promise(resolve => c.emit('groupMessage', { groupId: '123', data: 'not-a-member' }, resolve));
  assert.equal(groupAck.ok, false);
  // Auth identity cannot be replaced by a body field.
  assert.equal((await request('/logout', { username: 'bob' }, auth(alice))).status, 403);
  assert.equal((await request('/user/alice', null, auth(bob))).status, 200);
  assert.equal((await request('/user/bob', null, auth(alice))).status, 200);
  // Keep Bob's incoming queue while he signs out. A headers-only logout is real.
  const queued = { id: crypto.randomUUID(), to: 'bob', data: encrypt('survives sign-out', bob.publicKey) };
  const queuedArrival = once(b, 'message'); await send(a, queued); await queuedArrival;
  assert.equal((await request('/logout', {}, auth(bob))).status, 200);
  assert.equal((await request('/user/alice', null, auth(bob))).status, 403);
  await new Promise(resolve => setTimeout(resolve, 600));
  const stale = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false, ca: fs.readFileSync(path.join(certs, 'cert.pem')) }); sockets.push(stale);
  const staleConnect = once(stale, 'connect'); stale.connect(); await staleConnect;
  const denied = once(stale, 'authError'); stale.emit('register', { username: 'bob', token: bob.token }); await denied; stale.disconnect();
  await new Promise(resolve => setTimeout(resolve, 600));
  await register(bob);
  b = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false, ca: fs.readFileSync(path.join(certs, 'cert.pem')) }); sockets.push(b);
  const restoredMessages = []; b.on('message', value => restoredMessages.push(value));
  const preserved = once(b, 'message'), bc = once(b, 'connect'); b.connect(); await bc;
  b.emit('register', { username: 'bob', token: bob.token }); await preserved;
  await new Promise(resolve => setTimeout(resolve, 150));
  assert.ok(restoredMessages.some(message => message.id === queued.id), 'logout preserves the pending queue');
  // Delete a delivered message while the receiver is offline; replay the tombstone after restart.
  b.disconnect(); await new Promise(resolve => setTimeout(resolve, 600));
  const deletion = await new Promise(resolve => a.emit('deleteMessage', { to: 'bob', msgId: payload.id, forEveryone: true }, resolve));
  assert.equal(deletion.ok, true);
  a.disconnect(); c.disconnect(); await stop(); logs = ''; await start();
  await register(bob);
  b = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false, ca: fs.readFileSync(path.join(certs, 'cert.pem')) }); sockets.push(b);
  const tombstone = once(b, 'messageDeleted'), reconnected = once(b, 'connect'); b.connect(); await reconnected;
  b.emit('register', { username: 'bob', token: bob.token });
  const deleted = await tombstone; assert.equal(deleted.from, 'alice'); assert.equal(deleted.msgId, payload.id);
  const login = await request('/admin/login', {}, { authorization: 'Basic ' + Buffer.from('admin:' + environment.DASHBOARD_PASS).toString('base64') });
  const cookie = login.headers['set-cookie'][0].split(';')[0];
  await request('/admin/logout', {}, { cookie });
  assert.equal((await request('/api/stats', null, { cookie })).status, 302);
  // Queue/receipt snapshot is encrypted at rest, not plaintext sender metadata.
  const snapshot = fs.readFileSync(path.join(temp, 'data', 'messaging.json'), 'utf8');
  assert.equal(snapshot.includes('alice'), false);
});

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

test('real TLS relay: three clients, receipt isolation, retry, offline restart and auth rejection', { timeout: 60000 }, async t => {
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
  const request = (route, body, headers = {}, method = body ? "POST" : "GET") => new Promise((resolve, reject) => {
    const req = https.request(base + route, { agent, method, headers: { 'Content-Type': 'application/json', ...headers } }, res => {
      let data = ''; res.on('data', value => data += value); res.on('end', () => resolve({ status: res.statusCode, data: JSON.parse(data) }));
    });
    req.on('error', reject); if (body) req.write(JSON.stringify(body)); req.end();
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
  const headers = u => ({'x-username':u.username,'x-session-token':u.token});
  const gift={toUsername:'bob',stickerId:'flowers',requestId:crypto.randomUUID(),note:'private-test-note'};
  assert.equal((await request('/profile/name',{displayName:'Луна'},headers(alice),'PUT')).status,200);
  assert.equal((await request('/user/alice/stickers',null,headers(bob))).data.displayName,'Луна');
  const sendGift=(body,h=headers(alice))=>request('/stickers/gift',body,h);
  assert.equal((await sendGift(gift,{})).status,401);
  for(const [change,status] of [[{toUsername:'missing'},404],[{fromUsername:'bob'},400],[{stickerId:'unknown'},400],[{note:'a'.repeat(241)},400]]){
    assert.equal((await sendGift({...gift,...change})).status,status);
  }
  const sent=await Promise.all([sendGift(gift),sendGift(gift)]);
  assert.equal(sent[0].status,200);assert.deepEqual(sent[0],sent[1]);
  const giftId=sent[0].data.giftId;
  const inventory=await request('/stickers/inventory',null,headers(bob));
  assert.equal(inventory.data.inventory.length,1);assert.equal(inventory.data.inventory[0].fromUsername,'alice');
  assert.deepEqual(inventory.data.wall,[]);
  const publicView=await request('/user/bob/stickers',null,headers(alice));
  assert.equal(publicView.data.inventory[0].note,undefined);
  const place={giftId,xNorm:.5,yNorm:.5,scale:1,rotation:0,zIndex:0};
  const put=(body,h=headers(bob))=>request('/stickers/wall',body,h,'PUT');
  assert.equal((await put({revision:0,wall:[place]},headers(carol))).status,400);
  assert.equal((await put({revision:0,username:'bob',wall:[]},headers(carol))).status,400);
  assert.equal((await put({revision:0,wall:[{...place,xNorm:-.1}]})).status,400);
  assert.equal((await put({revision:0,wall:[place,place]})).status,400);
  const competing=await Promise.all([put({revision:0,wall:[place]}),put({revision:0,wall:[place]})]);
  assert.deepEqual(competing.map(r=>r.status).sort(),[200,409]);
  // Make the temp destination unwritable in this isolated DATA_DIR.
  const blocked=path.join(temp,'data','stickers.json.tmp');fs.mkdirSync(blocked);
  assert.equal((await put({revision:1,wall:[]})).status,503);
  fs.rmdirSync(blocked);
  assert.equal((await request('/stickers/inventory',null,headers(bob))).data.revision,1);
  assert.equal(fs.readFileSync(path.join(temp,'data','stickers.json'),'utf8').includes(gift.note),false);
  const a = await connect(alice), b = await connect(bob), c = await connect(carol);
  const id = crypto.randomUUID();
  const payload = { id, to: 'bob', data: encrypt('Привет, Bob! 🔐', bob.publicKey) };
  const received = once(b, 'message');
  assert.equal((await send(a, payload)).ok, true);
  const message = await received;
  assert.equal(decrypt(message.data, bob.privateKey), 'Привет, Bob! 🔐');
  assert.equal(message.id, id);
  let duplicates = 0, unrelatedReceipts = 0;
  b.on('message', () => duplicates++); c.on('messageStatus', () => unrelatedReceipts++);
  assert.equal((await send(a, payload)).ok, true);
  assert.equal((await send(a, { ...payload, data: encrypt('changed', bob.publicKey) })).ok, false);
  c.emit('read', { from: 'alice', msgIds: [id] });
  const delivered = once(a, 'messageStatus'); b.emit('delivered', { from: 'alice', msgIds: [id] });
  assert.equal((await delivered).status, 'delivered');
  const read = once(a, 'messageStatus'); b.emit('read', { from: 'alice', msgIds: [id] });
  assert.equal((await read).status, 'read');
  assert.equal(duplicates, 0); assert.equal(unrelatedReceipts, 0);
  assert.equal((await send(a, { id: crypto.randomUUID(), to: 'missing', data: payload.data })).ok, false);
  // Queue a photo while Bob is offline, then restart the actual server.
  b.disconnect(); await new Promise(resolve => setTimeout(resolve, 600));
  const photoText = 'IMG:' + Buffer.from('image-fixture').toString('base64');
  const offline = { id: crypto.randomUUID(), to: 'bob', data: encrypt(photoText, bob.publicKey) };
  assert.equal((await send(a, offline)).ok, true);
  a.disconnect(); c.disconnect(); await stop(); logs = ''; await start();
  await register(alice); await register(bob);
  const restored=(await request('/stickers/inventory',null,headers(bob))).data;
  assert.equal(restored.inventory[0].note,gift.note);assert.equal(restored.wall[0].giftId,giftId);
  const a2 = await connect(alice);
  const b2 = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false, ca: fs.readFileSync(path.join(certs, 'cert.pem')) }); sockets.push(b2);
  const queued = once(b2, 'message'), connected = once(b2, 'connect'); b2.connect(); await connected;
  b2.emit('register', { username: 'bob', token: bob.token });
  assert.equal(decrypt((await queued).data, bob.privateKey), photoText);
  const confirmed = once(a2, 'messageStatus'); b2.emit('delivered', { from: 'alice', msgIds: [offline.id] }); await confirmed;
  assert.ok(fs.existsSync(path.join(temp, 'data', 'messaging.json')));
  assert.equal((await send(a2, offline)).status, 'delivered');
  assert.equal((await request('/user/bob')).status, 401);
});

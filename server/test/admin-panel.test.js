const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const net = require('node:net');
const { spawn, execFileSync } = require('node:child_process');

async function freePort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

test('admin panel: login brute-force stays locked while authenticated polling is not throttled', { timeout: 60000 }, async t => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'shade-admin-panel-test-'));
  const certs = path.join(temp, 'certs');
  execFileSync('python', [path.join(__dirname, 'make-test-cert.py'), certs]);
  const tlsPort = await freePort(), redirectPort = await freePort();
  const base = `https://127.0.0.1:${tlsPort}`;
  const agent = new https.Agent({ ca: fs.readFileSync(path.join(certs, 'cert.pem')), keepAlive: true });
  const environment = { ...process.env, CERT_DIR: certs, DATA_DIR: path.join(temp, 'data'),
    HTTPS_PORT: String(tlsPort), HTTP_PORT: String(redirectPort), NODE_ENV: 'test',
    DASHBOARD_PASS: crypto.randomBytes(24).toString('hex'), SESSION_SECRET: crypto.randomBytes(32).toString('hex'),
    ALLOW_LEGACY_REGISTRATION: 'true', ENABLE_INSECURE_TEST_PORT: 'false' };
  const child = spawn(process.execPath, ['server.js'], { cwd: path.join(__dirname, '..'), env: environment, windowsHide: true });
  let logs = '';
  child.stdout.on('data', data => { logs += data; });
  child.stderr.on('data', data => { logs += data; });
  t.after(async () => {
    t.diagnostic(logs);
    if (child.exitCode === null) { const exit = new Promise(resolve => child.once('exit', resolve)); child.kill(); await exit; }
    agent.destroy();
    fs.rmSync(temp, { recursive: true, force: true });
  });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(Error(`Server startup failed: ${logs}`)), 12000);
    const poll = setInterval(() => {
      if (logs.includes(`server on :${tlsPort}`)) { clearTimeout(timeout); clearInterval(poll); resolve(); }
    }, 50);
    child.once('exit', code => { clearInterval(poll); clearTimeout(timeout); reject(Error(`Server exit ${code}: ${logs}`)); });
  });

  const request = (route, { method = 'GET', body, headers = {} } = {}) => new Promise((resolve, reject) => {
    const req = https.request(base + route, { agent, method, headers: { 'Content-Type': 'application/json', ...headers } }, res => {
      let data = ''; res.on('data', value => data += value);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, data }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(JSON.stringify(body));
    req.end();
  });
  const basic = { Authorization: 'Basic ' + Buffer.from('admin:' + environment.DASHBOARD_PASS).toString('base64') };

  // Anti-brute-force on POST /admin/login is preserved: 5 attempts per window,
  // so the 6th..11th login POSTs must all be rejected with 429.
  let sessionCookie = null;
  const loginStatuses = [];
  for (let i = 0; i < 11; i++) {
    const reply = await request('/admin/login', { method: 'POST', body: {}, headers: basic });
    loginStatuses.push(reply.status);
    if (reply.status === 200 && !sessionCookie) {
      sessionCookie = (reply.headers['set-cookie'] || []).find(c => c.startsWith('shade_admin_sess='))?.split(';')[0];
    }
  }
  assert.deepEqual(loginStatuses.slice(0, 5), [200, 200, 200, 200, 200], 'first 5 logins succeed');
  assert.ok(loginStatuses.slice(5).every(status => status === 429), '6th..11th logins are 429');
  assert.equal(loginStatuses[10], 429, '11th login within the window must be rejected');
  assert.ok(sessionCookie, 'a successful login issued a session cookie');
  const cookie = { Cookie: sessionCookie };

  // The panel polls stats every 5s (≈180 req/15min): 240 consecutive
  // authenticated GETs must all pass, and only the 241st hits the soft cap.
  for (let i = 0; i < 240; i++) {
    const reply = await request('/api/dashboard-stats', { headers: cookie });
    assert.equal(reply.status, 200, `stats poll #${i + 1} must not be throttled`);
  }
  assert.equal((await request('/api/dashboard-stats', { headers: cookie })).status, 429, 'soft per-route cap still applies');

  // /dashboard and /logs have independent budgets and stay reachable.
  assert.equal((await request('/dashboard', { headers: cookie })).status, 200);
  assert.equal((await request('/logs', { headers: cookie })).status, 200);
  const logsBody = JSON.parse((await request('/logs', { headers: cookie })).data);
  assert.ok(Array.isArray(logsBody), 'logs endpoint still returns the log array');

  // Unauthenticated access is still rejected (checked last: a failed auth
  // arms the requireAuth backoff for a couple of seconds).
  assert.equal((await request('/api/dashboard-stats')).status, 302);
});
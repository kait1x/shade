// Run: node tools/web_beta_qa.mjs <absolute path to playwright package>
// Uses localhost only; never contacts the VPS or any real Google account.
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import fs from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
const client = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.join(client, 'build', 'web');
const { webkit, chromium } = await import(pathToFileURL(path.join(process.argv[2], 'index.mjs')));
const engine = process.argv[3] || 'webkit-persistent';
assert.ok(['webkit', 'webkit-persistent', 'edge'].includes(engine));
const mime = { '.mjs': 'application/javascript', '.js': 'application/javascript', '.json': 'application/json',
  '.html': 'text/html; charset=utf-8', '.wasm': 'application/wasm', '.png': 'image/png' };
const server = http.createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const target = path.resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
    assert.ok(target.startsWith(root + path.sep));
    res.setHeader('Content-Type', mime[path.extname(target)] || 'application/octet-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.end(await fs.readFile(target));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const options = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 1 };
let browser, context;
if (engine === 'webkit-persistent') {
  const profile = await fs.mkdtemp(path.join(client, 'build', 'webkit-qa-profile-'));
  context = await webkit.launchPersistentContext(profile, { ...options, headless: true });
} else {
  browser = await (engine === 'webkit' ? webkit.launch({ headless: true }) : chromium.launch({ channel: 'msedge', headless: true }));
  context = await browser.newContext(options);
}
const page = await context.newPage();
const errors = [], unexpected = [], externalResponses = [], externalFailures = [];
page.on('pageerror', e => errors.push(e.message));
page.on('request', req => { if (!req.url().startsWith(origin) && !req.url().startsWith('data:') && !req.url().startsWith('blob:')) unexpected.push(req.url()); });
page.on('response', res => { if (!res.url().startsWith(origin) && res.url().startsWith('https:')) externalResponses.push(res.url()); });
page.on('requestfailed', req => { if (req.url().startsWith('https:')) externalFailures.push({ url: req.url(), reason: req.failure()?.errorText }); });
const results = {};
try {
  await page.goto(origin);
  await page.waitForSelector('#loading', { state: 'detached', timeout: 60000 });
  await page.waitForLoadState('networkidle');
  results.releaseFirstFrame = true;
  const storage = await page.evaluate(async () => {
    const c = await import('./device_crypto.mjs');
    const passphrase = 'synthetic WebKit persistence test phrase';
    const vault = await c.createVault('webkit_test', passphrase);
    await c.saveVault(vault);
    let refusedOverwrite = false;
    try { await c.saveVault(vault); } catch { refusedOverwrite = true; }
    const session = await c.unlockVault(await c.loadVault(vault.id), passphrase);
    const encrypted = await c.encryptRecord(session, 'checkpoint', { revision: 3 });
    const record = await c.decryptRecord(session, 'checkpoint', encrypted);
    const payload = await c.encryptLegacy('WebKit ciphertext 🔐', vault.encryptionKey);
    const plaintext = await c.decryptLegacy(payload, session.encryption);
    return { id: vault.id, encryptionKey: vault.encryptionKey, signingKey: vault.signingKey,
      nonExtractable: !session.encryption.extractable && !session.signing.extractable,
      refusedOverwrite, record, plaintext, persistedFields: Object.keys(await c.loadVault(vault.id)).sort() };
  });
  assert.equal(storage.nonExtractable, true); assert.equal(storage.refusedOverwrite, true);
  assert.equal(storage.plaintext, 'WebKit ciphertext 🔐'); assert.deepEqual(storage.record, { revision: 3 });
  assert.deepEqual(storage.persistedFields, ['account', 'ciphertext', 'encryptionKey', 'id', 'iv', 'salt', 'signingKey', 'version']);
  results.encryptedIndexedDB = true;
  await page.reload();
  await page.waitForSelector('#loading', { state: 'detached', timeout: 60000 });
  await page.waitForLoadState('networkidle');
  const restored = await page.evaluate(async ({ id }) => {
    const c = await import('./device_crypto.mjs');
    const vault = await c.loadVault(id);
    const session = await c.unlockVault(vault, 'synthetic WebKit persistence test phrase');
    let badPasswordRejected = false;
    try { await c.unlockVault(vault, 'incorrect password'); } catch { badPasswordRejected = true; }
    return { id: session.id, encryptionKey: vault.encryptionKey, signingKey: vault.signingKey, badPasswordRejected };
  }, { id: storage.id });
  assert.equal(restored.id, storage.id); assert.equal(restored.encryptionKey, storage.encryptionKey);
  assert.equal(restored.signingKey, storage.signingKey); assert.equal(restored.badPasswordRejected, true);
  results.sameIdentityAfterReload = true;
  results.onlinePageErrors = errors.length;
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }));
  });
  results.cache = await page.evaluate(async () => {
    const names = await caches.keys();
    const name = names.find(n => n.startsWith('shade-web-beta-'));
    const cache = name ? await caches.open(name) : null;
    return { names, entries: cache ? (await cache.keys()).length : 0,
      index: cache ? (await cache.match(new URL('./index.html', location.href).href))?.status : null,
      controller: navigator.serviceWorker.controller?.scriptURL };
  });
  await context.setOffline(true);
  try {
    await page.reload({ waitUntil: 'load' });
    await page.waitForSelector('#loading', { state: 'detached', timeout: 60000 });
  await page.waitForLoadState('networkidle');
    results.offlineShellReload = true;
  } catch (error) {
    results.offlineShellReload = false;
    results.offlineError = error.message.split('\n')[0];
  }
  await context.setOffline(false);
  if (!results.offlineShellReload) {
    await page.goto(origin);
    await page.waitForSelector('#loading', { state: 'detached', timeout: 60000 });
  await page.waitForLoadState('networkidle');
  }
  const out = path.resolve(client, '..', 'artifacts', 'multidevice-qa');
  await fs.mkdir(out, { recursive: true });
  await page.screenshot({ path: path.join(out, `web-beta-${engine}.png`), fullPage: true });
  results.externalResponses = externalResponses;
  results.blockedSdkRequests = externalFailures;
  results.pageErrors = errors;
  results.engine = `${engine}, 390x844 touch emulation; not a physical iPhone`;
  await fs.writeFile(path.join(out, `${engine}-results.json`), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results));
  assert.equal(results.onlinePageErrors, 0);
  assert.deepEqual(externalResponses, []);
  assert.ok(unexpected.every(url => url === 'https://accounts.google.com/gsi/client'));
  assert.equal(externalFailures.length, unexpected.length);
  assert.ok(externalFailures.every(f => f.reason === 'csp' || f.reason?.includes('BLOCKED_BY_CSP')));
  assert.equal(results.offlineShellReload, true, `${engine}: offline reload failed; see saved results`);
  assert.deepEqual(errors, []);
} finally {
  await context.close();
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}

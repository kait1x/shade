// Изолированная диагностика webkit recovery: реальный alpha-fixture + webkit,
// захват console/pageerror и состояния клиента на каждом шаге.
import path from 'node:path';
import fs from 'node:fs/promises';
import { randomBytes, createHash, X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { fixture } from '../test/helpers/alpha-fixture.mjs';
import { createVault, unlockVault, descriptor, createRecoveryBackup,
  finalizeRecoveryBackup, createGenesis, approveDevices, pairingProof } from '../../client/web/device_crypto.mjs';

const pwCore = process.argv[2];
const { webkit } = await import(pathToFileURL(path.join(pwCore, 'index.mjs')));
const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const run = await fs.mkdtemp(path.join(serverRoot, 'build', 'webkit-diag-'));
execFileSync('python', [path.join(serverRoot, 'test/make-test-cert.py'), path.join(run, 'certs')]);
const tls = { key: await fs.readFile(path.join(run, 'certs/key.pem')), cert: await fs.readFile(path.join(run, 'certs/cert.pem')) };
const webPush = createRequire(import.meta.url)('web-push');
const f = await fixture({ dataDir: path.join(run, 'data'), storageSecret: randomBytes(32).toString('hex'), tls,
  vapidKeys: webPush.generateVAPIDKeys(), pushSender: async () => {} });
const phrase = 'synthetic recovery device passphrase 2026';
const recoveryPhrase = 'independent synthetic offline recovery passphrase only';
const vault = await createVault('browser_rec', phrase);
const session = await unlockVault(vault, phrase);
let backup = await createRecoveryBackup('browser_rec', vault.signingKey, recoveryPhrase);
const genesis = await createGenesis(vault, session, backup.publicKey);
backup = await finalizeRecoveryBackup(backup, recoveryPhrase, genesis);
const manifest = await approveDevices(genesis, [], [descriptor(vault)], session);
const cookie = await f.login('synthetic-browser-recovery');
const reg = await f.request('/api/v2/register', { genesis, manifest, proofs: [await pairingProof(vault, session)] }, cookie);
console.log('REGISTER', reg.response.status);
const pkgBuffer = Buffer.from(JSON.stringify({ backup, genesis }));

const context = await webkit.launchPersistentContext(path.join(run, 'ctx'), {
  headless: true, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true,
  ignoreHTTPSErrors: true,
});
const page = context.pages()[0] || await context.newPage();
const logs = [];
page.on('console', m => logs.push(`[console.${m.type()}] ${m.text()}`));
page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));
const [cname, cvalue] = cookie.split('=');
await context.addCookies([{ name: cname, value: cvalue, url: f.origin }]);
const step = async (name, fn) => {
  try { await fn(); console.log('STEP OK', name); }
  catch (e) { console.log('STEP FAIL', name, e.message.split('\n')[0]); throw e; }
};
try {
  await step('goto', () => page.goto(f.origin));
  // Проверки владельца: шим отдаётся сервером (200) и попадает в offline-прекэш SW.
  const shimStatus = await page.evaluate(() => fetch('/viewport-shim.js').then(r => r.status));
  console.log('SHIM HTTP', shimStatus);
  console.log('SHIM BRANCH', await page.evaluate(() => window.__shadeShim || 'missing'));
  await page.waitForTimeout(3000);
  const precache = await page.evaluate(async () => {
    const keys = await caches.keys();
    for (const k of keys) {
      const c = await caches.open(k);
      if (await c.match('/viewport-shim.js')) return k;
    }
    return null;
  });
  console.log('SHIM PRECACHE', precache);
  await step('link-step', () => page.getByRole('button', { name: 'Восстановить с recovery-пакетом' }).click());
  await step('form', () => page.getByText('Восстановление аккаунта', { exact: true }).waitFor({ timeout: 30000 }));
  // Flutter entrance animation: webkit stability wait требует оседания макета.
  await page.waitForTimeout(2500);
  const chooserP = page.waitForEvent('filechooser', { timeout: 30000 });
  chooserP.catch(() => {});
  await step('pick-click', () => page.getByRole('button', { name: 'Выбрать файл пакета (JSON)' }).click());
  await step('chooser-setfiles', async () => {
    const chooser = await chooserP;
    await chooser.setFiles({ name: 'shade-recovery-browser_rec.json', mimeType: 'application/json', buffer: pkgBuffer });
  });
  await step('pkg-name', () => page.getByText('shade-recovery-browser_rec.json', { exact: false }).waitFor({ timeout: 30000 }));
  await page.waitForTimeout(1500);
  await step('fill-recovery', async () => {
    await page.getByLabel('Recovery-фраза', { exact: true }).click();
    await page.waitForTimeout(600);
    await page.keyboard.type(recoveryPhrase);
  });
  await step('fill-phrase', async () => {
    await page.getByLabel('Фраза устройства ·').click();
    await page.waitForTimeout(600);
    await page.keyboard.type(phrase);
  });
  await step('fill-confirm', async () => {
    await page.getByLabel('Повторите фразу устройства').click();
    await page.waitForTimeout(600);
    await page.keyboard.type(phrase);
  });
  await page.waitForTimeout(1000);
  await step('submit', () => page.getByRole('button', { name: 'Восстановить аккаунт' }).click());
  await step('success', () => page.getByText('Личность восстановлена', { exact: true }).waitFor({ timeout: 150000 }));
  console.log('RECOVERY SUCCESS');
} catch (e) {
  console.log('DIAG STOP:', e.message.split('\n')[0]);
}
const state = await page.evaluate(() => {
  const c = window.__shadeClient;
  return { hasClient: Boolean(c), hasState: Boolean(c?.state), registered: c?.state?.registered ?? null,
    lastError: c?.lastError || '', lastSocketError: c?.lastSocketError || '',
    notice: document.querySelector('#notice')?.textContent || '',
    bodyText: document.body.innerText.slice(0, 600) };
}).catch(e => ({ evalError: e.message }));
console.log('STATE', JSON.stringify(state, null, 1));
console.log('LOGS\n' + logs.slice(-40).join('\n'));
await page.screenshot({ path: path.join(run, 'diag.png') }).catch(() => {});
console.log('SCREENSHOT', path.join(run, 'diag.png'));
await context.close();
await f.close();
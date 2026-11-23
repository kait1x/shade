// Onboarding screenshots for design review: welcome → nickname → identity →
// recovery → chat → unlock, at iPhone and desktop viewports. Works against the
// synthetic-OAuth fixture; tolerant of the pre-redesign auth screens so the
// same tool produces the BEFORE/AFTER evidence pair from the two branches.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { randomBytes, createHash, X509Certificate } from 'node:crypto';
import { createRequire } from 'node:module';
import { fixture } from '../test/helpers/alpha-fixture.mjs';
const webPush = createRequire(import.meta.url)('web-push');

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const flutterBootstrap = path.join(serverRoot, '..', 'client', 'build', 'web-alpha', 'flutter_bootstrap.js');
try { await fs.access(flutterBootstrap); } catch {
  throw Error('Flutter web-alpha build missing: run "python client/tools/build_web_alpha.py" from the repo root first');
}
const run = path.join(serverRoot, 'build', `shots-run-${randomBytes(6).toString('hex')}`);
await fs.mkdir(run, { recursive: true });
execFileSync('python', [path.join(serverRoot, 'test/make-test-cert.py'), path.join(run,'certs')]);
const tls = { key: await fs.readFile(path.join(run,'certs/key.pem')), cert: await fs.readFile(path.join(run,'certs/cert.pem')) };
const testSPKI = createHash('sha256').update(new X509Certificate(tls.cert).publicKey.export({type:'spki',format:'der'})).digest('base64');
const f = await fixture({ dataDir: path.join(run,'data'), storageSecret: randomBytes(32).toString('hex'), tls,
  vapidKeys: webPush.generateVAPIDKeys(), pushSender: async () => {} });
const { webkit, chromium } = await import(pathToFileURL(path.join(process.argv[2], 'index.mjs')));
const engineName = process.argv[3] || 'webkit';
assert.ok(['webkit', 'edge'].includes(engineName));
const output = path.resolve(serverRoot, '..', 'artifacts', 'onboarding');
await fs.mkdir(output, { recursive: true });
const phrase = 'onboarding screenshot device phrase';
const shot = async (page, name) => {
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(output, `${engineName}-${name}.png`) });
  console.log('SHOT', `${engineName}-${name}.png`);
};
async function browser(name, width = 390, height = 844) {
  const context = await (engineName === 'webkit' ? webkit : chromium).launchPersistentContext(path.join(run,name), {
    headless: true, ...(engineName === 'edge' ? { channel:'msedge',args:[`--ignore-certificate-errors-spki-list=${testSPKI}`] } : {}),
    viewport:{ width, height }, isMobile:true, hasTouch:true, ignoreHTTPSErrors:true,
  });
  const page = await context.newPage(); page.setDefaultTimeout(20000);
  page.on('pageerror', e => console.log('PAGEERROR', e.message));
  return { context, page };
}
async function passGoogle(page) {
  // Old UI: text button; new UI: styled link with the accessible name. Boot
  // renders after /api/session, so WAIT for either target instead of counting.
  // locator.waitFor() resolves to void, hence the explicit markers.
  const link = page.getByRole('link',{name:'Продолжить с Google'});
  const legacy = page.getByText('Войти через Google',{exact:true});
  const which = await Promise.any([link.waitFor({timeout:20000}).then(() => 'new'),
    legacy.waitFor({timeout:20000}).then(() => 'old')]).catch(() => null);
  await (which === 'old' ? legacy : link).click();
}
async function register(page, account, sub) {
  f.setLoginSub(sub);
  await page.goto(f.origin); await shot(page, 'welcome');
  await passGoogle(page);
  await page.getByLabel('Ваш никнейм').fill(account);
  const recovery = page.getByLabel('Пароль восстановления ·');
  await recovery.waitFor({ timeout: 30000 });
  const local = page.getByLabel('Пароль этого браузера ·');
  if (!await local.isVisible()) {
    await shot(page, 'identity-prf');
    const usePin = page.getByRole('button', { name: 'Использовать PIN', exact: true });
    if (await usePin.isVisible()) await usePin.click();
    await page.getByRole('button', { name: 'Использовать пароль браузера' }).click();
  }
  await local.fill(phrase);
  await recovery.fill('synthetic onboarding recovery password');
  await shot(page, 'identity');
  await page.getByRole('button', { name: 'Создать аккаунт', exact: true }).click();
  await page.getByText('Подключено · E2EE',{exact:true}).waitFor({timeout:120000});
  await page.waitForTimeout(2500); // Flutter projection paints the chat list
  await shot(page, 'chat');
}
// Full flow at the iPhone 13/14 reference size.
const main = await browser('main');
await register(main.page, 'shot_alice', 'synthetic-shot-alice');
// Returning user: unlock card adapts to the vault binding method.
await main.page.reload();
await main.page.getByLabel('Пароль этого браузера',{exact:true}).waitFor({timeout:30000});
await shot(main.page, 'unlock');
// Nickname validation error state.
{
  const { context, page } = await browser('error-state');
  f.setLoginSub('synthetic-shot-bob');
  await page.goto(f.origin); await passGoogle(page);
  const { field, isNew } = await nicknameField(page);
  if (isNew) {
    await field.fill('Bad Nick!');
    await page.getByRole('button',{name:'Продолжить',exact:true}).click();
    await page.getByRole('alert').waitFor({timeout:5000}).catch(() => {});
    await shot(page, 'nickname-error');
  } else await shot(page, 'create-legacy');
  await context.close();
}
// Viewport sweep on the two most layout-sensitive states (fresh contexts).
for (const [width,height,label] of [[320,568,'320x568-se'],[375,812,'375x812'],[430,932,'430x932'],[768,1024,'768x1024']]) {
  const { context, page } = await browser(`vp-${width}`, width, height);
  f.setLoginSub(`synthetic-shot-vp-${width}`);
  await page.goto(f.origin);
  await shot(page, `welcome-${label}`);
  await passGoogle(page);
  await nicknameField(page);
  await shot(page, `nickname-${label}`);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
  if (overflow) console.log('OVERFLOW', label);
  await context.close();
}
await main.context.close();
// The fixture HTTPS server keeps the event loop alive; close it so the tool
// exits after printing DONE (otherwise the process hangs with all shots done).
await f.close();
console.log('DONE', output);

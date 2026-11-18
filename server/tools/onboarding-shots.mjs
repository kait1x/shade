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
// The nickname step renders after the full OAuth round-trip; wait for either
// the new ('Ваш никнейм') or the legacy ('Имя пользователя') label. Returns
// the located field plus whether the new two-step flow is active.
async function nicknameField(page) {
  const fresh = page.getByLabel('Ваш никнейм');
  const legacy = page.getByLabel('Имя пользователя');
  const which = await Promise.any([fresh.waitFor({timeout:30000}).then(() => 'new'),
    legacy.waitFor({timeout:30000}).then(() => 'old')]).catch(() => null);
  return { field: which === 'old' ? legacy : fresh, isNew: which === 'new' };
}
async function register(page, account, sub) {
  f.setLoginSub(sub);
  await page.goto(f.origin); await shot(page, 'welcome');
  await passGoogle(page);
  const { field: nickname, isNew } = await nicknameField(page);
  await shot(page, 'nickname');
  await nickname.fill(account);
  if (isNew) await page.getByRole('button',{name:'Продолжить',exact:true}).click();
  // The identity step renders after the async authenticator probe: wait for
  // either variant before deciding which path this engine takes.
  const phraseButton = page.getByRole('button',{name:'Создать ключи на этом устройстве'});
  const prfButton = page.getByRole('button',{name:'Создать ключи и включить защиту'});
  const first = await Promise.any([phraseButton.waitFor({timeout:30000}), prfButton.waitFor({timeout:30000})]).catch(() => null);
  if (first === prfButton) {
    await shot(page, 'identity-prf'); // PRF path state before the fallback decision
    await prfButton.click();
    if (!await phraseButton.waitFor({timeout:10000}).catch(() => null)) {
      await page.getByRole('button',{name:'Использовать фразу устройства'}).click();
    }
  }
  await phraseButton.waitFor({timeout:30000});
  await page.getByLabel('Фраза устройства ·').fill(phrase);
  await page.getByLabel('Повторите фразу устройства').fill(phrase);
  // The legacy single-form UI still requires the invented recovery phrase;
  // the new flow generates it on the recovery step instead.
  const legacyRecovery = page.getByLabel('Отдельная recovery-фраза');
  if (await legacyRecovery.count()) await legacyRecovery.fill('onboarding screenshot independent recovery phrase');
  await shot(page, 'identity');
  await page.getByRole('button',{name:'Создать ключи на этом устройстве'}).click();
  await page.getByRole('heading',{name:'Сохраните recovery-пакет'}).waitFor({timeout:180000}).catch(async e => {
    console.log('DIAG recovery wait:', await page.locator('#notice').textContent().catch('n/a'), await page.url());
    throw e;
  });
  await shot(page, 'recovery');
  const downloaded = page.waitForEvent('download');
  await page.getByRole('button',{name:'Скачать recovery-пакет'}).click(); await downloaded;
  await page.getByRole('checkbox').check();
  await page.getByRole('button',{name:'Завершить регистрацию'}).click();
  await page.getByText('Подключено · E2EE',{exact:true}).waitFor({timeout:120000});
  await page.waitForTimeout(2500); // Flutter projection paints the chat list
  await shot(page, 'chat');
}
// Full flow at the iPhone 13/14 reference size.
const main = await browser('main');
await register(main.page, 'shot_alice', 'synthetic-shot-alice');
// Returning user: unlock card adapts to the vault binding method.
await main.page.reload();
await main.page.getByLabel('Фраза устройства',{exact:true}).waitFor({timeout:30000});
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
console.log('DONE', output);

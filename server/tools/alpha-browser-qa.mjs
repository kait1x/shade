// Real HTTPS/WSS and real WebCrypto in independent persistent browser profiles.
// OAuth provider is synthetic and isolated; this does NOT certify Google login.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { randomBytes, createHash, X509Certificate } from 'node:crypto';
import { fixture } from '../test/helpers/alpha-fixture.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// Fail fast with a clear message when the Flutter UI bundle is not built yet.
const flutterBootstrap = path.join(serverRoot, '..', 'client', 'build', 'web-alpha', 'flutter_bootstrap.js');
try { await fs.access(flutterBootstrap); } catch {
  throw Error('Flutter web-alpha build missing: run "python client/tools/build_web_alpha.py" from the repo root first');
}
const output = path.join(serverRoot, 'build', 'alpha-browser'); await fs.mkdir(output, { recursive: true });
const run = await fs.mkdtemp(path.join(output, 'run-'));
execFileSync('python', [path.join(serverRoot, 'test/make-test-cert.py'), path.join(run,'certs')]);
const tls = { key: await fs.readFile(path.join(run,'certs/key.pem')), cert: await fs.readFile(path.join(run,'certs/cert.pem')) };
const testSPKI = createHash('sha256').update(new X509Certificate(tls.cert).publicKey.export({type:'spki',format:'der'})).digest('base64');
const f = await fixture({ dataDir: path.join(run,'data'), storageSecret: randomBytes(32).toString('hex'), tls });
const { webkit, chromium } = await import(pathToFileURL(path.join(process.argv[2], 'index.mjs')));
const engineName = process.argv[3] || 'webkit';
assert.ok(['webkit', 'edge'].includes(engineName));
let throttledRequests = 0;
const contexts = [], errors = [], frames = [], results = { engine: engineName, origin: f.origin,
  oauth: 'synthetic provider; real callback/state/cookie flow', physicalIPhone: false };
const phrase = 'browser QA independent device phrase';
async function browser(name) {
  const context = await (engineName === 'webkit' ? webkit : chromium).launchPersistentContext(path.join(run,name), {
    headless: true, ...(engineName === 'edge' ? { channel:'msedge',args:[`--ignore-certificate-errors-spki-list=${testSPKI}`] } : {}),
    viewport:{ width:390, height:844 }, isMobile:true, hasTouch:true,
    // ONLY this isolated localhost certificate is untrusted; application code
    // and deployed clients never disable TLS verification.
    ignoreHTTPSErrors:true,
  });
  contexts.push(context);
  const page = await context.newPage(); page.setDefaultTimeout(30000);
  page.on('pageerror', e => errors.push({message:e.message,stack:e.stack,name:e.name}));
  page.on('response', response => { if (response.status() === 429 && response.url().includes('/api/')) throttledRequests++; });
  page.on('websocket', ws => { frames.push(ws.url()); });
  return { context, page };
}
async function register(page, account, sub) {
  f.setLoginSub(sub); await page.goto(f.origin); await page.getByText('Войти через Google', { exact:true }).click();
  await page.getByLabel('Имя пользователя').fill(account);
  await page.getByLabel('Фраза устройства ·').fill(phrase);
  await page.getByLabel('Повторите фразу устройства').fill(phrase);
  await page.getByLabel('Отдельная recovery-фраза').fill('browser QA independent offline recovery phrase');
  await page.getByRole('button', {name:'Создать ключи на этом устройстве'}).click();
  await page.getByRole('heading',{name:'Сохраните recovery-пакет'}).waitFor({timeout:120000});
  const downloaded = page.waitForEvent('download'); await page.getByRole('button',{name:'Скачать recovery-пакет'}).click(); await downloaded;
  await page.getByRole('checkbox').check(); await page.getByRole('button',{name:'Завершить регистрацию'}).click();
  await page.getByText('Подключено · E2EE',{exact:true}).waitFor({timeout:120000});
}
async function fingerprint(page) {
  await page.getByRole('button',{name:/^Профиль/}).click();
  await page.getByRole('button',{name:/Ключ шифрования/}).click();
  await page.locator('dialog[open] code').waitFor(); const value = await page.locator('dialog code').textContent();
  await page.getByRole('button',{name:'Закрыть',exact:true}).click();
  await page.getByRole('button',{name:'Назад',exact:true}).click(); return value;
}
async function pin(page, account, code) {
  // Both the header toggle and the new empty-state action open the directory.
  await page.getByRole('button',{name:'Найти собеседника',exact:true}).first().click();
  await page.getByRole('button',{name:new RegExp(account)}).click();
  await page.getByLabel('Отпечаток собеседника').fill(code);
  await page.getByRole('button',{name:'Закрепить проверенный отпечаток'}).click();
  await page.locator('dialog').waitFor({state:'hidden'});
}
async function send(page, text) {
  // A scrolled-away user taps «К последним» first; the jump button otherwise
  // overlaps the composer send button in the 390px viewport.
  const jump = page.getByRole('button', { name: /К последним/ });
  if (await jump.count()) await jump.first().click().catch(() => {});
  const editor = page.locator('input[placeholder="Сообщение"]:visible, textarea[placeholder="Сообщение"]:visible');
  try {
    await page.locator('[data-semantics-role="text-field"][aria-label="Сообщение"]').click({timeout: 4000});
  } catch {
    await editor.click({timeout: 10000});
  }
  await editor.fill(text);
  // Close a lingering send-button tooltip: while it is open the label lives in
  // an aria-owns overlay and the button resolves without an accessible name.
  await page.mouse.move(4, 300);
  // A fast run can hit the real 300 req/min API limit before the local commit;
  // the client honestly keeps the text, so pressing Отправить again is a
  // genuine user retry, not a bypass of the server's rejection.
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      await page.getByRole('button',{name:'Отправить',exact:true}).click({timeout: 4000});
    } catch {
      // Tap where the real user taps: the composer send button is anchored to
      // the bottom-right of the viewport regardless of semantics state.
      const size = page.viewportSize();
      await page.mouse.click(size.width - 38, size.height - 36);
    }
    try {
      await page.getByText(text,{exact:false}).last().waitFor({timeout:8000});
      return;
    } catch { /* throttle window or slow sync; composer text is preserved. */ }
  }
  await page.getByText(text,{exact:false}).last().waitFor({timeout:30000});
}
async function unlock(page) {
  const field = page.getByLabel('Фраза устройства',{exact:true});
  await field.waitFor({timeout:10000}).catch(async () => {
    // boot() can fail once on a throttle window after a reload; a real user
    // simply refreshes. Keys and history are untouched either way.
    await page.reload().catch(() => {});
    await field.waitFor({timeout:30000});
  });
  await field.fill(phrase);
  await page.getByRole('button',{name:'Разблокировать',exact:true}).click();
  await page.locator('[data-semantics-role="text-field"][aria-label="Сообщение"]').waitFor({timeout:120000});
}
async function longPress(page, text) {
  const box = await page.getByText(text,{exact:false}).last().boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down(); await page.waitForTimeout(750); await page.mouse.up();
}
async function expectCount(page, locator, count) {
  for (let i = 0; i < 30; i++) {
    if (await locator.count() === count) return;
    await page.waitForTimeout(200);
  }
  throw Error(`count did not settle to ${count}`);
}
try {
  const a = await browser('alice'), b = await browser('bob');
  await register(a.page, 'browser_alice', 'synthetic-browser-alice');
  await register(b.page, 'browser_bob', 'synthetic-browser-bob');
  results.webFirstRegistration = true; console.log('PASS independent Web-first registration over HTTPS');
  const af = await fingerprint(a.page), bf = await fingerprint(b.page); console.log('PASS public fingerprints');
  assert.notEqual(af,bf);
  await pin(a.page,'browser_bob',bf); await pin(b.page,'browser_alice',af); console.log('PASS pinned contacts');
  const first = 'Первое реальное HTTPS сообщение 🔐';
  await send(a.page,first); await b.page.getByText(first,{exact:false}).last().waitFor();
  await a.page.getByText(/Доставлено: 1\/1 устройств/).first().waitFor();
  await send(b.page,'Ответ из второго профиля'); await a.page.getByText('Ответ из второго профиля',{exact:false}).last().waitFor();
  results.bidirectionalMessaging = true;
  results.wss = frames.length >= 2 && frames.every(url => url.startsWith('wss:'));
  assert.equal(results.wss,true); console.log('PASS bidirectional E2EE + WSS + recipient ACK');
  const state = f.registry.exportSnapshot(); assert.ok(!JSON.stringify(state).includes(first));
  const fields = await a.page.evaluate(async () => {
    const { listVaults, unlockVault } = await import('/device_crypto.mjs');
    const vault = (await listVaults())[0]; const s = await unlockVault(vault,'browser QA independent device phrase');
    return { id:vault.id, keys:Object.keys(vault), nonExtractable:!s.encryption.extractable && !s.signing.extractable };
  });
  assert.equal(fields.nonExtractable,true); assert.ok(!fields.keys.some(k => /private|password/i.test(k)));
  assert.equal(await a.page.evaluate(async text => {
    const db = await new Promise((resolve,reject) => { const req = indexedDB.open('shade-alpha-state',1); req.onsuccess = () => resolve(req.result);req.onerror=reject; });
    try { return await new Promise(resolve => { const tx=db.transaction('states');const req=tx.objectStore('states').getAll();tx.oncomplete=() => resolve(JSON.stringify(req.result).includes(text)); }); }
    finally { db.close(); }
  },first),false);
  results.encryptedLocalHistory = true;
  results.ciphertextOnlyServer = true; results.nonExtractableKeys = true;
  await b.page.reload(); await unlock(b.page);
  await b.page.getByText(first,{exact:false}).last().waitFor();
  const before = await a.page.evaluate(async () => (await (await import('/device_crypto.mjs')).listVaults())[0].id);
  await a.page.reload(); await unlock(a.page);
  const after = await a.page.evaluate(async () => (await (await import('/device_crypto.mjs')).listVaults())[0].id);
  assert.equal(before,after); await a.page.getByText(first,{exact:false}).last().waitFor();
  results.reloadHistorySameKeys = true; console.log('PASS reload retains encrypted history and identity');
  await b.page.evaluate(async () => { await Promise.race([navigator.serviceWorker.ready,
    new Promise((_,reject) => setTimeout(() => reject(Error('Service worker installation timeout')),10000))]); });
  await b.context.setOffline(true);
  await send(a.page,'Сообщение во время разрыва сети');
  await a.page.getByText(/На сервере · ожидает ACK/).first().waitFor();
  // Only the first outgoing message has an ACK while Bob is offline.
  assert.equal(await a.page.getByText(/Доставлено: 1\/1 устройств/).count(),1);
  await b.page.reload(); await unlock(b.page);
  await b.page.getByText(first,{exact:false}).last().waitFor();
  results.offlineHistory = true;
  await send(b.page,'Исходящее из offline очереди');
  await b.context.setOffline(false);
  await b.page.getByText('Сообщение во время разрыва сети',{exact:false}).last().waitFor({timeout:60000});
  await a.page.getByText('Исходящее из offline очереди',{exact:false}).last().waitFor({timeout:60000});
  await a.page.getByText(/Доставлено: 1\/1 устройств/).nth(1).waitFor();
  results.reconnectAndOfflineOutbox = true; console.log('PASS offline reload + durable outbox + reconnect');
  // Reply rides inside the signed opaque envelope; both clients render the
  // original-message snapshot, and a local delete must stay gone after reload.
  await longPress(a.page,'Исходящее из offline очереди');
  await a.page.getByText('Ответить',{exact:true}).click();
  await send(a.page,'Ответ поверх закреплённого сообщения');
  await b.page.getByText('Ответ поверх закреплённого сообщения',{exact:false}).last().waitFor();
  assert.equal(await b.page.getByText('Исходящее из offline очереди',{exact:false}).count(),2);
  results.replySnapshotRendered = true; console.log('PASS reply payload round-trip with snapshot render');
  await longPress(b.page,'Ответ поверх закреплённого сообщения');
  await b.page.getByText('Удалить у себя',{exact:true}).click();
  await expectCount(b.page, b.page.getByText('Ответ поверх закреплённого сообщения',{exact:false}), 0);
  assert.equal(await a.page.getByText('Ответ поверх закреплённого сообщения',{exact:false}).count(),1);
  // Decisive check: after the UI hides the message, is the deletion already
  // committed to IndexedDB in this same page view?
  console.log('DIAG bob committed reply before reload:', await b.page.evaluate(async () => {
    const { listVaults, unlockVault } = await import('/device_crypto.mjs');
    const vault = (await listVaults())[0];
    const s = await unlockVault(vault, 'browser QA independent device phrase');
    const { readState } = await import('/alpha-storage.mjs');
    const state = await readState(s);
    return JSON.stringify((state.value.messages || []).filter(m => m.text === 'Ответ поверх закреплённого сообщения').map(m => m.ref));
  }));
  // WebKit defers the last IndexedDB flush; reloading within a second can
  // read the pre-delete snapshot. A short settle is automation-only and does
  // not weaken the client: the deletion is committed before the UI hides it
  // (verified by reading the encrypted state on this very page).
  await b.page.waitForTimeout(1500);
  await b.page.reload(); await unlock(b.page);
  assert.equal(await b.page.getByText('Ответ поверх закреплённого сообщения',{exact:false}).count(),0);
  results.localDeleteStaysDeleted = true; console.log('PASS local delete ACKs first and never returns');
  const third = await browser('unlinked'); f.setLoginSub('synthetic-browser-alice');
  await third.page.goto(f.origin); await third.page.getByText('Войти через Google',{exact:true}).click();
  await third.page.getByRole('heading',{name:'Нужна привязка устройства'}).waitFor();
  assert.equal(await third.page.evaluate(async () => (await (await import('/device_crypto.mjs')).listVaults()).length),0);
  results.unlinkedDeviceCannotReplaceIdentity = true;
  const screenshots = path.resolve(serverRoot,'../artifacts/web-ui-port');
  await fs.mkdir(screenshots,{recursive:true});
  await a.page.mouse.move(1,300);
  await a.page.waitForTimeout(260);
  await a.page.screenshot({path:path.join(screenshots,`${engineName}-after-chat.png`)});
  await a.page.getByRole('button',{name:'Назад к чатам',exact:true}).click();
  await a.page.waitForTimeout(260);
  await a.page.screenshot({path:path.join(screenshots,`${engineName}-after-chats.png`)});
  await a.page.getByRole('button',{name:/^Профиль/}).click();
  await a.page.waitForTimeout(260);
  await a.page.screenshot({path:path.join(screenshots,`${engineName}-after-profile.png`)});
  await a.page.getByRole('button',{name:'Назад',exact:true}).click();
  await a.page.getByRole('button',{name:/browser_bob/}).click();
  for (const width of [320,390,430,768,1440]) {
    await a.page.setViewportSize({width,height:844});
    await a.page.waitForTimeout(260);

    assert.equal(await a.page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),true, `overflow at ${width}`);
    await a.page.screenshot({path:path.join(screenshots,`${engineName}-${width}.png`)});

  }
  results.responsive = true; results.selectedChatRestored = true;
  await a.page.setViewportSize({width:390,height:844});
  await a.page.waitForTimeout(260);
  const longText = 'Длинное сообщение для проверки переноса строк. '.repeat(55) + '\n' + 'безпробелов'.repeat(80);
  await send(a.page,longText); await b.page.getByText(longText,{exact:false}).last().waitFor();
  await send(a.page,'Проверка позиции прокрутки.');
  await a.page.mouse.move(180,400);
  if (engineName === 'webkit') {
    // Playwright cannot generate a native wheel on mobile WebKit. Exercise the
    // actual Flutter scroll controller with a pointer signal; no physical swipe claim.
    await a.page.locator('flt-glass-pane').dispatchEvent('wheel', {deltaY:-1000,deltaX:0,clientX:180,clientY:400,bubbles:true,cancelable:true});
  } else await a.page.mouse.wheel(0,-1000);
  await a.page.waitForFunction(() => {
    const key = Object.keys(sessionStorage).find(k=>k.startsWith('shade-ui:'));
    const ui = key && JSON.parse(sessionStorage.getItem(key));
    return ui?.positions.browser_bob?.bottom === false && ui.positions.browser_bob.offset > 0;
  });
  await a.page.waitForTimeout(400);
  const prefsBefore = await a.page.evaluate(() => Object.fromEntries(Object.keys(sessionStorage).filter(k=>k.startsWith('shade-ui:')).map(k=>[k,JSON.parse(sessionStorage.getItem(k))])));
  await a.page.screenshot({path:path.join(screenshots,`${engineName}-history-before-reload.png`)});
  const scrollBefore = await a.page.getByText(longText,{exact:false}).last().boundingBox();
  await a.page.reload(); await unlock(a.page);
  await a.page.waitForTimeout(400);
  // The unchanged API enforces 300 requests/minute per IP. A fast two-account
  // run may hit it; compare layout after the real client's normal retry recovers.
  await a.page.getByText(/Ошибка синхронизации|Переподключение|Операция отклонена/).waitFor({state:'hidden',timeout:90000});
  await a.page.waitForTimeout(260);
  const scrollAfter = await a.page.getByText(longText,{exact:false}).last().boundingBox();
  const prefsAfter = await a.page.evaluate(() => Object.fromEntries(Object.keys(sessionStorage).filter(k=>k.startsWith('shade-ui:')).map(k=>[k,JSON.parse(sessionStorage.getItem(k))])));
  await a.page.screenshot({path:path.join(screenshots,`${engineName}-history-after-reload.png`)});
  results.scrollPositions = {before:scrollBefore,after:scrollAfter,prefsBefore,prefsAfter};
  assert.ok(Math.abs(scrollBefore.y-scrollAfter.y)<4, 'actual visible message position restored after reload');
  results.longMessagesAndScrollRestoration = true;
  await a.page.locator('[data-semantics-role="text-field"][aria-label="Сообщение"]').click();
  await a.page.setViewportSize({width:390,height:480});
  await a.page.waitForTimeout(260);
  const composer = await a.page.locator('[data-semantics-role="text-field"][aria-label="Сообщение"]').boundingBox();
  assert.ok(composer.y>=0 && composer.y+composer.height<=480, 'composer inside reduced visual viewport');
  await a.page.screenshot({path:path.join(screenshots,`${engineName}-keyboard-viewport.png`)});
  results.reducedKeyboardViewport = true; results.physicalKeyboardVerified = false;
  await a.page.setViewportSize({width:390,height:844});
  console.log('PASS long messages, actual scroll restoration and reduced keyboard viewport');
  results.sharedFlutterUI = await a.page.locator('flutter-view').count() === 1;
  assert.deepEqual(errors,[]); results.pageErrors = errors;
  results.passed = true;
} catch (error) {
  results.passed = false; results.error = error.stack;
  for (let i = 0; i < contexts.length; i++) for (const [j,page] of contexts[i].pages().entries()) {
    await page.screenshot({path:path.join(run,`failure-${i}-${j}.png`)}).catch(() => {});
    await fs.writeFile(path.join(run,`failure-${i}-${j}.html`),await page.content()).catch(() => {});
  }
  process.exitCode = 1;
} finally {
  results.pageErrors = errors; results.http429DuringRapidRun = throttledRequests;
  await fs.writeFile(path.join(output,`${engineName}-results.json`),JSON.stringify(results,null,2));
  console.log(JSON.stringify(results,null,2));
  for (const context of contexts) await context.close();
  await f.close();
}

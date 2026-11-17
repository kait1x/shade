// Relative performance metrics for the Shade web-alpha PWA on a desktop
// headless Chromium with CPU throttling. These are NOT Samsung Galaxy A31
// numbers: no physical device is involved. They exist to compare builds of
// the same rig and to catch transfer-size and decode regressions.
// Usage: node tools/alpha-perf-check.mjs <playwright-core-dir> [throttle]
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { randomBytes, createHash, X509Certificate } from 'node:crypto';
import { fixture } from '../test/helpers/alpha-fixture.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const throttle = Number(process.argv[3] || 4);
const bootstrap = path.join(serverRoot, '..', 'client', 'build', 'web-alpha', 'flutter_bootstrap.js');
try { await fs.access(bootstrap); } catch {
  throw Error('Missing Flutter web-alpha build: run "python client/tools/build_web_alpha.py" first');
}
const output = path.join(serverRoot, 'build', 'alpha-perf'); await fs.mkdir(output, { recursive: true });
const run = await fs.mkdtemp(path.join(output, 'run-'));
execFileSync('python', [path.join(serverRoot, 'test/make-test-cert.py'), path.join(run, 'certs')]);
const tls = {
  key: await fs.readFile(path.join(run, 'certs/key.pem')),
  cert: await fs.readFile(path.join(run, 'certs/cert.pem'))
};
const testSPKI = createHash('sha256').update(new X509Certificate(tls.cert).publicKey
  .export({ type: 'spki', format: 'der' })).digest('base64');
const f = await fixture({ dataDir: path.join(run, 'data'), storageSecret: randomBytes(32).toString('hex'), tls });
const { chromium } = await import(pathToFileURL(path.join(process.argv[2], 'index.mjs')));
const results = { throttle, physicalDevice: false, engine: 'chromium (desktop headless)' };
const phrase = 'browser perf independent device phrase';

const context = await chromium.launchPersistentContext(path.join(run, 'perf'), {
  headless: true, channel: 'msedge',
  args: [`--ignore-certificate-errors-spki-list=${testSPKI}`],
  viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true,
  ignoreHTTPSErrors: true
});
const page = await context.newPage();
page.setDefaultTimeout(60000);
const session = await context.newCDPSession(page);
await session.send('Performance.enable');

// Page-driven bytes only: SW-precached fetches carry no frame.
let pageBytes = 0, pageRequests = 0;
page.on('response', async r => {
  if (!r.frame()) return;
  pageRequests++;
  const length = Number(r.headers()['content-length'] || 0);
  if (length) pageBytes += length;
});
const heap = async () => {
  const m = await session.send('Performance.getMetrics');
  const pick = n => m.metrics.find(x => x.name === n)?.value ?? 0;
  return { jsHeapMB: +(pick('JSHeapUsedSize') / 1048576).toFixed(1), nodes: pick('Nodes') };
};

try {
  await session.send('Emulation.setCPUThrottlingRate', { rate: throttle });
  const t = async (work) => { const s = performance.now(); const v = await work(); return [Math.round(performance.now() - s), v]; };

  // 1. Cold shell: fresh profile, throttled CPU — page-driven bytes to first UI.
  const [shellMs] = await t(async () => {
    await page.goto(f.origin);
    await page.getByText('Войти через Google', { exact: true }).waitFor();
  });
  results.coldShell = { ms: shellMs, pageBytesMB: +(pageBytes / 1048576).toFixed(2), pageRequests };
  console.log('COLD_SHELL', JSON.stringify(results.coldShell));
  results.firstVisitPageBytesMB = results.coldShell.pageBytesMB;

  // Register (unthrottled: RSA-4096 keygen is registration-specific, measured
  // once as a reference, not an app-start metric).
  await session.send('Emulation.setCPUThrottlingRate', { rate: 1 });
  await page.getByText('Войти через Google', { exact: true }).click();
  await page.getByLabel('Имя пользователя').fill('perf_alice');
  await page.getByLabel('Фраза устройства ·').fill(phrase);
  await page.getByLabel('Повторите фразу устройства').fill(phrase);
  await page.getByLabel('Отдельная recovery-фраза').fill('perf QA independent offline recovery phrase');
  await page.getByRole('button', { name: 'Создать ключи на этом устройстве' }).click();
  await page.getByRole('heading', { name: 'Сохраните recovery-пакет' }).waitFor({ timeout: 120000 });
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Завершить регистрацию' }).click();
  await page.getByText('Подключено · E2EE', { exact: true }).waitFor({ timeout: 120000 });
  // Wait for the Flutter UI and the offline cache to settle before reload.
  await page.evaluate(() => window.shadeAction('sync', '{}'));
  const swReady = await page.evaluate(async () => {
    await Promise.race([navigator.serviceWorker.ready,
      new Promise((_, reject) => setTimeout(() => reject(Error('sw timeout')), 15000))]);
    for (let i = 0; i < 200; i++) {
      const keys = await caches.keys();
      const key = keys.find(k => k.startsWith('shade-alpha-'));
      if (key) {
        const cache = await caches.open(key);
        if (await cache.match('/flutter-ui/main.dart.js')) return key;
      }
      await new Promise(r => setTimeout(r, 250));
    }
    throw Error('offline cache never completed');
  });
  await session.send('Emulation.setCPUThrottlingRate', { rate: throttle });
  const cacheKeys = await page.evaluate(async () => {
    const keys = await caches.keys();
    const cache = await caches.open(keys.find(k => k.startsWith('shade-alpha-')));
    let bytes = 0, count = 0;
    for (const request of await cache.keys()) {
      count++;
      const response = await cache.match(request);
      if (response) bytes += (await response.arrayBuffer()).byteLength;
    }
    return { count, cacheMB: +(bytes / 1048576).toFixed(1) };
  });
  results.offlineCache = cacheKeys;
  console.log('OFFLINE_CACHE', JSON.stringify(cacheKeys));

  // 2. Warm start: reload from the offline cache, unlock, Flutter ready.
  for (const [label, rate] of [['warmStartThrottled', throttle], ['warmStartUnthrottled', 1]]) {
    await session.send('Emulation.setCPUThrottlingRate', { rate });
    const before = await heap();
    const [shell, flutter] = [null, null];
    const marks = { shell: 0, flutter: 0 };
    const navStart = Date.now();
    await page.goto(f.origin);
    await page.getByLabel('Фраза устройства').waitFor();
    marks.shell = Date.now() - navStart;
    await page.getByLabel('Фраза устройства').fill(phrase);
    const [unlockMs] = await t(async () => {
      await page.getByRole('button', { name: 'Разблокировать' }).click();
      await page.locator('.flutter-loading').waitFor({ state: 'detached', timeout: 120000 });
      // A fresh account has zero messages; the first projection render is the
      // honest "UI is live" marker.
      await page.waitForFunction(() => window.__lastProjection != null, undefined, { timeout: 120000 });
    });
    marks.flutter = Date.now() - navStart;
    const after = await heap();
    results[label] = { shellMs: marks.shell, flutterReadyMs: marks.flutter, unlockAndFirstRenderMs: unlockMs, ...after };
    console.log(label.toUpperCase(), JSON.stringify(results[label]));
    if (label === 'warmStartThrottled') results.memoryAfterStart = before;
  }

  await session.send('Emulation.setCPUThrottlingRate', { rate: throttle });
  // 3. Seed a long history in the self-chat (favorites): texts + photos.
  // The relay budget restores only after a quiet window (the 429 body is
  // text/html, so retries themselves must not hammer it). Seeding is paced,
  // then a drain probe waits for /api/session to return 200 before syncing.
  const seeded = await page.evaluate(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const client = window.__shadeClient;
    const account = client.session.account;
    const realRefresh = client.refreshOwn;
    client.refreshOwn = async () => {};
    // The 15 s background sync timer shares the per-minute relay budget;
    // pause it for the seed like the soak does.
    clearInterval(client.timer);
    const drained = async () => {
      for (let attempt = 0; attempt < 20; attempt++) {
        try {
          const response = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' });
          if (response.ok) return true;
        } catch { /* keep waiting for the window to reset */ }
        await sleep(8000);
      }
      return false;
    };
    try {
      for (let i = 0; i < 40; i++) {
        await client.send(account, `Сообщение истории №${i} — проверка прокрутки длинного чата.`);
        await sleep(600);
      }
      const canvas = document.createElement('canvas');
      canvas.width = 480; canvas.height = 640;
      const ctx = canvas.getContext('2d');
      for (let p = 0; p < 4; p++) {
        const gradient = ctx.createLinearGradient(0, 0, 480, 640);
        gradient.addColorStop(0, `hsl(${p * 60},80%,60%)`);
        gradient.addColorStop(1, '#111');
        ctx.fillStyle = gradient; ctx.fillRect(0, 0, 480, 640);
        const data = canvas.toDataURL('image/jpeg', 0.8).split(',')[1];
        await client.sendMedia(account, data, 'image/jpeg');
        await sleep(900);
      }
    } finally { client.refreshOwn = realRefresh; }
    await drained();
    await client.sync();
    // Restore the background sync cadence exactly as start() installed it.
    client.timer = setInterval(() => client.sync().catch(() => {}), 15000);
    return (client.state.messages || []).length;
  });
  results.seededMessages = seeded;
  console.log('SEEDED', seeded, 'messages');

  // 4. Scroll through the whole history (reversed list): rAF throughput while
  // the lazy list builds items under CPU throttle.
  await page.waitForTimeout(600);
  const scrollProbe = page.evaluate(() => new Promise(resolve => {
    let frames = 0; const t0 = performance.now();
    const tick = () => { frames++; performance.now() - t0 < 8000 ? requestAnimationFrame(tick) : resolve({ frames, ms: Math.round(performance.now() - t0), fps: +(frames / ((performance.now() - t0) / 1000)).toFixed(1) }); };
    requestAnimationFrame(tick);
  }));
  await page.mouse.move(195, 420);
  for (let step = 0; step < 24; step++) {
    await page.locator('flt-glass-pane').dispatchEvent('wheel',
      { deltaY: 1200, deltaX: 0, clientX: 195, clientY: 420, bubbles: true, cancelable: true });
    await page.waitForTimeout(320);
  }
  results.scrollThroughHistory = await scrollProbe;
  console.log('SCROLL', JSON.stringify(results.scrollThroughHistory));
  results.memoryAfterScroll = await heap();
  console.log('MEM_AFTER_SCROLL', JSON.stringify(results.memoryAfterScroll));

  // 5. Profile open: tap the avatar button, wait for the profile list.
  const [profileMs] = await t(async () => {
    await page.getByRole('button', { name: /^Профиль/ }).click();
    await page.getByText('АККАУНТ И БЕЗОПАСНОСТЬ').waitFor({ timeout: 30000 });
    await page.waitForTimeout(300);
  });
  results.profileOpenMs = profileMs;
  console.log('PROFILE_OPEN', profileMs, 'ms');

  // 6. Sticker wall (vinyl) render: own collection loads inventory and the
  // flowers decode path.
  const [stickersMs] = await t(async () => {
    await page.getByText('ВИНИЛОВАЯ СТЕНА', { exact: false }).waitFor({ timeout: 30000 });
    await page.waitForTimeout(1200);
  });
  results.stickerWallSettleMs = stickersMs;
  console.log('STICKER_WALL', stickersMs, 'ms (settle window incl. vinyl decode)');
  results.memoryAfterProfile = await heap();
  console.log('MEM_AFTER_PROFILE', JSON.stringify(results.memoryAfterProfile));

  // 7. Long-run soak: repeated full syncs + projections, heap must stay flat.
  // Paced like the seed: the per-minute relay budget is shared by everything
  // above, so the soak waits for a drained window and spaces its cycles.
  const beforeSoak = await heap();
  await page.waitForTimeout(8000);
  // The 15 s background sync timer shares the relay budget; pause it for the
  // paced soak so the request rate stays under the contract.
  await page.evaluate(() => clearInterval(window.__shadeClient.timer));
  await page.evaluate(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const client = window.__shadeClient;
    const drained = async () => {
      for (let attempt = 0; attempt < 15; attempt++) {
        try {
          const response = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' });
          if (response.ok) return true;
        } catch { /* the window needs quiet time to reset */ }
        await sleep(8000);
      }
      return false;
    };
    const paced = async work => {
      for (let attempt = 0; attempt < 3; attempt++) {
        try { return await work(); } catch (error) {
          if (attempt === 2 || !/Слишком много запросов|Сервер недоступен|отклонена/.test(error.message)) throw error;
          await drained();
        }
      }
    };
    for (let cycle = 0; cycle < 10; cycle++) {
      await paced(() => client.send(client.session.account, `Soak ${cycle}`));
      await paced(() => client.sync());
      for (let i = 0; i < 25; i++) await new Promise(r => setTimeout(r, 16));
      await sleep(4000);
    }
  });
  // Restore the background sync cadence exactly as start() installed it.
  await page.evaluate(() => {
    const client = window.__shadeClient;
    clearInterval(client.timer);
    client.timer = setInterval(() => client.sync().catch(() => {}), 15000);
  });
  await page.waitForTimeout(1500);
  const afterSoak = await heap();
  results.soak = { before: beforeSoak, after: afterSoak };
  console.log('SOAK', JSON.stringify(results.soak));

  results.passed = true;
} catch (error) {
  results.passed = false;
  results.error = error.stack || String(error);
  await page.screenshot({ path: path.join(run, 'failure.png') }).catch(() => {});
  process.exitCode = 1;
} finally {
  await fs.writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results, null, 2));
  await context.close();
  await f.close();
}

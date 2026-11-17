// Isolated PWA preview for physical-device testing (Samsung Galaxy A31/A25).
// Runs the real alpha server with a THROWAWAY data dir and the synthetic
// OAuth provider: no production data, no real Google accounts, nothing
// shared with the release deployment. The phone reaches it over USB with
// `adb reverse`, which makes http://localhost:<port> a secure context on the
// device (service worker, WebCrypto and Web Push all work — no certificates,
// no public domain).
//
// Usage from the repo root:
//   node server/tools/run-alpha-preview.mjs [--port 3101] [--fresh]
// Optional: --tls cert.pem key.pem for LAN/tunnel deployments (public origin).
import fs from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const port = Number(arg('--port', 3101));
const fresh = args.includes('--fresh');
const dataDir = path.join(serverRoot, 'build', 'alpha-preview', 'data');
if (fresh) await fs.rm(dataDir, { recursive: true, force: true });
await fs.mkdir(dataDir, { recursive: true });

const { fixture } = await import(pathToFileURL(path.join(serverRoot, 'test/helpers/alpha-fixture.mjs')));
const webPush = createRequire(import.meta.url)('web-push');

// VAPID keys persist in the throwaway data dir so device subscriptions
// survive preview restarts (a new key would orphan every subscription).
const vapidFile = path.join(serverRoot, 'build', 'alpha-preview', 'vapid.json');
let vapidKeys;
try {
  vapidKeys = JSON.parse(await fs.readFile(vapidFile, 'utf8'));
} catch {
  vapidKeys = webPush.generateVAPIDKeys();
  await fs.writeFile(vapidFile, JSON.stringify(vapidKeys), 'utf8');
}

const tls = args.includes('--tls')
  ? { cert: await fs.readFile(arg('--tls', '')), key: await fs.readFile(arg('--tls-key', '')) }
  : null;
const f = await fixture({
  port, dataDir, storageSecret: 'preview-throwaway-instance-secret',
  tls,
  vapidKeys: { ...vapidKeys, subject: 'mailto:preview@shade.local' },
  // Real Web Push delivery from the preview instance: subscriptions created
  // on the phone receive a live wake notification (no message content).
  pushSender: async (sub, payload, options) => {
    try { await webPush.sendNotification(sub, JSON.stringify(payload), options); }
    catch (error) { console.log('[preview] push delivery skipped:', error.statusCode || error.message); }
  }
});

let url = f.origin;
console.log('Shade PWA preview (isolated throwaway instance)');
console.log(`  data dir : ${dataDir}${fresh ? '  (fresh)' : ''}`);
console.log(`  origin   : ${url}`);
console.log('  OAuth    : synthetic provider (any login creates a test session)');
console.log('  VAPID    : enabled (Web Push works on the device)');
if (!tls) {
  const devices = execFileSync('adb', ['devices'], { encoding: 'utf8' });
  const attached = devices.split('\n').filter(l => l.endsWith('\tdevice')).length;
  if (attached > 0) {
    try {
      execFileSync('adb', ['reverse', `tcp:${port}`, `tcp:${port}`]);
      console.log(`  adb      : reverse tcp:${port} OK — откройте на телефоне http://localhost:${port}`);
      url = `http://localhost:${port}`;
    } catch (error) {
      console.log('  adb      : reverse failed:', error.message);
    }
  } else {
    console.log('  adb      : устройство не найдено. Подключите телефон по USB,');
    console.log(`             включите «Отладку по USB» и выполните: adb reverse tcp:${port} tcp:${port}`);
    console.log(`             затем откройте на телефоне http://localhost:${port}`);
  }
} else {
  console.log('  TLS      : включён — открывайте origin с устройства (доверенный сертификат или туннель).');
}
console.log(`\nГотово: ${url}  — Ctrl+C останавливает сервер. Данные превью одноразовые.`);

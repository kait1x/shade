// Service Worker push handlers: wake-only notification, no payload parsing,
// notificationclick focuses an existing client or opens the app.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const swPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../client/web/alpha-sw.js');

function loadSW({ clients = [] } = {}) {
  const handlers = {};
  const notifications = [];
  const focused = [];
  const opened = [];
  const self = {
    addEventListener: (name, fn) => { handlers[name] = fn; },
    location: { origin: 'https://shade.test' },
    registration: { showNotification: async (title, opts) => notifications.push({ title, opts }) },
    clients: {
      matchAll: async () => clients,
      openWindow: async url => { opened.push(url); },
      claim: async () => {}
    },
    skipWaiting: () => {},
    SHADE_UI_VERSION: 'test',
    SHADE_UI_FILES: []
  };
  const context = vm.createContext({
    self,
    importScripts: () => {},
    caches: { open: async () => ({ addAll: async () => {}, match: async () => null }), keys: async () => [], delete: async () => {} },
    fetch: async () => ({}),
    URL,
    console
  });
  vm.runInContext(fs.readFileSync(swPath, 'utf8'), context);
  return { handlers, notifications, focused, opened };
}
const waitUntil = () => { const promises = []; return { waitUntil: p => promises.push(p), done: () => Promise.all(promises) }; };

test('push handler shows a static wake-only notification and never reads the payload', async () => {
  const sw = loadSW();
  const event = waitUntil();
  // If the handler ever touches event.data, the test fails: wake-only means
  // the SW does not parse server payload at all.
  Object.defineProperty(event, 'data', { get() { throw Error('SW must not read push payload'); } });
  sw.handlers.push(event);
  await event.done();
  assert.equal(sw.notifications.length, 1);
  assert.equal(sw.notifications[0].title, 'Shade');
  assert.equal(sw.notifications[0].opts.body, 'Новое сообщение');
  assert.equal(sw.notifications[0].opts.tag, 'shade-wake');
  assert.ok(!JSON.stringify(sw.notifications[0].opts).match(/message|cipher|account|ref/i));
});

test('notificationclick focuses an existing window', async () => {
  const focused = [];
  const client = { focus: async () => { focused.push(client); } };
  const sw = loadSW({ clients: [client] });
  const event = waitUntil();
  let closed = false;
  event.notification = { close: () => { closed = true; } };
  sw.handlers.notificationclick(event);
  await event.done();
  assert.ok(closed);
  assert.equal(focused.length, 1);
  assert.equal(sw.opened.length, 0);
});

test('notificationclick opens the app when no window exists', async () => {
  const sw = loadSW({ clients: [] });
  const event = waitUntil();
  event.notification = { close: () => {} };
  sw.handlers.notificationclick(event);
  await event.done();
  assert.deepEqual(sw.opened, ['/']);
});
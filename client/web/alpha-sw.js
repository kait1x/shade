'use strict';
// Versioned allowlist. Never cache auth, API responses or arbitrary URLs.
importScripts('/flutter-ui/cache-files.js');
const CACHE = 'shade-alpha-flutter-' + self.SHADE_UI_VERSION;
const FILES = ['/', '/alpha.html', '/alpha.css', '/alpha-ui.mjs', '/alpha-client.mjs', '/alpha-storage.mjs',
  '/device_crypto.mjs', '/protocol/device-v2.mjs', '/alpha-manifest.json', '/socket.io/socket.io.js',
  '/icons/Icon-192.png', '/icons/Icon-512.png', '/icons/Icon-maskable-512.png', '/icons/apple-touch-icon.png', '/favicon.png', ...self.SHADE_UI_FILES];
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES))));
self.addEventListener('activate', event => event.waitUntil((async () => {
  for (const key of await caches.keys()) if ((key.startsWith('shade-alpha-') || key.startsWith('shade-web-beta-')) && key !== CACHE) await caches.delete(key);
  await self.clients.claim();
})()));
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.search || !FILES.includes(url.pathname)) return;
  event.respondWith((async () => {
    try { return await fetch(event.request); }
    catch { return (await caches.open(CACHE)).match(url.pathname); }
  })());
});

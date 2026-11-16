"""Build the existing Flutter app's isolated Web Beta and static-only cache."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

client = Path(__file__).resolve().parents[1]
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('Flutter not found in PATH')
subprocess.run([flutter, 'build', 'web', '--release', '--no-web-resources-cdn',
                *sys.argv[1:]], cwd=client, check=True)
root = client / 'build' / 'web'
# Only artifacts in this explicit allowlist can ever be served from our cache.
files = sorted(p for p in root.rglob('*') if p.is_file() and
               p.name not in ('shade-sw.js', 'flutter_service_worker.js') and
               not p.name.endswith('.map'))
digest = hashlib.sha256()
for p in files:
    digest.update(p.relative_to(root).as_posix().encode())
    digest.update(p.read_bytes())
version = digest.hexdigest()[:20]
urls = ['./' + p.relative_to(root).as_posix() for p in files]
worker = """'use strict';
const CACHE = 'shade-web-beta-VERSION';
const FILES = URLS;
const ALLOWED = new Set(FILES.map(p => new URL(p, self.registration.scope).href));
const INDEX = new URL('./index.html', self.registration.scope).href;
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(FILES)));
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key.startsWith('shade-web-beta-') && key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin || url.search) return;
  // No arbitrary routes or authenticated requests are cached.
  const home = req.mode === 'navigate' &&
    (url.href === self.registration.scope || url.href === INDEX);
  if (!home && !ALLOWED.has(url.href)) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    // Keep each running release consistent; a new worker waits for old tabs.
    const saved = await cache.match(home ? INDEX : req);
    if (saved) return saved;
    return fetch(req);
  })());
});
""".replace('VERSION', version).replace('URLS', json.dumps(urls))
(root / 'shade-sw.js').write_text(worker, encoding='utf-8')
print(f'Web Beta ready: {root} ({len(files)} static files, cache {version})')

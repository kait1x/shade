"""Build the shared Flutter UI for the existing Alpha transport, without CDN."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

client = Path(__file__).resolve().parents[1]
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('Flutter not found in PATH')
subprocess.run([flutter, 'build', 'web', '--release', '--csp',
                '--no-web-resources-cdn', '--no-web-content-hash',
                '--target', 'lib/main_alpha.dart', '--base-href', '/flutter-ui/',
                '--output', str(client / 'build/web-alpha')], cwd=client, check=True)
root = client / 'build/web-alpha'
bootstrap = root / 'flutter_bootstrap.js'
source = bootstrap.read_text(encoding='utf-8')
marker = '_flutter.loader.load('
if marker not in source:
    raise SystemExit('Flutter bootstrap changed; review embedding before serving')
bootstrap.write_text(source[:source.rindex(marker)] + """_flutter.loader.load({config: {
  hostElement: document.querySelector('#flutter-host'),
  entrypointBaseUrl: '/flutter-ui/', assetBase: '/flutter-ui/',
  canvasKitBaseUrl: '/flutter-ui/canvaskit/'
}});""", encoding='utf-8')
shutil.copytree(client / 'fonts/emoji', root / 'fonts', dirs_exist_ok=True)
# The deployed build is a single dart2js/canvaskit target (see the generated
# flutter_bootstrap.js buildConfig). Everything below is dead weight the
# runtime never fetches: the skwasm/wimp engines are reachable only from a
# dart2wasm build entry, webparagraph/ additionally requires a
# preferWebParagraph flag absent from buildConfig, and .js.symbols files are
# only consumed by DevTools symbolization. Removing them cuts the offline
# precache by ~30 MB. REVISIT this list when switching renderer flags.
pruned = 0
for pattern in ['canvaskit/skwasm.js', 'canvaskit/skwasm.wasm',
                'canvaskit/skwasm_heavy.js', 'canvaskit/skwasm_heavy.wasm',
                'canvaskit/wimp.js', 'canvaskit/wimp.wasm']:
    p = root / pattern
    if p.exists():
        p.unlink(); pruned += 1
webparagraph = root / 'canvaskit/webparagraph'
if webparagraph.exists():
    shutil.rmtree(webparagraph)
for p in root.rglob('*.js.symbols'):
    p.unlink(); pruned += 1
# Explicit static allowlist. No auth/API requests, arbitrary URLs, or user data.
files = [bootstrap, root / 'main.dart.js']
for directory in ['assets', 'canvaskit', 'fonts']:
    files.extend(p for p in (root / directory).rglob('*') if p.is_file())
files = sorted(set(files))
digest = hashlib.sha256()
for p in files:
    digest.update(p.relative_to(root).as_posix().encode())
    digest.update(p.read_bytes())
# The version digest must cover every cached shell file: a change to e.g.
# alpha-client.mjs alone would otherwise ship offline without a cache bump.
for name in ['alpha.html', 'alpha.css', 'alpha-ui.mjs', 'alpha-client.mjs',
             'alpha-storage.mjs', 'device_crypto.mjs', 'protocol/device-v2.mjs',
             'alpha-manifest.json', 'alpha-sw.js']:
    digest.update((client / 'web' / name).read_bytes())
urls = ['/flutter-ui/' + p.relative_to(root).as_posix() for p in files]
(root / 'cache-files.js').write_text(
    'self.SHADE_UI_VERSION = ' + json.dumps(digest.hexdigest()[:20]) + ';\n' +
    'self.SHADE_UI_FILES = ' + json.dumps(urls) + ';\n', encoding='utf-8')
print(f'Alpha Flutter UI ready: {root} ({len(files)} static assets, {pruned} engine artifacts pruned)')

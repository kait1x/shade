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
# Explicit static allowlist. No auth/API requests, arbitrary URLs, or user data.
files = [bootstrap, root / 'main.dart.js']
for directory in ['assets', 'canvaskit', 'fonts']:
    files.extend(p for p in (root / directory).rglob('*') if p.is_file())
files = sorted(set(files))
digest = hashlib.sha256()
for p in files:
    digest.update(p.relative_to(root).as_posix().encode())
    digest.update(p.read_bytes())
for name in ['alpha-ui.mjs', 'alpha.css']:
    digest.update((client / 'web' / name).read_bytes())
urls = ['/flutter-ui/' + p.relative_to(root).as_posix() for p in files]
(root / 'cache-files.js').write_text(
    'self.SHADE_UI_VERSION = ' + json.dumps(digest.hexdigest()[:20]) + ';\n' +
    'self.SHADE_UI_FILES = ' + json.dumps(urls) + ';\n', encoding='utf-8')
print(f'Alpha Flutter UI ready: {root} ({len(files)} static assets)')

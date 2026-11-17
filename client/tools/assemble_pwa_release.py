"""Assemble a self-contained Shade PWA release directory.

The web-alpha runtime splits across two sources that the alpha server mounts
separately: the DOM shell in ``client/web`` (served at ``/``) and the Flutter
UI bundle in ``client/build/web-alpha`` (served at ``/flutter-ui/``). This tool
copies both into one deployable root ``client/build/pwa-release`` so a staging
server can point its web root at a single directory. The offline service
worker allowlist (alpha-sw.js) stays authoritative: it covers exactly these
shell files plus ``/socket.io/socket.io.js``, which the server must provide.

Run from the repository root AFTER ``python client/tools/build_web_alpha.py``.
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

client = Path(__file__).resolve().parents[1]
web = client / 'web'
flutter_ui = client / 'build/web-alpha'
root = client / 'build/pwa-release'

shell_files = ['alpha.html', 'alpha.css', 'alpha-ui.mjs', 'alpha-client.mjs',
               'alpha-storage.mjs', 'device_crypto.mjs',
               'protocol/device-v2.mjs', 'alpha-manifest.json', 'alpha-sw.js',
               'favicon.png']
bootstrap = flutter_ui / 'flutter_bootstrap.js'
if not bootstrap.is_file():
    raise SystemExit('Missing flutter_bootstrap.js: run "python client/tools/build_web_alpha.py" first')

if root.exists():
    shutil.rmtree(root)
root.mkdir()
for name in shell_files:
    source = web / name
    if not source.is_file():
        raise SystemExit(f'Missing shell file: client/web/{name}')
    (root / name).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, root / name)
shutil.copytree(web / 'icons', root / 'icons')
shutil.copytree(flutter_ui, root / 'flutter-ui')

# Report the artifacts a human (or CI) can verify exist before deployment.
files = sorted(p for p in root.rglob('*') if p.is_file())
digest = hashlib.sha256()
for p in files:
    digest.update(p.relative_to(root).as_posix().encode())
    digest.update(p.read_bytes())
critical = ['alpha.html', 'alpha-manifest.json', 'alpha-sw.js',
            'flutter-ui/flutter_bootstrap.js', 'flutter-ui/main.dart.js',
            'flutter-ui/cache-files.js', 'icons/Icon-192.png',
            'icons/Icon-512.png', 'icons/Icon-maskable-512.png',
            'icons/apple-touch-icon.png']
missing = [name for name in critical if not (root / name).is_file()]
if missing:
    raise SystemExit(f'Critical artifacts missing from release: {missing}')
report = {
    'root': str(root),
    'files': len(files),
    'totalMB': round(sum(p.stat().st_size for p in files) / 1048576, 1),
    'sha256': digest.hexdigest(),
    'critical': {name: (root / name).stat().st_size for name in critical},
}
(root / 'release-manifest.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
sys.exit(0)

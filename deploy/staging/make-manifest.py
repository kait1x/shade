"""Generate MANIFEST.sha256 + MANIFEST.meta for a staging upload package.

Usage: python deploy/staging/make-manifest.py <package-dir>
Covers every file under server/ and client/ (the release runtime). Root
templates/scripts are NOT part of the release dir and not covered.
Format: pure sha256sum lines ("<64hex>  <relpath>", forward slashes) so
`sha256sum -c MANIFEST.sha256` works from the release root on the VPS.
Metadata (commit/branch/...) lives in MANIFEST.meta, never in the checksum
file (convention of release 20261117-225500+, docs/PWA_INTEGRATION_REPORT.md).
"""
import hashlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

pkg = Path(sys.argv[1]).resolve()
if not (pkg / 'server').is_dir() or not (pkg / 'client').is_dir():
    raise SystemExit('package must contain server/ and client/')
repo = Path(__file__).resolve().parents[2]


def git(*args):
    return subprocess.run(['git', '-C', str(repo), *args],
                          capture_output=True, text=True, check=True).stdout.strip()


commit = git('rev-parse', 'HEAD')
branch = git('rev-parse', '--abbrev-ref', 'HEAD')
dirty = '\n'.join(l for l in git('status', '--porcelain').splitlines()
                  if 'client/windows/flutter/generated_' not in l)
# Generated plugin registrants are rewritten by any flutter build and are not
# part of the staging runtime; they must not block the manifest (rake 19.11).
if dirty:
    raise SystemExit('worktree dirty; commit release changes before packaging:\n' + dirty)

files = sorted(p for sub in ('server', 'client')
               for p in (pkg / sub).rglob('*') if p.is_file())
lines = []
for p in files:
    rel = p.relative_to(pkg).as_posix()
    digest = hashlib.sha256(p.read_bytes()).hexdigest()
    lines.append(f'{digest}  {rel}')
(pkg / 'MANIFEST.sha256').write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')

sw = (pkg / 'client/build/web-alpha/cache-files.js').read_text(encoding='utf-8')
sw_version = sw.split('"')[1]
meta = (f'commit: {commit}\n'
        f'branch: {branch}\n'
        f'generated: {datetime.now(timezone.utc).isoformat(timespec="seconds")}\n'
        f'sw_version: {sw_version}\n'
        f'files: {len(files)}\n')
(pkg / 'MANIFEST.meta').write_text(meta, encoding='utf-8', newline='\n')
print(f'MANIFEST: {len(files)} files, commit {commit[:12]}, sw {sw_version}')
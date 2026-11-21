#!/bin/bash
# Shade v2 STAGING live smoke wrapper (от shade-staging, без root).
# Usage: bash staging-live-smoke.sh <release-stamp>
set -euo pipefail
STAMP=${1:?usage: staging-live-smoke.sh <release-stamp>}
REL=/opt/shade-staging/releases/$STAMP
export PATH=/opt/node/bin:$PATH
DATA=/var/lib/shade-staging
cd "$REL/server"

echo "== stop alpha for synthetic prepare =="
kill "$(cat $DATA/alpha.pid)" 2>/dev/null || true
sleep 2
node staging-live-smoke.mjs prepare

echo "== restart alpha with synthetic bridge =="
set -a; . "$DATA/staging.env"; set +a
nohup node alpha.mjs > "$DATA/alpha.log" 2>&1 &
echo $! > "$DATA/alpha.pid"
sleep 2
curl -fsS -m 5 http://127.0.0.1:3101/api/health; echo

node staging-live-smoke.mjs enroll

echo "== packaged integration tests on VPS (synthetic, loopback) =="
node --test --test-concurrency=1 test/migration-dryrun.test.mjs test/rsa-rotation.test.mjs test/rollback-journal.test.mjs 2>&1 | tail -9
echo "LIVE_SMOKE_DONE"
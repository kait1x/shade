#!/bin/bash
# Staging backup/rollback drill — ТОЛЬКО /var/lib/shade-staging, синтетика.
# Доказывает операционную процедуру checkpoint -> replay-restore -> verify.
set -euo pipefail
export PATH=/opt/node/bin:$PATH
DATA=/var/lib/shade-staging
STAMP=$(ls -1 /opt/shade-staging/releases | sort | tail -1)
CLI=/opt/shade-staging/releases/$STAMP/server/tools/migrate-v1-to-v2.mjs
cd "/opt/shade-staging/releases/$STAMP/server"
set -a; . "$DATA/staging.env"; set +a
DRILL="$DATA/backups/drill-$(date +%Y%m%d-%H%M%S)"

echo "== 1. checkpoint (live store, read-only) =="
node "$CLI" checkpoint --target "$DATA/data" --out "$DRILL"

echo "== 2. checkpoint loads (status from backup) =="
node "$CLI" status --target "$DRILL" | head -20

echo "== 3. stop alpha =="
kill "$(cat $DATA/alpha.pid)" 2>/dev/null || true
sleep 2

echo "== 4. replay-restore (backup -> live, safety backup created) =="
node "$CLI" replay-restore --target "$DATA/data" --backup "$DRILL" --confirm

echo "== 5. verify against synthetic source =="
node "$CLI" verify --source "$DATA/v1-synthetic" --target "$DATA/data" | head -12

echo "== 6. restart alpha + health =="
nohup node alpha.mjs > "$DATA/alpha.log" 2>&1 &
echo $! > "$DATA/alpha.pid"
sleep 2
curl -fsS -m 5 http://127.0.0.1:3101/api/health; echo

echo "== 7. rollout monitor baseline (read-only) =="
if [ -f "$DATA/rollout-monitor.sh" ]; then
  CLI="$CLI" bash "$DATA/rollout-monitor.sh" "$DATA/data" "$DATA/v1-synthetic"
else
  echo "(monitor script not uploaded; skipping)"
fi
echo "DRILL_OK"
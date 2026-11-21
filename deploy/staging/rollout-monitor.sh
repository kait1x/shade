#!/bin/bash
# Read-only rollout monitor for the v1->v2 transition (run on the VPS).
# Prints a JSON snapshot + STOP/CONTINUE recommendation against the documented
# thresholds (docs/V2_FINAL_RELEASE.md §8). Changes nothing.
# Usage: rollout-monitor.sh [v2-data-dir] [v1-data-dir]
set -euo pipefail
V2DIR=${1:-/var/lib/shade-v2/data}
V1DIR=${2:-/var/lib/shade/data}
NODE=${NODE:-/opt/node/bin/node}
CLI=${CLI:-/opt/shade-v2/current/server/tools/migrate-v1-to-v2.mjs}

echo "== services =="
systemctl is-active shade caddy shade-v2 shade-alpha 2>/dev/null || true

echo "== health =="
for p in 3000 3101 3201; do
  printf 'port %s: ' "$p"
  curl -fsS -m 3 "http://127.0.0.1:$p/api/health" 2>/dev/null || echo 'no response'
  echo
done

echo "== migration status (counts only) =="
if [ -f "$CLI" ] && [ -n "${ALPHA_STORAGE_SECRET:-}" ]; then
  "$NODE" "$CLI" status --target "$V2DIR" 2>/dev/null | "$NODE" -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const j=JSON.parse(s);const a=Object.values(j.accounts||{});
      const sum={enrolled:0,prepared:0,failed:0,rotation_required:0,inboxPending:0};
      for(const x of a){sum[x.status]=(sum[x.status]||0)+1;sum.inboxPending+=x.inboxPending||0;}
      console.log(JSON.stringify(sum));
    });'
else
  echo 'CLI/secret unavailable; skipping'
fi

echo "== recent error rates (5 min) =="
for u in shade shade-v2; do
  printf '%s errors: ' "$u"
  journalctl -u "$u" --since '5 minutes ago' -p err --no-pager 2>/dev/null | wc -l
done
printf 'caddy TLS/ACME errors: '
journalctl -u caddy --since '15 minutes ago' --no-pager 2>/dev/null | grep -ciE 'error|obtain.*fail' || true

echo "== storage integrity =="
[ -d "$V1DIR" ] && ls "$V1DIR"/users.json >/dev/null 2>&1 && echo 'v1 users.json present'
[ -f "$V2DIR/device-v2.enc" ] && echo 'v2 snapshot present'

echo "== recommendation =="
echo 'STOP rollout if any of: E2EE errors; message loss; account identity'
echo 'violations; mass auth failures; storage corruption; unsafe restore;'
echo 'unexpected Socket.IO error growth. Quantitative baseline: inboxPending'
echo 'must not grow monotonically with active ACKs; bridge prune lag < 5s;'
echo 'verify ok; auth/send error rate < 1% after canary.'
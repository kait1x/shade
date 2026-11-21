#!/bin/bash
# Shade v2 STAGING server setup — выполняется от shade-staging (БЕЗ root).
# Только /opt/shade-staging + /var/lib/shade-staging. Production не затрагивается.
# Usage: bash staging-server-setup.sh <release-stamp>
set -euo pipefail
STAMP=${1:?usage: staging-server-setup.sh <release-stamp>}
REL=/opt/shade-staging/releases/$STAMP
export PATH=/opt/node/bin:$PATH
ENVF=/var/lib/shade-staging/staging.env
[ -d "$REL/server" ] || { echo "release missing: $REL" >&2; exit 1; }

echo "== npm ci =="
(cd "$REL/server" && npm ci --omit=dev --no-audit --no-fund --loglevel=error)

echo "== syntax checks =="
node --check "$REL/server/alpha.mjs"
node --check "$REL/server/server.js"
node --check "$REL/server/tools/migrate-v1-to-v2.mjs"

echo "== manifest integrity (commit-bound) =="
node -e '
  const fs=require("fs"),c=require("crypto"),path=require("path");
  const rel=process.argv[1];
  const lines=fs.readFileSync(path.join(rel,"MANIFEST.sha256"),"utf8").split(/\r?\n/);
  let ok=0,bad=0;
  for(const l of lines){
    const m=l.match(/^([0-9a-f]{64})  (.+)$/); if(!m) continue;
    const f=path.join(rel,m[2]);
    if(!fs.existsSync(f)){ console.log("MISSING",m[2]); bad++; continue; }
    const h=c.createHash("sha256").update(fs.readFileSync(f)).digest("hex");
    if(h===m[1]) ok++; else { console.log("MISMATCH",m[2]); bad++; }
  }
  console.log(`manifest: ${ok} ok, ${bad} bad`);
  if(bad) process.exit(1);
' "$REL"
grep '^commit:' "$REL/MANIFEST.sha256"

echo "== staging secrets (new, never production) =="
mkdir -p /var/lib/shade-staging/data /var/lib/shade-staging/checkpoints
if [ ! -f "$ENVF" ]; then
  node -e '
    const c=require("crypto"),fs=require("fs");
    const wp=require(process.argv[1]+"/server/node_modules/web-push");
    const v=wp.generateVAPIDKeys();
    const lines=["SHADE_ENV=alpha","ALPHA_PORT=3101",
      "ALPHA_PUBLIC_ORIGIN=http://127.0.0.1:3101",
      "ALPHA_DATA_DIR=/var/lib/shade-staging/data",
      "ALPHA_STORAGE_SECRET="+c.randomBytes(32).toString("hex"),
      "ALPHA_VAPID_PUBLIC_KEY="+v.publicKey,
      "ALPHA_VAPID_PRIVATE_KEY="+v.privateKey,
      "ALPHA_VAPID_SUBJECT=mailto:staging@shadechat.ru",
      "ALPHA_PUSH_ALLOWED_HOSTS=fcm.googleapis.com,updates.push.services.mozilla.com,push.services.mozilla.com,web.push.apple.com",
      "ALPHA_CHECKPOINT_DIR=/var/lib/shade-staging/checkpoints",
      "ALPHA_CHECKPOINT_KEEP=20"];
    fs.writeFileSync(process.argv[2],lines.join("\n")+"\n",{mode:0o600});
  ' "$REL" "$ENVF"
  chmod 600 "$ENVF"
  echo "staging.env created (0600, secrets not printed)"
else
  echo "staging.env exists — left untouched"
fi

echo "== start alpha on loopback :3101 (user process, NOT a system service) =="
pkill -f 'node alpha.mjs' 2>/dev/null || true
sleep 1
cd "$REL/server"
set -a; . "$ENVF"; set +a
nohup node alpha.mjs > /var/lib/shade-staging/alpha.log 2>&1 &
echo $! > /var/lib/shade-staging/alpha.pid
sleep 2
curl -fsS -m 5 http://127.0.0.1:3101/api/health
echo
echo "SETUP_OK (stop: kill \$(cat /var/lib/shade-staging/alpha.pid))"
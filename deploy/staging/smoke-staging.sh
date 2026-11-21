#!/bin/bash
# Shade v2 STAGING read-only smoke test. Запускается ПОСЛЕ развёртывания
# (с рабочей машины или с VPS). Ничего не изменяет: только GET/health/
# socket.io polling probe и проверка заголовков/сертификата.
# Usage: bash smoke-staging.sh [https://alpha.shadechat.ru]
set -euo pipefail
ORIGIN=${1:-https://alpha.shadechat.ru}
FAIL=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS: $1 ($3)"; else echo "FAIL: $1 (expected $2, got $3)"; FAIL=1; fi
}

echo "== health =="
HEALTH=$(curl -s --max-time 15 "$ORIGIN/api/health")
echo "$HEALTH"
echo "$HEALTH" | grep -q '"protocol":2' && echo "PASS: protocol 2" || { echo "FAIL: protocol"; FAIL=1; }
echo "$HEALTH" | grep -q '"isolated":true' && echo "PASS: isolated" || { echo "FAIL: isolated flag"; FAIL=1; }

echo "== security headers =="
HDRS=$(curl -sI --max-time 15 "$ORIGIN/")
echo "$HDRS" | grep -qi "content-security-policy: default-src 'self'" && echo "PASS: CSP" || { echo "FAIL: CSP"; FAIL=1; }
echo "$HDRS" | grep -qi 'x-content-type-options: nosniff' && echo "PASS: nosniff" || { echo "FAIL: nosniff"; FAIL=1; }
echo "$HDRS" | grep -qi 'referrer-policy: no-referrer' && echo "PASS: referrer" || { echo "FAIL: referrer"; FAIL=1; }

echo "== admin surfaces closed =="
for p in /admin /dashboard /api/stats; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$ORIGIN$p")
  check "admin $p" 404 "$CODE"
done

echo "== socket.io polling probe (read-only) =="
SIO=$(curl -s --max-time 15 "$ORIGIN/socket.io/?EIO=4&transport=polling")
case "$SIO" in
  *'"sid"'*) echo "PASS: socket.io handshake" ;;
  *) echo "FAIL: socket.io handshake: ${SIO:0:120}"; FAIL=1 ;;
esac

echo "== TLS certificate =="
CERT=$(curl -sv --max-time 15 "$ORIGIN/" -o /dev/null 2>&1 | grep -E 'subject:|issuer:|expire date:' || true)
echo "$CERT"
echo "$CERT" | grep -q 'subject:' && echo "PASS: TLS served" || { echo "FAIL: TLS"; FAIL=1; }

echo "== origin rejection (cross-origin API must be refused) =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H 'Origin: https://evil.example' "$ORIGIN/api/session")
check "cross-origin /api/session" 403 "$CODE"

echo "== production untouched (local checks, if run on VPS) =="
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active shade 2>/dev/null && echo "INFO: production shade active" || true
fi

[ "$FAIL" = 0 ] && echo "SMOKE_OK" || { echo "SMOKE_FAILED"; exit 1; }
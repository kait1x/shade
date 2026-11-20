#!/bin/bash
# Бэкап перехода v1→v2 (root на VPS). НЕ меняет сервисы/данные/симлинки.
# Использование: bash backup-transition.sh <stamp> [v2-data-dir]
#   stamp          — метка, напр. 20261121-120000
#   v2-data-dir    — каталог данных v2 (по умолчанию /var/lib/shade-staging)
# Секреты копируются в архив с правами 600 и НЕ выводятся в stdout/лог.
# Внешняя копия архива — обязательное действие владельца (вне VPS/Git/чата).
set -euo pipefail
STAMP=${1:?usage: backup-transition.sh <stamp> [v2-data-dir]}
V2DIR=${2:-/var/lib/shade-staging}
OUT=/var/backups/shade-transition/$STAMP
install -d -m 700 "$OUT"
tar -czf "$OUT/data-v1.tgz" -C /var/lib/shade data
tar -czf "$OUT/data-v2.tgz" -C "$V2DIR" .
# env-файлы содержат секреты: только права 600, без эха содержимого.
install -m 600 /etc/shade/shade.env "$OUT/shade.env"
if [ -f /var/lib/shade-staging/staging.env ]; then
  install -m 600 /var/lib/shade-staging/staging.env "$OUT/staging.env"
fi
install -m 644 /etc/caddy/Caddyfile "$OUT/Caddyfile"
systemctl cat shade --no-pager > "$OUT/shade.service.txt"
systemctl cat shade-staging --no-pager > "$OUT/shade-staging.service.txt"
if systemctl cat shade-v2 --no-pager > "$OUT/shade-v2.service.txt" 2>/dev/null; then :; else rm -f "$OUT/shade-v2.service.txt"; fi
readlink -f /opt/shade/current > "$OUT/current-v1.txt"
readlink -f /opt/shade-staging/current > "$OUT/current-staging.txt"
(cd "$OUT" && sha256sum ./* > SHA256SUMS)
chmod 600 "$OUT/SHA256SUMS"
echo "BACKUP_OK $OUT"
echo "NEXT: внешняя копия архива владельцем + sha256 -c SHA256SUMS на копии"
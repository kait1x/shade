#!/bin/bash
# Shade v2 STAGING setup — выполняет ВЛАДЕЛЕЦ как root на VPS.
# Идемпотентно. НЕ трогает production: /var/lib/shade, shade.service,
# /etc/shade, текущий Caddyfile. НЕ включает сервис и НЕ меняет Caddy —
# это отдельные шаги с отдельного разрешения.
#
# Usage: bash setup-staging.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root" >&2; exit 1; }

STAGING_USER=shade-staging
APP_DIR=/opt/shade-staging
DATA_DIR=/var/lib/shade-staging
ENV_DIR=/etc/shade-staging

echo "== user =="
if id "$STAGING_USER" >/dev/null 2>&1; then
  echo "user exists: $STAGING_USER"
else
  adduser --disabled-password --gecos "Shade v2 staging" "$STAGING_USER"
fi
# No sudo: verify group membership is exactly the private group.
GROUPS=$(groups "$STAGING_USER")
case "$GROUPS" in
  *sudo*|*adm*|*root*) echo "WARNING: $STAGING_USER has privileged groups: $GROUPS" >&2 ;;
  *) echo "groups ok: $GROUPS" ;;
esac

echo "== directories =="
install -d -m 755 -o "$STAGING_USER" -g "$STAGING_USER" "$APP_DIR"
install -d -m 755 -o "$STAGING_USER" -g "$STAGING_USER" "$APP_DIR/releases"
install -d -m 700 -o "$STAGING_USER" -g "$STAGING_USER" "$DATA_DIR"
install -d -m 700 -o "$STAGING_USER" -g "$STAGING_USER" "$DATA_DIR/data"
install -d -m 700 -o "$STAGING_USER" -g "$STAGING_USER" "$DATA_DIR/checkpoints"
install -d -m 750 -o root -g "$STAGING_USER" "$ENV_DIR"
install -d -m 755 -o root -g root /var/log/caddy

echo "== ssh key (если ещё не установлен) =="
install -d -m 700 -o "$STAGING_USER" -g "$STAGING_USER" "/home/$STAGING_USER/.ssh"
if [ ! -f "/home/$STAGING_USER/.ssh/authorized_keys" ]; then
  echo "Добавьте публичный ключ агента в /home/$STAGING_USER/.ssh/authorized_keys:"
  echo "  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUSx5vOO23iVHUpGv9vWR5NX5wcLqdojHZIkhAmdiRS shade-staging-agent"
  echo "  chown $STAGING_USER:$STAGING_USER; chmod 600"
fi

echo "== env template (не перезаписывает существующий) =="
if [ ! -f "$ENV_DIR/staging.env" ]; then
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  install -m 640 -o root -g "$STAGING_USER" "$SCRIPT_DIR/staging.env.example" "$ENV_DIR/staging.env"
  echo "Заполните $ENV_DIR/staging.env (новые секреты: openssl rand -hex 32;"
  echo "VAPID: npx web-push generate-vapid-keys; OAuth: отдельный Web-клиент)."
else
  echo "staging.env exists — left untouched"
fi

echo "== systemd unit (установка, БЕЗ включения) =="
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
install -m 644 "$SCRIPT_DIR/shade-staging.service.example" /etc/systemd/system/shade-staging.service
systemctl daemon-reload
echo "Unit installed. Start ONLY after env filled + code uploaded + owner approval:"
echo "  systemctl enable --now shade-staging"

echo "== production isolation check =="
[ -e /var/lib/shade/data ] && ls -ld /var/lib/shade/data
echo "shade-staging must NOT be able to read production data:"
su -s /bin/bash "$STAGING_USER" -c 'test -r /var/lib/shade/data/users.json && echo "WARNING: readable!" || echo "isolated: production data unreadable"'

echo "SETUP_DONE (сервис не запущен, Caddy не изменён)"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
DOMAIN=13-143-207-108.sslip.io
apt-get update -q
apt-get -y -q full-upgrade
apt-get -y -q install --no-install-recommends curl ca-certificates xz-utils ufw caddy unattended-upgrades tar
# Firewall: SSH stays allowed before enabling
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
# Node.js 22 LTS (official tarball, checksum verified)
if ! /opt/node/bin/node -v 2>/dev/null | grep -q '^v22'; then
  cd /tmp
  BASE=https://nodejs.org/dist/latest-v22.x
  F=$(curl -fsSL $BASE/SHASUMS256.txt | awk '/linux-x64.tar.xz$/{print $2}')
  curl -fsSLO $BASE/$F
  curl -fsSL $BASE/SHASUMS256.txt | grep " $F\$" | sha256sum -c -
  tar -xJf $F -C /opt
  ln -sfn /opt/${F%.tar.xz} /opt/node
  rm -f $F
fi
/opt/node/bin/node -v
# Service account and directories
id shade >/dev/null 2>&1 || useradd --system --home /var/lib/shade --shell /usr/sbin/nologin shade
install -d -o root -g root -m 755 /opt/shade
install -d -o shade -g shade -m 700 /var/lib/shade /var/lib/shade/data
install -d -o root -g shade -m 750 /etc/shade
install -d -o root -g root -m 700 /var/backups/shade
# journald limits
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\nMaxRetentionSec=30day\n' > /etc/systemd/journald.conf.d/shade.conf
systemctl restart systemd-journald
echo BOOTSTRAP_OK
getent hosts $DOMAIN || true

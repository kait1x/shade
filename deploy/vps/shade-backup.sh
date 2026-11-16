#!/bin/bash
# Daily snapshot. Retention/deletion requires a separately approved policy.
set -euo pipefail
D=/var/backups/shade
tar -czf $D/data-$(date +%Y%m%d-%H%M%S).tgz -C /var/lib/shade data
chmod 600 $D/*.tgz

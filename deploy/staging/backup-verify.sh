#!/bin/bash
# Verify a Shade backup WITHOUT touching live data: lists the archive,
# extracts it into a throwaway directory and checks the inventory.
# Usage: backup-verify.sh <backup.tgz> [work-dir]
set -euo pipefail
ARCHIVE=${1:?usage: backup-verify.sh <backup.tgz> [work-dir]}
WORK=${2:-$(mktemp -d /var/tmp/shade-verify.XXXXXX)}
[ -f "$ARCHIVE" ] || { echo "Archive not found: $ARCHIVE" >&2; exit 1; }
echo "== archive integrity =="
tar -tzf "$ARCHIVE" > "$WORK/inventory.txt"
echo "entries: $(wc -l < "$WORK/inventory.txt")"
head -20 "$WORK/inventory.txt"
echo "== extraction probe =="
mkdir -p "$WORK/extracted"
tar -xzf "$ARCHIVE" -C "$WORK/extracted"
for f in users.json session_secret server_master_key; do
  if [ -f "$WORK/extracted/data/$f" ]; then echo "present: $f"; else echo "MISSING: $f"; fi
done
du -sh "$WORK/extracted"
echo "VERIFY_OK $WORK"
echo "Restore drill (manual, owner-approved): copy extracted/data into an EMPTY"
echo "candidate DATA_DIR and start a loopback candidate server; never overwrite live data."
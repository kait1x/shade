#!/bin/bash
# Controlled v1 -> v2 migration run on the VPS (staging first, production only
# with explicit owner approval). Never modifies v1 data files: the v1 directory
# is opened read-only; all writes go to the separate v2 store.
#
# Usage:
#   migration-run.sh audit     <v1-data-dir>
#   migration-run.sh prepare   <v1-data-dir> <v2-data-dir> <accounts|ALL>
#   migration-run.sh verify    <v1-data-dir> <v2-data-dir>
#   migration-run.sh status    <v2-data-dir>
#   migration-run.sh guard     <v2-data-dir> <guard-file-out>
#   migration-run.sh stop      <v2-data-dir>
#   migration-run.sh resume    <v2-data-dir>
#   migration-run.sh rollback  <v2-data-dir> <accounts>
#
# Required environment:
#   ALPHA_STORAGE_SECRET   - v2 store secret (32+ chars, from /etc/shade-alpha/alpha.env)
#   NODE                   - node binary (default /opt/node/bin/node)
#   SERVER_DIR             - directory containing tools/migrate-v1-to-v2.mjs
# Production guard: MIGRATION_OWNER_APPROVAL=yes must be set explicitly for
# prepare/rollback/guard when the v1 dir is the live production directory.
set -euo pipefail
CMD=${1:?usage: migration-run.sh <command> ...}
NODE=${NODE:-/opt/node/bin/node}
SERVER_DIR=${SERVER_DIR:-/opt/shade-alpha/current/server}
CLI="$SERVER_DIR/tools/migrate-v1-to-v2.mjs"
[ -f "$CLI" ] || { echo "CLI not found: $CLI" >&2; exit 1; }
[ -n "${ALPHA_STORAGE_SECRET:-}" ] || { echo "Set ALPHA_STORAGE_SECRET" >&2; exit 1; }

is_live_production() { [ "$1" = /var/lib/shade/data ]; }
require_approval() {
  if is_live_production "$1" && [ "${MIGRATION_OWNER_APPROVAL:-}" != yes ]; then
    echo "Refusing: production directory requires MIGRATION_OWNER_APPROVAL=yes" >&2
    exit 1
  fi
}

case "$CMD" in
  audit)
    "$NODE" "$CLI" audit --source "$2" ;;
  prepare)
    require_approval "$2"
    # Verified backup of BOTH stores before any change (v1 backup is read-only
    # tar; it does not modify the source).
    STAMP=$(date +%Y%m%d-%H%M%S)
    install -d -m 700 /var/backups/shade
    tar -czf "/var/backups/shade/data-premigration-$STAMP.tgz" -C "$(dirname "$2")" "$(basename "$2")"
    if [ -d "$3" ] && [ -n "$(ls -A "$3" 2>/dev/null)" ]; then
      tar -czf "/var/backups/shade/alpha-premigration-$STAMP.tgz" -C "$(dirname "$3")" "$(basename "$3")"
    fi
    if [ "$4" = ALL ]; then
      "$NODE" "$CLI" prepare --source "$2" --target "$3" --all
    else
      "$NODE" "$CLI" prepare --source "$2" --target "$3" --accounts "$4"
    fi
    "$NODE" "$CLI" verify --source "$2" --target "$3" ;;
  verify)
    "$NODE" "$CLI" verify --source "$2" --target "$3" ;;
  status)
    "$NODE" "$CLI" status --target "$2" ;;
  guard)
    require_approval "$2"
    "$NODE" "$CLI" guard-export --target "$2" --out "$3" ;;
  stop)
    "$NODE" "$CLI" stop --target "$2" ;;
  resume)
    "$NODE" "$CLI" resume --target "$2" ;;
  rollback)
    require_approval "$2"
    "$NODE" "$CLI" rollback --target "$2" --accounts "$3" --confirm ;;
  checkpoint)
    "$NODE" "$CLI" checkpoint --target "$2" --out "$3" ;;
  replay-restore)
    require_approval "$2"
    systemctl is-active --quiet shade-alpha 2>/dev/null && {
      echo "Stop shade-alpha first: systemctl stop shade-alpha" >&2; exit 1; }
    "$NODE" "$CLI" replay-restore --target "$2" --backup "$3" --confirm ;;
  *)
    echo "Unknown command: $CMD" >&2; exit 1 ;;
esac
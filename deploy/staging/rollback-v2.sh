#!/bin/bash
# Shade v2 rollback helper. TWO distinct rollbacks — never confuse them:
#
# 1) guard-off: removes the v2 guard file so enrolled accounts can use v1 again.
#    Safe ONLY while no v2-only messages were exchanged (see docs/V2_ROLLBACK.md).
#    v1 data was never modified by the migration, so it is intact.
#
# 2) replay-restore (PREFERRED for enrolled accounts): restores an older backup
#    while replaying the newer live state — post-backup messages/ACKs/retracts/
#    device revisions survive (docs/V2_ROLLBACK.md §2). Run via the CLI with
#    shade-alpha stopped:
#      node tools/migrate-v1-to-v2.mjs replay-restore --target <v2-dir> \
#        --backup <older device-v2.enc> --confirm
#    (or: migration-run.sh replay-restore <v2-dir> <backup>)
#
# 3) snapshot-restore: restores a pre-migration v2 snapshot backup into the
#    alpha store WITHOUT replay. Requires shade-alpha stopped. Messages queued
#    in v2 after the backup point are LOST from the relay (clients keep their
#    local copies); use only when the live snapshot is unreadable and replay
#    is impossible. This is why rollback of enrolled accounts is refused by
#    the CLI and must be a deliberate, owner-approved restore.
#
# Usage:
#   rollback-v2.sh guard-off <guard-file>
#   rollback-v2.sh snapshot-restore <backup-device-v2.enc> <v2-data-dir>
# Nothing here ever writes into /var/lib/shade/data.
set -euo pipefail
CMD=${1:?usage: rollback-v2.sh <guard-off|snapshot-restore> ...}
case "$CMD" in
  guard-off)
    GUARD=${2:?guard file path required}
    if [ -f "$GUARD" ]; then
      mv "$GUARD" "$GUARD.disabled-$(date +%Y%m%d-%H%M%S)"
      echo "Guard disabled; v1 server picks this up within ~1s."
    else
      echo "No guard file present; nothing to do."
    fi
    ;;
  snapshot-restore)
    BACKUP=${2:?backup device-v2.enc path required}
    TARGET=${3:?v2 data dir required}
    [ -f "$BACKUP" ] || { echo "Backup not found" >&2; exit 1; }
    case "$TARGET" in
      /var/lib/shade/data*) echo "Refusing: target is the v1 production store" >&2; exit 1 ;;
    esac
    systemctl is-active --quiet shade-alpha && {
      echo "Stop shade-alpha first: systemctl stop shade-alpha" >&2; exit 1; }
    STAMP=$(date +%Y%m%d-%H%M%S)
    if [ -f "$TARGET/device-v2.enc" ]; then
      cp -a "$TARGET/device-v2.enc" "$TARGET/device-v2.enc.pre-restore-$STAMP"
    fi
    install -m 600 "$BACKUP" "$TARGET/device-v2.enc"
    echo "Restored. Start shade-alpha and run: migration-run.sh verify <v1-dir> $TARGET"
    ;;
  *)
    echo "Unknown command: $CMD" >&2; exit 1 ;;
esac
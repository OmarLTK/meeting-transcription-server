#!/bin/bash
# Cold backup of Speakr: DB + config (+ audio by default).
#
# Speakr is stopped for the duration. Copying a live SQLite file can produce a
# corrupt backup, and host-side sqlite3 locking across the Colima VM mount is
# not something to trust. Expect ~1 minute of downtime plus tar time.
# Schedule outside meeting hours (e.g. 03:00, after the 02:00 retention sweep).
#
# The archive contains .env (API keys) and meeting content: it is sensitive.
set -euo pipefail

SPEAKR_DIR="${SPEAKR_DIR:-$HOME/speakr}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/speakr-backups}"
KEEP="${KEEP:-7}"                    # number of archives to retain
INCLUDE_AUDIO="${INCLUDE_AUDIO:-1}"  # 0 = DB + config only (small)

cd "$SPEAKR_DIR"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

stamp="$(date +%Y%m%d-%H%M%S)"
out="$BACKUP_DIR/speakr-$stamp.tar.gz"

echo "Stopping Speakr..."
docker compose down
# Bring it back up whether tar succeeds or fails.
trap 'echo "Starting Speakr..."; docker compose up -d' EXIT

items=(instance .env)
if [ "$INCLUDE_AUDIO" = "1" ]; then items+=(uploads); fi

tar czf "$out" "${items[@]}"
chmod 600 "$out"
echo "Wrote $out ($(du -h "$out" | cut -f1))"

# Prune old archives (portable: no GNU-only xargs flags).
ls -1t "$BACKUP_DIR"/speakr-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" |
  while IFS= read -r old; do rm -f -- "$old"; echo "Pruned $old"; done

echo "Reminder: a backup on the same disk is not a backup. Copy it off this machine."

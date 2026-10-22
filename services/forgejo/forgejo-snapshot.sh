#!/usr/bin/env bash
# Hourly crash-consistent snapshot of .20's Forgejo local named volume into the
# backed-up NFS store (config/backups/off-nfs/forgejo/), which Backrest/restic -> B2
# sweeps nightly at 03:00.
#
# Mirrors /home/agent/bin/off-nfs-snapshot.sh on .6 — same pattern, but for .20's volume
# (a snapshot script must run on the host that owns the volume; .6's cannot see .20's).
#
# Forgejo's state moved off the NFS mount to a local named volume 2026-10-22: nick/infra #29.
# The NFS original at services/forgejo/forgejo is deliberately left in place as a second copy.
set -uo pipefail
VOL=/var/lib/docker/volumes/forgejo_forgejo-data/_data
DEST=/mnt/nas-2-fast-data/config/backups/off-nfs/forgejo
PY=/home/agent/bin/sqlite-dump.py
LOG=/home/agent/logs/forgejo-snapshot.log
KEEP_DUMPS=2

mkdir -p /home/agent/logs
echo "=== forgejo snapshot $(date -Is) ===" >> "$LOG"

# 1. raw tree. dumps/ is excluded here and handled separately in step 3 so the zips
#    (260M each) don't accumulate inside the snapshot tree.
sudo mkdir -p "$DEST/data"
sudo rsync -a --delete --exclude 'gitea/dumps/' "$VOL"/ "$DEST/data"/ 2>>"$LOG"

# 2. crash-consistent DB, via sqlite's online backup API (WAL-safe) over the copied file.
sudo python3 "$PY" "$VOL/gitea/gitea.db" "$DEST/data/gitea/gitea.db" >> "$LOG" 2>&1

# 3. the newest forgejo dump zips — the authoritative logical artifact for a restore.
# NOTE: the test MUST run under sudo. /var/lib/docker/volumes is 0700 root, so as `agent`
# the -d test silently returns false (no error) and the dumps never get copied.
if sudo test -d "$VOL/gitea/dumps"; then
  sudo mkdir -p "$DEST/dumps"
  sudo rsync -a --ignore-existing "$VOL/gitea/dumps/" "$DEST/dumps/" 2>>"$LOG"
  sudo sh -c "ls -1t $DEST/dumps/*.zip 2>/dev/null | tail -n +$((KEEP_DUMPS+1)) | xargs -r rm -f"
fi

sudo sh -c "date -Is > $DEST/.last-run" 2>/dev/null
echo "done $(date -Is)" >> "$LOG"

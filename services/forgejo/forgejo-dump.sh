#!/usr/bin/env bash
# Daily logical backup of Forgejo: DB + repositories + config in one zip (forgejo dump).
#
# The zip is MOVED OUT of the container's data dir as soon as it is written, for two reasons:
#  1. `forgejo dump` packs the whole data dir, so a leftover dump inside it gets included in
#     the next one. Observed on the first two runs: 269M zip, then a 537M zip that was just
#     the new data plus the previous dump. Left alone this compounds daily.
#  2. The destination is the restic-covered NFS tree, so the artifact is swept to B2 by the
#     03:00 Backrest run without depending on forgejo-snapshot.sh.
#
# The hourly forgejo-snapshot.sh still copies any zip it finds as a safety net.
# Context: nick/infra #29 (state moved off NFS to a local volume, 2026-10-22).
set -uo pipefail
VOL=/var/lib/docker/volumes/forgejo_forgejo-data/_data
DEST=/mnt/nas-2-fast-data/config/backups/off-nfs/forgejo/dumps
LOG=/home/agent/logs/forgejo-dump.log
KEEP=3
STAMP=$(date +%Y%m%d-%H%M)

mkdir -p /home/agent/logs
echo "=== forgejo dump $(date -Is) ===" >> "$LOG"

# a. nothing may sit in the data dir when the dump runs, or it lands inside the dump
sudo mkdir -p "$DEST"
sudo sh -c "ls -1 $VOL/gitea/dumps/*.zip >/dev/null 2>&1 && mv -f $VOL/gitea/dumps/*.zip $DEST/ 2>>$LOG"

# b. take the dump
docker exec -u git forgejo mkdir -p /data/gitea/dumps >> "$LOG" 2>&1
docker exec -u git forgejo forgejo dump -c /data/gitea/conf/app.ini \
  -f "/data/gitea/dumps/forgejo-$STAMP.zip" >> "$LOG" 2>&1
rc=$?
echo "dump rc=$rc file=forgejo-$STAMP.zip" >> "$LOG"

# c. move the new dump out of the data dir into the covered tree
sudo sh -c "mv -f $VOL/gitea/dumps/forgejo-$STAMP.zip $DEST/ 2>>$LOG" \
  && sudo chown root:root "$DEST/forgejo-$STAMP.zip" 2>>"$LOG"

# d. retention: keep the newest $KEEP
sudo sh -c "ls -1t $DEST/*.zip 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f"

count=$(sudo sh -c "ls -1 $DEST/*.zip 2>/dev/null | wc -l")
echo "done $(date -Is) dumps_kept=$count" >> "$LOG"

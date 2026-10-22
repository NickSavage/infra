#!/usr/bin/env bash
# deploy-telegraf.sh <node> [--local] [--build]
#
# Copies one node's Telegraf stack from this repo directory to that host's LOCAL
# disk (/config/telegraf) and (re)starts it.
#
#   node ∈ eos | nas-1 | nas-2 | server-1 | server-3
#
# Default runs over ssh as agent@<host> (NOPASSWD sudo on the four servers).
#   --local   run ON the target host itself (required for eos: no agent@eos, and
#             nick has no NOPASSWD sudo there — run it by hand on the desktop)
#   --build   rebuild the image (only needed after a Dockerfile change)
#
# Runtime lives on local disk on purpose: these agents report host/NFS health, so
# they must not need the shared /mnt/nas-2-fast-data mount to be up in order to start.
# See README.md in this directory for the full picture.
set -euo pipefail

NODE=""; LOCAL=0; BUILD=0
for a in "$@"; do
  case "$a" in
    --local) LOCAL=1 ;;
    --build) BUILD=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) NODE="$a" ;;
  esac
done
[ -n "$NODE" ] || { echo "usage: deploy-telegraf.sh <node> [--local] [--build]" >&2; exit 2; }

SRC=$(cd "$(dirname "$0")" && pwd)
DEST=/config/telegraf

case "$NODE" in
  eos)      HOST=192.168.0.168;  SSH=0 ;;   # no agent@eos — local only
  nas-1)    HOST=192.168.0.6;    SSH=1 ;;
  nas-2)    HOST=192.168.0.160;  SSH=1 ;;
  server-1) HOST=192.168.0.93;   SSH=1 ;;
  server-3) HOST=192.168.0.20;   SSH=1 ;;
  *) echo "unknown node: $NODE (want eos|nas-1|nas-2|server-1|server-3)" >&2; exit 2 ;;
esac

[ -f "$SRC/conf/$NODE.conf" ] || { echo "missing $SRC/conf/$NODE.conf" >&2; exit 1; }
# Token: from the environment (lets another account run this — e.g. agent, which has
# the ssh keys but cannot read nick-owned .env), else from the gitignored .env here.
TOKEN="${INFLUXDB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  [ -f "$SRC/.env" ] || { echo "no $SRC/.env and INFLUXDB_TOKEN not set in the environment" >&2; exit 1; }
  TOKEN=$(sed -n 's/^INFLUXDB_TOKEN=["]*\([^"]*\)["]*$/\1/p' "$SRC/.env")
fi
[ -n "$TOKEN" ] || { echo "INFLUXDB_TOKEN is empty (checked environment and $SRC/.env)" >&2; exit 1; }

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
install -m 644 "$SRC/Dockerfile"          "$STAGE/Dockerfile"
install -m 644 "$SRC/docker-compose.yml"  "$STAGE/docker-compose.yml"
install -m 644 "$SRC/conf/$NODE.conf"     "$STAGE/telegraf.conf"
install -m 600 /dev/null                  "$STAGE/.env"
printf 'MONITOR_NODE_NAME="%s"\n\nINFLUXDB_TOKEN="%s"\n' "$NODE" "$TOKEN" > "$STAGE/.env"
if [ -f "$SRC/override/$NODE.docker-compose.yml" ]; then
  install -m 644 "$SRC/override/$NODE.docker-compose.yml" "$STAGE/docker-compose.override.yml"
fi

COMPOSE_ARGS="up -d"; [ "$BUILD" -eq 1 ] && COMPOSE_ARGS="up -d --build"

echo "== $NODE ($HOST) ← $SRC"
if [ "$LOCAL" -eq 1 ]; then
  SUDO=""
  [ "$(id -u)" -eq 0 ] || SUDO="sudo"
  $SUDO mkdir -p "$DEST"
  $SUDO install -o root -g root -m 644 "$STAGE/Dockerfile"         "$DEST/Dockerfile"
  $SUDO install -o root -g root -m 644 "$STAGE/docker-compose.yml" "$DEST/docker-compose.yml"
  $SUDO install -o root -g root -m 644 "$STAGE/telegraf.conf"      "$DEST/telegraf.conf"
  $SUDO install -o root -g root -m 600 "$STAGE/.env"               "$DEST/.env"
  $SUDO rm -f "$DEST/docker-compose.override.yml"
  if [ -f "$STAGE/docker-compose.override.yml" ]; then
    $SUDO install -o root -g root -m 644 "$STAGE/docker-compose.override.yml" "$DEST/docker-compose.override.yml"
  fi
  ( cd "$DEST" && $SUDO docker compose $COMPOSE_ARGS )
  $SUDO docker ps --filter name=telegraf --format '   {{.Names}}  {{.Status}}'
else
  [ "$SSH" -eq 1 ] || { echo "node $NODE has no ssh path — re-run with --local on that host" >&2; exit 1; }
  tar czf - -C "$STAGE" . | ssh "agent@$HOST" 'rm -rf /tmp/tg-deploy && mkdir -p /tmp/tg-deploy && tar xzf - -C /tmp/tg-deploy'
  ssh "agent@$HOST" "
    set -e
    sudo mkdir -p $DEST
    sudo install -o root -g root -m 644 /tmp/tg-deploy/Dockerfile         $DEST/Dockerfile
    sudo install -o root -g root -m 644 /tmp/tg-deploy/docker-compose.yml $DEST/docker-compose.yml
    sudo install -o root -g root -m 644 /tmp/tg-deploy/telegraf.conf      $DEST/telegraf.conf
    sudo install -o root -g root -m 600 /tmp/tg-deploy/.env               $DEST/.env
    sudo rm -f $DEST/docker-compose.override.yml
    if [ -f /tmp/tg-deploy/docker-compose.override.yml ]; then
      sudo install -o root -g root -m 644 /tmp/tg-deploy/docker-compose.override.yml $DEST/docker-compose.override.yml
    fi
    rm -rf /tmp/tg-deploy
    cd $DEST && sudo docker compose $COMPOSE_ARGS
    sudo docker ps --filter name=telegraf --format '   {{.Names}}  {{.Status}}'
  "
fi
echo "== done. Verify fresh samples: see VERIFY section of $SRC/README.md"

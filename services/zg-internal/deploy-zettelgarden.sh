#!/usr/bin/env bash
#
# deploy.sh — Deploy Zettelgarden internal stack (zg-internal) on .20
# ---------------------------------------------------------------------------
# Single-command flow (matches the manual deploy steps, 2026-08-30):
#   1. pull latest source in the build checkout
#   2. build the two nsavage/zettelgarden_{frontend,go_backend}:latest images
#   3. docker compose up -d the zg-internal stack
#   4. verify: containers up, fresh image ages, frontend + API reachable
#
# Run as root or nick (docker + git access):
#     sudo ./deploy-zettelgarden.sh
# or, from an automation account with NOPASSWD sudo:
#     sudo /home/nick/deploy-zettelgarden.sh
#
set -euo pipefail

# ---- Config ----------------------------------------------------------------
SRC_DIR="/home/nick/code/Zettelgarden"   # build checkout (git)
STACK_DIR="/mnt/nas-2-fast-data/config/services/zg-internal"  # deploy compose
BACKEND_PORT=8085
FRONTEND_PORT=3003

# ---- Helpers ---------------------------------------------------------------
pass()  { printf '\033[0;32m✔ %s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m! %s\033[0m\n' "$*"; }
fail()  { printf '\033[0;31m✘ %s\033[0m\n' "$*"; exit 1; }

command -v docker >/dev/null || fail "docker not found (are you root, or in the docker group?)"
[ -d "$SRC_DIR/.git" ]   || fail "build checkout missing: $SRC_DIR"
[ -f "$SRC_DIR/.env" ]   || fail "missing $SRC_DIR/.env (build needs VITE_* args)"
[ -f "$STACK_DIR/docker-compose.yml" ] || fail "stack compose missing: $STACK_DIR"

# ---- 1. Pull latest source --------------------------------------------------
echo "==> [1/4] Pulling latest source"
git -C "$SRC_DIR" pull --rebase
pass "source at $(git -C "$SRC_DIR" log --oneline -1 | sed 's/^\([0-9a-f]\{7\}\).*/\1/')"

# ---- 2. Build images ---------------------------------------------------------
echo "==> [2/4] Building images (frontend + go_backend)"
docker compose -f "$SRC_DIR/docker-compose.yml" build

# ---- 3. Deploy stack ---------------------------------------------------------
echo "==> [3/4] Deploying zg-internal stack"
docker compose -f "$STACK_DIR/docker-compose.yml" up -d

# ---- 4. Verify -----------------------------------------------------------------
echo "==> [4/4] Verifying"
sleep 3
for c in zettel-backend zg-frontend-internal; do
  st=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  [ "$st" = "running" ] || fail "$c is not running (status: $st)"
done
pass "containers running"

docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}' \
  | grep -E 'nsavage/zettelgarden_(frontend|go_backend):latest' || true

front=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$FRONTEND_PORT/" || true)
[ "$front" = "200" ] && pass "frontend :$FRONTEND_PORT -> 200" \
                    || warn "frontend :$FRONTEND_PORT -> ${front:-no response}"

# Backend route check: 405/4xx on /api/cards proves the router is alive.
back=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$BACKEND_PORT/api/cards" || true)
[ "$back" = "405" ] && pass "api :$BACKEND_PORT routing alive (405 on /api/cards GET)" \
                    || warn "api :$BACKEND_PORT -> ${back:-no response} (expected 405/401)"

echo
pass "Deploy complete. Live frontend bundle check:"
docker exec zg-frontend-internal sh -c \
  'grep -rl "Card already exists\|already_exists" /usr/src/app/zettelkasten-front/dist/assets 2>/dev/null \
   | sed "s/^/    new code in: /"' || warn "could not confirm new frontend bundle string"
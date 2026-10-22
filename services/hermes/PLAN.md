# Hermes: migrate off eos onto nas-1 (.6), with failure-mode hardening

> **Status:** plan / not executed. Owner: Nick. Author: Hermes (2026-10-22).
> **For Hermes:** implement task-by-task; do not skip the verification steps — they are the point.

**Goal:** Hermes runs continuously on `nas-1` (192.168.0.6) instead of on `eos` (Nick's desktop), and keeps
working — degraded rather than dead — when the container crashes, the host reboots, `state.db` corrupts,
a platform API is down, or the host itself is lost.

**Architecture:** official `nousresearch/hermes-agent` image run as a Docker container on `nas-1`, mode
`gateway run`, data on **local ext4** (`/srv/hermes`), secrets and keys bind-mounted, cabinet/files bind-mounted
from the existing Syncthing replicas. `nas-1` is treated as a **gateway + light-task** host: CPU-heavy work
(STT, browser, OCR/PDF, video) is offloaded to `server-1` (.93) / `server-3` (.20), which are more capable.
Backups stay **pull-based from .93**, so a dead `nas-1` still raises the alarm. Cold standby runbook lives on .93.

**Tech stack:** Docker + Compose v2, Debian 12, Syncthing, Forgejo (this repo), Backrest→B2, uptime-kuma,
telegraf, Telegram bot API (direct curl for alerts, independent of the gateway).

---

## 1. Verified current state (2026-10-22)

| Thing | Value |
|---|---|
| Host | `eos` = Nick's desktop, 192.168.0.168 (**DHCP**), tailscale 100.99.102.9, 24c / 125 GB, up 75 days |
| Install | git install at `~/.hermes/hermes-agent`, **v0.21.0 (2026.8.31)**, Python 3.11.16 |
| Service | `systemd --user hermes-gateway`, enabled, linger on |
| Memory | cgroup 12.9 GB current / 14.9 GB peak — of which **anon 0.51 GB**, `inactive_file` 11.95 GB (reclaimable page cache) |
| Data | `~/.hermes` 8.9 GB total; `state.db` **403 MB**; junk: 3.2 GB snapshots, 699 MB staging, 588 MB `recovered.sql`, 728 MB `state.db.broken`/`.original` |
| Cron | 11 jobs (5 agent prompts, 6 script/no-agent) |
| Backup | `~/.hermes/scripts/hermes-backup.sh` daily 02:15 → WAL-safe snapshot → rsync to `agent@192.168.0.93:/mnt/nas-2-fast-data/config/backups/hermes-eos/daily/<date>/`; weekly full zip (732 MB, 2026-10-19). Backrest carries that dir to B2. |
| Platforms | telegram, homeassistant, webhook (port 8644) |
| MCP | `trek` via `~/.hermes/scripts/trek-mcp-proxy.py` (needs the venv python + approvals) |
| eos stability | 11 unclean "crash" reboots logged, five of them Jun–Aug 2026 |

**Target host `nas-1` = 192.168.0.6**, Beelink MINI S, Intel **N100 (4 cores)**, **15 GB RAM** (2.5 GB used,
969 MB true-free, 595 MB swap in use), Debian 12, kernel 6.1, up 52 days — previous run **231 days**.
Runs: NPM (public 80/443/81), oauth2-proxy, pocket-id, mosquitto, dockhand, telegraf, **Syncthing**.
Has docker 28.5.1 + compose v2.40.3, tailscale, git, python3; `nick` = uid/gid **1000**; `agent` account with
NOPASSWD sudo; docker enabled at boot; `/` 467 GB with **328 GB free**. Port **8644 free**. No node/ffmpeg/chromium
on the host (the image ships node + ffmpeg, **not chromium**).

**Data already in place on `nas-1`:** Syncthing folder `Electronic Filing Cabinet`
(`/srv/data1/config/syncthing/Electronic Filing Cabinet`, **11 GB, sendreceive, fsWatcher on**) and
`files` — i.e. the cabinet is already replicated on `nas-1`, and the NAS copy at
`/mnt/nas-data-4/files/Electronic Filing Cabinet` is a peer, not a divergent copy. **No split-brain risk.**

**Image note:** only `nousresearch/hermes-agent:latest` is pulled locally
(`sha256:d4da4a40cd7a28aba983775d9fd31d94cbf153eeb0cb9e844d6d0f612b7c24db`, = **v0.21.5**, 2026-09-24).
The migration therefore *also* moves 0.21.0 → 0.21.5. Treated as an accepted, separately-verified risk (§7).

---

## 2. Target state

```
nas-1 (192.168.0.6)
├── docker: hermes (gateway run)          ← Telegram / HA / webhook / cron
│     ├── /opt/data            -> /srv/hermes/data        (state.db, .env, cron, plugins, skills)
│     ├── /root/.ssh           -> /srv/hermes/ssh:ro      (fleet keys: agent@server-1, agent@server-3)
│     ├── /nas/electronic-filing-cabinet -> syncthing replica  (rw)
│     └── /nas/files           -> syncthing replica       (rw)
├── systemd timer: hermes-snapshot        (WAL-safe snapshot inside container)
└── systemd timer: hermes-liveness        (uptime-kuma push heartbeat)

server-1 (.93) — backup + watchdog + cold standby
├── systemd timer: hermes-pull-snapshot   (rsync-pull from nas-1, verify, prune, alert)
├── Backrest plan nas-2-fast-data-config  (already carries the dir to B2)
└── runbook: bring Hermes up here if nas-1 dies

eos — gateway disabled, install kept ~2 weeks as rollback, then data pruned
```

### Decisions, and the alternatives rejected

1. **Local disk, not NFS, for `/srv/hermes/data`.** `state.db` is a 400 MB SQLite DB with heavy WAL traffic;
   SQLite locking over NFS is a known corruption path. (`hermes-wife` keeps its data on the NAS — fine for its
   size, not a precedent to copy.) Snapshots are still pushed to the NAS for offsite.
2. **Pull-based backup/monitoring from .93, not push from the subject.** Today the backup script lives *on* the
   box it protects. If `nas-1` dies, a pull-based job on .93 still alerts ("no fresh snapshot in >26 h").
3. **No `docker.sock` in the container.** Mounting it is root-equivalent host access and would undo the
   least-privilege win of moving off `nick@eos`. Jobs needing docker go to .93 or a host timer instead.
4. **Derived image for Python extras.** Anything `pip install`ed at runtime (e.g. `caldav` for the CalDAV
   calendar pull, `rapidocr` if OCR stays local) dies on recreate → build `services/hermes/Dockerfile` FROM the
   pinned digest.
5. **Data directory outside the repo.** Unlike `services/hermes-wife/data`, `/srv/hermes` is not inside
   `/mnt/nas-2-fast-data/config` — no giant DB in the git working tree, no accidental `git add`.
6. **Cap the container** (`memory: 3G`, `cpus: "2.0"`) so the agent can never starve the public ingress on the
   same 4-core box. Measured anon footprint is ~0.5 GB, so 3 GB is generous headroom, not a squeeze.

---

## 3. Failure modes and the answer to each (this is the "works when things go wrong" half)

| Failure | Detection | Behaviour / recovery |
|---|---|---|
| Container crash / OOM | docker healthcheck + `restart: unless-stopped` | auto-restart in seconds. Liveness timer alerts if container is down >2 min. |
| Crash loop | liveness timer counts restarts in a 10-min window | alert to Telegram (direct curl, no gateway needed) with `docker logs --tail 50`. |
| Host reboot (kernel upgrade) | — | `docker.service` enabled at boot + `restart: unless-stopped` → Hermes is back unattended. **Verify once after a real reboot (§6, task 6.4).** |
| `state.db` corruption | snapshot verify fails (`PRAGMA quick_check` ≠ ok, or size < 10 MB) | .93 alerts; restore a verified snapshot with the container **stopped** and WAL sidecars cleared; see the existing `hermes-state-backup-recovery` skill (same procedure, new paths). |
| Host `nas-1` lost (disk/PSU) | .93 pull job sees no fresh snapshot; uptime-kuma down alert | cold standby on .93: latest snapshot is already on the NAS → `docker compose up` + restore + repoint the Telegram poller (§8). |
| Telegram / model API outage | — | nothing to do; gateway retries. Do **not** wire restart-on-failure to API errors — it just hides outages. |
| Ingress/NPM problem on `nas-1` | — | outbound Telegram long-poll is unaffected; only the **webhook** platform depends on NPM. Documented, not mitigated. |
| Cron script fails | existing contract: silence on success, compact alert on failure | preserved; scripts are re-homed per §5. |
| Disk growth (logs, sessions, snapshots) | weekly digest | docker `json-file` capped at 20 MB × 5; snapshot retention 7 local / 14 on NAS / 4 weekly. |
| Secret loss | — | `.env` + `auth.json` are inside `/srv/hermes/data` → captured by every snapshot and the weekly zip. Required key list recorded in §5. |
| Silent-death window (agent up, bot not answering) | uptime-kuma push heartbeat from the liveness timer **plus** a weekly "post a message and read it back" self-test | the self-test is the only thing that proves the whole path (model + Telegram + tools) works end to end. |

---

## 4. Phases and tasks

Each task is one action with a verification. Do not batch them; the verifications are the deliverable.

### Phase 0 — pre-flight on nas-1 (read-only, no state change)

**0.1 Confirm host facts**
```bash
ssh nick@192.168.0.6 'id nick; docker compose version; systemctl is-enabled docker; df -h /srv; ss -lntp | grep :8644 || echo 8644-free'
```
Expected: uid=1000, compose ≥ v2.40, `enabled`, ≥100 GB free, `8644-free`.

**0.2 Confirm the cabinet replica is current**
```bash
ssh nick@192.168.0.6 'sudo du -sh "/srv/data1/config/syncthing/Electronic Filing Cabinet"; sudo ls "/srv/data1/config/syncthing/Electronic Filing Cabinet" | head'
```
Expected: ~11 GB. Compare the newest top-level mtime against eos's copy; if eos is ahead, wait for a Syncthing scan
(`rescanIntervalS=3600`, fsWatcher already on).

**0.3 Confirm the image pulls through the local registry cache (or Docker Hub)**
```bash
ssh nick@192.168.0.6 'docker pull nousresearch/hermes-agent@sha256:d4da4a40cd7a28aba983775d9fd31d94cbf153eeb0cb9e844d6d0f612b7c24db'
```
Expected: digest matches, ~4 GB.

**0.4 Inventory what the container will actually need (decides the extra-image work)**
```bash
ssh nick@192.168.0.6 'docker run --rm nousresearch/hermes-agent:latest sh -c "for c in node ffmpeg chromium ssh rsync sqlite3 curl python3; do printf \"%s: %s\n\" \$c \$(command -v \$c || echo MISSING); done; python3 -c \"import caldav\" 2>&1 | tail -1; echo HERMES_HOME=\$HERMES_HOME; ls /opt/data 2>/dev/null | head -3"'
```
Expected: node/ffmpeg/ssh/curl/python3 present; **chromium MISSING**, `caldav` import error, `HERMES_HOME=/opt/data`.
Record the result — it drives task 1.3.

**0.5 Snapshot the live instance before touching anything** (on eos)
```bash
hermes backup --quick -l pre-migration     # writes ~/.hermes/state-snapshots/<id>/
ls -1dt ~/.hermes/state-snapshots/*/ | head -1
```
Expected: new snapshot dir; `sqlite3 <dir>/state.db 'PRAGMA quick_check;'` → `ok`.

### Phase 1 — service definition in this repo

**1.1 Create the tree**
```
services/hermes/
├── README.md              # runbook: cutover, rollback, cold standby, CLI access
├── PLAN.md                # this document
├── Dockerfile             # derived image (python extras)
├── docker-compose.yml
├── .env.example           # HERMES_UID / HERMES_GID / IMAGE
├── .gitignore             # .env, data/
├── snapshot.sh            # runs against the container; nas-1 systemd timer
├── liveness.sh            # uptime-kuma heartbeat + restart-loop alarm; nas-1 timer
└── pull-snapshot.sh       # runs on .93; pull + verify + prune + alert
```
Verification: `git status` shows only these paths; no `data/`.

**1.2 `docker-compose.yml`**
```yaml
services:
  hermes:
    image: nousresearch/hermes-agent@sha256:d4da4a40cd7a28aba983775d9fd31d94cbf153eeb0cb9e844d6d0f612b7c24db
    container_name: hermes
    command: ["gateway", "run"]
    restart: unless-stopped
    network_mode: host
    env_file: .env
    volumes:
      - /srv/hermes/data:/opt/data
      - /srv/hermes/ssh:/root/.ssh:ro
      - "/srv/data1/config/syncthing/Electronic Filing Cabinet:/nas/electronic-filing-cabinet:rw"
      - /srv/data1/config/syncthing/files:/nas/files:rw
    logging:
      driver: json-file
      options: { max-size: "20m", max-file: "5" }
    deploy:
      resources:
        limits: { memory: 3G, cpus: "2.0" }
    healthcheck:
      test: ["CMD-SHELL", "hermes status >/dev/null 2>&1 || exit 1"]
      interval: 60s
      timeout: 20s
      retries: 3
      start_period: 180s
```
Note: no `docker.sock`, no `:rw` on anything Hermes must not write except the two synced trees.

**1.3 `Dockerfile`** — only if 0.4 showed gaps.
```dockerfile
FROM nousresearch/hermes-agent@sha256:d4da4a40cd7a28aba983775d9fd31d94cbf153eeb0cb9e844d6d0f612b7c24db
# CalDAV pull for the daily dashboard; mounted venv path per 0.4.
RUN /opt/hermes/venv/bin/pip install --no-cache-dir caldav
```
Verification: `docker build -t hermes-nas1:0.21.5 . && docker run --rm hermes-nas1:0.21.5 /opt/hermes/venv/bin/python -c "import caldav; print('ok')"`
Swap the `image:` line to `hermes-nas1:0.21.5` if built.

**1.4 Seed `/srv/hermes/data` from the verified snapshot** (not from the live tree — the live `state.db` is open)
```bash
# on eos
hermes backup --quick -l pre-migration
# transfer (snapshot dir → nas-1 staging)
rsync -a --delete ~/.hermes/state-snapshots/<id>/ nick@192.168.0.6:/srv/hermes/seed/
```
Then on nas-1: `mkdir -p /srv/hermes/data && cp -a /srv/hermes/seed/. /srv/hermes/data/`, ensure
`/srv/hermes/data/.env` is mode 600, and **exclude** `state-snapshots/`, `cache/`, `node/`, `lsp/`, `hermes-agent/`
if the transfer included them. Verification: `sqlite3 /srv/hermes/data/state.db 'select count(*) from sessions; select count(*) from messages;'`
— record both numbers; they are the parity baseline for 3.3.

**1.5 Fleet SSH for the container**
```bash
# on nas-1
ssh-keygen -t ed25519 -f /srv/hermes/ssh/id_ed25519 -N "" -C "hermes@nas-1"
cat /srv/hermes/ssh/id_ed25519.pub                       # add to agent@192.168.0.93 and agent@192.168.0.20
cp ~/.ssh/config /srv/hermes/ssh/config 2>/dev/null || true
chmod 700 /srv/hermes/ssh; chmod 600 /srv/hermes/ssh/id_ed25519
```
Verification: `ssh -i /srv/hermes/ssh/id_ed25519 agent@192.168.0.93 'hostname'` → `server-1`.
Do **not** copy eos's private key — a new key keeps the audit trail clean and lets you revoke eos independently.

### Phase 2 — dry run without touching the live bot

**2.1 Boot the container with the gateway but no Telegram poller.** Keep the real `.env` but comment out
`TELEGRAM_BOT_TOKEN` for the dry run (otherwise you get a 409 poller conflict with eos).
```bash
cd /srv/hermes && docker compose up -d && sleep 30 && docker compose logs --tail 40
```
Verification: no traceback; `docker compose exec hermes hermes doctor` reports healthy config.

**2.2 Validate data + tools in-container**
```bash
docker compose exec hermes sh -lc 'hermes --version; hermes cron list | head -20; sqlite3 /opt/data/state.db "PRAGMA quick_check;"; sqlite3 /opt/data/state.db "select count(*) from sessions; select count(*) from messages;"'
docker compose exec hermes sh -lc 'hermes chat -q "print the current host and date"'
```
Verification: version reports 0.21.5; cron jobs all present with sane next-run times; `quick_check` = ok;
session/message counts **match or exceed** the 1.4 baseline; the one-shot chat returns real output (proves model +
tools + network).

**2.3 Measure the real cost on an N100**
```bash
docker stats --no-stream hermes
```
Record RSS + CPU during a normal turn and during a voice-note transcription. Expected: RSS well under 1 GB.
This number decides Phase 7.

### Phase 3 — cutover (hard, single Telegram poller)

**3.1 Announce the window** — Telegram holds undelivered updates for ~24 h, so a short outage loses no messages;
only *two* pollers are harmful.

**3.2 Stop eos, take the final snapshot, start nas-1**
```bash
# eos
systemctl --user stop hermes-gateway
hermes backup --quick -l final-cutover
rsync -a --delete ~/.hermes/state-snapshots/<final-id>/ nick@192.168.0.6:/srv/hermes/seed-final/
# nas-1: stop container, restore final state, re-enable TELEGRAM_BOT_TOKEN, start
docker compose down
rm -f /srv/hermes/data/state.db-wal /srv/hermes/data/state.db-shm
cp -a /srv/hermes/seed-final/state.db /srv/hermes/data/state.db
docker compose up -d
```
Verification: `docker compose logs -f` shows the gateway connecting Telegram with no 409; `sqlite3 ... "PRAGMA quick_check;"` → ok.

**3.3 Smoke test every path that has ever been depended on**
- Send a Telegram DM, get a reply.
- `/status` in the session.
- Read a file from `/nas/electronic-filing-cabinet` and confirm a *new* file appears on eos via Syncthing.
- `hermes cron run <daily-dashboard-id>` and confirm the ZG card renders (exercises ZG API + CalDAV).
- Home Assistant: ask for a light state (exercises `HASS_URL`/`HASS_TOKEN` from nas-1).
- Webhook: `curl -X POST http://192.168.0.6:8644/webhooks/<name>` → 200.
- Session/message parity vs 3.2, and `hermes sessions list | head`.

**3.4 Leave eos in place, gateway disabled**
```bash
systemctl --user disable --now hermes-gateway     # keep ~/.hermes intact for 2 weeks
```
Rollback (§8) is cheap only inside this window — after a day of traffic on nas-1, eos is stale.

### Phase 4 — cron and script triage

**4.1 Re-point the scripts.** Audit each of the 11 jobs for absolute paths and host assumptions before enabling:

| Job | Fate |
|---|---|
| Daily dashboard card | container (needs `caldav` → task 1.3; credential dir `/home/nick/.local/share/hermes-cal` → copy into `/srv/hermes/data/secrets/hermes-cal`, update the script's path) |
| Weekly checklist card / Monthly checklist card / French weekly check-in | container, unchanged (ZG API + LLM) |
| Vyvanse reminder / Midday todos check | container (curl to Telegram) |
| homelabDailyHealthCheck (`homelab-health-check.py`) | container (uses ssh + curl + kuma ssh) |
| NPM services update check | container (NPM is on nas-1, `127.0.0.1:81`) |
| Weekly homelab update report (`update-report.sh`) | **move to .93** — it inspects local docker and SSHes to 5 hosts; keeping it out of the container avoids `docker.sock` |
| Actual→Fava bean sync (`actual-fava-sync.sh`) | **move to .20** as a systemd timer — it already writes there via `agent@`, and it is *currently broken on eos* (`better-sqlite3 ERR_DLOPEN_FAILED`, 24 consecutive failures) |
| room-planner checker | container, but needs `~/code/room-planner` → clone to `/srv/hermes/repos/room-planner` and update the script |

**4.2 Sanity-check the clock/timezone** in-container (`date`) — cron schedules are local-time.

**4.3 Re-run each re-homed job manually once** and confirm both the effect and the alert contract (silence on
success).

### Phase 5 — backup, monitoring, and the drill

**5.1 `/srv/hermes/snapshot.sh` + nas-1 timer** (daily 02:15, weekly zip Sundays)
```bash
docker exec hermes hermes backup --quick -l nightly
```
Then verify size (>10 MB) and `PRAGMA quick_check` on the produced snapshot, prune local snapshots to 7.

**5.2 `pull-snapshot.sh` + .93 timer** (daily 03:00) — the load-bearing piece:
```bash
rsync -a --delete -e "ssh -o BatchMode=yes" nick@192.168.0.6:/srv/hermes/data/state-snapshots/<newest>/ \
  /mnt/nas-2-fast-data/config/backups/hermes-nas1/daily/$(date +%F)/
```
Then: verify remote `state.db` size and `quick_check`; prune to 14 daily / 4 weekly; alert to Telegram via
direct bot-API curl on any failure **or** if the newest snapshot is older than 26 h. Backrest's existing
`nas-2-fast-data-config` plan carries this path to B2 — verify the path is inside the plan's include list.

**5.3 Liveness + monitoring**
- nas-1 timer: container up? restarts in the last 10 min < 3? → push heartbeat to uptime-kuma (already at .160);
  alert on breach to the `home-monitoring` Telegram channel (-5272523127).
- kuma monitor: push-type for the heartbeat; plus the freshness check in 5.2 covers "host gone".
- telegraf already runs on nas-1 — confirm it collects `docker_container_*` for `hermes`.

**5.4 Weekly end-to-end self-test**: cron job that posts a message to a test chat, reads it back, and reports
failure. This is the only check that covers model + Telegram + tools together.

**5.5 Restore drill (do it, don't plan it)** — on .93, into a throwaway dir: restore the newest snapshot, start a
container with Telegram disabled, confirm `quick_check` + session/message counts + a one-shot chat. Document the
timing. This is also the cold-standby rehearsal (§8).

### Phase 6 — retire on eos

**6.1** `systemctl --user disable hermes-gateway` stays; after 2 clean weeks, stop the unit and remove the
`~/.hermes` tree, *keeping* the last weekly zip.
**6.2** Before deleting: prune the 5 GB of junk (`state-snapshots/` 3.2 GB, `recovered.sql` 588 MB,
`state.db.broken` 365 MB, `state.db.original` 364 MB, `backups/` 699 MB) — but only after 6.1.
**6.3** Update `~/.hermes/scripts/hermes-backup.sh`'s successor docs and the `hermes-state-backup-recovery` skill
to the new paths (it currently documents eos paths and the push model).
**6.4** Leave `eos` out of the agent's reachable set: it has **no `agent` account** and neither .93 nor .20 can SSH
in as `nick`. Decide explicitly: either add an `agent` account + key on eos (so Hermes can still help on the
desktop) or accept that Hermes can no longer touch it. *Open question — §7.*

### Phase 7 — offload policy (degraded > dead)

**7.1** STT off-box: `hermes config set stt.provider openai` (or Groq) in the container's config; local
faster-whisper on an N100 is the single worst experience risk.
**7.2** Browser: `browser.engine` → Browserbase (`BROWSERBASE_API_KEY` already in `.env`); the image has **no
chromium**. Alternative: bake chromium into the derived image (heavy on a 4-core N100 — not preferred).
**7.3** Heavy batch (OCR, marker-pdf, manim, video): run on .93/.20 — either a `/nas`-visible workdir plus an SSH
invocation, or `ssh server-1 hermes chat -q "..."` for long jobs. Document the pattern in `README.md`.
**7.4** `computer_use` will not exist on nas-1 (no desktop session). Accept and document; if it is ever needed,
target eos from another instance rather than re-homing the gateway.

### Phase 8 — docs

**8.1** `services/hermes/README.md`: cutover, rollback, cold-standby, CLI access
(`ssh nas-1 'docker exec -it hermes hermes'`), the offload policy, and the required env keys.
**8.2** Update the `hermes-agent` / `hermes-state-backup-recovery` skills to the new topology so future sessions
don't reason from the old eos-centric world.

---

## 5. Files likely to change

- **This repo:** `services/hermes/{PLAN.md,README.md,Dockerfile,docker-compose.yml,.env.example,.gitignore,snapshot.sh,liveness.sh,pull-snapshot.sh}`; possibly `nodes/nas-1/install.sh` if timers are provisioned there; `services/hermes-wife/` untouched.
- **nas-1:** `/srv/hermes/{data,ssh,seed}`; `/etc/systemd/system/hermes-{snapshot,liveness}.{service,timer}`; `/srv/data1/config/syncthing/...` (read/write from the container only).
- **server-1 (.93):** `/mnt/nas-2-fast-data/config/backups/hermes-nas1/`; systemd timer for `pull-snapshot.sh`; Backrest plan include path.
- **eos:** `systemctl --user disable hermes-gateway`; `~/.hermes` retained then pruned.

## 6. Validation summary

| Check | Command | Expected |
|---|---|---|
| DB integrity | `sqlite3 /srv/hermes/data/state.db "PRAGMA quick_check;"` | `ok` |
| History parity | `select count(*) from sessions; select count(*) from messages;` | ≥ pre-migration baseline |
| Config | `docker exec hermes hermes doctor` | no failures |
| Cron | `docker exec hermes hermes cron list` | 11 jobs, sane next-run |
| Telegram | DM the bot | reply, no 409 in logs |
| Cabinet write | write via agent, check on eos | file syncs |
| Webhook | `curl -X POST 192.168.0.6:8644/webhooks/<name>` | 200 |
| Restart survives | `docker restart hermes` | healthy within 3 min |
| Reboot survives | (once) `ssh nas-1 sudo reboot`, wait, check | container auto-starts |
| Backup | `pull-snapshot.sh` dry run from .93 | verified `state.db` at expected size |
| Restore drill | cold standby on .93 into a scratch dir | counts + one-shot chat OK |

## 7. Risks and open questions

**Risks**
1. **Version bump bundled in** (0.21.0 → 0.21.5). `state.db` migrations are automatic and one-way. Mitigation:
   verified snapshot before cutover; if the new instance misbehaves, restore the snapshot and run a *pinned* older
   image; if no older tag exists, the fallback is eos (still installed) rather than a downgrade.
2. **N100 CPU is the real constraint**, not RAM. Whole classes of work get slower (browser, OCR, PDF, transcode);
   §7 exists because of this. Nick has accepted "degraded Hermes > no Hermes".
3. **`nas-1` is the public ingress + SSO host.** Prompt-injected or runaway agent code lands on the box facing the
   internet. Mitigations: no `docker.sock`, no host network beyond the required ports, resource caps, container
   runs as uid 1000 with scoped mounts. This is a conscious tradeoff — the alternative (`.93`) is the conservative
   answer. **Nick explicitly chose .6.**
4. **Single poller.** Two Telegram pollers = 409 flapping. Only ever one at a time; rollback must stop nas-1 first.
5. **Syncthing write conflicts.** The container writes the cabinet; if another peer also writes, expect
   `sync-conflict` files. Only the agent files there after cutover; monitor for conflict files for the first week.
6. **`deploy.resources.limits`** is honoured by Compose v2 — confirm with `docker stats` that the cap is live
   (a silent no-op would be worse than no cap, because it hides CPU starvation).
7. **Healthcheck command is unverified.** `hermes status` may not be an adequate probe; task 2.1 must confirm one
   (`hermes status --json` or a gateway-socket check), otherwise the healthcheck is theatre.

**Open questions**
1. Does the agent keep any access to `eos` (add an `agent` account + key, or cut it off)? §6.4.
2. Accept the bundled 0.21.5 bump, or hunt for a pinned 0.21.0 image tag first?
3. Which offloads do you want *now* (STT is the big one) vs later?
4. Expose the webhook platform publicly through NPM (behind oauth2-proxy) or keep it LAN-only?
5. `.6` is "nas-1" in this repo's node naming — confirm that's the name you want in paths/timers
   (`hermes-nas1/`).

## 8. Rollback

**Inside the first hours (cheap):**
```bash
# nas-1
docker compose down
# eos
systemctl --user enable --now hermes-gateway
```
Cost: messages received on nas-1 in the window exist only in nas-1's DB (recoverable by hand if anyone cares).

**After that (expensive):** restore the newest NAS snapshot into eos's `~/.hermes` with the gateway stopped, clear
`state.db-wal`/`-shm`, start, accept the loss of everything since the cutover.

**Cold standby (nas-1 unrecoverable):** on `server-1`, `docker compose up` from this repo's definition with
`/srv/hermes` replaced by a restored copy of the newest snapshot, add a `TELEGRAM_BOT_TOKEN`, start — the reverse
of the cutover, using the same scripts. This is why the backup is pull-based from .93.

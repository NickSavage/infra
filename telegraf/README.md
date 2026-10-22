# Telegraf metric agents — source of truth (nick/infra)
#
# One agent per node, all writing to the InfluxDB `telegraf` bucket (org `home`) on
# 192.168.0.93:8086, which Grafana reads (datasource uid `influx-telegraf`).
#
# Layout
#   conf/<node>.conf          per-node telegraf config (the only real difference)
#   docker-compose.yml        base stack, used by every node
#   override/<node>....yml    optional per-node additions (currently nas-2 only)
#   deploy-telegraf.sh        copies a node's stack to that host and restarts it
#   .env                      gitignored: the InfluxDB WRITE token (see below)
#
# Node → host map (also encoded in deploy-telegraf.sh)
#   eos      = 192.168.0.168  desktop      cpu/mem/disk
#   nas-1    = 192.168.0.6    secondary NAS  cpu/mem/disk
#   nas-2    = 192.168.0.160  storage box    cpu/mem/disk (big shares via override)
#   server-1 = 192.168.0.93   primary NAS    cpu/mem/disk
#                            + prometheus scrapes of jellyfin and uptime-kuma
#                            + http_response health of the zettel mail service
#   server-3 = 192.168.0.20   app server     cpu/mem/disk
#
# The Ookla speedtest input was REMOVED from all three configs that had it
# (eos, server-1, server-3) on 2026-10-22: [[inputs.exec]] runs at the agent
# interval, so it was firing every ~1-2 min (~45 runs/hour/node, ~3300/day
# fleet-wide), Ookla was answering "Limit reached", and no dashboard panel or
# alert rule ever read the `speedtest` measurement.
# NOTE (leftover): the Dockerfile still installs the CLI even though nothing calls
# it now. Dropping the install — or the custom build entirely, since nothing else
# needs it (compose would just use `image: telegraf:1.35.2`) — is a deliberate
# follow-up: it means rebuilding/pulling on all five nodes.
#
# WHY THE RUNTIME COPY IS LOCAL (/config/telegraf on each host)
# These agents report host and NFS health, so they must not depend on the shared
# /mnt/nas-2-fast-data mount being available in order to start. This directory is the
# versioned source; deploy-telegraf.sh pushes a copy to each host's LOCAL disk. eos has
# no /mnt/nas-2-fast-data mount at all, so a repo-mounted stack could not work there —
# local copies keep all five nodes identical.
#
# DEPLOY
#   bash deploy-telegraf.sh <node>            # remote mode: copies over ssh to agent@<host>
#   bash deploy-telegraf.sh <node> --local    # run ON the target host itself
#   Add --build when the Dockerfile changed (today it only adds the Ookla speedtest
#   CLI, which no config calls any more — see the leftover note above).
#
# Run it as the account whose SSH key is authorized on the targets: that is nick@eos,
# the fleet default. (There is an `agent` account on the servers, but it has no key of
# its own to reach the other nodes — agent → agent SSH is not set up — so don't run the
# remote mode as agent from a fleet host.)
#
# From the four servers the shared checkout is right here:
#   bash /mnt/nas-2-fast-data/config/telegraf/deploy-telegraf.sh nas-1
# From eos (which has no /mnt/nas-2-fast-data mount) use a clone of nick/infra — e.g.
# ~/code/infra — and supply the token (there is no .env in a fresh clone):
#   INFLUXDB_TOKEN=$(printf '%s' '<write token>') ~/code/nick-infra/telegraf/deploy-telegraf.sh nas-1
# deploy-telegraf.sh takes INFLUXDB_TOKEN from the environment when set, else from the
# gitignored .env beside it.
#
# eos needs its own hand-held run for both reasons (nothing ssh's into it, and nick has
# no NOPASSWD sudo on the desktop):
#   sudo /path/to/telegraf/deploy-telegraf.sh eos --local
#
# TOKEN
# .env in this directory holds INFLUXDB_TOKEN (gitignored, mode 600) — the shared
# "WRITE telegraf bucket" token, identical on all five nodes. deploy-telegraf.sh reads
# it and writes the per-node .env (node name + token) on the host.
# Rotate it in InfluxDB UI → API Tokens, then redeploy all five nodes.
#
# VERIFY (read-only token at ~/.hermes/secrets/influxdb.json)
#   from(bucket:"telegraf") |> range(start:-2m)
#     |> filter(fn:(r)=> r._measurement=="cpu" and r._field=="usage_idle")
#     |> group(columns:["node"]) |> last() |> keep(columns:["node","_time"])
# All five nodes should show a timestamp within the last ~15s. After a deploy also
# confirm the deployed files match this directory (md5sum of Dockerfile,
# docker-compose.yml and conf/<node>.conf on the host vs here).
#
# Context / history: ZG 722.10.11 (2026-10-22 audit that found these stacks unversioned).

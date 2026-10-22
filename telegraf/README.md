# Telegraf metric agents — source of truth (nick/infra)
#
# One agent per node, all writing to InfluxDB `telegraf` bucket (org `home`) on
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
#   eos      = 192.168.0.168  desktop   cpu/mem/disk + speedtest
#   nas-1    = 192.168.0.6    secondary NAS  cpu/mem/disk
#   nas-2    = 192.168.0.160  storage box    cpu/mem/disk (big shares via override)
#   server-1 = 192.168.0.93   primary NAS    cpu/mem/disk + speedtest
#                            + prometheus scrapes of jellyfin and uptime-kuma
#                            + http_response health of the zettel mail service
#   server-3 = 192.168.0.20   app server    cpu/mem/disk + speedtest
#
# WHY THE RUNTIME COPY IS LOCAL (/config/telegraf on each host)
# These agents report host and NFS health, so they must not depend on the shared
# /mnt/nas-2-fast-data mount being available in order to start. This directory is
# the versioned source; deploy-telegraf.sh pushes a copy to each host's LOCAL disk.
# eos has no /mnt/nas-2-fast-data mount at all, so a repo-mounted stack could not
# work there — local copies keep all five nodes identical.
#
# DEPLOY
#   sudo /path/to/telegraf/deploy-telegraf.sh <node>            # from a fleet host, over ssh (agent@)
#   sudo ./deploy-telegraf.sh <node> --local                    # run ON the target host itself
#   Add --build when the Dockerfile changed (it bakes in the speedtest CLI).
#
# Run it as the `agent` account from a fleet host where you can (agent holds the ssh
# keys for the other nodes, plus NOPASSWD sudo there). agent cannot read nick-owned
# .env, so hand it the token through the environment instead:
#   INFLUXDB_TOKEN=$(sudo -n -u nick sed -n 's/^INFLUXDB_TOKEN=["]*\([^"]*\)["]*$/\1/p' \
#       /mnt/nas-2-fast-data/config/telegraf/.env) \
#     /mnt/nas-2-fast-data/config/telegraf/deploy-telegraf.sh nas-1
#
# eos is a special case: it has no `agent` account reachable over ssh and nick has
# no NOPASSWD sudo there, so its copy has to be run by hand on the desktop:
#   sudo /path/to/telegraf/deploy-telegraf.sh eos --local
#
# TOKEN
# .env in this directory holds INFLUXDB_TOKEN (gitignored, mode 600) — the shared
# "WRITE telegraf bucket" token, identical on all five nodes. deploy-telegraf.sh
# reads it and writes the per-node .env (node name + token) on the host.
# Rotate it in InfluxDB UI → API Tokens, then update this file and redeploy all nodes.
#
# VERIFY (from any host with the read-only token in ~/.hermes/secrets/influxdb.json)
#   from(bucket:"telegraf") |> range(start:-5m)
#     |> filter(fn:(r)=> r._measurement=="cpu" and r._field=="usage_idle")
#     |> group(columns:["node"]) |> last() |> keep(columns:["node","_time"])
# all five nodes should report a timestamp within the last ~15s.
#
# Context / history: ZG 722.10.11 (2026-10-22 audit that found these stacks unversioned).

# Telegraf metric agent image — one build per node, all five identical.
# Source of truth: nick/infra, telegraf/Dockerfile  (copied to each host by deploy-telegraf.sh)
#
# Base is PINNED: the fleet ran telegraf:latest until 2026-10-22, when this dir was
# versioned (the running images were built 2025-12-24 from latest = 1.35.2). Bump the
# pin deliberately, then redeploy ALL nodes with --build so they stay identical.
FROM telegraf:1.35.2

# Ookla Speedtest CLI — used by the eos, server-1 and server-3 configs
# ([[inputs.exec]] /usr/bin/speedtest). Not present in the base image; the other
# configs simply never call it, so one shared image works everywhere.
RUN apt-get update && apt-get install -y curl gnupg1 apt-transport-https && \
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && \
    apt-get install -y speedtest && \
    rm -rf /var/lib/apt/lists/*

# The telegraf user must be able to run the binary, and the configs pass
# --accept-license / --accept-gdpr explicitly on the command line.

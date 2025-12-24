FROM telegraf:latest

# Install dependencies and Ookla Speedtest
RUN apt-get update && apt-get install -y curl gnupg1 apt-transport-https && \
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && \
    apt-get install -y speedtest && \
    rm -rf /var/lib/apt/lists/*

# The Telegraf user needs to be able to run the binary
# and it must accept the license via the flag in the config.

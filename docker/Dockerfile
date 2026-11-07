# syntax=docker/dockerfile:1
# =============================================================================
#  The Isle (Evrima) dedicated server - container image
#
#  The game itself is NOT baked into the image. SteamCMD downloads it into the
#  /data volume on first start, and updates it on every restart.
#
#    docker build -f docker/Dockerfile -t theisle-server .
#    docker compose up -d          (see docker-compose.yml and DOCKER.md)
# =============================================================================
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# 32-bit libs are required by SteamCMD; tini is a tiny init that forwards signals.
# hadolint ignore=DL3008
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar gzip python3 procps tini \
      lib32gcc-s1 lib32stdc++6 \
 && rm -rf /var/lib/apt/lists/*

# Unprivileged runtime user. The entrypoint remaps it to PUID/PGID at start.
RUN groupadd --gid 1000 theisle \
 && useradd --uid 1000 --gid 1000 --home-dir /data/home --no-create-home --shell /bin/bash theisle

COPY VERSION /opt/theisle-scripts/VERSION
COPY config/server.conf.example /opt/theisle-scripts/config/server.conf.example
COPY linux/ /opt/theisle-scripts/linux/
COPY tools/ /opt/theisle-scripts/tools/
COPY docker/entrypoint.sh /usr/local/bin/theisle-entrypoint
COPY docker/isle-server /usr/local/bin/isle-server
RUN sed -i 's/\r$//' /opt/theisle-scripts/linux/*.sh /usr/local/bin/theisle-entrypoint /usr/local/bin/isle-server \
 && chmod 755 /opt/theisle-scripts/linux/*.sh /opt/theisle-scripts/tools/*.py \
              /usr/local/bin/theisle-entrypoint /usr/local/bin/isle-server

# Paths are written into /data/config/server.conf by the entrypoint (env overrides).
ENV ISLE_CONF=/data/config/server.conf \
    ISLE_NO_SYSTEMD=1 \
    HOME=/data/home \
    STEAMCMD_DIR=/data/steamcmd \
    SERVER_DIR=/data/server \
    BACKUP_DIR=/data/backups \
    PUID=1000 \
    PGID=1000

VOLUME ["/data"]
EXPOSE 7777/udp 7777/tcp 10000/tcp 8888/tcp

# Healthy while the game server process is alive. The long start period covers
# the first download of the server files (several GB).
HEALTHCHECK --interval=30s --timeout=10s --start-period=30m --retries=3 \
  CMD ["isle-server", "status"]

STOPSIGNAL SIGTERM
# tini forwards SIGTERM to the entrypoint only (not the whole process group), so
# the entrypoint can save via RCON before it stops the server.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/theisle-entrypoint"]
CMD ["run"]

LABEL org.opencontainers.image.title="The Isle (Evrima) dedicated server" \
      org.opencontainers.image.source="https://github.com/kyroskoh/the-isle-dedicated-server" \
      org.opencontainers.image.licenses="MIT"

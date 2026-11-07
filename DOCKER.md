# Running in Docker

The image packages the Linux scripts with everything SteamCMD and the server need. The
**game itself isn't in the image.** It downloads into the `/data` volume on first start and
updates on every container restart.

Requirements: Docker Engine 24+ or Docker Desktop (Windows, macOS, Linux) on an
**x86_64 / amd64** host. ARM hosts (Apple Silicon, Raspberry Pi, Graviton) aren't supported,
because the game server is x86_64 only.

## Quick start (Docker Compose)

```bash
git clone https://github.com/kyroskoh/the-isle-dedicated-server.git
cd the-isle-dedicated-server
docker compose up -d --build      # first start downloads several GB - be patient
docker compose logs -f            # wait for the server to finish starting
```

Then forward **7777/udp + 7777/tcp** and **10000/tcp** to the Docker host on your router or
cloud firewall.

Change settings in a `.env` file next to `docker-compose.yml`:

```dotenv
SERVER_NAME=My Evrima Server
SERVER_PASSWORD=
MAX_PLAYERS=100
ADMIN_STEAM_IDS=76561198000000001,76561198000000002
```

Apply them with `docker compose up -d`, which recreates the container. The world is kept.

## Plain `docker run`

```bash
docker build -f docker/Dockerfile -t theisle-server .
docker run -d --name theisle --restart unless-stopped --stop-timeout 90 \
  -p 7777:7777/udp -p 7777:7777/tcp -p 10000:10000/tcp -p 127.0.0.1:8888:8888/tcp \
  -v theisle-data:/data \
  -e SERVER_NAME="My Evrima Server" -e ADMIN_STEAM_IDS=76561198000000001 \
  theisle-server
```

## Configuration

- **Every key in [`config/server.conf.example`](config/server.conf.example) can be set as an environment
  variable** with the same name (see [CONFIGURATION.md](CONFIGURATION.md)).
- On each start the entrypoint writes those variables into `/data/config/server.conf`, then validates it
  (`check`). If a value is invalid, the container exits with an error that names the key.
- **Env vars win on every start.** If you remove a variable, the file keeps its last value. To go back to
  a default, set the variable explicitly or edit the file:
  `docker compose exec theisle sh -c 'vi /data/config/server.conf'`.
- An RCON password is generated on first start. Read it with
  `docker compose exec theisle grep RCON_PASSWORD /data/config/server.conf`.
- **Ports:** keep host and container ports the same (`7777:7777`). The server advertises its own port, so
  remapping `7777` to another host port breaks joins. To use another port, set `GAME_PORT` / `QUEUE_PORT`.
  The compose file maps both sides from those variables.

| Variable | Default | Purpose |
|---|---|---|
| `PUID` / `PGID` | `1000` | User and group the server runs as. Match a bind-mount owner |
| `UPDATE_ON_START` | `true` | Update the game with SteamCMD on every start |
| `STOP_TIMEOUT` | `60` | Seconds to wait for a clean exit (keep `stop_grace_period` 30 s longer) |

## Volume layout

```
/data/config/server.conf   settings (mode 600)
/data/server/              game files + TheIsle/Saved (world, logs, ini files)
/data/steamcmd/            SteamCMD
/data/backups/             backup archives
/data/home/                HOME of the server user (steamclient.so)
```

To use a host folder instead of a named volume, set `- ./data:/data` in the compose file, and set
`PUID`/`PGID` to the folder owner (`id -u`, `id -g`). On start, the entrypoint fixes ownership inside `/data`.

## Everyday operations

| Task | Command |
|---|---|
| Start / stop / restart | `docker compose start` / `stop` / `restart` |
| Logs | `docker compose logs -f` |
| Update the game | `docker compose restart` (updates on start) |
| Update these scripts | `git pull && docker compose up -d --build` |
| Status | `docker compose exec theisle isle-server status` |
| Check config | `docker compose exec theisle isle-server check` |
| Backup | `docker compose exec theisle isle-server backup` |
| RCON | `docker compose exec theisle isle-server rcon announce "Restart in 5 min"` |
| Restore | `docker compose stop`, then `docker compose run --rm theisle restore /data/backups/<file>.tar.gz`, then `docker compose start` |
| Shell | `docker compose exec theisle bash` |

- `isle-server start|stop|restart` inside the container refers you to `docker compose`, because the container *is* the service.
- `docker compose stop` sends SIGTERM. The entrypoint saves the world over RCON, stops the server cleanly, and waits up
  to `STOP_TIMEOUT` before it force-kills.
- If the server crashes, the container exits and `restart: unless-stopped` brings it back.
- The health check (`isle-server status`) shows `healthy` while the server process is alive. It allows 30 minutes for
  the first download.

### Scheduled backups and restarts

There's no cron inside the container. Use the host's:

```cron
0 5 * * *  cd /path/to/the-isle-dedicated-server && docker compose exec -T theisle isle-server backup
30 5 * * * cd /path/to/the-isle-dedicated-server && docker compose restart theisle
```

## Troubleshooting

- **Not listed in the server browser:** check the port forwards, then try host networking. Remove the `ports:`
  section and set `network_mode: host` in `docker-compose.yml`. This is Linux hosts only.
- **`/data is not writable`:** set `PUID`/`PGID` to the bind-mount owner, or `chown -R 1000:1000 ./data`.
- **Container exits right away:** run `docker compose logs`. A `[FAIL] config:` line names the setting to fix.
- **Slow first start:** that's the SteamCMD download. Follow it with `docker compose logs -f`.
- **Windows / macOS (Docker Desktop):** works with Linux containers on x86_64 machines. Give Docker enough RAM
  (8 GB or more) in Docker Desktop settings.

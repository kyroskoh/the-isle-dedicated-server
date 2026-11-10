# Web UI and REST API

The scripts can optionally run a small web UI and REST API on the server. It does everything the command line
does: start/stop, settings, admins, whitelist, roster, profiles, presets, plugins, snapshots, logs and an RCON
console. Every action goes through the same launcher (`isle-server.sh` / `IsleServer.ps1`), so it works natively
and in Docker, on Linux and Windows.

![Dashboard (light theme)](docs/images/ui/dashboard-light.png)

- **UI:** `http://127.0.0.1:8090/` (light, dark or system theme)
- **API docs:** `http://127.0.0.1:8090/docs`, an interactive OpenAPI viewer with "Try it"
- **OpenAPI document:** `http://127.0.0.1:8090/openapi.json` (OpenAPI 3.1)

It needs Python 3.6+ (standard library only). Nothing is downloaded at runtime, and the pages load no external
scripts, fonts or images.

## Starting it

| | Linux | Windows |
|---|---|---|
| Run in the foreground (Ctrl+C stops it) | `sudo -u theisle isle-server ui` (docker mode: `sudo isle-server ui`) | `UI.bat` or `IsleServer.ps1 UI` |
| ...and open a browser | `isle-server ui --open` | `UI.bat --open` |
| Show the access token | `sudo -u theisle isle-server ui-token` | `Manage.bat UiToken` |
| Replace the token | `isle-server ui-token --rotate` | `Manage.bat UiToken --rotate` |
| Run at boot | `sudo ./linux/install.sh --ui` (systemd `theisle-ui`) | `Install.bat -UI` (scheduled task `TheIsleServer-UI`) |
| Stop running at boot | `sudo ./linux/install.sh --no-ui` | `Install.bat -NoUI` |

Once installed, the boot-time service is kept when you re-run the installer or switch modes. Uninstalling removes it.

Options for `ui`: `--host H`, `--port P`, `--open`, `--cert FILE --key FILE` (HTTPS), `--cors ORIGIN`. The defaults
come from `UI_HOST` and `UI_PORT` in `server.conf` (127.0.0.1 and 8090).

## Signing in

The UI asks for the **access token**. It is created on first start in `config/ui-token`, next to `server.conf`,
readable only by its owner. Paste it once per browser tab. It is kept in that tab's session storage and sent as
`Authorization: Bearer <token>`. There are no cookies, so other sites cannot make requests in your name.

`ISLE_UI_TOKEN=...` in the environment overrides the file.

<p align="center"><img src="docs/images/ui/login.png" alt="Sign-in page asking for the access token" width="640"></p>

## Reaching it from another computer

The UI listens on **127.0.0.1 only** by default. Choose one of these:

1. **SSH tunnel (simplest):** `ssh -L 8090:127.0.0.1:8090 you@server`, then open `http://localhost:8090/`.
2. **Reverse proxy with TLS** (Caddy, nginx, IIS) in front of `127.0.0.1:8090`.
3. **Built-in HTTPS:** `isle-server ui --host 0.0.0.0 --cert fullchain.pem --key privkey.pem`, and open the port in
   the firewall for your own address only.

Listening on another address without TLS works, but prints a warning: the token would cross the network in
plain text.

## Pages

| Page | What it does |
|---|---|
| Dashboard | State, Start/Stop/Restart/Save/Backup, Update/Verify game files, server details, recent jobs with their output |
| Settings | Every `server.conf` key, grouped and searchable. Secrets are masked. Changes are checked with `check` and rolled back if invalid. Machine-specific keys (paths, runtime, UI address) are read-only here |
| Players | Admins and whitelist (add, remove, on/off) |
| Roster | Playable classes as tick boxes (with types), roster presets, a type filter (incl. human and egg) with Only / Add / Remove, and the humans switch |
| Map & AI | Switch maps (with their Steam branch), AI spawning, density (live), spawn interval, AI presets, disabled AI classes with their roles, mutations |
| Profiles & presets | Apply a profile, or several presets in order |
| Plugins | Search, install, enable/disable, update, remove, configure, plugin presets, catalog sources, community resources |
| Snapshots & backups | Create, restore (choose parts, overwrite, stop first) and delete snapshots; back up now; backup schedule (cron) with live preview; 3-2-1 check |
| Logs | The game's log or any rotated `launcher_` / `server_` / `ui_` log file, last 100–2000 lines, with auto-refresh |
| Admin | Live admin commands: players online, player data, DM, kick, ban, announce, live switches, growth multiplier, save, wipe corpses, custom |
| RCON console | Send RCON commands to the running server |

### Date & time, cut-off text and screen sizes

- **Date & time** (sidebar): show times in **server time**, **this browser's** time zone or **UTC**, with a date format
  of your choice. The presets all show the month as three letters (`08 Nov 2026, 14:30:05` by default), and custom
  patterns use `yyyy yy MMMM MMM MM M dd d EEEE EEE HH H hh h mm ss a ZZ 'text'`. The choice is saved in this browser.
  Hovering or focusing any date shows the full timestamp with its zone.
- **Peek:** text that is cut off with "…" (long dinosaur names, the server name ...) shows in full **immediately** on
  hover, keyboard focus or a tap, with no tooltip delay.
- **Any screen:** phones and tablets in portrait and landscape, and desktops up to wide screens. Tables turn into
  labelled cards when their space gets narrow, buttons grow to 44 px on touch screens, and nothing scrolls sideways.
  Long names, IDs and paths wrap instead of overflowing. This is checked on every change in Chromium (Chrome, Edge),
  Firefox and WebKit (Safari) at 320–1920 px (`tests/test_ui_overflow.mjs`).

| Date & time | Logs (rotated files) |
|---|---|
| ![Date & time preferences](docs/images/ui/date-time.png) | ![Logs page with a server_yyyymmdd_hhmmss.log file](docs/images/ui/logs.png) |

| Tap to peek (phone) | Phone, landscape | Tablet, portrait |
|---|---|---|
| ![Tapping the cut-off server name shows it in full](docs/images/ui/phone-peek-dark.png) | ![Phone in landscape](docs/images/ui/phone-landscape.png) | ![Tablet in portrait](docs/images/ui/tablet-portrait.png) |

### Screenshots

**Dashboard.** Server state, quick actions, server details and recent jobs. Disruptive actions ask first.

| Light | Dark |
|---|---|
| ![Dashboard, light theme](docs/images/ui/dashboard-light.png) | ![Dashboard, dark theme](docs/images/ui/dashboard-dark.png) |

![Confirmation before a restart](docs/images/ui/confirm-restart.png)

**Settings.** Every `server.conf` key, grouped and searchable, with toggles for true/false and masked secrets.
Changed fields are highlighted until you save. Machine-specific keys sit read-only in a collapsed section at the end.

| Light | Dark |
|---|---|
| ![Settings with an unsaved change](docs/images/ui/settings.png) | ![Settings, dark theme](docs/images/ui/settings-dark.png) |

**Players.** Admins and the whitelist, with SteamID64 validation in the browser and links to Steam profiles.

![Players page](docs/images/ui/players.png)

**Roster.** Playable classes as tick boxes, with diets and roster presets.

![Roster page](docs/images/ui/roster.png)

Filter by type (carnivore, herbivore, omnivore, flying, aquatic, human, egg), then **Only** / **Add** / **Remove** that
type in one click. Humans are a live switch (`ENABLE_HUMANS`); eggs and hatchlings have no server setting, and the tile
says so.

![Roster filtered to carnivores](docs/images/ui/roster-types.png)

**Map & AI.** Pick the map (its Steam branch switches with it), and set AI spawning, density, spawn interval, AI presets
and disabled AI classes.

| Map | AI creatures |
|---|---|
| ![Map & AI page](docs/images/ui/map-ai.png) | ![AI creatures](docs/images/ui/map-ai-creatures.png) |

**Mutations.** Every mutation (the game default), or only the ticked ones with their values. "Fixed" mutations only take 1.

![Mutations card](docs/images/ui/mutations.png)

**Profiles & presets.** Profile cards show what they change. Presets can be applied together, in order.

![Profiles and presets](docs/images/ui/profiles.png)

**Plugins.** Search, install, enable, configure, update, remove, and plugin presets, plus community catalog sources and a
list of community tools and guides.

| Plugins | Catalog sources & community |
|---|---|
| ![Plugins page](docs/images/ui/plugins.png) | ![Catalog sources and community](docs/images/ui/plugins-community.png) |

**Snapshots & backups.** Create snapshots with chosen parts, then restore (choosing parts, overwrite and stop first) or delete them.

| Snapshots | Restore |
|---|---|
| ![Snapshots page](docs/images/ui/snapshots.png) | ![Restore dialog](docs/images/ui/snapshot-restore.png) |

**Backup schedule and 3-2-1.** Pick a preset or type a cron expression; the next five runs show as you type (in the
server's time zone). The 3-2-1 card checks copies, media and off-site.

![Backup schedule and 3-2-1 check](docs/images/ui/backup-schedule.png)

**Admin.** Live RCON commands: players online with data / message / kick / ban, announcements, moderation by SteamID64,
live switches (pause, migrations, humans, global chat, AI learning, network updates), the growth multiplier, save, queue
status, playable classes, server details, wipe corpses and an experimental custom command. A note explains what RCON
cannot do (size, skin, mutations, god mode, teleport, heal).

![Admin page](docs/images/ui/admin.png)

**Logs and RCON console.**

| RCON console |
|---|
| ![RCON console](docs/images/ui/console.png) |

**On a phone.** The layout adapts and the menu slides in.

<p><img src="docs/images/ui/phone-dashboard-dark.png" alt="Dashboard on a phone, dark theme" width="280"> <img src="docs/images/ui/phone-menu-dark.png" alt="Menu on a phone, dark theme" width="280"></p>

Long actions (start, stop, update, backup, snapshots) run as **jobs**. The UI shows their output live. Only one
lifecycle action runs at a time, and a second one gets `409 Conflict`.

## The API

All routes are under `/api/v1`, documented at `/docs`, and need the Bearer token, except `GET /api/v1/health`.

| `/docs` | "Try it" (dark theme) |
|---|---|
| ![Interactive API documentation](docs/images/ui/api-docs.png) | ![Trying GET /api/v1/status from the docs](docs/images/ui/api-docs-try-it-dark.png) |

```bash
TOKEN=$(sudo -u theisle isle-server ui-token)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8090/api/v1/status
curl -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8090/api/v1/server/restart        # 202 + job
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8090/api/v1/jobs/<id>                       # poll it
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"values": {"MAX_PLAYERS": "80"}}' http://127.0.0.1:8090/api/v1/config
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"command": "announce", "args": ["Restart in 5 minutes"]}' http://127.0.0.1:8090/api/v1/rcon
```

| Area | Routes |
|---|---|
| System / server | `GET health`, `GET status`, `GET info`, `POST server/{start\|stop\|restart\|save\|backup\|update\|validate}`, `GET logs?lines=`, `POST rcon` |
| Jobs | `GET jobs`, `GET jobs/{id}` |
| Settings | `GET config`, `PATCH config`, `GET config/check` |
| Players | `GET/POST admins`, `DELETE admins/{id}`, `GET/POST whitelist`, `DELETE whitelist/{id}`, `PUT whitelist/enabled` |
| Roster | `GET/PUT classes`, `POST classes/preset`, `GET rosters`, `GET/PUT ai-classes` |
| Map & AI | `GET maps`, `PUT map`, `GET/PATCH ai`, `POST ai/preset` |
| Profiles | `GET profiles`, `POST profiles/{name}/apply`, `GET presets`, `POST presets/apply` |
| Plugins | `GET/POST/DELETE plugins/sources`, `GET plugins/community`, `GET plugins`, `GET plugins/{name}`, `POST plugins/{name}/{install\|remove\|enable\|disable\|update}`, `PATCH plugins/{name}/config`, `POST plugins/presets/{preset}` |
| Snapshots | `GET snapshots`, `POST snapshots`, `POST snapshots/{name}/restore`, `DELETE snapshots/{name}` |

How the API behaves:

- **Errors** use RFC 7807 `application/problem+json` with `title`, `status`, `detail` and `request_id`.
- **Status codes:**

  | Code | Meaning |
  |---|---|
  | 422 | Validation failed |
  | 401 | Missing or wrong token |
  | 429 | Locked out after 10 wrong tokens in a minute (`Retry-After`) |
  | 403 | Machine-specific setting |
  | 409 | Busy |
  | 413 | Body over 64 KB |
  | 415 | Not JSON |

- **Request IDs:** send `X-Request-ID` to trace a request; every response carries one, and the access log
  (stdout / journal) records it.
- **Inputs are validated:** SteamID64s, class names, setting keys and preset names. Commands run as argument
  lists, never through a shell.

## Security notes

- Anyone with the token can control the server, change settings and install plugins, which run with the server
  user's rights. Keep the token private, and rotate it if it leaks.
- On Linux in native mode the UI runs as the `theisle` user. In docker mode it runs as root, because Docker access
  is root-equivalent anyway. On Windows the boot task runs as SYSTEM, and the token file is limited to
  Administrators and SYSTEM.
- Every page response sets these headers:
  - a strict `Content-Security-Policy` (only `'self'`, no inline scripts)
  - `X-Frame-Options: DENY`
  - `X-Content-Type-Options: nosniff`
  - `Referrer-Policy: no-referrer`
  - `Strict-Transport-Security` (with TLS)
- CORS is off unless you allow one exact origin with `--cors`.

See also [SECURITY.md](SECURITY.md).

---

Made with ❤️ by [Kyros Koh](https://github.com/kyroskoh)

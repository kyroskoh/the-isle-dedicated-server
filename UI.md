# Web UI and REST API

The scripts can optionally run a small web UI and REST API on the server. It does everything the command line
does: start/stop, settings, admins, whitelist, roster, profiles, presets, plugins, snapshots, logs and an RCON
console. Every action goes through the same launcher (`isle-server.sh` / `IsleServer.ps1`), so it works natively
and in Docker, on Linux and Windows.

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
| Roster | Playable classes and disabled AI as tick boxes, plus roster presets |
| Profiles & presets | Apply a profile, or several presets in order |
| Plugins | Search, install, enable/disable, update, remove, configure, plugin presets |
| Snapshots & backups | Create, restore (choose parts, overwrite, stop first) and delete snapshots; back up now |
| Logs | Last 100–2000 lines, with auto-refresh |
| RCON console | Send RCON commands to the running server |

Long actions (start, stop, update, backup, snapshots) run as **jobs**. The UI shows their output live. Only one
lifecycle action runs at a time, and a second one gets `409 Conflict`.

## The API

All routes are under `/api/v1`, documented at `/docs`, and need the Bearer token, except `GET /api/v1/health`.

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
| Profiles | `GET profiles`, `POST profiles/{name}/apply`, `GET presets`, `POST presets/apply` |
| Plugins | `GET plugins`, `GET plugins/{name}`, `POST plugins/{name}/{install\|remove\|enable\|disable\|update}`, `PATCH plugins/{name}/config`, `POST plugins/presets/{preset}` |
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

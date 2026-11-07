# Troubleshooting

Start with the logs:

- Server log: `<SERVER_DIR>/TheIsle/Saved/Logs/TheIsle.log` (`isle-server logs -f`, or `IsleServer.ps1 Logs -Follow`)
- Linux service: `journalctl -u theisle-server -f`
- Linux background mode: `<SERVER_DIR>/.isle-scripts/console.log`

## Server doesn't appear in the in-game server list

1. Check that `Engine.ini` contains the `[EpicOnlineServices]` section. The server registers through EOS.
2. Check that **UDP 7777** (and TCP 10000 for the queue) is open in the OS firewall **and** forwarded on your router or cloud firewall.
3. Wait 2–5 minutes after the first start, then search by exact name in the browser.
4. Behind CGNAT (common on mobile or ISP-shared connections), inbound ports can't work. Use a VPS or ask your ISP for a public IPv4.
5. If the host has several network interfaces, set `MULTIHOME_IP` to the public-facing local IP.

## SteamCMD errors

| Message | Fix |
|---|---|
| `steamcmd.sh: ... No such file or directory` / `ELF 32-bit` errors | 32-bit libraries are missing. Install `lib32gcc-s1` / `glibc.i686` / `lib32-gcc-libs` (see INSTALL.md) |
| `ERROR! Failed to install app '412680' (No subscription)` | Check `STEAM_BRANCH` spelling (`evrima`). Run the `validate` command |
| `Error! App '412680' state is 0x202 after update job` | Not enough disk space. Free up space |
| `0x602` / `0x6` / timeouts | Steam is having trouble. The scripts retry 3 times. Run `update` again later |
| Exits with code 7 or 8 on first run | SteamCMD updated itself. The scripts retry automatically |

## `steamclient.so` / `SteamAPI_Init() failed` (Linux)

Copy the library and restart:
```bash
mkdir -p ~/.steam/sdk64 && cp ~/steamcmd/linux64/steamclient.so ~/.steam/sdk64/
```
`isle-server.sh update` does this for you.

## Windows: server closes right away or `VCRUNTIME140.dll` missing

Install the Visual C++ 2015-2022 x64 runtime (`Install.ps1` does this), then reboot.
If an error mentions `XINPUT1_3.dll` or `d3dx`, install the *DirectX End-User Runtime (June 2010)* from Microsoft.

## Windows: "running scripts is disabled on this system"

Use the `.bat` launchers, or run
`powershell -ExecutionPolicy Bypass -File .\IsleServer.ps1 <Command>`.
If you downloaded a ZIP, right-click it, choose **Properties**, tick **Unblock**, and then extract it.

## Windows: `Stop.bat` says access denied

When the server runs as the `TheIsleServer` scheduled task (`LOCAL SERVICE`), you can only
stop it from an **elevated** prompt. Right-click `Stop.bat` and choose **Run as administrator**.

## RCON doesn't respond

- Check that `RCON_ENABLED=true` and that `RCON_PASSWORD` is set, then restart (`bRconEnabled` is read at start).
- Make sure Python 3 is installed and on `PATH`. On Windows, the Microsoft Store `python.exe` stub doesn't work.
- If you connect remotely, open `RCON_PORT`/TCP in the firewall (`FIREWALL_OPEN_RCON=true`). Better: use SSH or a VPN.
- The game patch may have changed the protocol. Try `isle_rcon.py raw 0x12` to check that the connection works.

## Settings don't apply

- With `MANAGE_INI_FILES=true`, edits to `Game.ini` are **overwritten** on the next start. Edit `server.conf` instead,
  or set `MANAGE_INI_FILES=false`.
- To add a key the scripts don't know yet, use `EXTRA_GAME_SESSION_SETTINGS=KeyA=1|KeyB=true`.

## High memory use or lag

- Lower `AI_DENSITY` and `PLANT_SPAWN_MULTIPLIER`, and reduce `MAX_PLAYERS`.
- Use an SSD and a CPU with high single-thread performance.
- On Linux, `isle-server.sh` raises the open-file limit (`ulimit -n`). The systemd unit sets `LimitNOFILE=100000`.

## Restoring after a bad update

```bash
isle-server stop
isle-server restore ~/theisle-backups/theisle-YYYYMMDD-HHMMSS.tar.gz
isle-server validate
isle-server start
```

# Security

## Reporting a vulnerability

Please open a private security advisory on GitHub
(**Security → Advisories → Report a vulnerability**) rather than a public issue.

## Hardening checklist

- **Never expose RCON (8888/tcp) to the internet.** The protocol is unencrypted. Use it locally,
  over SSH (`ssh -L 8888:127.0.0.1:8888 host`) or over a VPN. The installers keep it closed unless you set
  `FIREWALL_OPEN_RCON=true`.
- **Use a strong `RCON_PASSWORD`.** The installers generate a random 24-character one.
- **Protect `config/server.conf`.** It holds the RCON and server passwords. On Linux it's `chmod 600`
  and owned by the service user, and it's listed in `.gitignore`, so don't commit it.
- **Don't run the server as root or Administrator.** On Linux it runs as the `theisle` user, and
  `isle-server.sh` refuses to run as root. On Windows the boot task runs as `LOCAL SERVICE`, which only has
  modify rights on the install folders.
- **Keep the OS and the game updated.** `UPDATE_ON_START=true` updates the game on every restart.
- **Open only the ports you need:** the game port (UDP/TCP) and the queue port (TCP).
- **Web UI / API (optional, see [UI.md](UI.md)).** It listens on `127.0.0.1` only by default. Reach it with an
  SSH tunnel or put a TLS reverse proxy in front, or use `--cert/--key`. Never expose it over plain HTTP.
  - **Token:** every route except `/api/v1/health` needs the Bearer token in `config/ui-token` (mode 600, never
    copied by the installers or carried by snapshots). Ten wrong tokens in a minute lock the address out for a
    minute. Rotate the token with `isle-server ui-token --rotate`.
  - **What the API won't do:**
    - change machine-specific settings (paths, runtime, UI address)
    - run commands through a shell (the launcher is called with an argument list)
    - set cookies or allow other origins (no CORS unless `--cors ORIGIN`)
  - **Headers:** pages are sent with a strict Content-Security-Policy (`'self'` only, no inline scripts),
    `X-Frame-Options: DENY`, `nosniff` and `no-referrer`.
- The sudoers rule the Linux installer adds lets the service user run only
  `systemctl start|stop|restart|status theisle-server`. Skip it with `--no-sudoers`.

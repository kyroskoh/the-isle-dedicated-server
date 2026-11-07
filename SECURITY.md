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
- The sudoers rule the Linux installer adds lets the service user run only
  `systemctl start|stop|restart|status theisle-server`. Skip it with `--no-sudoers`.

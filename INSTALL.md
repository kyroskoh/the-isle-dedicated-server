# Installation Guide

This guide covers automated and manual installation on Windows and Linux.
Read [CONFIGURATION.md](CONFIGURATION.md) afterwards to tune the server.

## Requirements

| | Minimum | Recommended |
|---|---|---|
| CPU | 4 cores x86_64, high single-thread speed | 6+ cores |
| RAM | 8 GB | 16 GB+ for 100+ players |
| Disk | 20 GB free (SSD) | NVMe SSD |
| Network | 20 Mbit/s upload | 100 Mbit/s+, public IPv4 |
| OS | See the support table in [README.md](README.md) | |

You need outbound internet access to Steam (SteamCMD) and Epic Online Services.
You do **not** need to own the game on the server machine: SteamCMD downloads the server anonymously.

---

## Windows (10 / 11 / Server 2019, 2022, 2025)

### Automated install

1. Download this repository as a ZIP and extract it, or `git clone` it.
2. Double-click **`windows\Install.bat`**. It asks for Administrator rights, then:
   - copies the scripts to `C:\TheIsle\scripts` and creates `config\server.conf`
   - installs the **Visual C++ 2015-2022 x64** runtime if it's missing
   - installs **Python 3** with `winget` if it's available. Python is used for RCON save-on-stop. It's optional.
   - downloads **SteamCMD** to `C:\TheIsle\steamcmd`
   - installs the server (app `412680`, branch `evrima`) to `C:\TheIsle\server`
   - generates a random RCON password, `Game.ini` and `Engine.ini`
   - adds **Windows Defender Firewall** rules (group *The Isle Dedicated Server*)
   - registers the **`TheIsleServer`** scheduled task, which starts the server at boot as `LOCAL SERVICE` and restarts it if it crashes, and the **`TheIsleServer-Backup`** task, which runs daily at 05:00
3. Edit `C:\TheIsle\scripts\config\server.conf`, then run `C:\TheIsle\scripts\windows\Restart.bat`.

Installer options (run from an elevated PowerShell):

```powershell
cd <repo>\windows
.\Install.ps1 -InstallRoot D:\TheIsle     # install somewhere else
.\Install.ps1 -Start                      # start when finished
.\Install.ps1 -NoService                  # no boot-time task (use Start.bat / Console.bat)
.\Install.ps1 -NoFirewall -NoPython
.\Install.ps1 -ServiceAccount System      # run the task as SYSTEM instead of LOCAL SERVICE
.\Install.ps1 -Branch ''                  # install the public (Legacy) branch instead of evrima
.\Install.ps1 -Uninstall                  # remove tasks + firewall rules (keeps files)
```

> **Windows Server Core:** everything works from `powershell.exe`. `winget` is usually
> missing there, so install Python from python.org if you want RCON features.

> **Execution policy:** the `.bat` launchers pass `-ExecutionPolicy Bypass` for you.
> If you call the `.ps1` files directly, run
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, or use `-ExecutionPolicy Bypass`.

### Manual install (Windows)

```powershell
# 1. SteamCMD
New-Item -ItemType Directory C:\TheIsle\steamcmd -Force
Invoke-WebRequest https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip -OutFile $env:TEMP\steamcmd.zip
Expand-Archive $env:TEMP\steamcmd.zip C:\TheIsle\steamcmd

# 2. Server files (Evrima branch)
C:\TheIsle\steamcmd\steamcmd.exe +force_install_dir C:\TheIsle\server +login anonymous +app_update 412680 -beta evrima validate +quit

# 3. Config: create these two files (see CONFIGURATION.md for the content)
#    C:\TheIsle\server\TheIsle\Saved\Config\WindowsServer\Game.ini
#    C:\TheIsle\server\TheIsle\Saved\Config\WindowsServer\Engine.ini

# 4. Firewall
New-NetFirewallRule -DisplayName "TheIsle-Game-UDP"  -Direction Inbound -Protocol UDP -LocalPort 7777  -Action Allow
New-NetFirewallRule -DisplayName "TheIsle-Game-TCP"  -Direction Inbound -Protocol TCP -LocalPort 7777  -Action Allow
New-NetFirewallRule -DisplayName "TheIsle-Queue-TCP" -Direction Inbound -Protocol TCP -LocalPort 10000 -Action Allow

# 5. Start
C:\TheIsle\server\TheIsleServer.exe -Port=7777 -log
```

---

## Linux (all major distributions)

### Automated install

```bash
git clone https://github.com/kyroskoh/the-isle-dedicated-server.git
cd the-isle-dedicated-server
sudo ./linux/install.sh
```

The installer:

1. Detects the distro from `/etc/os-release` and the package manager (`apt`, `dnf`, `yum`, `pacman`, `zypper`), then installs
   `curl`, `tar`, `python3`, `ca-certificates` and the **32-bit runtime libraries SteamCMD needs**:

   | Family | Packages |
   |---|---|
   | Debian/Ubuntu | `lib32gcc-s1` (or `lib32gcc1`), `lib32stdc++6`, with `i386` architecture enabled |
   | Fedora/RHEL | `glibc.i686`, `libstdc++.i686`, `libgcc.i686` |
   | Arch | `lib32-gcc-libs`, `lib32-glibc` (turns on `[multilib]` and backs up `pacman.conf`) |
   | openSUSE | `glibc-32bit`, `libgcc_s1-32bit`, `libstdc++6-32bit` |

2. Creates the unprivileged user **`theisle`** (home `/home/theisle`).
3. Copies the scripts to `/home/theisle/theisle-scripts`, creates `config/server.conf` with a random RCON password,
   and links `/usr/local/bin/isle-server`.
4. As `theisle`, installs SteamCMD (`~/steamcmd`) and the server (`~/theisle-server`), and copies
   `steamclient.so` to `~/.steam/sdk64/`.
5. Opens ports in **ufw** or **firewalld** if one is active.
6. Installs **`theisle-server.service`**, which is enabled at boot and restarts on failure, plus **`theisle-server-backup.timer`**, which runs daily at 05:00.
   It also adds a sudoers rule so `theisle` can start, stop and restart its own service.

Options:

```bash
sudo ./linux/install.sh --start              # start when done
sudo ./linux/install.sh --user isle --home /srv/isle
sudo ./linux/install.sh --branch ""          # public/Legacy branch
sudo ./linux/install.sh --no-firewall --no-service --no-sudoers --no-deps
sudo ./linux/install.sh --uninstall          # remove units/sudoers/firewall rules (keeps files)
```

Re-running the installer is safe. It keeps your `server.conf` and updates the scripts.

### Manual install (Linux, any glibc distro)

```bash
# 1. Install curl, tar, python3 and 32-bit glibc/libgcc/libstdc++ with your package manager.
# 2. As a normal (non-root) user:
git clone https://github.com/kyroskoh/the-isle-dedicated-server.git ~/theisle-scripts
cd ~/theisle-scripts
cp config/server.conf.example config/server.conf && nano config/server.conf
./linux/isle-server.sh install     # SteamCMD + server + ini files
./linux/isle-server.sh start       # background watchdog (no systemd needed)
./linux/isle-server.sh logs -f
```

Equivalent raw commands:

```bash
mkdir -p ~/steamcmd && cd ~/steamcmd
curl -sqL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxvf -
./steamcmd.sh +force_install_dir ~/theisle-server +login anonymous +app_update 412680 -beta evrima validate +quit
mkdir -p ~/.steam/sdk64 && cp ~/steamcmd/linux64/steamclient.so ~/.steam/sdk64/
# create ~/theisle-server/TheIsle/Saved/Config/LinuxServer/{Game,Engine}.ini
~/theisle-server/TheIsleServer.sh -Port=7777 -log
```

### Firewall (manual)

```bash
# ufw
sudo ufw allow 7777/udp && sudo ufw allow 7777/tcp && sudo ufw allow 10000/tcp
# firewalld
sudo firewall-cmd --permanent --add-port=7777/udp --add-port=7777/tcp --add-port=10000/tcp && sudo firewall-cmd --reload
# iptables
sudo iptables -A INPUT -p udp --dport 7777 -j ACCEPT
sudo iptables -A INPUT -p tcp -m multiport --dports 7777,10000 -j ACCEPT
```

Cloud providers (AWS, GCP, Azure, Oracle, Hetzner and others) also need matching security-group or firewall rules.

---

## Updating

- **Game:** the server updates itself on every start when `UPDATE_ON_START=true`, so a restart is enough.
  To update by hand: stop, then `update` (or `Update.bat`), then start.
- **These scripts:** `git pull` in your clone, then re-run the installer. Your `server.conf` is kept.

## Uninstalling

- **Windows:** `Install.ps1 -Uninstall`, then delete `C:\TheIsle`.
- **Linux:** `sudo ./linux/install.sh --uninstall`, then `sudo userdel -r theisle` and `sudo rm /usr/local/bin/isle-server`.

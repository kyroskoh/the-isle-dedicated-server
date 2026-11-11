<#
.SYNOPSIS
    The Isle (Evrima) dedicated server manager for Windows.

.DESCRIPTION
    Installs, updates, configures, starts, stops, backs up and monitors a
    The Isle Evrima dedicated server. Works with Windows PowerShell 5.1
    (Windows 10/11, Windows Server 2019/2022/2025) and PowerShell 7+.

    Settings are read from ..\config\server.conf (shared with the Linux scripts).

    The same commands work natively and with Docker Desktop. The runtime comes
    from -Runtime, else $env:ISLE_RUNTIME, else RUNTIME in server.conf.

.PARAMETER Command
    Install        Install prerequisites, SteamCMD, the server and generate config
    Update         Update server files through SteamCMD
    Validate       Update + verify every file (server must be stopped)
    Check          Validate server.conf (exit 1 on errors)
    Configure      Validate, then (re)generate Game.ini / Engine.ini
    Start          Start the server (scheduled-task service if installed, else a new window)
    Stop           Save (RCON) and stop the server
    Restart        Stop + Start
    Status         Show whether the server is running
    Run            Run the server in this window with an auto-restart watchdog
    Logs           Show a log: the game's own log (default) or Logs launcher|ui|list (add -Follow to tail it)
    Backup         Zip save data and config into BACKUP_DIR (+ second copy and off-site, 3-2-1)
                   Backup schedule [show|set "<cron>"|off], Backup status [--json], Backup tick (per-minute task)
    Restore        Restore a backup (-Path <.zip or .tar.gz>; both work in both runtimes)
    Rcon           Send an RCON command (-RconArgs 'announce','Hello')
    Save           Ask the server to save via RCON
    Firewall       Create Windows Firewall rules for the configured ports
    RemoveFirewall Remove the firewall rules
    InstallService Register a scheduled task that runs the server at boot
    RemoveService  Remove that scheduled task
    Admins         list|add|remove <SteamID64...>             (e.g. Admins add 7656119...)
    Whitelist      list|add|remove <SteamID64...>|on|off      (live via RCON when running)
                   lists and adds show Steam names (cached; list --refresh looks again)
    Steam          names [--refresh] <SteamID64...>           (resolve SteamID64s to Steam names)
    Classes        list|known|set|add|remove <Class...>|reset|preset [roster]
                   types | select|add-type|remove-type <type...> | humans [on|off]
    Mutations      list | enable <Name> [value] | disable <Name...> | reset
    Admin          players | player | dm <id> <text> | kick|ban <id> [reason] | announce <text> | save |
                   wipecorpses | details | queue | playables | pause|migrations|humans|chat|ai-learning|
                   netupdate on|off | growth on|off|<n> | custom "<command>"   (live over RCON)
    AIClasses      list|known|set|add|remove <Class...>|reset (disabled AI)
    AI             status|on|off|density <n>|interval <s>|preset <ai-name>  (AI spawning and density)
    Maps           list|show [name]|set <name> [--keep-branch]  (config\maps.txt; set also switches STEAM_BRANCH)
    Profile        list|show <name>|apply <name>              (whole play styles)
    Preset         list|show <name>|apply <name...>           (stackable tweaks)
    Plugins        list|search|info|install|remove|enable|disable|update|preset|run|config|sources
    Snapshot       create [--include LIST] [--output F] | restore F [--include LIST] [--overwrite]
                   [--all-settings] [--stop] | info F | list   (move/clone to any OS or runtime)
    UI             Web UI + REST API (OpenAPI docs at /docs). Options after UI:
                   --host H --port P --open --cert F --key F (see UI.md)
    UiToken        Show the web UI access token (UiToken --rotate replaces it)
    Info           Print resolved paths and settings
    Version        Print the script version

.PARAMETER Items
    Arguments for Admins, Whitelist, Classes, AIClasses, Profile, Preset and Plugins,
    e.g.  .\IsleServer.ps1 Whitelist add 76561198000000001
          .\IsleServer.ps1 Plugins install discord-notify

.PARAMETER Runtime
    Native or Docker. Overrides RUNTIME in server.conf for this command.

.EXAMPLE
    .\IsleServer.ps1 Install
    .\IsleServer.ps1 Start -Runtime Docker
    .\IsleServer.ps1 Start
    .\IsleServer.ps1 Logs -Follow
    .\IsleServer.ps1 Rcon -RconArgs announce,'Restart in 5 minutes'
    .\IsleServer.ps1 Profile apply realism
    .\IsleServer.ps1 Classes preset carnivores

.NOTES
    Made with love by Kyros Koh (https://github.com/kyroskoh). MIT licence.

.LINK
    https://github.com/kyroskoh/the-isle-dedicated-server
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Install', 'Update', 'Validate', 'Check', 'Configure', 'Start', 'Stop', 'Restart', 'Status', 'Run',
                 'Logs', 'Backup', 'Restore', 'Rcon', 'Save', 'Firewall', 'RemoveFirewall',
                 'InstallService', 'RemoveService', 'Info', 'Version', 'Help',
                 'Admins', 'Whitelist', 'Classes', 'AIClasses', 'Profile', 'Preset', 'Plugins', 'Snapshot', 'UI', 'UiToken', 'AI', 'Maps', 'Mutations', 'Admin', 'Steam')]
    [string]$Command = 'Help',

    [string]$ConfigPath,
    [string]$Path,
    [string[]]$RconArgs,
    [switch]$Follow,
    [ValidateSet('LocalService', 'System')]
    [string]$ServiceAccount = 'LocalService',
    [ValidateSet('Native', 'Docker')]
    [string]$Runtime,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Items
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 turns a native command's stderr into a terminating error under 'Stop'
# (e.g. "no such volume" from a probe). Every "docker" call goes through this wrapper instead.
function docker {
    $exe = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { throw 'docker is not installed' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $exe.Source @args } finally { $ErrorActionPreference = $prev }
}
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on 5.1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
if (-not $ConfigPath) {
    if ($env:ISLE_CONF) { $ConfigPath = $env:ISLE_CONF } else { $ConfigPath = Join-Path $RepoDir 'config\server.conf' }
}
$ProjectUrl = 'https://github.com/kyroskoh/the-isle-dedicated-server'
$Author = 'Kyros Koh'; $AuthorUrl = 'https://github.com/kyroskoh'
$ScriptVersion = 'unknown'
$versionFile = Join-Path $RepoDir 'VERSION'
if (Test-Path $versionFile) { $ScriptVersion = (Get-Content $versionFile | Select-Object -First 1).Trim() }
$TaskName = 'TheIsleServer'
$FirewallGroup = 'The Isle Dedicated Server'
$SteamCmdUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$VcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'

# ------------------------------------------------------------------ output --
function Write-Step([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Now).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $m) -ForegroundColor Cyan; Write-FileLog INFO $m }
function Write-Ok([string]$m)   { Write-Host "[ OK ] $m" -ForegroundColor Green; Write-FileLog OK $m }
function Write-Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow; Write-FileLog WARN $m }
function Fail([string]$m)       { Write-Host "[FAIL] $m" -ForegroundColor Red; Write-FileLog FAIL $m; exit 1 }

# ------------------------------------------------------------------- logs ---
# TIMEZONE=local|utc; every log file is KIND_yyyyMMdd_HHmmss.log in LOG_DIR (PRD LOG-01..05).
$script:LogToFile = $false
$script:LauncherLog = $null
$script:LogDir = $null
$LogNameRe = '^(?<kind>[a-z][a-z0-9-]*)_(?<stamp>\d{8}_\d{6})(_(?<n>\d+))?\.log$'
function Test-UtcClock { return @('utc', 'gmt', 'z') -contains ([string]$script:Cfg['TIMEZONE']).Trim().ToLowerInvariant() }
$Invariant = [Globalization.CultureInfo]::InvariantCulture   # ':' and '/' in .NET formats are culture-specific otherwise
function Get-Now { if ($script:Cfg -and (Test-UtcClock)) { return (Get-Date).ToUniversalTime() } return (Get-Date) }
function Get-Stamp { return (Get-Now).ToString('yyyyMMdd_HHmmss', $Invariant) }
function Get-ZoneLabel {
    if (Test-UtcClock) { return 'UTC' }
    $o = [TimeZoneInfo]::Local.GetUtcOffset((Get-Date))
    $sign = '+'; if ($o.Ticks -lt 0) { $sign = '-' }
    return ('UTC{0}{1:00}:{2:00}' -f $sign, [Math]::Abs($o.Hours), [Math]::Abs($o.Minutes))
}
function Get-LogFiles([string]$kind) {
    if (-not $script:LogDir -or -not (Test-Path $script:LogDir)) { return @() }
    $items = foreach ($f in Get-ChildItem -Path $script:LogDir -Filter "$kind`_*.log" -File) {
        if ($f.Name -match $LogNameRe -and $Matches.kind -eq $kind) {
            $n = 0; if ($Matches.ContainsKey('n')) { $n = [int]$Matches['n'] }   # StrictMode: absent group = absent key
            [pscustomobject]@{ Name = $f.Name; Key = ('{0}_{1:D6}' -f $Matches.stamp, $n); Stamp = $Matches.stamp; N = $n }
        }
    }
    return @($items | Sort-Object Key)
}
function Remove-OldLogs([string]$kind) {
    $keep = 0; [void][int]::TryParse((C 'LOG_RETENTION' '14'), [ref]$keep)
    if ($keep -le 0) { return }
    $all = @(Get-LogFiles $kind)   # @(): PS 5.1 unwraps a single result, and .Count on it throws under StrictMode
    if ($all.Count -gt $keep) { $all | Select-Object -First ($all.Count - $keep) | ForEach-Object { Remove-Item (Join-Path $script:LogDir $_.Name) -Force -ErrorAction SilentlyContinue } }
}
function Remove-OldGameLogs {
    $keep = 0; [void][int]::TryParse((C 'LOG_RETENTION' '14'), [ref]$keep)
    $dir = Join-Path $ServerDir 'TheIsle\Saved\Logs'
    if ($keep -le 0 -or -not (Test-Path $dir)) { return }
    Get-ChildItem -Path $dir -Filter 'TheIsle-backup-*.log' -File | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $keep | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}
function New-LogName([string]$kind) {
    $st = Get-Stamp
    $same = @(Get-LogFiles $kind | Where-Object { $_.Stamp -eq $st })
    if (-not $same.Count) { return (Join-Path $script:LogDir "$kind`_$st.log") }
    return (Join-Path $script:LogDir ('{0}_{1}_{2}.log' -f $kind, $st, (($same | Measure-Object -Property N -Maximum).Maximum + 1)))
}
function Get-LogFile([string]$kind) {
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    $max = 20; [void][int]::TryParse((C 'LOG_MAX_SIZE_MB' '20'), [ref]$max)
    $last = Get-LogFiles $kind | Select-Object -Last 1
    if ($last) {
        $path = Join-Path $script:LogDir $last.Name
        if ($max -le 0 -or (Get-Item $path).Length -lt ($max * 1MB)) { return $path }
    }
    $f = New-LogName $kind
    [IO.File]::WriteAllText($f, '')
    Remove-OldLogs $kind
    return $f
}
function Write-FileLog([string]$level, [string]$m) {
    if (-not $script:LogToFile) { return }
    try {
        $max = 20; [void][int]::TryParse((C 'LOG_MAX_SIZE_MB' '20'), [ref]$max)
        if (-not $script:LauncherLog -or ($max -gt 0 -and (Get-Item $script:LauncherLog).Length -ge ($max * 1MB))) { $script:LauncherLog = Get-LogFile 'launcher' }
        [IO.File]::AppendAllText($script:LauncherLog, ('[{0} {1}] {2,-4} {3}' -f (Get-Now).ToString('yyyy-MM-dd HH:mm:ss', $Invariant), (Get-ZoneLabel), $level, $m) + [Environment]::NewLine)
    } catch { $script:LogToFile = $false }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Admin([string]$what) {
    if (-not (Test-Admin)) { Fail "$what requires an elevated (Run as Administrator) PowerShell." }
}

# ------------------------------------------------------------------ config --
$Cfg = @{}
function Import-ServerConfig {
    if (-not (Test-Path $ConfigPath)) {
        $example = Join-Path $RepoDir 'config\server.conf.example'
        if (Test-Path $example) {
            Write-Warn "No $ConfigPath found - creating it from server.conf.example"
            Copy-Item $example $ConfigPath
        } else { Fail "Config file not found: $ConfigPath" }
    }
    foreach ($raw in [IO.File]::ReadAllLines($ConfigPath)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) { continue }
        $i = $line.IndexOf('=')
        $key = $line.Substring(0, $i).Trim()
        $val = $line.Substring($i + 1).Trim()
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') { $script:Cfg[$key] = $val }
    }
    $defaults = [ordered]@{
        STEAMCMD_DIR = 'C:\TheIsle\steamcmd'; SERVER_DIR = 'C:\TheIsle\server'; BACKUP_DIR = 'C:\TheIsle\backups'
        STEAM_APP_ID = '412680'; STEAM_BRANCH = 'evrima'; GAME_PORT = '7777'; QUEUE_PORT = '10000'; RCON_PORT = '8888'
        MAX_PLAYERS = '100'; MAP_NAME = 'Gateway'; SERVER_NAME = 'The Isle Evrima Server'; STOP_TIMEOUT = '60'
        BACKUP_RETENTION = '10'; UPDATE_ON_START = 'true'; VALIDATE_ON_UPDATE = 'false'; AUTO_RESTART = 'true'
        MANAGE_INI_FILES = 'true'; SAVE_BEFORE_STOP = 'true'; RCON_ENABLED = 'true'; QUEUE_ENABLED = 'true'
        EXTRA_ARGS = '-log'; RUNTIME = 'native'; DOCKER_BUILD = 'true'; DOCKER_IMAGE = 'theisle-server:latest'
        TIMEZONE = 'local'; LOG_RETENTION = '14'; LOG_MAX_SIZE_MB = '20'; BACKUP_SCHEDULE = '0 5 * * *'
    }
    $script:RawServerName = C 'SERVER_NAME'
    foreach ($k in $defaults.Keys) {
        if (-not $script:Cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($script:Cfg[$k])) { $script:Cfg[$k] = $defaults[$k] }
    }
    $script:SteamCmdDir = $script:Cfg.STEAMCMD_DIR
    $script:ServerDir = $script:Cfg.SERVER_DIR
    $script:BackupDir = $script:Cfg.BACKUP_DIR
    $script:IniDir = Join-Path $script:ServerDir 'TheIsle\Saved\Config\WindowsServer'
    $script:StateDir = Join-Path $script:ServerDir '.isle-scripts'
    $script:LogFile = Join-Path $script:ServerDir 'TheIsle\Saved\Logs\TheIsle.log'
    $script:LogDir = $env:ISLE_LOG_DIR
    if (-not $script:LogDir) { $script:LogDir = C 'LOG_DIR' (Join-Path $RepoDir 'logs') }
}
function C([string]$key, [string]$default = '') {
    if ($script:Cfg.ContainsKey($key) -and $script:Cfg[$key] -ne '') { return [string]$script:Cfg[$key] }
    return $default
}
function Test-True([string]$v) { return @('true', 'yes', '1', 'on') -contains $v.ToLowerInvariant() }
function UeBool([string]$v) { if (Test-True $v) { 'true' } else { 'false' } }

# Validate server.conf (PRD CFG-05). Prints every problem; returns $false on errors.
function Test-ServerConfig {
    $errors = New-Object 'Collections.Generic.List[string]'
    $warnings = New-Object 'Collections.Generic.List[string]'
    $portsOk = $true
    foreach ($k in 'GAME_PORT', 'QUEUE_PORT', 'RCON_PORT') {
        $v = C $k
        $n = 0
        if (-not ($v -match '^\d+$' -and [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535)) {
            $errors.Add("$k='$v' is not a port number (1-65535)"); $portsOk = $false
        }
    }
    if (@('local', 'utc') -notcontains (C 'TIMEZONE' 'local').ToLowerInvariant()) { $errors.Add("TIMEZONE='$(C 'TIMEZONE')' must be local or utc") }
    foreach ($k in 'LOG_RETENTION', 'LOG_MAX_SIZE_MB') {
        if ((C $k '0') -notmatch '^\d+$') { $errors.Add("$k='$(C $k)' must be a whole number (0 = no limit)") }
    }
    if (Get-Python) {
        $chk = Invoke-Cron @('check', (C 'BACKUP_SCHEDULE'))
        if ($chk.Code -ne 0) { $errors.Add("BACKUP_SCHEDULE: $($chk.Out)") }
    }
    $mapName = C 'MAP_NAME'
    if ($mapName -and (Test-Path (Join-Path $RepoDir 'config\maps.txt')) -and -not (Get-MapEntry $mapName)) {
        $warnings.Add("MAP_NAME='$mapName' is not in config\maps.txt (known: $((Get-MapEntries | ForEach-Object Name) -join ',')) - names are case-sensitive")
    }
    $v = C 'UI_PORT'
    $n = 0
    if ($v -and -not ($v -match '^\d+$' -and [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535)) {
        $errors.Add("UI_PORT='$v' is not a port number (1-65535)")
    }
    if ($portsOk) {
        if ((Test-True (C 'QUEUE_ENABLED')) -and (C 'GAME_PORT') -eq (C 'QUEUE_PORT')) { $errors.Add("GAME_PORT and QUEUE_PORT are both $(C 'GAME_PORT')") }
        if (Test-True (C 'RCON_ENABLED')) {
            if ((C 'RCON_PORT') -eq (C 'GAME_PORT')) { $errors.Add("RCON_PORT and GAME_PORT are both $(C 'RCON_PORT')") }
            if ((Test-True (C 'QUEUE_ENABLED')) -and (C 'RCON_PORT') -eq (C 'QUEUE_PORT')) { $errors.Add("RCON_PORT and QUEUE_PORT are both $(C 'RCON_PORT')") }
        }
    }
    $rt = Get-Runtime
    if (@('native', 'docker') -notcontains $rt) { $errors.Add("RUNTIME='$rt' must be native or docker") }
    foreach ($k in 'PUID', 'PGID') {
        $v = C $k
        if ($v -and $v -notmatch '^\d+$') { $errors.Add("$k='$v' must be a numeric id") }
    }
    $mp = C 'MAX_PLAYERS'
    $mpn = 0
    if (-not ($mp -match '^\d+$' -and [int]::TryParse($mp, [ref]$mpn) -and $mpn -gt 0)) { $errors.Add("MAX_PLAYERS='$mp' must be a positive integer") }
    $boolKeys = 'UPDATE_ON_START', 'VALIDATE_ON_UPDATE', 'FIREWALL_OPEN_RCON', 'WHITELIST_ENABLED', 'QUEUE_ENABLED',
        'RCON_ENABLED', 'GLOBAL_CHAT', 'ENABLE_HUMANS', 'DYNAMIC_WEATHER', 'ENABLE_MUTATIONS', 'ENABLE_DIETS',
        'ENABLE_PATROL_ZONES', 'ALLOW_RECORDING_REPLAY', 'SPAWN_PLANTS', 'SPAWN_AI', 'ENABLE_MIGRATION',
        'ENABLE_MASS_MIGRATION', 'MANAGE_INI_FILES', 'AUTO_RESTART', 'SAVE_BEFORE_STOP', 'DOCKER_BUILD',
        'REGION_SPAWNING', 'REGION_SPAWN_COOLDOWN', 'STEAM_NAME_LOOKUP'
    foreach ($k in $boolKeys) {
        $v = C $k
        if ($v -and (@('true', 'false', 'yes', 'no', '1', '0', 'on', 'off') -notcontains $v.ToLowerInvariant())) { $errors.Add("$k='$v' must be true or false") }
    }
    foreach ($k in 'GROWTH_MULTIPLIER', 'CORPSE_DECAY_MULTIPLIER', 'PLANT_SPAWN_MULTIPLIER', 'AI_DENSITY', 'DAY_LENGTH_MINUTES', 'NIGHT_LENGTH_MINUTES', 'WEATHER_MIN_INTERVAL', 'WEATHER_MAX_INTERVAL') {
        $v = C $k
        if ($v -and $v -notmatch '^\d+(\.\d+)?$') { $errors.Add("$k='$v' must be a number") }
    }
    foreach ($k in 'MAX_MIGRATION_TIME', 'MASS_MIGRATION_TIME', 'MASS_MIGRATION_DISABLE_TIME', 'STOP_TIMEOUT', 'BACKUP_RETENTION', 'REGION_SPAWN_COOLDOWN_SECONDS', 'NET_TICK_RATE', 'AI_SPAWN_INTERVAL', 'STEAM_NAME_CACHE_DAYS') {
        $v = C $k
        if ($v -and $v -notmatch '^\d+$') { $errors.Add("$k='$v' must be a whole number") }
    }
    if ((Test-True (C 'RCON_ENABLED')) -and -not (C 'RCON_PASSWORD')) { $errors.Add('RCON_ENABLED=true but RCON_PASSWORD is empty (set one, or RCON_ENABLED=false)') }
    if (-not (C 'EOS_CLIENT_ID') -or -not (C 'EOS_CLIENT_SECRET')) { $errors.Add('EOS_CLIENT_ID / EOS_CLIENT_SECRET are empty - the server will not be listed') }
    if (-not $script:RawServerName) { $warnings.Add("SERVER_NAME is empty - using '$(C 'SERVER_NAME')'") }
    foreach ($k in 'ADMIN_STEAM_IDS', 'WHITELIST_IDS') {
        foreach ($id in ((C $k) -split ',')) {
            $t = $id.Trim()
            if ($t -and $t -notmatch '^7656119\d{10}$') { $warnings.Add("$k entry '$t' is not a 17-digit SteamID64") }
        }
    }
    if ((Test-True (C 'WHITELIST_ENABLED' 'false')) -and -not (C 'WHITELIST_IDS')) { $warnings.Add('WHITELIST_ENABLED=true but WHITELIST_IDS is empty - nobody can join') }

    foreach ($w in $warnings) { Write-Warn "config: $w" }
    foreach ($e in $errors) { Write-Host "[FAIL] config: $e" -ForegroundColor Red }
    if ($errors.Count -gt 0) { Write-Host ("[FAIL] {0} error(s) in {1}" -f $errors.Count, $ConfigPath) -ForegroundColor Red; return $false }
    return $true
}
function Assert-ServerConfig {
    if (-not (Test-ServerConfig)) { throw 'Fix the configuration errors above, then try again' }
}

function Set-ConfigValue([string]$key, [string]$value) {
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($ConfigPath))
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ("^" + [regex]::Escape($key) + "=")) { $lines[$i] = "$key=$value"; $found = $true }
    }
    if (-not $found) { $lines.Add("$key=$value") }
    [IO.File]::WriteAllLines($ConfigPath, $lines)
    $script:Cfg[$key] = $value
}

# ----------------------------------------------------------- prerequisites --
function Enable-Tls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}
function Get-File([string]$url, [string]$dest) {
    Enable-Tls12
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

function Install-VcRedist {
    $key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    $installed = $false
    try { $installed = ((Get-ItemProperty -Path $key -Name Installed -ErrorAction Stop).Installed -eq 1) } catch { }
    if ($installed) { Write-Ok 'Visual C++ 2015-2022 x64 runtime present'; return }
    if (-not (Test-Admin)) { Write-Warn 'Visual C++ runtime missing - re-run as Administrator to install it.'; return }
    Write-Step 'Installing Visual C++ 2015-2022 x64 runtime'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'vc_redist.x64.exe'
    Get-File $VcRedistUrl $tmp
    $proc = Start-Process -FilePath $tmp -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if (@(0, 1638, 3010) -contains $proc.ExitCode) { Write-Ok 'Visual C++ runtime installed' }
    else { Write-Warn "vc_redist exited with code $($proc.ExitCode)" }
}

function Install-SteamCmd {
    $exe = Join-Path $SteamCmdDir 'steamcmd.exe'
    if (Test-Path $exe) { Write-Ok "SteamCMD present in $SteamCmdDir"; return }
    Write-Step "Installing SteamCMD into $SteamCmdDir"
    New-Item -ItemType Directory -Force -Path $SteamCmdDir | Out-Null
    $zip = Join-Path ([IO.Path]::GetTempPath()) 'steamcmd.zip'
    Get-File $SteamCmdUrl $zip
    Expand-Archive -Path $zip -DestinationPath $SteamCmdDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Ok 'SteamCMD installed'
}

function Invoke-SteamCmd([string[]]$arguments) {
    $exe = Join-Path $SteamCmdDir 'steamcmd.exe'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & $exe @arguments
        $rc = $LASTEXITCODE
        if ($rc -eq 0) { return }
        # SteamCMD frequently exits non-zero right after self-updating; retry.
        Write-Warn "SteamCMD exited with code $rc (attempt $attempt/3) - retrying in 5s"
        Start-Sleep -Seconds 5
    }
    throw 'SteamCMD update failed'
}

function Update-Server([switch]$Validate) {
    Install-SteamCmd
    New-Item -ItemType Directory -Force -Path $ServerDir | Out-Null
    $a = @('+force_install_dir', $ServerDir, '+login', 'anonymous', '+app_update', (C 'STEAM_APP_ID'))
    if (C 'STEAM_BRANCH') {
        $a += @('-beta', (C 'STEAM_BRANCH'))
        if (C 'STEAM_BRANCH_PASSWORD') { $a += @('-betapassword', (C 'STEAM_BRANCH_PASSWORD')) }
    }
    if ($Validate -or (Test-True (C 'VALIDATE_ON_UPDATE'))) { $a += 'validate' }
    $a += '+quit'
    Write-Step ("Updating The Isle server (app {0}, branch '{1}')" -f (C 'STEAM_APP_ID'), (C 'STEAM_BRANCH'))
    Invoke-SteamCmd $a
    if (-not (Get-ServerExe)) { throw "Server executable not found after update in $ServerDir" }
    Write-Ok 'Server files are up to date'
}

# ------------------------------------------------------------ ini files ----
function Add-IniList([Collections.Generic.List[string]]$out, [string]$key, [string]$csv) {
    foreach ($item in ($csv -split ',')) {
        $t = $item.Trim()
        if ($t) { $out.Add("$key=$t") }
    }
}

function Get-GameIni {
    $o = New-Object 'Collections.Generic.List[string]'
    $o.Add('[/Script/TheIsle.TIGameSession]')
    $o.Add("ServerName=$(C 'SERVER_NAME')")
    $o.Add("MapName=$(C 'MAP_NAME')")
    $o.Add("MaxPlayerCount=$(C 'MAX_PLAYERS')")
    if (C 'SERVER_PASSWORD') { $o.Add('bServerPassword=true'); $o.Add("ServerPassword=$(C 'SERVER_PASSWORD')") }
    else { $o.Add('bServerPassword=false'); $o.Add('ServerPassword=') }
    $o.Add("bQueueEnabled=$(UeBool (C 'QUEUE_ENABLED'))")
    $o.Add("QueuePort=$(C 'QUEUE_PORT')")
    $o.Add("bRconEnabled=$(UeBool (C 'RCON_ENABLED'))")
    $o.Add("RconPassword=$(C 'RCON_PASSWORD')")
    $o.Add("RconPort=$(C 'RCON_PORT')")
    $o.Add("bServerWhitelist=$(UeBool (C 'WHITELIST_ENABLED' 'false'))")
    $o.Add("bEnableGlobalChat=$(UeBool (C 'GLOBAL_CHAT' 'true'))")
    $o.Add("bEnableHumans=$(UeBool (C 'ENABLE_HUMANS' 'false'))")
    $o.Add("bServerDynamicWeather=$(UeBool (C 'DYNAMIC_WEATHER' 'true'))")
    $o.Add("ServerDayLengthMinutes=$(C 'DAY_LENGTH_MINUTES' '45')")
    $o.Add("ServerNightLengthMinutes=$(C 'NIGHT_LENGTH_MINUTES' '20')")
    $o.Add("GrowthMultiplier=$(C 'GROWTH_MULTIPLIER' '1')")
    $o.Add("CorpseDecayMultiplier=$(C 'CORPSE_DECAY_MULTIPLIER' '1')")
    $o.Add("bEnableMutations=$(UeBool (C 'ENABLE_MUTATIONS' 'true'))")
    foreach ($m in ((C 'ENABLED_MUTATIONS') -split ';')) {   # empty = every mutation (game default)
        if ($m.Trim()) { $i = $m.LastIndexOf(':'); $o.Add(('EnabledMutations={0}, {1}' -f $m.Substring(0, $i), $m.Substring($i + 1))) }
    }
    $o.Add("bEnableDiets=$(UeBool (C 'ENABLE_DIETS' 'true'))")
    $o.Add("bEnablePatrolZones=$(UeBool (C 'ENABLE_PATROL_ZONES' 'true'))")
    $o.Add("bAllowRecordingReplay=$(UeBool (C 'ALLOW_RECORDING_REPLAY' 'true'))")
    $o.Add("bSpawnPlants=$(UeBool (C 'SPAWN_PLANTS' 'true'))")
    $o.Add("PlantSpawnMultiplier=$(C 'PLANT_SPAWN_MULTIPLIER' '1')")
    $o.Add("bSpawnAI=$(UeBool (C 'SPAWN_AI' 'true'))")
    $o.Add("AIDensity=$(C 'AI_DENSITY' '1')")
    $o.Add("AISpawnInterval=$(C 'AI_SPAWN_INTERVAL' '40')")
    $o.Add("bEnableMigration=$(UeBool (C 'ENABLE_MIGRATION' 'true'))")
    $o.Add("MaxMigrationTime=$(C 'MAX_MIGRATION_TIME' '5400')")
    $o.Add("bEnableMassMigration=$(UeBool (C 'ENABLE_MASS_MIGRATION' 'true'))")
    $o.Add("MassMigrationTime=$(C 'MASS_MIGRATION_TIME' '43200')")
    $o.Add("MassMigrationDisableTime=$(C 'MASS_MIGRATION_DISABLE_TIME' '7200')")
    # Optional keys: only written when set (PRD CFX-03)
    if (C 'REGION_SPAWNING') { $o.Add("bUseRegionSpawning=$(UeBool (C 'REGION_SPAWNING'))") }
    if (C 'REGION_SPAWN_COOLDOWN') { $o.Add("bUseRegionSpawnCooldown=$(UeBool (C 'REGION_SPAWN_COOLDOWN'))") }
    if (C 'REGION_SPAWN_COOLDOWN_SECONDS') { $o.Add("RegionSpawnCooldownTimeSeconds=$(C 'REGION_SPAWN_COOLDOWN_SECONDS')") }
    if (C 'WEATHER_MIN_INTERVAL') { $o.Add("MinWeatherVariationInterval=$(C 'WEATHER_MIN_INTERVAL')") }
    if (C 'WEATHER_MAX_INTERVAL') { $o.Add("MaxWeatherVariationInterval=$(C 'WEATHER_MAX_INTERVAL')") }
    Add-IniList $o 'AllowedClasses' (C 'ALLOWED_CLASSES')
    Add-IniList $o 'DisallowedAIClasses' (C 'DISABLED_AI_CLASSES')
    Add-IniList $o 'AdminsSteamIDs' (C 'ADMIN_STEAM_IDS')
    Add-IniList $o 'WhitelistIDs' (C 'WHITELIST_IDS')
    foreach ($extra in ((C 'EXTRA_GAME_SESSION_SETTINGS') -split '\|')) { if ($extra.Trim()) { $o.Add($extra.Trim()) } }
    $o.Add('')
    $o.Add('[/Script/TheIsle.TIGameStateBase]')
    Add-IniList $o 'AdminsSteamIDs' (C 'ADMIN_STEAM_IDS')
    Add-IniList $o 'WhitelistIDs' (C 'WHITELIST_IDS')
    $o.Add('')
    $o.Add('[/Script/Engine.GameSession]')
    $o.Add("MaxPlayers=$(C 'MAX_PLAYERS')")
    return ($o -join "`r`n") + "`r`n"
}

function Get-EngineIni {
    $lines = @(
        '[EpicOnlineServices]',
        "DedicatedServerClientId=$(C 'EOS_CLIENT_ID')",
        "DedicatedServerClientSecret=$(C 'EOS_CLIENT_SECRET')",
        '',
        '[/Script/OnlineSubsystemUtils.IpNetDriver]',
        'MaxClientRate=100000',
        'MaxInternetClientRate=100000'
    )
    if (C 'NET_TICK_RATE') { $lines += "NetServerMaxTickRate=$(C 'NET_TICK_RATE')" }
    return ($lines -join "`r`n") + "`r`n"
}

function Write-IniFile([string]$file, [string]$content) {
    if ((Test-Path $file) -and ([IO.File]::ReadAllText($file) -ceq $content)) { return }
    if (Test-Path $file) { Copy-Item $file "$file.bak" -Force }
    [IO.File]::WriteAllText($file, $content, (New-Object Text.UTF8Encoding($false)))
    Write-Ok "Wrote $file"
}

function Set-ServerConfig([switch]$Force) {
    Assert-ServerConfig
    New-Item -ItemType Directory -Force -Path $IniDir | Out-Null
    $game = Join-Path $IniDir 'Game.ini'
    $engine = Join-Path $IniDir 'Engine.ini'
    $ovr = Get-OverridesDir
    $gameText = Merge-IniOverrides (Get-GameIni) (Join-Path $ovr 'Game.ini')
    $engineText = Merge-IniOverrides (Get-EngineIni) (Join-Path $ovr 'Engine.ini')
    if ($Force -or (Test-True (C 'MANAGE_INI_FILES'))) {
        Write-IniFile $game $gameText
        Write-IniFile $engine $engineText
    } else {
        if (-not (Test-Path $game)) { Write-IniFile $game $gameText }
        if (-not (Test-Path $engine)) { Write-IniFile $engine $engineText }
        Write-Step 'MANAGE_INI_FILES=false - existing .ini files left untouched'
    }
}

# --------------------------------------------------------------- process ---
function Get-ServerExe {
    foreach ($c in @((Join-Path $ServerDir 'TheIsle\Binaries\Win64\TheIsleServer-Win64-Shipping.exe'),
                     (Join-Path $ServerDir 'TheIsleServer.exe'))) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-ServerArgs {
    $a = @('TheIsle', "-Port=$(C 'GAME_PORT')")
    if (C 'MULTIHOME_IP') { $a += "-MultiHome=$(C 'MULTIHOME_IP')" }
    if (C 'EXTRA_ARGS') { $a += ((C 'EXTRA_ARGS') -split '\s+' | Where-Object { $_ }) }
    return $a
}

function Read-Pid([string]$name) {
    $f = Join-Path $StateDir $name
    if (Test-Path $f) { $v = (Get-Content $f -ErrorAction SilentlyContinue | Select-Object -First 1); if ($v -match '^\d+$') { return [int]$v } }
    return $null
}
function Get-AliveProcess($procId) {
    if (-not $procId) { return $null }
    return Get-Process -Id $procId -ErrorAction SilentlyContinue
}
function Get-ServerProcess {
    $p = Get-AliveProcess (Read-Pid 'server.pid')
    if ($p) { return $p }
    # Fall back to any shipping process running from our server directory.
    $exe = Get-ServerExe
    if (-not $exe) { return $null }
    return Get-Process -Name 'TheIsleServer-Win64-Shipping', 'TheIsleServer' -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Path -and $_.Path.StartsWith($ServerDir, [StringComparison]::OrdinalIgnoreCase) } catch { $false } } |
        Select-Object -First 1
}
function Test-TaskInstalled { return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) }

function Invoke-Run {
    if ((Test-True (C 'UPDATE_ON_START')) -or -not (Get-ServerExe)) {
        try { Update-Server } catch { if (-not (Get-ServerExe)) { throw } ; Write-Warn "Update failed - starting existing build: $_" }
    }
    Set-ServerConfig
    New-Item -ItemType Directory -Force -Path $StateDir, $script:LogDir | Out-Null
    foreach ($k in 'launcher', 'ui', 'server') { Remove-OldLogs $k }
    Remove-OldGameLogs
    $stopFlag = Join-Path $StateDir 'stop.flag'
    Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue
    Set-Content -Path (Join-Path $StateDir 'watchdog.pid') -Value $PID
    try {
        while ($true) {
            $exe = Get-ServerExe
            $argList = Get-ServerArgs
            Write-Step ("Launching: {0} {1}" -f $exe, ($argList -join ' '))
            $proc = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $ServerDir -NoNewWindow -PassThru
            $null = $proc.Handle   # cache the handle so ExitCode is available later
            Set-Content -Path (Join-Path $StateDir 'server.pid') -Value $proc.Id
            $proc.WaitForExit()
            $code = $proc.ExitCode
            Remove-Item (Join-Path $StateDir 'server.pid') -Force -ErrorAction SilentlyContinue
            if ((Test-Path $stopFlag) -or -not (Test-True (C 'AUTO_RESTART'))) { Write-Step "Server exited (code $code) - watchdog stopping"; break }
            Write-Warn "Server exited unexpectedly (code $code) - restarting in 10s"
            Start-Sleep -Seconds 10
            if (Test-Path $stopFlag) { break }
        }
    } finally {
        Remove-Item (Join-Path $StateDir 'watchdog.pid'), $stopFlag -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Start {
    if (Get-ServerProcess) { Write-Warn 'Server is already running'; return }
    Assert-ServerConfig
    if (Test-TaskInstalled) {
        Start-ScheduledTask -TaskName $TaskName
        Write-Ok "Scheduled task '$TaskName' started (server runs in the background)"
        return
    }
    $psExe = (Get-Process -Id $PID).Path
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $ScriptDir 'IsleServer.ps1')`" Run -ConfigPath `"$ConfigPath`""
    Start-Process -FilePath $psExe -ArgumentList $argLine -WindowStyle Minimized | Out-Null
    Write-Ok 'Server starting in a new (minimized) console window'
}

function Invoke-Save {
    if (-not (Test-True (C 'RCON_ENABLED')) -or -not (C 'RCON_PASSWORD')) { Write-Warn 'RCON disabled or no password - skipping save'; return }
    if (-not (Get-Python)) { Write-Warn 'Python 3 not found - skipping RCON save'; return }
    Write-Step 'Requesting world save via RCON'
    $rc = Invoke-PyRcon @('save')
    if ($rc -ne 0) { Write-Warn 'RCON save failed' } else { Start-Sleep -Seconds 5 }
}

function Invoke-Stop {
    $proc = Get-ServerProcess
    if (-not $proc -and -not (Get-AliveProcess (Read-Pid 'watchdog.pid'))) { Write-Warn 'Server is not running'; return }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Set-Content -Path (Join-Path $StateDir 'stop.flag') -Value 'stop'
    if ($proc -and (Test-True (C 'SAVE_BEFORE_STOP'))) { Invoke-Save }
    if ($proc) {
        $timeout = [int](C 'STOP_TIMEOUT' '60')
        Write-Step "Stopping server (PID $($proc.Id), timeout ${timeout}s)"
        $closed = $false
        try { $closed = $proc.CloseMainWindow() } catch { }
        $wait = 5
        if ($closed) { $wait = $timeout }
        if (-not $proc.WaitForExit($wait * 1000)) {
            # No console signal is available for a detached Windows process;
            # the RCON save above protects player data.
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(15000)
        }
    }
    if (Test-TaskInstalled) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
    $w = Get-AliveProcess (Read-Pid 'watchdog.pid')
    if ($w) { [void]$w.WaitForExit(15000); if (-not $w.HasExited) { Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue } }
    Remove-Item (Join-Path $StateDir 'server.pid'), (Join-Path $StateDir 'watchdog.pid') -Force -ErrorAction SilentlyContinue
    Write-Ok 'Server stopped'
}

function Show-Status {
    $p = Get-ServerProcess
    if ($p) {
        $mem = [Math]::Round($p.WorkingSet64 / 1MB)
        Write-Ok ("Running (PID {0}, {1} MB RAM, started {2})" -f $p.Id, $mem, $p.StartTime)
    } else { Write-Warn 'Not running' }
    if (Test-TaskInstalled) {
        $t = Get-ScheduledTask -TaskName $TaskName
        Write-Host ("Scheduled task '{0}': {1}" -f $TaskName, $t.State)
    }
    if (-not $p) { exit 3 }
}

function Show-Logs {
    $which = 'game'; if ($Items -and $Items.Count) { $which = $Items[0].ToLowerInvariant() }
    if ($which -eq 'list') {
        $(foreach ($k in 'launcher', 'server', 'ui') { Get-LogFiles $k }) | Sort-Object Key -Descending | ForEach-Object {
            Write-Host ('{0}  {1} bytes' -f $_.Name, (Get-Item (Join-Path $script:LogDir $_.Name)).Length) }
        return
    }
    if (@('game', 'launcher', 'server', 'ui') -notcontains $which) { Fail 'Usage: IsleServer.ps1 Logs [game|launcher|server|ui|list] [-Follow]' }
    $file = $LogFile
    if ($which -ne 'game') {
        $last = Get-LogFiles $which | Select-Object -Last 1
        $file = $null; if ($last) { $file = Join-Path $script:LogDir $last.Name }
    }
    if (-not $file -or -not (Test-Path $file)) { Fail "No $which log yet (looked in $LogFile and $script:LogDir)" }
    if ($Follow) { Get-Content -Path $file -Tail 100 -Wait } else { Get-Content -Path $file -Tail 200 }
}

# ------------------------------------------------------------------ RCON ---
function Invoke-PyRcon([string[]]$rconArgs) {
    $py = Get-Python
    if (-not $py) { return $null }
    $pyArgs = @()
    if ($py[1]) { $pyArgs += $py[1] }
    $pyArgs += @((Join-Path $RepoDir 'tools\isle_rcon.py'), '-p', (C 'RCON_PORT'))
    $pyArgs += $rconArgs
    $env:ISLE_RCON_PASSWORD = C 'RCON_PASSWORD'
    try { & $py[0] @pyArgs | ForEach-Object { Write-Host $_ } } finally { Remove-Item Env:\ISLE_RCON_PASSWORD -ErrorAction SilentlyContinue }
    return $LASTEXITCODE
}

function Get-Python {
    foreach ($c in @(@('py', '-3'), @('python', ''), @('python3', ''))) {
        $cmd = Get-Command $c[0] -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps\\python') { return @($cmd.Source, $c[1]) }
    }
    return $null
}
function Invoke-Rcon {
    if (-not $RconArgs -or $RconArgs.Count -eq 0) { Fail "Usage: IsleServer.ps1 Rcon -RconArgs <command>,[args]" }
    if (-not (Get-Python)) { Fail 'Python 3 is required for RCON (winget install Python.Python.3.12)' }
    $rc = Invoke-PyRcon $RconArgs
    exit $rc
}

# --------------------------------------------------------------- backups ---
function Invoke-Backup {
    $saved = Join-Path $ServerDir 'TheIsle\Saved'
    if (-not (Test-Path $saved)) { Fail "Nothing to back up ($saved does not exist)" }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    if ((Get-ServerProcess) -and (Test-True (C 'SAVE_BEFORE_STOP'))) { Invoke-Save }
    $stamp = Get-Stamp
    $stage = Join-Path ([IO.Path]::GetTempPath()) "theisle-backup-stage-$stamp"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        # robocopy copies files that the running server holds open (read-shared)
        & robocopy $saved (Join-Path $stage 'Saved') /E /R:1 /W:1 /XD Logs Crashes /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Fail "robocopy failed with code $LASTEXITCODE" }
        Copy-Item $ConfigPath (Join-Path $stage 'server.conf') -ErrorAction SilentlyContinue
        $zip = Join-Path $BackupDir "theisle-backup_$stamp.zip"
        Write-Step "Creating backup $zip"
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
        Write-Ok ("Backup written ({0:N1} MB)" -f ((Get-Item $zip).Length / 1MB))
        Invoke-Backup321 $zip
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $keep = [int](C 'BACKUP_RETENTION' '10')
    if ($keep -gt 0) {
        Get-ChildItem -Path $BackupDir -Filter 'theisle-*.zip' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $keep | ForEach-Object { Remove-Item $_.FullName -Force; Write-Step "Pruned $($_.Name)" }
    }
}

# ---------------------------------------------------- 3-2-1 and the schedule --
function Get-StateFile([string]$name) { return (Join-Path (Split-Path -Parent $ConfigPath) ".$name") }
function Invoke-Cron([string[]]$cronArgs) {
    $py = Get-Python
    if (-not $py) { throw 'Python 3 is required for backup schedules (winget install Python.Python.3.12)' }
    $a = @(); if ($py[1]) { $a += $py[1] }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $py[0] @($a + @((Join-Path $RepoDir 'tools\isle_cron.py'), '--conf', $ConfigPath) + $cronArgs) 2>&1 | ForEach-Object { "$_" }
        return @{ Code = $LASTEXITCODE; Out = (@($out) -join "`n") }
    } finally { $ErrorActionPreference = $prev }
}
function Invoke-Backup321([string]$file) {
    $copy = C 'BACKUP_COPY_DIR'
    if ($copy) {
        try {
            New-Item -ItemType Directory -Force -Path $copy | Out-Null
            Copy-Item -LiteralPath $file -Destination $copy -Force
            Write-Ok "Second copy: $(Join-Path $copy (Split-Path -Leaf $file))"
            if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($copy)) -eq [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($file))) {
                Write-Warn "BACKUP_COPY_DIR is on the same drive as the backups - use another disk for the '2 media' of 3-2-1"
            }
            $keep = [int](C 'BACKUP_RETENTION' '10')
            if ($keep -gt 0) {
                Get-ChildItem -Path $copy -Filter 'theisle-*' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep |
                    ForEach-Object { Remove-Item $_.FullName -Force }
            }
        } catch { Write-Warn "Could not copy the backup to BACKUP_COPY_DIR=$copy ($_)" }
    }
    $cmd = C 'BACKUP_OFFSITE_COMMAND'
    if ($cmd) {
        $cmd = $cmd.Replace('{file}', '"' + $file + '"')
        Write-Step "Off-site copy: $cmd"
        $env:BACKUP_FILE = $file
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & cmd.exe /d /c $cmd *>&1 | ForEach-Object { Write-Host "$_" }
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
        Set-Content -Path (Get-StateFile 'backup-offsite') -Value ('{0} {1} {2} {3}' -f (Get-Now).ToString('yyyy-MM-dd HH:mm:ss', $Invariant), (Get-ZoneLabel), $rc, (Split-Path -Leaf $file))
        if ($rc -eq 0) { Write-Ok 'Off-site copy done' } else { Write-Warn "Off-site copy failed (exit $rc) - the local backups are fine" }
    }
}
function Invoke-DockerBackup321 {
    if (-not ((C 'BACKUP_COPY_DIR') + (C 'BACKUP_OFFSITE_COMMAND'))) { return }
    $name = (Invoke-Dc @('run', '--rm', '--entrypoint', 'sh', 'theisle', '-c', 'ls -t /data/backups/theisle-*.tar.gz 2>/dev/null | head -n1') 2>$null | Select-Object -Last 1)
    if (-not "$name".Trim()) { Write-Warn 'No backup found in the volume for the second copy / off-site step'; return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('theisle-321-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $id = (Invoke-Dc @('ps', '-aq', 'theisle') | Select-Object -First 1)
        & docker cp ("{0}:{1}" -f "$id".Trim(), "$name".Trim()) $tmp *> $null
        $local = Join-Path $tmp (Split-Path -Leaf "$name".Trim())
        if (Test-Path $local) { Invoke-Backup321 $local } else { Write-Warn "Could not copy $name out of the volume" }
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
function Invoke-BackupTool {   # Backup schedule|status|tick
    $sub = $Items[0].ToLowerInvariant(); $rest = @($Items | Select-Object -Skip 1)
    switch ($sub) {
        'schedule' {
            $what = 'show'; if ($rest.Count) { $what = $rest[0].ToLowerInvariant() }
            switch ($what) {
                'show' {
                    $d = Invoke-Cron @('describe', (C 'BACKUP_SCHEDULE'))
                    Write-Host ("Schedule : {0}  ({1})" -f (C 'BACKUP_SCHEDULE'), $d.Out)
                    Write-Host 'Next     :'; (Invoke-Cron @('next', (C 'BACKUP_SCHEDULE'), '-n', '5')).Out -split "`n" | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" }
                }
                'set' {
                    if ($rest.Count -lt 2) { throw 'Usage: IsleServer.ps1 Backup schedule set "<minute hour day month weekday>"  e.g. "0 5 * * *", "0 */6 * * *", @daily' }
                    $chk = Invoke-Cron @('check', $rest[1])
                    if ($chk.Code -ne 0) { throw "Not a valid schedule: $($chk.Out)" }
                    Set-ConfigValue 'BACKUP_SCHEDULE' $rest[1]
                    Write-Ok ("Backups scheduled: {0} - next: {1}" -f $chk.Out, ((Invoke-Cron @('next', $rest[1], '-n', '1')).Out))
                }
                'off' { Set-ConfigValue 'BACKUP_SCHEDULE' 'off'; Write-Ok 'Scheduled backups are off (manual: IsleServer.ps1 Backup)' }
                default { throw 'Usage: IsleServer.ps1 Backup schedule [show|set "<cron>"|off]' }
            }
        }
        'tick' {
            $f = Get-StateFile 'backup-tick'
            $a = @('due', (C 'BACKUP_SCHEDULE'))
            if (Test-Path $f) { $a += @('--since', ((Get-Content $f -Raw).Trim())) }
            $r = Invoke-Cron $a
            if ($r.Code -ne 0) { return }
            Set-Content -Path $f -Value $r.Out.Trim()
            Write-Step "Scheduled backup ($($r.Out.Trim()), $(C 'BACKUP_SCHEDULE'))"
            & (Join-Path $ScriptDir 'IsleServer.ps1') Backup -ConfigPath $ConfigPath
        }
        'status' {
            $dir = $BackupDir
            $local = @(); if (Test-Path $dir) { $local = @(Get-ChildItem -Path $dir -Filter 'theisle-*' -File | Sort-Object LastWriteTime -Descending) }
            $copy = C 'BACKUP_COPY_DIR'; $nCopy = 0; $other = $false
            if ($copy -and (Test-Path $copy)) {
                $nCopy = @(Get-ChildItem -Path $copy -Filter 'theisle-*' -File).Count
                $other = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($copy)) -ne [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($dir))
            }
            $off = @(); if (C 'BACKUP_OFFSITE_COMMAND') { $off += 'command' }
            $en = Join-Path (Split-Path -Parent $ConfigPath) 'plugins\enabled.txt'
            if ((Test-Path $en) -and ((Get-Content $en) -contains 'offsite-backup')) { $off += 'offsite-backup plugin' }
            $offLast = ''; if (Test-Path (Get-StateFile 'backup-offsite')) { $offLast = (Get-Content (Get-StateFile 'backup-offsite') -Raw).Trim() }
            $copies = 1 + [int]($local.Count -gt 0) + [int]($nCopy -gt 0) + [int]($off.Count -gt 0)
            $media = 1; if ($other -or $off.Count) { $media = 2 }
            $last = $null; $age = $null
            if ($local.Count) { $last = $local[0].Name; $age = [int]((Get-Date) - $local[0].LastWriteTime).TotalSeconds }
            if ($rest -contains '--json') {
                $nx = (Invoke-Cron @('next', (C 'BACKUP_SCHEDULE'), '-n', '5', '--json')).Out | ConvertFrom-Json
                [ordered]@{ schedule = (C 'BACKUP_SCHEDULE'); describe = $nx.describe; zone = $nx.zone; next = @($nx.next)
                    last = [ordered]@{ file = $last; age_seconds = $age }; local = [ordered]@{ dir = $dir; count = $local.Count }
                    copy = [ordered]@{ dir = $copy; count = $nCopy; other_disk = $other }
                    offsite = [ordered]@{ configured = ($off -join '+'); last = $offLast }
                    rule321 = [ordered]@{ copies = $copies; media = $media; offsite = [bool]$off.Count; ok = ($copies -ge 3 -and $media -ge 2 -and $off.Count -gt 0) }
                } | ConvertTo-Json -Depth 4 -Compress | Write-Host
                return
            }
            $script:Items = @('schedule', 'show'); Invoke-BackupTool
            Write-Host ("Last     : {0}" -f $last)
            Write-Host ("Local    : {0} backups in {1}" -f $local.Count, $dir)
            if ($copy) { $where = 'SAME drive'; if ($other) { $where = 'another drive' }; Write-Host ("Copy 2   : {0} in {1} ({2})" -f $nCopy, $copy, $where) }
            $offText = 'not configured (BACKUP_OFFSITE_COMMAND or the offsite-backup plugin)'; if ($off.Count) { $offText = ($off -join '+') }
            if ($offLast) { $offText += " - last: $offLast" }
            Write-Host "Off-site : $offText"
            Write-Host ("3-2-1    : {0} copies, {1} media, off-site {2}" -f $copies, $media, [bool]$off.Count)
        }
    }
}

function Test-TarArchive([string]$file) { return ($file -match '\.(tar\.gz|tgz)$') }
function Expand-Backup([string]$file, [string]$dest) {
    # Native Windows backups are .zip; Linux/Docker backups are .tar.gz (tar.exe
    # ships with Windows 10 1803+ and Server 2019+).
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if (Test-TarArchive $file) {
        & tar -xzf $file -C $dest
        if ($LASTEXITCODE -ne 0) { throw "tar could not extract $file" }
    } else {
        Expand-Archive -Path $file -DestinationPath $dest
    }
    if (-not (Test-Path (Join-Path $dest 'Saved'))) { throw "$file does not contain a Saved folder - not a server backup?" }
}

function Invoke-Restore {
    if (-not $Path -or -not (Test-Path $Path)) { Fail 'Usage: IsleServer.ps1 Restore -Path <backup.zip | backup.tar.gz>' }
    if (Get-ServerProcess) { Fail 'Stop the server before restoring' }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("theisle-restore-" + [guid]::NewGuid())
    Expand-Backup (Resolve-Path $Path).Path $stage
    $saved = Join-Path $ServerDir 'TheIsle\Saved'
    New-Item -ItemType Directory -Force -Path (Join-Path $ServerDir 'TheIsle') | Out-Null
    if (Test-Path $saved) { Rename-Item $saved ("Saved.pre-restore_" + (Get-Stamp)) }
    Move-Item (Join-Path $stage 'Saved') $saved
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Restored $Path (previous data kept as Saved.pre-restore_*)"
}

# -------------------------------------------------------------- firewall ---
function Get-FirewallRuleSpecs {
    $specs = @(
        @{ Name = 'TheIsle-Game-UDP'; Port = (C 'GAME_PORT'); Proto = 'UDP' },
        @{ Name = 'TheIsle-Game-TCP'; Port = (C 'GAME_PORT'); Proto = 'TCP' },
        @{ Name = 'TheIsle-Queue-TCP'; Port = (C 'QUEUE_PORT'); Proto = 'TCP' }
    )
    if (Test-True (C 'FIREWALL_OPEN_RCON' 'false')) { $specs += @{ Name = 'TheIsle-RCON-TCP'; Port = (C 'RCON_PORT'); Proto = 'TCP' } }
    return $specs
}
function Set-Firewall {
    Assert-Admin 'Configuring the firewall'
    Remove-Firewall -Quiet
    foreach ($r in Get-FirewallRuleSpecs) {
        New-NetFirewallRule -DisplayName $r.Name -Group $FirewallGroup -Direction Inbound -Action Allow `
            -Protocol $r.Proto -LocalPort $r.Port -Profile Any | Out-Null
        Write-Ok ("Firewall: allow inbound {0}/{1}" -f $r.Port, $r.Proto)
    }
}
function Remove-Firewall([switch]$Quiet) {
    Assert-Admin 'Configuring the firewall'
    Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (-not $Quiet) { Write-Ok 'Firewall rules removed' }
}

# --------------------------------------------------------------- service ---
function Install-ServerService {
    Assert-Admin 'Installing the service'
    $root = Split-Path -Parent $ServerDir
    if ($ServiceAccount -eq 'LocalService') {
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount -RunLevel Limited
        # Give LOCAL SERVICE write access to the folders it needs.
        $dirs = @($ServerDir, $SteamCmdDir, $BackupDir, (Split-Path -Parent $ConfigPath)) | Select-Object -Unique
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            & icacls $d /grant '*S-1-5-19:(OI)(CI)M' /T /C /Q | Out-Null
        }
    } else {
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $psExe -WorkingDirectory $ScriptDir `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" Run -ConfigPath `"{1}`"" -f (Join-Path $ScriptDir 'IsleServer.ps1'), $ConfigPath)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Description 'The Isle (Evrima) dedicated server' -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Ok "Scheduled task '$TaskName' registered (runs at boot as $ServiceAccount, root $root)"

    Register-BackupTask $principal
}
# Per-minute task that runs "Backup tick": backs up when BACKUP_SCHEDULE (cron syntax) is due.
function Register-BackupTask($principal) {
    $backupTask = "$TaskName-Backup"
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $bAction = New-ScheduledTaskAction -Execute $psExe -WorkingDirectory $ScriptDir `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" Backup tick -ConfigPath `"{1}`"" -f (Join-Path $ScriptDir 'IsleServer.ps1'), $ConfigPath)
    $bTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
    $bSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $backupTask -Description 'The Isle server: backups on BACKUP_SCHEDULE (checked every minute)' -Action $bAction `
        -Trigger $bTrigger -Principal $principal -Settings $bSettings -Force | Out-Null
    Write-Ok "Scheduled task '$backupTask' registered: backups follow BACKUP_SCHEDULE ($(C 'BACKUP_SCHEDULE')). Change it with: IsleServer.ps1 Backup schedule set `"<cron>`""
}
function Remove-ServerService {
    Assert-Admin 'Removing the service'
    foreach ($t in @($TaskName, "$TaskName-Backup")) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-Ok "Removed scheduled task '$t'"
        }
    }
}

function Show-Info {
@"
Scripts       : v$ScriptVersion ($ProjectUrl)
Runtime       : native
Config file   : $ConfigPath
SteamCMD dir  : $SteamCmdDir
Server dir    : $ServerDir
Config (ini)  : $IniDir
Backup dir    : $BackupDir
App / branch  : $(C 'STEAM_APP_ID') / $(C 'STEAM_BRANCH')
Ports         : game $(C 'GAME_PORT')/udp, queue $(C 'QUEUE_PORT')/tcp, rcon $(C 'RCON_PORT')/tcp
Server name   : $(C 'SERVER_NAME')
Service task  : $(if (Test-TaskInstalled) { "$TaskName (installed)" } else { 'not installed' })
"@ | Write-Host
}

# ----------------------------------------------------------- docker mode ---
# RUNTIME=docker: the same commands drive the container defined in
# docker-compose.yml. The host server.conf is passed in as env_file and used
# for port interpolation, so one config file serves both runtimes.
function Get-Runtime {
    $r = $Runtime
    if (-not $r) { $r = $env:ISLE_RUNTIME }
    if (-not $r) { $r = C 'RUNTIME' 'native' }
    return $r.ToLowerInvariant()
}

function Initialize-RconPassword {
    if ((Test-True (C 'RCON_ENABLED')) -and -not (C 'RCON_PASSWORD')) {
        $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $bytes = New-Object byte[] 24; $rng.GetBytes($bytes)
        Set-ConfigValue 'RCON_PASSWORD' (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
        Write-Ok "Generated a random RCON password (saved in $ConfigPath)"
    }
}

function Assert-Docker {
    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "RUNTIME=docker but 'docker' was not found. Install Docker Desktop (https://docs.docker.com/desktop/) or set RUNTIME=native."
    }
    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose v2 ('docker compose') is required. Update Docker Desktop." }
    $os = (& docker info --format '{{.OSType}}' 2> $null)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot talk to the Docker engine. Start Docker Desktop and wait until it is running.' }
    if ("$os".Trim() -ne 'linux') { throw "Docker is in '$os' container mode. Switch Docker Desktop to Linux containers." }
    if (-not (Test-Path (Join-Path $RepoDir 'docker-compose.yml'))) { throw "docker-compose.yml not found in $RepoDir" }
}

# Always pass docker arguments as one array: a bare "--rm" would be parsed as a
# PowerShell parameter name. Docker output goes to the host, not the pipeline.
# Docker Compose would interpolate $VARS, collapse $$ and cut " #..." off values
# if it read server.conf directly. Write a compose-safe copy that holds exactly
# what the native parser sees (double-quoted, with \ \" $$ escaped).
function Get-ComposeEnvFile {
    $f = Join-Path (Split-Path -Parent $ConfigPath) '.compose.env'
    $lines = New-Object 'Collections.Generic.List[string]'
    $lines.Add("# Generated from $ConfigPath by IsleServer.ps1 - do not edit (rewritten on every docker command)")
    foreach ($k in ($script:Cfg.Keys | Sort-Object)) {
        $v = ([string]$script:Cfg[$k]).Replace('\', '\\').Replace('"', '\"').Replace('$', '$$')
        $lines.Add("$k=""$v""")
    }
    if (-not (Test-UtcClock)) {  # TIMEZONE=local: the container gets this PC's UTC offset as a POSIX TZ (no tzdata needed)
        $o = [TimeZoneInfo]::Local.GetUtcOffset((Get-Date))
        $sign = '+'; $posix = '-'; if ($o.Ticks -lt 0) { $sign = '-'; $posix = '+' }
        $lines.Add(('TZ="<{0}{1:00}{2:00}>{3}{1:00}:{2:00}"' -f $sign, [Math]::Abs($o.Hours), [Math]::Abs($o.Minutes), $posix))
    }
    [IO.File]::WriteAllLines($f, $lines)
    return $f
}

function Invoke-Dc([string[]]$DcArgs) {
    $envFile = Get-ComposeEnvFile
    $env:ISLE_CONF_FILE = $envFile
    $env:ISLE_OVERRIDES_DIR = Get-OverridesDir
    New-Item -ItemType Directory -Force -Path $env:ISLE_OVERRIDES_DIR | Out-Null
    $base = @('compose', '--project-directory', $RepoDir, '-f', (Join-Path $RepoDir 'docker-compose.yml'), '--env-file', $envFile)
    & docker @base @DcArgs | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
}
function Invoke-DcChecked([string[]]$DcArgs) {
    $rc = Invoke-Dc $DcArgs
    if ($rc -ne 0) { throw ("docker compose {0} failed (exit {1})" -f ($DcArgs -join ' '), $rc) }
}

function Test-DockerRunning {
    $envFile = Get-ComposeEnvFile
    $env:ISLE_CONF_FILE = $envFile
    $id = & docker compose --project-directory $RepoDir -f (Join-Path $RepoDir 'docker-compose.yml') --env-file $envFile ps --status running -q theisle 2> $null
    return [bool]("$id".Trim())
}
function Assert-DockerStopped([string]$what) {
    if (Test-DockerRunning) { throw "The container is running - stop it before you $what" }
}

function Get-NoBuildArgs {
    if (Test-True (C 'DOCKER_BUILD' 'true')) { return @() }
    return @('--no-build')
}

function Invoke-DockerImage {
    if (Test-True (C 'DOCKER_BUILD' 'true')) {
        Write-Step ("Building image {0} from {1}" -f (C 'DOCKER_IMAGE' 'theisle-server:latest'), $RepoDir)
        Invoke-DcChecked @('build')
    } else {
        & docker image inspect (C 'DOCKER_IMAGE' 'theisle-server:latest') *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Step ("Pulling image {0}" -f (C 'DOCKER_IMAGE'))
            Invoke-DcChecked @('pull')
        }
    }
}

function Show-DockerInfo {
    $state = 'unknown (docker not available)'
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'
    $ErrorActionPreference = 'Continue'
    if (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue) {
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            $envFile = Get-ComposeEnvFile
            $env:ISLE_CONF_FILE = $envFile
            $s = & docker compose --project-directory $RepoDir -f (Join-Path $RepoDir 'docker-compose.yml') --env-file $envFile ps -a --format '{{.State}} ({{.Status}})' theisle 2> $null | Select-Object -First 1
            if ("$s".Trim()) { $state = "$s".Trim() } else { $state = 'not created' }
        }
    }
    $src = 'prebuilt'
    if (Test-True (C 'DOCKER_BUILD' 'true')) { $src = 'built from this repo' }
@"
Scripts       : v$ScriptVersion ($ProjectUrl)
Runtime       : docker
Config file   : $ConfigPath (passed to the container)
Compose file  : $(Join-Path $RepoDir 'docker-compose.yml')
Image         : $(C 'DOCKER_IMAGE' 'theisle-server:latest') ($src)
Container     : theisle - $state
Data          : Docker volume theisle-data (mounted at /data)
Ports         : game $(C 'GAME_PORT')/udp+tcp, queue $(C 'QUEUE_PORT')/tcp, rcon 127.0.0.1:$(C 'RCON_PORT')/tcp
Server name   : $(C 'SERVER_NAME')
"@ | Write-Host
}

function Invoke-DockerCommand([string]$cmd) {
    switch ($cmd) {
        'Check' { if (Test-ServerConfig) { Write-Ok "Configuration OK ($ConfigPath, runtime docker)"; return } else { exit 1 } }
        'Info'  { Show-DockerInfo; return }
        'InstallService' {
            Write-Warn 'RUNTIME=docker: no server task is needed. The container uses restart: unless-stopped.'
            Write-Warn "Enable 'Start Docker Desktop when you sign in' in Docker Desktop settings so it starts with Windows."
            Register-BackupTask (New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive)
            return
        }
        'RemoveService' { Remove-ServerService; return }
    }
    Assert-Docker
    $nb = @(Get-NoBuildArgs)
    switch ($cmd) {
        'Install' {
            Initialize-RconPassword; Assert-ServerConfig
            Invoke-DockerImage
            Invoke-DcChecked (@('up', '--no-start') + $nb)
            Write-Ok 'Install complete (Docker). The game downloads on first start: .\IsleServer.ps1 Start'
        }
        { $_ -in 'Update', 'Validate' } {
            Assert-DockerStopped $cmd.ToLowerInvariant(); Assert-ServerConfig
            Invoke-DockerImage
            Invoke-DcChecked @('run', '--rm', 'theisle', $cmd.ToLowerInvariant())
            Invoke-Hooks 'post-update'
        }
        'Configure' { Assert-ServerConfig; Invoke-DcChecked @('run', '--rm', 'theisle', 'configure') }
        'Start' {
            Initialize-RconPassword; Assert-ServerConfig
            Invoke-DcChecked (@('up', '-d') + $nb)
            Write-Ok 'Container started - follow the startup with: .\IsleServer.ps1 Logs -Follow'
            Invoke-Hooks 'post-start'
        }
        'Stop' {
            if (Test-DockerRunning) { Invoke-Hooks 'pre-stop' }
            Invoke-DcChecked @('stop'); Write-Ok 'Container stopped'
            Invoke-Hooks 'post-stop'
        }
        'Restart' {
            if (Test-DockerRunning) { Invoke-Hooks 'pre-stop' }
            Invoke-DcChecked @('stop')
            Invoke-Hooks 'post-stop'
            Initialize-RconPassword; Assert-ServerConfig
            Invoke-DcChecked (@('up', '-d') + $nb)
            Write-Ok 'Container restarted'
            Invoke-Hooks 'post-start'
        }
        'Status' {
            if (Test-DockerRunning) { $rc = Invoke-Dc @('exec', '-T', 'theisle', 'isle-server', 'status'); exit $rc }
            Write-Warn 'Not running (container stopped or not created)'; exit 3
        }
        'Run' { Initialize-RconPassword; Assert-ServerConfig; [void](Invoke-Dc (@('up') + $nb)) }
        'Logs' {
            if ($Follow) { [void](Invoke-Dc @('logs', '--tail', '100', '-f', 'theisle')) } else { [void](Invoke-Dc @('logs', '--tail', '200', 'theisle')) }
        }
        'Backup' {
            if (Test-DockerRunning) { Invoke-DcChecked @('exec', '-T', 'theisle', 'isle-server', 'backup') }
            else { Invoke-DcChecked @('run', '--rm', 'theisle', 'backup') }
            Invoke-DockerBackup321
            Invoke-Hooks 'post-backup'
        }
        'Restore' {
            if (-not $Path) { throw 'Usage: IsleServer.ps1 Restore -Path <backup.tar.gz | name in /data/backups>' }
            Assert-DockerStopped 'restore'
            if (Test-Path $Path) {
                $file = (Resolve-Path $Path).Path
                if (-not (Test-TarArchive $file)) {
                    # A native Windows .zip backup: repack as .tar.gz for the Linux container.
                    $stage = Join-Path ([IO.Path]::GetTempPath()) ("theisle-repack-" + [guid]::NewGuid())
                    Expand-Backup $file $stage
                    $file = Join-Path ([IO.Path]::GetTempPath()) (([IO.Path]::GetFileNameWithoutExtension($file)) + '.tar.gz')
                    & tar -czf $file -C $stage Saved
                    if ($LASTEXITCODE -ne 0) { throw 'tar could not repack the backup' }
                    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Ok "Repacked the .zip backup as $file"
                }
                $name = Split-Path -Leaf $file
                Invoke-DcChecked (@('up', '--no-start') + $nb)
                # A one-off run lets the entrypoint create the /data layout (fresh volume).
                Invoke-DcChecked @('run', '--rm', 'theisle', 'check')
                Invoke-DcChecked @('cp', $file, "theisle:/data/backups/$name")
                $target = "/data/backups/$name"
            } elseif ($Path.StartsWith('/data/')) { $target = $Path }
            else { $target = "/data/backups/$Path" }
            Invoke-DcChecked @('run', '--rm', 'theisle', 'restore', $target)
        }
        { $_ -in 'Rcon', 'Save' } {
            if (-not (Test-DockerRunning)) { throw 'The container is not running' }
            $extra = @()
            if ($cmd -eq 'Rcon') {
                if (-not $RconArgs -or $RconArgs.Count -eq 0) { throw 'Usage: IsleServer.ps1 Rcon -RconArgs <command>,[args]' }
                $extra = $RconArgs
            }
            $rc = Invoke-Dc (@('exec', '-T', 'theisle', 'isle-server', $cmd.ToLowerInvariant()) + $extra)
            exit $rc
        }
    }
}

# ----------------------------------------------------------- ini overrides --
# config\overrides\{Game,Engine}.ini are merged into the generated files
# (PRD CFX-01): a Key=Value replaces every generated line of that key in that
# section, new keys/sections are appended, +/-/! lines pass through unchanged.
function Get-OverridesDir {
    $d = C 'INI_OVERRIDES_DIR'
    if ($d) { return $d }
    return (Join-Path (Split-Path -Parent $ConfigPath) 'overrides')
}
function Merge-IniOverrides([string]$content, [string]$overrideFile) {
    if (-not (Test-Path $overrideFile)) { return $content }
    $order = New-Object 'Collections.Generic.List[string]'
    $lines = @{}
    $replace = @{}
    $sec = ''
    foreach ($raw in [IO.File]::ReadAllLines($overrideFile)) {
        $l = $raw.Trim()
        if (-not $l -or $l.StartsWith(';') -or $l.StartsWith('#')) { continue }
        if ($l -match '^\[.*\]$') {
            $sec = $l
            if (-not $lines.ContainsKey($sec)) { $lines[$sec] = New-Object 'Collections.Generic.List[string]'; $order.Add($sec) }
            continue
        }
        if (-not $sec) { continue }
        $passThrough = $l -match '^[+!-]'
        if (-not $l.Contains('=') -and -not $passThrough) { continue }
        $lines[$sec].Add($l)
        if (-not $passThrough) { $replace[$sec + '|' + $l.Split('=')[0].Trim().ToLowerInvariant()] = $true }
    }
    $out = New-Object 'Collections.Generic.List[string]'
    $done = @{}
    $cur = ''
    foreach ($raw in ($content -split "`r?`n")) {
        $l = $raw.Trim()
        if ($l -match '^\[.*\]$') {
            if ($cur -and $lines.ContainsKey($cur) -and -not $done.ContainsKey($cur)) { foreach ($x in $lines[$cur]) { $out.Add($x) }; $done[$cur] = $true }
            $cur = $l; $out.Add($raw); continue
        }
        if ($cur -and $l -and -not $l.StartsWith(';') -and $l.Contains('=') -and
            $replace.ContainsKey($cur + '|' + $l.Split('=')[0].Trim().ToLowerInvariant())) { continue }
        $out.Add($raw)
    }
    if ($cur -and $lines.ContainsKey($cur) -and -not $done.ContainsKey($cur)) { foreach ($x in $lines[$cur]) { $out.Add($x) }; $done[$cur] = $true }
    foreach ($s in $order) {
        if (-not $done.ContainsKey($s)) { $out.Add(''); $out.Add($s); foreach ($x in $lines[$s]) { $out.Add($x) } }
    }
    Write-Step "Merged overrides from $overrideFile"
    return (($out -join "`r`n").TrimEnd() + "`r`n")
}

# ------------------------------------------------------- list editing -------
# Admins / whitelist / rosters (PRD CFX-06..08): edit the host server.conf and
# push live changes through RCON when the server is running.
function Get-ListValues([string]$key) { return @((C $key) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Set-ListValues([string]$key, [string[]]$values) {
    $seen = @{}; $unique = New-Object 'Collections.Generic.List[string]'
    foreach ($v in $values) {
        $t = "$v".Trim()
        if ($t -and -not $seen.ContainsKey($t.ToLowerInvariant())) { $seen[$t.ToLowerInvariant()] = $true; $unique.Add($t) }
    }
    Set-ConfigValue $key ($unique -join ',')
    return $unique.ToArray()   # callers wrap the result in @() (a comma here would nest the array)
}
function Assert-SteamIds([string[]]$ids) {
    foreach ($i in $ids) { if ($i -notmatch '^7656119\d{10}$') { throw "'$i' is not a SteamID64 (17 digits starting with 7656119)" } }
}
function Get-ClassEntries([string]$section) {   # [{Name, Types}] - diet and traits from classes.txt
    $file = Join-Path $RepoDir 'config\classes.txt'
    if (-not (Test-Path $file)) { return @() }
    $on = $false
    $out = foreach ($line in [IO.File]::ReadAllLines($file)) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $on = ($Matches[1] -eq $section); continue }
        if ($on -and $t -and -not $t.StartsWith('#')) {
            $f = $t -split '\s+'
            [pscustomobject]@{ Name = $f[0]; Types = @($f | Select-Object -Skip 1 | ForEach-Object { $_.ToLowerInvariant() }) }
        }
    }
    return @($out)
}
# -------------------------------------------------------------- mutations --
function Get-MutationEntries {
    $file = Join-Path $RepoDir 'config\mutations.txt'
    if (-not (Test-Path $file)) { return @() }
    $out = foreach ($line in [IO.File]::ReadAllLines($file)) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $f = $line -split "`t"
        $flag = ''; if ($f.Count -gt 2) { $flag = $f[2] }
        [pscustomobject]@{ Name = $f[0]; Default = $f[1]; Fixed = ($flag -eq 'fixed') }
    }
    return @($out)
}
function Invoke-MutationsCommand {
    $sub = 'list'; $rest = @()
    if ($Items -and $Items.Count -gt 0) { $sub = $Items[0].ToLowerInvariant(); $rest = @($Items | Select-Object -Skip 1) }
    $all = Get-MutationEntries
    $cur = C 'ENABLED_MUTATIONS'
    $map = [ordered]@{}
    foreach ($e in ($cur -split ';')) { if ($e.Trim()) { $i = $e.LastIndexOf(':'); $map[$e.Substring(0, $i)] = $e.Substring($i + 1) } }
    switch ($sub) {
        'list' {
            if (-not $cur) { Write-Host "All mutations are available (ENABLED_MUTATIONS is empty - the game default).`n" }
            foreach ($m in $all) {
                $state = 'off'; $val = '-'
                if (-not $cur) { $state = 'on'; $val = $m.Default } elseif ($map.Contains($m.Name)) { $state = 'on'; $val = $map[$m.Name] }
                $note = ''; if ($m.Fixed) { $note = '(value must be 1)' }
                Write-Host ('  {0,-3} {1,-34} {2,-6} {3}' -f $state, $m.Name, $val, $note)
            }
        }
        { $_ -in 'enable', 'disable' } {
            if (-not $rest.Count) { throw "Usage: IsleServer.ps1 Mutations $sub <Name> ...   (see: Mutations list)" }
            if (-not $cur) { foreach ($m in $all) { $map[$m.Name] = $m.Default } }
            if ($sub -eq 'enable') {
                $m = $all | Where-Object { $_.Name -eq $rest[0] } | Select-Object -First 1
                if (-not $m) { throw "Unknown mutation '$($rest[0])' (see: Mutations list)" }
                $val = $m.Default; if ($rest.Count -gt 1) { $val = $rest[1] }
                if ($val -notmatch '^\d+(\.\d+)?$') { throw "The value must be a number, e.g. $($m.Default)" }
                if ($m.Fixed -and $val -ne '1') { throw "$($m.Name) only takes 1 (leave it out to disable it)" }
                if ($val -ne $m.Default) { Write-Warn "$($m.Name): $val differs from the default $($m.Default) - changed values may produce unstable gameplay" }
                $map[$m.Name] = $val
                Write-Ok "Mutation $($m.Name) enabled ($val)"
            } else {
                foreach ($n in $rest) {
                    $m = $all | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                    if (-not $m) { throw "Unknown mutation '$n' (see: Mutations list)" }
                    $map.Remove($m.Name); Write-Ok "Mutation $($m.Name) disabled"
                }
                if (-not $map.Count) { throw 'Disabling every mutation: set ENABLE_MUTATIONS=false instead' }
            }
            Set-ConfigValue 'ENABLED_MUTATIONS' ((@($map.Keys | ForEach-Object { "${_}:$($map[$_])" })) -join ';')
            Write-Step "$($map.Count) of $($all.Count) mutations available - restart the server to apply"
        }
        'reset' { Set-ConfigValue 'ENABLED_MUTATIONS' ''; Write-Ok 'Every mutation is available again (game default) - restart to apply' }
        default { throw 'Usage: IsleServer.ps1 Mutations list|enable <Name> [value]|disable <Name...>|reset' }
    }
}
# ------------------------------------------------------------------ admin --
function Invoke-RconNow([string[]]$rconArgs) {
    if (-not (Test-True (C 'RCON_ENABLED')) -or -not (C 'RCON_PASSWORD')) { throw 'RCON is disabled or has no password (RCON_ENABLED, RCON_PASSWORD)' }
    if ((Get-Runtime) -eq 'docker') {
        if (-not (Test-DockerRunning)) { throw 'The server is not running' }
        $rc = Invoke-Dc (@('exec', '-T', 'theisle', 'isle-server', 'rcon') + $rconArgs)
    } else {
        if (-not (Get-Python)) { throw 'Python 3 is required for RCON' }
        $rc = Invoke-PyRcon $rconArgs
    }
    if ($rc -ne 0) { throw "RCON $($rconArgs[0]) failed (is the server running?)" }
}
function Invoke-AdminCommand {
    if (-not $Items -or -not $Items.Count) {
        throw "Usage: IsleServer.ps1 Admin players|player|dm|kick|ban|announce|save|wipecorpses|details|queue|playables|pause|migrations|humans|chat|ai-learning|netupdate on|off|growth on|off|<n>|custom <cmd>`nNote: Evrima's RCON has no commands to change a player's size, skin or mutations, give god mode, teleport or heal - in-game admins (ADMIN_STEAM_IDS) use the game's own admin panel for those."
    }
    $sub = $Items[0].ToLowerInvariant(); $rest = @($Items | Select-Object -Skip 1)
    $toggles = @{ pause = 'pause'; migrations = 'togglemigrations'; humans = 'togglehumans'; chat = 'toggleglobalchat'; 'ai-learning' = 'toggleailearning'; netupdate = 'togglenetupdate' }
    $persist = @{ migrations = 'ENABLE_MIGRATION'; humans = 'ENABLE_HUMANS'; chat = 'GLOBAL_CHAT' }
    $simple = @{ players = 'playerlist'; details = 'serverdetails'; queue = 'queuestatus'; playables = 'getplayables'; save = 'save'; wipecorpses = 'wipecorpses' }
    if ($simple.ContainsKey($sub)) { Invoke-RconNow @($simple[$sub]); return }
    switch ($sub) {
        'player' { Invoke-RconNow (@('playerdata') + $rest) }
        'announce' { if (-not $rest.Count) { throw 'Usage: IsleServer.ps1 Admin announce <text>' }; Invoke-RconNow @('announce', ($rest -join ' ')) }
        { $_ -in 'dm', 'kick', 'ban' } {
            if (-not $rest.Count -or $rest[0] -notmatch '^7656119\d{10}$') { throw "Usage: IsleServer.ps1 Admin $sub <SteamID64> [text]" }
            $text = ($rest | Select-Object -Skip 1) -join ' '
            if ($sub -eq 'dm') { if (-not $text) { throw 'Usage: IsleServer.ps1 Admin dm <SteamID64> <text>' }; Invoke-RconNow @('directmessage', "$($rest[0]),$text") }
            else { if (-not $text) { $text = 'Removed by an admin' }; Invoke-RconNow @($sub, "$($rest[0]),$text"); Write-Ok "${sub}: $($rest[0])" }
        }
        { $toggles.ContainsKey($_) } {
            if (-not $rest.Count -or @('on', 'off') -notcontains $rest[0].ToLowerInvariant()) { throw "Usage: IsleServer.ps1 Admin $sub on|off" }
            $on = $rest[0].ToLowerInvariant() -eq 'on'; $bit = '0'; if ($on) { $bit = '1' }
            Invoke-RconNow @($toggles[$sub], $bit)
            if ($persist.ContainsKey($sub)) { Set-ConfigValue $persist[$sub] ($on.ToString().ToLowerInvariant()) }
            Write-Ok "$sub $($rest[0])"
        }
        'growth' {
            if (-not $rest.Count) { throw 'Usage: IsleServer.ps1 Admin growth on|off|<multiplier e.g. 1.5>' }
            $a = $rest[0].ToLowerInvariant()
            if ($a -in 'on', 'off') { $bit = '0'; if ($a -eq 'on') { $bit = '1' }; Invoke-RconNow @('togglegrowthmultiplier', $bit); Write-Ok "Growth multiplier $a" }
            elseif ($a -match '^\d+(\.\d+)?$') { Invoke-RconNow @('setgrowthmultiplier', $a); Set-ConfigValue 'GROWTH_MULTIPLIER' $a; Write-Ok "Growth multiplier $a (live and in server.conf)" }
            else { throw 'Usage: IsleServer.ps1 Admin growth on|off|<multiplier e.g. 1.5>' }
        }
        'custom' {
            if (-not $rest.Count) { throw 'Usage: IsleServer.ps1 Admin custom "<command>"  (experimental: the game may ignore it)' }
            Write-Warn 'custom RCON commands are experimental - the game may ignore them'
            Invoke-RconNow @('custom', ($rest -join ' '))
        }
        default { $script:Items = @(); Invoke-AdminCommand }
    }
}
function Get-KnownClasses([string]$section) {
    $file = Join-Path $RepoDir 'config\classes.txt'
    if (-not (Test-Path $file)) { return @() }
    $on = $false; $names = @()
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $on = ($Matches[1] -eq $section); continue }
        if ($on -and $t -and -not $t.StartsWith('#')) { $names += ($t -split '\s+')[0] }
    }
    return $names
}
function Assert-ClassNames([string]$section, [string[]]$names) {
    $known = @(Get-KnownClasses $section)
    foreach ($n in $names) {
        if ($n -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "'$n' is not a valid class name" }
        if ($known.Count -and -not ($known | Where-Object { $_ -ieq $n })) {
            Write-Warn "'$n' is not in config\classes.txt - keeping it anyway (new or renamed species?)"
        }
    }
}
function Edit-List([string]$key, [string]$op, [string[]]$items) {
    $cur = @(Get-ListValues $key)
    switch ($op) {
        'set'    { return Set-ListValues $key $items }
        'add'    { return Set-ListValues $key ($cur + $items) }
        'remove' { return Set-ListValues $key @($cur | Where-Object { $v = $_; -not ($items | Where-Object { $_ -ieq $v }) }) }
    }
}
function Send-LiveRcon([string[]]$rconArgs) {
    if (-not (Test-True (C 'RCON_ENABLED')) -or -not (C 'RCON_PASSWORD')) { Write-Step 'RCON disabled - the change applies on the next restart'; return }
    if ((Get-Runtime) -eq 'docker') {
        if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue) -or -not (Test-DockerRunning)) { Write-Step 'Server not running - the change applies on the next start'; return }
        $rc = Invoke-Dc (@('exec', '-T', 'theisle', 'isle-server', 'rcon') + $rconArgs)
    } else {
        if (-not (Get-ServerProcess)) { Write-Step 'Server not running - the change applies on the next start'; return }
        if (-not (Get-Python)) { Write-Warn 'Python 3 missing - the change applies on the next restart'; return }
        $rc = Invoke-PyRcon $rconArgs
    }
    if ($rc -eq 0) { Write-Ok "Applied live via RCON ($($rconArgs[0]))" } else { Write-Warn 'Live RCON update failed - the change applies on the next restart' }
}
# SteamID64 -> Steam name via tools/isle_steam.py (cached; STEAM_NAME_LOOKUP, STEAM_WEB_API_KEY). Never throws.
function Get-SteamNames([string[]]$ids, [switch]$Refresh) {
    $names = @{}
    if (-not $ids -or $ids.Count -eq 0) { return $names }
    $py = Get-Python
    if (-not $py) { return $names }
    $a = @(); if ($py[1]) { $a += $py[1] }
    $a += @((Join-Path $RepoDir 'tools\isle_steam.py'), '--conf', $ConfigPath, 'names', '--json')
    if ($Refresh) { $a += '--refresh' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = (& $py[0] @($a + $ids) 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $out) {
            $obj = $out | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { if ($p.Value.name) { $names[$p.Name] = [string]$p.Value.name } }
        }
    } catch { Write-Verbose "Steam name lookup failed: $_" } finally { $ErrorActionPreference = $prev }
    return $names
}
function Show-SteamIds([string[]]$ids, [string]$empty, [string]$indent = '', [switch]$Refresh) {
    $ids = @($ids | Where-Object { $_ })
    if ($ids.Count -eq 0) { Write-Host $empty; return }
    $names = Get-SteamNames $ids -Refresh:$Refresh
    foreach ($id in $ids) {
        $n = '(name unknown)'; if ($names.ContainsKey($id)) { $n = $names[$id] }
        Write-Host "$indent$id  $n"
    }
}
function Show-List([string]$key, [string]$empty) {
    $v = @(Get-ListValues $key)
    if ($v.Count -eq 0) { Write-Host $empty } else { $v | ForEach-Object { Write-Host $_ } }
}
function Invoke-ListCommand([string]$kind) {
    $sub = 'list'; $rest = @()
    if ($Items -and $Items.Count -gt 0) { $sub = $Items[0].ToLowerInvariant(); $rest = @($Items | Select-Object -Skip 1) }
    switch ($kind) {
        'Admins' {
            switch ($sub) {
                'list' { Show-SteamIds @(Get-ListValues 'ADMIN_STEAM_IDS') '(no admins)' -Refresh:($rest -contains '--refresh') }
                { $_ -in 'add', 'remove' } {
                    if ($rest.Count -eq 0) { throw "Usage: IsleServer.ps1 Admins $sub <SteamID64> [...]" }
                    Assert-SteamIds $rest
                    $v = @(Edit-List 'ADMIN_STEAM_IDS' $sub $rest)
                    Write-Ok "Admins: $($v.Count) - restart the server to apply (the game reads admins at start)"
                    if ($sub -eq 'add') { Show-SteamIds $rest '' '  ' }
                }
                default { throw 'Usage: IsleServer.ps1 Admins list|add|remove <SteamID64> [...]' }
            }
        }
        'Whitelist' {
            switch ($sub) {
                'list' {
                    $state = 'OFF'; if (Test-True (C 'WHITELIST_ENABLED' 'false')) { $state = 'ON' }
                    Write-Host "Whitelist is $state"; Show-SteamIds @(Get-ListValues 'WHITELIST_IDS') '(no whitelisted players)' -Refresh:($rest -contains '--refresh')
                }
                { $_ -in 'add', 'remove' } {
                    if ($rest.Count -eq 0) { throw "Usage: IsleServer.ps1 Whitelist $sub <SteamID64> [...]" }
                    Assert-SteamIds $rest
                    $v = @(Edit-List 'WHITELIST_IDS' $sub $rest)
                    Write-Ok "Whitelist: $($v.Count) player(s)"
                    if ($sub -eq 'add') { Show-SteamIds $rest '' '  ' }
                    $verb = 'removewhitelist'; if ($sub -eq 'add') { $verb = 'addwhitelist' }
                    Send-LiveRcon @($verb, ($rest -join ','))
                }
                { $_ -in 'on', 'off' } {
                    $was = Test-True (C 'WHITELIST_ENABLED' 'false'); $want = ($sub -eq 'on')
                    Set-ConfigValue 'WHITELIST_ENABLED' ($want.ToString().ToLowerInvariant())
                    Write-Ok "Whitelist turned $sub"
                    if ($was -ne $want) { Send-LiveRcon @('togglewhitelist') }
                    if ($want -and -not (C 'WHITELIST_IDS')) { Write-Warn 'The whitelist is empty - nobody can join' }
                }
                default { throw 'Usage: IsleServer.ps1 Whitelist list|add|remove <SteamID64> [...]|on|off' }
            }
        }
        { $_ -in 'Classes', 'AIClasses' } {
            $key = 'ALLOWED_CLASSES'; $section = 'playable'; $rcmd = 'updateplayables'; $label = 'Classes'
            if ($kind -eq 'AIClasses') { $key = 'DISABLED_AI_CLASSES'; $section = 'ai'; $rcmd = 'disableaiclasses'; $label = 'AIClasses' }
            $v = $null
            switch ($sub) {
                'list' { $e = '(none disabled)'; if ($section -eq 'playable') { $e = '(all classes allowed)' }; Show-List $key $e; return }
                'known' { Get-KnownClasses $section | ForEach-Object { Write-Host $_ }; return }
                'types' {
                    Write-Host "Types ($section):"
                    $t = [ordered]@{}
                    foreach ($c in Get-ClassEntries $section) { foreach ($ty in $c.Types) { if (-not $t.Contains($ty)) { $t[$ty] = @() }; $t[$ty] += $c.Name } }
                    foreach ($k in ($t.Keys | Sort-Object)) { Write-Host ('  {0,-10} {1}' -f $k, ($t[$k] -join ', ')) }
                    if ($section -eq 'playable') { Write-Host "`n  Humans are not a class: IsleServer.ps1 Classes humans on|off (ENABLE_HUMANS, live via RCON).`n  Eggs/hatchlings are not a class either and have no server setting." }
                    return
                }
                { $_ -in 'select', 'add-type', 'remove-type' } {
                    if ($rest.Count -eq 0) { throw "Usage: IsleServer.ps1 $label $sub <type> [...] (see: $label types)" }
                    $want = @($rest | ForEach-Object { $_.ToLowerInvariant() })
                    $match = @(Get-ClassEntries $section | Where-Object { @($_.Types | Where-Object { $want -contains $_ }).Count } | ForEach-Object Name)
                    if (-not $match.Count) { throw "No $section class has type: $($rest -join ' ') (see: $label types)" }
                    if ($sub -eq 'select') { $v = @(Edit-List $key 'set' $match) }
                    elseif ($sub -eq 'add-type') { $v = @(Edit-List $key 'add' $match) }
                    else {
                        $base = @((C $key) -split ',' | Where-Object { $_ })
                        if (-not $base.Count -and $section -eq 'playable') { $base = @(Get-KnownClasses $section) }
                        $keep = @($base | Where-Object { $match -notcontains $_ })
                        if (-not $keep.Count) { throw 'That would leave no playable class' }
                        $v = @(Edit-List $key 'set' $keep)
                    }
                }
                'humans' {
                    if ($section -ne 'playable') { throw 'Usage: IsleServer.ps1 Classes humans [on|off]' }
                    if (-not $rest.Count) { Write-Host "Humans: $(C 'ENABLE_HUMANS' 'false')"; return }
                    if (@('on', 'off') -notcontains $rest[0].ToLowerInvariant()) { throw 'Usage: IsleServer.ps1 Classes humans [on|off]' }
                    $on = $rest[0].ToLowerInvariant() -eq 'on'
                    Set-ConfigValue 'ENABLE_HUMANS' ($on.ToString().ToLowerInvariant()); Write-Ok "Humans $($rest[0])"
                    $bit = '0'; if ($on) { $bit = '1' }
                    Send-LiveRcon @('togglehumans', $bit); return
                }
                { $_ -in 'set', 'add', 'remove' } {
                    if ($rest.Count -eq 0) { throw "Usage: IsleServer.ps1 $label $sub <Class> [...]" }
                    Assert-ClassNames $section $rest
                    $v = @(Edit-List $key $sub $rest)
                }
                'reset' { Set-ConfigValue $key ''; $v = @() }
                'preset' {
                    if ($section -ne 'playable') { throw 'Roster presets are for the playable roster (Classes)' }
                    $dir = Join-Path $RepoDir 'config\rosters'
                    if ($rest.Count -eq 0) {
                        Get-ChildItem $dir -Filter *.txt | ForEach-Object {
                            $d = ((Get-Content $_.FullName -TotalCount 1) -replace '^# Roster: \S+ - ', '')
                            Write-Host ('  {0,-12} {1}' -f $_.BaseName, $d)
                        }
                        return
                    }
                    $file = Join-Path $dir ($rest[0] + '.txt')
                    if (-not (Test-Path $file)) { throw "Unknown roster '$($rest[0])' (see: IsleServer.ps1 Classes preset)" }
                    $names = @([IO.File]::ReadAllLines($file) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
                    if ($names.Count) { Assert-ClassNames 'playable' $names; $v = @(Edit-List $key 'set' $names) } else { Set-ConfigValue $key ''; $v = @() }
                }
                default { throw "Usage: IsleServer.ps1 $label list|known|set|add|remove <Class> [...]|reset|preset [name]" }
            }
            if ($v.Count -eq 0) {
                if ($section -eq 'playable') { Write-Ok "$($label): all classes allowed - restart the server to apply" } else { Write-Ok "$($label): none disabled" }
            } else {
                Write-Ok ("$($label): " + ($v -join ','))
                Send-LiveRcon @($rcmd, ($v -join ','))
            }
        }
    }
}

# ------------------------------------------------------ profiles / presets --
function Get-OverlayDescription([string]$file) { return ((Get-Content $file -TotalCount 1) -replace '^# [A-Za-z]+: \S+ - ', '') }
# ------------------------------------------------------------------- maps ---
function Get-MapEntries {
    $file = Join-Path $RepoDir 'config\maps.txt'
    if (-not (Test-Path $file)) { return @() }
    $out = foreach ($line in [IO.File]::ReadAllLines($file)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $f = $t -split '\s+', 4
        $desc = ''; if ($f.Count -gt 3) { $desc = $f[3] }
        [pscustomobject]@{ Name = $f[0]; Branch = $f[1]; Status = $f[2]; Description = $desc }
    }
    return @($out)
}
function Get-MapEntry([string]$name) { return (Get-MapEntries | Where-Object { $_.Name -ceq $name } | Select-Object -First 1) }
function Invoke-MapsCommand {
    $sub = 'list'; $rest = @()
    if ($Items -and $Items.Count -gt 0) { $sub = $Items[0].ToLowerInvariant(); $rest = @($Items | Select-Object -Skip 1) }
    $cur = C 'MAP_NAME'
    $known = (Get-MapEntries | ForEach-Object Name) -join ' '
    switch ($sub) {
        'list' {
            foreach ($m in Get-MapEntries) {
                $mark = ' '; if ($m.Name -ceq $cur) { $mark = '*' }
                Write-Host ('{0} {1,-12} {2,-18} {3,-9} {4}' -f $mark, $m.Name, $m.Branch, $m.Status, $m.Description)
            }
            Write-Host ''; Write-Host "  * = current (MAP_NAME=$cur, STEAM_BRANCH=$(C 'STEAM_BRANCH'))"
        }
        'show' {
            $name = $cur; if ($rest.Count) { $name = $rest[0] }
            $m = Get-MapEntry $name
            if (-not $m) { throw "Unknown map '$name' (known: $known)" }
            Write-Host ("Map          : {0}`nSteam branch : {1}`nStatus       : {2}`nAbout        : {3}" -f $m.Name, $m.Branch, $m.Status, $m.Description)
        }
        'set' {
            if (-not $rest.Count) { throw 'Usage: IsleServer.ps1 Maps set <name> [--keep-branch]' }
            $m = Get-MapEntry $rest[0]
            if (-not $m) { throw "Unknown map '$($rest[0])' (known: $known). Names are case-sensitive; add new maps to config\maps.txt" }
            Set-ConfigValue 'MAP_NAME' $m.Name
            if ($rest -notcontains '--keep-branch' -and $m.Branch -ne '-' -and $m.Branch -ne (C 'STEAM_BRANCH')) {
                Set-ConfigValue 'STEAM_BRANCH' $m.Branch
                Write-Ok "Map set to $($m.Name) and Steam branch to $($m.Branch)"
                Write-Warn 'Different branch: stop the server, then run IsleServer.ps1 Validate to download that build before starting'
            } else { Write-Ok "Map set to $($m.Name)" }
            if ($m.Status -eq 'archived') { Write-Warn "$($m.Name) is an archived build: it receives no updates or new species" }
            Write-Step 'Restart the server to load the new map'
        }
        default { throw 'Usage: IsleServer.ps1 Maps list|show [name]|set <name> [--keep-branch]' }
    }
}

# --------------------------------------------------------------------- AI ---
function Invoke-AICommand {
    $sub = 'status'; $rest = @()
    if ($Items -and $Items.Count -gt 0) { $sub = $Items[0].ToLowerInvariant(); $rest = @($Items | Select-Object -Skip 1) }
    switch ($sub) {
        'status' {
            $dis = C 'DISABLED_AI_CLASSES'; if (-not $dis) { $dis = '(none - every AI class spawns)' }
            Write-Host ("Spawn AI       : {0}`nDensity        : {1}`nSpawn interval : {2} s`nDisabled       : {3}" -f (C 'SPAWN_AI' 'true'), (C 'AI_DENSITY' '1'), (C 'AI_SPAWN_INTERVAL' '40'), $dis)
        }
        { $_ -in 'on', 'off' } {
            $v = 'false'; if ($sub -eq 'on') { $v = 'true' }
            Set-ConfigValue 'SPAWN_AI' $v
            Write-Ok "AI spawning $sub - applied on the next restart"
        }
        'density' {
            if (-not $rest.Count -or $rest[0] -notmatch '^\d+(\.\d+)?$') { throw 'Usage: IsleServer.ps1 AI density <number>, e.g. 0.5 (half), 1 (default), 2 (double)' }
            Set-ConfigValue 'AI_DENSITY' $rest[0]
            Write-Ok "AI density $($rest[0])"
            Send-LiveRcon @('aidensity', $rest[0])
        }
        'interval' {
            if (-not $rest.Count -or $rest[0] -notmatch '^\d+$' -or [int]$rest[0] -lt 1) { throw 'Usage: IsleServer.ps1 AI interval <seconds>, e.g. 40 (default)' }
            Set-ConfigValue 'AI_SPAWN_INTERVAL' $rest[0]
            Write-Ok "AI spawn interval $($rest[0])s - applied on the next restart"
        }
        'preset' {
            if (-not $rest.Count -or -not $rest[0].StartsWith('ai-')) { throw 'Usage: IsleServer.ps1 AI preset <ai-name> (see: IsleServer.ps1 Preset list)' }
            $script:Items = @('apply', $rest[0])
            Invoke-OverlayCommand 'Preset'
        }
        default { throw 'Usage: IsleServer.ps1 AI status|on|off|density <n>|interval <s>|preset <ai-name>' }
    }
}

function Invoke-OverlayCommand([string]$kind) {
    $dir = Join-Path $RepoDir ("config\" + $kind.ToLowerInvariant() + 's')
    $sub = 'list'; $rest = @()
    if ($Items -and $Items.Count -gt 0) { $sub = $Items[0].ToLowerInvariant(); $rest = @($Items | Select-Object -Skip 1) }
    switch ($sub) {
        'list' { Get-ChildItem $dir -Filter *.conf | ForEach-Object { Write-Host ('  {0,-18} {1}' -f $_.BaseName, (Get-OverlayDescription $_.FullName)) } }
        'show' {
            if ($rest.Count -eq 0 -or -not (Test-Path (Join-Path $dir ($rest[0] + '.conf')))) { throw "Usage: IsleServer.ps1 $kind show <name>" }
            $file = Join-Path $dir ($rest[0] + '.conf')
            Write-Host ("{0}: {1}" -f $rest[0], (Get-OverlayDescription $file))
            foreach ($line in [IO.File]::ReadAllLines($file)) {
                if ($line -match '^\s*([A-Z_][A-Z0-9_]*)=(.*)$') {
                    $now = C $Matches[1] '(empty)'; $new = $Matches[2]; if (-not $new) { $new = '(empty)' }
                    Write-Host ('  {0,-28} {1} -> {2}' -f $Matches[1], $now, $new)
                }
            }
        }
        'apply' {
            if ($rest.Count -eq 0) { throw "Usage: IsleServer.ps1 $kind apply <name>" }
            if ($kind -eq 'Profile' -and $rest.Count -gt 1) { throw 'Apply one profile at a time (combine presets with: IsleServer.ps1 Preset apply a b c)' }
            $files = foreach ($n in $rest) {
                $f = Join-Path $dir ($n + '.conf')
                if (-not (Test-Path $f)) { throw "Unknown $($kind.ToLowerInvariant()) '$n' (see: IsleServer.ps1 $kind list)" }
                $f
            }
            $backup = "$ConfigPath.bak_" + (Get-Stamp)
            Copy-Item $ConfigPath $backup
            foreach ($f in $files) {
                foreach ($line in [IO.File]::ReadAllLines($f)) {
                    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)=(.*)$') { Set-ConfigValue $Matches[1] ($Matches[2].Trim().Trim('"')) }
                }
            }
            $script:Cfg = @{}; Import-ServerConfig
            if (Test-ServerConfig) {
                Write-Ok ("Applied " + ($rest -join ' ') + " (previous config saved as $backup)")
                Write-Step 'Restart the server to apply: IsleServer.ps1 Restart'
            } else {
                Copy-Item $backup $ConfigPath -Force
                throw "The result did not validate - server.conf was restored from $backup"
            }
        }
        default { throw "Usage: IsleServer.ps1 $kind list|show <name>|apply <name>" }
    }
}

# ------------------------------------------------------------------ plugins --
function Invoke-Python([string[]]$pyArgs) {
    $py = Get-Python
    if (-not $py) { throw 'Python 3 is required for plugins (winget install Python.Python.3.12)' }
    $a = @(); if ($py[1]) { $a += $py[1] }
    # Windows PowerShell 5.1 turns native stderr (e.g. a Python warning) into a terminating error under 'Stop'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & $py[0] @($a + $pyArgs) 2>&1 | ForEach-Object { Write-Host "$_" }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
}
function Invoke-Plugins([string[]]$pluginArgs) {
    $base = @((Join-Path $RepoDir 'tools\isle_plugins.py'), '--conf', $ConfigPath,
              '--launcher', (Join-Path $ScriptDir 'IsleServer.ps1'), '--runtime', (Get-Runtime))
    return Invoke-Python ($base + $pluginArgs)
}
function Invoke-Hooks([string]$hookEvent) {
    $enabled = Join-Path (Split-Path -Parent $ConfigPath) 'plugins\enabled.txt'
    if (-not (Test-Path $enabled) -or -not ((Get-Content $enabled) -join '').Trim()) { return }
    if (-not (Get-Python)) { Write-Warn 'Python 3 missing - plugin hooks skipped'; return }
    try { if ((Invoke-Plugins @('hook', $hookEvent)) -ne 0) { Write-Warn "A plugin hook for $hookEvent failed" } }
    catch { Write-Warn "Plugin hooks for $hookEvent failed: $_" }
}
function Invoke-ConfigTool([string]$cmd) {
    switch ($cmd) {
        { $_ -in 'Admins', 'Whitelist', 'Classes', 'AIClasses' } { Invoke-ListCommand $cmd; return $true }
        { $_ -in 'Profile', 'Preset' } { Invoke-OverlayCommand $cmd; return $true }
        'Maps' { Invoke-MapsCommand; return $true }
        'Mutations' { Invoke-MutationsCommand; return $true }
        'Admin' { Invoke-AdminCommand; return $true }
        'Steam' {
            $rest = @($Items | Select-Object -Skip 1)
            if (-not $Items -or $Items[0] -ne 'names' -or -not @($rest | Where-Object { $_ -ne '--refresh' }).Count) { throw 'Usage: IsleServer.ps1 Steam names [--refresh] <SteamID64...>' }
            $ids = @($rest | Where-Object { $_ -ne '--refresh' }); Assert-SteamIds $ids
            Show-SteamIds $ids '' -Refresh:($rest -contains '--refresh'); return $true
        }
        'Backup' {
            if ($Items -and $Items.Count -and @('schedule', 'status', 'tick') -contains $Items[0].ToLowerInvariant()) { Invoke-BackupTool; return $true }
            return $false
        }
        'AI' { Invoke-AICommand; return $true }
        'Plugins' {
            $a = @('list'); if ($Items -and $Items.Count) { $a = $Items }
            $rc = Invoke-Plugins $a
            exit $rc
        }
        'Snapshot' {
            $a = @('list'); if ($Items -and $Items.Count) { $a = $Items }
            $base = @((Join-Path $RepoDir 'tools\isle_snapshot.py'), '--conf', $ConfigPath, '--runtime', (Get-Runtime),
                      '--launcher', (Join-Path $ScriptDir 'IsleServer.ps1'), '--server-dir', $ServerDir,
                      '--backup-dir', $BackupDir, '--overrides-dir', (Get-OverridesDir))
            $rc = Invoke-Python ($base + $a)
            exit $rc
        }
        { $_ -in 'UI', 'UiToken' } {
            $base = @((Join-Path $RepoDir 'tools\isle_api.py'), '--conf', $ConfigPath, '--runtime', (Get-Runtime),
                      '--launcher', (Join-Path $ScriptDir 'IsleServer.ps1'))
            $a = @(); if ($Items) { $a = @($Items) }
            if ($cmd -eq 'UiToken') {
                if ($a -contains '--rotate') { $a = @('--rotate-token'); Write-Warn 'Restart the web UI (TheIsleServer-UI task) to use the new token' }
                else { $a = @('--print-token') }
            }
            $rc = Invoke-Python ($base + $a)
            exit $rc
        }
    }
    return $false
}

# ------------------------------------------------------------------ main ---
function Show-Credits { Write-Host "Project: $ProjectUrl"; Write-Host ("Made with " + [char]0x2665 + " by $Author ($AuthorUrl)") }
if ($Command -eq 'Help') { Get-Help $MyInvocation.MyCommand.Path -Detailed; Show-Credits; exit 0 }
if ($Command -eq 'Version') { Write-Host "IsleServer.ps1 $ScriptVersion"; Show-Credits; exit 0 }
Import-ServerConfig
if (@('Status', 'Info', 'Logs', 'Check', 'Version', 'Help', 'UI', 'UiToken') -notcontains $Command) {
    $script:LogToFile = $true
    $first = ''; if ($Items -and $Items.Count) { $first = $Items[0] }   # only the first argument: values may be secrets
    Write-FileLog CMD "$Command $first"
}

try {
    $rt = Get-Runtime
    if (@('native', 'docker') -contains $rt -and (Invoke-ConfigTool $Command)) { exit 0 }
    if ($rt -eq 'docker' -and @('Firewall', 'RemoveFirewall') -notcontains $Command) {
        Invoke-DockerCommand $Command
        exit 0
    }
    if ($rt -ne 'native') { [void](Test-ServerConfig); Fail "Unknown runtime '$rt' (use native or docker)" }
    switch ($Command) {
        'Install' {
            Install-VcRedist
            Initialize-RconPassword
            if (Get-ServerProcess) { Fail 'Stop the server before installing/updating' }
            Assert-ServerConfig
            Update-Server
            Set-ServerConfig
            Write-Ok "Install complete. Start with: .\IsleServer.ps1 Start"
        }
        'Update'         { if (Get-ServerProcess) { Fail 'Stop the server before updating' }; Update-Server; Invoke-Hooks 'post-update' }
        'Validate'       { if (Get-ServerProcess) { Fail 'Stop the server before validating' }; Update-Server -Validate; Invoke-Hooks 'post-update' }
        'Check'          { if (Test-ServerConfig) { Write-Ok "Configuration OK ($ConfigPath)" } else { exit 1 } }
        'Configure'      { Set-ServerConfig -Force }
        'Start'          { Invoke-Start; Invoke-Hooks 'post-start' }
        'Stop'           { if (Get-ServerProcess) { Invoke-Hooks 'pre-stop' }; Invoke-Stop; Invoke-Hooks 'post-stop' }
        'Restart'        { if (Get-ServerProcess) { Invoke-Hooks 'pre-stop' }; Invoke-Stop; Invoke-Hooks 'post-stop'; Start-Sleep -Seconds 2; Invoke-Start; Invoke-Hooks 'post-start' }
        'Status'         { Show-Status }
        'Run'            { Invoke-Run }
        'Logs'           { Show-Logs }
        'Backup'         { Invoke-Backup; Invoke-Hooks 'post-backup' }
        'Restore'        { Invoke-Restore }
        'Rcon'           { Invoke-Rcon }
        'Save'           { Invoke-Save }
        'Firewall'       { Set-Firewall }
        'RemoveFirewall' { Remove-Firewall }
        'InstallService' { Install-ServerService }
        'RemoveService'  { Remove-ServerService }
        'Info'           { Show-Info }
    }
} catch {
    Fail $_.Exception.Message
}
exit 0

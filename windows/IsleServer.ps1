<#
.SYNOPSIS
    The Isle (Evrima) dedicated server manager for Windows.

.DESCRIPTION
    Installs, updates, configures, starts, stops, backs up and monitors a
    The Isle Evrima dedicated server. Works with Windows PowerShell 5.1
    (Windows 10/11, Windows Server 2019/2022/2025) and PowerShell 7+.

    Settings are read from ..\config\server.conf (shared with the Linux scripts).

.PARAMETER Command
    Install        Install prerequisites, SteamCMD, the server and generate config
    Update         Update server files through SteamCMD
    Validate       Update + verify every file
    Configure      (Re)generate Game.ini / Engine.ini from server.conf
    Start          Start the server (scheduled-task service if installed, else a new window)
    Stop           Save (RCON) and stop the server
    Restart        Stop + Start
    Status         Show whether the server is running
    Run            Run the server in this window with an auto-restart watchdog
    Logs           Show the server log (add -Follow to tail it)
    Backup         Zip save data and config into BACKUP_DIR
    Restore        Restore a backup zip (-Path <zip>)
    Rcon           Send an RCON command (-RconArgs 'announce','Hello')
    Save           Ask the server to save via RCON
    Firewall       Create Windows Firewall rules for the configured ports
    RemoveFirewall Remove the firewall rules
    InstallService Register a scheduled task that runs the server at boot
    RemoveService  Remove that scheduled task
    Info           Print resolved paths and settings

.EXAMPLE
    .\IsleServer.ps1 Install
    .\IsleServer.ps1 Start
    .\IsleServer.ps1 Logs -Follow
    .\IsleServer.ps1 Rcon -RconArgs announce,'Restart in 5 minutes'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Install', 'Update', 'Validate', 'Configure', 'Start', 'Stop', 'Restart', 'Status', 'Run',
                 'Logs', 'Backup', 'Restore', 'Rcon', 'Save', 'Firewall', 'RemoveFirewall',
                 'InstallService', 'RemoveService', 'Info', 'Help')]
    [string]$Command = 'Help',

    [string]$ConfigPath,
    [string]$Path,
    [string[]]$RconArgs,
    [switch]$Follow,
    [ValidateSet('LocalService', 'System')]
    [string]$ServiceAccount = 'LocalService'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on 5.1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
if (-not $ConfigPath) {
    if ($env:ISLE_CONF) { $ConfigPath = $env:ISLE_CONF } else { $ConfigPath = Join-Path $RepoDir 'config\server.conf' }
}
$TaskName = 'TheIsleServer'
$FirewallGroup = 'The Isle Dedicated Server'
$SteamCmdUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$VcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'

# ------------------------------------------------------------------ output --
function Write-Step([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail([string]$m)       { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

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
        EXTRA_ARGS = '-log'
    }
    foreach ($k in $defaults.Keys) {
        if (-not $script:Cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($script:Cfg[$k])) { $script:Cfg[$k] = $defaults[$k] }
    }
    $script:SteamCmdDir = $script:Cfg.STEAMCMD_DIR
    $script:ServerDir = $script:Cfg.SERVER_DIR
    $script:BackupDir = $script:Cfg.BACKUP_DIR
    $script:IniDir = Join-Path $script:ServerDir 'TheIsle\Saved\Config\WindowsServer'
    $script:StateDir = Join-Path $script:ServerDir '.isle-scripts'
    $script:LogFile = Join-Path $script:ServerDir 'TheIsle\Saved\Logs\TheIsle.log'
}
function C([string]$key, [string]$default = '') {
    if ($script:Cfg.ContainsKey($key) -and $script:Cfg[$key] -ne '') { return [string]$script:Cfg[$key] }
    return $default
}
function Test-True([string]$v) { return @('true', 'yes', '1', 'on') -contains $v.ToLowerInvariant() }
function UeBool([string]$v) { if (Test-True $v) { 'true' } else { 'false' } }

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
    $tmp = Join-Path $env:TEMP 'vc_redist.x64.exe'
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
    $zip = Join-Path $env:TEMP 'steamcmd.zip'
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
    $o.Add("bEnableDiets=$(UeBool (C 'ENABLE_DIETS' 'true'))")
    $o.Add("bEnablePatrolZones=$(UeBool (C 'ENABLE_PATROL_ZONES' 'true'))")
    $o.Add("bAllowRecordingReplay=$(UeBool (C 'ALLOW_RECORDING_REPLAY' 'true'))")
    $o.Add("bSpawnPlants=$(UeBool (C 'SPAWN_PLANTS' 'true'))")
    $o.Add("PlantSpawnMultiplier=$(C 'PLANT_SPAWN_MULTIPLIER' '1')")
    $o.Add("bSpawnAI=$(UeBool (C 'SPAWN_AI' 'true'))")
    $o.Add("AIDensity=$(C 'AI_DENSITY' '1')")
    $o.Add("bEnableMigration=$(UeBool (C 'ENABLE_MIGRATION' 'true'))")
    $o.Add("MaxMigrationTime=$(C 'MAX_MIGRATION_TIME' '5400')")
    $o.Add("bEnableMassMigration=$(UeBool (C 'ENABLE_MASS_MIGRATION' 'true'))")
    $o.Add("MassMigrationTime=$(C 'MASS_MIGRATION_TIME' '43200')")
    $o.Add("MassMigrationDisableTime=$(C 'MASS_MIGRATION_DISABLE_TIME' '7200')")
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
    return ($lines -join "`r`n") + "`r`n"
}

function Write-IniFile([string]$file, [string]$content) {
    if ((Test-Path $file) -and ([IO.File]::ReadAllText($file) -ceq $content)) { return }
    if (Test-Path $file) { Copy-Item $file "$file.bak" -Force }
    [IO.File]::WriteAllText($file, $content, (New-Object Text.UTF8Encoding($false)))
    Write-Ok "Wrote $file"
}

function Set-ServerConfig([switch]$Force) {
    if ((Test-True (C 'RCON_ENABLED')) -and -not (C 'RCON_PASSWORD')) {
        Write-Warn 'RCON_ENABLED=true but RCON_PASSWORD is empty - RCON will not be usable'
    }
    New-Item -ItemType Directory -Force -Path $IniDir | Out-Null
    $game = Join-Path $IniDir 'Game.ini'
    $engine = Join-Path $IniDir 'Engine.ini'
    if ($Force -or (Test-True (C 'MANAGE_INI_FILES'))) {
        Write-IniFile $game (Get-GameIni)
        Write-IniFile $engine (Get-EngineIni)
    } else {
        if (-not (Test-Path $game)) { Write-IniFile $game (Get-GameIni) }
        if (-not (Test-Path $engine)) { Write-IniFile $engine (Get-EngineIni) }
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
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
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
    if (-not (Test-Path $LogFile)) { Fail "No log file yet at $LogFile" }
    if ($Follow) { Get-Content -Path $LogFile -Tail 100 -Wait } else { Get-Content -Path $LogFile -Tail 200 }
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
    try { & $py[0] @pyArgs | Out-Host } finally { Remove-Item Env:\ISLE_RCON_PASSWORD -ErrorAction SilentlyContinue }
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
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stage = Join-Path $env:TEMP "theisle-backup-$stamp"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        # robocopy copies files that the running server holds open (read-shared)
        & robocopy $saved (Join-Path $stage 'Saved') /E /R:1 /W:1 /XD Logs Crashes /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Fail "robocopy failed with code $LASTEXITCODE" }
        Copy-Item $ConfigPath (Join-Path $stage 'server.conf') -ErrorAction SilentlyContinue
        $zip = Join-Path $BackupDir "theisle-$stamp.zip"
        Write-Step "Creating backup $zip"
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
        Write-Ok ("Backup written ({0:N1} MB)" -f ((Get-Item $zip).Length / 1MB))
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $keep = [int](C 'BACKUP_RETENTION' '10')
    if ($keep -gt 0) {
        Get-ChildItem -Path $BackupDir -Filter 'theisle-*.zip' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $keep | ForEach-Object { Remove-Item $_.FullName -Force; Write-Step "Pruned $($_.Name)" }
    }
}

function Invoke-Restore {
    if (-not $Path -or -not (Test-Path $Path)) { Fail 'Usage: IsleServer.ps1 Restore -Path <backup.zip>' }
    if (Get-ServerProcess) { Fail 'Stop the server before restoring' }
    $saved = Join-Path $ServerDir 'TheIsle\Saved'
    if (Test-Path $saved) { Rename-Item $saved ("Saved.pre-restore-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    $stage = Join-Path $env:TEMP ("theisle-restore-" + [guid]::NewGuid())
    Expand-Archive -Path $Path -DestinationPath $stage
    Move-Item (Join-Path $stage 'Saved') $saved
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Restored $Path (previous data kept as Saved.pre-restore-*)"
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

    $backupTask = "$TaskName-Backup"
    $bAction = New-ScheduledTaskAction -Execute $psExe -WorkingDirectory $ScriptDir `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" Backup -ConfigPath `"{1}`"" -f (Join-Path $ScriptDir 'IsleServer.ps1'), $ConfigPath)
    $bTrigger = New-ScheduledTaskTrigger -Daily -At '05:00'
    Register-ScheduledTask -TaskName $backupTask -Description 'Daily backup of The Isle server' -Action $bAction `
        -Trigger $bTrigger -Principal $principal -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable) -Force | Out-Null
    Write-Ok "Scheduled task '$backupTask' registered (daily 05:00)"
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

# ------------------------------------------------------------------ main ---
if ($Command -eq 'Help') { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }
Import-ServerConfig

try {
    switch ($Command) {
        'Install' {
            Install-VcRedist
            if (-not (C 'RCON_PASSWORD')) {
                $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
                $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
                $bytes = New-Object byte[] 24; $rng.GetBytes($bytes)
                Set-ConfigValue 'RCON_PASSWORD' (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
                Write-Ok 'Generated a random RCON password (see config\server.conf)'
            }
            Update-Server
            Set-ServerConfig
            Write-Ok "Install complete. Start with: .\IsleServer.ps1 Start"
        }
        'Update'         { if (Get-ServerProcess) { Fail 'Stop the server before updating' }; Update-Server }
        'Validate'       { if (Get-ServerProcess) { Fail 'Stop the server before validating' }; Update-Server -Validate }
        'Configure'      { Set-ServerConfig -Force }
        'Start'          { Invoke-Start }
        'Stop'           { Invoke-Stop }
        'Restart'        { Invoke-Stop; Start-Sleep -Seconds 2; Invoke-Start }
        'Status'         { Show-Status }
        'Run'            { Invoke-Run }
        'Logs'           { Show-Logs }
        'Backup'         { Invoke-Backup }
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

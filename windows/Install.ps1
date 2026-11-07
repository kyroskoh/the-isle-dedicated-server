<#
.SYNOPSIS
    Installer for The Isle (Evrima) dedicated server on Windows - native or Docker.

.DESCRIPTION
    Supported: Windows 10 / 11 (x64), Windows Server 2019 / 2022 / 2025
    (Desktop Experience or Server Core), Windows PowerShell 5.1 or PowerShell 7+.

    Two install modes - pick one with a switch, or answer the prompt:
      -Native   VC++ runtime, SteamCMD, the server and a boot-time scheduled task
      -Docker   the server runs in a Docker Desktop container (Linux containers)
    Both use the same launcher afterwards (Start.bat, Stop.bat, IsleServer.ps1 ...).

    Re-running is safe: scripts are updated, settings and data are kept.
    Re-running with the other mode switches modes: the old one is stopped and
    disabled (its data is kept) and the settings carry over.

.PARAMETER InstallRoot
    Base folder for scripts, SteamCMD, server files and backups. Default C:\TheIsle

.PARAMETER Native
    Install natively (default when not interactive and nothing was installed before).

.PARAMETER Docker
    Install in Docker Desktop. Skips the VC++ runtime, Python, SteamCMD and the scheduled task.

.PARAMETER Branch
    Steam beta branch. Default: value in server.conf (evrima). Pass '' for public.

.PARAMETER Uninstall
    Remove what is installed (both modes unless -Native or -Docker is given). Keeps world
    data, settings and backups so the installer can simply be run again later.

.PARAMETER Purge
    With -Uninstall: also delete InstallRoot (server files, backups, settings), the Docker
    volume and image. Asks for confirmation unless -Yes is given.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Native -InstallRoot D:\Games\TheIsle -Start
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Docker -Start
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall -Purge -Yes
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\TheIsle',
    [string]$Branch,
    [ValidateSet('LocalService', 'System')]
    [string]$ServiceAccount = 'LocalService',
    [switch]$Native,
    [switch]$Docker,
    [switch]$NoService,
    [switch]$NoFirewall,
    [switch]$NoPython,
    [switch]$Start,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Yes
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail([string]$m)       { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

if ($Native -and $Docker) { Fail 'Choose either -Native or -Docker, not both.' }
if ($Purge -and -not $Uninstall) { Fail '-Purge is only valid together with -Uninstall.' }

# ------------------------------------------------------------ elevation ----
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Requesting Administrator rights...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" } }
        else { $argList += @("-$($kv.Key)", "`"$($kv.Value)`"") }
    }
    $psExe = (Get-Process -Id $PID).Path
    try { Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs | Out-Null }
    catch { Fail 'Elevation was cancelled. Re-run from an elevated PowerShell.' }
    exit 0
}

# ------------------------------------------------------------- OS check ----
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if (-not [Environment]::Is64BitOperatingSystem) { Fail 'A 64-bit version of Windows is required.' }
# 17763 = Windows 10 1809 / Server 2019. Windows 10 builds older than that may work but are untested.
if ($build -lt 17763) { Write-Warn "Windows build $build is older than the tested minimum (17763 / Server 2019 / Win10 1809)." }
Write-Ok ("{0} (build {1})" -f $os.Caption, $build)

$ScriptsDir = Join-Path $InstallRoot 'scripts'
$Manager = Join-Path $ScriptsDir 'windows\IsleServer.ps1'
$Conf = Join-Path $ScriptsDir 'config\server.conf'
$StateFile = Join-Path $InstallRoot 'install-state.txt'
$TaskName = 'TheIsleServer'
$Container = 'theisle'
$Volume = 'theisle-data'
$Version = 'unknown'
if (Test-Path (Join-Path $SourceRoot 'VERSION')) { $Version = (Get-Content (Join-Path $SourceRoot 'VERSION') | Select-Object -First 1).Trim() }

# ------------------------------------------------------------------ state ---
function Read-InstallState {
    $st = @{ MODE = ''; STATUS = '' }
    if (Test-Path $StateFile) {
        foreach ($line in [IO.File]::ReadAllLines($StateFile)) {
            $i = $line.IndexOf('=')
            if ($i -gt 0) { $st[$line.Substring(0, $i)] = $line.Substring($i + 1) }
        }
    }
    return $st
}
function Write-InstallState([string]$mode, [string]$status = 'installed') {
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $lines = @("MODE=$mode", "SCRIPTS_DIR=$ScriptsDir", "STATUS=$status", "VERSION=$Version",
               ("UPDATED=" + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
    [IO.File]::WriteAllLines($StateFile, $lines)
}
$State = Read-InstallState

function Test-DockerUsable {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}
function Test-NativeActive {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { return $true }
    return ($State.MODE -eq 'native' -and $State.STATUS -ne 'uninstalled')
}
function Test-DockerContainer {
    if (-not (Test-DockerUsable)) { return $false }
    $id = & docker ps -aq --filter "name=^$Container`$" 2> $null
    return [bool]("$id".Trim())
}
function Invoke-Manager {
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    if (-not (Test-Path $Manager)) { return 1 }
    & $Manager @Rest -ConfigPath $Conf
    return $LASTEXITCODE
}

# ------------------------------------------------- retire (keeps data) ------
function Stop-NativeInstall {
    Write-Step 'Stopping and disabling the native server (data is kept)'
    [void](Invoke-Manager Stop -Runtime Native)
    [void](Invoke-Manager RemoveService -Runtime Native)
    Write-Ok 'Native server stopped, scheduled tasks removed'
}
function Remove-DockerContainer {
    Write-Step "Stopping and removing the container (the $Volume volume is kept)"
    if (Test-DockerUsable) {
        & docker stop -t 90 $Container *> $null
        & docker rm $Container *> $null
    }
    Write-Ok 'Container removed'
}

function Confirm-Purge {
    if ($Yes) { return }
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if (-not $interactive) { Fail 'Refusing to purge without confirmation - re-run with -Yes.' }
    $ans = Read-Host "PURGE: delete $InstallRoot (server files, worlds, backups, settings) and the Docker volume? Type 'yes' to continue"
    if ($ans -ne 'yes') { Fail 'Aborted' }
}

# --------------------------------------------------------------- uninstall --
if ($Uninstall) {
    if ($Purge) { Confirm-Purge }
    $any = $false
    if (-not $Docker -and ((Test-NativeActive) -or (Test-Path $Manager))) {
        $any = $true
        Stop-NativeInstall
        [void](Invoke-Manager RemoveFirewall -Runtime Native)
    }
    if (-not $Native -and ((Test-DockerContainer) -or $State.MODE -eq 'docker')) {
        $any = $true
        Remove-DockerContainer
    }
    if ($Purge) {
        Write-Step 'Purging data'
        if (Test-DockerUsable) {
            $vols = @($Volume) + @(& docker volume ls -q 2> $null | Where-Object { $_ -match '_theisle-data$' })
            foreach ($v in $vols) { & docker volume rm $v *> $null; if ($LASTEXITCODE -eq 0) { Write-Ok "Removed volume $v" } }
            & docker image rm theisle-server:latest *> $null
        }
        $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
        $looksOurs = (Test-Path $StateFile) -or (Test-Path (Join-Path $root 'scripts\windows\IsleServer.ps1'))
        if ($root.Length -le 3 -or -not $looksOurs) {
            Write-Warn "Not deleting $root (it is a drive root or does not look like an install folder)."
        } elseif (Test-Path $root) {
            Set-Location ([IO.Path]::GetTempPath())
            Remove-Item -LiteralPath $root -Recurse -Force
            Write-Ok "Removed $root"
        }
        Write-Ok 'Purged. A reinstall starts from scratch.'
    } else {
        if ($State.MODE) { Write-InstallState $State.MODE 'uninstalled' }
        if (-not $any) { Write-Warn 'Nothing to uninstall was found.' }
        Write-Ok "Uninstalled. World data, settings and backups in $InstallRoot were kept - run the installer again to reinstall."
    }
    exit 0
}

# ------------------------------------------------------------ choose mode --
$Mode = ''
if ($Native) { $Mode = 'native' } elseif ($Docker) { $Mode = 'docker' }
if (-not $Mode) {
    $default = 'native'
    if ($State.MODE) { $default = $State.MODE }
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if ($interactive) {
        Write-Host ''
        Write-Host 'How should the server run?'
        Write-Host '  1) native  - SteamCMD + scheduled task on this machine'
        Write-Host '  2) docker  - in a Docker Desktop container (Linux containers)'
        $d = '1'; if ($default -eq 'docker') { $d = '2' }
        $ans = Read-Host "Choose 1 or 2 [$d]"
        switch ($ans) {
            '' { $Mode = $default }
            { $_ -in '1', 'native' } { $Mode = 'native' }
            { $_ -in '2', 'docker' } { $Mode = 'docker' }
            default { Fail 'Please answer 1 or 2.' }
        }
    } else { $Mode = $default }
}
$prev = ''
if ($State.MODE) { $prev = " (previously: $($State.MODE))" }
Write-Ok "Install mode: $Mode$prev"

if ($Mode -eq 'docker' -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail 'Docker Desktop was not found. Install it from https://docs.docker.com/desktop/ (WSL 2 backend), start it, then re-run with -Docker.'
}

# ------------------------------------------------------------ copy files ---
Write-Step "Installing management scripts to $ScriptsDir"
New-Item -ItemType Directory -Force -Path $ScriptsDir | Out-Null
if ((Resolve-Path $SourceRoot).Path.TrimEnd('\') -ne (Resolve-Path $ScriptsDir).Path.TrimEnd('\')) {
    & robocopy $SourceRoot $ScriptsDir /E /XD .git /XF server.conf /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "Copying scripts failed (robocopy code $LASTEXITCODE)" }
}
# Files downloaded from the internet carry a "mark of the web"; clear it.
Get-ChildItem -Path $ScriptsDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

if (-not (Test-Path $Conf)) {
    $srcConf = Join-Path $SourceRoot 'config\server.conf'
    if (Test-Path $srcConf) { Copy-Item $srcConf $Conf } else { Copy-Item (Join-Path $ScriptsDir 'config\server.conf.example') $Conf }
    Write-Ok 'Created config\server.conf'
} else {
    Write-Ok 'Keeping existing config\server.conf'
}

function Set-Conf([string]$key, [string]$value, [switch]$OnlyIfEmpty) {
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($Conf))
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^' + [regex]::Escape($key) + '=(.*)$')) {
            $found = $true
            if ($OnlyIfEmpty -and $Matches[1].Trim()) { return }
            $lines[$i] = "$key=$value"
        }
    }
    if (-not $found) { $lines.Add("$key=$value") }
    [IO.File]::WriteAllLines($Conf, $lines)
}
Set-Conf 'RUNTIME' $Mode
Set-Conf 'STEAMCMD_DIR' (Join-Path $InstallRoot 'steamcmd') -OnlyIfEmpty
Set-Conf 'SERVER_DIR' (Join-Path $InstallRoot 'server') -OnlyIfEmpty
Set-Conf 'BACKUP_DIR' (Join-Path $InstallRoot 'backups') -OnlyIfEmpty
if ($PSBoundParameters.ContainsKey('Branch')) { Set-Conf 'STEAM_BRANCH' $Branch }
$cfgText = [IO.File]::ReadAllText($Conf)
function Get-Conf([string]$k, [string]$d) { if ($cfgText -match "(?m)^$k=(.*)$") { $v = $Matches[1].Trim().Trim('"'); if ($v) { return $v } }; return $d }
$BackupDir = Get-Conf 'BACKUP_DIR' (Join-Path $InstallRoot 'backups')
$MigrateHint = ''

# ------------------------------------------------------------ mode switch --
if ($Mode -eq 'docker' -and (Test-NativeActive)) {
    Write-Step 'Switching from native to docker'
    $before = @(Get-ChildItem -Path $BackupDir -Filter 'theisle-*.zip' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    [void](Invoke-Manager Backup -Runtime Native)
    $new = Get-ChildItem -Path $BackupDir -Filter 'theisle-*.zip' -ErrorAction SilentlyContinue |
        Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($new) { $MigrateHint = "Your native world was backed up to $($new.FullName) - to load it into Docker: Restore.bat -Path `"$($new.FullName)`"" }
    Stop-NativeInstall
}
if ($Mode -eq 'native' -and (Test-DockerContainer)) {
    Write-Step 'Switching from docker to native'
    [void](Invoke-Manager Stop -Runtime Docker)
    if ((Invoke-Manager Backup -Runtime Docker) -eq 0) {
        $img = (& docker inspect -f '{{.Config.Image}}' $Container 2> $null)
        $latest = (& docker run --rm -v "${Volume}:/data" --entrypoint sh $img -c 'ls -t /data/backups/theisle-*.tar.gz 2>/dev/null | head -n1' 2> $null)
        if ("$latest".Trim()) {
            New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
            $dest = Join-Path $BackupDir ([IO.Path]::GetFileName("$latest".Trim()))
            & docker cp "${Container}:$("$latest".Trim())" $dest *> $null
            if ($LASTEXITCODE -eq 0) { $MigrateHint = "Your Docker world was backed up to $dest - to load it natively: Restore.bat -Path `"$dest`"" }
        }
    }
    Remove-DockerContainer
}

# ------------------------------------------------------------------ python --
if ($Mode -eq 'native' -and -not $NoPython) {
    $hasPy = $false
    foreach ($c in 'py', 'python') {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps\\python') { $hasPy = $true }
    }
    if ($hasPy) { Write-Ok 'Python 3 found (used for RCON)' }
    elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Step 'Installing Python 3 with winget (used for RCON save-on-stop)'
        & winget install --id Python.Python.3.12 -e --scope machine --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Write-Warn 'winget could not install Python - RCON features will be skipped.' }
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    } else {
        Write-Warn 'Python 3 not found and winget unavailable (common on Windows Server). Install it from python.org to enable RCON save-on-stop.'
    }
}

# ------------------------------------------------------------------ server --
if ($Mode -eq 'docker') { Write-Step 'Building the image and creating the container' }
else { Write-Step 'Installing prerequisites, SteamCMD and The Isle server (this can take a while)' }
if ((Invoke-Manager Status) -eq 0) {
    Write-Warn 'Server is running - stopping it for the update (it will be started again)'
    [void](Invoke-Manager Stop)
    $Start = $true
}
if ((Invoke-Manager Install) -ne 0) { Fail 'Installation failed - see the messages above.' }

if (-not $NoFirewall) {
    Write-Step 'Configuring Windows Defender Firewall'
    [void](Invoke-Manager Firewall)
}
if ($Mode -eq 'native' -and -not $NoService) {
    Write-Step 'Registering the boot-time scheduled task'
    [void](Invoke-Manager InstallService -ServiceAccount $ServiceAccount)
}
if ($Start) {
    Write-Step 'Starting the server'
    [void](Invoke-Manager Start)
}
Write-InstallState $Mode

Write-Host ''
Write-Host "The Isle dedicated server is installed ($Mode)." -ForegroundColor Green
Write-Host "  Config file : $Conf   (edit, then Restart.bat)"
Write-Host "  Manage      : $ScriptsDir\windows\Start.bat | Stop.bat | Restart.bat | Update.bat | Backup.bat | Status.bat"
Write-Host "  PowerShell  : & '$Manager' <Start|Stop|Restart|Status|Logs|Update|Backup|Restore|Rcon>"
Write-Host ("  Ports       : {0}/udp+tcp (game), {1}/tcp (queue), {2}/tcp (RCON, keep private)" -f (Get-Conf 'GAME_PORT' '7777'), (Get-Conf 'QUEUE_PORT' '10000'), (Get-Conf 'RCON_PORT' '8888'))
if ($Mode -eq 'docker') {
    Write-Host "  Runtime     : Docker - data in volume $Volume (kept on uninstall); enable 'Start Docker Desktop when you sign in'"
}
Write-Host "  Reinstall   : run the installer again; uninstall keeps data (-Uninstall), -Uninstall -Purge removes it"
if ($MigrateHint) { Write-Host ''; Write-Host "  $MigrateHint" -ForegroundColor Yellow }
Write-Host '  Remember to forward the game and queue ports on your router / cloud firewall.'

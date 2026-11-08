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
    Uninstall keeps the world; a later reinstall (either mode) picks it up again,
    importing it from the other mode's retained data when the target has none.
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

.PARAMETER Data
    What happens to the other mode's data when switching (or when it is found):
    Copy (default) carries it and keeps the source, Move carries it and then clears the source
    worlds/backups, Fresh carries nothing. On Windows both modes share one config folder, so
    settings, overrides and plugins are always shared; worlds and backups are carried.

.PARAMETER Carry
    Parts to carry: worlds,backups (settings,overrides,plugins are shared on Windows).
    Default on a mode switch: worlds. Otherwise only a retained world is picked up.

.PARAMETER Overwrite
    Replace a world that already exists in the target.

.PARAMETER FromSnapshot
    Restore a snapshot (from any OS/runtime) after installing - e.g. moving to a new machine.

.PARAMETER UI
    Also run the web UI + REST API at boot (scheduled task TheIsleServer-UI, 127.0.0.1:UI_PORT,
    see UI.md). Kept on later re-runs; -NoUI removes it.

.PARAMETER Image
    Docker: use this prebuilt/registry image instead of building one from the repo.

.PARAMETER NoImport
    Do not import a world retained from the other mode (by default a reinstall imports it
    when the target has no world yet; an existing world is never overwritten).

.PARAMETER Purge
    With -Uninstall: also delete InstallRoot (server files, backups, settings), the Docker
    volume and image. Asks for confirmation unless -Yes is given.

.PARAMETER KeepData
    With -Uninstall: keep game files, worlds, backups and settings (the default when
    there is no prompt). Without any data switch an interactive uninstall shows a menu.

.PARAMETER RemoveGameFiles
    With -Uninstall: delete re-downloadable files (server install, SteamCMD, Docker image).

.PARAMETER RemoveWorlds
    With -Uninstall: delete worlds (TheIsle\Saved). A final backup is taken if backups are kept.

.PARAMETER RemoveBackups
    With -Uninstall: delete backups.

.PARAMETER RemoveSettings
    With -Uninstall: delete server.conf and the scripts copy.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Native -InstallRoot D:\Games\TheIsle -Start
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Docker -Start
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Native -UI
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall -RemoveGameFiles
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
    [switch]$UI,
    [switch]$NoUI,
    [switch]$Start,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Yes,
    [switch]$NoImport,
    [ValidateSet('Copy', 'Move', 'Fresh')]
    [string]$Data = 'Copy',
    [string]$Carry,
    [switch]$Overwrite,
    [string]$FromSnapshot,
    [string]$Image,
    [switch]$KeepData,
    [switch]$RemoveGameFiles,
    [switch]$RemoveWorlds,
    [switch]$RemoveBackups,
    [switch]$RemoveSettings
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
$SourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail([string]$m)       { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

if ($Native -and $Docker) { Fail 'Choose either -Native or -Docker, not both.' }
if ($NoImport) { $Data = 'Fresh' }
$CarryParts = @()
if ($Carry) {
    foreach ($p in ($Carry -split ',')) {
        $t = $p.Trim().ToLowerInvariant()
        if (@('worlds', 'backups', 'settings', 'overrides', 'plugins', 'all') -notcontains $t) { Fail "-Carry: unknown part '$t' (worlds,backups,settings,overrides,plugins)" }
        if ($t -eq 'all') { $CarryParts = @('worlds', 'backups') } elseif (@('worlds', 'backups') -contains $t) { $CarryParts += $t }
    }
}
if ($FromSnapshot) {
    if (-not (Test-Path $FromSnapshot)) { Fail "-FromSnapshot: no such file $FromSnapshot" }
    $FromSnapshot = (Resolve-Path $FromSnapshot).Path
}
$dataSwitch = $Purge -or $KeepData -or $RemoveGameFiles -or $RemoveWorlds -or $RemoveBackups -or $RemoveSettings
if ($dataSwitch -and -not $Uninstall) { Fail '-Purge/-KeepData/-Remove* are only valid together with -Uninstall.' }
if ($KeepData -and ($Purge -or $RemoveGameFiles -or $RemoveWorlds -or $RemoveBackups -or $RemoveSettings)) {
    Fail '-KeepData cannot be combined with -Purge or -Remove*.'
}

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
$UiTask = 'TheIsleServer-UI'
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
$script:NoFinalBackup = $false   # set during a "move" switch (the carry snapshot is the safety copy)

function Test-DockerUsable {
    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
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

# ---------------------------------------------------------- config access --
$script:cfgText = ''
if (Test-Path $Conf) { $script:cfgText = [IO.File]::ReadAllText($Conf) }
function Get-Stamp {  # yyyyMMdd_HHmmss in the install's TIMEZONE (local|utc), the suffix of dated files
    if ((Get-Conf 'TIMEZONE' 'local').ToLowerInvariant() -eq 'utc') { return (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss') }
    return (Get-Date).ToString('yyyyMMdd_HHmmss')
}
function Get-Conf([string]$k, [string]$d) {
    if ($script:cfgText -match "(?m)^$k=(.*)$") { $v = $Matches[1].Trim().Trim('"'); if ($v) { return $v } }
    return $d
}

# ------------------------------------------------- retained world data ------
# A "world" is TheIsle\Saved with anything besides Config, Logs and Crashes.
# Reinstalls import a retained world from the other runtime when the target has
# none, and never overwrite an existing world (PRD INS-19).
function Get-NativeSavedDir { return (Join-Path (Get-Conf 'SERVER_DIR' (Join-Path $InstallRoot 'server')) 'TheIsle\Saved') }
function Test-NativeWorld {
    $saved = Get-NativeSavedDir
    if (-not (Test-Path $saved)) { return $false }
    return [bool](Get-ChildItem -Path $saved -Force | Where-Object { @('Config', 'Logs', 'Crashes') -notcontains $_.Name } | Select-Object -First 1)
}
function Get-HelperImage {
    foreach ($img in @((Get-Conf 'DOCKER_IMAGE' ''), 'theisle-server:latest', 'debian:bookworm-slim')) {
        if (-not $img) { continue }
        & docker image inspect $img *> $null
        if ($LASTEXITCODE -eq 0) { return $img }
    }
    & docker pull -q debian:bookworm-slim *> $null
    if ($LASTEXITCODE -eq 0) { return 'debian:bookworm-slim' }
    return $null
}
function Test-VolumeWorld {
    if (-not (Test-DockerUsable)) { return $false }
    & docker volume inspect $Volume *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    $img = Get-HelperImage
    if (-not $img) { return $false }
    $check = 'd=/data/server/TheIsle/Saved; [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 ! -name Config ! -name Logs ! -name Crashes | grep -q .'
    & docker run --rm -v "${Volume}:/data:ro" --entrypoint sh $img -c $check *> $null
    return ($LASTEXITCODE -eq 0)
}

# ------------------------------------------------------- uninstall choices --
# Data categories (PRD INS-20): game files (server, SteamCMD, image - re-downloadable),
# worlds (TheIsle\Saved), backups, settings (server.conf + scripts copy).
function Get-RemovalList([hashtable]$rm, [bool]$removed) {
    $names = [ordered]@{ Game = 'game files'; Worlds = 'worlds'; Backups = 'backups'; Settings = 'settings' }
    $l = @($names.Keys | Where-Object { [bool]$rm[$_] -eq $removed } | ForEach-Object { $names[$_] })
    if ($l.Count -eq 0) { return 'nothing' }
    return ($l -join ', ')
}
function Read-YesNo([string]$q) { $a = Read-Host "$q [y/N]"; return @('y', 'yes') -contains "$a".ToLowerInvariant() }
function Select-Removals {
    $rm = @{ Game = [bool]$RemoveGameFiles; Worlds = [bool]$RemoveWorlds; Backups = [bool]$RemoveBackups; Settings = [bool]$RemoveSettings }
    if ($Purge) { foreach ($k in @($rm.Keys)) { $rm[$k] = $true }; return $rm }
    $anyFlag = $KeepData -or $RemoveGameFiles -or $RemoveWorlds -or $RemoveBackups -or $RemoveSettings
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if ($anyFlag -or -not $interactive) { return $rm }
    Write-Host ''
    Write-Host 'What should happen to the server data?'
    Write-Host '  1) Keep everything                 - a reinstall picks it up again (default)'
    Write-Host '  2) Remove game files only          - frees disk space; worlds, backups and settings are kept'
    Write-Host '  3) Remove game files and worlds    - backups and settings are kept (a final backup is taken)'
    Write-Host '  4) Delete everything (purge)       - deletes the install folder and the Docker volume'
    Write-Host '  5) Choose each item'
    $ans = Read-Host 'Choose 1-5 [1]'
    switch ("$ans") {
        { $_ -in '', '1' } { }
        '2' { $rm.Game = $true }
        '3' { $rm.Game = $true; $rm.Worlds = $true }
        '4' { $script:Purge = $true; foreach ($k in @($rm.Keys)) { $rm[$k] = $true } }
        '5' {
            $rm.Game = Read-YesNo 'Remove game files (server install, SteamCMD, Docker image - re-downloadable)?'
            $rm.Worlds = Read-YesNo 'Remove worlds (TheIsle\Saved)?'
            $rm.Backups = Read-YesNo 'Remove backups?'
            $rm.Settings = Read-YesNo 'Remove settings (server.conf and the scripts copy)?'
        }
        default { Fail 'Please answer 1-5.' }
    }
    return $rm
}
function Confirm-Removal([string]$what) {
    if ($Yes) { return }
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if (-not $interactive) { Fail "Refusing to delete $what without confirmation - re-run with -Yes." }
    $ans = Read-Host "Delete $what? Type 'yes' to continue"
    if ($ans -ne 'yes') { Fail 'Aborted' }
}
function Remove-SafeItem([string]$p) {
    if (-not $p) { return }
    $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
    $deny = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE,
              (Split-Path -Parent $env:USERPROFILE)) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    $depth = @($full.Split('\') | Where-Object { $_ }).Count
    if ($depth -lt 2 -or $deny -contains $full) {
        Write-Warn "Not deleting $full (looks like a system or profile folder) - remove it by hand if you really want to"
        return
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force; Write-Ok "Removed $full" }
}
function Remove-NativeData([hashtable]$rm) {
    if (-not ($rm.Game -or $rm.Worlds -or $rm.Backups -or $rm.Settings)) { return }
    Write-Step ("Removing native data: " + (Get-RemovalList $rm $true))
    $sdir = Get-Conf 'SERVER_DIR' (Join-Path $InstallRoot 'server')
    $scdir = Get-Conf 'STEAMCMD_DIR' (Join-Path $InstallRoot 'steamcmd')
    $bdir = Get-Conf 'BACKUP_DIR' (Join-Path $InstallRoot 'backups')
    $isle = Join-Path $sdir 'TheIsle'
    if ($rm.Worlds -and -not $rm.Backups -and -not $script:NoFinalBackup -and (Test-NativeWorld)) {
        New-Item -ItemType Directory -Force -Path $bdir | Out-Null
        $f = Join-Path $bdir ('theisle-final_' + (Get-Stamp) + '.tar.gz')
        & tar -czf $f -C $isle --exclude=Saved/Logs --exclude=Saved/Crashes Saved
        if ($LASTEXITCODE -ne 0) { Fail 'Could not take a final backup - nothing was deleted' }
        Write-Ok "Final backup of the world: $f"
    }
    if ($rm.Game -and $rm.Worlds) { Remove-SafeItem $sdir }
    else {
        if ($rm.Game -and (Test-Path $sdir)) {
            Get-ChildItem -LiteralPath $sdir -Force | Where-Object { $_.Name -ne 'TheIsle' } | Remove-Item -Recurse -Force
            if (Test-Path $isle) { Get-ChildItem -LiteralPath $isle -Force | Where-Object { $_.Name -notlike 'Saved*' } | Remove-Item -Recurse -Force }
            Write-Ok "Removed game files in $sdir (worlds kept)"
        }
        if ($rm.Worlds -and (Test-Path $isle)) {
            Get-ChildItem -LiteralPath $isle -Force | Where-Object { $_.Name -like 'Saved*' } | Remove-Item -Recurse -Force
            Write-Ok "Removed worlds in $isle"
        }
    }
    if ($rm.Game) { Remove-SafeItem $scdir }
    if ($rm.Backups) { Remove-SafeItem $bdir }
    if ($rm.Settings) { Set-Location ([IO.Path]::GetTempPath()); Remove-SafeItem $ScriptsDir }
}
function Remove-DockerData([hashtable]$rm) {
    if (-not ($rm.Game -or $rm.Worlds -or $rm.Backups -or $rm.Settings)) { return }
    Write-Step ("Removing Docker data: " + (Get-RemovalList $rm $true))
    if (-not (Test-DockerUsable)) { Write-Warn 'Docker is not available - Docker data was not touched'; return }
    & docker volume inspect $Volume *> $null
    if ($LASTEXITCODE -eq 0) {
        if ($rm.Game -and $rm.Worlds -and $rm.Backups -and $rm.Settings) {
            & docker volume rm $Volume *> $null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Removed volume $Volume" }
        } else {
            $img = Get-HelperImage
            if (-not $img) { Fail "No image available to edit volume $Volume - nothing was deleted" }
            $cmd = 'set -e'
            if ($rm.Worlds -and -not $rm.Backups -and -not $script:NoFinalBackup -and (Test-VolumeWorld)) {
                $cmd += '; mkdir -p /data/backups; tar -czf /data/backups/theisle-final_' + (Get-Stamp) + '.tar.gz -C /data/server/TheIsle --exclude=Saved/Logs --exclude=Saved/Crashes Saved'
                Write-Ok 'Taking a final backup of the world into /data/backups'
            }
            if ($rm.Game) {
                $cmd += "; [ -d /data/server ] && find /data/server -mindepth 1 -maxdepth 1 ! -name TheIsle -exec rm -rf {} + || true"
                $cmd += "; [ -d /data/server/TheIsle ] && find /data/server/TheIsle -mindepth 1 -maxdepth 1 ! -name 'Saved*' -exec rm -rf {} + || true"
                $cmd += '; rm -rf /data/steamcmd /data/home'
            }
            if ($rm.Worlds) { $cmd += '; rm -rf /data/server/TheIsle/Saved /data/server/TheIsle/Saved.pre-restore[-_]*' }
            if ($rm.Backups) { $cmd += '; rm -rf /data/backups' }
            if ($rm.Settings) { $cmd += '; rm -rf /data/config' }
            & docker run --rm -v "${Volume}:/data" --entrypoint sh $img -c $cmd
            if ($LASTEXITCODE -ne 0) { Fail "Editing volume $Volume failed" }
            Write-Ok ("Updated volume $Volume (kept: " + (Get-RemovalList $rm $false) + ')')
        }
    }
    if ($rm.Game) { & docker image rm theisle-server:latest *> $null; if ($LASTEXITCODE -eq 0) { Write-Ok 'Removed image theisle-server:latest' } }
}

# ------------------------------------------------------------------ web UI --
function Remove-UiTask {
    if (Get-ScheduledTask -TaskName $UiTask -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $UiTask -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $UiTask -Confirm:$false
        Write-Ok "Removed scheduled task '$UiTask'"
    }
}
function Install-UiTask([string]$runtime) {
    $py = Find-Python
    if (-not $py) { Write-Warn 'Python 3 is not available - web UI not installed (winget install Python.Python.3.12, then re-run with -UI)'; return }
    $api = Join-Path $ScriptsDir 'tools\isle_api.py'
    $pre = @(); if ($py[1]) { $pre += $py[1] }
    # create the token now and limit it to Administrators + SYSTEM (the task runs as SYSTEM)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $py[0] @($pre + @($api, '--conf', $Conf, '--print-token')) *> $null
    $ErrorActionPreference = $prev
    $tok = Join-Path (Split-Path -Parent $Conf) 'ui-token'
    if (Test-Path $tok) { & icacls $tok /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' /Q | Out-Null }
    $argLine = (($pre + @("`"$api`"", '--conf', "`"$Conf`"", '--launcher', "`"$Manager`"", '--runtime', $runtime)) -join ' ')
    $action = New-ScheduledTaskAction -Execute $py[0] -Argument $argLine -WorkingDirectory $ScriptsDir
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Stop-ScheduledTask -TaskName $UiTask -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $UiTask -Description 'The Isle server web UI and REST API' -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $UiTask
    Write-Ok ("Web UI on http://127.0.0.1:{0}/ (API docs at /docs) - scheduled task '{1}'" -f (Get-Conf 'UI_PORT' '8090'), $UiTask)
}

# --------------------------------------------------------------- uninstall --
if ($Uninstall) {
    Remove-UiTask
    $rm = Select-Removals
    if ($Purge) { Confirm-Purge }
    elseif ($rm.Worlds -or $rm.Backups -or $rm.Settings) {
        $destructive = @{ Game = $false; Worlds = $rm.Worlds; Backups = $rm.Backups; Settings = $rm.Settings }
        Confirm-Removal (Get-RemovalList $destructive $true)
    }
    $any = $false
    # A native setup that was uninstalled earlier (state MODE=native) still has data to remove.
    if (-not $Docker -and ((Test-NativeActive) -or (Test-Path $Manager) -or $State.MODE -eq 'native')) {
        $any = $true
        Stop-NativeInstall
        [void](Invoke-Manager RemoveFirewall -Runtime Native)
        if (-not $Purge) { Remove-NativeData $rm }
    }
    $hasVolume = $false
    if (Test-DockerUsable) { & docker volume inspect $Volume *> $null; $hasVolume = ($LASTEXITCODE -eq 0) }
    if (-not $Native -and ((Test-DockerContainer) -or $State.MODE -eq 'docker' -or $hasVolume)) {
        $any = $true
        Remove-DockerContainer
        if (-not $Purge) { Remove-DockerData $rm }
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
        Write-Ok ("Uninstalled. Removed: " + (Get-RemovalList $rm $true) + '. Kept: ' + (Get-RemovalList $rm $false) + '.')
        if (-not $rm.Worlds) { Write-Host '  Run the installer again to reinstall - kept worlds are picked up again.' }
        else { Write-Host '  Run the installer again to reinstall.' }
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

if ($Mode -eq 'docker' -and -not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
    Fail 'Docker Desktop was not found. Install it from https://docs.docker.com/desktop/ (WSL 2 backend), start it, then re-run with -Docker.'
}

# ------------------------------------------------------------ copy files ---
Write-Step "Installing management scripts to $ScriptsDir"
New-Item -ItemType Directory -Force -Path $ScriptsDir | Out-Null
if ((Resolve-Path $SourceRoot).Path.TrimEnd('\') -ne (Resolve-Path $ScriptsDir).Path.TrimEnd('\')) {
    & robocopy $SourceRoot $ScriptsDir /E /XD .git /XF server.conf ui-token /NFL /NDL /NJH /NJS /NP | Out-Null
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
if ($Image) { Set-Conf 'DOCKER_BUILD' 'false'; Set-Conf 'DOCKER_IMAGE' $Image; Write-Ok "Using prebuilt image $Image" }
Set-Conf 'STEAMCMD_DIR' (Join-Path $InstallRoot 'steamcmd') -OnlyIfEmpty
Set-Conf 'SERVER_DIR' (Join-Path $InstallRoot 'server') -OnlyIfEmpty
Set-Conf 'BACKUP_DIR' (Join-Path $InstallRoot 'backups') -OnlyIfEmpty
if ($PSBoundParameters.ContainsKey('Branch')) { Set-Conf 'STEAM_BRANCH' $Branch }
$script:cfgText = [IO.File]::ReadAllText($Conf)
$BackupDir = Get-Conf 'BACKUP_DIR' (Join-Path $InstallRoot 'backups')
$MigrateHint = ''

# ------------------------------------------------------------------ python --
if (-not $NoPython) {   # used for RCON, plugins and snapshots (both modes)
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

# ------------------------------------------------- carry data (snapshots) --
# Worlds/backups move between the native folders and the Docker volume with
# tools\isle_snapshot.py, the same engine as "IsleServer.ps1 Snapshot" (MIG-05/06).
function Find-Python {
    foreach ($c in @(@('py', '-3'), @('python', ''), @('python3', ''))) {
        $cmd = Get-Command $c[0] -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps\\python') { return @($cmd.Source, $c[1]) }
    }
    return $null
}
function Invoke-SnapshotTool([string]$runtime, [string[]]$toolArgs) {
    $py = Find-Python
    if (-not $py) { Write-Warn 'Python 3 is not available - data was not carried (it is kept; use IsleServer.ps1 Snapshot later)'; return @{ Code = 1; Out = '' } }
    $a = @(); if ($py[1]) { $a += $py[1] }
    $a += @((Join-Path $ScriptsDir 'tools\isle_snapshot.py'), '--conf', $Conf, '--runtime', $runtime, '--launcher', $Manager,
            '--server-dir', (Get-Conf 'SERVER_DIR' (Join-Path $InstallRoot 'server')), '--backup-dir', $BackupDir,
            '--overrides-dir', (Join-Path $ScriptsDir 'config\overrides'), '--plugins-dir', (Join-Path $ScriptsDir 'plugins\installed'))
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = (& $py[0] @($a + $toolArgs) 2>&1 | ForEach-Object { "$_" }) -join "`n"; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    ($out.TrimEnd() -split "`r?`n") | ForEach-Object { Write-Host "  $_" }
    return @{ Code = $code; Out = $out }
}
$SnapFile = $null; $SnapParts = @(); $SnapSource = ''; $Reused = $false
$sourceRuntime = 'native'; if ($Mode -eq 'native') { $sourceRuntime = 'docker' }
$switching = $false
if ($Mode -eq 'docker' -and (Test-NativeActive)) { $switching = $true; Write-Step 'Switching from native to docker'; Stop-NativeInstall }
$hadContainer = $false
if ($Mode -eq 'native' -and (Test-DockerContainer)) {
    $switching = $true; $hadContainer = $true
    Write-Step 'Switching from docker to native'
    & docker stop -t 90 $Container *> $null
}
$sourceWorld = $false; $targetWorld = $false
if ($Mode -eq 'docker') { $sourceWorld = Test-NativeWorld; $targetWorld = Test-VolumeWorld }
else { $sourceWorld = Test-VolumeWorld; $targetWorld = Test-NativeWorld }
$parts = @()
if ($Data -ne 'Fresh') {
    if ($CarryParts.Count) { $parts = $CarryParts }
    elseif ($switching -or $sourceWorld) { $parts = @('worlds') }
}
if ($parts -contains 'worlds') {
    if (-not $sourceWorld) { $parts = @($parts | Where-Object { $_ -ne 'worlds' }) }
    elseif ($targetWorld -and -not $Overwrite) {
        if ($Mode -eq 'docker') { Write-Ok "Reusing the world kept in Docker volume $Volume (the native world is kept too; -Overwrite replaces it)" }
        else { Write-Ok "Keeping the native world (the Docker world stays in volume $Volume; -Overwrite replaces it)" }
        $Reused = $true
        $parts = @($parts | Where-Object { $_ -ne 'worlds' })
    }
}
if ($parts.Count) {
    $out = Join-Path ([IO.Path]::GetTempPath()) ("theisle-carry-$sourceRuntime`_" + (Get-Stamp) + '.tar.gz')
    Write-Step ("Taking a snapshot of the $sourceRuntime data to carry over (" + ($parts -join ',') + ')')
    $r = Invoke-SnapshotTool $sourceRuntime @('create', '--include', ($parts -join ','), '--output', $out, '--no-save')
    if ($r.Code -eq 0) { $SnapFile = $out; $SnapParts = $parts; $SnapSource = $sourceRuntime }
    elseif ($r.Out -match 'nothing to snapshot') { Write-Ok "Nothing to carry over from $sourceRuntime" }
    else { Write-Warn "The snapshot failed - the $sourceRuntime data was not carried over (it is kept)" }
}
if ($hadContainer) { Remove-DockerContainer }

# ------------------------------------------------------------------ server --
if ($Mode -eq 'docker') { Write-Step 'Building the image and creating the container' }
else { Write-Step 'Installing prerequisites, SteamCMD and The Isle server (this can take a while)' }
if ((Invoke-Manager Status) -eq 0) {
    Write-Warn 'Server is running - stopping it for the update (it will be started again)'
    [void](Invoke-Manager Stop)
    $Start = $true
}
if ((Invoke-Manager Install) -ne 0) { Fail 'Installation failed - see the messages above.' }

function Restore-Snapshot([string]$file, [string[]]$restoreParts) {
    $extra = @(); if ($Overwrite) { $extra = @('--overwrite') }
    Write-Step ("Restoring " + (Split-Path -Leaf $file) + " into $Mode (" + ($restoreParts -join ',') + ')')
    $r = Invoke-SnapshotTool $Mode (@('restore', $file, '--include', ($restoreParts -join ',')) + $extra)
    if ($r.Code -ne 0) { $script:MigrateHint = "Restoring $file failed - retry with: Manage.bat Snapshot restore `"$file`"" }
    return $r.Out
}
if ($SnapFile) {
    $restoreOut = Restore-Snapshot $SnapFile $SnapParts
    if ($Data -eq 'Move') {
        $rm = @{ Game = $false; Settings = $false; Worlds = ($restoreOut -match 'World restored');
                 Backups = (($SnapParts -contains 'backups') -and ($restoreOut -match 'Backups restored')) }
        if ($rm.Worlds -or $rm.Backups) {
            $script:NoFinalBackup = $true
            Write-Step "Moving: clearing the $SnapSource copy"
            if ($SnapSource -eq 'native') { Remove-NativeData $rm } else { Remove-DockerData $rm }
        } else { Write-Warn "Nothing was restored, so nothing was removed from $SnapSource" }
    }
    $keep = Join-Path $ScriptsDir 'snapshots'
    New-Item -ItemType Directory -Force -Path $keep | Out-Null
    Move-Item $SnapFile $keep -Force
    Write-Ok ("The carry snapshot is kept at " + (Join-Path $keep (Split-Path -Leaf $SnapFile)))
} elseif ($Mode -eq 'docker' -and -not $FromSnapshot -and -not $Reused -and (Test-VolumeWorld)) {
    Write-Ok "Reusing the world kept in Docker volume $Volume"
}
if ($FromSnapshot) {
    $fsParts = @('worlds', 'settings', 'overrides', 'plugins')
    if ($Carry) { $fsParts = @($Carry -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) }
    [void](Restore-Snapshot $FromSnapshot $fsParts)
}

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
$uiWanted = $UI -or [bool](Get-ScheduledTask -TaskName $UiTask -ErrorAction SilentlyContinue)
if ($NoUI) { Remove-UiTask; $uiWanted = $false }
elseif ($uiWanted) { Write-Step 'Registering the web UI'; Install-UiTask $Mode }
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
if ($uiWanted) {
    Write-Host ("  Web UI      : http://127.0.0.1:{0}/  (token: & '$Manager' UiToken; API docs at /docs)" -f (Get-Conf 'UI_PORT' '8090'))
} else {
    Write-Host "  Web UI      : $ScriptsDir\windows\UI.bat (or re-run the installer with -UI to start it at boot)"
}
if ($MigrateHint) { Write-Host ''; Write-Host "  $MigrateHint" -ForegroundColor Yellow }
Write-Host '  Remember to forward the game and queue ports on your router / cloud firewall.'

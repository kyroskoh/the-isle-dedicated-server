<#
.SYNOPSIS
    One-shot installer for The Isle (Evrima) dedicated server on Windows.

.DESCRIPTION
    Supported: Windows 10 / 11 (x64), Windows Server 2019 / 2022 / 2025
    (Desktop Experience or Server Core), Windows PowerShell 5.1 or PowerShell 7+.

    1. Self-elevates to Administrator
    2. Copies these scripts to <InstallRoot>\scripts and creates config\server.conf
    3. Installs the Visual C++ runtime, SteamCMD and the server (app 412680, branch evrima)
    4. Opens the game/queue ports in Windows Defender Firewall
    5. Registers a scheduled task that starts the server at boot (+ daily backup)
    6. Optionally installs Python 3 (needed for RCON save-on-stop) via winget

.PARAMETER InstallRoot
    Base folder for scripts, SteamCMD, server files and backups. Default C:\TheIsle

.PARAMETER Branch
    Steam beta branch. Default: value in server.conf (evrima). Pass '' for public.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -InstallRoot D:\Games\TheIsle -Start
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\TheIsle',
    [string]$Branch,
    [ValidateSet('LocalService', 'System')]
    [string]$ServiceAccount = 'LocalService',
    [switch]$NoService,
    [switch]$NoFirewall,
    [switch]$NoPython,
    [switch]$Start,
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail([string]$m)       { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

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

if ($Uninstall) {
    if (-not (Test-Path $Manager)) { $Manager = Join-Path $SourceRoot 'windows\IsleServer.ps1'; $Conf = Join-Path $SourceRoot 'config\server.conf' }
    Write-Step 'Stopping server and removing scheduled tasks and firewall rules'
    & $Manager Stop -ConfigPath $Conf
    & $Manager RemoveService -ConfigPath $Conf
    & $Manager RemoveFirewall -ConfigPath $Conf
    Write-Ok "Uninstalled. Files in $InstallRoot were kept - delete the folder to remove everything."
    exit 0
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
Set-Conf 'STEAMCMD_DIR' (Join-Path $InstallRoot 'steamcmd') -OnlyIfEmpty
Set-Conf 'SERVER_DIR' (Join-Path $InstallRoot 'server') -OnlyIfEmpty
Set-Conf 'BACKUP_DIR' (Join-Path $InstallRoot 'backups') -OnlyIfEmpty
if ($PSBoundParameters.ContainsKey('Branch')) { Set-Conf 'STEAM_BRANCH' $Branch }

# --------------------------------------------------------------- python ----
if (-not $NoPython) {
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

# --------------------------------------------------------------- server ----
Write-Step 'Installing prerequisites, SteamCMD and The Isle server (this can take a while)'
& $Manager Install -ConfigPath $Conf
if ($LASTEXITCODE -ne 0) { Fail 'Server installation failed - see the messages above.' }

if (-not $NoFirewall) {
    Write-Step 'Configuring Windows Defender Firewall'
    & $Manager Firewall -ConfigPath $Conf
}
if (-not $NoService) {
    Write-Step 'Registering the boot-time scheduled task'
    & $Manager InstallService -ConfigPath $Conf -ServiceAccount $ServiceAccount
}
if ($Start) {
    Write-Step 'Starting the server'
    & $Manager Start -ConfigPath $Conf
}

$cfgText = [IO.File]::ReadAllText($Conf)
function Get-Conf([string]$k, [string]$d) { if ($cfgText -match "(?m)^$k=(.*)$") { $v = $Matches[1].Trim().Trim('"'); if ($v) { return $v } }; return $d }
Write-Host ''
Write-Host 'The Isle dedicated server is installed.' -ForegroundColor Green
Write-Host "  Config file : $Conf   (edit, then restart)"
Write-Host "  Manage      : $ScriptsDir\windows\Start.bat | Stop.bat | Update.bat | Backup.bat | Status.bat"
Write-Host "  PowerShell  : & '$Manager' <Start|Stop|Restart|Status|Logs|Update|Backup|Rcon>"
Write-Host ("  Ports       : {0}/udp+tcp (game), {1}/tcp (queue), {2}/tcp (RCON, keep private)" -f (Get-Conf 'GAME_PORT' '7777'), (Get-Conf 'QUEUE_PORT' '10000'), (Get-Conf 'RCON_PORT' '8888'))
Write-Host '  Remember to forward the game and queue ports on your router / cloud firewall.'

<#
  tests/test_snapshot.ps1 - snapshot round trip through IsleServer.ps1 (PRD MIG-07/08):
  two "machines" with their own config and server folders, plus a snapshot made by the
  Linux launcher's engine on another OS. Native mode only; never starts a server.
    powershell -ExecutionPolicy Bypass -File tests\test_snapshot.ps1
#>
$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$m = Join-Path $Repo 'windows/IsleServer.ps1'
$W = Join-Path ([IO.Path]::GetTempPath()) ('isle-snap-' + [guid]::NewGuid())
$fails = 0
function ck($label, [scriptblock]$block) { $r = $false; try { $r = [bool](& $block) } catch { Write-Host "    error: $_" }; if ($r) { "  PASS $label" } else { "  FAIL $label"; $script:fails++ } }

function New-Machine([string]$name, [string]$serverName) {
    $root = Join-Path $W $name
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'config') | Out-Null
    $conf = Join-Path $root 'config/server.conf'
    (Get-Content (Join-Path $Repo 'config/server.conf.example')) `
        -replace '^SERVER_DIR=.*$', ('SERVER_DIR=' + (Join-Path $root 'server')) `
        -replace '^STEAMCMD_DIR=.*$', ('STEAMCMD_DIR=' + (Join-Path $root 'steamcmd')) `
        -replace '^BACKUP_DIR=.*$', ('BACKUP_DIR=' + (Join-Path $root 'backups')) `
        -replace '^SERVER_NAME=.*$', ('SERVER_NAME="' + $serverName + '"') `
        -replace '^RCON_PASSWORD=$', ('RCON_PASSWORD=pw-' + $name) | Set-Content $conf
    return @{ Root = $root; Conf = $conf; Saved = (Join-Path $root 'server/TheIsle/Saved') }
}
function conf($machine, $k) { ((Get-Content $machine.Conf) | Where-Object { $_ -match "^$k=" } | Select-Object -Last 1) -replace "^$k=", '' }
function run { & $m @args *>&1 | Out-String }

$a = New-Machine 'a' 'Server A'
$b = New-Machine 'b' 'Server B'
New-Item -ItemType Directory -Force -Path (Join-Path $a.Saved 'SaveGames') | Out-Null
Set-Content (Join-Path $a.Saved 'SaveGames/world.sav') 'world-a'
New-Item -ItemType Directory -Force -Path (Join-Path $a.Root 'config/overrides') | Out-Null
Set-Content (Join-Path $a.Root 'config/overrides/Game.ini') @('[/Script/TheIsle.TIGameSession]', 'GrowthMultiplier=3')
$snap = Join-Path $W 'a.tar.gz'

ck 'Snapshot create'           { $o = run Snapshot create --output $snap -ConfigPath $a.Conf; $ok = ($LASTEXITCODE -eq 0) -and (Test-Path $snap); if (-not $ok) { Write-Host "    exit $LASTEXITCODE output:`n$o" }; $ok }
ck 'Snapshot info'             { (run Snapshot info $snap -ConfigPath $a.Conf) -match '"server_name": "Server A"' }
ck 'Snapshot restore to B'     { run Snapshot restore $snap -ConfigPath $b.Conf | Out-Null; $LASTEXITCODE -eq 0 }
ck 'world on B'                { (Get-Content (Join-Path $b.Saved 'SaveGames/world.sav')) -eq 'world-a' }
ck 'settings on B'             { ((conf $b 'SERVER_NAME') -eq '"Server A"') -and ((conf $b 'RCON_PASSWORD') -eq 'pw-a') }
ck 'machine keys kept on B'    { (conf $b 'SERVER_DIR') -eq (Join-Path $b.Root 'server') }
ck 'overrides on B'            { Test-Path (Join-Path $b.Root 'config/overrides/Game.ini') }
ck 'no overwrite by default'   { Set-Content (Join-Path $b.Saved 'SaveGames/world.sav') 'world-b'; (run Snapshot restore $snap -ConfigPath $b.Conf) -match 'already has a world' }
ck 'still world-b'             { (Get-Content (Join-Path $b.Saved 'SaveGames/world.sav')) -eq 'world-b' }
ck '--overwrite'               { run Snapshot restore $snap --overwrite -ConfigPath $b.Conf | Out-Null; (Get-Content (Join-Path $b.Saved 'SaveGames/world.sav')) -eq 'world-a' }

# A snapshot as written by another OS (LF server.conf with Linux paths)
$other = Join-Path $W 'other'
New-Item -ItemType Directory -Force -Path (Join-Path $other 'world/Saved/SaveGames'), (Join-Path $other 'settings') | Out-Null
Set-Content (Join-Path $other 'world/Saved/SaveGames/w.sav') 'from-linux'
[IO.File]::WriteAllText((Join-Path $other 'settings/server.conf'), "SERVER_NAME=`"Linux Box`"`nSERVER_DIR=/home/theisle/theisle-server`nMAX_PLAYERS=55`n")
[IO.File]::WriteAllText((Join-Path $other 'snapshot.json'), '{"format": 1, "created": "x", "source": {"os": "Linux", "runtime": "docker", "host": "vps"}, "server_name": "Linux Box", "parts": {"worlds": {}, "settings": {}}}')
$linuxSnap = Join-Path $W 'linux.tar.gz'
& tar -czf $linuxSnap -C $other snapshot.json world settings
$c = New-Machine 'c' 'Server C'
ck 'Linux snapshot restores'   { run Snapshot restore $linuxSnap -ConfigPath $c.Conf | Out-Null; $LASTEXITCODE -eq 0 }
ck 'Linux world + settings'    { ((Get-Content (Join-Path $c.Saved 'SaveGames/w.sav')) -eq 'from-linux') -and ((conf $c 'MAX_PLAYERS') -eq '55') -and ((conf $c 'SERVER_DIR') -eq (Join-Path $c.Root 'server')) }

Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $fails failure(s)"
if ($fails -gt 0) { exit 1 }

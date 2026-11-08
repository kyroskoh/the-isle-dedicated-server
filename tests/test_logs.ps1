<#
  tests/test_logs.ps1 - launcher log, rotation, retention, TIMEZONE and dated names in IsleServer.ps1
  (PRD LOG-01..05). Native mode only; never starts a server.
    powershell -ExecutionPolicy Bypass -File tests\test_logs.ps1
#>
$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$m = Join-Path $Repo 'windows/IsleServer.ps1'
$W = Join-Path ([IO.Path]::GetTempPath()) ('isle-logs-' + [guid]::NewGuid())
$fails = 0
function ck($label, [scriptblock]$block) { $r = $false; try { $r = [bool](& $block) } catch { Write-Host "    error: $_" }; if ($r) { "  PASS $label" } else { "  FAIL $label"; $script:fails++ } }
function run { & $m @args *>&1 | Out-String }
$isWin = [Environment]::OSVersion.Platform -eq 'Win32NT'

$logs = Join-Path $W 'logs'
$conf = Join-Path $W 'server.conf'
New-Item -ItemType Directory -Force -Path $logs, (Join-Path $W 'server/TheIsle/Saved/SaveGames'), (Join-Path $W 'server/TheIsle/Saved/Logs') | Out-Null
(Get-Content (Join-Path $Repo 'config/server.conf.example')) `
    -replace '^SERVER_DIR=.*$', ('SERVER_DIR=' + (Join-Path $W 'server')) `
    -replace '^BACKUP_DIR=.*$', ('BACKUP_DIR=' + (Join-Path $W 'backups')) `
    -replace '^RCON_PASSWORD=$', 'RCON_PASSWORD=pw' `
    -replace '^SAVE_BEFORE_STOP=.*$', 'SAVE_BEFORE_STOP=false' `
    -replace '^TIMEZONE=.*$', 'TIMEZONE=utc' `
    -replace '^LOG_DIR=.*$', ('LOG_DIR=' + $logs) `
    -replace '^LOG_RETENTION=.*$', 'LOG_RETENTION=2' `
    -replace '^LOG_MAX_SIZE_MB=.*$', 'LOG_MAX_SIZE_MB=1' | Set-Content $conf
Remove-Item Env:ISLE_LOG_DIR -ErrorAction SilentlyContinue
$name = '^launcher_\d{8}_\d{6}(_\d+)?\.log$'

ck 'Check passes with the log keys'      { run Check -ConfigPath $conf | Out-Null; $LASTEXITCODE -eq 0 }
ck 'read-only commands write no log'      { run Info -ConfigPath $conf | Out-Null; @(Get-ChildItem $logs).Count -eq 0 }
ck 'a change writes launcher_<stamp>.log' { run Admins add 76561198000000001 -ConfigPath $conf | Out-Null; $f = @(Get-ChildItem $logs); ($f.Count -eq 1) -and ($f[0].Name -match $name) }
ck 'stamp is UTC (TIMEZONE=utc)'          { (Get-ChildItem $logs)[0].Name.Substring(9, 8) -eq (Get-Date).ToUniversalTime().ToString('yyyyMMdd') }
ck 'lines carry time, zone and level'     { (Get-Content (Get-ChildItem $logs)[0].FullName) -match '^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC\] CMD  Admins add' }
ck 'no secret values in the log'          { run Plugins config x SECRET_TOKEN=abc123 -ConfigPath $conf | Out-Null; -not ((Get-Content (Get-ChildItem $logs)[0].FullName) -match 'abc123') }
ck 'the same file is reused under the limit' { run Admins remove 76561198000000001 -ConfigPath $conf | Out-Null; @(Get-ChildItem $logs).Count -eq 1 }

# size rotation + retention: three full old files -> a new one is started, the newest 2 are kept
Get-ChildItem $logs | Remove-Item
foreach ($d in '20200101', '20200102', '20200103') { [IO.File]::WriteAllText((Join-Path $logs "launcher_$($d)_000000.log"), ('x' * 1100000)) }
ck 'a full log starts a new file'          { run Admins add 76561198000000002 -ConfigPath $conf | Out-Null; @(Get-ChildItem $logs | Where-Object { $_.Name -notlike 'launcher_2020*' }).Count -eq 1 }
ck 'LOG_RETENTION keeps the newest 2'      { $n = @(Get-ChildItem $logs | Sort-Object Name | ForEach-Object Name); ($n.Count -eq 2) -and ($n[0] -eq 'launcher_20200103_000000.log') }
ck 'Logs list shows them'                  { (run Logs list -ConfigPath $conf) -match 'launcher_2020' }
ck 'Logs launcher shows the newest'        { (run Logs launcher -ConfigPath $conf) -match 'CMD  Admins add' }
ck 'bad TIMEZONE is refused'               { $bad = "$conf.bad"; (Get-Content $conf) -replace '^TIMEZONE=.*$', 'TIMEZONE=mars' | Set-Content $bad; $o = run Check -ConfigPath $bad; ($LASTEXITCODE -eq 1) -and ($o -match 'TIMEZONE') }
ck 'bad LOG_RETENTION is refused'          { $bad = "$conf.bad"; (Get-Content $conf) -replace '^LOG_RETENTION=.*$', 'LOG_RETENTION=lots' | Set-Content $bad; $o = run Check -ConfigPath $bad; ($LASTEXITCODE -eq 1) -and ($o -match 'LOG_RETENTION') }
ck 'profile apply keeps server.conf.bak_<stamp>' { run Profile apply casual -ConfigPath $conf | Out-Null; @(Get-ChildItem $W -Filter 'server.conf.bak_*' | Where-Object { $_.Name -match '\.bak_\d{8}_\d{6}$' }).Count -ge 1 }
if ($isWin) {
    Set-Content (Join-Path $W 'server/TheIsle/Saved/SaveGames/w.sav') 'world'
    ck 'backup is theisle-backup_<stamp>.zip' { run Backup -ConfigPath $conf | Out-Null; @(Get-ChildItem (Join-Path $W 'backups') | Where-Object { $_.Name -match '^theisle-backup_\d{8}_\d{6}\.zip$' }).Count -eq 1 }
}

Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $fails failure(s)"
if ($fails -gt 0) { exit 1 }

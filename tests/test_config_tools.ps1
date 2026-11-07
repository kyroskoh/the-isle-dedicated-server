<#
  tests/test_config_tools.ps1 - Windows/PowerShell checks for ini overrides, profiles, presets,
  admins, whitelist and roster commands (PRD CFX-01..09). Uses a temporary folder; never
  starts a server.   powershell -ExecutionPolicy Bypass -File tests\test_config_tools.ps1
#>
$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$W = Join-Path ([IO.Path]::GetTempPath()) ('isle-cfx-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path (Join-Path $W 'overrides') | Out-Null
$Conf = Join-Path $W 'server.conf'
(Get-Content (Join-Path $Repo 'config/server.conf.example')) `
    -replace '^SERVER_DIR=.*$', ('SERVER_DIR=' + (Join-Path $W 'srv')) `
    -replace '^STEAMCMD_DIR=.*$', ('STEAMCMD_DIR=' + (Join-Path $W 'sc')) `
    -replace '^BACKUP_DIR=.*$', ('BACKUP_DIR=' + (Join-Path $W 'bk')) `
    -replace '^RCON_PASSWORD=$', 'RCON_PASSWORD=x' | Set-Content $Conf
Set-Content (Join-Path $W 'overrides/Game.ini') @(
    '[/Script/TheIsle.TIGameSession]', 'GrowthMultiplier=9', 'AllowedClasses=Carnotaurus', '+Arr=1', '',
    '[/Script/TheIsle.Custom]', 'Foo=Bar')
$m = Join-Path $Repo 'windows/IsleServer.ps1'
$fails = 0
function ck($label, [scriptblock]$b) { $r = $false; try { $r = [bool](& $b) } catch { Write-Host "    error: $_" }; if ($r) { "  PASS $label" } else { "  FAIL $label"; $script:fails++ } }
function conf($k) { ((Get-Content $Conf) | Where-Object { $_ -match "^$k=" } | Select-Object -Last 1) -replace "^$k=", '' }
function run { & $m @args -ConfigPath $Conf *>&1 | Out-String }
ck 'Profile list'            { (run Profile list) -match 'realism' }
ck 'Profile show'            { (run Profile show realism) -match 'GROWTH_MULTIPLIER\s+1 -> 0.75' }
ck 'Profile apply'           { run Profile apply realism | Out-Null; (conf GROWTH_MULTIPLIER) -eq '0.75' }
ck 'Preset apply stacked'    { run Preset apply ai-off fast-growth | Out-Null; ((conf SPAWN_AI) -eq 'false') -and ((conf GROWTH_MULTIPLIER) -eq '2') }
ck 'Unknown preset fails'    { run Preset apply nope | Out-Null; $LASTEXITCODE -eq 1 }
ck 'Admins add + dedupe'     { run Admins add 76561198000000001 76561198000000002 76561198000000001 | Out-Null; (conf ADMIN_STEAM_IDS) -eq '76561198000000001,76561198000000002' }
ck 'Admins invalid refused'  { $o = run Admins add 123; ($LASTEXITCODE -eq 1) -and ($o -match 'not a SteamID64') }
ck 'Admins remove'           { run Admins remove 76561198000000001 | Out-Null; (conf ADMIN_STEAM_IDS) -eq '76561198000000002' }
ck 'Whitelist add/on/off'    { run Whitelist add 76561198000000003 | Out-Null; run Whitelist on | Out-Null; $a = (conf WHITELIST_ENABLED) -eq 'true'; run Whitelist off | Out-Null; $a -and ((conf WHITELIST_ENABLED) -eq 'false') -and ((conf WHITELIST_IDS) -eq '76561198000000003') }
ck 'Classes set/add/remove'  { run Classes set Tyrannosaurus Triceratops | Out-Null; run Classes add Stegosaurus | Out-Null; run Classes remove Triceratops | Out-Null; (conf ALLOWED_CLASSES) -eq 'Tyrannosaurus,Stegosaurus' }
ck 'Unknown class warns'     { (run Classes add Futurosaurus) -match 'not in config' }
ck 'Roster preset'           { run Classes preset herbivores | Out-Null; ((conf ALLOWED_CLASSES) -match 'Triceratops') -and ((conf ALLOWED_CLASSES) -notmatch 'Tyrannosaurus') }
ck 'Classes reset'           { run Classes reset | Out-Null; (conf ALLOWED_CLASSES) -eq '' }
ck 'AIClasses set'           { run AIClasses set Boar Deer | Out-Null; (conf DISABLED_AI_CLASSES) -eq 'Boar,Deer' }
run Preset apply region-spawning | Out-Null; run Profile apply performance | Out-Null
ck 'Configure with overrides' { run Configure | Out-Null; $LASTEXITCODE -eq 0 }
$gi = Get-Content (Join-Path $W 'srv/TheIsle/Saved/Config/WindowsServer/Game.ini')
$ei = Get-Content (Join-Path $W 'srv/TheIsle/Saved/Config/WindowsServer/Engine.ini')
ck 'override replaces key'   { @($gi | Where-Object { $_ -like 'GrowthMultiplier=*' }).Count -eq 1 -and ($gi -contains 'GrowthMultiplier=9') }
ck 'override replaces list'  { (@($gi | Where-Object { $_ -like 'AllowedClasses=*' }) -join ',') -eq 'AllowedClasses=Carnotaurus' }
ck '+array passes through'   { $gi -contains '+Arr=1' }
ck 'new section appended'    { ($gi -contains '[/Script/TheIsle.Custom]') -and ($gi -contains 'Foo=Bar') }
ck 'optional keys rendered'  { ($gi -contains 'bUseRegionSpawning=true') -and ($ei -contains 'NetServerMaxTickRate=30') }
Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $fails failure(s)"
if ($fails -gt 0) { exit 1 }

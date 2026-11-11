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
# fake Steam for the name lookups (tests/fixtures/fake-steam.py)
$py = 'python3'; if (-not (Get-Command $py -ErrorAction SilentlyContinue)) { $py = 'python' }
$steamOut = Join-Path $W 'steam.out'
$steam = Start-Process $py -ArgumentList @((Join-Path $Repo 'tests/fixtures/fake-steam.py'), '0') -RedirectStandardOutput $steamOut -PassThru -NoNewWindow
for ($i = 0; $i -lt 100 -and -not ((Test-Path $steamOut) -and (Get-Content $steamOut -ErrorAction SilentlyContinue)); $i++) { Start-Sleep -Milliseconds 100 }
$env:ISLE_STEAM_COMMUNITY_URL = 'http://127.0.0.1:' + ((Get-Content $steamOut | Select-Object -First 1) -split ' ')[1]
$env:ISLE_STEAM_API_URL = $env:ISLE_STEAM_COMMUNITY_URL
$fails = 0
function ck($label, [scriptblock]$b) { $r = $false; try { $r = [bool](& $b) } catch { Write-Host "    error: $_" }; if ($r) { "  PASS $label" } else { "  FAIL $label"; $script:fails++ } }
function conf($k) { ((Get-Content $Conf) | Where-Object { $_ -match "^$k=" } | Select-Object -Last 1) -replace "^$k=", '' }
function run { & $m @args -ConfigPath $Conf *>&1 | Out-String -Width 8192 }   # PS 5.1 wraps captured output at the console width
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
ck 'Maps list'               { (run Maps list) -match '\* Gateway' }
ck 'Maps set switches branch' { run Maps set Isla_Spiro | Out-Null; ((conf MAP_NAME) -eq 'Isla_Spiro') -and ((conf STEAM_BRANCH) -eq 'spiro0.11.59.04') }
ck 'Maps case-sensitive'     { $o = run Maps set gateway; ($o -match 'Unknown map') -and ((conf MAP_NAME) -eq 'Isla_Spiro') }
ck 'Maps back to Gateway'    { run Maps set Gateway | Out-Null; (conf STEAM_BRANCH) -eq 'evrima' }
ck 'AI density/interval'     { run AI density 0.5 | Out-Null; run AI interval 25 | Out-Null; ((conf AI_DENSITY) -eq '0.5') -and ((conf AI_SPAWN_INTERVAL) -eq '25') }
ck 'AI bad values refused'   { ((run AI density lots) -match 'Usage') -and ((run AI interval 0) -match 'Usage') }
ck 'AI preset ai-* only'     { run AI preset ai-prey-only | Out-Null; ((conf DISABLED_AI_CLASSES) -eq 'Compsognathus,Pterodactylus') -and ((run AI preset casual) -match 'Usage') }
ck 'AISpawnInterval rendered' { run Configure | Out-Null; (Get-Content (Join-Path $W 'srv/TheIsle/Saved/Config/WindowsServer/Game.ini')) -contains 'AISpawnInterval=25' }
ck 'Classes types'           { (run Classes types) -match 'flying\s+Pteranodon' }
ck 'Classes select flying'   { run Classes select flying | Out-Null; (conf ALLOWED_CLASSES) -eq 'Pteranodon' }
ck 'Classes remove-type'     { run Classes add-type aquatic | Out-Null; run Classes remove-type flying | Out-Null; (conf ALLOWED_CLASSES) -eq 'Deinosuchus' }
ck 'Unknown type refused'    { ((run Classes select egg) -match 'has type: egg') -and ((conf ALLOWED_CLASSES) -eq 'Deinosuchus') }
ck 'Humans on'               { run Classes humans on | Out-Null; (conf ENABLE_HUMANS) -eq 'true' }
run Classes reset | Out-Null; run Classes humans off | Out-Null
ck 'Mutation enable value'   { run Mutations enable Hemomania 0.3 | Out-Null; (conf ENABLED_MUTATIONS) -match 'Hemomania:0.3' }
ck 'Fixed mutation only 1'   { $o = run Mutations enable Reabsorption 2; ($o -match 'only takes 1') -and ("$(conf ENABLED_MUTATIONS)" -notmatch 'Reabsorption:2') }
ck 'EnabledMutations in ini' { run Configure | Out-Null; (Get-Content (Join-Path $W 'srv/TheIsle/Saved/Config/WindowsServer/Game.ini')) -contains 'EnabledMutations=Hemomania, 0.3' }
ck 'Mutations reset'         { run Mutations reset | Out-Null; [string]::IsNullOrEmpty((conf ENABLED_MUTATIONS)) }
ck 'Backup schedule set'     { run Backup schedule set '30 */6 * * 1-5' | Out-Null; (conf BACKUP_SCHEDULE) -match '30 \*/6 \* \* 1-5' }
ck 'Bad schedule refused'    { run Backup schedule set '61 * * * *' | Out-Null; (conf BACKUP_SCHEDULE) -match '30 \*/6' }
ck 'Backup status json'      { $j = ((run Backup status --json) -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json; $j.rule321.copies -ge 1 }
ck 'Admin kick needs id'     { (run Admin kick 123) -match 'SteamID64|Usage' }
ck 'Admin notes limits'      { (run Admin) -match 'god mode' }
ck 'Version shows credits'   { $v = & $m Version *>&1 | Out-String; ($v -match 'github.com/kyroskoh/the-isle-dedicated-server') -and ($v -match 'Kyros Koh') }
ck 'Admins list shows names'  { (run Admins list) -match '76561198000000002  Ptera <Pal> & Co' }
ck 'Whitelist add shows name' { (run Whitelist add 76561198000000003) -match '76561198000000003  ' }
ck 'Steam names'             { $o = run Steam names 76561198000000001 76561198000000099; ($o -match '76561198000000001  RexHunter') -and ($o -match '76561198000000099  \(name unknown\)') }
ck 'Steam names checks ids'  { (run Steam names 123) -match 'SteamID64' }
ck 'Names cached'            { Test-Path (Join-Path $W '.steam-names.json') }
$c2 = Join-Path $W 'copy2'; $nas = Join-Path $W 'nas2'
ck 'Strategy copy + keep'    { run Backup strategy copy $c2 --keep 3 | Out-Null; ((conf BACKUP_COPY_DIR) -eq $c2) -and ((conf BACKUP_COPY_RETENTION) -eq '3') }
ck 'Strategy offsite dir'    { run Backup strategy offsite "dir:$nas" --keep 2 | Out-Null; (conf BACKUP_OFFSITE_TARGET) -eq "dir:$nas" }
ck 'Unsafe target refused'   { $o = run Backup strategy offsite 'ssh://h/p;rm'; ($o -match 'Not a valid') -and ((conf BACKUP_OFFSITE_TARGET) -eq "dir:$nas") }
ck 'Strategy test passes'    { (run Backup strategy test) -match 'Off-site\s+: OK' }
ck 'Strategy show --json'    { ((run Backup strategy show --json) -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1 | ConvertFrom-Json).offsite_kind -eq 'dir' }
run Backup strategy offsite off | Out-Null; run Backup strategy copy off | Out-Null
$env:ISLE_SYSINFO_FAKE = '{"cpus": 2, "mem_gb": 6, "disk_free_gb": 50, "arch": "x86_64"}'
ck 'Recommend table'         { (run Recommend) -match 'MAX_PLAYERS\s+30' }
ck 'Recommend --apply KEY'   { run Recommend --apply MAX_PLAYERS NET_TICK_RATE | Out-Null; ((conf MAX_PLAYERS) -eq '30') -and ((conf NET_TICK_RATE) -eq '20') }
ck 'Recommend unknown key'   { (run Recommend --apply RCON_PASSWORD) -match 'Nothing to apply' }
ck 'Setup --yes'             { run Setup --yes | Out-Null; ((conf AI_DENSITY) -eq '0.75') -and (Test-Path (Join-Path $W '.setup-done')) }
Remove-Item Env:ISLE_SYSINFO_FAKE
Stop-Process -Id $steam.Id -Force -ErrorAction SilentlyContinue
Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $fails failure(s)"
if ($fails -gt 0) { exit 1 }

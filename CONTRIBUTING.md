# Contributing

Bug reports, distro fixes and new config keys are welcome.

1. Fork the repository and create a branch.
2. Keep both platforms in sync. A new `server.conf` key must be handled in **both**
   `linux/isle-server.sh` (`render_game_ini`) and `windows/IsleServer.ps1` (`Get-GameIni`), and
   documented in `config/server.conf.example` and `CONFIGURATION.md`.
3. Script rules:
   - Bash: must pass `shellcheck -x linux/*.sh`. Don't `source` the config file.
   - PowerShell: must work in **Windows PowerShell 5.1**. Don't use `??`, ternaries, `ForEach-Object -Parallel`, and so on.
     Keep `.ps1` files **ASCII-only**, because 5.1 misreads UTF-8 files that have no BOM.
   - Line endings are enforced by `.gitattributes` (LF for `.sh`, CRLF for `.ps1` and `.bat`).
4. Add an entry under **[Unreleased]** in `CHANGELOG.md`.
5. Open a pull request. CI runs ShellCheck, the PowerShell parser, PSScriptAnalyzer and smoke tests.

When you report a bug, include your OS and version, the command you ran, and the last 50 lines of
the server log or console output. Remove any passwords first.

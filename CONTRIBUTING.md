# Contributing

Bug reports, distro fixes and new config keys are welcome.

1. **Start from the PRD.** New behaviour gets a requirement ID and acceptance criteria in `PRD.md`
   (and a row in its traceability matrix) before it gets code.
2. Fork the repository and create a branch.
3. Keep both platforms in sync. A new `server.conf` key must be handled in **both**
   `linux/isle-server.sh` (`render_game_ini`) and `windows/IsleServer.ps1` (`Get-GameIni`), and
   documented in `config/server.conf.example` and `CONFIGURATION.md`. If the key has a type (port, boolean,
   number), add it to `check_config` / `Test-ServerConfig` as well.
4. Keep both **runtimes** in sync. A new launcher command needs a native implementation *and* a docker-mode
   mapping (`docker_main` in `isle-server.sh`, `Invoke-DockerCommand` in `IsleServer.ps1`).
5. Script rules:
   - Bash: must pass `shellcheck -x linux/*.sh`. Don't `source` the config file.
   - PowerShell: must work in **Windows PowerShell 5.1**. Don't use `??`, ternaries, `ForEach-Object -Parallel`, and so on.
     Keep `.ps1` files **ASCII-only**, because 5.1 misreads UTF-8 files that have no BOM.
   - Line endings are enforced by `.gitattributes` (LF for `.sh`, CRLF for `.ps1` and `.bat`).
6. Add an entry under **[Unreleased]** in `CHANGELOG.md`.
7. If you touch an installer, run the end-to-end cycle on a **disposable** VM (it purges the local install):
   `sudo ISLE_TEST_I_UNDERSTAND=1 bash tests/installer-cycle.sh`. CI runs it on every push.
8. Snapshot/migration changes: `python3 -m unittest tests/test_snapshot.py` (and `tests\test_snapshot.ps1` on Windows).
   Docker changes: run `ISLE_TEST_I_UNDERSTAND=1 IMAGE=<image> bash tests/test_container_e2e.sh` (it replaces
   the local `theisle` container and volume). Then run the fast tests: `bash tests/test_config_tools.sh` and `python3 -m unittest tests/test_plugins.py`.
   On Windows run `tests\test_config_tools.ps1`. New plugins go in `plugins/available/<name>/` plus an entry in
   `plugins/catalog.json` (see PLUGINS.md).
9. API or web UI changes: `python3 -m unittest tests/test_api.py` and `node tests/test_ui.mjs` (Playwright +
   Chromium: `npm i playwright@1.48.2 && npx playwright install chromium`). If the UI looks different, regenerate
   the documentation screenshots with `node tests/ui_screenshots.mjs` (writes `docs/images/ui/*.png`; needs Pillow
   to shrink them).
10. Open a pull request. CI runs ShellCheck, the PowerShell parser, PSScriptAnalyzer and smoke tests.

When you report a bug, include your OS and version, the command you ran, and the last 50 lines of
the server log or console output. Remove any passwords first.

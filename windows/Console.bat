@echo off
rem Run The Isle server in this window (watchdog, Ctrl+C to stop)
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IsleServer.ps1" Run %*
set "RC=%ERRORLEVEL%"
if not defined ISLE_NOPAUSE pause
exit /b %RC%

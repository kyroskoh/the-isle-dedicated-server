@echo off
rem Back up The Isle save data
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IsleServer.ps1" Backup %*
set "RC=%ERRORLEVEL%"
if not defined ISLE_NOPAUSE pause
exit /b %RC%

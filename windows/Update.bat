@echo off
rem Update The Isle dedicated server files via SteamCMD (stop the server first)
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IsleServer.ps1" Update %*
set "RC=%ERRORLEVEL%"
if not defined ISLE_NOPAUSE pause
exit /b %RC%

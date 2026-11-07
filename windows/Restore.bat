@echo off
rem Restore a backup: Restore.bat -Path "C:\TheIsle\backups\theisle-YYYYMMDD-HHMMSS.zip" (.zip or .tar.gz)
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IsleServer.ps1" Restore %*
set "RC=%ERRORLEVEL%"
if not defined ISLE_NOPAUSE pause
exit /b %RC%

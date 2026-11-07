@echo off
rem Start The Isle dedicated server
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IsleServer.ps1" Start %*
set "RC=%ERRORLEVEL%"
if not defined ISLE_NOPAUSE pause
exit /b %RC%

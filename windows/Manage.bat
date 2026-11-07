@echo off
rem Run any IsleServer.ps1 command, e.g.:
rem   Manage.bat Whitelist add 76561198000000001
rem   Manage.bat Classes preset carnivores
rem   Manage.bat Profile apply realism
rem   Manage.bat Plugins install discord-notify
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IsleServer.ps1" %*
set "RC=%ERRORLEVEL%"
if not defined ISLE_NOPAUSE pause
exit /b %RC%

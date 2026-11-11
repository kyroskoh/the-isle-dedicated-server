@echo off
rem Web UI + REST API for this server (API docs at /docs). Stop it with Ctrl+C.
rem   UI.bat              http://localhost:8090/
rem   UI.bat --open       ...and open it in the browser
rem   UI.bat --port 9000  another port (or set UI_PORT in server.conf)
rem Show the access token with:  Manage.bat UiToken
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0IsleServer.ps1" UI %*
set "RC=%ERRORLEVEL%"
if not defined ISLE_NOPAUSE pause
exit /b %RC%

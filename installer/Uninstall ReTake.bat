@echo off
rem Double-click to uninstall ReTake. It runs Uninstall-ReTake.ps1 from the files folder next to this file.
title ReTake uninstaller
set "SCRIPT=%~dp0files\Uninstall-ReTake.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Uninstall-ReTake.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
echo.
pause

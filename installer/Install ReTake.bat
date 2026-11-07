@echo off
rem Double-click to install ReTake. It runs Install-ReTake.ps1 from the files folder next to this file.
title ReTake installer
set "SCRIPT=%~dp0files\Install-ReTake.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Install-ReTake.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
echo.
pause

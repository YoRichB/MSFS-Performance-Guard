@echo off
title MSFS Performance Guard uninstall
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-MSFSGuard.ps1"
if errorlevel 1 pause

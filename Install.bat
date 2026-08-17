@echo off
title MSFS Performance Guard installer
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MSFSGuard.ps1"
if errorlevel 1 pause

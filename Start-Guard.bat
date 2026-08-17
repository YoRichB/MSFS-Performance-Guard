@echo off
title MSFS Performance Guard
cd /d "%~dp0"
if exist "%~dp0MSFSGuard.exe" (
  start "" "%~dp0MSFSGuard.exe"
) else (
  start "" /min powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0MSFSGuard.ps1"
)

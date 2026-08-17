@echo off
title Stop MSFS Performance Guard
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { $e = [System.Threading.EventWaitHandle]::OpenExisting('Local\MSFSPerformanceGuard-Stop'); [void]$e.Set(); Write-Host 'Asked MSFS Performance Guard to resume slept programs and exit.' } catch { Write-Host 'Guard is not running.' }"
timeout /t 3 /nobreak >nul

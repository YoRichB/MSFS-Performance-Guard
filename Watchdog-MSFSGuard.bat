@echo off
REM Restarts MSFS Guard unless the user chose Exit, or a flight just ended.
cd /d "%~dp0"
if exist "%~dp0Logs\user-stopped.flag" exit /b 0
if exist "%~dp0Logs\session-complete.flag" (
  tasklist /FI "IMAGENAME eq FlightSimulator2024.exe" | find /I "FlightSimulator2024.exe" >nul
  if errorlevel 1 (
    tasklist /FI "IMAGENAME eq FlightSimulator.exe" | find /I "FlightSimulator.exe" >nul
    if errorlevel 1 exit /b 0
  )
)
tasklist /FI "IMAGENAME eq MSFSGuard.exe" | find /I "MSFSGuard.exe" >nul
if errorlevel 1 (
  start "" "%~dp0MSFSGuard.exe"
)

@echo off
cd /d "%~dp0"
if exist "%~dp0Logs\latest-session.md" (
  start "" "%~dp0Logs\latest-session.md"
) else (
  echo No session report yet. Finish a Flight Simulator session first.
  pause
)

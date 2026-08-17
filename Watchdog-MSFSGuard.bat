@echo off
REM Hidden hand-off. Prefer the .vbs scheduled task so no console flashes in-game.
wscript.exe //B //Nologo "%~dp0Watchdog-MSFSGuard.vbs"

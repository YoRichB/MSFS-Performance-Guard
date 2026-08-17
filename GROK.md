# Grok: read this before changing MSFS Performance Guard

This folder is a live tray app. After **every Flight Simulator session** it writes how well it did and what to change next.

## Read in this order

1. `Logs/GROK-DEV-BRIEFING.md` - prioritized development tasks from recent flights
2. `Logs/latest-session.md` - last flight, human-readable
3. `Logs/latest-session.json` - same data, structured
4. `Logs/Sessions/` - older flights
5. `MSFSGuard.ps1` + `Config.json`

If those files exist, **use them**. Do not guess about nag rate, missed programs, Sleep failures, or tick cost.

## What to implement

Do the **Next development tasks** in the briefing, highest priority first. Typical work:

- add a process to `KnownHogs` / `$script:Friendly`
- retune thresholds for this 32-core PC
- make Sleep more reliable when not elevated
- add `FocusSleepList` if the user always sleeps the same apps
- speed up the monitor tick if session reports show slow samples

## Rules

- Sleep / Close stay opt-in unless `AutoSleepKnownHogs` is already true
- Never suggest companions, Defender, or protected OS processes
- After edits: parse `MSFSGuard.ps1` for syntax errors, then restart the tray app (`Stop-Guard.bat` then `Start-Guard.bat`)
- Do not churn defaults after a grade-A clean session
- Optional smoke test (writes a fake session, then delete it): `powershell -NoProfile -ExecutionPolicy Bypass -File MSFSGuard.ps1 -WriteTestReport`

# MSFS Performance Guard

A tray app that watches the PC **only while Microsoft Flight Simulator is running**. If Chrome, OneDrive, Discord, Edge, Steam’s web helper, or another heavy program is stealing CPU, RAM, or disk, a small overlay appears so you can:

- **Sleep** — freeze the program (reversible; it wakes when MSFS exits, or when you resume it)
- **Close** — quit it (asks first; unsaved work can be lost)
- **Ignore** — leave it alone for this flight
- **Never** — never suggest that program again

It does **not** kill or freeze anything on its own unless you turn on `AutoSleepKnownHogs` in `Config.json`. Windows protected processes, Defender, GPU/USB helpers (iCUE, NVIDIA), and sim add-ons (FSUIPC, Little Navmap, vPilot, BeyondATC, SimToolkitPro, …) are never suggested.

Looks and installs the same way as **BootOptimizer**: dark overlay, scheduled task at sign-in, JSON config.

## Install

1. Open `Documents\MSFS-Performance-Guard`
2. Double-click **`Install.bat`**
3. Choose how it should start:
   - **1 — When Flight Simulator starts** (recommended). A hidden listener waits after you sign in and launches Guard by itself when MSFS 2020/2024 starts. You do not have to start Guard manually.
   - **2 — Manual only.** Guard runs only when you double-click the **MSFS Guard** desktop shortcut.
4. Approve the administrator prompt

Run **Install.bat** again any time to switch between those two modes. Elevation is what lets Sleep/Close reach more programs.

A **bright blue plane** sits in the system tray (dark square, cyan jet, status dot). A labeled **MSFS Guard** badge also sits at the bottom-right of the screen, and a **MSFS Guard** button appears on the taskbar. That is how you know it is running.

Double-click `MSFSGuard.exe` (or `Start-Guard.bat`) to start it. If you closed the badge, right-click the tray plane → **Show on-screen badge**.

| Icon color | Meaning |
| --- | --- |
| Blue ring / lamp | Running, waiting for Flight Simulator (or paused) |
| Green | Sim is running and the PC looks clean |
| Amber | A suggestion is up, or programs are slept |

Windows often tucks new icons behind the `^` overflow next to the clock. Click `^` and drag the plane onto the taskbar if you want it always visible. The guard also asks Windows to pin it.

## Useful buttons

| File | Purpose |
| --- | --- |
| `Install.bat` | Start automatically at sign-in |
| `Uninstall.bat` | Remove that task (files stay) |
| `Start-Guard.bat` | Run it now, hidden, until you exit |
| `Open-Dashboard.bat` | Run / focus the live dashboard |
| `Stop-Guard.bat` | Resume anything you slept and quit |
| `Open-Last-Session.bat` | Open the last flight's report |
| `Config.json` | Thresholds, allowlists, known hogs |

## How it decides something is a bottleneck

Every ~2.5 seconds it samples other processes. A program is suggested only if it stays loud for **3 samples in a row** (~7.5 s), so a one-second spike is ignored.

Default triggers (CPU is Task Manager style — percent of the whole machine). The 8% / 3.5% figures are calibrated for an 8-core PC and are scaled automatically (this box has many cores, so the real bar is lower or the tool would never fire):

| Signal | Normal program | Known hog (Chrome, OneDrive, …) |
| --- | --- | --- |
| CPU | ≥ 8% on an 8-core (scaled) | ≥ 3.5% on an 8-core (scaled) |
| RAM | ≥ 900 MB | ≥ 400 MB |
| Disk | ≥ 8 MB/s (OneDrive / Drive / Steam / Search) | same |
| Low RAM | if less than 2 GB is free, RAM trigger drops to 500 MB | same |

MSFS 2020 (`FlightSimulator`) and MSFS 2024 (`FlightSimulator2024`) are both detected.

## Tray menu

- Flight Simulator running / not
- Open dashboard (live top consumers + slept list)
- Resume all slept programs
- Pause watching
- Exit — always resumes anything still frozen

Left-click the icon to reopen the last suggestion or the dashboard.

When MSFS closes, slept programs are woken automatically and a **session report** is written.

## After each flight

When Flight Simulator exits (or you quit the guard mid-flight), the app grades itself and writes:

| File | What it is |
| --- | --- |
| `Logs/latest-session.md` | How the last flight went, plus optimize-next notes |
| `Logs/latest-session.json` | Same facts for tools |
| `Logs/Sessions\*.md` / `*.json` | One pair per flight |
| `Logs/GROK-DEV-BRIEFING.md` | Rolling "what Grok should change next" from recent flights |

The tray balloon shows the grade (A-F). Right-click the icon → **Open last session report**, or double-click `Open-Last-Session.bat`.

The report includes:

- FPS from the sim itself (SimConnect **Frame** event — the official in-sim frame rate), with PresentMon as backup
- your current sim settings from `UserCfg.opt` (Max Frame Rate, VSync, Dynamic Settings, TLOD/OLOD, clouds, traffic) so advice matches what the sim is actually set to
- a Dev-FPS-style limiter: **Limited by MainThread**, **Limited by GPU**, Memory, Disk, or Network, plus how much of the flight each one lasted
- CPU, GPU, VRAM, RAM, disk queue, and network rates so the card can say what actually held frames down
- MSFS CPU / RAM and how much free RAM you had
- which overlays appeared, and whether you Slept, Closed, Ignored, or dismissed them
- programs that were loud but never suggested (missed hogs)
- concrete next-time advice (graphics vs other programs vs streaming/disk)
- a **If updating with Grok** task list so the next code change is based on this PC, not guesses

Tell Grok: *read `GROK.md` and `Logs/GROK-DEV-BRIEFING.md`, then apply the next development tasks.*

## Config you may want to flip

Edit `Config.json`, then use **Stop-Guard** and **Start-Guard** (or sign out/in) so the new values load.

```json
"CpuPercentThreshold": 8,       // raise if it nags too often
"MemoryMBThreshold": 900,
"DismissMinutes": 15,           // quiet time after you hit Not now
"AutoSleepKnownHogs": false,    // true = freeze Chrome/OneDrive/etc. without asking
"UserAllowlist": ["Discord"]    // or click Never on the overlay
```

Add extra sim tools to `CompanionAllowlist` so they are never suggested. Add extra browsers / launchers to `KnownHogs` to treat them more strictly.

## Safety

- Sleep uses the same `NtSuspendProcess` call as Process Explorer / Process Lasso. The program stays in Task Manager, frozen.
- Close is `Stop-Process` and always asks.
- Protected OS processes, Defender, Explorer, and the allowlists cannot be slept or closed from this UI.
- If the guard crashes, the next start resumes anything it left frozen (unless MSFS is still up).
- Exiting the guard always resumes slept programs.

Sleep is safer than Close mid-flight. Close is better when you want the RAM back.

## If Sleep does nothing

The process is likely protected or running as another user. Use **Install.bat** so the guard is elevated, or use Close. Some Store / anti-cheat processes cannot be frozen; those are left alone.

## Uninstall

Double-click `Uninstall.bat`. The scheduled task goes away and the running tray app is asked to quit (and resume anything it slept). Delete this folder if you also want the scripts and logs gone.

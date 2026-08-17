#requires -Version 5.1
<#
.SYNOPSIS
    Registers MSFS Performance Guard so it starts hidden at sign-in.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'MSFSGuard.ps1'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Requesting administrator approval...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    exit
}

if (-not (Test-Path -LiteralPath $engine)) {
    throw "MSFSGuard.ps1 not found in $here"
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$engine`""

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$settings.DisallowStartIfOnBatteries = $false
$settings.StopIfGoingOnBatteries = $false

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Delay = 'PT20S'
$action = New-ScheduledTaskAction -Execute $ps -Argument $args
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

Register-ScheduledTask `
    -TaskName 'MSFS-Performance-Guard' `
    -TaskPath '\' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'MSFS Performance Guard: tray monitor that suggests Sleep/Close for programs competing with Flight Simulator.' `
    -Force | Out-Null

Unblock-File -Path (Join-Path $here '*.ps1') -ErrorAction SilentlyContinue
Unblock-File -Path (Join-Path $here '*.bat') -ErrorAction SilentlyContinue

# Start it now if it is not already sitting in the tray.
$running = $false
try {
    $m = [System.Threading.Mutex]::OpenExisting('Local\MSFSPerformanceGuard')
    if ($m) { $running = $true; $m.Dispose() }
} catch { $running = $false }

if (-not $running) {
    $exe = Join-Path $here 'MSFSGuard.exe'
    if (Test-Path -LiteralPath $exe) {
        Start-Process -FilePath $exe
    } else {
        Start-ScheduledTask -TaskName 'MSFS-Performance-Guard'
    }
}

Write-Host ''
Write-Host 'MSFS Performance Guard will start 20 seconds after you sign in.' -ForegroundColor Green
Write-Host 'It is in the system tray now (hidden icons ^ if you do not see it).' -ForegroundColor Green
Write-Host ''
Write-Host 'Sleep / Close work on more programs because the task runs elevated.'
Write-Host 'Edit Config.json any time — the next process start picks it up.'
Write-Host ''
Write-Host 'Press Enter to close.'
[void][Console]::ReadLine()

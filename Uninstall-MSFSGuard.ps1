#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    exit
}

# Ask the tray app to resume slept programs and exit cleanly.
try {
    $stop = [System.Threading.EventWaitHandle]::OpenExisting('Local\MSFSPerformanceGuard-Stop')
    [void]$stop.Set()
    Start-Sleep -Seconds 2
} catch { }

$task = Get-ScheduledTask -TaskName 'MSFS-Performance-Guard' -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName 'MSFS-Performance-Guard' -Confirm:$false
    Write-Host 'Removed scheduled task: MSFS-Performance-Guard' -ForegroundColor Green
} else {
    Write-Host 'Task not found: MSFS-Performance-Guard' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Automatic startup is stopped. The folder, logs, and Config.json were left in place.' -ForegroundColor Cyan
Write-Host 'Delete the folder yourself if you also want the files gone.'
Write-Host ''
Write-Host 'Press Enter to close.'
[void][Console]::ReadLine()

#requires -Version 5.1
<#
.SYNOPSIS
    Registers (or removes) automatic start based on StartMode.
.PARAMETER StartMode
    WhenMsfsStarts - hidden listener at sign-in; Guard launches when MSFS starts.
    Manual         - no automatic tasks; desktop shortcut only.
#>
[CmdletBinding()]
param(
    [ValidateSet('WhenMsfsStarts', 'Manual')]
    [string]$StartMode = 'WhenMsfsStarts'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $here 'MSFSGuard.exe'
$listen = Join-Path $here 'Listen-MSFSGuard.vbs'
$watchVbs = Join-Path $here 'Watchdog-MSFSGuard.vbs'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

function Remove-GuardTask([string]$Name) {
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
}

Remove-GuardTask 'MSFS-Guard-Logon'
Remove-GuardTask 'MSFS-Guard-Watchdog'
Remove-GuardTask 'MSFS-Guard-Listener'
Remove-GuardTask 'MSFS-Performance-Guard'

if ($StartMode -eq 'Manual') {
    Write-Host 'Automatic start is off. Use the desktop MSFS Guard shortcut when you want it.' -ForegroundColor Cyan
    return
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$prin = New-Object Security.Principal.WindowsPrincipal($id)
$elevated = $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
if ($elevated) {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
}

$settingsListen = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logon.Delay = 'PT15S'
$actionListen = New-ScheduledTaskAction -Execute $wscript -Argument "//B //Nologo `"$listen`"" -WorkingDirectory $here

Register-ScheduledTask -TaskName 'MSFS-Guard-Listener' -Action $actionListen -Trigger $logon `
    -Principal $principal -Settings $settingsListen `
    -Description 'Hidden listener: starts MSFS Guard when Flight Simulator launches.' -Force | Out-Null

$settingsWatch = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$actionWatch = New-ScheduledTaskAction -Execute $wscript -Argument "//B //Nologo `"$watchVbs`"" -WorkingDirectory $here
$watchTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName 'MSFS-Guard-Watchdog' -Action $actionWatch -Trigger $watchTrigger `
    -Principal $principal -Settings $settingsWatch `
    -Description 'If the MSFS Guard listener dies, start the elevated listener task again. Does not launch Guard itself.' -Force | Out-Null

Write-Host 'Automatic start is on: Guard will launch when Flight Simulator starts.' -ForegroundColor Green

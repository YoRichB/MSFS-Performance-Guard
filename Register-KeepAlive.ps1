#requires -Version 5.1
# User-level keepalive: start at logon and re-check every 2 minutes.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$watch = Join-Path $here 'Watchdog-MSFSGuard.bat'
$exe = Join-Path $here 'MSFSGuard.exe'

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$actionLogon = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $here
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$prin = New-Object Security.Principal.WindowsPrincipal($id)
$elevated = $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
if ($elevated) {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
}

Register-ScheduledTask -TaskName 'MSFS-Guard-Logon' -Action $actionLogon -Trigger $logon `
    -Principal $principal -Settings $settings `
    -Description 'Start MSFS Performance Guard when you sign in.' -Force | Out-Null

schtasks.exe /Create /TN 'MSFS-Guard-Watchdog' /TR "`"$watch`"" /SC MINUTE /MO 2 /F | Out-Null

Write-Host 'Keepalive tasks registered: MSFS-Guard-Logon and MSFS-Guard-Watchdog' -ForegroundColor Green

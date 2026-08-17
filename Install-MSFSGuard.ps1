#requires -Version 5.1
<#
.SYNOPSIS
    Installs MSFS Performance Guard and asks how it should start.
#>
[CmdletBinding()]
param(
    [ValidateSet('WhenMsfsStarts', 'Manual')]
    [string]$StartMode
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'MSFSGuard.ps1'
$exe = Join-Path $here 'MSFSGuard.exe'
$configPath = Join-Path $here 'Config.json'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $StartMode) {
    Write-Host ''
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host '  MSFS Performance Guard - Install' -ForegroundColor Cyan
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'How should MSFS Guard start?'
    Write-Host ''
    Write-Host '  1) Automatically when Flight Simulator starts   (recommended)'
    Write-Host '     A hidden listener waits in the background. No need to start Guard yourself.'
    Write-Host ''
    Write-Host '  2) Manually only'
    Write-Host '     You start it from the desktop shortcut when you want it.'
    Write-Host ''
    $pick = Read-Host 'Enter 1 or 2'
    if ($pick -eq '2') {
        $StartMode = 'Manual'
    } else {
        $StartMode = 'WhenMsfsStarts'
    }
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Requesting administrator approval...' -ForegroundColor Yellow
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -StartMode $StartMode"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -Verb RunAs
    exit
}

if (-not (Test-Path -LiteralPath $engine)) {
    throw "MSFSGuard.ps1 not found in $here"
}

# Persist choice
if (Test-Path -LiteralPath $configPath) {
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName StartMode -NotePropertyValue $StartMode -Force
        $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
    } catch {
        Write-Host "Could not write StartMode to Config.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

& (Join-Path $here 'Register-KeepAlive.ps1') -StartMode $StartMode

Unblock-File -Path (Join-Path $here '*.ps1') -ErrorAction SilentlyContinue
Unblock-File -Path (Join-Path $here '*.bat') -ErrorAction SilentlyContinue
Unblock-File -Path (Join-Path $here '*.vbs') -ErrorAction SilentlyContinue

# Desktop shortcut always
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop 'MSFS Guard.lnk'
$w = New-Object -ComObject WScript.Shell
$lnk = $w.CreateShortcut($lnkPath)
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $here
$lnk.WindowStyle = 1
$lnk.Description = 'MSFS Performance Guard'
$ico = Join-Path $here 'Icons\guard-idle.ico'
if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
$lnk.Save()

if ($StartMode -eq 'WhenMsfsStarts') {
    $listen = Join-Path $here 'Listen-MSFSGuard.vbs'
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    Start-Process -FilePath $wscript -ArgumentList "//B //Nologo `"$listen`"" -WorkingDirectory $here -WindowStyle Hidden
    Write-Host ''
    Write-Host 'Installed.' -ForegroundColor Green
    Write-Host 'A hidden listener is on. When you start Flight Simulator, MSFS Guard will start by itself.'
    Write-Host 'A desktop shortcut is there if you ever want to open it manually.'
} else {
    Write-Host ''
    Write-Host 'Installed (manual start).' -ForegroundColor Green
    Write-Host 'Double-click "MSFS Guard" on the desktop when you want it. It will not start on its own.'
}

Write-Host ''
Write-Host 'Sleep / Close work on more programs because the installer ran as administrator.'
Write-Host 'Run Install.bat again any time to change auto-start vs manual.'
Write-Host ''
Write-Host 'Press Enter to close.'
[void][Console]::ReadLine()

#requires -Version 5.1
<#
.SYNOPSIS
    MSFS Performance Guard - background monitor for Microsoft Flight Simulator.

.DESCRIPTION
    Lives in the system tray. While Flight Simulator is running it watches other
    programs for CPU, RAM, and disk pressure, then pops a suggestion overlay so
    you can Sleep (freeze) or Close the hog. It also samples FPS (PresentMon),
    GPU, RAM, disk, and network the same way the sim Dev FPS overlay does, so
    the flight report can say what actually limited frames. Slept programs are
    resumed when MSFS exits, when you ask, or when this app quits.

    Never touches Windows protected processes, Defender, or your sim add-ons.
    Nothing is closed or frozen without a click (unless you turn on AutoSleep).
#>
[CmdletBinding()]
param(
    [switch]$Visible,
    [switch]$WriteTestReport,
    [switch]$ShowLastReport
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:Root 'Config.json'
$script:StatePath = Join-Path $script:Root 'state.json'
$script:LogDir = Join-Path $script:Root 'Logs'

$script:Headless = [bool]($WriteTestReport -or $ShowLastReport)

if ($WriteTestReport -or $ShowLastReport) {
    # Fall through. Mutex / tray are skipped after functions load.
}

if (-not $WriteTestReport -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Visible) { $arg += ' -Visible' }
    if ($ShowLastReport) { $arg += ' -ShowLastReport' }
    $style = if ($Visible -or $ShowLastReport) { 'Normal' } else { 'Hidden' }
    Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle $style
    exit
}

# -----------------------------------------------------------------------------
# Single instance
# -----------------------------------------------------------------------------
$script:CreatedMutex = $true
$script:Mutex = $null
if (-not $script:Headless) {
    $script:CreatedMutex = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\MSFSPerformanceGuard', [ref]$script:CreatedMutex)
    if (-not $script:CreatedMutex) {
        try {
            $show = [System.Threading.EventWaitHandle]::OpenExisting('Local\MSFSPerformanceGuard-Show')
            [void]$show.Set()
        } catch { }
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
if (-not $WriteTestReport) {
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
if (-not $script:Headless) {
    $script:StopEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\MSFSPerformanceGuard-Stop')
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\MSFSPerformanceGuard-Show')
    [void]$script:StopEvent.Reset()
    [void]$script:ShowEvent.Reset()
}

if (-not $WriteTestReport -and -not ('GuardToastForm' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class GuardToastForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            return cp;
        }
    }
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
    public void RoundCorners(int radius) {
        this.Region = System.Drawing.Region.FromHrgn(CreateRoundRectRgn(0, 0, this.Width + 1, this.Height + 1, radius, radius));
    }
}
public static class NtProc {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr handle);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr handle);
    public const uint PROCESS_SUSPEND_RESUME = 0x1800;
}
"@
}

# -----------------------------------------------------------------------------
# Palette (matches BootOptimizer)
# -----------------------------------------------------------------------------
$script:C = @{
    Bg      = [System.Drawing.Color]::FromArgb(28, 28, 34)
    Panel   = [System.Drawing.Color]::FromArgb(36, 36, 44)
    Track   = [System.Drawing.Color]::FromArgb(48, 48, 58)
    Text    = [System.Drawing.Color]::FromArgb(244, 244, 248)
    Muted   = [System.Drawing.Color]::FromArgb(168, 170, 178)
    Ok      = [System.Drawing.Color]::FromArgb(62, 196, 120)
    Err     = [System.Drawing.Color]::FromArgb(232, 72, 85)
    Warn    = [System.Drawing.Color]::FromArgb(232, 168, 56)
    Accent  = [System.Drawing.Color]::FromArgb(80, 168, 232)
    Btn     = [System.Drawing.Color]::FromArgb(52, 52, 64)
    Sleep   = [System.Drawing.Color]::FromArgb(46, 92, 160)
    Close   = [System.Drawing.Color]::FromArgb(140, 52, 58)
}

$script:Friendly = @{
    chrome                     = 'Google Chrome'
    msedge                     = 'Microsoft Edge'
    firefox                    = 'Mozilla Firefox'
    opera                      = 'Opera'
    brave                      = 'Brave'
    OneDrive                   = 'Microsoft OneDrive'
    OneDriveStandaloneUpdater  = 'OneDrive Updater'
    GoogleDriveFS              = 'Google Drive'
    Dropbox                    = 'Dropbox'
    Teams                      = 'Microsoft Teams'
    'ms-teams'                 = 'Microsoft Teams'
    Slack                      = 'Slack'
    Zoom                       = 'Zoom'
    Spotify                    = 'Spotify'
    Discord                    = 'Discord'
    DiscordPTB                 = 'Discord'
    steamwebhelper             = 'Steam (web helper)'
    EpicGamesLauncher          = 'Epic Games Launcher'
    EpicWebHelper              = 'Epic Games (web)'
    SearchIndexer              = 'Windows Search Indexer'
    CompatTelRunner            = 'Windows Compatibility Telemetry'
    GameBar                    = 'Xbox Game Bar'
    GameBarFTW                 = 'Xbox Game Bar'
    Widgets                    = 'Windows Widgets'
    PhoneExperienceHost        = 'Phone Link'
    OUTLOOK                    = 'Outlook'
    olk                        = 'Outlook'
    Copilot                    = 'Microsoft Copilot'
    Code                       = 'Visual Studio Code'
    Cursor                     = 'Cursor'
    devenv                     = 'Visual Studio'
    WINWORD                    = 'Microsoft Word'
    EXCEL                      = 'Microsoft Excel'
    POWERPNT                   = 'Microsoft PowerPoint'
    CCXProcess                 = 'Adobe Creative Cloud'
    BackgroundDownload         = 'Background Download'
    PPUninstaller              = 'PP Uninstaller'
    SimFlightTab               = 'Sim Flight Tab'
    'vatsim-radar'             = 'VATSIM Radar'
    SteelSeriesGGClient        = 'SteelSeries GG'
    SteelSeriesGGEZ            = 'SteelSeries GG'
    QtWebEngineProcess         = 'Qt WebEngine'
}

$script:DiskWatch = @(
    'OneDrive', 'OneDriveStandaloneUpdater', 'GoogleDriveFS', 'Dropbox',
    'steam', 'steamwebhelper', 'SearchIndexer', 'MsMpEng'
)

# -----------------------------------------------------------------------------
# Logging / config / state
# -----------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'OK', 'ERR')]
        [string]$Level = 'INFO'
    )
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $line = '{0:yyyy-MM-dd HH:mm:ss}  [{1}]  {2}' -f (Get-Date), $Level, $Message
    $log = Join-Path $script:LogDir ('MSFSGuard-{0:yyyyMMdd}.log' -f (Get-Date))
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($Visible) { Write-Host $line }
}

function Get-DefaultConfig {
    return @{
        MsfsProcessNames           = @('FlightSimulator', 'FlightSimulator2024')
        SampleSeconds              = 2.5
        PersistSamples             = 3
        CpuPercentThreshold        = 8.0
        MemoryMBThreshold          = 900
        LowRamMB                   = 2048
        LowRamMemoryMBThreshold    = 500
        DiskMBpsThreshold          = 8.0
        KnownHogSoftCpuPercent     = 3.5
        KnownHogSoftMemoryMB       = 400
        DismissMinutes             = 15
        AutoResumeWhenMsfsExits    = $true
        AutoSleepKnownHogs         = $false
        ShowSuggestionOverlay      = $false
        MaxSuggestions             = 5
        ShowWelcome                = $true
        ShowCornerBadge            = $false
        ExitAfterSession           = $true
        StartMode                  = 'WhenMsfsStarts'
        WriteSessionReports        = $true
        MinSessionSeconds          = 45
        BriefingKeepSessions       = 8
        UserAllowlist              = @()
        KnownHogs                  = @()
        CompanionAllowlist         = @()
        ProtectedNames             = @()
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        Write-Log "Failed to read $Path : $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Convert-ToStringArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -ne $item -and "$item".Trim().Length -gt 0) {
            [void]$list.Add("$item")
        }
    }
    return , $list.ToArray()
}

function Import-Config {
    $cfg = Get-DefaultConfig
    $loaded = Read-JsonFile $script:ConfigPath
    $arrayKeys = New-IgnoreSet -Names @(
        'MsfsProcessNames', 'UserAllowlist', 'KnownHogs',
        'CompanionAllowlist', 'ProtectedNames', 'FocusSleepList', 'DoNotSleepNames'
    )
    if ($loaded) {
        foreach ($p in $loaded.PSObject.Properties) {
            if ($cfg.ContainsKey($p.Name)) {
                if ($arrayKeys.Contains($p.Name) -or $cfg[$p.Name] -is [array]) {
                    $cfg[$p.Name] = Convert-ToStringArray $p.Value
                } else {
                    $cfg[$p.Name] = $p.Value
                }
            }
        }
    }
    return $cfg
}

function Save-UserAllowlist {
    $loaded = Read-JsonFile $script:ConfigPath
    if (-not $loaded) { return }
    $loaded.UserAllowlist = @($script:Config.UserAllowlist)
    try {
        $loaded | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    } catch {
        Write-Log "Could not save allowlist: $($_.Exception.Message)" 'WARN'
    }
}

function Import-State {
    $st = Read-JsonFile $script:StatePath
    if (-not $st) {
        return @{ Slept = @(); WelcomeShown = $false; IconHintShown = $false }
    }
    return $st
}

function Save-State {
    try {
        $obj = [ordered]@{
            WelcomeShown = [bool]$script:WelcomeShown
            IconHintShown = [bool]$script:IconHintShown
            SavedAt      = (Get-Date).ToString('o')
            Slept        = @($script:Slept.GetEnumerator() | ForEach-Object {
                    [ordered]@{
                        Name = $_.Key
                        Pids = @($_.Value.Pids)
                        At   = $_.Value.At
                    }
                })
        }
        ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
    } catch {
        Write-Log "Could not save state: $($_.Exception.Message)" 'WARN'
    }
}

function New-IgnoreSet {
    param([string[]]$Names)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($Names)) { if ($n) { [void]$set.Add($n) } }
    # Unary comma stops PowerShell unrolling an empty HashSet into $null.
    return , $set
}

# -----------------------------------------------------------------------------
# Process control
# -----------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FriendlyName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    try {
        if ($null -ne $script:Friendly) {
            if ($script:Friendly.ContainsKey($Name)) { return [string]$script:Friendly[$Name] }
            foreach ($k in $script:Friendly.Keys) {
                if ($k -ieq $Name) { return [string]$script:Friendly[$k] }
            }
        }
    } catch { }
    return $Name
}

function Get-LivePids {
    param([string]$Name)
    @(Get-Process -Name $Name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

function Suspend-Pid {
    param([int]$ProcessId)
    $h = [NtProc]::OpenProcess([NtProc]::PROCESS_SUSPEND_RESUME, $false, $ProcessId)
    if ($h -eq [IntPtr]::Zero) { return $false }
    try {
        $code = [NtProc]::NtSuspendProcess($h)
        return ($code -eq 0)
    } finally {
        [void][NtProc]::CloseHandle($h)
    }
}

function Resume-Pid {
    param([int]$ProcessId)
    $h = [NtProc]::OpenProcess([NtProc]::PROCESS_SUSPEND_RESUME, $false, $ProcessId)
    if ($h -eq [IntPtr]::Zero) { return $false }
    try {
        $code = [NtProc]::NtResumeProcess($h)
        return ($code -eq 0)
    } finally {
        [void][NtProc]::CloseHandle($h)
    }
}

function Invoke-SleepNamed {
    param([string]$Name)
    if ($script:Protected.Contains($Name) -or $script:Companions.Contains($Name)) {
        Write-Log "Refusing to sleep protected/companion process $Name" 'WARN'
        return 0
    }
    $pids = Get-LivePids $Name
    $ok = New-Object System.Collections.Generic.List[int]
    foreach ($id in $pids) {
        if ($id -eq $PID) { continue }
        if (Suspend-Pid $id) { [void]$ok.Add($id) }
    }
    if ($ok.Count -gt 0) {
        $script:Slept[$Name] = @{ Pids = @($ok.ToArray()); At = (Get-Date).ToString('o') }
        $script:SessionIgnore.Add($Name) | Out-Null
        Save-State
        Write-Log "Slept $Name ($($ok.Count) process(es))" 'OK'
        Add-SessionAction -Type 'sleep' -Name $Name -Ok $true -Detail "$($ok.Count) process(es)"
        Update-Tray
        return $ok.Count
    }
    Write-Log "Failed to sleep $Name (need admin, or process blocked it)" 'WARN'
    Add-SessionAction -Type 'sleep' -Name $Name -Ok $false -Detail 'OpenProcess/NtSuspend failed'
    return 0
}

function Invoke-ResumeNamed {
    param([string]$Name)
    $count = 0
    $pids = @()
    if ($script:Slept.ContainsKey($Name)) { $pids = @($script:Slept[$Name].Pids) }
    $pids = @($pids + (Get-LivePids $Name) | Select-Object -Unique)
    foreach ($id in $pids) {
        if (Resume-Pid $id) { $count++ }
    }
    [void]$script:Slept.Remove($Name)
    Save-State
    Write-Log "Resumed $Name ($count handle(s))" 'OK'
    Update-Tray
    return $count
}

function Invoke-ResumeAll {
    $names = @($script:Slept.Keys)
    foreach ($n in $names) { [void](Invoke-ResumeNamed $n) }
    return $names.Count
}

function Invoke-CloseNamed {
    param([string]$Name)
    if ($script:Protected.Contains($Name) -or $script:Companions.Contains($Name)) {
        Write-Log "Refusing to close protected/companion process $Name" 'WARN'
        return $false
    }
    try {
        if ($script:Slept.ContainsKey($Name)) { [void](Invoke-ResumeNamed $Name) }
        Stop-Process -Name $Name -Force -ErrorAction Stop
        $script:SessionIgnore.Add($Name) | Out-Null
        Write-Log "Closed $Name" 'OK'
        Add-SessionAction -Type 'close' -Name $Name -Ok $true
        Update-Tray
        return $true
    } catch {
        Write-Log "Failed to close $Name : $($_.Exception.Message)" 'WARN'
        Add-SessionAction -Type 'close' -Name $Name -Ok $false -Detail $_.Exception.Message
        return $false
    }
}

# -----------------------------------------------------------------------------
# Sampling
# -----------------------------------------------------------------------------
function Get-Snapshot {
    $items = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $cpu = 0.0
        try { $cpu = $_.TotalProcessorTime.TotalSeconds } catch { $cpu = 0.0 }
        $ws = [int64]0
        try { $ws = [int64]$_.WorkingSet64 } catch { $ws = 0 }
        $items[$_.Id] = @{
            Pid    = $_.Id
            Name   = $_.ProcessName
            CpuSec = $cpu
            Ws     = $ws
        }
    }
    return @{ At = [datetime]::UtcNow; Items = $items }
}

function Get-IoBytes {
    param([int[]]$Pids)
    $map = @{}
    if (-not $Pids -or $Pids.Count -eq 0) { return $map }
    $chunks = New-Object System.Collections.Generic.List[string]
    foreach ($id in $Pids) { [void]$chunks.Add("ProcessId=$id") }
    # CIM filter length is limited; do 25 at a time
    for ($i = 0; $i -lt $chunks.Count; $i += 25) {
        $end = [Math]::Min($i + 24, $chunks.Count - 1)
        $filter = ($chunks[$i..$end] -join ' OR ')
        try {
            Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop | ForEach-Object {
                $map[[int]$_.ProcessId] = [int64]$_.ReadTransferCount + [int64]$_.WriteTransferCount
            }
        } catch { }
    }
    return $map
}

function Get-FreeRamMB {
    if ($script:FreeRamCachedAt -and (((Get-Date) - $script:FreeRamCachedAt).TotalSeconds -lt 5)) {
        return [int]$script:FreeRamCached
    }
    $mb = 0
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $mb = [int]([double]$os.FreePhysicalMemory / 1024.0)
    } catch {
        $mb = 0
    }
    $script:FreeRamCached = $mb
    $script:FreeRamCachedAt = Get-Date
    return $mb
}

function Initialize-HardwareCounters {
    if ($script:HwReady) { return }
    $script:HwReady = $false
    try {
        $script:PcCpu = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
        $script:PcDiskQ = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', 'Avg. Disk Queue Length', '_Total')
        $script:PcDiskB = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', 'Disk Bytes/sec', '_Total')
        $nets = New-Object System.Collections.Generic.List[object]
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('Network Interface')
        foreach ($inst in $cat.GetInstanceNames()) {
            if ($inst -match 'isatap|loopback|teredo|WAN Miniport') { continue }
            $nc = New-Object System.Diagnostics.PerformanceCounter('Network Interface', 'Bytes Total/sec', $inst)
            [void]$nc.NextValue()
            [void]$nets.Add($nc)
        }
        $script:PcNet = $nets
        [void]$script:PcCpu.NextValue()
        [void]$script:PcDiskQ.NextValue()
        [void]$script:PcDiskB.NextValue()
        $script:HwReady = $true
        $script:GpuFailLogged = $false
        Write-Log ('Hardware counters ready (CPU/disk/network x{0})' -f $nets.Count) 'OK'
        Initialize-VramCounters
    } catch {
        Write-Log ("Hardware counters failed: {0}" -f $_.Exception.Message) 'WARN'
    }
    $script:PresentMonExe = $null
    foreach ($p in @(
            "${env:ProgramFiles}\AMD\CNext\CNext\PresentMon-x64.exe",
            "${env:ProgramFiles(x86)}\PresentMon\PresentMon-x64.exe",
            "${env:ProgramFiles}\PresentMon\PresentMon-x64.exe"
        )) {
        if (Test-Path -LiteralPath $p) { $script:PresentMonExe = $p; break }
    }
    Ensure-FrameProbe
}

function Initialize-VramCounters {
    if ($script:GpuVramCounters -and $script:GpuVramCounters.Count -gt 0) { return }
    $script:GpuVramCounters = New-Object System.Collections.Generic.List[object]
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Adapter Memory')
        foreach ($inst in $cat.GetInstanceNames()) {
            try {
                $pc = New-Object System.Diagnostics.PerformanceCounter('GPU Adapter Memory', 'Dedicated Usage', $inst, $true)
                [void]$pc.NextValue()
                [void]$script:GpuVramCounters.Add($pc)
            } catch { }
        }
    } catch { }
}

function Sync-GpuCounters {
    param($MsfsPids)
    $want = New-Object System.Collections.Generic.List[int]
    foreach ($pid in @($MsfsPids)) {
        try { [void]$want.Add([int]$pid) } catch { }
    }
    $key = (($want | Sort-Object) -join ',')
    $fresh = $false
    if ($script:GpuSyncKey -ne $key) { $fresh = $true }
    if (-not $script:GpuEngineCounters -or $script:GpuEngineCounters.Count -eq 0) { $fresh = $true }
    if (($script:TickIndex % 20) -eq 2) { $fresh = $true }
    if (-not $fresh) { return }
    $script:GpuSyncKey = $key
    if ($script:GpuEngineCounters) {
        foreach ($item in $script:GpuEngineCounters) {
            try { $item.Counter.Dispose() } catch { }
        }
    }
    $script:GpuEngineCounters = New-Object System.Collections.Generic.List[object]
    if ($want.Count -eq 0) { return }
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Engine')
        $set = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($w in $want) { [void]$set.Add([int]$w) }
        foreach ($inst in $cat.GetInstanceNames()) {
            if ($inst -notmatch 'engtype_3d|engtype_graphics|engtype_compute') { continue }
            $pid = 0
            if ($inst -match 'pid_(\d+)_') { $pid = [int]$Matches[1] } else { continue }
            if (-not $set.Contains($pid)) { continue }
            try {
                $pc = New-Object System.Diagnostics.PerformanceCounter('GPU Engine', 'Utilization Percentage', $inst, $true)
                [void]$pc.NextValue()
                [void]$script:GpuEngineCounters.Add(@{ Pid = $pid; Counter = $pc })
            } catch { }
        }
        if ($script:GpuEngineCounters.Count -eq 0 -and -not $script:GpuFailLogged) {
            Write-Log ('GPU engine: no 3D/compute instances for pid(s) {0} yet' -f $key) 'INFO'
        }
    } catch {
        if (-not $script:GpuFailLogged) {
            $script:GpuFailLogged = $true
            Write-Log ("GPU Engine category: {0}" -f $_.Exception.Message) 'WARN'
        }
    }
}

function Get-GpuSample {
    param($MsfsPids)
    $row = [pscustomobject]@{ Gpu = 0.0; MsfsGpu = 0.0; VramMB = 0 }
    $gpu = 0.0
    $msfsGpu = 0.0
    if ($script:GpuEngineCounters) {
        foreach ($item in $script:GpuEngineCounters) {
            $v = 0.0
            try { $v = [double]$item.Counter.NextValue() } catch { continue }
            if ($v -le 0) { continue }
            if ($v -gt $gpu) { $gpu = $v }
            $msfsGpu += $v
        }
    }
    if ($msfsGpu -gt 100) { $msfsGpu = 100 }
    if ($msfsGpu -gt $gpu) { $gpu = $msfsGpu }
    $vramMB = 0
    if ($script:GpuVramCounters) {
        $max = 0.0
        foreach ($pc in $script:GpuVramCounters) {
            try {
                $v = [double]$pc.NextValue()
                if ($v -gt $max) { $max = $v }
            } catch { }
        }
        if ($max -gt 0) { $vramMB = [int]($max / 1MB) }
    }
    $row.Gpu = [math]::Round($gpu, 1)
    $row.MsfsGpu = [math]::Round($msfsGpu, 1)
    $row.VramMB = $vramMB
    return $row
}

function Get-NetMBps {
    $sum = 0.0
    if ($script:PcNet) {
        foreach ($c in $script:PcNet) {
            try { $sum += [double]$c.NextValue() } catch { }
        }
    }
    if ($sum -gt 0) { return [math]::Round($sum / 1MB, 3) }
    try {
        $rows = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
        foreach ($r in $rows) {
            if ($r.Name -match 'isatap|loopback|teredo|WAN Miniport') { continue }
            try { $sum += [double]$r.BytesTotalPersec } catch { }
        }
    } catch { }
    return [math]::Round($sum / 1MB, 3)
}

function Get-HardwareSample {
    param($MsfsPids)
    $cpu = 0.0
    $diskQ = 0.0
    $diskMBps = 0.0
    $netMBps = 0.0
    $gpuVal = 0.0
    $msfsGpu = 0.0
    $vramMB = 0
    if ($script:HwReady) {
        try { $cpu = [double]$script:PcCpu.NextValue() } catch { }
        try { $diskQ = [double]$script:PcDiskQ.NextValue() } catch { }
        try { $diskMBps = [double]$script:PcDiskB.NextValue() / 1MB } catch { }
        try { $netMBps = Get-NetMBps } catch { }
    }
    $gpu = $null
    if (($script:TickIndex % 2) -eq 0) {
        try { Sync-GpuCounters $MsfsPids } catch { }
        try { $gpu = Get-GpuSample $MsfsPids } catch { }
        if ($gpu) { $script:LastGpu = $gpu }
    } elseif ($script:LastGpu) {
        $gpu = $script:LastGpu
    }
    if ($gpu) {
        try { $gpuVal = [double]$gpu.Gpu } catch { }
        try { $msfsGpu = [double]$gpu.MsfsGpu } catch { }
        try { $vramMB = [int]$gpu.VramMB } catch { }
    }
    [pscustomobject]@{
        SysCpu   = [double]$cpu
        DiskQ    = [double]$diskQ
        DiskMBps = [double]$diskMBps
        NetMBps  = [double]$netMBps
        Gpu      = [double]$gpuVal
        MsfsGpu  = [double]$msfsGpu
        VramMB   = [int]$vramMB
    }
}

function Get-BottleneckName {
    param($Hw, [double]$MsfsCpu, [int]$FreeRamMB)
    if ($FreeRamMB -gt 0 -and $FreeRamMB -lt 2048) { return 'RAM' }
    if ($Hw.DiskQ -ge 2.5 -or $Hw.DiskMBps -ge 80) { return 'Disk' }
    if ($Hw.NetMBps -ge 20) { return 'Network' }
    $cap = 0
    if ($script:Session -and $script:Session.ContainsKey('FrameLimiter')) {
        try { $cap = [int]$script:Session.FrameLimiter } catch { }
    }
    $fps = 0.0
    if ($null -ne $script:LastFps) { try { $fps = [double]$script:LastFps } catch { } }
    $gpu = 0.0
    try { $gpu = [math]::Max([double]$Hw.Gpu, [double]$Hw.MsfsGpu) } catch {
        try { $gpu = [double]$Hw.Gpu } catch { }
    }
    if ($cap -ge 15 -and $cap -le 90 -and $fps -ge ($cap * 0.92)) {
        if ($gpu -lt 85 -and $MsfsCpu -lt 20 -and [double]$Hw.DiskQ -lt 2) { return 'Cap' }
    }
    if ($gpu -ge 88 -and $MsfsCpu -lt 22) { return 'GPU' }
    if ($MsfsCpu -ge 14 -or $Hw.SysCpu -ge 82) { return 'CPU' }
    if ($gpu -ge 78) { return 'GPU' }
    return 'None'
}

function Ensure-FrameProbe {
    $exe = Join-Path $script:Root 'MsfsFrameProbe.exe'
    $cs = Join-Path $script:Root 'MsfsFrameProbe.cs'
    $dll = Join-Path $script:Root 'SimConnect.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        $sdk = 'C:\MSFS 2024 SDK\SimConnect SDK\lib\SimConnect.dll'
        if (Test-Path -LiteralPath $sdk) {
            try { Copy-Item -LiteralPath $sdk -Destination $dll -Force } catch { }
        }
    }
    $needBuild = -not (Test-Path -LiteralPath $exe)
    if (-not $needBuild -and (Test-Path -LiteralPath $cs) -and (Test-Path -LiteralPath $exe)) {
        if ((Get-Item -LiteralPath $cs).LastWriteTime -gt (Get-Item -LiteralPath $exe).LastWriteTime) { $needBuild = $true }
    }
    if ($needBuild -and (Test-Path -LiteralPath $cs)) {
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (Test-Path -LiteralPath $csc) {
            try {
                $p = Start-Process -FilePath $csc -ArgumentList @('/nologo', '/optimize', '/target:winexe', "/out:$exe", $cs) -Wait -PassThru -WindowStyle Hidden
                if ($p.ExitCode -eq 0) { Write-Log 'Built MsfsFrameProbe.exe (SimConnect FPS)' 'OK' }
            } catch {
                Write-Log ("Frame probe compile failed: {0}" -f $_.Exception.Message) 'WARN'
            }
        }
    }
    $script:FrameProbeExe = $(if (Test-Path -LiteralPath $exe) { $exe } else { $null })
}

function Read-MsfsInternalSettings {
    $out = @{
        Path            = $null
        FrameLimiter    = 0
        VSync           = $false
        DynamicSettings = $false
        TargetFrameRate = 0
        FrameGeneration = 'NONE'
        AntiAliasing    = ''
        FsrMode         = ''
        Tlod            = 0.0
        Olod            = 0.0
        CloudsQuality   = -1
        TrafficQty      = -1
        Buildings       = -1
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt')
    )
    $path = $null
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $path = $c; break }
    }
    if (-not $path) { return $out }
    $out.Path = $path
    $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $out }
    if ($text -match '(?m)^\s*FrameLimiter\s+(\d+)') { $out.FrameLimiter = [int]$Matches[1] }
    if ($text -match '(?m)^\s*VSync\s+(\d+)') { $out.VSync = ([int]$Matches[1] -ne 0) }
    if ($text -match '(?m)^\s*DynamicSettings\s+(\d+)') { $out.DynamicSettings = ([int]$Matches[1] -ne 0) }
    if ($text -match '(?m)^\s*TargetFrameRate\s+(\d+)') { $out.TargetFrameRate = [int]$Matches[1] }
    if ($text -match '(?m)^\s*FrameGeneration\s+(\S+)') { $out.FrameGeneration = [string]$Matches[1] }
    if ($text -match '(?m)^\s*AntiAliasing\s+(\S+)') { $out.AntiAliasing = [string]$Matches[1] }
    if ($text -match '(?m)^\s*FSRMode\s+(\S+)') { $out.FsrMode = [string]$Matches[1] }
    $gIdx = $text.IndexOf('{Graphics')
    $gVr = $text.IndexOf('{GraphicsVR')
    if ($gIdx -ge 0) {
        $end = $text.Length
        if ($gVr -gt $gIdx) { $end = $gVr }
        $gfx = $text.Substring($gIdx, $end - $gIdx)
        if ($gfx -match '(?s)\{Terrain[^\{\}]*LoDFactor\s+([0-9.]+)') { $out.Tlod = [double]$Matches[1] }
        if ($gfx -match '(?s)\{ObjectsLoD[^\{\}]*LoDFactor\s+([0-9.]+)') { $out.Olod = [double]$Matches[1] }
        if ($gfx -match '(?s)\{VolumetricClouds[^\{\}]*Quality\s+(\d+)') { $out.CloudsQuality = [int]$Matches[1] }
        if ($gfx -match '(?s)\{Traffic[^\{\}]*AircraftTrafficQuantity\s+(-?\d+)') { $out.TrafficQty = [int]$Matches[1] }
        if ($gfx -match '(?s)\{Buildings[^\{\}]*Quality\s+(\d+)') { $out.Buildings = [int]$Matches[1] }
    }
    return $out
}

function Get-QualityName {
    param([int]$Q)
    switch ($Q) {
        0 { return 'Low' }
        1 { return 'Medium' }
        2 { return 'High' }
        3 { return 'Ultra' }
        default { return "$Q" }
    }
}

function Start-FpsCapture {
    $script:PresentMonPid = $null
    $script:SimConnectPid = $null
    $script:FpsSource = $null
    $script:PresentMonFile = Join-Path $script:LogDir 'presentmon-live.csv'
    $script:SimConnectJson = Join-Path $script:LogDir 'simconnect-live.json'
    $script:SimConnectCsv = Join-Path $script:LogDir 'simconnect-live.csv'
    foreach ($f in @($script:SimConnectJson, $script:SimConnectCsv, "$($script:SimConnectJson).tmp")) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    if ($script:FrameProbeExe -and (Test-Path -LiteralPath $script:FrameProbeExe)) {
        try {
            Get-Process MsfsFrameProbe -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:FrameProbeExe
            $psi.Arguments = '--json "' + $script:SimConnectJson + '" --csv "' + $script:SimConnectCsv + '" --parent ' + $PID
            $psi.WorkingDirectory = $script:Root
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $p = [System.Diagnostics.Process]::Start($psi)
            $script:SimConnectPid = $p.Id
            Write-Log ("SimConnect FPS started (MsfsFrameProbe pid={0})" -f $p.Id) 'OK'
        } catch {
            Write-Log ("SimConnect FPS failed: {0}" -f $_.Exception.Message) 'WARN'
        }
    }
    if (-not $script:PresentMonExe) { return }
    try {
        if (Test-Path -LiteralPath $script:PresentMonFile) {
            Remove-Item -LiteralPath $script:PresentMonFile -Force -ErrorAction SilentlyContinue
        }
        Get-Process PresentMon-x64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:PresentMonExe
        $psi.Arguments = '--process_name FlightSimulator2024.exe --process_name FlightSimulator.exe --output_file "' + $script:PresentMonFile + '" --stop_existing_session --no_console_stats --exclude_dropped --v1_metrics'
        $psi.WorkingDirectory = $script:LogDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $p = [System.Diagnostics.Process]::Start($psi)
        $script:PresentMonPid = $p.Id
        $script:PmMsCol = $null
        Write-Log ("PresentMon backup started (pid={0})" -f $p.Id) 'OK'
    } catch {
        Write-Log ("PresentMon backup failed: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Measure-FpsList {
    param($Vals)
    $out = @{ Count = 0; Avg = 0.0; Min = 0.0; Max = 0.0; AvgMs = 0.0 }
    if (-not $Vals -or $Vals.Count -le 0) { return $out }
    $m = $Vals | Measure-Object -Average -Minimum -Maximum
    $out.Count = [int]$m.Count
    $out.Avg = [math]::Round([double]$m.Average, 1)
    $out.Min = [math]::Round([double]$m.Minimum, 1)
    $out.Max = [math]::Round([double]$m.Maximum, 1)
    if ($out.Avg -gt 0) { $out.AvgMs = [math]::Round(1000.0 / $out.Avg, 1) }
    return $out
}

function Stop-FpsCapture {
    $stats = @{
        Count = 0; Avg = 0.0; Min = 0.0; Max = 0.0; AvgMs = 0.0; Source = 'none'; SimSpeed = 1.0
        GameplayCount = 0; GameplayAvg = 0.0; GameplayMin = 0.0; GameplayMax = 0.0; GameplayAvgMs = 0.0
        GameplayKnown = $false
    }
    if ($script:SimConnectPid) {
        try { Stop-Process -Id $script:SimConnectPid -Force -ErrorAction SilentlyContinue } catch { }
        $script:SimConnectPid = $null
        Start-Sleep -Milliseconds 250
    }
    if ($script:PresentMonPid) {
        try { Stop-Process -Id $script:PresentMonPid -Force -ErrorAction SilentlyContinue } catch { }
        $script:PresentMonPid = $null
        Start-Sleep -Milliseconds 250
    }
    if ($script:SimConnectCsv -and (Test-Path -LiteralPath $script:SimConnectCsv)) {
        try {
            $rows = @(Import-Csv -LiteralPath $script:SimConnectCsv)
            $vals = New-Object System.Collections.Generic.List[double]
            $play = New-Object System.Collections.Generic.List[double]
            $spd = 1.0
            $hasSimCol = $false
            if ($rows.Count -gt 0) {
                $hasSimCol = @($rows[0].PSObject.Properties.Name) -contains 'Sim'
            }
            foreach ($r in $rows) {
                $v = 0.0
                if (-not [double]::TryParse([string]$r.Fps, [ref]$v) -or $v -le 1 -or $v -ge 400) { continue }
                [void]$vals.Add($v)
                $s = 0.0
                if ([double]::TryParse([string]$r.SimSpeed, [ref]$s) -and $s -gt 0) { $spd = $s }
                $inFlight = $false
                if ($hasSimCol) {
                    $sim = 0; $paused = 0
                    [void][int]::TryParse([string]$r.Sim, [ref]$sim)
                    [void][int]::TryParse([string]$r.Paused, [ref]$paused)
                    $inFlight = ($sim -eq 1 -and $paused -eq 0)
                    $stats.GameplayKnown = $true
                } else {
                    $inFlight = ($spd -ge 0.9 -and $spd -le 1.15 -and $v -ge 12)
                }
                if ($inFlight) { [void]$play.Add($v) }
            }
            if ($vals.Count -gt 5) {
                $all = Measure-FpsList $vals
                $stats.Count = $all.Count
                $stats.Avg = $all.Avg
                $stats.Min = $all.Min
                $stats.Max = $all.Max
                $stats.AvgMs = $all.AvgMs
                $stats.Source = 'simconnect'
                $stats.SimSpeed = [math]::Round($spd, 2)
                if ($play.Count -gt 5) {
                    $gp = Measure-FpsList $play
                    $stats.GameplayCount = $gp.Count
                    $stats.GameplayAvg = $gp.Avg
                    $stats.GameplayMin = $gp.Min
                    $stats.GameplayMax = $gp.Max
                    $stats.GameplayAvgMs = $gp.AvgMs
                }
                return $stats
            }
        } catch {
            Write-Log ("SimConnect FPS parse failed: {0}" -f $_.Exception.Message) 'WARN'
        }
    }
    if (-not $script:PresentMonFile -or -not (Test-Path -LiteralPath $script:PresentMonFile)) { return $stats }
    try {
        $rows = Import-Csv -LiteralPath $script:PresentMonFile
        $ms = New-Object System.Collections.Generic.List[double]
        foreach ($r in $rows) {
            $v = 0.0
            if ($r.MsBetweenPresents) { [void][double]::TryParse([string]$r.MsBetweenPresents, [ref]$v) }
            if ($v -gt 1 -and $v -lt 250) { [void]$ms.Add($v) }
        }
        if ($ms.Count -gt 5) {
            $fps = foreach ($x in $ms) { 1000.0 / $x }
            $stats.Count = $ms.Count
            $stats.Avg = [math]::Round((($fps | Measure-Object -Average).Average), 1)
            $stats.Min = [math]::Round((($fps | Measure-Object -Minimum).Minimum), 1)
            $stats.Max = [math]::Round((($fps | Measure-Object -Maximum).Maximum), 1)
            $stats.AvgMs = [math]::Round((($ms | Measure-Object -Average).Average), 1)
            $stats.Source = 'presentmon'
        }
    } catch {
        Write-Log ("FPS parse failed: {0}" -f $_.Exception.Message) 'WARN'
    }
    return $stats
}

function Update-HardwareSession {
    param($Hw, [double]$MsfsCpu, [int]$FreeRamMB)
    if (-not $script:Session) { return }
    $s = $script:Session
    if (-not $s.ContainsKey('HwSamples')) {
        $s['HwSamples'] = 0
        $s['GpuSum'] = 0.0; $s['GpuMax'] = 0.0
        $s['VramMaxMB'] = 0
        $s['DiskQSum'] = 0.0; $s['DiskQMax'] = 0.0; $s['DiskMBpsMax'] = 0.0
        $s['NetMBpsSum'] = 0.0; $s['NetMBpsMax'] = 0.0
        $s['SysCpuSum'] = 0.0; $s['SysCpuMax'] = 0.0
        $s['BnCpu'] = 0; $s['BnGpu'] = 0; $s['BnRam'] = 0; $s['BnDisk'] = 0; $s['BnNet'] = 0; $s['BnCap'] = 0; $s['BnNone'] = 0
        $s['LastLimit'] = 'None'
    }
    $gpu = 0.0; $msfsGpu = 0.0; $vram = 0
    $diskQ = 0.0; $diskMB = 0.0; $netMB = 0.0; $sysCpu = 0.0
    try { $gpu = [double]$Hw.Gpu } catch { }
    try { $msfsGpu = [double]$Hw.MsfsGpu } catch { }
    try { $vram = [int]$Hw.VramMB } catch { }
    try { $diskQ = [double]$Hw.DiskQ } catch { }
    try { $diskMB = [double]$Hw.DiskMBps } catch { }
    try { $netMB = [double]$Hw.NetMBps } catch { }
    try { $sysCpu = [double]$Hw.SysCpu } catch { }
    if ($msfsGpu -gt $gpu) { $gpu = $msfsGpu }
    $s.HwSamples++
    $s.GpuSum += $gpu
    if ($gpu -gt $s.GpuMax) { $s.GpuMax = $gpu }
    if ($vram -gt $s.VramMaxMB) { $s.VramMaxMB = $vram }
    $s.DiskQSum += $diskQ
    if ($diskQ -gt $s.DiskQMax) { $s.DiskQMax = $diskQ }
    if ($diskMB -gt $s.DiskMBpsMax) { $s.DiskMBpsMax = $diskMB }
    $s.NetMBpsSum += $netMB
    if ($netMB -gt $s.NetMBpsMax) { $s.NetMBpsMax = $netMB }
    $s.SysCpuSum += $sysCpu
    if ($sysCpu -gt $s.SysCpuMax) { $s.SysCpuMax = $sysCpu }
    $Hw = @{ Gpu = $gpu; MsfsGpu = $msfsGpu; VramMB = $vram; DiskQ = $diskQ; DiskMBps = $diskMB; NetMBps = $netMB; SysCpu = $sysCpu }
    $bn = Get-BottleneckName -Hw $Hw -MsfsCpu $MsfsCpu -FreeRamMB $FreeRamMB
    $s.LastLimit = $bn
    switch ($bn) {
        'CPU' { $s.BnCpu++ }
        'GPU' { $s.BnGpu++ }
        'RAM' { $s.BnRam++ }
        'Disk' { $s.BnDisk++ }
        'Network' { $s.BnNet++ }
        'Cap' { $s.BnCap++ }
        default { $s.BnNone++ }
    }
}

function Get-LimitSummary {
    param($Session)
    if (-not $Session.HwSamples -or $Session.HwSamples -le 0) {
        return @{
            Name      = 'Unknown'
            DevName   = 'Limiter unknown'
            Percent   = 0
            When      = 'Not enough hardware samples.'
            Detail    = 'Not enough hardware samples.'
            GpuAvg    = 0
            GpuMax    = 0
            SysCpuAvg = 0
            DiskQAvg  = 0
            DiskQMax  = 0
            DiskMax   = 0
            NetAvg    = 0
            NetMax    = 0
            VramMaxMB = 0
            BnCpu     = 0
            BnGpu     = 0
            BnRam     = 0
            BnDisk    = 0
            BnNet     = 0
            BnNone    = 0
        }
    }
    $map = @{
        CPU     = [int]$Session.BnCpu
        GPU     = [int]$Session.BnGpu
        RAM     = [int]$Session.BnRam
        Disk    = [int]$Session.BnDisk
        Network = [int]$Session.BnNet
        Cap     = [int]$Session.BnCap
        None    = [int]$Session.BnNone
    }
    $top = 'None'
    $topN = -1
    foreach ($k in @('GPU', 'CPU', 'Disk', 'RAM', 'Network', 'Cap', 'None')) {
        if ($map[$k] -gt $topN) { $top = $k; $topN = $map[$k] }
    }
    $pct = [int](100.0 * $topN / [math]::Max(1, [int]$Session.HwSamples))
    $mix = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('GPU', 'CPU', 'Disk', 'RAM', 'Network', 'Cap')) {
        $n = [int]$map[$k]
        if ($n -le 0) { continue }
        $p = [int](100.0 * $n / [math]::Max(1, [int]$Session.HwSamples))
        if ($p -ge 5) { [void]$mix.Add(('{0} {1}%' -f $k, $p)) }
    }
    $when = if ($mix.Count -gt 0) { $mix -join ', ' } else { 'No limiter stood out.' }
    $detail = switch ($top) {
        'GPU' { 'The graphics card was the main limit (like Limited by GPU on the sim FPS display).' }
        'CPU' { 'The processor / main thread was the main limit (like Limited by MainThread).' }
        'RAM' { 'System memory got tight and that can hitch the sim.' }
        'Disk' { 'The drive was busy (scenery streaming). That usually causes stutters more than a steady FPS drop.' }
        'Network' { 'The network was busy (live weather, photogrammetry, or a download).' }
        'Cap' { 'The sim frame-rate cap / VSync was holding FPS on purpose (same idea as a locked number on the Dev FPS display).' }
        default { 'No single part of the PC stayed maxed out for most of the flight.' }
    }
    return @{
        Name      = $top
        DevName   = (Get-DevLimitLabel $top)
        Percent   = $pct
        When      = $when
        Detail    = $detail
        GpuAvg    = [math]::Round($Session.GpuSum / $Session.HwSamples, 1)
        GpuMax    = [math]::Round($Session.GpuMax, 1)
        SysCpuAvg = [math]::Round($Session.SysCpuSum / $Session.HwSamples, 1)
        DiskQAvg  = [math]::Round($Session.DiskQSum / $Session.HwSamples, 2)
        DiskQMax  = [math]::Round([double]$Session.DiskQMax, 2)
        DiskMax   = [math]::Round([double]$Session.DiskMBpsMax, 1)
        NetAvg    = [math]::Round($Session.NetMBpsSum / $Session.HwSamples, 2)
        NetMax    = [math]::Round([double]$Session.NetMBpsMax, 2)
        VramMaxMB = [int]$Session.VramMaxMB
        BnCpu     = [int]$Session.BnCpu
        BnGpu     = [int]$Session.BnGpu
        BnRam     = [int]$Session.BnRam
        BnDisk    = [int]$Session.BnDisk
        BnNet     = [int]$Session.BnNet
        BnCap     = [int]$Session.BnCap
        BnNone    = [int]$Session.BnNone
    }
}

function Get-DevLimitLabel {
    param([string]$Name)
    switch ($Name) {
        'CPU' { return 'Limited by MainThread' }
        'GPU' { return 'Limited by GPU' }
        'RAM' { return 'Limited by Memory' }
        'Disk' { return 'Limited by Disk' }
        'Network' { return 'Limited by Network' }
        'Cap' { return 'Limited by Frame Rate Cap' }
        'None' { return 'No single limiter' }
        default { return 'Limiter unknown' }
    }
}

function Get-LiveFps {
    if ($script:SimConnectJson -and (Test-Path -LiteralPath $script:SimConnectJson)) {
        try {
            $j = Get-Content -LiteralPath $script:SimConnectJson -Raw -ErrorAction Stop | ConvertFrom-Json
            $at = [datetime]$j.at
            if (((Get-Date) - $at).TotalSeconds -lt 6 -and [double]$j.fps -gt 1) {
                $script:FpsSource = 'simconnect'
                try { $script:LastSimSpeed = [double]$j.simSpeed } catch { }
                return [math]::Round([double]$j.fps, 1)
            }
        } catch { }
    }
    $script:FpsSource = 'presentmon'
    if (-not $script:PresentMonFile -or -not (Test-Path -LiteralPath $script:PresentMonFile)) { return $null }
    try {
        $fi = Get-Item -LiteralPath $script:PresentMonFile -ErrorAction Stop
        if ($fi.Length -lt 120) { return $null }
        $fs = [System.IO.File]::Open(
            $script:PresentMonFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            if ($null -eq $script:PmMsCol) {
                $head = New-Object System.IO.StreamReader($fs, $true)
                $header = $head.ReadLine()
                $script:PmMsCol = -1
                if ($header) {
                    $cols = $header.Split(',')
                    for ($i = 0; $i -lt $cols.Length; $i++) {
                        if ($cols[$i].Trim() -eq 'MsBetweenPresents') { $script:PmMsCol = $i; break }
                    }
                }
            }
            if ($script:PmMsCol -lt 0) { return $null }
            $take = [int64][math]::Min($fi.Length, 12288)
            [void]$fs.Seek(-$take, [System.IO.SeekOrigin]::End)
            $sr = New-Object System.IO.StreamReader($fs, $true)
            $tail = $sr.ReadToEnd()
        } finally {
            $fs.Dispose()
        }
        $sum = 0.0
        $n = 0
        foreach ($raw in $tail.Split([char]10)) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith('Application')) { continue }
            $parts = $line.Split(',')
            if ($parts.Length -le $script:PmMsCol) { continue }
            $v = 0.0
            if ([double]::TryParse($parts[$script:PmMsCol], [ref]$v) -and $v -gt 1 -and $v -lt 250) {
                $sum += (1000.0 / $v)
                $n++
            }
        }
        if ($n -lt 4) { return $null }
        return [math]::Round($sum / $n, 1)
    } catch {
        return $null
    }
}

function Get-MsfsInfo {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($n in @($script:Config.MsfsProcessNames)) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { [void]$found.Add($_) }
    }
    if ($found.Count -eq 0) {
        return @{ Running = $false; Name = $null; CpuSec = 0.0; Ws = [int64]0; Pids = @() }
    }
    $cpu = 0.0
    $ws = [int64]0
    foreach ($p in $found) {
        try { $cpu += $p.TotalProcessorTime.TotalSeconds } catch { }
        try { $ws += [int64]$p.WorkingSet64 } catch { }
    }
    return @{
        Running = $true
        Name    = $found[0].ProcessName
        CpuSec  = $cpu
        Ws      = $ws
        Pids    = @($found | ForEach-Object { $_.Id })
    }
}

function Compare-Snapshots {
    param($Before, $After, $IoBefore, $IoAfter)
    $wall = ($After.At - $Before.At).TotalSeconds
    if ($wall -lt 0.2) { $wall = 0.2 }
    $cores = [Math]::Max(1, [Environment]::ProcessorCount)
    $groups = @{}
    foreach ($id in $After.Items.Keys) {
        $cur = $After.Items[$id]
        $name = $cur.Name
        if (-not $groups.ContainsKey($name)) {
            $groups[$name] = @{
                Name   = $name
                CpuPct = 0.0
                Ws     = [int64]0
                IoBps  = 0.0
                Pids   = New-Object System.Collections.Generic.List[int]
            }
        }
        $g = $groups[$name]
        [void]$g.Pids.Add([int]$id)
        $g.Ws += $cur.Ws
        if ($Before.Items.ContainsKey($id)) {
            $delta = $cur.CpuSec - $Before.Items[$id].CpuSec
            if ($delta -lt 0) { $delta = 0 }
            $g.CpuPct += ($delta / $wall) * 100.0 / $cores
        }
        if ($IoAfter -and $IoAfter.ContainsKey($id) -and $IoBefore -and $IoBefore.ContainsKey($id)) {
            $dIo = $IoAfter[$id] - $IoBefore[$id]
            if ($dIo -gt 0) { $g.IoBps += $dIo / $wall }
        }
    }
    return @($groups.Values)
}

function Test-HostPresent {
    try {
        $m = [System.Threading.Mutex]::OpenExisting('Local\MSFSPerformanceGuardHost')
        $m.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Write-RuntimeStatus {
    try {
        $obj = [ordered]@{
            At          = (Get-Date).ToString('o')
            MsfsRunning = [bool]$script:MsfsRunning
            Admin       = [bool]$script:IsAdmin
            Label       = [string]$script:MsfsLabel
            Fps         = $script:LastFps
            Limit       = [string]$script:LastLimit
        }
        ($obj | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $script:LogDir 'runtime-status.json') -Encoding UTF8
    } catch { }
}

function Get-SafetyCache {
    if ($script:SafetyCache) { return $script:SafetyCache }
    $script:SafetyCache = @{}
    $path = Join-Path $script:LogDir 'process-safety-cache.json'
    $loaded = Read-JsonFile $path
    if ($loaded) {
        foreach ($p in $loaded.PSObject.Properties) {
            $script:SafetyCache[$p.Name] = [string]$p.Value
        }
    }
    return $script:SafetyCache
}

function Save-SafetyCache {
    try {
        $script:SafetyCache | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:LogDir 'process-safety-cache.json') -Encoding UTF8
    } catch { }
}

function Test-NameLooksMsfsRelated {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    $keys = @(
        'msfs', 'flightsim', 'flight sim', 'flightsimulator', 'fs2020', 'fs2024',
        'navigraph', 'couatl', 'gsx', 'fsdt', 'pmdg', 'fenix', 'ifly', '737max',
        'orbx', 'fsuipc', 'vpilot', 'vatsim', 'simbrief', 'littlenav', 'spad',
        'mobiflight', 'xboxpc', 'webview', 'amdrs', 'radeon', 'nvidia', 'tobi',
        'trackir', 'beyondatc', 'sayintentions', 'volanta', 'onair', 'chaseplane',
        'autofps', 'mdclient', 'maddog', 'bridge', 'presentmon',
        'simflight', 'vatsim-radar'
    )
    foreach ($k in $keys) {
        if ($n.Contains($k)) { return $true }
    }
    return $false
}

function Search-ProcessMsfsLink {
    param([string]$Name)
    # Kept for optional offline cache use. Do not call on the overlay hot path:
    # searching "X Flight Simulator addon" matches almost every page, which
    # previously marked Chrome/Opera/Discord as sim-related and hid every toast.
    $cache = Get-SafetyCache
    if ($cache.ContainsKey($Name)) { return [string]$cache[$Name] }
    return 'ok-to-suggest'
}

function Test-IsSafeToSuggest {
    param([string]$Name, [switch]$Online)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match '^(powershell|pwsh|MSFSGuard)$') { return $false }
    if ($script:DoNotSleep -and $script:DoNotSleep.Contains($Name)) { return $false }
    if (Test-NameLooksMsfsRelated $Name) { return $false }
    if ($script:Hogs -and $script:Hogs.Contains($Name)) { return $true }
    if ($Online) {
        $v = Search-ProcessMsfsLink $Name
        if ($v -eq 'msfs-related') { return $false }
    }
    return $true
}

function Test-IsOffender {
    param($Group, [int]$FreeRamMB)
    $name = $Group.Name
    if ($script:Protected.Contains($name)) { return $null }
    if ($script:Companions.Contains($name)) { return $null }
    if ($script:Allow.Contains($name)) { return $null }
    if ($script:SessionIgnore.Contains($name)) { return $null }
    if ($script:Slept.ContainsKey($name)) { return $null }
    if ($script:MsfsNames.Contains($name)) { return $null }
    $allGuard = $true
    foreach ($id in $Group.Pids) {
        if (-not $script:GuardPids.Contains([int]$id)) { $allGuard = $false; break }
    }
    if ($allGuard) { return $null }
    if (-not (Test-IsSafeToSuggest $name)) { return $null }

    $memMB = [int]($Group.Ws / 1MB)
    $diskMBps = $Group.IoBps / 1MB
    $isHog = $script:Hogs.Contains($name)
    $memLimit = [double]$script:Config.MemoryMBThreshold
    if ($FreeRamMB -gt 0 -and $FreeRamMB -lt [int]$script:Config.LowRamMB) {
        $memLimit = [double]$script:Config.LowRamMemoryMBThreshold
    }

    # Config CPU numbers are "percent of the whole machine on an 8-core PC".
    # Scale so a 32-core box is not deaf and a 4-core box is not twitchy.
    $cores = [Math]::Max(1, [Environment]::ProcessorCount)
    $scale = 8.0 / $cores
    $cpuHard = [Math]::Max(1.2, [double]$script:Config.CpuPercentThreshold * $scale)
    $cpuSoft = [Math]::Max(0.6, [double]$script:Config.KnownHogSoftCpuPercent * $scale)

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($Group.CpuPct -ge $cpuHard) {
        [void]$reasons.Add(('{0:n0}% CPU' -f $Group.CpuPct))
    } elseif ($isHog -and $Group.CpuPct -ge $cpuSoft) {
        [void]$reasons.Add(('{0:n0}% CPU' -f $Group.CpuPct))
    }

    if ($memMB -ge $memLimit) {
        [void]$reasons.Add(('{0:n1} GB RAM' -f ($memMB / 1024.0)))
    } elseif ($isHog -and $memMB -ge [double]$script:Config.KnownHogSoftMemoryMB) {
        [void]$reasons.Add(('{0:n1} GB RAM' -f ($memMB / 1024.0)))
    }

    if ($diskMBps -ge [double]$script:Config.DiskMBpsThreshold) {
        [void]$reasons.Add(('{0:n1} MB/s disk' -f $diskMBps))
    }

    if ($reasons.Count -eq 0) { return $null }

    $score = $Group.CpuPct * 3.0 + ($memMB / 80.0) + ($diskMBps * 2.0)
    return @{
        Name     = $name
        Label    = (Get-FriendlyName $name)
        CpuPct   = $Group.CpuPct
        MemMB    = $memMB
        DiskMBps = $diskMBps
        Count    = $Group.Pids.Count
        Pids     = @($Group.Pids)
        Reason   = ($reasons -join '  |  ')
        Score    = $score
        KnownHog = $isHog
    }
}

function Refresh-GuardPids {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$set.Add([int]$PID)
    try {
        Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.CommandLine -and $_.CommandLine -like '*MSFSGuard.ps1*') {
                [void]$set.Add([int]$_.ProcessId)
            }
        }
    } catch { }
    $script:GuardPids = $set
}

# -----------------------------------------------------------------------------
# Session reports (written when MSFS exits; also feeds GROK-DEV-BRIEFING.md)
# -----------------------------------------------------------------------------
function New-FlightSession {
    param([string]$MsfsName)
    $script:Session = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $script:Session['Id'] = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:Session['StartedAt'] = Get-Date
    $script:Session['EndedAt'] = $null
    $script:Session['Outcome'] = 'running'
    $script:Session['MsfsName'] = $MsfsName
    $script:Session['Admin'] = [bool](Test-IsAdmin)
    $script:Session['Cores'] = [int][Environment]::ProcessorCount
    $script:Session['Samples'] = 0
    $script:Session['TickMsSum'] = 0.0
    $script:Session['TickMsMax'] = 0.0
    $script:Session['TickErrors'] = 0
    $script:Session['MsfsCpuSum'] = 0.0
    $script:Session['MsfsCpuMax'] = 0.0
    $script:Session['MsfsRamSum'] = 0.0
    $script:Session['MsfsRamMax'] = 0.0
    $script:Session['MsfsRamMin'] = [double]::MaxValue
    $script:Session['FreeRamSum'] = 0.0
    $script:Session['FreeRamMin'] = [int]::MaxValue
    $script:Session['FreeRamMax'] = 0
    $script:Session['NonMsfsCpuSum'] = 0.0
    $script:Session['PausedSamples'] = 0
    $script:Session['CooldownSamples'] = 0
    $script:Session['ToastShown'] = 0
    $script:Session['SleepOk'] = 0
    $script:Session['SleepFail'] = 0
    $script:Session['CloseOk'] = 0
    $script:Session['CloseFail'] = 0
    $script:Session['Ignored'] = 0
    $script:Session['Never'] = 0
    $script:Session['Dismissed'] = 0
    $script:Session['SleepAll'] = 0
    $script:Session['AutoSleep'] = 0
    $script:Session['RamAtStartMB'] = 0
    $script:Session['RamAfterActionMB'] = $null
    $script:Session['Peaks'] = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $script:Session['Suggested'] = New-Object System.Collections.Generic.List[object]
    $script:Session['Actions'] = New-Object System.Collections.Generic.List[object]
    $script:Session['SuggestedNames'] = New-IgnoreSet -Names @()
    $script:Session['NearMisses'] = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $script:LastFps = $null
    $script:LastLimit = 'None'
    $script:LastSimSpeed = 1.0
    $script:FpsSource = $null
    $cfg = Read-MsfsInternalSettings
    $script:Session['FrameLimiter'] = [int]$cfg.FrameLimiter
    $script:Session['VSync'] = [bool]$cfg.VSync
    $script:Session['DynamicSettings'] = [bool]$cfg.DynamicSettings
    $script:Session['TargetFrameRate'] = [int]$cfg.TargetFrameRate
    $script:Session['FrameGeneration'] = [string]$cfg.FrameGeneration
    $script:Session['AntiAliasing'] = [string]$cfg.AntiAliasing
    $script:Session['FsrMode'] = [string]$cfg.FsrMode
    $script:Session['Tlod'] = [double]$cfg.Tlod
    $script:Session['Olod'] = [double]$cfg.Olod
    $script:Session['CloudsQuality'] = [int]$cfg.CloudsQuality
    $script:Session['TrafficQty'] = [int]$cfg.TrafficQty
    $script:Session['Buildings'] = [int]$cfg.Buildings
    $script:Session['UserCfgPath'] = [string]$cfg.Path
    if (-not $WriteTestReport) { Start-FpsCapture }
}

function Add-NearMiss {
    param($Group, [int]$FreeRamMB)
    if (-not $script:Session) { return }
    $name = $Group.Name
    if ($script:Protected.Contains($name) -or $script:Companions.Contains($name)) { return }
    if ($script:MsfsNames.Contains($name)) { return }
    if ($name -match '^(powershell|pwsh|MSFSGuard)$') { return }
    if (Test-NameLooksMsfsRelated $name) { return }
    $memMB = [int]($Group.Ws / 1MB)
    $cores = [Math]::Max(1, [Environment]::ProcessorCount)
    $scale = 8.0 / $cores
    $cpuSoft = [Math]::Max(0.6, [double]$script:Config.KnownHogSoftCpuPercent * $scale)
    $memSoft = [double]$script:Config.KnownHogSoftMemoryMB
    if ($Group.CpuPct -lt ($cpuSoft * 0.5) -and $memMB -lt ($memSoft * 0.5)) { return }
    if (-not $script:Session.ContainsKey('NearMisses') -or $null -eq $script:Session.NearMisses) {
        $script:Session['NearMisses'] = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    }
    $hits = $script:Session.NearMisses
    if (-not $hits.ContainsKey($name)) {
        $hits[$name] = @{ Name = $name; Count = 0; MaxCpu = 0.0; MaxMemMB = 0 }
    }
    $row = $hits[$name]
    $row.Count++
    if ($Group.CpuPct -gt $row.MaxCpu) { $row.MaxCpu = $Group.CpuPct }
    if ($memMB -gt $row.MaxMemMB) { $row.MaxMemMB = $memMB }
}

function Add-SessionAction {
    param(
        [string]$Type,
        [string]$Name = '',
        [bool]$Ok = $true,
        [string]$Detail = ''
    )
    if (-not $script:Session) { return }
    $s = $script:Session
    $row = [ordered]@{
        At     = (Get-Date).ToString('HH:mm:ss')
        Type   = $Type
        Name   = $Name
        Label  = $(if ($Name) { Get-FriendlyName $Name } else { '' })
        Ok     = [bool]$Ok
        Detail = $Detail
    }
    [void]$s.Actions.Add($row)
    switch ($Type) {
        'sleep' {
            if ($Ok) { $s.SleepOk++ } else { $s.SleepFail++ }
            if ($Ok -and $script:LastFreeRam -gt 0) { $s.RamAfterActionMB = [int]$script:LastFreeRam }
        }
        'autosleep' {
            $s.AutoSleep++
            if ($Ok) { $s.SleepOk++ } else { $s.SleepFail++ }
            if ($Ok -and $script:LastFreeRam -gt 0) { $s.RamAfterActionMB = [int]$script:LastFreeRam }
        }
        'close' { if ($Ok) { $s.CloseOk++ } else { $s.CloseFail++ } }
        'ignore' { $s.Ignored++ }
        'never' { $s.Never++ }
        'dismiss' { $s.Dismissed++ }
        'sleep-all' { $s.SleepAll++ }
    }
}

function Update-SessionPeak {
    param([string]$Name, [double]$CpuPct, [int]$MemMB, [double]$DiskMBps)
    if (-not $script:Session) { return }
    if ($script:Protected -and $script:Protected.Contains($Name)) { return }
    if ($script:MsfsNames -and $script:MsfsNames.Contains($Name)) { return }
    $peaks = $script:Session.Peaks
    if ($null -eq $peaks) {
        $peaks = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
        $script:Session.Peaks = $peaks
    }
    if (-not $peaks.ContainsKey($Name)) {
        $peaks[$Name] = @{
            Name      = $Name
            Label     = (Get-FriendlyName $Name)
            Samples   = 0
            SumCpu    = 0.0
            MaxCpu    = 0.0
            MaxMemMB  = 0
            MaxDisk   = 0.0
            KnownHog  = [bool]$script:Hogs.Contains($Name)
            Companion = [bool]$script:Companions.Contains($Name)
            Allow     = [bool]$script:Allow.Contains($Name)
        }
    }
    $p = $peaks[$Name]
    $p.Samples++
    $p.SumCpu += $CpuPct
    if ($CpuPct -gt $p.MaxCpu) { $p.MaxCpu = $CpuPct }
    if ($MemMB -gt $p.MaxMemMB) { $p.MaxMemMB = $MemMB }
    if ($DiskMBps -gt $p.MaxDisk) { $p.MaxDisk = $DiskMBps }
}

function Update-SessionSample {
    param($Msfs, [double]$MsfsCpu, [int]$FreeRamMB, $Groups)
    if (-not $script:Session) { return }
    $s = $script:Session
    $s.Samples++
    if ($script:Paused) { $s.PausedSamples++ }
    if ((Get-Date) -lt $script:CooldownUntil) { $s.CooldownSamples++ }

    if ($MsfsCpu -gt 0) {
        $s.MsfsCpuSum += $MsfsCpu
        if ($MsfsCpu -gt $s.MsfsCpuMax) { $s.MsfsCpuMax = $MsfsCpu }
    }
    $ramGB = 0.0
    if ($Msfs -and $Msfs.Ws) { $ramGB = [double]$Msfs.Ws / 1GB }
    $s.MsfsRamSum += $ramGB
    if ($ramGB -gt $s.MsfsRamMax) { $s.MsfsRamMax = $ramGB }
    if ($ramGB -gt 0 -and $ramGB -lt $s.MsfsRamMin) { $s.MsfsRamMin = $ramGB }

    if ($FreeRamMB -gt 0) {
        $s.FreeRamSum += $FreeRamMB
        if ($FreeRamMB -lt $s.FreeRamMin) { $s.FreeRamMin = $FreeRamMB }
        if ($FreeRamMB -gt $s.FreeRamMax) { $s.FreeRamMax = $FreeRamMB }
        if ($s.Samples -eq 1) { $s.RamAtStartMB = $FreeRamMB }
    }

    $otherCpu = 0.0
    foreach ($g in @($Groups)) {
        if ($script:MsfsNames.Contains($g.Name)) { continue }
        $otherCpu += [double]$g.CpuPct
        $memMB = [int]($g.Ws / 1MB)
        $disk = [double]$g.IoBps / 1MB
        if ($g.CpuPct -ge 0.4 -or $memMB -ge 200 -or $disk -ge 2) {
            Update-SessionPeak $g.Name $g.CpuPct $memMB $disk
        }
    }
    $s.NonMsfsCpuSum += $otherCpu
}

function Add-SessionSuggestionShown {
    param($Offenders, [bool]$Shown = $true)
    if (-not $script:Session) { return }
    if ($Shown) { $script:Session.ToastShown++ }
    if ($null -eq $script:Session.SuggestedNames) {
        $script:Session.SuggestedNames = New-IgnoreSet -Names @()
    }
    foreach ($o in @($Offenders)) {
        [void]$script:Session.SuggestedNames.Add($o.Name)
        [void]$script:Session.Suggested.Add([ordered]@{
                Name     = $o.Name
                Label    = $o.Label
                Reason   = $o.Reason
                CpuPct   = [math]::Round($o.CpuPct, 2)
                MemMB    = $o.MemMB
                KnownHog = [bool]$o.KnownHog
            })
    }
}

function Get-SessionAverages {
    param($Session)
    $n = [math]::Max(1, [int]$Session.Samples)
    $cpuN = [math]::Max(1, [int]$Session.Samples)
    return @{
        TickMsAvg    = [math]::Round($Session.TickMsSum / $n, 1)
        MsfsCpuAvg   = [math]::Round($Session.MsfsCpuSum / $cpuN, 2)
        MsfsRamAvgGB = [math]::Round($Session.MsfsRamSum / $n, 2)
        FreeRamAvgMB = [int]($Session.FreeRamSum / $n)
        OtherCpuAvg  = [math]::Round($Session.NonMsfsCpuSum / $n, 2)
    }
}

function Get-LetterGrade {
    param([int]$Score)
    if ($Score -ge 90) { return 'A' }
    if ($Score -ge 80) { return 'B' }
    if ($Score -ge 70) { return 'C' }
    if ($Score -ge 55) { return 'D' }
    return 'F'
}

function Get-SimShortName {
    param([string]$Name)
    switch -Regex ($Name) {
        '2024' { return 'MSFS 2024' }
        'FlightSimulator' { return 'MSFS 2020' }
        default { if ($Name) { return $Name } else { return 'Flight Simulator' } }
    }
}

function Get-GradeColor {
    param([string]$Grade)
    switch ($Grade) {
        'A' { return $script:C.Ok }
        'B' { return [System.Drawing.Color]::FromArgb(72, 188, 168) }
        'C' { return $script:C.Warn }
        'D' { return [System.Drawing.Color]::FromArgb(232, 124, 56) }
        'F' { return $script:C.Err }
        default { return $script:C.Muted }
    }
}

function Get-GameplayGrade {
    param(
        [double]$Avg,
        [int]$Cap = 0
    )
    if ($Avg -le 0) {
        return @{ Grade = '-'; Score = 0; Label = 'No in-flight FPS' }
    }
    $score = 0
    if ($Cap -ge 20) {
        $ratio = $Avg / [double]$Cap
        if ($ratio -ge 0.95) { $score = [int][math]::Min(100, [math]::Round(90 + (10 * ($ratio - 0.95) / 0.15))) }
        elseif ($ratio -ge 0.85) { $score = [int][math]::Round(80 + (10 * ($ratio - 0.85) / 0.10)) }
        elseif ($ratio -ge 0.70) { $score = [int][math]::Round(70 + (10 * ($ratio - 0.70) / 0.15)) }
        elseif ($ratio -ge 0.50) { $score = [int][math]::Round(55 + (15 * ($ratio - 0.50) / 0.20)) }
        else { $score = [int][math]::Max(0, [math]::Round(54 * ($ratio / 0.50))) }
    } else {
        # Uncapped MSFS: 60 is excellent, 45 comfortable, 30 playable, 20 choppy.
        if ($Avg -ge 60) { $score = [int][math]::Min(100, [math]::Round(90 + [math]::Min(10, ($Avg - 60) / 4.0))) }
        elseif ($Avg -ge 45) { $score = [int][math]::Round(80 + (10 * ($Avg - 45) / 15.0)) }
        elseif ($Avg -ge 30) { $score = [int][math]::Round(70 + (10 * ($Avg - 30) / 15.0)) }
        elseif ($Avg -ge 20) { $score = [int][math]::Round(55 + (15 * ($Avg - 20) / 10.0)) }
        else { $score = [int][math]::Max(0, [math]::Round(54 * ($Avg / 20.0))) }
    }
    if ($score -gt 100) { $score = 100 }
    if ($score -lt 0) { $score = 0 }
    $letter = Get-LetterGrade $score
    $label = switch ($letter) {
        'A' { 'Smooth' }
        'B' { 'Comfortable' }
        'C' { 'Playable' }
        'D' { 'Choppy' }
        default { 'Poor' }
    }
    return @{ Grade = $letter; Score = $score; Label = $label }
}

function Format-Duration {
    param($Span)
    $ts = $null
    if ($Span -is [timespan]) {
        $ts = $Span
    } else {
        try { $ts = [timespan]$Span } catch { $ts = [timespan]::FromSeconds(0) }
    }
    if ($ts.TotalHours -ge 1) {
        return ('{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes)
    }
    if ($ts.TotalMinutes -ge 1) {
        return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds)
    }
    return ('{0}s' -f [int]$ts.TotalSeconds)
}

function Get-TopPeaks {
    param($Session, [int]$Take = 8)
    $rows = foreach ($p in @($Session.Peaks.Values)) {
        $avg = 0.0
        if ($p.Samples -gt 0) { $avg = $p.SumCpu / $p.Samples }
        [pscustomobject]@{
            Name      = $p.Name
            Label     = $p.Label
            Samples   = $p.Samples
            MaxCpu    = $p.MaxCpu
            MaxMemMB  = $p.MaxMemMB
            KnownHog  = $p.KnownHog
            Companion = $p.Companion
            Allow     = $p.Allow
            Score     = ($p.MaxCpu * 3.0 + ($p.MaxMemMB / 80.0) + $avg)
        }
    }
    return @($rows | Sort-Object Score -Descending | Select-Object -First $Take)
}

function Get-SessionSuggestions {
    param($Session, $Avg)
    $ideas = New-Object System.Collections.Generic.List[object]
    $cores = [math]::Max(1, [int]$Session.Cores)
    $scale = 8.0 / $cores
    $cpuSoft = [math]::Max(0.6, [double]$script:Config.KnownHogSoftCpuPercent * $scale)
    $acted = [int]$Session.SleepOk + [int]$Session.CloseOk
    $pushedBack = [int]$Session.Dismissed + [int]$Session.Ignored

    function Add-Idea {
        param($Priority, $Area, $Title, $Why, $Change, $GrokTask)
        [void]$ideas.Add([ordered]@{
                Priority = $Priority
                Area     = $Area
                Title    = $Title
                Why      = $Why
                Change   = $Change
                GrokTask = $GrokTask
            })
    }

    if (-not $Session.Admin) {
        Add-Idea 'high' 'reliability' 'Guard is not elevated' `
            'Sleep/Close cannot reach some programs unless the scheduled task runs as administrator.' `
            'Double-click Install.bat so the logon task is RunLevel Highest.' `
            'If Install.bat already exists, add a tray banner when Test-IsAdmin is false and surface Sleep failures more clearly.'
    }

    if ($Session.SleepFail -gt 0) {
        Add-Idea 'high' 'reliability' 'Sleep failed during the flight' `
            ("Sleep failed {0} time(s). Those programs kept using CPU/RAM." -f $Session.SleepFail) `
            'Run the guard elevated, or use Close for that program.' `
            'Widen OpenProcess access, log Win32 error codes on NtSuspendProcess failure, and retry once. Name the failing process in the session JSON.'
    }

    if ($Session.TickMsMax -ge 800 -or $Avg.TickMsAvg -ge 200) {
        Add-Idea 'high' 'overhead' 'Monitor tick is too slow' `
            ("Average tick {0} ms (max {1} ms). A slow tick can stall the overlay and miss short spikes." -f $Avg.TickMsAvg, [int]$Session.TickMsMax) `
            'Raise SampleSeconds to 3.5 in Config.json if the PC stutters when the guard is watching.' `
            'Speed up Get-Snapshot (skip CIM IO when SampleSeconds is low), cache Win32_Process IO, and log tick time in the dashboard.'
    }

    $unknown = @($Session.Peaks.Values | Where-Object {
            -not $_.KnownHog -and -not $_.Companion -and -not $_.Allow -and
            -not (Test-NameLooksMsfsRelated $_.Name) -and
            ($_.Name -notmatch '^(powershell|pwsh|MSFSGuard)$') -and
            (-not $script:DoNotSleep -or -not $script:DoNotSleep.Contains($_.Name)) -and
            ($_.MaxCpu -ge $cpuSoft -or $_.MaxMemMB -ge [double]$script:Config.KnownHogSoftMemoryMB) -and
            $_.Samples -ge 8
        } | Sort-Object { $_.MaxCpu } -Descending)
    foreach ($u in ($unknown | Select-Object -First 3)) {
        $already = $Session.SuggestedNames.Contains($u.Name)
        if ($already) { continue }
        Add-Idea 'high' 'lists' ("Missed heavy program: {0}" -f $u.Label) `
            ("{0} peaked at {1:n1}% CPU and {2} MB RAM over {3} samples but was never suggested." -f $u.Label, $u.MaxCpu, $u.MaxMemMB, $u.Samples) `
            ("Add `"{0}`" to KnownHogs in Config.json." -f $u.Name) `
            ("Add '{0}' to Config.json KnownHogs and to `$script:Friendly in MSFSGuard.ps1. Decide if Test-IsOffender should treat unknown high-RAM processes like known hogs." -f $u.Name)
    }

    $companions = @($Session.Peaks.Values | Where-Object {
            $_.Companion -and ($_.MaxCpu -ge ($cpuSoft * 2) -or $_.MaxMemMB -ge 1200)
        } | Sort-Object { $_.MaxCpu } -Descending)
    foreach ($c in ($companions | Select-Object -First 2)) {
        Add-Idea 'medium' 'lists' ("Sim companion was expensive: {0}" -f $c.Label) `
            ("{0} is allowlisted (so it is never suggested) but peaked at {1:n1}% CPU / {2} MB." -f $c.Label, $c.MaxCpu, $c.MaxMemMB) `
            'Leave it allowlisted if you need it for the flight. If not, remove it from CompanionAllowlist.' `
            ("Do not auto-remove companions. Keep '{0}' in the Grok briefing when it is expensive. Do not show a user toast." -f $c.Name)
    }

    if ($Session.Dismissed -ge 2 -and $Session.Dismissed -ge $acted) {
        Add-Idea 'medium' 'config' 'Suggestions are being dismissed' `
            ("Dismissed {0} overlay(s) and only acted on {1}. The bar may be too twitchy." -f $Session.Dismissed, $acted) `
            'Raise CpuPercentThreshold by 2 and MemoryMBThreshold by 200, or set PersistSamples to 4.' `
            'Tune default thresholds upward, or add a "too noisy" mode that requires a higher score before Show-Toast.'
    }

    if ((Test-ShowSuggestionOverlay) -and $Session.ToastShown -eq 0 -and $Avg.OtherCpuAvg -ge [math]::Max(2.0, [double]$script:Config.CpuPercentThreshold * $scale)) {
        Add-Idea 'medium' 'detection' 'Other programs used CPU but nothing was suggested' `
            ("Non-sim CPU averaged {0:n1}% and no overlay appeared." -f $Avg.OtherCpuAvg) `
            'Lower KnownHogSoftCpuPercent to 2.5 or PersistSamples to 2.' `
            'Review Test-IsOffender on high-core machines. Log near-misses (50% of threshold) into the session JSON so the next briefing can name them.'
    }

    $alwaysSleep = @($Session.Actions | Where-Object { $_.Type -eq 'sleep' -and $_.Ok } | Group-Object Name | Where-Object { $_.Count -ge 1 })
    if ($acted -ge 2 -and $alwaysSleep.Count -ge 1 -and -not [bool]$script:Config.AutoSleepKnownHogs) {
        $names = ($alwaysSleep | ForEach-Object { Get-FriendlyName $_.Name }) -join ', '
        Add-Idea 'medium' 'config' 'You keep sleeping the same programs' `
            ("Slept: {0}. The guard can do that automatically next time." -f $names) `
            'Set AutoSleepKnownHogs to true in Config.json, or ask Grok to add a FocusSleepList of process names.' `
            'Add Config.json FocusSleepList (string array). When MSFS starts, offer one confirmation, then auto-sleep those names. Do not auto-sleep companions or protected processes.'
    }

    if ($Session.Ignored -ge 1) {
        $ign = @($Session.Actions | Where-Object { $_.Type -eq 'ignore' } | Select-Object -ExpandProperty Label -Unique)
        Add-Idea 'low' 'config' 'Ignored programs this flight' `
            ("Ignored: {0}. Click Never next time if you never want to see them." -f ($ign -join ', ')) `
            ("Add them to UserAllowlist in Config.json: {0}" -f (($Session.Actions | Where-Object Type -eq 'ignore' | Select-Object -ExpandProperty Name -Unique) -join ', ')) `
            'No code change required unless Ignore should persist across sessions (that is what Never already does).'
    }

    if ($Session.FreeRamMin -ne [int]::MaxValue -and $Session.FreeRamMin -lt [int]$script:Config.LowRamMB) {
        Add-Idea 'medium' 'config' 'RAM got tight during the flight' `
            ("Free RAM bottomed out at {0} MB." -f $Session.FreeRamMin) `
            'Sleep or close browsers before loading the cockpit. The guard already tightens the RAM trigger below 2 GB free.' `
            'When FreeRamMB is below LowRamMB, prioritize RAM in overlay sort order (score memory higher than CPU) and change the toast subtitle to mention low RAM first.'
    }

    $limit = Get-LimitSummary $Session
    $fpsAvg = 0.0
    try { $fpsAvg = [double]$Session.FpsAvg } catch { }
    $fpsBit = if ($fpsAvg -gt 0) { (' Average FPS was {0}.' -f $fpsAvg) } else { '' }

    if ($limit.Name -eq 'GPU') {
        $gpuFix = New-Object System.Collections.Generic.List[string]
        if ([int]$Session.CloudsQuality -ge 2) { [void]$gpuFix.Add(('volumetric clouds ({0})' -f (Get-QualityName $Session.CloudsQuality))) }
        if ([double]$Session.Tlod -ge 0.7) { [void]$gpuFix.Add(('terrain LOD {0:n2}' -f $Session.Tlod)) }
        if ([int]$Session.Buildings -ge 2) { [void]$gpuFix.Add(('buildings ({0})' -f (Get-QualityName $Session.Buildings))) }
        if ($Session.AntiAliasing -and $Session.AntiAliasing -ne 'OFF') { [void]$gpuFix.Add(('anti-aliasing {0}' -f $Session.AntiAliasing)) }
        $gpuChange = if ($gpuFix.Count -gt 0) {
            'In the sim graphics menu, lower: {0}. Sleeping other programs will not raise FPS much while the GPU is already full.' -f ($gpuFix -join ', ')
        } else {
            'Lower clouds, terrain LOD, or anti-aliasing one step. Sleeping other programs will not raise FPS much while the GPU is already full.'
        }
        Add-Idea 'high' 'fps' 'The graphics card was the limiter' `
            ("{0} for {1}% of the flight ({2}).{3} GPU averaged {4}% (peak {5}%)." -f $limit.DevName, $limit.Percent, $limit.When, $fpsBit, $limit.GpuAvg, $limit.GpuMax) `
            $gpuChange `
            'Surface GPU-bound vs CPU-bound on the report card using SimConnect Frame + GPU Engine counters. Do not suggest Sleep for GPU-only limits.'
    } elseif ($limit.Name -eq 'CPU') {
        $other = [double]$Avg.OtherCpuAvg
        $cpuFix = New-Object System.Collections.Generic.List[string]
        if ([int]$Session.TrafficQty -ge 1) { [void]$cpuFix.Add('aircraft traffic') }
        if ([double]$Session.Olod -ge 1.0) { [void]$cpuFix.Add(('objects LOD {0:n2}' -f $Session.Olod)) }
        $settingsBit = if ($cpuFix.Count -gt 0) { ' Then lower {0} in the sim.' -f ($cpuFix -join ' and ') } else { ' Then lower traffic, AI aircraft, or object density.' }
        $change = if ($other -ge 2.5) {
            'Sleep or close other programs before you load in (they were using the processor).{0}' -f $settingsBit
        } else {
            'Other programs were quiet, so the sim itself is CPU-bound (Limited by MainThread).{0}' -f $settingsBit
        }
        Add-Idea 'high' 'fps' 'The processor / main thread was the limiter' `
            ("{0} for {1}% of the flight ({2}).{3} Sim CPU avg {4}%. Other programs avg {5}%." -f $limit.DevName, $limit.Percent, $limit.When, $fpsBit, $Avg.MsfsCpuAvg, $other) `
            $change `
            'When BnCpu dominates, rank Sleep suggestions by CPU first and mention MainThread on the overlay header.'
    } elseif ($limit.Name -eq 'Cap') {
        $capN = [int]$Session.FrameLimiter
        $dyn = if ([bool]$Session.DynamicSettings) { (' Dynamic Settings is on with a {0} FPS target.' -f $Session.TargetFrameRate) } else { '' }
        $vs = if ([bool]$Session.VSync) { ' VSync is on.' } else { '' }
        Add-Idea 'medium' 'fps' 'The sim is holding FPS on purpose' `
            ("{0} for {1}% of the flight.{2} Your Max Frame Rate in UserCfg is {3}.{4}{5}" -f $limit.DevName, $limit.Percent, $fpsBit, $capN, $dyn, $vs) `
            'If you want more frames, raise Max Frame Rate or turn VSync off in the sim. Hardware was not the thing holding you down.' `
            'Treat FrameLimiter / VSync / DynamicSettings from UserCfg.opt as Limited by Frame Rate Cap on the report card.'
    } elseif ($limit.Name -eq 'RAM') {
        Add-Idea 'high' 'fps' 'Memory got tight and that can drop FPS' `
            ("{0} for {1}% of the flight. Lowest free RAM {2} MB.{3}" -f $limit.DevName, $limit.Percent, $Session.FreeRamMin, $fpsBit) `
            'Sleep browsers and other heavy apps before you load the cockpit so Windows does not start paging.' `
            'Treat FreeRamMB under LowRamMB as a RAM limiter even if GPU/CPU are not pegged.'
    } elseif ($limit.Name -eq 'Disk') {
        Add-Idea 'medium' 'fps' 'The drive was busy (scenery streaming)' `
            ("{0} for {1}% of the flight. Disk queue peak {2}, peak {3} MB/s.{4}" -f $limit.DevName, $limit.Percent, $limit.DiskQMax, $limit.DiskMax, $fpsBit) `
            'Let the scenery cache settle after you load in. Pause OneDrive or other downloads during flight. Stutters are more likely than a lower locked FPS.' `
            'Keep disk as a hitch limiter, not a steady-FPS limiter, on the report card.'
    } elseif ($limit.Name -eq 'Network') {
        Add-Idea 'medium' 'fps' 'The network was busy during the flight' `
            ("{0} for {1}% of the flight. Average {2} MB/s (peak {3}).{4}" -f $limit.DevName, $limit.Percent, $limit.NetAvg, $limit.NetMax, $fpsBit) `
            'Turn off photogrammetry or pause other downloads if FPS dips near airports. Live weather can hitch the sim the same way.' `
            'Treat high Network Interface Bytes/sec as Limited by Network on the report card.'
    } elseif ($fpsAvg -gt 0 -and $fpsAvg -lt 28 -and $limit.Name -in @('None', 'Unknown')) {
        Add-Idea 'medium' 'fps' 'FPS was low without a maxed-out part' `
            ("Average FPS was {0} but CPU, GPU, RAM, disk, and network were not pegged for most of the flight." -f $fpsAvg) `
            $(if ([int]$Session.FrameLimiter -ge 15 -and [int]$Session.FrameLimiter -le 90) {
                    'Your sim Max Frame Rate is {0}. Raise it if you want more FPS, or leave it if that cap is on purpose.' -f $Session.FrameLimiter
                } elseif ([bool]$Session.VSync) {
                    'VSync is on in the sim. That can lock FPS to the monitor. Turn it off or use a higher Max Frame Rate if you want more frames.'
                } else {
                    'Check VSync, a frame-rate cap, or AutoFPS. A limiter in the sim settings can hold FPS down on purpose.'
                }) `
            'If FPS is low and no hardware limiter is set, mention frame-cap / VSync / AutoFPS on the report card.'
    }

    if ($Session.CooldownSamples -gt [int]($Session.Samples * 0.2) -and $Session.Dismissed -gt 0) {
        Add-Idea 'low' 'detection' 'Long quiet window after Not now' `
            ("{0} of {1} samples were in dismiss-cooldown. Later hogs may have been skipped." -f $Session.CooldownSamples, $Session.Samples) `
            'Lower DismissMinutes from 15 to 8 in Config.json.' `
            'Keep cooldown on Dismiss only (already the case). Consider a shorter default and a per-process cooldown instead of a global one.'
    }

    if ($ideas.Count -eq 0) {
        Add-Idea 'low' 'none' 'No change needed this session' `
            'The guard watched the flight, stayed quiet when the PC was clean, and did not fail any actions.' `
            'Leave Config.json as-is.' `
            'No development task from this session. Do not churn defaults.'
    }

    return [object[]]$ideas.ToArray()
}

function Get-ScalarText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Array]) {
        if ($Value.Length -eq 0) { return '' }
        return (Get-ScalarText $Value[0])
    }
    $t = $Value.ToString()
    if ($t -eq 'System.Object[]') { return '' }
    return $t
}

function Get-SessionScore {
    param($Session, $Avg, $Ideas)
    $score = 78
    $notes = New-Object System.Collections.Generic.List[string]
    $acted = [int]$Session.SleepOk + [int]$Session.CloseOk

    if ($Session.Samples -ge 20) { $score += 4; [void]$notes.Add('+ watched a full sample set') }
    if ($acted -gt 0) { $score += 8; [void]$notes.Add(('+ you accepted {0} Sleep/Close action(s)' -f $acted)) }
    if ($Session.SleepFail -eq 0 -and $Session.CloseFail -eq 0 -and $acted -gt 0) {
        $score += 4
        [void]$notes.Add('+ every accepted action succeeded')
    }
    if ($null -ne $Session.RamAfterActionMB -and $Session.RamAtStartMB -gt 0 -and $Session.RamAfterActionMB -gt $Session.RamAtStartMB) {
        $gain = $Session.RamAfterActionMB - $Session.RamAtStartMB
        $score += 6
        [void]$notes.Add(('+ free RAM rose by {0} MB after an action' -f $gain))
    }
    if ($Session.ToastShown -eq 0 -and $Avg.OtherCpuAvg -lt 2 -and $Session.FreeRamMin -ge [int]$script:Config.LowRamMB) {
        $score += 8
        [void]$notes.Add('+ clean flight: nothing worth suggesting')
    }
    if ($Session.Dismissed -ge 2) { $score -= 10; [void]$notes.Add(('- dismissed {0} overlay(s)' -f $Session.Dismissed)) }
    if ($Session.SleepFail -gt 0) { $score -= 12; [void]$notes.Add(('- Sleep failed {0} time(s)' -f $Session.SleepFail)) }
    if ($Session.TickMsMax -ge 800) { $score -= 8; [void]$notes.Add('- monitor tick spiked over 800 ms') }
    if ($Session.TickErrors -gt 0) { $score -= 8; [void]$notes.Add(('- {0} tick error(s)' -f $Session.TickErrors)) }
    if (-not $Session.Admin) { $score -= 6; [void]$notes.Add('- running without administrator rights') }
    $highMiss = @($Ideas | Where-Object { $_.Priority -eq 'high' -and $_.Area -eq 'lists' }).Count
    if ($highMiss -gt 0) { $score -= 10; [void]$notes.Add(('- missed {0} heavy program(s)' -f $highMiss)) }
    if ($Session.ToastShown -eq 0 -and $Avg.OtherCpuAvg -ge 4) {
        if ($Session.Suggested -and $Session.Suggested.Count -gt 0) {
            [void]$notes.Add('+ loud programs recorded for Grok (not shown to the user)')
        } else {
            $score -= 8
            [void]$notes.Add('- other programs used CPU and nothing was suggested')
        }
    }
    if ($Session.PausedSamples -gt [int]($Session.Samples * 0.4)) {
        $score -= 6
        [void]$notes.Add('- watching was paused for much of the flight')
    }
    $limitNote = Get-LimitSummary $Session
    if ($limitNote.Name -eq 'GPU') {
        [void]$notes.Add('+ graphics card was the limiter (settings, not other programs)')
    } elseif ($limitNote.Name -eq 'CPU' -and $Avg.OtherCpuAvg -ge 2.5) {
        $score -= 4
        [void]$notes.Add('- main thread limited while other programs still used CPU')
    } elseif ($limitNote.Name -eq 'CPU') {
        [void]$notes.Add('+ Limited by MainThread with other programs quiet')
    } elseif ($limitNote.Name -eq 'RAM') {
        $score -= 4
        [void]$notes.Add('- memory limiter (low free RAM)')
    }
    if ([double]$Session.FpsAvg -gt 0) {
        [void]$notes.Add(('+ FPS captured: avg {0}' -f $Session.FpsAvg))
    }

    if ($score -gt 100) { $score = 100 }
    if ($score -lt 0) { $score = 0 }
    return @{ Score = [int]$score; Notes = @($notes) }
}

function Write-SessionFiles {
    param($Payload, [string]$Stamp, [string]$Sim)
    $dir = Join-Path $script:LogDir 'Sessions'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $safeSim = ($Sim -replace '[^\w\-]', '')
    if (-not $safeSim) { $safeSim = 'MSFS' }
    $base = Join-Path $dir ('{0}-{1}' -f $Stamp, $safeSim)
    $jsonPath = "$base.json"
    $mdPath = "$base.md"
    $markdown = [string]$Payload.Markdown
    Set-Content -LiteralPath $mdPath -Value $markdown -Encoding UTF8
    try { $Payload.Markdown = $null } catch { }
    ($Payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:LogDir 'latest-session.json') -Value (Get-Content -LiteralPath $jsonPath -Raw) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:LogDir 'latest-session.md') -Value $markdown -Encoding UTF8
    $script:LastReportMd = $mdPath
    $script:LastReportJson = $jsonPath
    $script:LastSessionGrade = $Payload.Grade
    $script:LastSessionScore = [int]$Payload.Score
    $script:LastSessionFps = 0.0
    try { $script:LastSessionFps = [double]$Payload.GameplayFpsAvg } catch { }
    if ($script:LastSessionFps -le 0) {
        try { $script:LastSessionFps = [double]$Payload.FpsAvg } catch { }
    }
    return @{ Json = $jsonPath; Markdown = $mdPath }
}

function Build-SessionMarkdown {
    param($Session, $Avg, $ScoreInfo, $Ideas, [timespan]$Duration, $Perf)
    $lines = New-Object System.Collections.Generic.List[string]
    $grade = if ($Perf -and $Perf.Grade) { [string]$Perf.Grade } else { Get-LetterGrade $ScoreInfo.Score }
    $fps = 0.0
    try { $fps = [double]$Session.GameplayFpsAvg } catch { }
    if ($fps -le 0) { try { $fps = [double]$Session.FpsAvg } catch { } }
    [void]$lines.Add('# Flight log')
    [void]$lines.Add('')
    [void]$lines.Add(('**Grade {0}**' -f $grade))
    [void]$lines.Add('')
    if ($fps -gt 0) {
        [void]$lines.Add(('{0} avg FPS during gameplay' -f $fps))
    } else {
        [void]$lines.Add('No in-flight FPS captured')
    }
    $ramAvg = 0.0; $ramMax = 0.0
    try { $ramAvg = [double]$Avg.MsfsRamAvgGB } catch { }
    try { $ramMax = [double]$Session.MsfsRamMax } catch { }
    if ($ramAvg -gt 0 -or $ramMax -gt 0) {
        [void]$lines.Add(('RAM {0:n1} GB (peak {1:n1} GB)' -f $ramAvg, $ramMax))
    }
    $gpuAvg = 0.0; $vramMB = 0
    try {
        if ([int]$Session.HwSamples -gt 0) {
            $gpuAvg = [math]::Round([double]$Session.GpuSum / [int]$Session.HwSamples, 1)
        }
    } catch { }
    try { $vramMB = [int]$Session.VramMaxMB } catch { }
    $gpuBits = New-Object System.Collections.Generic.List[string]
    if ($gpuAvg -gt 0) { [void]$gpuBits.Add(('{0:n0}%' -f $gpuAvg)) }
    if ($vramMB -gt 0) { [void]$gpuBits.Add(('VRAM {0:n1} GB' -f ($vramMB / 1024.0))) }
    if ($gpuBits.Count -gt 0) { [void]$lines.Add(('GPU {0}' -f ($gpuBits -join '  '))) }
    [void]$lines.Add('')
    [void]$lines.Add(('{0}  -  {1}' -f (Format-Duration $Duration), (Get-SimShortName $Session.MsfsName)))
    return ($lines -join "`r`n")
}

function Test-ShowSuggestionOverlay {
    try { return [bool]$script:Config.ShowSuggestionOverlay } catch { return $false }
}

function Get-ReportFps {
    param($Payload)
    $fps = 0.0
    $inFlight = $false
    $known = $false
    try { $known = [bool]$Payload.GameplayKnown } catch { }
    try {
        $n = 0
        try { $n = [int]$Payload.GameplayFpsCount } catch { }
        if ($n -gt 0) {
            $fps = [double]$Payload.GameplayFpsAvg
            $inFlight = $true
        }
    } catch { }
    if ($fps -le 0 -and -not $known) {
        try { $fps = [double]$Payload.GameplayFpsAvg } catch { }
        if ($fps -le 0) {
            try { $fps = [double]$Payload.FpsAvg } catch { }
        }
    }
    return @{ Avg = [math]::Round($fps, 0); InFlight = $inFlight; Raw = $fps }
}

function Get-FlightLogTheme {
    return @{
        Navy    = [System.Drawing.Color]::FromArgb(10, 22, 44)
        Header  = [System.Drawing.Color]::FromArgb(14, 30, 58)
        Panel   = [System.Drawing.Color]::FromArgb(16, 34, 64)
        Gold    = [System.Drawing.Color]::FromArgb(201, 162, 74)
        GoldDim = [System.Drawing.Color]::FromArgb(150, 122, 62)
        Cream   = [System.Drawing.Color]::FromArgb(244, 236, 214)
        Muted   = [System.Drawing.Color]::FromArgb(156, 172, 196)
        Line    = [System.Drawing.Color]::FromArgb(36, 58, 92)
        Ink     = [System.Drawing.Color]::FromArgb(8, 16, 32)
    }
}

function New-LogStampBitmap {
    param(
        [string]$Letter,
        [string]$Caption,
        [System.Drawing.Color]$Ink,
        $Theme
    )
    $size = 132
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $bmp.SetResolution(96, 96)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    $fill = New-Object System.Drawing.SolidBrush $Theme.Panel
    $g.FillRectangle($fill, 8, 8, $size - 16, $size - 16)
    $fill.Dispose()

    $outer = New-Object System.Drawing.Pen $Theme.Gold, 2.2
    $inner = New-Object System.Drawing.Pen $Theme.GoldDim, 1.0
    $g.DrawRectangle($outer, 10, 10, $size - 21, $size - 21)
    $g.DrawRectangle($inner, 16, 16, $size - 33, $size - 33)
    $outer.Dispose()
    $inner.Dispose()

    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $capFont = New-Object System.Drawing.Font('Segoe UI Semibold', 7.5)
    $capBrush = New-Object System.Drawing.SolidBrush $Theme.Gold
    $g.DrawString('DISPATCH GRADE', $capFont, $capBrush, (New-Object System.Drawing.RectangleF 18, 20, ($size - 36), 16), $sf)
    $letterSize = if ($Letter.Length -gt 1) { 28 } else { 44 }
    $letterFont = New-Object System.Drawing.Font('Segoe UI Semibold', $letterSize, [System.Drawing.FontStyle]::Bold)
    $inkBrush = New-Object System.Drawing.SolidBrush $Ink
    $g.DrawString($Letter, $letterFont, $inkBrush, (New-Object System.Drawing.RectangleF 10, 34, ($size - 20), 70), $sf)
    $wordFont = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
    $g.DrawString($Caption.ToUpper(), $wordFont, $capBrush, (New-Object System.Drawing.RectangleF 18, 100, ($size - 36), 18), $sf)
    $capFont.Dispose(); $capBrush.Dispose(); $letterFont.Dispose(); $inkBrush.Dispose(); $wordFont.Dispose(); $sf.Dispose()
    $g.Dispose()
    return $bmp
}

function Add-AirlineHairline {
    param($Parent, [int]$X, [int]$Y, [int]$W, $Color)
    $line = New-Object System.Windows.Forms.Panel
    $line.BackColor = $Color
    $line.Location = New-Object System.Drawing.Point $X, $Y
    $line.Size = New-Object System.Drawing.Size $W, 1
    $Parent.Controls.Add($line)
}

function Add-AirlineField {
    param(
        $Parent,
        [int]$X, [int]$Y, [int]$W,
        [string]$Label,
        [string]$Value,
        $Theme
    )
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $Label.ToUpper()
    $cap.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 7)
    $cap.ForeColor = $Theme.Gold
    $cap.Location = New-Object System.Drawing.Point $X, $Y
    $cap.Size = New-Object System.Drawing.Size $W, 14
    $Parent.Controls.Add($cap)
    $val = New-Object System.Windows.Forms.Label
    $val.Text = $Value
    $val.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $val.ForeColor = $Theme.Cream
    $val.Location = New-Object System.Drawing.Point $X, ($Y + 14)
    $val.Size = New-Object System.Drawing.Size $W, 22
    $Parent.Controls.Add($val)
}

function Add-AirlineStatBox {
    param(
        $Parent,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [string]$Title,
        [string]$Value,
        [string]$Sub,
        $Theme
    )
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point $X, $Y
    $p.Size = New-Object System.Drawing.Size $W, $H
    $p.BackColor = $Theme.Panel
    $gold = New-Object System.Windows.Forms.Panel
    $gold.BackColor = $Theme.Gold
    $gold.Dock = [System.Windows.Forms.DockStyle]::Top
    $gold.Height = 2
    $p.Controls.Add($gold)
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = $Title.ToUpper()
    $hdr.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 7.5)
    $hdr.ForeColor = $Theme.Gold
    $hdr.Location = New-Object System.Drawing.Point 12, 10
    $hdr.Size = New-Object System.Drawing.Size ($W - 24), 14
    $p.Controls.Add($hdr)
    $val = New-Object System.Windows.Forms.Label
    $val.Text = $Value
    $val.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    $val.ForeColor = $Theme.Cream
    $val.Location = New-Object System.Drawing.Point 12, 26
    $val.Size = New-Object System.Drawing.Size ($W - 24), 28
    $p.Controls.Add($val)
    $subLbl = New-Object System.Windows.Forms.Label
    $subLbl.Text = $Sub
    $subLbl.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $subLbl.ForeColor = $Theme.Muted
    $subLbl.Location = New-Object System.Drawing.Point 12, 54
    $subLbl.Size = New-Object System.Drawing.Size ($W - 24), 16
    $p.Controls.Add($subLbl)
    $Parent.Controls.Add($p)
    return $p
}

function Get-ReportRamGpu {
    param($Payload)
    $ramAvg = 0.0; $ramMax = 0.0
    try { $ramAvg = [double]$Payload.MsfsRamAvgGB } catch { }
    try { $ramMax = [double]$Payload.MsfsRamMaxGB } catch { }
    $gpuAvg = 0.0; $gpuMax = 0.0; $vramMB = 0
    try { $gpuAvg = [double]$Payload.GpuAvg } catch { }
    try { $gpuMax = [double]$Payload.GpuMax } catch { }
    try { $vramMB = [int]$Payload.VramMaxMB } catch { }
    $dash = [string][char]0x2014
    $ramVal = $dash
    $ramSub = 'sim average'
    if ($ramAvg -gt 0) {
        $ramVal = ('{0:n1} GB' -f $ramAvg)
        if ($ramMax -gt 0) { $ramSub = ('peak {0:n1} GB' -f $ramMax) }
    } elseif ($ramMax -gt 0) {
        $ramVal = ('{0:n1} GB' -f $ramMax)
        $ramSub = 'peak'
    }
    $gpuVal = $dash
    $gpuSub = 'average'
    if ($gpuAvg -gt 0.5) {
        $gpuVal = ('{0:n0}%' -f $gpuAvg)
        if ($vramMB -gt 0) {
            $gpuSub = ('VRAM {0:n1} GB' -f ($vramMB / 1024.0))
        } elseif ($gpuMax -gt 0) {
            $gpuSub = ('peak {0:n0}%' -f $gpuMax)
        }
    } elseif ($vramMB -gt 0) {
        $gpuVal = ('{0:n1} GB' -f ($vramMB / 1024.0))
        $gpuSub = 'VRAM peak'
    } elseif ($gpuMax -gt 0.5) {
        $gpuVal = ('{0:n0}%' -f $gpuMax)
        $gpuSub = 'peak'
    }
    return @{
        RamValue = $ramVal
        RamSub   = $ramSub
        GpuValue = $gpuVal
        GpuSub   = $gpuSub
    }
}

function Get-FlightLogDate {
    param($Payload)
    $raw = $null
    try { $raw = [string]$Payload.StartedAt } catch { }
    if ($raw) {
        try {
            $dt = [datetime]$raw
            return $dt.ToString('dd MMM yyyy').ToUpper()
        } catch { }
    }
    return (Get-Date).ToString('dd MMM yyyy').ToUpper()
}

function Show-UserReportCard {
    param($Payload, $DurationText)
    $theme = Get-FlightLogTheme
    $info = Get-ReportFps $Payload
    $cap = 0
    try { $cap = [int]$Payload.FrameLimiter } catch { }
    $storedGrade = ''
    try { $storedGrade = [string]$Payload.Grade } catch { }
    $perf = Get-GameplayGrade -Avg $info.Raw -Cap $cap
    if ($storedGrade -and $storedGrade -match '^[A-F]$' -and [int]$Payload.SchemaVersion -ge 3) {
        $perf.Grade = $storedGrade
        try { $perf.Score = [int]$Payload.Score } catch { }
        try { if ($Payload.GradeLabel) { $perf.Label = [string]$Payload.GradeLabel } } catch { }
    }
    $grade = [string]$perf.Grade
    $color = Get-GradeColor $grade
    $simName = Get-SimShortName ([string]$Payload.Sim)
    if (-not $DurationText) {
        try { $DurationText = [string]$Payload.DurationText } catch { }
    }
    if (-not $DurationText) { $DurationText = [string][char]0x2014 }
    $logId = '--------'
    try {
        $id = [string]$Payload.Id
        if ($id) { $logId = $id.ToUpper() }
    } catch { }
    $dateText = Get-FlightLogDate $Payload
    $fpsText = if ($info.Raw -gt 0) { '{0}' -f $info.Avg } else { [string][char]0x2014 }
    $fpsSub = if ($info.Raw -gt 0) { 'AVERAGE DURING GAMEPLAY' } else { 'NO IN-FLIGHT FPS' }
    $hw = Get-ReportRamGpu $Payload

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Flight Log'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.Size = New-Object System.Drawing.Size 420, 590
    $f.BackColor = $theme.Navy
    $f.ForeColor = $theme.Cream
    $f.TopMost = $true
    $f.ShowInTaskbar = $true
    $f.KeyPreview = $true
    $f.Add_KeyDown({
            if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $this.Close() }
        })
    if ($script:IconOk) { $f.Icon = $script:IconOk }
    try {
        $prop = $f.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
        if ($prop) { $prop.SetValue($f, $true, $null) }
    } catch { }

    $f.Add_Load({
            if ('GuardToastForm' -as [type]) {
                $rgn = [GuardToastForm]::CreateRoundRectRgn(0, 0, ($this.Width + 1), ($this.Height + 1), 14, 14)
                $this.Region = [System.Drawing.Region]::FromHrgn($rgn)
            }
        })

    $livery = New-Object System.Windows.Forms.Panel
    $livery.BackColor = $theme.Gold
    $livery.Dock = [System.Windows.Forms.DockStyle]::Top
    $livery.Height = 6
    $f.Controls.Add($livery)

    $header = New-Object System.Windows.Forms.Panel
    $header.BackColor = $theme.Header
    $header.Location = New-Object System.Drawing.Point 0, 6
    $header.Size = New-Object System.Drawing.Size 420, 56
    $f.Controls.Add($header)

    $wing = New-Object System.Windows.Forms.PictureBox
    $wing.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::CenterImage
    $wing.Location = New-Object System.Drawing.Point 16, 10
    $wing.Size = New-Object System.Drawing.Size 36, 36
    $wing.BackColor = $theme.Header
    $wing.Image = (New-GuardBitmap 28 $theme.Gold)
    $header.Controls.Add($wing)

    $co = New-Object System.Windows.Forms.Label
    $co.Text = 'MSFS GUARD'
    $co.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $co.ForeColor = $theme.Cream
    $co.Location = New-Object System.Drawing.Point 56, 8
    $co.Size = New-Object System.Drawing.Size 200, 22
    $header.Controls.Add($co)
    $coSub = New-Object System.Windows.Forms.Label
    $coSub.Text = 'AIRLINE OPERATIONS'
    $coSub.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 7.5)
    $coSub.ForeColor = $theme.Gold
    $coSub.Location = New-Object System.Drawing.Point 56, 30
    $coSub.Size = New-Object System.Drawing.Size 200, 16
    $header.Controls.Add($coSub)

    $doc = New-Object System.Windows.Forms.Label
    $doc.Text = 'FLIGHT LOG'
    $doc.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $doc.ForeColor = $theme.Gold
    $doc.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $doc.Location = New-Object System.Drawing.Point 250, 8
    $doc.Size = New-Object System.Drawing.Size 154, 22
    $header.Controls.Add($doc)
    $docSub = New-Object System.Windows.Forms.Label
    $docSub.Text = 'TECHNICAL REPORT'
    $docSub.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $docSub.ForeColor = $theme.Muted
    $docSub.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $docSub.Location = New-Object System.Drawing.Point 250, 30
    $docSub.Size = New-Object System.Drawing.Size 154, 16
    $header.Controls.Add($docSub)

    Add-AirlineHairline $f 0 62 420 $theme.Gold

    Add-AirlineField $f 24 76 180 'Date' $dateText $theme
    Add-AirlineField $f 220 76 176 'Block time' $DurationText $theme
    Add-AirlineField $f 24 118 180 'Aircraft' $simName $theme
    Add-AirlineField $f 220 118 176 'Log no.' $logId $theme

    Add-AirlineHairline $f 24 160 372 $theme.Line
    $sec = New-Object System.Windows.Forms.Label
    $sec.Text = '  PERFORMANCE  '
    $sec.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 7.5)
    $sec.ForeColor = $theme.Gold
    $sec.BackColor = $theme.Navy
    $sec.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $sec.AutoSize = $true
    $sec.Location = New-Object System.Drawing.Point 155, 152
    $f.Controls.Add($sec)

    $stamp = New-Object System.Windows.Forms.PictureBox
    $stamp.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::CenterImage
    $stamp.Location = New-Object System.Drawing.Point 24, 176
    $stamp.Size = New-Object System.Drawing.Size 132, 132
    $stamp.BackColor = $theme.Navy
    $stamp.Image = (New-LogStampBitmap $grade ([string]$perf.Label) $color $theme)
    $f.Controls.Add($stamp)

    $fpsCap = New-Object System.Windows.Forms.Label
    $fpsCap.Text = 'AVG FPS'
    $fpsCap.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
    $fpsCap.ForeColor = $theme.Gold
    $fpsCap.Location = New-Object System.Drawing.Point 172, 196
    $fpsCap.Size = New-Object System.Drawing.Size 220, 16
    $f.Controls.Add($fpsCap)
    $fpsNum = New-Object System.Windows.Forms.Label
    $fpsNum.Text = $fpsText
    $fpsNum.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 36)
    $fpsNum.ForeColor = $theme.Cream
    $fpsNum.Location = New-Object System.Drawing.Point 168, 212
    $fpsNum.Size = New-Object System.Drawing.Size 228, 56
    $f.Controls.Add($fpsNum)
    $fpsNote = New-Object System.Windows.Forms.Label
    $fpsNote.Text = $fpsSub
    $fpsNote.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $fpsNote.ForeColor = $theme.Muted
    $fpsNote.Location = New-Object System.Drawing.Point 172, 268
    $fpsNote.Size = New-Object System.Drawing.Size 220, 16
    $f.Controls.Add($fpsNote)

    $ramBox = Add-AirlineStatBox $f 24 324 180 78 'RAM' $hw.RamValue $hw.RamSub $theme
    $gpuBox = Add-AirlineStatBox $f 216 324 180 78 'GPU' $hw.GpuValue $hw.GpuSub $theme

    Add-AirlineHairline $f 24 418 372 $theme.Line
    $end = New-Object System.Windows.Forms.Label
    $end.Text = 'END OF LOG  -  NO DISPATCH REMARKS'
    $end.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $end.ForeColor = $theme.Muted
    $end.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $end.Location = New-Object System.Drawing.Point 0, 428
    $end.Size = New-Object System.Drawing.Size 420, 16
    $f.Controls.Add($end)

    $btn = New-FlatButton 'FILE LOG' 140 460 140 36 $theme.Gold $theme.Ink
    $btn.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    $btn.Add_Click({ $this.FindForm().Close() })
    $f.Controls.Add($btn)
    $f.AcceptButton = $btn
    $f.CancelButton = $btn

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.BackColor = $theme.Gold
    $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottom.Height = 6
    $f.Controls.Add($bottom)

    [void]$f.ShowDialog()
    if ($stamp.Image) { $stamp.Image.Dispose() }
    if ($wing.Image) { $wing.Image.Dispose() }
}

function Finish-AfterSession {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:LogDir 'session-complete.flag') -Value ((Get-Date).ToString('o')) -Encoding UTF8
    } catch { }
    try {
        $done = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\MSFSPerformanceGuard-SessionDone')
        [void]$done.Set()
    } catch { }
    Close-Guard
}

function Update-GrokBriefing {
    param($LatestPayload)
    $dir = Join-Path $script:LogDir 'Sessions'
    $keep = [int]$script:Config.BriefingKeepSessions
    if ($keep -lt 3) { $keep = 3 }
    $files = @()
    if (Test-Path -LiteralPath $dir) {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First $keep)
    }
    $sessions = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $j = Read-JsonFile $f.FullName
        if ($j) { [void]$sessions.Add($j) }
    }
    $taskHits = @{}
    foreach ($s in $sessions) {
        $ideaBag = New-Object System.Collections.Generic.List[object]
        foreach ($idea in @($s.Suggestions)) {
            if ($idea -is [System.Array]) {
                foreach ($inner in $idea) { if ($inner) { [void]$ideaBag.Add($inner) } }
            } elseif ($idea) {
                [void]$ideaBag.Add($idea)
            }
        }
        foreach ($idea in $ideaBag) {
            if (-not $idea) { continue }
            if ((Get-ScalarText $idea.Area) -eq 'none') { continue }
            $key = Get-ScalarText $idea.Title
            if (-not $key) { continue }
            if (-not $taskHits.ContainsKey($key)) {
                $taskHits[$key] = @{
                    Title    = $key
                    Priority = (Get-ScalarText $idea.Priority)
                    Area     = (Get-ScalarText $idea.Area)
                    GrokTask = (Get-ScalarText $idea.GrokTask)
                    Change   = (Get-ScalarText $idea.Change)
                    Count    = 0
                }
            }
            $taskHits[$key].Count++
        }
    }
    $ranked = @($taskHits.Values | Sort-Object @{ Expression = {
                switch ($_.Priority) { 'high' { 0 } 'medium' { 1 } default { 2 } }
            } }, @{ Expression = { -$_.Count } })

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# GROK DEV BRIEFING')
    [void]$lines.Add('')
    [void]$lines.Add('Read this file **before** changing MSFS Performance Guard.')
    [void]$lines.Add('It is rewritten after every Flight Simulator session from real telemetry, not guesses.')
    [void]$lines.Add('')
    [void]$lines.Add(('Last updated: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)))
    $briefFps = 0.0
    try { $briefFps = [double]$LatestPayload.GameplayFpsAvg } catch { }
    if ($briefFps -le 0) { try { $briefFps = [double]$LatestPayload.FpsAvg } catch { } }
    $guardBit = ''
    try {
        if ($LatestPayload.GuardGrade) {
            $guardBit = (', guard **{0}** ({1}/100)' -f $LatestPayload.GuardGrade, $LatestPayload.GuardScore)
        }
    } catch { }
    [void]$lines.Add(('Latest session: flight **{0}** ({1} FPS){2}, {3}, {4}.' -f $LatestPayload.Grade, $briefFps, $guardBit, $LatestPayload.Sim, $LatestPayload.DurationText))
    [void]$lines.Add('')
    [void]$lines.Add('This file is **developer-only**. It is never shown on the on-screen flight report card.')
    [void]$lines.Add('')
    [void]$lines.Add('## This session')
    [void]$lines.Add('')
    [void]$lines.Add(('| Field | Value |'))
    [void]$lines.Add('| --- | --- |')
    [void]$lines.Add(('| Outcome | {0} |' -f $LatestPayload.Outcome))
    [void]$lines.Add(('| Admin | {0} |' -f $LatestPayload.Admin))
    [void]$lines.Add(('| Samples | {0} (tick avg {1} ms, max {2} ms) |' -f $LatestPayload.Samples, $LatestPayload.TickMsAvg, $LatestPayload.TickMsMax))
    [void]$lines.Add(('| MSFS CPU | avg {0}% max {1}% |' -f $LatestPayload.MsfsCpuAvg, $LatestPayload.MsfsCpuMax))
    [void]$lines.Add(('| MSFS RAM | avg {0} GB max {1} GB |' -f $LatestPayload.MsfsRamAvgGB, $LatestPayload.MsfsRamMaxGB))
    [void]$lines.Add(('| Other CPU | avg {0}% |' -f $LatestPayload.OtherCpuAvg))
    [void]$lines.Add(('| FPS | gameplay avg {0} (session avg {1} min {2} max {3}) via {4} |' -f $LatestPayload.GameplayFpsAvg, $LatestPayload.FpsAvg, $LatestPayload.FpsMin, $LatestPayload.FpsMax, $LatestPayload.FpsSource))
    [void]$lines.Add(('| Sim settings | cap {0} VSync {1} TLOD {2} clouds {3} |' -f $LatestPayload.FrameLimiter, $LatestPayload.VSync, $LatestPayload.Tlod, $LatestPayload.CloudsQuality))
    [void]$lines.Add(('| Limiter | {0} ({1}%) mix {2} |' -f $LatestPayload.LimitDevName, $LatestPayload.LimitPercent, $LatestPayload.LimitWhen))
    [void]$lines.Add(('| GPU / VRAM | avg {0}% peak {1}% / {2} MB |' -f $LatestPayload.GpuAvg, $LatestPayload.GpuMax, $LatestPayload.VramMaxMB))
    [void]$lines.Add(('| Disk / Net | q {0} peak {1} MB/s / avg {2} MB/s |' -f $LatestPayload.DiskQAvg, $LatestPayload.DiskMBpsMax, $LatestPayload.NetAvgMBps))
    [void]$lines.Add(('| Overlays / Sleep ok / Fail | {0} / {1} / {2} |' -f $LatestPayload.ToastShown, $LatestPayload.SleepOk, $LatestPayload.SleepFail))
    [void]$lines.Add('')
    foreach ($n in @($LatestPayload.ScoreNotes)) {
        if ($n) { [void]$lines.Add("- $n") }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Next development tasks')
    [void]$lines.Add('')
    if ($ranked.Count -eq 0) {
        [void]$lines.Add('No recurring development work. Do not churn defaults.')
    } else {
        $i = 1
        foreach ($t in ($ranked | Select-Object -First 8)) {
            [void]$lines.Add(('### {0}. [{1}] {2}' -f $i, $t.Priority, $t.Title))
            [void]$lines.Add('')
            [void]$lines.Add(('Seen in **{0}** recent session(s). Area: `{1}`' -f $t.Count, $t.Area))
            [void]$lines.Add('')
            [void]$lines.Add(('**Implement:** {0}' -f $t.GrokTask))
            [void]$lines.Add('')
            $i++
        }
    }
    [void]$lines.Add('## Recent sessions')
    [void]$lines.Add('')
    [void]$lines.Add('| When | Sim | Duration | Grade | FPS | Overlays | Sleep ok | Dismiss |')
    [void]$lines.Add('| --- | --- | --- | --- | ---: | ---: | ---: | ---: |')
    foreach ($s in $sessions) {
        $rowFps = 0.0
        try { $rowFps = [double]$s.GameplayFpsAvg } catch { }
        if ($rowFps -le 0) { try { $rowFps = [double]$s.FpsAvg } catch { } }
        [void]$lines.Add(('| {0} | {1} | {2} | {3} ({4}) | {5} | {6} | {7} | {8} |' -f $s.EndedAt, $s.Sim, $s.DurationText, $s.Grade, $s.Score, $rowFps, $s.ToastShown, $s.SleepOk, $s.Dismissed))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## How to work this repo')
    [void]$lines.Add('')
    [void]$lines.Add('- Code: `MSFSGuard.ps1`. Config: `Config.json`.')
    [void]$lines.Add('- After each flight: `Logs/GROK-DEV-BRIEFING.md` (this file), `Logs/latest-grok-dev.md`, `Logs/Sessions/*.grok.md`.')
    [void]$lines.Add('- Prefer the tasks above over drive-by refactors.')
    [void]$lines.Add('- Keep Sleep/Close opt-in unless the user already enabled AutoSleepKnownHogs.')
    [void]$lines.Add('- Never suggest companions, Defender, GPU helpers, WebView2, or protected OS processes.')
    [void]$lines.Add('- After code changes, syntax-parse MSFSGuard.ps1, rebuild MSFSGuard.exe if the host changed, start via scheduled task.')
    [void]$lines.Add('')
    [void]$lines.Add('See `GROK.md` in the project root.')
    $path = Join-Path $script:LogDir 'GROK-DEV-BRIEFING.md'
    Set-Content -LiteralPath $path -Value ($lines -join "`r`n") -Encoding UTF8
}

function Write-GrokSessionNotes {
    param($Payload, [string]$Stamp, [string]$Sim)
    $dir = Join-Path $script:LogDir 'Sessions'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $safeSim = ($Sim -replace '[^\w\-]', '')
    if (-not $safeSim) { $safeSim = 'MSFS' }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# Grok session notes (developer only)')
    [void]$lines.Add('')
    [void]$lines.Add('Not shown on the user flight report card.')
    [void]$lines.Add('')
    [void]$lines.Add(('**{0}** - flight {1} ({2} FPS) - guard {3} ({4}/100) - {5} - {6}' -f $Payload.Sim, $Payload.Grade, $Payload.GameplayFpsAvg, $Payload.GuardGrade, $Payload.GuardScore, $Payload.DurationText, $Payload.Outcome))
    [void]$lines.Add('')
    [void]$lines.Add('## How the session went')
    [void]$lines.Add('')
    [void]$lines.Add(('- Admin: {0}' -f $Payload.Admin))
    [void]$lines.Add(('- Samples: {0}; tick avg {1} ms (max {2} ms); errors {3}' -f $Payload.Samples, $Payload.TickMsAvg, $Payload.TickMsMax, $Payload.TickErrors))
    [void]$lines.Add(('- MSFS CPU avg {0}% peak {1}%; RAM avg {2} GB peak {3} GB' -f $Payload.MsfsCpuAvg, $Payload.MsfsCpuMax, $Payload.MsfsRamAvgGB, $Payload.MsfsRamMaxGB))
    [void]$lines.Add(('- Other programs CPU avg {0}%' -f $Payload.OtherCpuAvg))
    [void]$lines.Add(('- FPS gameplay avg {0} (session avg {1} min {2} max {3}) samples {4} via {5}' -f $Payload.GameplayFpsAvg, $Payload.FpsAvg, $Payload.FpsMin, $Payload.FpsMax, $Payload.FpsCount, $Payload.FpsSource))
    [void]$lines.Add(('- Sim UserCfg: cap {0}, VSync {1}, dynamic {2}/{3}, FG {4}, TLOD {5}, OLOD {6}, clouds {7}, traffic {8}' -f $Payload.FrameLimiter, $Payload.VSync, $Payload.DynamicSettings, $Payload.TargetFrameRate, $Payload.FrameGeneration, $Payload.Tlod, $Payload.Olod, $Payload.CloudsQuality, $Payload.TrafficQty))
    [void]$lines.Add(('- Limiter: {0} ({1}%) mix {2}' -f $Payload.LimitDevName, $Payload.LimitPercent, $Payload.LimitWhen))
    [void]$lines.Add(('- GPU avg {0}% peak {1}% VRAM {2} MB; sys CPU {3}%; disk q {4}/{5} {6} MB/s; net {7}/{8} MB/s' -f $Payload.GpuAvg, $Payload.GpuMax, $Payload.VramMaxMB, $Payload.SysCpuAvg, $Payload.DiskQAvg, $Payload.DiskQMax, $Payload.DiskMBpsMax, $Payload.NetAvgMBps, $Payload.NetMaxMBps))
    [void]$lines.Add(('- Bottleneck counts CPU/GPU/RAM/Disk/Net/None: {0}/{1}/{2}/{3}/{4}/{5}' -f $Payload.BnCpu, $Payload.BnGpu, $Payload.BnRam, $Payload.BnDisk, $Payload.BnNet, $Payload.BnNone))
    [void]$lines.Add(('- Overlays shown: {0}; Sleep ok/fail {1}/{2}; Close ok/fail {3}/{4}; Dismiss {5}' -f $Payload.ToastShown, $Payload.SleepOk, $Payload.SleepFail, $Payload.CloseOk, $Payload.CloseFail, $Payload.Dismissed))
    [void]$lines.Add('')
    foreach ($n in @($Payload.ScoreNotes)) {
        if ($n) { [void]$lines.Add("- $n") }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Actions')
    [void]$lines.Add('')
    $acts = @($Payload.Actions)
    if ($acts.Count -eq 0) {
        [void]$lines.Add('None.')
    } else {
        foreach ($a in $acts) {
            [void]$lines.Add(('- {0} {1} {2} ok={3}' -f $a.At, $a.Type, $a.Name, $a.Ok))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Loudest other programs')
    [void]$lines.Add('')
    foreach ($p in @($Payload.TopPrograms)) {
        [void]$lines.Add(('- {0}: max {1}% CPU, {2} MB, samples {3}, hog={4}, companion={5}' -f $p.Label, $p.MaxCpu, $p.MaxMemMB, $p.Samples, $p.KnownHog, $p.Companion))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Near misses (not suggested)')
    [void]$lines.Add('')
    $nms = @($Payload.NearMisses)
    if ($nms.Count -eq 0) {
        [void]$lines.Add('None recorded.')
    } else {
        foreach ($nm in $nms) {
            [void]$lines.Add(('- {0}: {1} samples near bar, max {2}% CPU, {3} MB' -f $nm.Name, $nm.Count, $nm.MaxCpu, $nm.MaxMemMB))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Implement next')
    [void]$lines.Add('')
    $any = $false
    foreach ($idea in @($Payload.Suggestions)) {
        $area = Get-ScalarText $idea.Area
        if ($area -eq 'none') { continue }
        $any = $true
        [void]$lines.Add(('### [{0}] {1}' -f (Get-ScalarText $idea.Priority), (Get-ScalarText $idea.Title)))
        [void]$lines.Add('')
        [void]$lines.Add((Get-ScalarText $idea.Why))
        [void]$lines.Add('')
        [void]$lines.Add(('**Implement:** {0}' -f (Get-ScalarText $idea.GrokTask)))
        [void]$lines.Add('')
    }
    if (-not $any) {
        [void]$lines.Add('No development tasks this session. Do not churn defaults.')
        [void]$lines.Add('')
    }
    $text = $lines -join "`r`n"
    $path = Join-Path $dir ('{0}-{1}.grok.md' -f $Stamp, $safeSim)
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:LogDir 'latest-grok-dev.md') -Value $text -Encoding UTF8
    Write-Log ("Grok dev notes -> {0}" -f $path) 'OK'
}

function Complete-FlightSession {
    param([string]$Outcome = 'completed')
    $session = $script:Session
    $script:Session = $null
    if (-not $session) { return }
    $fps = Stop-FpsCapture
    if (-not $session.FpsCount -or [int]$session.FpsCount -le 0) {
        $session['FpsCount'] = [int]$fps.Count
        $session['FpsAvg'] = [double]$fps.Avg
        $session['FpsMin'] = [double]$fps.Min
        $session['FpsMax'] = [double]$fps.Max
        $session['FpsAvgMs'] = [double]$fps.AvgMs
        $session['FpsSource'] = [string]$fps.Source
        $session['SimSpeed'] = [double]$fps.SimSpeed
        $session['GameplayFpsCount'] = [int]$fps.GameplayCount
        $session['GameplayFpsAvg'] = [double]$fps.GameplayAvg
        $session['GameplayFpsMin'] = [double]$fps.GameplayMin
        $session['GameplayFpsMax'] = [double]$fps.GameplayMax
        $session['GameplayFpsAvgMs'] = [double]$fps.GameplayAvgMs
        $session['GameplayKnown'] = [bool]$fps.GameplayKnown
    }
    $script:LastFps = $null
    $script:LastLimit = 'None'
    if (-not [bool]$script:Config.WriteSessionReports) { return }

    $session.EndedAt = Get-Date
    $session.Outcome = $Outcome
    $startAt = [datetime]$session.StartedAt
    $endAt = [datetime]$session.EndedAt
    $duration = $endAt - $startAt
    $minSec = 45.0
    try { $minSec = [double]("$($script:Config.MinSessionSeconds)") } catch { }
    if ($duration.TotalSeconds -lt $minSec -and $session.Actions.Count -eq 0 -and $session.ToastShown -eq 0) {
        Write-Log ("Session {0} skipped (only {1:n0}s, no actions)" -f $session.Id, $duration.TotalSeconds) 'INFO'
        if (-not $WriteTestReport -and [bool]$script:Config.ExitAfterSession) { Finish-AfterSession }
        return
    }

    try {
        $avg = Get-SessionAverages $session
        $ideas = @()
        foreach ($ideaItem in @(Get-SessionSuggestions $session $avg)) {
            if ($ideaItem -is [System.Array]) {
                foreach ($inner in $ideaItem) { $ideas += $inner }
            } elseif ($ideaItem) {
                $ideas += $ideaItem
            }
        }
        $scoreInfo = Get-SessionScore $session $avg $ideas
        $guardGrade = Get-LetterGrade $scoreInfo.Score
        $gameplayAvg = 0.0
        $gameplayKnown = $false
        try { $gameplayKnown = [bool]$session.GameplayKnown } catch { }
        try { $gameplayAvg = [double]$session.GameplayFpsAvg } catch { }
        if ($gameplayAvg -le 0 -and -not $gameplayKnown) {
            try { $gameplayAvg = [double]$session.FpsAvg } catch { }
        }
        $cap = 0
        try { $cap = [int]$session.FrameLimiter } catch { }
        $perf = Get-GameplayGrade -Avg $gameplayAvg -Cap $cap
        $grade = [string]$perf.Grade
        $md = Build-SessionMarkdown $session $avg $scoreInfo $ideas $duration $perf
        $stamp = '{0:yyyyMMdd-HHmmss}' -f $session.EndedAt
        $freeMin = if ($session.FreeRamMin -eq [int]::MaxValue) { $null } else { [int]$session.FreeRamMin }
        $durationText = Format-Duration $duration
        $topPrograms = New-Object System.Collections.Generic.List[object]
        foreach ($tp in @(Get-TopPeaks $session 8)) {
            $row = New-Object PSObject
            Add-Member -InputObject $row -NotePropertyName Name -NotePropertyValue $tp.Name
            Add-Member -InputObject $row -NotePropertyName Label -NotePropertyValue $tp.Label
            Add-Member -InputObject $row -NotePropertyName MaxCpu -NotePropertyValue ([math]::Round([double]$tp.MaxCpu, 2))
            Add-Member -InputObject $row -NotePropertyName MaxMemMB -NotePropertyValue $tp.MaxMemMB
            Add-Member -InputObject $row -NotePropertyName Samples -NotePropertyValue $tp.Samples
            Add-Member -InputObject $row -NotePropertyName KnownHog -NotePropertyValue $tp.KnownHog
            Add-Member -InputObject $row -NotePropertyName Companion -NotePropertyValue $tp.Companion
            [void]$topPrograms.Add($row)
        }
        $payload = New-Object PSObject
        Add-Member -InputObject $payload -NotePropertyName SchemaVersion -NotePropertyValue 3
        Add-Member -InputObject $payload -NotePropertyName Id -NotePropertyValue ([string]$session.Id)
        Add-Member -InputObject $payload -NotePropertyName StartedAt -NotePropertyValue $startAt.ToString('o')
        Add-Member -InputObject $payload -NotePropertyName EndedAt -NotePropertyValue $endAt.ToString('o')
        Add-Member -InputObject $payload -NotePropertyName DurationText -NotePropertyValue $durationText
        Add-Member -InputObject $payload -NotePropertyName DurationSec -NotePropertyValue ([int]$duration.TotalSeconds)
        Add-Member -InputObject $payload -NotePropertyName Outcome -NotePropertyValue $Outcome
        Add-Member -InputObject $payload -NotePropertyName Sim -NotePropertyValue ([string]$session.MsfsName)
        Add-Member -InputObject $payload -NotePropertyName Admin -NotePropertyValue ([bool]$session.Admin)
        Add-Member -InputObject $payload -NotePropertyName Cores -NotePropertyValue ([int]$session.Cores)
        Add-Member -InputObject $payload -NotePropertyName Samples -NotePropertyValue ([int]$session.Samples)
        Add-Member -InputObject $payload -NotePropertyName TickMsAvg -NotePropertyValue $avg.TickMsAvg
        Add-Member -InputObject $payload -NotePropertyName TickMsMax -NotePropertyValue ([int]$session.TickMsMax)
        Add-Member -InputObject $payload -NotePropertyName TickErrors -NotePropertyValue ([int]$session.TickErrors)
        Add-Member -InputObject $payload -NotePropertyName MsfsCpuAvg -NotePropertyValue $avg.MsfsCpuAvg
        Add-Member -InputObject $payload -NotePropertyName MsfsCpuMax -NotePropertyValue ([math]::Round([double]$session.MsfsCpuMax, 2))
        Add-Member -InputObject $payload -NotePropertyName MsfsRamAvgGB -NotePropertyValue $avg.MsfsRamAvgGB
        Add-Member -InputObject $payload -NotePropertyName MsfsRamMaxGB -NotePropertyValue ([math]::Round([double]$session.MsfsRamMax, 2))
        Add-Member -InputObject $payload -NotePropertyName OtherCpuAvg -NotePropertyValue $avg.OtherCpuAvg
        Add-Member -InputObject $payload -NotePropertyName FreeRamAvgMB -NotePropertyValue $avg.FreeRamAvgMB
        Add-Member -InputObject $payload -NotePropertyName FreeRamMinMB -NotePropertyValue $freeMin
        Add-Member -InputObject $payload -NotePropertyName ToastShown -NotePropertyValue ([int]$session.ToastShown)
        Add-Member -InputObject $payload -NotePropertyName SleepOk -NotePropertyValue ([int]$session.SleepOk)
        Add-Member -InputObject $payload -NotePropertyName SleepFail -NotePropertyValue ([int]$session.SleepFail)
        Add-Member -InputObject $payload -NotePropertyName CloseOk -NotePropertyValue ([int]$session.CloseOk)
        Add-Member -InputObject $payload -NotePropertyName CloseFail -NotePropertyValue ([int]$session.CloseFail)
        Add-Member -InputObject $payload -NotePropertyName Ignored -NotePropertyValue ([int]$session.Ignored)
        Add-Member -InputObject $payload -NotePropertyName Never -NotePropertyValue ([int]$session.Never)
        Add-Member -InputObject $payload -NotePropertyName Dismissed -NotePropertyValue ([int]$session.Dismissed)
        Add-Member -InputObject $payload -NotePropertyName AutoSleep -NotePropertyValue ([int]$session.AutoSleep)
        Add-Member -InputObject $payload -NotePropertyName Score -NotePropertyValue ([int]$perf.Score)
        Add-Member -InputObject $payload -NotePropertyName Grade -NotePropertyValue $grade
        Add-Member -InputObject $payload -NotePropertyName GradeLabel -NotePropertyValue ([string]$perf.Label)
        Add-Member -InputObject $payload -NotePropertyName GuardScore -NotePropertyValue ([int]$scoreInfo.Score)
        Add-Member -InputObject $payload -NotePropertyName GuardGrade -NotePropertyValue $guardGrade
        $notesCopy = @()
        if ($scoreInfo.Notes) { $notesCopy = [object[]]$scoreInfo.Notes }
        $ideasCopy = @()
        if ($ideas) { $ideasCopy = [object[]]$ideas }
        $shownCopy = @()
        if ($session.Suggested) { $shownCopy = @($session.Suggested | ForEach-Object { $_ }) }
        $actionCopy = @()
        if ($session.Actions) { $actionCopy = @($session.Actions | ForEach-Object { $_ }) }
        Add-Member -InputObject $payload -NotePropertyName ScoreNotes -NotePropertyValue $notesCopy
        Add-Member -InputObject $payload -NotePropertyName Suggestions -NotePropertyValue $ideasCopy
        Add-Member -InputObject $payload -NotePropertyName Suggested -NotePropertyValue $shownCopy
        Add-Member -InputObject $payload -NotePropertyName Actions -NotePropertyValue $actionCopy
        Add-Member -InputObject $payload -NotePropertyName TopPrograms -NotePropertyValue $topPrograms.ToArray()
        $near = @()
        if ($session.NearMisses) {
            $near = @($session.NearMisses.Values | Sort-Object { $_.Count } -Descending | Select-Object -First 12 | ForEach-Object {
                    [ordered]@{ Name = $_.Name; Count = $_.Count; MaxCpu = [math]::Round($_.MaxCpu, 2); MaxMemMB = $_.MaxMemMB }
                })
        }
        Add-Member -InputObject $payload -NotePropertyName NearMisses -NotePropertyValue $near
        $limit = Get-LimitSummary $session
        Add-Member -InputObject $payload -NotePropertyName FpsAvg -NotePropertyValue ([double]$session.FpsAvg)
        Add-Member -InputObject $payload -NotePropertyName FpsMin -NotePropertyValue ([double]$session.FpsMin)
        Add-Member -InputObject $payload -NotePropertyName FpsMax -NotePropertyValue ([double]$session.FpsMax)
        Add-Member -InputObject $payload -NotePropertyName FpsAvgMs -NotePropertyValue ([double]$session.FpsAvgMs)
        Add-Member -InputObject $payload -NotePropertyName FpsCount -NotePropertyValue ([int]$session.FpsCount)
        Add-Member -InputObject $payload -NotePropertyName FpsSource -NotePropertyValue ($(if ($session.FpsSource) { [string]$session.FpsSource } else { 'none' }))
        $gpAvg = 0.0; $gpMin = 0.0; $gpMax = 0.0; $gpMs = 0.0; $gpN = 0
        try { $gpAvg = [double]$session.GameplayFpsAvg } catch { }
        try { $gpMin = [double]$session.GameplayFpsMin } catch { }
        try { $gpMax = [double]$session.GameplayFpsMax } catch { }
        try { $gpMs = [double]$session.GameplayFpsAvgMs } catch { }
        try { $gpN = [int]$session.GameplayFpsCount } catch { }
        Add-Member -InputObject $payload -NotePropertyName GameplayFpsAvg -NotePropertyValue $gpAvg
        Add-Member -InputObject $payload -NotePropertyName GameplayFpsMin -NotePropertyValue $gpMin
        Add-Member -InputObject $payload -NotePropertyName GameplayFpsMax -NotePropertyValue $gpMax
        Add-Member -InputObject $payload -NotePropertyName GameplayFpsAvgMs -NotePropertyValue $gpMs
        Add-Member -InputObject $payload -NotePropertyName GameplayFpsCount -NotePropertyValue $gpN
        $gpKnown = $false
        try { $gpKnown = [bool]$session.GameplayKnown } catch { }
        Add-Member -InputObject $payload -NotePropertyName GameplayKnown -NotePropertyValue $gpKnown
        Add-Member -InputObject $payload -NotePropertyName SimSpeed -NotePropertyValue ($(if ($session.SimSpeed) { [double]$session.SimSpeed } else { 1.0 }))
        Add-Member -InputObject $payload -NotePropertyName FrameLimiter -NotePropertyValue ([int]$session.FrameLimiter)
        Add-Member -InputObject $payload -NotePropertyName VSync -NotePropertyValue ([bool]$session.VSync)
        Add-Member -InputObject $payload -NotePropertyName DynamicSettings -NotePropertyValue ([bool]$session.DynamicSettings)
        Add-Member -InputObject $payload -NotePropertyName TargetFrameRate -NotePropertyValue ([int]$session.TargetFrameRate)
        Add-Member -InputObject $payload -NotePropertyName FrameGeneration -NotePropertyValue ([string]$session.FrameGeneration)
        Add-Member -InputObject $payload -NotePropertyName AntiAliasing -NotePropertyValue ([string]$session.AntiAliasing)
        Add-Member -InputObject $payload -NotePropertyName Tlod -NotePropertyValue ([double]$session.Tlod)
        Add-Member -InputObject $payload -NotePropertyName Olod -NotePropertyValue ([double]$session.Olod)
        Add-Member -InputObject $payload -NotePropertyName CloudsQuality -NotePropertyValue ([int]$session.CloudsQuality)
        Add-Member -InputObject $payload -NotePropertyName TrafficQty -NotePropertyValue ([int]$session.TrafficQty)
        Add-Member -InputObject $payload -NotePropertyName LimitName -NotePropertyValue ([string]$limit.Name)
        Add-Member -InputObject $payload -NotePropertyName LimitDevName -NotePropertyValue ([string]$limit.DevName)
        Add-Member -InputObject $payload -NotePropertyName LimitPercent -NotePropertyValue ([int]$limit.Percent)
        Add-Member -InputObject $payload -NotePropertyName LimitWhen -NotePropertyValue ([string]$limit.When)
        Add-Member -InputObject $payload -NotePropertyName LimitDetail -NotePropertyValue ([string]$limit.Detail)
        Add-Member -InputObject $payload -NotePropertyName GpuAvg -NotePropertyValue ([double]$limit.GpuAvg)
        Add-Member -InputObject $payload -NotePropertyName GpuMax -NotePropertyValue ([double]$limit.GpuMax)
        Add-Member -InputObject $payload -NotePropertyName SysCpuAvg -NotePropertyValue ([double]$limit.SysCpuAvg)
        Add-Member -InputObject $payload -NotePropertyName DiskQAvg -NotePropertyValue ([double]$limit.DiskQAvg)
        Add-Member -InputObject $payload -NotePropertyName DiskQMax -NotePropertyValue ([double]$limit.DiskQMax)
        Add-Member -InputObject $payload -NotePropertyName DiskMBpsMax -NotePropertyValue ([double]$limit.DiskMax)
        Add-Member -InputObject $payload -NotePropertyName NetAvgMBps -NotePropertyValue ([double]$limit.NetAvg)
        Add-Member -InputObject $payload -NotePropertyName NetMaxMBps -NotePropertyValue ([double]$limit.NetMax)
        Add-Member -InputObject $payload -NotePropertyName VramMaxMB -NotePropertyValue ([int]$limit.VramMaxMB)
        Add-Member -InputObject $payload -NotePropertyName BnCpu -NotePropertyValue ([int]$limit.BnCpu)
        Add-Member -InputObject $payload -NotePropertyName BnGpu -NotePropertyValue ([int]$limit.BnGpu)
        Add-Member -InputObject $payload -NotePropertyName BnRam -NotePropertyValue ([int]$limit.BnRam)
        Add-Member -InputObject $payload -NotePropertyName BnDisk -NotePropertyValue ([int]$limit.BnDisk)
        Add-Member -InputObject $payload -NotePropertyName BnNet -NotePropertyValue ([int]$limit.BnNet)
        Add-Member -InputObject $payload -NotePropertyName BnNone -NotePropertyValue ([int]$limit.BnNone)
        Add-Member -InputObject $payload -NotePropertyName Markdown -NotePropertyValue $md
        $paths = Write-SessionFiles $payload $stamp $session.MsfsName
        Write-GrokSessionNotes -Payload $payload -Stamp $stamp -Sim $session.MsfsName
        Update-GrokBriefing $payload
        Write-Log ("Session report {0} grade {1} ({2} FPS) guard {3} ({4}) -> {5}" -f $session.Id, $grade, $gameplayAvg, $guardGrade, $scoreInfo.Score, $paths.Markdown) 'OK'
        if (-not $WriteTestReport) {
            try {
                Show-UserReportCard -Payload $payload -DurationText $durationText
            } catch {
                Write-Log ("Flight log UI failed: {0} :: {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) 'ERR'
            }
            if ([bool]$script:Config.ExitAfterSession) { Finish-AfterSession }
        }
    } catch {
        Write-Log ("Failed to write session report: {0} :: {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) 'ERR'
        if (-not $WriteTestReport -and [bool]$script:Config.ExitAfterSession -and -not $script:Exiting) {
            Finish-AfterSession
        }
    }
}

function Open-LastSessionReport {
    $path = $script:LastReportJson
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        $path = Join-Path $script:LogDir 'latest-session.json'
    }
    if (Test-Path -LiteralPath $path) {
        $payload = Read-JsonFile $path
        if ($payload) {
            $dur = ''
            try { $dur = [string]$payload.DurationText } catch { }
            Show-UserReportCard -Payload $payload -DurationText $dur
            return
        }
    }
    [System.Windows.Forms.MessageBox]::Show(
        'No session report yet. Finish a Flight Simulator session first.',
        'MSFS Performance Guard',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
function Add-RoundRect {
    param($Path, [single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    if ($R -lt 0.5) {
        $Path.AddRectangle((New-Object System.Drawing.RectangleF $X, $Y, $W, $H))
        return
    }
    if ($R * 2 -gt $W) { $R = $W / 2 }
    if ($R * 2 -gt $H) { $R = $H / 2 }
    $d = $R * 2
    $Path.AddArc($X, $Y, $d, $d, 180, 90)
    $Path.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $Path.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $Path.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $Path.CloseFigure()
}

function New-GuardBitmap {
    param(
        [int]$Size,
        [System.Drawing.Color]$Accent
    )
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $bmp.SetResolution(96, 96)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = [math]::Max(0.5, $Size * 0.04)
    $body = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundRect $body $pad $pad ($Size - 2 * $pad) ($Size - 2 * $pad) ([math]::Max(2, $Size * 0.22))
    $navy = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 14, 22, 36))
    $g.FillPath($navy, $body)

    $ring = New-Object System.Drawing.Pen $Accent, ([math]::Max(1.2, $Size * 0.08))
    $ring.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
    $g.DrawPath($ring, $body)

    # Top-down jet: nose up, swept wings. Coordinates are 0-1 inside the badge.
    $s = [single]$Size
    $pts = @(
        (New-Object System.Drawing.PointF ($s * 0.50), ($s * 0.16)),
        (New-Object System.Drawing.PointF ($s * 0.58), ($s * 0.34)),
        (New-Object System.Drawing.PointF ($s * 0.88), ($s * 0.50)),
        (New-Object System.Drawing.PointF ($s * 0.78), ($s * 0.58)),
        (New-Object System.Drawing.PointF ($s * 0.57), ($s * 0.50)),
        (New-Object System.Drawing.PointF ($s * 0.56), ($s * 0.64)),
        (New-Object System.Drawing.PointF ($s * 0.70), ($s * 0.80)),
        (New-Object System.Drawing.PointF ($s * 0.50), ($s * 0.70)),
        (New-Object System.Drawing.PointF ($s * 0.30), ($s * 0.80)),
        (New-Object System.Drawing.PointF ($s * 0.44), ($s * 0.64)),
        (New-Object System.Drawing.PointF ($s * 0.43), ($s * 0.50)),
        (New-Object System.Drawing.PointF ($s * 0.22), ($s * 0.58)),
        (New-Object System.Drawing.PointF ($s * 0.12), ($s * 0.50)),
        (New-Object System.Drawing.PointF ($s * 0.42), ($s * 0.34))
    )
    $plane = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 126, 214, 255))
    $g.FillPolygon($plane, $pts)

    # Status lamp so idle / ok / warn stay obvious at 16px.
    $lamp = [math]::Max(3, [int]($Size * 0.22))
    $lx = $Size - $lamp - [int]($Size * 0.10)
    $ly = $Size - $lamp - [int]($Size * 0.10)
    $g.FillEllipse($navy, ($lx - 1), ($ly - 1), ($lamp + 2), ($lamp + 2))
    $accentBrush = New-Object System.Drawing.SolidBrush $Accent
    $g.FillEllipse($accentBrush, $lx, $ly, $lamp, $lamp)

    $accentBrush.Dispose()
    $plane.Dispose()
    $ring.Dispose()
    $navy.Dispose()
    $body.Dispose()
    $g.Dispose()
    return $bmp
}

function Save-PngIcon {
    param(
        [string]$Path,
        [System.Drawing.Bitmap[]]$Bitmaps
    )
    $streams = New-Object System.Collections.Generic.List[System.IO.MemoryStream]
    foreach ($b in $Bitmaps) {
        $ms = New-Object System.IO.MemoryStream
        $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        [void]$streams.Add($ms)
    }
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$streams.Count)
    $offset = 6 + (16 * $streams.Count)
    for ($i = 0; $i -lt $streams.Count; $i++) {
        $b = $Bitmaps[$i]
        $len = [int]$streams[$i].Length
        $w = 0
        $h = 0
        if ($b.Width -lt 256) { $w = $b.Width }
        if ($b.Height -lt 256) { $h = $b.Height }
        $bw.Write([byte]$w)
        $bw.Write([byte]$h)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$len)
        $bw.Write([uint32]$offset)
        $offset += $len
    }
    foreach ($ms in $streams) {
        $bw.Write($ms.ToArray())
        $ms.Dispose()
    }
    $bw.Flush()
    $fs.Dispose()
}

function Get-GuardIcon {
    param([string]$Kind)
    $dir = Join-Path $script:Root 'Icons'
    $path = Join-Path $dir ('guard-{0}.ico' -f $Kind)
    if (Test-Path -LiteralPath $path) {
        return New-Object System.Drawing.Icon $path
    }
    $color = $script:C.Muted
    if ($Kind -eq 'ok') { $color = $script:C.Ok }
    if ($Kind -eq 'warn') { $color = $script:C.Warn }
    $bmp = New-GuardBitmap 32 $color
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

function Initialize-GuardIcons {
    $dir = Join-Path $script:Root 'Icons'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $sizes = @(16, 20, 24, 32, 48, 64, 256)
    $kinds = @{
        idle = $script:C.Accent
        ok   = $script:C.Ok
        warn = $script:C.Warn
    }
    foreach ($kind in $kinds.Keys) {
        $bitmaps = foreach ($sz in $sizes) { New-GuardBitmap $sz $kinds[$kind] }
        $ico = Join-Path $dir ('guard-{0}.ico' -f $kind)
        Save-PngIcon -Path $ico -Bitmaps $bitmaps
        if ($kind -eq 'idle') {
            $preview = Join-Path $dir 'guard-preview.png'
            $bitmaps[-1].Save($preview, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        foreach ($b in $bitmaps) { $b.Dispose() }
    }
}

function Show-TrayIconOnTaskbar {
    $root = 'HKCU:\Control Panel\NotifyIconSettings'
    if (-not (Test-Path -LiteralPath $root)) { return }
    Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
            $exe = [string]$p.ExecutablePath
            if ($exe -and ($exe -like '*powershell.exe' -or $exe -like '*pwsh.exe' -or $exe -like '*MSFSGuard*')) {
                Set-ItemProperty -LiteralPath $_.PSPath -Name IsPromoted -Value 1 -Type DWord -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

function New-FlatButton {
    param(
        [string]$Text,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [System.Drawing.Color]$Back,
        [System.Drawing.Color]$Fore
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point $X, $Y
    $b.Size = New-Object System.Drawing.Size $W, $H
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.TabStop = $false
    $b.UseVisualStyleBackColor = $false
    return $b
}

function Place-Toast {
    if (-not $script:Toast) { return }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:Toast.Left = $wa.Right - $script:Toast.Width - 18
    $script:Toast.Top = $wa.Bottom - $script:Toast.Height - 18
    try { $script:Toast.RoundCorners(18) } catch { }
}

function Hide-Toast {
    if ($script:Toast) {
        $script:Toast.Hide()
        $script:ToastVisible = $false
    }
}

function Build-ToastRows {
    param($Offenders)
    $script:ToastBody.Controls.Clear()
    $y = 0
    $width = 364
    foreach ($o in $Offenders) {
        $card = New-Object System.Windows.Forms.Panel
        $card.Location = New-Object System.Drawing.Point 0, $y
        $card.Size = New-Object System.Drawing.Size $width, 78
        $card.BackColor = $script:C.Panel

        $title = New-Object System.Windows.Forms.Label
        $title.Text = $o.Label
        $title.ForeColor = $script:C.Text
        $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
        $title.Location = New-Object System.Drawing.Point 10, 8
        $title.AutoSize = $true
        $card.Controls.Add($title)

        $meta = New-Object System.Windows.Forms.Label
        $countBit = if ($o.Count -gt 1) { '  |  {0} processes' -f $o.Count } else { '' }
        $meta.Text = $o.Reason + $countBit
        $meta.ForeColor = $script:C.Muted
        $meta.Font = New-Object System.Drawing.Font('Segoe UI', 8)
        $meta.Location = New-Object System.Drawing.Point 10, 28
        $meta.Size = New-Object System.Drawing.Size 340, 16
        $card.Controls.Add($meta)

        $n = $o.Name
        $btnSleep = New-FlatButton 'Sleep' 10 48 78 22 $script:C.Sleep $script:C.Text
        $btnSleep.Add_Click({
                $c = Invoke-SleepNamed $n
                if ($c -le 0) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Could not sleep $(Get-FriendlyName $n). Windows blocked it.`r`n`r`nDouble-click Install.bat so MSFS Guard runs as administrator, then try Sleep again. Or use Close.",
                        'MSFS Performance Guard',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                }
                Hide-Toast
                Rebuild-Dashboard
            }.GetNewClosure())
        $card.Controls.Add($btnSleep)

        $btnClose = New-FlatButton 'Close' 94 48 78 22 $script:C.Close $script:C.Text
        $btnClose.Add_Click({
                $label = Get-FriendlyName $n
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    "Close $label now? Unsaved work in that program may be lost.`r`n`r`nSleep is safer if you just want it out of the way until MSFS exits.",
                    'Close this program?',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
                    if (-not (Invoke-CloseNamed $n)) {
                        [System.Windows.Forms.MessageBox]::Show(
                            "Could not close $label. Windows blocked it.`r`n`r`nDouble-click Install.bat so MSFS Guard runs as administrator, then try again.",
                            'MSFS Performance Guard',
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Warning
                        ) | Out-Null
                    }
                    Hide-Toast
                    Rebuild-Dashboard
                }
            }.GetNewClosure())
        $card.Controls.Add($btnClose)

        $btnIgnore = New-FlatButton 'Ignore' 178 48 78 22 $script:C.Btn $script:C.Text
        $btnIgnore.Add_Click({
                [void]$script:SessionIgnore.Add($n)
                Write-Log "Ignored $n for this MSFS session" 'INFO'
                Add-SessionAction -Type 'ignore' -Name $n -Ok $true
                Hide-Toast
            }.GetNewClosure())
        $card.Controls.Add($btnIgnore)

        $btnNever = New-FlatButton 'Never' 262 48 78 22 $script:C.Btn $script:C.Muted
        $btnNever.Add_Click({
                $list = New-Object System.Collections.Generic.List[string]
                foreach ($x in @($script:Config.UserAllowlist)) { if ($x) { [void]$list.Add($x) } }
                if (-not ($list -contains $n)) { [void]$list.Add($n) }
                $script:Config.UserAllowlist = $list.ToArray()
                [void]$script:Allow.Add($n)
                Save-UserAllowlist
                Write-Log "Added $n to UserAllowlist" 'OK'
                Add-SessionAction -Type 'never' -Name $n -Ok $true
                Hide-Toast
            }.GetNewClosure())
        $card.Controls.Add($btnNever)

        $script:ToastBody.Controls.Add($card)
        $y += 84
    }
    $script:ToastBody.Height = $y
    $script:Toast.Height = 118 + $y + 52
    $script:ToastFooter.Top = 118 + $y
}

function Show-CompanionInfo {
    param($Groups)
    if (-not $script:Notify -or $script:Exiting) { return }
    if (-not $script:CompanionWarned) {
        $script:CompanionWarned = New-IgnoreSet @()
    }
    $cores = [Math]::Max(1, [Environment]::ProcessorCount)
    $scale = 8.0 / $cores
    $bar = [Math]::Max(4.0, [double]$script:Config.CpuPercentThreshold * $scale * 2.0)
    foreach ($g in @($Groups)) {
        if (-not $script:Companions.Contains($g.Name)) { continue }
        if ($script:CompanionWarned.Contains($g.Name)) { continue }
        $memMB = [int]($g.Ws / 1MB)
        if ($g.CpuPct -lt $bar -and $memMB -lt 1500) { continue }
        [void]$script:CompanionWarned.Add($g.Name)
        $label = Get-FriendlyName $g.Name
        Write-Log ("Companion {0} is expensive ({1:n1}% CPU, {2} MB) - Grok only" -f $g.Name, $g.CpuPct, $memMB) 'INFO'
        if (Test-ShowSuggestionOverlay) {
            try {
                $script:Notify.ShowBalloonTip(
                    5000,
                    'Sim add-on is busy',
                    ('{0} is using {1:n0}% CPU / {2:n1} GB. Left running because it is a Flight Simulator add-on.' -f $label, $g.CpuPct, ($memMB / 1024.0)),
                    [System.Windows.Forms.ToolTipIcon]::Info
                )
            } catch { }
        }
        return
    }
}

function Show-Toast {
    param($Offenders, [string]$Header)
    if (-not $Offenders -or $Offenders.Count -eq 0) { return }
    $script:LastOffenders = @($Offenders)
    if ($script:ToastTitle) {
        if ($script:LastLimit -eq 'CPU') {
            $script:ToastTitle.Text = 'Limited by MainThread'
        } else {
            $script:ToastTitle.Text = 'MSFS Performance Guard'
        }
    }
    $script:ToastSub.Text = $Header
    Build-ToastRows $Offenders
    $script:ToastStripe.BackColor = $script:C.Warn
    Place-Toast
    $script:Toast.Show()
    $script:ToastVisible = $true
    try {
        $script:Notify.ShowBalloonTip(
            4000,
            'MSFS Performance Guard',
            ('{0} may be hurting Flight Simulator. Click the tray icon to review.' -f $Offenders[0].Label),
            [System.Windows.Forms.ToolTipIcon]::Warning
        )
    } catch { }
}

function Ensure-Dashboard {
    if ($script:Dash) { return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'MSFS Performance Guard'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $f.MaximizeBox = $false
    $f.MinimizeBox = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.Size = New-Object System.Drawing.Size 460, 620
    $f.BackColor = $script:C.Bg
    $f.ForeColor = $script:C.Text
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.ShowInTaskbar = $true
    if ($script:IconIdle) { $f.Icon = $script:IconIdle }
    $f.Add_FormClosing({
            if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
                $_.Cancel = $true
                $script:Dash.Hide()
            }
        })

    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.BackColor = $script:C.Accent
    $stripe.Dock = [System.Windows.Forms.DockStyle]::Left
    $stripe.Width = 4
    $f.Controls.Add($stripe)
    $script:DashStripe = $stripe

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'MSFS Performance Guard'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $title.ForeColor = $script:C.Text
    $title.Location = New-Object System.Drawing.Point 20, 14
    $title.AutoSize = $true
    $f.Controls.Add($title)

    $st = New-Object System.Windows.Forms.Label
    $st.Name = 'Status'
    $st.ForeColor = $script:C.Muted
    $st.Location = New-Object System.Drawing.Point 20, 40
    $st.Size = New-Object System.Drawing.Size 410, 36
    $f.Controls.Add($st)
    $script:DashStatus = $st

    $hdr1 = New-Object System.Windows.Forms.Label
    $hdr1.Text = 'Top consumers'
    $hdr1.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $hdr1.ForeColor = $script:C.Text
    $hdr1.Location = New-Object System.Drawing.Point 20, 82
    $hdr1.AutoSize = $true
    $f.Controls.Add($hdr1)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point 20, 104
    $list.Size = New-Object System.Drawing.Size 404, 200
    $list.BackColor = $script:C.Panel
    $list.ForeColor = $script:C.Text
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $list.Font = New-Object System.Drawing.Font('Consolas', 9)
    $f.Controls.Add($list)
    $script:DashList = $list

    $hdr2 = New-Object System.Windows.Forms.Label
    $hdr2.Text = 'Slept programs (frozen until you resume or MSFS exits)'
    $hdr2.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $hdr2.ForeColor = $script:C.Text
    $hdr2.Location = New-Object System.Drawing.Point 20, 316
    $hdr2.AutoSize = $true
    $f.Controls.Add($hdr2)

    $slept = New-Object System.Windows.Forms.ListBox
    $slept.Location = New-Object System.Drawing.Point 20, 338
    $slept.Size = New-Object System.Drawing.Size 404, 130
    $slept.BackColor = $script:C.Panel
    $slept.ForeColor = $script:C.Text
    $slept.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $slept.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.Controls.Add($slept)
    $script:DashSlept = $slept

    $btnResumeOne = New-FlatButton 'Resume selected' 20 478 130 30 $script:C.Sleep $script:C.Text
    $btnResumeOne.Add_Click({
            if ($script:DashSlept.SelectedItem) {
                $raw = [string]$script:DashSlept.SelectedItem
                $nm = ($raw -split '  \|  ')[0]
                # selected shows friendly name; map back to process name
                $key = $null
                foreach ($k in @($script:Slept.Keys)) {
                    if ($k -eq $nm -or (Get-FriendlyName $k) -eq $nm) { $key = $k; break }
                }
                if ($key) { [void](Invoke-ResumeNamed $key); Rebuild-Dashboard }
            }
        })
    $f.Controls.Add($btnResumeOne)

    $btnResumeAll = New-FlatButton 'Resume all' 158 478 110 30 $script:C.Ok ([System.Drawing.Color]::FromArgb(20, 28, 24))
    $btnResumeAll.Add_Click({ [void](Invoke-ResumeAll); Rebuild-Dashboard })
    $f.Controls.Add($btnResumeAll)

    $btnPause = New-FlatButton 'Pause watch' 276 478 148 30 $script:C.Btn $script:C.Text
    $btnPause.Add_Click({
            $script:Paused = -not $script:Paused
            $btnPause.Text = $(if ($script:Paused) { 'Resume watch' } else { 'Pause watch' })
            Update-Tray
        })
    $f.Controls.Add($btnPause)
    $script:DashPause = $btnPause

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Sleep freezes a program (reversible). Close ends it. Never = do not suggest this program again. Edit Config.json for thresholds and allowlists.'
    $hint.ForeColor = $script:C.Muted
    $hint.Location = New-Object System.Drawing.Point 20, 518
    $hint.Size = New-Object System.Drawing.Size 404, 48
    $f.Controls.Add($hint)

    $script:Dash = $f
}

function Rebuild-Dashboard {
    if (-not $script:Dash -or -not $script:Dash.Visible) { return }
    $msfs = if ($script:MsfsRunning) { $script:MsfsLabel } else { 'Flight Simulator is not running' }
    $ram = if ($script:LastFreeRam -gt 0) { '{0:n1} GB RAM free' -f ($script:LastFreeRam / 1024.0) } else { '' }
    $pause = if ($script:Paused) { 'Watching is paused.' } else { 'Watching in the background.' }
    $last = ''
    if ($script:LastSessionGrade) {
        if ($script:LastSessionFps -gt 0) {
            $last = '   |   last session {0}  {1} FPS' -f $script:LastSessionGrade, [int]$script:LastSessionFps
        } else {
            $last = '   |   last session {0}' -f $script:LastSessionGrade
        }
    }
    $hw = ''
    if ($script:MsfsRunning) {
        if ($null -ne $script:LastFps) { $hw = '   |   {0} FPS' -f $script:LastFps }
        if ($script:LastLimit -and $script:LastLimit -ne 'None') {
            $hw += '   |   {0}' -f (Get-DevLimitLabel $script:LastLimit)
        }
    }
    $script:DashStatus.Text = "$msfs`r`n$ram   |   $pause$last$hw"
    $script:DashStripe.BackColor = if ($script:MsfsRunning) {
        if ($script:Slept.Count -gt 0 -or $script:ToastVisible) { $script:C.Warn } else { $script:C.Ok }
    } else { $script:C.Accent }

    $script:DashList.Items.Clear()
    foreach ($row in @($script:LastTop)) {
        [void]$script:DashList.Items.Add($row)
    }
    $script:DashSlept.Items.Clear()
    if ($script:Slept.Count -eq 0) {
        [void]$script:DashSlept.Items.Add('(none)')
    } else {
        foreach ($k in $script:Slept.Keys) {
            $n = $script:Slept[$k].Pids.Count
            [void]$script:DashSlept.Items.Add(('{0}  |  {1} frozen' -f (Get-FriendlyName $k), $n))
        }
    }
    if ($script:DashPause) {
        $script:DashPause.Text = $(if ($script:Paused) { 'Resume watch' } else { 'Pause watch' })
    }
}

function Show-Dashboard {
    Ensure-Dashboard
    Rebuild-Dashboard
    $script:Dash.Show()
    $script:Dash.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:Dash.Activate()
}

function Place-Badge {
    if (-not $script:Badge) { return }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:Badge.Left = $wa.Left + [int](($wa.Width - $script:Badge.Width) / 2)
    $script:Badge.Top = $wa.Bottom - $script:Badge.Height - 18
}

function Update-Badge {
    if (-not $script:Badge -or -not $script:BadgeStatus) { return }
    if ($script:Paused) {
        $script:BadgeStatus.Text = 'paused'
        $script:BadgeStripe.BackColor = $script:C.Muted
    } elseif ($script:MsfsRunning) {
        $script:BadgeStatus.Text = $(if ($null -ne $script:LastFps) { '{0} FPS' -f $script:LastFps } else { 'sim running' })
        $script:BadgeStripe.BackColor = $(if ($script:ToastVisible -or $script:Slept.Count -gt 0) { $script:C.Warn } else { $script:C.Ok })
    } else {
        $script:BadgeStatus.Text = 'watching'
        $script:BadgeStripe.BackColor = $script:C.Accent
    }
}

function Show-CornerBadge {
    if ($script:Badge) {
        $script:Badge.Show()
        Place-Badge
        Update-Badge
        return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'MSFS Guard'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $true
    $f.TopMost = $true
    $f.BackColor = $script:C.Bg
    $f.Size = New-Object System.Drawing.Size 228, 72
    $f.MinimizeBox = $false
    $f.MaximizeBox = $false
    if ($script:IconIdle) { $f.Icon = $script:IconIdle }
    $f.Add_FormClosing({
            if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
                $_.Cancel = $true
                $script:Badge.Hide()
            }
        })
    $f.Add_Click({ Show-Dashboard })

    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.BackColor = $script:C.Accent
    $stripe.Dock = [System.Windows.Forms.DockStyle]::Left
    $stripe.Width = 6
    $f.Controls.Add($stripe)
    $script:BadgeStripe = $stripe

    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Size = New-Object System.Drawing.Size 48, 48
    $pic.Location = New-Object System.Drawing.Point 16, 12
    $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
    $pic.Image = (New-GuardBitmap 48 $script:C.Accent)
    $pic.Cursor = [System.Windows.Forms.Cursors]::Hand
    $pic.Add_Click({ Show-Dashboard })
    $f.Controls.Add($pic)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'MSFS Guard'
    $title.ForeColor = $script:C.Text
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $title.Location = New-Object System.Drawing.Point 72, 12
    $title.AutoSize = $true
    $title.Cursor = [System.Windows.Forms.Cursors]::Hand
    $title.Add_Click({ Show-Dashboard })
    $f.Controls.Add($title)

    $st = New-Object System.Windows.Forms.Label
    $st.Text = 'watching'
    $st.ForeColor = $script:C.Muted
    $st.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $st.Location = New-Object System.Drawing.Point 72, 36
    $st.AutoSize = $true
    $st.Cursor = [System.Windows.Forms.Cursors]::Hand
    $st.Add_Click({ Show-Dashboard })
    $f.Controls.Add($st)
    $script:BadgeStatus = $st

    $x = New-Object System.Windows.Forms.Label
    $x.Text = 'x'
    $x.ForeColor = $script:C.Muted
    $x.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $x.Location = New-Object System.Drawing.Point 204, 4
    $x.AutoSize = $true
    $x.Cursor = [System.Windows.Forms.Cursors]::Hand
    $x.Add_Click({ $script:Badge.Hide() })
    $f.Controls.Add($x)

    $script:Badge = $f
    Place-Badge
    $f.Show()
    Update-Badge
    Write-Log 'Corner badge shown (taskbar + bottom-right)' 'OK'
}

function Update-Tray {
    if ($script:Exiting) { return }
    if (-not $script:Notify) { return }
    $slept = $script:Slept.Count
    $icon = $script:IconIdle
    $tip = 'MSFS Guard - waiting for Flight Simulator'
    if ($script:Paused) {
        $icon = $script:IconIdle
        $tip = 'MSFS Guard - paused'
    } elseif ($script:MsfsRunning) {
        $fpsTip = ''
        if ($null -ne $script:LastFps) {
            $fpsTip = '{0} FPS' -f [double]$script:LastFps
            if ($script:LastLimit -and $script:LastLimit -ne 'None') {
                $fpsTip = '{0}, {1}' -f $fpsTip, [string](Get-DevLimitLabel $script:LastLimit)
            }
        }
        if ($slept -gt 0 -or $script:ToastVisible) {
            $icon = $script:IconWarn
            $tip = $(if ($fpsTip) { "MSFS Guard - $fpsTip" } else { "MSFS Guard - sim running, $slept slept" })
        } else {
            $icon = $script:IconOk
            $tip = $(if ($fpsTip) { "MSFS Guard - $fpsTip" } else { 'MSFS Guard - sim running, clean' })
        }
    }
    try {
        if ($icon) { $script:Notify.Icon = $icon }
        $script:Notify.Text = $tip
    } catch {
        return
    }
    try {
        $script:MenuMsfs.Text = $(if ($script:MsfsRunning) {
                if ($null -ne $script:LastFps) { 'Flight Simulator: {0} FPS' -f [double]$script:LastFps } else { 'Flight Simulator: running' }
            } else { 'Flight Simulator: not running' })
        $script:MenuSlept.Text = "Slept programs: $slept"
        $script:MenuPause.Text = $(if ($script:Paused) { 'Resume watching' } else { 'Pause watching' })
    } catch { }
    Update-Badge
}

function Close-Guard {
    if ($script:Exiting) { return }
    $script:Exiting = $true
    Write-Log 'Shutting down - resuming any slept programs' 'INFO'
    try { if ($script:Timer) { $script:Timer.Stop() } } catch { }
    try {
        if ($script:Session) {
            $out = if ($script:MsfsRunning) { 'interrupted' } else { 'completed' }
            Complete-FlightSession -Outcome $out
        }
    } catch { }
    try { [void](Invoke-ResumeAll) } catch { }
    try {
        if ($script:Notify) {
            $script:Notify.Visible = $false
            $script:Notify.Dispose()
        }
    } catch { }
    $script:Notify = $null
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}

# -----------------------------------------------------------------------------
# Monitor tick
# -----------------------------------------------------------------------------
function Invoke-MonitorTick {
    if ($script:Exiting) { return }
    if ($script:Busy) { return }
    $script:Busy = $true
    $tickWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($script:StopEvent.WaitOne(0)) { Close-Guard; return }
        if ($script:ShowEvent.WaitOne(0)) { Show-Dashboard }

        $now = Get-Date
        if ($now -gt $script:NextPidRefresh) {
            Refresh-GuardPids
            $script:NextPidRefresh = $now.AddSeconds(20)
        }

        $snap = Get-Snapshot
        $msfs = Get-MsfsInfo
        $wasRunning = $script:MsfsRunning
        $script:MsfsRunning = [bool]$msfs.Running

        if ($script:MsfsRunning) {
            $script:MsfsLabel = '{0}  |  {1:n1} GB RAM' -f $msfs.Name, ($msfs.Ws / 1GB)
        }

        if ($script:MsfsRunning -and -not $wasRunning) {
            Write-Log "Flight Simulator detected ($($msfs.Name))" 'OK'
            $script:SessionIgnore = New-IgnoreSet @()
            $script:Strikes = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
            $script:CompanionWarned = New-IgnoreSet @()
            $script:CooldownUntil = [datetime]::MinValue
            if ($script:Session) { Complete-FlightSession -Outcome 'interrupted' }
            New-FlightSession -MsfsName $msfs.Name
            try {
                $script:Notify.ShowBalloonTip(2500, 'MSFS Performance Guard', 'Flight Simulator is running. Watching for resource hogs.', [System.Windows.Forms.ToolTipIcon]::Info)
            } catch { }
        }

        if (-not $script:MsfsRunning -and $wasRunning) {
            Write-Log 'Flight Simulator exited' 'INFO'
            Hide-Toast
            Complete-FlightSession -Outcome 'completed'
            if ($script:Exiting) { return }
            if ($script:Config.AutoResumeWhenMsfsExits -and $script:Slept.Count -gt 0) {
                [void](Invoke-ResumeAll)
            }
            $script:SessionIgnore = New-IgnoreSet @()
            $script:Strikes = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
            $script:CompanionWarned = New-IgnoreSet @()
        }

        $free = Get-FreeRamMB
        $script:LastFreeRam = $free

        $script:TickIndex++
        $ioNow = $script:PrevIo
        if (($script:TickIndex % 8) -eq 0) {
            $ioPids = New-Object System.Collections.Generic.List[int]
            foreach ($id in $snap.Items.Keys) {
                if ($script:DiskWatchSet.Contains($snap.Items[$id].Name)) { [void]$ioPids.Add([int]$id) }
            }
            if ($ioPids.Count -gt 0) { $ioNow = Get-IoBytes $ioPids.ToArray() }
        }

        $hadPrev = [bool]$script:PrevSnap
        $groups = @()
        if ($hadPrev) {
            $groups = @(Compare-Snapshots $script:PrevSnap $snap $script:PrevIo $ioNow)
            $top = $groups | Sort-Object { $_.CpuPct } -Descending | Select-Object -First 8
            $script:LastTop = @(
                foreach ($g in $top) {
                    ('{0,-18} {1,5:n1}%  {2,5:n1} GB' -f $g.Name, $g.CpuPct, ($g.Ws / 1GB))
                }
            )

            $msfsCpu = 0.0
            if ($script:MsfsRunning -and $script:PrevMsfsCpu -ge 0) {
                $wall = ($snap.At - $script:PrevSnap.At).TotalSeconds
                if ($wall -lt 0.2) { $wall = 0.2 }
                $cores = [Math]::Max(1, [Environment]::ProcessorCount)
                $msfsCpu = (($msfs.CpuSec - $script:PrevMsfsCpu) / $wall) * 100.0 / $cores
                if ($msfsCpu -lt 0) { $msfsCpu = 0 }
                $script:MsfsLabel = '{0}  |  {1:n0}% CPU  |  {2:n1} GB RAM' -f $msfs.Name, $msfsCpu, ($msfs.Ws / 1GB)
            }
            if ($script:Session -and $script:MsfsRunning) {
                Update-SessionSample -Msfs $msfs -MsfsCpu $msfsCpu -FreeRamMB $free -Groups $groups
                try {
                    $pids = @()
                    foreach ($id in @($msfs.Pids)) { try { $pids += [int]$id } catch { } }
                    $hw = Get-HardwareSample -MsfsPids $pids
                    Update-HardwareSession -Hw $hw -MsfsCpu ([double]$msfsCpu) -FreeRamMB ([int]$free)
                    $script:LastLimit = [string]$script:Session.LastLimit
                    if (($script:TickIndex % 2) -eq 0) {
                        $live = Get-LiveFps
                        if ($null -ne $live) { $script:LastFps = [double]$live }
                    }
                    $fpsBit = ''
                    if ($null -ne $script:LastFps) { $fpsBit = '  |  {0} FPS' -f [double]$script:LastFps }
                    $limBit = ''
                    if ($script:LastLimit -and $script:LastLimit -ne 'None') {
                        $limBit = '  |  {0}' -f [string](Get-DevLimitLabel $script:LastLimit)
                    }
                    $script:MsfsLabel = '{0}  |  {1:n0}% CPU  |  {2:n1} GB RAM{3}{4}' -f [string]$msfs.Name, [double]$msfsCpu, [double]($msfs.Ws / 1GB), [string]$fpsBit, [string]$limBit
                } catch {
                    Write-Log ("Hardware sample failed: {0} :: {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) 'WARN'
                }
            }
        }

        $script:PrevSnap = $snap
        $script:PrevIo = $ioNow
        $script:PrevMsfsCpu = $msfs.CpuSec

        Write-RuntimeStatus
        if ($script:Exiting) { return }
        Update-Tray
        Rebuild-Dashboard

        if (-not $hadPrev) { return }
        if ($script:Paused -or -not $script:MsfsRunning) { return }
        if ($now -lt $script:CooldownUntil) { return }
        if ($script:ToastVisible) { return }

        $offenders = New-Object System.Collections.Generic.List[object]
        foreach ($g in $groups) {
            $hit = Test-IsOffender $g $free
            if ($hit) {
                if (-not $script:Strikes.ContainsKey($g.Name)) { $script:Strikes[$g.Name] = 0 }
                $script:Strikes[$g.Name] = [int]$script:Strikes[$g.Name] + 1
                if ($script:Strikes[$g.Name] -ge [int]$script:Config.PersistSamples) {
                    [void]$offenders.Add($hit)
                }
            } else {
                $script:Strikes[$g.Name] = 0
                Add-NearMiss $g $free
            }
        }

        if ($offenders.Count -eq 0) {
            Show-CompanionInfo $groups
            return
        }

        $cpuBound = ($script:LastLimit -eq 'CPU')
        if ($cpuBound) {
            $ranked = @($offenders | Sort-Object CpuPct -Descending | Select-Object -First ([int]$script:Config.MaxSuggestions))
        } else {
            $ranked = @($offenders | Sort-Object Score -Descending | Select-Object -First ([int]$script:Config.MaxSuggestions))
        }
        $ranked = @($ranked | Where-Object { Test-IsSafeToSuggest $_.Name })
        if ($ranked.Count -eq 0) {
            Write-Log ('Held back {0} offender(s) (companion/protected/MSFS-related)' -f $offenders.Count) 'INFO'
            return
        }

        if ([bool]$script:Config.AutoSleepKnownHogs) {
            foreach ($o in $ranked) {
                if ($o.KnownHog) {
                    $c = Invoke-SleepNamed $o.Name
                    if ($c -gt 0) {
                        if ($script:Session -and $script:Session.Actions.Count -gt 0) {
                            $script:Session.Actions[$script:Session.Actions.Count - 1].Type = 'autosleep'
                            $script:Session.AutoSleep++
                        } else {
                            Add-SessionAction -Type 'autosleep' -Name $o.Name -Ok $true
                        }
                    }
                    Write-Log "Auto-slept $($o.Name) ($($o.Reason))" 'OK'
                }
            }
            $ranked = @($ranked | Where-Object { -not $_.KnownHog })
            if ($ranked.Count -eq 0) { return }
        }

        $ramBit = if ($free -gt 0) { '  |  {0:n1} GB RAM free' -f ($free / 1024.0) } else { '' }
        $header = $script:MsfsLabel + $ramBit
        if (Test-ShowSuggestionOverlay) {
            Show-Toast $ranked $header
            Add-SessionSuggestionShown $ranked
            Write-Log ('Overlay: {0} ({1})' -f $ranked[0].Label, $ranked[0].Reason) 'INFO'
        } else {
            Add-SessionSuggestionShown $ranked -Shown $false
            Write-Log ('Saved for Grok (not shown): {0} ({1})' -f $ranked[0].Label, $ranked[0].Reason) 'INFO'
        }
    } catch {
        Write-Log ("Monitor tick failed: {0} :: {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) 'ERR'
        if ($script:Session) { $script:Session.TickErrors++ }
    } finally {
        try {
            $tickWatch.Stop()
            if ($script:Session) {
                $ms = [double]$tickWatch.Elapsed.TotalMilliseconds
                $script:Session.TickMsSum += $ms
                if ($ms -gt $script:Session.TickMsMax) { $script:Session.TickMsMax = $ms }
            }
        } catch { }
        $script:Busy = $false
    }
}

# -----------------------------------------------------------------------------
# Startup
# -----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

$script:Config = Import-Config
$script:Protected = New-IgnoreSet $script:Config.ProtectedNames
$script:Companions = New-IgnoreSet $script:Config.CompanionAllowlist
$script:Hogs = New-IgnoreSet $script:Config.KnownHogs
$script:Allow = New-IgnoreSet $script:Config.UserAllowlist
$script:DoNotSleep = New-IgnoreSet @(
    'msedgewebview2', 'XboxPcApp', 'GameBar', 'AMDRSServ',
    'Navigraph Charts', 'Couatl64_MSFS2024', '737MAX_Plugin',
    'MSFS_AutoFPS', 'MDClient', 'CP MSFS Bridge', 'powershell', 'pwsh',
    'PresentMon-x64', 'PresentMon', 'MsfsFrameProbe',
    'QtWebEngineProcess', 'QmlRenderer'
)
$script:SafetyCache = $null
$script:Hosted = Test-HostPresent
$script:MsfsNames = New-IgnoreSet $script:Config.MsfsProcessNames
$script:DiskWatchSet = New-IgnoreSet $script:DiskWatch
$script:SessionIgnore = New-IgnoreSet @()
$script:Slept = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
$script:Strikes = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
$script:GuardPids = New-Object 'System.Collections.Generic.HashSet[int]'
[void]$script:GuardPids.Add([int]$PID)
$script:Paused = $false
$script:Busy = $false
$script:Exiting = $false
$script:IsAdmin = Test-IsAdmin
$script:TickIndex = 0
$script:FreeRamCached = 0
$script:FreeRamCachedAt = $null
$script:MsfsRunning = $false
$script:MsfsLabel = 'Flight Simulator is not running'
$script:LastFreeRam = 0
$script:LastTop = @()
$script:LastOffenders = @()
$script:PrevSnap = $null
$script:PrevIo = @{}
$script:PrevMsfsCpu = -1.0
$script:ToastVisible = $false
$script:CooldownUntil = [datetime]::MinValue
$script:NextPidRefresh = [datetime]::MinValue
$script:WelcomeShown = $false
$script:IconHintShown = $false
$script:Session = $null
$script:LastReportMd = $null
$script:LastReportJson = $null
$script:LastSessionGrade = $null
$script:LastSessionScore = 0
$script:LastSessionFps = 0
$script:HwReady = $false
$script:PresentMonExe = $null
$script:PresentMonPid = $null
$script:PresentMonFile = $null
$script:PmMsCol = $null
$script:LastGpu = $null
$script:GpuFailLogged = $false
$script:GpuEngineCounters = $null
$script:GpuVramCounters = $null
$script:GpuSyncKey = ''
$script:CompanionWarned = New-IgnoreSet @()
$script:PcNet = $null
$script:LastFps = $null
$script:LastLimit = 'None'
$script:LastSimSpeed = 1.0
$script:FpsSource = $null
$script:FrameProbeExe = $null
$script:SimConnectPid = $null
$script:SimConnectJson = $null
$script:SimConnectCsv = $null
$script:Badge = $null
$script:BadgeStatus = $null
$script:BadgeStripe = $null
$latestMd = Join-Path $script:LogDir 'latest-session.md'
if (Test-Path -LiteralPath $latestMd) { $script:LastReportMd = $latestMd }
$latestJson = Join-Path $script:LogDir 'latest-session.json'
if (Test-Path -LiteralPath $latestJson) {
    $script:LastReportJson = $latestJson
    $prev = Read-JsonFile $latestJson
    if ($prev -and $prev.Grade) {
        $script:LastSessionGrade = [string]$prev.Grade
        $script:LastSessionScore = [int]$prev.Score
        try { $script:LastSessionFps = [double]$prev.GameplayFpsAvg } catch { }
        if ($script:LastSessionFps -le 0) {
            try { $script:LastSessionFps = [double]$prev.FpsAvg } catch { }
        }
    }
}

if ($ShowLastReport) {
    try { $script:IconOk = Get-GuardIcon 'ok' } catch { }
    Open-LastSessionReport
    exit
}

$state = Import-State
if ($state -and $state.WelcomeShown) { $script:WelcomeShown = $true }
if ($state -and $state.IconHintShown) { $script:IconHintShown = $true }

# Resume leftovers from a previous crash unless MSFS is already in a session
$existingMsfs = @{ Running = $false; Name = $null; CpuSec = 0.0; Ws = [int64]0; Pids = @() }
if (-not $WriteTestReport) {
    $existingMsfs = Get-MsfsInfo
}
if (-not $WriteTestReport -and $state -and $state.Slept) {
    foreach ($row in @($state.Slept)) {
        $nm = [string]$row.Name
        if (-not $nm) { continue }
        $pids = @($row.Pids)
        if ($existingMsfs.Running) {
            $script:Slept[$nm] = @{ Pids = $pids; At = [string]$row.At }
        } else {
            foreach ($id in $pids) { [void](Resume-Pid ([int]$id)) }
            Write-Log "Resumed leftover sleep on $nm from previous session" 'OK'
        }
    }
}

Initialize-HardwareCounters
Write-Log ('Started (admin={0}, cores={1}, presentmon={2})' -f (Test-IsAdmin), [Environment]::ProcessorCount, [bool]$script:PresentMonExe) 'INFO'

if ($existingMsfs.Running) {
    $script:MsfsRunning = $true
    $script:MsfsLabel = '{0}  |  {1:n1} GB RAM' -f $existingMsfs.Name, ($existingMsfs.Ws / 1GB)
    New-FlightSession -MsfsName $existingMsfs.Name
    Write-Log "Joined an already-running sim session ($($existingMsfs.Name))" 'INFO'
}

if ($WriteTestReport) {
    New-FlightSession -MsfsName 'FlightSimulator2024'
    $script:Session.StartedAt = (Get-Date).AddHours(-1.5)
    $script:Session.Samples = 120
    $script:Session.TickMsSum = 4800
    $script:Session.TickMsMax = 95
    $script:Session.MsfsCpuSum = 2100
    $script:Session.MsfsCpuMax = 28
    $script:Session.MsfsRamSum = 2520
    $script:Session.MsfsRamMax = 22.4
    $script:Session.MsfsRamMin = 18.1
    $script:Session.FreeRamSum = 420000
    $script:Session.FreeRamMin = 1800
    $script:Session.FreeRamMax = 6200
    $script:Session.NonMsfsCpuSum = 480
    $script:Session.RamAtStartMB = 2400
    $script:Session.HwSamples = 80
    $script:Session.GpuSum = 7280
    $script:Session.GpuMax = 98
    $script:Session.VramMaxMB = 14200
    $script:Session.DiskQSum = 40
    $script:Session.DiskQMax = 1.2
    $script:Session.DiskMBpsMax = 22
    $script:Session.NetMBpsSum = 40
    $script:Session.NetMBpsMax = 3.1
    $script:Session.SysCpuSum = 4960
    $script:Session.SysCpuMax = 72
    $script:Session.BnCpu = 12
    $script:Session.BnGpu = 58
    $script:Session.BnRam = 4
    $script:Session.BnDisk = 2
    $script:Session.BnNet = 0
    $script:Session.BnNone = 4
    $script:Session.FpsCount = 900
    $script:Session.FpsAvg = 31.4
    $script:Session.FpsMin = 18.2
    $script:Session.FpsMax = 48.0
    $script:Session.FpsAvgMs = 31.8
    $script:Session.GameplayFpsCount = 720
    $script:Session.GameplayFpsAvg = 31.4
    $script:Session.GameplayFpsMin = 22.1
    $script:Session.GameplayFpsMax = 42.0
    $script:Session.GameplayFpsAvgMs = 31.8
    $script:Session.GameplayKnown = $true
    $script:LastFreeRam = 4100
    Update-SessionPeak -Name 'chrome' -CpuPct 6.2 -MemMB 2100 -DiskMBps 1.2
    $script:Session.Peaks['chrome'].Samples = 80
    $script:Session.Peaks['chrome'].SumCpu = 280
    Update-SessionPeak -Name 'OneDrive' -CpuPct 2.1 -MemMB 420 -DiskMBps 12
    $script:Session.Peaks['OneDrive'].Samples = 40
    $script:Session.Peaks['OneDrive'].SumCpu = 40
    Update-SessionPeak -Name 'MysteryHelper' -CpuPct 4.8 -MemMB 900 -DiskMBps 0
    $script:Session.Peaks['MysteryHelper'].Samples = 30
    $script:Session.Peaks['MysteryHelper'].SumCpu = 90
    Add-SessionSuggestionShown @(@{
            Name = 'chrome'; Label = 'Google Chrome'; Reason = '6% CPU  |  2.1 GB RAM'
            CpuPct = 6.2; MemMB = 2100; KnownHog = $true
        })
    Add-SessionAction -Type 'sleep' -Name 'chrome' -Ok $true -Detail 'demo'
    Complete-FlightSession -Outcome 'completed'
    Write-Host "Wrote test session report to $script:LogDir"
    exit
}

Initialize-GuardIcons
$script:IconIdle = Get-GuardIcon 'idle'
$script:IconOk = Get-GuardIcon 'ok'
$script:IconWarn = Get-GuardIcon 'warn'

# Toast
$script:Toast = New-Object GuardToastForm
$script:Toast.Text = 'MSFS Performance Guard'
$script:Toast.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:Toast.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:Toast.ShowInTaskbar = $false
$script:Toast.TopMost = $true
$script:Toast.BackColor = $script:C.Bg
$script:Toast.Size = New-Object System.Drawing.Size 400, 280
$script:Toast.Opacity = 0.97

$script:ToastStripe = New-Object System.Windows.Forms.Panel
$script:ToastStripe.BackColor = $script:C.Warn
$script:ToastStripe.Dock = [System.Windows.Forms.DockStyle]::Left
$script:ToastStripe.Width = 4
$script:Toast.Controls.Add($script:ToastStripe)

$toastTitle = New-Object System.Windows.Forms.Label
$toastTitle.Text = 'MSFS Performance Guard'
$toastTitle.ForeColor = $script:C.Text
$toastTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$toastTitle.Location = New-Object System.Drawing.Point 18, 12
$toastTitle.AutoSize = $true
$script:Toast.Controls.Add($toastTitle)
$script:ToastTitle = $toastTitle

$script:ToastSub = New-Object System.Windows.Forms.Label
$script:ToastSub.ForeColor = $script:C.Muted
$script:ToastSub.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$script:ToastSub.Location = New-Object System.Drawing.Point 18, 36
$script:ToastSub.Size = New-Object System.Drawing.Size 360, 32
$script:Toast.Controls.Add($script:ToastSub)

$hint2 = New-Object System.Windows.Forms.Label
$hint2.Text = 'These programs may be cutting into frames'
$hint2.ForeColor = $script:C.Warn
$hint2.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$hint2.Location = New-Object System.Drawing.Point 18, 70
$hint2.AutoSize = $true
$script:Toast.Controls.Add($hint2)

$script:ToastBody = New-Object System.Windows.Forms.Panel
$script:ToastBody.Location = New-Object System.Drawing.Point 18, 94
$script:ToastBody.Size = New-Object System.Drawing.Size 364, 84
$script:ToastBody.BackColor = $script:C.Bg
$script:Toast.Controls.Add($script:ToastBody)

$script:ToastFooter = New-Object System.Windows.Forms.Panel
$script:ToastFooter.Location = New-Object System.Drawing.Point 18, 186
$script:ToastFooter.Size = New-Object System.Drawing.Size 364, 40
$script:ToastFooter.BackColor = $script:C.Bg
$script:Toast.Controls.Add($script:ToastFooter)

$btnSleepAll = New-FlatButton 'Sleep all suggested' 0 6 150 28 $script:C.Sleep $script:C.Text
$btnSleepAll.Add_Click({
        Add-SessionAction -Type 'sleep-all' -Ok $true
        foreach ($o in @($script:LastOffenders)) { [void](Invoke-SleepNamed $o.Name) }
        Hide-Toast
        Rebuild-Dashboard
    })
$script:ToastFooter.Controls.Add($btnSleepAll)

$btnDismiss = New-FlatButton 'Not now' 158 6 100 28 $script:C.Btn $script:C.Text
$btnDismiss.Add_Click({
        $script:CooldownUntil = (Get-Date).AddMinutes([double]$script:Config.DismissMinutes)
        Add-SessionAction -Type 'dismiss' -Ok $true
        Hide-Toast
    })
$script:ToastFooter.Controls.Add($btnDismiss)

$btnX = New-FlatButton '×' 330 8 28 24 $script:C.Bg $script:C.Muted
$btnX.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$btnX.Add_Click({
        $script:CooldownUntil = (Get-Date).AddMinutes([double]$script:Config.DismissMinutes)
        Add-SessionAction -Type 'dismiss' -Ok $true
        Hide-Toast
    })
$script:Toast.Controls.Add($btnX)

# Tray
$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:MenuMsfs = $script:Menu.Items.Add('Flight Simulator: not running')
$script:MenuMsfs.Enabled = $false
$script:MenuSlept = $script:Menu.Items.Add('Slept programs: 0')
$script:MenuSlept.Enabled = $false
[void]$script:Menu.Items.Add('-')
$itemDash = $script:Menu.Items.Add('Open dashboard')
$itemDash.Add_Click({ Show-Dashboard })
$itemResume = $script:Menu.Items.Add('Resume all slept programs')
$itemResume.Add_Click({ [void](Invoke-ResumeAll); Rebuild-Dashboard })
$script:MenuPause = $script:Menu.Items.Add('Pause watching')
$script:MenuPause.Add_Click({
        $script:Paused = -not $script:Paused
        Update-Tray
        Rebuild-Dashboard
    })
$itemReport = $script:Menu.Items.Add('Open last session report')
$itemReport.Add_Click({ Open-LastSessionReport })
$itemBadge = $script:Menu.Items.Add('Show on-screen badge')
$itemBadge.Add_Click({ Show-CornerBadge })
[void]$script:Menu.Items.Add('-')
$itemExit = $script:Menu.Items.Add('Exit (resume slept programs)')
$itemExit.Add_Click({ Close-Guard })

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = $script:IconIdle
$script:Notify.Text = 'MSFS Guard'
$script:Notify.Visible = (-not $script:Hosted)
$script:Notify.ContextMenuStrip = $script:Menu
if (-not $script:Hosted) {
    Show-TrayIconOnTaskbar
    $script:Notify.Add_MouseUp({
            param($sender, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                if ($script:ToastVisible) { Hide-Toast; Show-Dashboard }
                elseif ((Test-ShowSuggestionOverlay) -and $script:LastOffenders.Count -gt 0 -and $script:MsfsRunning) {
                    $ramBit = if ($script:LastFreeRam -gt 0) { '  |  {0:n1} GB RAM free' -f ($script:LastFreeRam / 1024.0) } else { '' }
                    Show-Toast $script:LastOffenders ($script:MsfsLabel + $ramBit)
                } else {
                    Show-Dashboard
                }
            }
        })
}
if ((-not $script:Hosted) -and (-not $script:Config.ContainsKey('ShowCornerBadge') -or [bool]$script:Config.ShowCornerBadge)) {
    Show-CornerBadge
}

$intervalMs = [int]([double]$script:Config.SampleSeconds * 1000)
if ($intervalMs -lt 1000) { $intervalMs = 1000 }
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $intervalMs
$script:Timer.Add_Tick({ Invoke-MonitorTick })
$script:Timer.Start()

if ($Visible) { Show-Dashboard }

if ((-not $script:Hosted) -and ((-not $script:WelcomeShown -and [bool]$script:Config.ShowWelcome) -or -not $script:IconHintShown)) {
    try {
        $script:Notify.ShowBalloonTip(
            5000,
            'MSFS Performance Guard',
            'Running now. Look for the bright blue plane next to the clock (or click ^ if Windows hid it).',
            [System.Windows.Forms.ToolTipIcon]::Info
        )
    } catch { }
    $script:WelcomeShown = $true
    $script:IconHintShown = $true
    Save-State
}

# Keep an off-screen form alive so the message loop does not exit.
# Do not Hide() it and do not treat Close as Exit - that killed the tray icon.
$script:HiddenHost = New-Object System.Windows.Forms.Form
$script:HiddenHost.Text = 'MSFS Performance Guard'
$script:HiddenHost.ShowInTaskbar = $false
$script:HiddenHost.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
$script:HiddenHost.Opacity = 0
$script:HiddenHost.Size = New-Object System.Drawing.Size 1, 1
$script:HiddenHost.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:HiddenHost.Location = New-Object System.Drawing.Point -32000, -32000
$script:HiddenHost.Add_FormClosing({
        if (-not $script:Exiting) { $_.Cancel = $true }
    })
Write-Log 'UI loop running (tray + badge)' 'OK'
try {
    [System.Windows.Forms.Application]::Run($script:HiddenHost)
} finally {
    Write-Log 'UI loop ended' 'WARN'
    Close-Guard
    try { $script:Mutex.ReleaseMutex() } catch { }
}

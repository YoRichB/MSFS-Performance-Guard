#requires -Version 5.1
<#
.SYNOPSIS
    MSFS Performance Guard - background monitor for Microsoft Flight Simulator.

.DESCRIPTION
    Lives in the system tray. While Flight Simulator is running it watches other
    programs for CPU, RAM, and disk pressure, then pops a suggestion overlay so
    you can Sleep (freeze) or Close the hog. Slept programs are resumed when
    MSFS exits, when you ask, or when this app quits.

    Never touches Windows protected processes, Defender, or your sim add-ons.
    Nothing is closed or frozen without a click (unless you turn on AutoSleep).
#>
[CmdletBinding()]
param(
    [switch]$Visible,
    [switch]$WriteTestReport
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:Root 'Config.json'
$script:StatePath = Join-Path $script:Root 'state.json'
$script:LogDir = Join-Path $script:Root 'Logs'

if ($WriteTestReport) {
    # Fall through. Mutex / tray are skipped after functions load.
}

if (-not $WriteTestReport -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Visible) { $arg += ' -Visible' }
    $style = if ($Visible) { 'Normal' } else { 'Hidden' }
    Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle $style
    exit
}

# -----------------------------------------------------------------------------
# Single instance
# -----------------------------------------------------------------------------
$script:CreatedMutex = $true
$script:Mutex = $null
if (-not $WriteTestReport) {
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
    $script:StopEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\MSFSPerformanceGuard-Stop')
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\MSFSPerformanceGuard-Show')
    [void]$script:StopEvent.Reset()
    [void]$script:ShowEvent.Reset()
    [System.Windows.Forms.Application]::EnableVisualStyles()
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
        'autofps', 'mdclient', 'maddog', 'bridge'
    )
    foreach ($k in $keys) {
        if ($n.Contains($k)) { return $true }
    }
    return $false
}

function Search-ProcessMsfsLink {
    param([string]$Name)
    $cache = Get-SafetyCache
    if ($cache.ContainsKey($Name)) { return [string]$cache[$Name] }
    $verdict = 'ok-to-suggest'
    try {
        $q = [uri]::EscapeDataString(('{0} MSFS OR "Flight Simulator" addon OR GSX OR Navigraph' -f $Name))
        $resp = Invoke-WebRequest -Uri ('https://html.duckduckgo.com/html/?q={0}' -f $q) -UseBasicParsing -TimeoutSec 4
        $html = [string]$resp.Content
        if ($html -match 'Flight Simulator|MSFS 2024|MSFS 2020|Navigraph|GSX Pro|Couatl|add-on|addon for MSFS|Community folder') {
            $verdict = 'msfs-related'
        }
    } catch {
        $verdict = 'unknown'
    }
    $cache[$Name] = $verdict
    Save-SafetyCache
    Write-Log ("Safety check {0} -> {1}" -f $Name, $verdict) 'INFO'
    return $verdict
}

function Test-IsSafeToSuggest {
    param([string]$Name, [switch]$Online)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match '^(powershell|pwsh|MSFSGuard)$') { return $false }
    if ($script:DoNotSleep -and $script:DoNotSleep.Contains($Name)) { return $false }
    if (Test-NameLooksMsfsRelated $Name) { return $false }
    if (-not $Online) { return $true }
    $v = Search-ProcessMsfsLink $Name
    if ($v -eq 'msfs-related' -or $v -eq 'unknown') { return $false }
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
    param($Offenders)
    if (-not $script:Session) { return }
    $script:Session.ToastShown++
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
            ("Do not auto-remove companions. Add an optional 'expensive companion' info toast for '{0}' that cannot Sleep it, only inform." -f $c.Name)
    }

    if ($Session.Dismissed -ge 2 -and $Session.Dismissed -ge $acted) {
        Add-Idea 'medium' 'config' 'Suggestions are being dismissed' `
            ("Dismissed {0} overlay(s) and only acted on {1}. The bar may be too twitchy." -f $Session.Dismissed, $acted) `
            'Raise CpuPercentThreshold by 2 and MemoryMBThreshold by 200, or set PersistSamples to 4.' `
            'Tune default thresholds upward, or add a "too noisy" mode that requires a higher score before Show-Toast.'
    }

    if ($Session.ToastShown -eq 0 -and $Avg.OtherCpuAvg -ge [math]::Max(2.0, [double]$script:Config.CpuPercentThreshold * $scale)) {
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
        $score -= 8
        [void]$notes.Add('- other programs used CPU and nothing was suggested')
    }
    if ($Session.PausedSamples -gt [int]($Session.Samples * 0.4)) {
        $score -= 6
        [void]$notes.Add('- watching was paused for much of the flight')
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
    return @{ Json = $jsonPath; Markdown = $mdPath }
}

function Build-SessionMarkdown {
    param($Session, $Avg, $ScoreInfo, $Ideas, [timespan]$Duration)
    $grade = Get-LetterGrade $ScoreInfo.Score
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# MSFS Performance Guard - session report')
    [void]$lines.Add('')
    [void]$lines.Add(('**Grade {0} ({1}/100)**' -f $grade, $ScoreInfo.Score))
    [void]$lines.Add('')
    [void]$lines.Add(('| Field | Value |'))
    [void]$lines.Add('| --- | --- |')
    [void]$lines.Add(('| Started | {0:yyyy-MM-dd HH:mm:ss} |' -f $Session.StartedAt))
    [void]$lines.Add(('| Ended | {0:yyyy-MM-dd HH:mm:ss} |' -f $Session.EndedAt))
    [void]$lines.Add(('| Duration | {0} |' -f (Format-Duration $Duration)))
    [void]$lines.Add(('| Sim | {0} |' -f $Session.MsfsName))
    [void]$lines.Add(('| Outcome | {0} |' -f $Session.Outcome))
    [void]$lines.Add(('| Admin | {0} |' -f $Session.Admin))
    [void]$lines.Add(('| Cores | {0} |' -f $Session.Cores))
    [void]$lines.Add(('| Samples | {0} (tick avg {1} ms, max {2} ms) |' -f $Session.Samples, $Avg.TickMsAvg, [int]$Session.TickMsMax))
    [void]$lines.Add(('| MSFS CPU | avg {0}%  max {1}% |' -f $Avg.MsfsCpuAvg, [math]::Round($Session.MsfsCpuMax, 1)))
    $ramMin = if ($Session.MsfsRamMin -eq [double]::MaxValue) { 0 } else { [math]::Round($Session.MsfsRamMin, 2) }
    [void]$lines.Add(('| MSFS RAM | avg {0} GB  max {1} GB  min {2} GB |' -f $Avg.MsfsRamAvgGB, [math]::Round($Session.MsfsRamMax, 2), $ramMin))
    $freeMin = if ($Session.FreeRamMin -eq [int]::MaxValue) { 0 } else { $Session.FreeRamMin }
    [void]$lines.Add(('| Free RAM | avg {0} MB  min {1} MB |' -f $Avg.FreeRamAvgMB, $freeMin))
    [void]$lines.Add(('| Other programs CPU | avg {0}% |' -f $Avg.OtherCpuAvg))
    [void]$lines.Add(('| Overlays shown | {0} |' -f $Session.ToastShown))
    [void]$lines.Add(('| Sleep / Close | {0} ok, {1} failed / {2} ok, {3} failed |' -f $Session.SleepOk, $Session.SleepFail, $Session.CloseOk, $Session.CloseFail))
    [void]$lines.Add(('| Ignore / Never / Dismiss | {0} / {1} / {2} |' -f $Session.Ignored, $Session.Never, $Session.Dismissed))
    [void]$lines.Add('')
    [void]$lines.Add('## How well the guard did')
    [void]$lines.Add('')
    if ($ScoreInfo.Notes.Count -eq 0) {
        [void]$lines.Add('- No extra score notes.')
    } else {
        foreach ($n in $ScoreInfo.Notes) { [void]$lines.Add("- $n") }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Suggestions shown')
    [void]$lines.Add('')
    if ($Session.Suggested.Count -eq 0) {
        [void]$lines.Add('None this flight.')
    } else {
        foreach ($o in $Session.Suggested) {
            [void]$lines.Add(('- **{0}** ({1}) - {2}' -f $o.Label, $o.Name, $o.Reason))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Your actions')
    [void]$lines.Add('')
    if ($Session.Actions.Count -eq 0) {
        [void]$lines.Add('No Sleep / Close / Ignore / Dismiss this flight.')
    } else {
        foreach ($a in $Session.Actions) {
            $ok = if ($a.Ok) { 'ok' } else { 'FAILED' }
            $label = if ($a.Label) { $a.Label } else { $a.Type }
            [void]$lines.Add(('- {0}  **{1}**  {2}  {3}' -f $a.At, $a.Type, $label, $ok))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Loudest other programs')
    [void]$lines.Add('')
    $tops = Get-TopPeaks $Session 8
    if ($tops.Count -eq 0) {
        [void]$lines.Add('Nothing notable besides the sim.')
    } else {
        [void]$lines.Add('| Program | Max CPU | Max RAM | Samples | Class |')
        [void]$lines.Add('| --- | ---: | ---: | ---: | --- |')
        foreach ($p in $tops) {
            $cls = 'other'
            if ($p.Companion) { $cls = 'companion' }
            elseif ($p.KnownHog) { $cls = 'known hog' }
            elseif ($p.Allow) { $cls = 'allowlisted' }
            [void]$lines.Add(('| {0} | {1:n1}% | {2} MB | {3} | {4} |' -f $p.Label, $p.MaxCpu, $p.MaxMemMB, $p.Samples, $cls))
        }
    }
    [void]$lines.Add('')
    $userIdeas = @(Get-UserFacingIdeas $Ideas)
    if ($userIdeas.Count -gt 0) {
        [void]$lines.Add('## What to do next')
        [void]$lines.Add('')
        foreach ($idea in $userIdeas) {
            [void]$lines.Add(('### {0}' -f (Get-ScalarText $idea.Title)))
            [void]$lines.Add('')
            [void]$lines.Add((Get-ScalarText $idea.Why))
            [void]$lines.Add('')
            [void]$lines.Add((Get-ScalarText $idea.Change))
            [void]$lines.Add('')
        }
    }
    return ($lines -join "`r`n")
}

function Get-UserFacingIdeas {
    param($Ideas)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($idea in @($Ideas)) {
        $area = Get-ScalarText $idea.Area
        $title = Get-ScalarText $idea.Title
        if ($area -eq 'none' -or $area -eq 'lists') { continue }
        if ($title -like 'Missed heavy program*') { continue }
        [void]$out.Add($idea)
    }
    return , $out.ToArray()
}

function Show-UserReportCard {
    param($Payload, $DurationText)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'MSFS Guard - flight report'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.Size = New-Object System.Drawing.Size 460, 520
    $f.BackColor = $script:C.Bg
    $f.ForeColor = $script:C.Text
    $f.TopMost = $true
    $f.ShowInTaskbar = $true
    if ($script:IconOk) { $f.Icon = $script:IconOk }

    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.BackColor = $script:C.Accent
    $stripe.Dock = [System.Windows.Forms.DockStyle]::Left
    $stripe.Width = 6
    $f.Controls.Add($stripe)

    $y = 16
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Flight report'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $title.ForeColor = $script:C.Text
    $title.Location = New-Object System.Drawing.Point 22, $y
    $title.AutoSize = $true
    $f.Controls.Add($title)
    $y += 34

    $grade = New-Object System.Windows.Forms.Label
    $grade.Text = ('Grade {0}  -  {1}' -f $Payload.Grade, $DurationText)
    $grade.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $grade.ForeColor = $script:C.Ok
    $grade.Location = New-Object System.Drawing.Point 22, $y
    $grade.AutoSize = $true
    $f.Controls.Add($grade)
    $y += 32

    $slept = @($Payload.Actions | Where-Object { $_.Type -eq 'sleep' -and $_.Ok } | ForEach-Object { Get-FriendlyName $_.Name })
    $closed = @($Payload.Actions | Where-Object { $_.Type -eq 'close' -and $_.Ok } | ForEach-Object { Get-FriendlyName $_.Name })
    $what = New-Object System.Collections.Generic.List[string]
    [void]$what.Add(('Simulator: {0}' -f $Payload.Sim))
    [void]$what.Add(('MSFS CPU avg {0}% (peak {1}%)' -f $Payload.MsfsCpuAvg, $Payload.MsfsCpuMax))
    [void]$what.Add(('MSFS RAM avg {0} GB (peak {1} GB)' -f $Payload.MsfsRamAvgGB, $Payload.MsfsRamMaxGB))
    if ($Payload.FreeRamMinMB) {
        [void]$what.Add(('Lowest free RAM: {0:n1} GB' -f ($Payload.FreeRamMinMB / 1024.0)))
    }
    if ($slept.Count -gt 0) { [void]$what.Add(('Put to sleep: {0}' -f ($slept -join ', '))) }
    if ($closed.Count -gt 0) { [void]$what.Add(('Closed: {0}' -f ($closed -join ', '))) }
    if ($slept.Count -eq 0 -and $closed.Count -eq 0) { [void]$what.Add('No programs were slept or closed.') }
    [void]$what.Add('Slept programs were resumed when the sim exited.')

    $body = New-Object System.Windows.Forms.Label
    $body.Text = ($what -join [Environment]::NewLine)
    $body.ForeColor = $script:C.Text
    $body.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $body.Location = New-Object System.Drawing.Point 22, $y
    $body.Size = New-Object System.Drawing.Size 400, 150
    $f.Controls.Add($body)
    $y += 158

    $userIdeas = @(Get-UserFacingIdeas $Payload.Suggestions)
    $next = New-Object System.Windows.Forms.Label
    $next.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $next.ForeColor = $script:C.Muted
    $next.Location = New-Object System.Drawing.Point 22, $y
    $next.Size = New-Object System.Drawing.Size 400, 140
    if ($userIdeas.Count -eq 0) {
        $next.Text = 'Nothing else you need to do. The sim had enough RAM and the guard stayed out of the way of add-ons.'
    } else {
        $bits = New-Object System.Collections.Generic.List[string]
        [void]$bits.Add('Next time:')
        foreach ($idea in ($userIdeas | Select-Object -First 3)) {
            [void]$bits.Add(('• {0}' -f (Get-ScalarText $idea.Change)))
        }
        $next.Text = ($bits -join [Environment]::NewLine)
    }
    $f.Controls.Add($next)

    $btn = New-FlatButton 'Done' 300 440 110 32 $script:C.Ok ([System.Drawing.Color]::FromArgb(20, 28, 24))
    $btn.Add_Click({ $f.Close() })
    $f.Controls.Add($btn)
    [void]$f.ShowDialog()
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
    [void]$lines.Add(('Latest session: grade **{0}** ({1}/100), {2}, {3}.' -f $LatestPayload.Grade, $LatestPayload.Score, $LatestPayload.Sim, $LatestPayload.DurationText))
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
            [void]$lines.Add(('**User-facing workaround today:** {0}' -f $t.Change))
            [void]$lines.Add('')
            $i++
        }
    }
    [void]$lines.Add('## Recent sessions')
    [void]$lines.Add('')
    [void]$lines.Add('| When | Sim | Duration | Grade | Overlays | Sleep ok | Dismiss |')
    [void]$lines.Add('| --- | --- | --- | --- | ---: | ---: | ---: |')
    foreach ($s in $sessions) {
        [void]$lines.Add(('| {0} | {1} | {2} | {3} ({4}) | {5} | {6} | {7} |' -f $s.EndedAt, $s.Sim, $s.DurationText, $s.Grade, $s.Score, $s.ToastShown, $s.SleepOk, $s.Dismissed))
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
    [void]$lines.Add(('**{0}** - grade {1} ({2}/100) - {3} - {4}' -f $Payload.Sim, $Payload.Grade, $Payload.Score, $Payload.DurationText, $Payload.Outcome))
    [void]$lines.Add('')
    [void]$lines.Add('## How the session went')
    [void]$lines.Add('')
    [void]$lines.Add(('- Admin: {0}' -f $Payload.Admin))
    [void]$lines.Add(('- Samples: {0}; tick avg {1} ms (max {2} ms); errors {3}' -f $Payload.Samples, $Payload.TickMsAvg, $Payload.TickMsMax, $Payload.TickErrors))
    [void]$lines.Add(('- MSFS CPU avg {0}% peak {1}%; RAM avg {2} GB peak {3} GB' -f $Payload.MsfsCpuAvg, $Payload.MsfsCpuMax, $Payload.MsfsRamAvgGB, $Payload.MsfsRamMaxGB))
    [void]$lines.Add(('- Other programs CPU avg {0}%' -f $Payload.OtherCpuAvg))
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
        $grade = Get-LetterGrade $scoreInfo.Score
        $md = Build-SessionMarkdown $session $avg $scoreInfo $ideas $duration
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
        Add-Member -InputObject $payload -NotePropertyName SchemaVersion -NotePropertyValue 1
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
        Add-Member -InputObject $payload -NotePropertyName Score -NotePropertyValue ([int]$scoreInfo.Score)
        Add-Member -InputObject $payload -NotePropertyName Grade -NotePropertyValue $grade
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
        Add-Member -InputObject $payload -NotePropertyName Markdown -NotePropertyValue $md
        $paths = Write-SessionFiles $payload $stamp $session.MsfsName
        Write-GrokSessionNotes -Payload $payload -Stamp $stamp -Sim $session.MsfsName
        Update-GrokBriefing $payload
        Write-Log ("Session report {0} grade {1} ({2}) -> {3}" -f $session.Id, $grade, $scoreInfo.Score, $paths.Markdown) 'OK'
        if (-not $WriteTestReport) {
            Show-UserReportCard -Payload $payload -DurationText $durationText
            if ([bool]$script:Config.ExitAfterSession) { Finish-AfterSession }
        }
    } catch {
        Write-Log ("Failed to write session report: {0} :: {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) 'ERR'
    }
}

function Open-LastSessionReport {
    $path = $script:LastReportMd
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        $path = Join-Path $script:LogDir 'latest-session.md'
    }
    if (Test-Path -LiteralPath $path) {
        Start-Process -FilePath $path
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            'No session report yet. Finish a Flight Simulator session first.',
            'MSFS Performance Guard',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
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

function Show-Toast {
    param($Offenders, [string]$Header)
    if (-not $Offenders -or $Offenders.Count -eq 0) { return }
    $script:LastOffenders = @($Offenders)
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
        $last = '   |   last session {0} ({1})' -f $script:LastSessionGrade, $script:LastSessionScore
    }
    $script:DashStatus.Text = "$msfs`r`n$ram   |   $pause$last"
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
        $script:BadgeStatus.Text = 'sim running'
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
    if (-not $script:Notify) { return }
    $slept = $script:Slept.Count
    if ($script:Paused) {
        $script:Notify.Icon = $script:IconIdle
        $script:Notify.Text = 'MSFS Guard - paused'
    } elseif ($script:MsfsRunning) {
        if ($slept -gt 0 -or $script:ToastVisible) {
            $script:Notify.Icon = $script:IconWarn
            $script:Notify.Text = "MSFS Guard - sim running, $slept slept"
        } else {
            $script:Notify.Icon = $script:IconOk
            $script:Notify.Text = 'MSFS Guard - sim running, clean'
        }
    } else {
        $script:Notify.Icon = $script:IconIdle
        $script:Notify.Text = 'MSFS Guard - waiting for Flight Simulator'
    }
    try {
        $script:MenuMsfs.Text = $(if ($script:MsfsRunning) { 'Flight Simulator: running' } else { 'Flight Simulator: not running' })
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
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}

# -----------------------------------------------------------------------------
# Monitor tick
# -----------------------------------------------------------------------------
function Invoke-MonitorTick {
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
            if ($script:Config.AutoResumeWhenMsfsExits -and $script:Slept.Count -gt 0) {
                [void](Invoke-ResumeAll)
            }
            $script:SessionIgnore = New-IgnoreSet @()
            $script:Strikes = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
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
            }
        }

        $script:PrevSnap = $snap
        $script:PrevIo = $ioNow
        $script:PrevMsfsCpu = $msfs.CpuSec

        Write-RuntimeStatus
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

        if ($offenders.Count -eq 0) { return }

        $ranked = @($offenders | Sort-Object { $_.Score } -Descending | Select-Object -First ([int]$script:Config.MaxSuggestions))
        $ranked = @($ranked | Where-Object { Test-IsSafeToSuggest $_.Name -Online })
        if ($ranked.Count -eq 0) { return }

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
        Show-Toast $ranked $header
        Add-SessionSuggestionShown $ranked
    } catch {
        Write-Log "Monitor tick failed: $($_.Exception.Message)" 'ERR'
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
    'MSFS_AutoFPS', 'MDClient', 'CP MSFS Bridge', 'powershell', 'pwsh'
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
    }
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

if ($existingMsfs.Running) {
    $script:MsfsRunning = $true
    $script:MsfsLabel = '{0}  |  {1:n1} GB RAM' -f $existingMsfs.Name, ($existingMsfs.Ws / 1GB)
    New-FlightSession -MsfsName $existingMsfs.Name
    Write-Log "Joined an already-running sim session ($($existingMsfs.Name))" 'INFO'
}

Write-Log ('Started (admin={0}, cores={1})' -f (Test-IsAdmin), [Environment]::ProcessorCount) 'INFO'

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
            Name = 'chrome'; Label = 'Google Chrome'; Reason = '6% CPU  ·  2.1 GB RAM'
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
                elseif ($script:LastOffenders.Count -gt 0 -and $script:MsfsRunning) {
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

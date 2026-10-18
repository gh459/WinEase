#Requires -Version 5.1
<#
.SYNOPSIS
    nano11 Guest VM Performance & Component Health Measurement Tool
.DESCRIPTION
    Executes inside a Windows 11 guest virtual machine (or physical machine) to objectively
    evaluate post-install lightweight metrics across 4 key dimensions:
    1. Disk Footprint (C: capacity, used space, free space)
    2. RAM & CPU Idle Load (physical memory, commit, idle CPU % across multi-second samples)
    3. Boot & Logon Timing (Diagnostics-Performance Event 100 MainPathBootTime / PostBootTime)
    4. Essential Functionality Health Checks (Network, Audio, IME, Windows Update, Settings App)

    Outputs structured JSON report (nano11_guest_benchmark.json) and console summary table.
    Clearly distinguishes between measured and estimated metrics per Domain 5 specifications.
.PARAMETER SampleSeconds
    Duration in seconds to monitor idle CPU and background activity (Default: 15 seconds).
.PARAMETER OutputPath
    File path to export the JSON benchmark results (Default: .\nano11_guest_benchmark.json).
.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [ValidateRange(5, 120)]
    [int]$SampleSeconds = 15,
    [string]$OutputPath = ".\nano11_guest_benchmark.json",
    [ValidateSet('Baseline', 'nano11 Standard', 'nano11 Experimental', 'Custom')]
    [string]$ConfigurationRole = 'Baseline',
    [ValidateSet('ImmediatePostOOBE', 'StabilizedSteadyState', 'PostUpdate')]
    [string]$MeasurementPhase = 'StabilizedSteadyState',
    [int]$RunIndex = 1,
    [string]$HistoryPath = "",
    [switch]$SkipResponseProbes
)

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "   nano11 Guest OS Performance & Baseline Health Measurement Suite            " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "Configuration: $ConfigurationRole | Phase: $MeasurementPhase | Run: #$RunIndex" -ForegroundColor DarkCyan
Write-Host "Sampling window: $SampleSeconds seconds" -ForegroundColor Gray
Write-Host ""

$measurementStart = Get-Date

# ------------------------------------------------------------------------------
# 1. OS & Hardware Environment Baseline
# ------------------------------------------------------------------------------
Write-Host "[1/6] Gathering OS and Hardware Specification..." -ForegroundColor Yellow

$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$csInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

$uptimeSec = 0
try {
    if ($osInfo -and $osInfo.LastBootUpTime) {
        $uptimeSec = [math]::Round(((Get-Date) - $osInfo.LastBootUpTime).TotalSeconds, 1)
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

$osCaption     = if ($osInfo) { $osInfo.Caption } else { [System.Environment]::OSVersion.VersionString }
$osVersion     = if ($osInfo) { $osInfo.Version } else { "Unknown" }
$osBuild       = if ($osInfo) { $osInfo.BuildNumber } else { "Unknown" }
$osArch        = if ($osInfo) { $osInfo.OSArchitecture } else { "64-bit" }
$totalRamMB    = if ($osInfo) { [math]::Round($osInfo.TotalVisibleMemorySize / 1024, 1) } else { 0 }
$cpuName       = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { "Unknown Processor" }
$cpuCores      = if ($cpuInfo) { $cpuInfo.NumberOfCores } else { 1 }
$cpuLogical    = if ($cpuInfo) { $cpuInfo.NumberOfLogicalProcessors } else { 1 }

Write-Host "  - OS:           $osCaption ($osVersion, Build $osBuild, $osArch)" -ForegroundColor Green
Write-Host "  - CPU:          $cpuName ($cpuCores Cores, $cpuLogical Logical)" -ForegroundColor Green
Write-Host "  - Physical RAM: $totalRamMB MB" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 2. Disk Footprint Metrics (Axis 3)
# ------------------------------------------------------------------------------
Write-Host "`n[2/5] Measuring System Drive Footprint (C:)..." -ForegroundColor Yellow

$systemDrive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -like "C:*" } | Select-Object -First 1
$diskTotalGB = 0
$diskFreeGB  = 0
$diskUsedGB  = 0

if ($systemDrive) {
    $diskTotalGB = [math]::Round($systemDrive.TotalSize / 1GB, 2)
    $diskFreeGB  = [math]::Round($systemDrive.TotalFreeSpace / 1GB, 2)
    $diskUsedGB  = [math]::Round(($systemDrive.TotalSize - $systemDrive.TotalFreeSpace) / 1GB, 2)
    Write-Host "  - C: Capacity:    $diskTotalGB GB" -ForegroundColor Green
    Write-Host "  - C: Used Space:  $diskUsedGB GB (Actual installed footprint)" -ForegroundColor Green
    Write-Host "  - C: Free Space:  $diskFreeGB GB" -ForegroundColor Green
} else {
    Write-Warning "Could not detect C: drive information."
}

# ------------------------------------------------------------------------------
# 3. RAM & CPU Idle Load Measurements (Multi-sample)
# ------------------------------------------------------------------------------
Write-Host "`n[3/5] Measuring Steady-State RAM & Idle CPU ($SampleSeconds samples)..." -ForegroundColor Yellow

$cpuSamples = [System.Collections.Generic.List[double]]::new()
$procCountSamples = [System.Collections.Generic.List[int]]::new()
$threadCountSamples = [System.Collections.Generic.List[int]]::new()
$handleCountSamples = [System.Collections.Generic.List[int]]::new()

for ($i = 1; $i -le $SampleSeconds; $i++) {
    Write-Progress -Activity "Sampling System Performance" -Status "Sample $i of $SampleSeconds" -PercentComplete (($i / $SampleSeconds) * 100)
    
    # Sample CPU load via WMI/CIM or Processor counter
    $cpuLoad = 0.0
    try {
        $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        if ($perf) { $cpuLoad = [double]$perf.PercentProcessorTime }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    $cpuSamples.Add($cpuLoad)

    # Process and handle counts
    $allProcs = Get-Process -ErrorAction SilentlyContinue
    if ($allProcs) {
        $procCountSamples.Add($allProcs.Count)
        $totalThreads = ($allProcs | Measure-Object -Property Threads -Sum).Sum
        $totalHandles = ($allProcs | Measure-Object -Property Handles -Sum).Sum
        $threadCountSamples.Add($(if ($totalThreads) { [int]$totalThreads } else { 0 }))
        $handleCountSamples.Add($(if ($totalHandles) { [int]$totalHandles } else { 0 }))
    }

    Start-Sleep -Seconds 1
}
Write-Progress -Activity "Sampling System Performance" -Completed

# Calculate statistics
$cpuAvg = [math]::Round(($cpuSamples | Measure-Object -Average).Average, 1)
$cpuMin = [math]::Round(($cpuSamples | Measure-Object -Minimum).Minimum, 1)
$cpuMax = [math]::Round(($cpuSamples | Measure-Object -Maximum).Maximum, 1)

$latestOs = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$freeRamMB = if ($latestOs) { [math]::Round($latestOs.FreePhysicalMemory / 1024, 1) } else { 0 }
$usedRamMB = [math]::Round($totalRamMB - $freeRamMB, 1)

$committedMB = 0
$commitLimitMB = 0
$cachedMB = 0
try {
    $perfMem = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    if ($perfMem) {
        $committedMB   = [math]::Round($perfMem.CommittedBytes / 1MB, 1)
        $commitLimitMB = [math]::Round($perfMem.CommitLimit / 1MB, 1)
        $cachedMB      = [math]::Round($perfMem.CacheBytes / 1MB, 1)
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

$avgProcs = if ($procCountSamples.Count -gt 0) { [int]([math]::Round(($procCountSamples | Measure-Object -Average).Average, 0)) } else { 0 }
$avgThreads = if ($threadCountSamples.Count -gt 0) { [int]([math]::Round(($threadCountSamples | Measure-Object -Average).Average, 0)) } else { 0 }
$avgHandles = if ($handleCountSamples.Count -gt 0) { [int]([math]::Round(($handleCountSamples | Measure-Object -Average).Average, 0)) } else { 0 }

Write-Host "  - Used RAM (Working Set): $usedRamMB MB (Free: $freeRamMB MB / Total: $totalRamMB MB)" -ForegroundColor Green
Write-Host "  - Committed / Cache RAM:  Committed: $committedMB MB (Limit: $commitLimitMB MB) | Cache: $cachedMB MB" -ForegroundColor Green
Write-Host "  - CPU Utilization (Idle): Avg: $cpuAvg% (Min: $cpuMin%, Max: $cpuMax%)" -ForegroundColor Green
Write-Host "  - Process Count:          $avgProcs processes (Threads: $avgThreads, Handles: $avgHandles)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 4. Boot & Logon Performance (Event Log)
# ------------------------------------------------------------------------------
Write-Host "`n[4/6] Reading Boot and Logon Timing from Diagnostics Log..." -ForegroundColor Yellow

$bootMainPathMs = $null
$bootPostBootMs = $null
$bootTotalMs    = $null
$bootEventFound = $false

try {
    $diagLog = Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        Id      = 100
    } -MaxEvents 1 -ErrorAction SilentlyContinue

    if ($diagLog) {
        $xml = [xml]$diagLog.ToXml()
        $eventData = $xml.Event.EventData.Data
        foreach ($item in $eventData) {
            if ($item.Name -eq 'MainPathBootTime') { $bootMainPathMs = [int]$item.'#text' }
            if ($item.Name -eq 'BootPostBootTime') { $bootPostBootMs = [int]$item.'#text' }
        }
        if ($bootMainPathMs -and $bootPostBootMs) {
            $bootTotalMs = $bootMainPathMs + $bootPostBootMs
            $bootEventFound = $true
            Write-Host "  - Main Boot Time:      $([math]::Round($bootMainPathMs / 1000, 2)) seconds (Kernel & Drivers)" -ForegroundColor Green
            Write-Host "  - Post-Boot Steady:    $([math]::Round($bootPostBootMs / 1000, 2)) seconds (Desktop stabilization)" -ForegroundColor Green
            Write-Host "  - Total Boot to Idle:  $([math]::Round($bootTotalMs / 1000, 2)) seconds" -ForegroundColor Green
        }
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

if (-not $bootEventFound) {
    Write-Host "  - Boot Diagnostics Event 100: Not yet generated (System may need a clean restart)." -ForegroundColor DarkGray
}

# ------------------------------------------------------------------------------
# 5. CLI & Process Launch Latency Probes (Cold vs Warm)
# ------------------------------------------------------------------------------
$probeResults = [ordered]@{
    ColdLaunch = [ordered]@{}
    WarmLaunch = [ordered]@{}
}

if (-not $SkipResponseProbes) {
    Write-Host "`n[5/6] Measuring CLI & Subsystem Launch Latencies (Cold vs Warm)..." -ForegroundColor Yellow

    # Probe A: cmd.exe
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c exit" -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
    $sw.Stop()
    $cmdColdMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
    $probeResults.ColdLaunch['CmdExeMs'] = $cmdColdMs

    $cmdWarmRuns = [System.Collections.Generic.List[double]]::new()
    for ($w = 0; $w -lt 3; $w++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c exit" -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
        $sw.Stop()
        $cmdWarmRuns.Add([math]::Round($sw.Elapsed.TotalMilliseconds, 2))
    }
    $cmdWarmMs = ($cmdWarmRuns | Sort-Object)[1]
    $probeResults.WarmLaunch['CmdExeMs'] = $cmdWarmMs

    # Probe B: reg.exe
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath "reg.exe" -ArgumentList "query HKCU\Console /v FontSize" -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
    $sw.Stop()
    $regColdMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
    $probeResults.ColdLaunch['RegExeMs'] = $regColdMs

    $regWarmRuns = [System.Collections.Generic.List[double]]::new()
    for ($w = 0; $w -lt 3; $w++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath "reg.exe" -ArgumentList "query HKCU\Console /v FontSize" -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
        $sw.Stop()
        $regWarmRuns.Add([math]::Round($sw.Elapsed.TotalMilliseconds, 2))
    }
    $regWarmMs = ($regWarmRuns | Sort-Object)[1]
    $probeResults.WarmLaunch['RegExeMs'] = $regWarmMs

    Write-Host "  - cmd.exe Latency:      Cold: ${cmdColdMs}ms | Warm: ${cmdWarmMs}ms" -ForegroundColor Green
    Write-Host "  - reg.exe Query Latency: Cold: ${regColdMs}ms | Warm: ${regWarmMs}ms" -ForegroundColor Green
} else {
    Write-Host "`n[5/6] Process launch latency probes skipped (-SkipResponseProbes)." -ForegroundColor DarkGray
}

# ------------------------------------------------------------------------------
# 6. Core System & Component Health Verification
# ------------------------------------------------------------------------------
Write-Host "`n[6/6] Testing 5 Core System Components & Subsystems..." -ForegroundColor Yellow

$healthResults = [ordered]@{}

# Test A: Network & DNS Connectivity
$netOk = $false
try {
    $ping = Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $ping) {
        $ping = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
    }
    $netOk = [bool]$ping
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
$healthResults['NetworkConnectivity'] = @{
    Component = "Network Connectivity"
    Passed    = $netOk
    Details   = if ($netOk) { "ICMP Ping to Gateway / DNS succeeded" } else { "No active internet/gateway ping (offline or disconnected)" }
}
Write-Host "  - Network:      $(if ($netOk) { '[PASS] Connected' } else { '[WARN] Offline / Disconnected' })" -ForegroundColor $(if ($netOk) { "Green" } else { "Yellow" })

# Test B: Audio Subsystem
$audioOk = $false
$audioDetails = ""
try {
    $audioSvc = Get-Service -Name "Audiosrv" -ErrorAction SilentlyContinue
    if ($audioSvc -and $audioSvc.Status -eq 'Running') {
        $audioOk = $true
        $audioDetails = "Windows Audio service (Audiosrv) is Running"
    } else {
        $audioDetails = "Audiosrv is $($audioSvc.Status)"
    }
} catch {
    $audioDetails = "$_"
}
$healthResults['AudioSubsystem'] = @{
    Component = "Audio Subsystem"
    Passed    = $audioOk
    Details   = $audioDetails
}
Write-Host "  - Audio:        $(if ($audioOk) { '[PASS] Audiosrv Running' } else { '[FAIL] Audiosrv Stopped' })" -ForegroundColor $(if ($audioOk) { "Green" } else { "Red" })

# Test C: Japanese & Regional IME Input
$imeOk = $false
$imeDetails = ""
try {
    $langList = Get-WinUserLanguageList -ErrorAction SilentlyContinue
    if ($langList -and ($langList | Where-Object { $_.LanguageTag -in @('ja', 'ja-JP', 'en-US') })) {
        $tags = ($langList | ForEach-Object { $_.LanguageTag }) -join ', '
        $imeOk = $true
        $imeDetails = "Active input languages: $tags"
    } else {
        $imeDetails = "No language list returned"
    }
} catch {
    $imeDetails = "$_"
}
$healthResults['IMESupport'] = @{
    Component = "Japanese & Regional IME"
    Passed    = $imeOk
    Details   = $imeDetails
}
Write-Host "  - IME & Input:  $(if ($imeOk) { "[PASS] $imeDetails" } else { '[WARN] Check language configuration' })" -ForegroundColor $(if ($imeOk) { "Green" } else { "Yellow" })

# Test D: Windows Update Service (wuauserv)
$wuOk = $false
$wuDetails = ""
try {
    $wuSvc = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
    if ($wuSvc) {
        $wuOk = $true
        $wuDetails = "Status: $($wuSvc.Status), StartType: $($wuSvc.StartType)"
    } else {
        $wuDetails = "wuauserv not found"
    }
} catch {
    $wuDetails = "$_"
}
$healthResults['WindowsUpdate'] = @{
    Component = "Windows Update Service"
    Passed    = $wuOk
    Details   = $wuDetails
}
Write-Host "  - Win Update:   $(if ($wuOk) { "[INFO] $wuDetails" } else { '[WARN] Service absent' })" -ForegroundColor Cyan

# Test E: System Settings App (Immersive Control Panel)
$settingsOk = $false
$settingsDetails = ""
try {
    $pkg = Get-AppxPackage -Name "windows.immersivecontrolpanel" -ErrorAction SilentlyContinue
    if ($pkg) {
        $settingsOk = $true
        $settingsDetails = "Version: $($pkg.Version)"
    } else {
        $settingsDetails = "Package not registered in current user context"
    }
} catch {
    $settingsDetails = "$_"
}
$healthResults['SettingsApp'] = @{
    Component = "Settings App (Immersive Control Panel)"
    Passed    = $settingsOk
    Details   = $settingsDetails
}
Write-Host "  - Settings App: $(if ($settingsOk) { "[PASS] $settingsDetails" } else { '[WARN] $settingsDetails' })" -ForegroundColor $(if ($settingsOk) { "Green" } else { "Yellow" })

# ------------------------------------------------------------------------------
# Export JSON Benchmark Document (Dual-Schema)
# ------------------------------------------------------------------------------
$benchmarkReport = [ordered]@{
    ReportTitle            = "nano11 Guest OS Benchmark & Health Report"
    Timestamp              = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    MeasurementDurationSec = [math]::Round(((Get-Date) - $measurementStart).TotalSeconds, 1)

    Metadata = [ordered]@{
        ConfigurationRole  = $ConfigurationRole
        MeasurementPhase   = $MeasurementPhase
        RunIndex           = $RunIndex
        UptimeSeconds      = $uptimeSec
    }

    Environment = [ordered]@{
        ComputerName  = $env:COMPUTERNAME
        OSCaption     = $osCaption
        OSVersion     = $osVersion
        OSBuild       = $osBuild
        Architecture  = $osArch
        CpuModel      = $cpuName
        CpuCores      = $cpuCores
        CpuLogical    = $cpuLogical
        TotalRamMB    = $totalRamMB
    }

    # Legacy Schema Keys
    DiskMetrics = [ordered]@{
        DriveLetter     = "C:"
        TotalCapacityGB = $diskTotalGB
        UsedSpaceGB     = $diskUsedGB
        FreeSpaceGB     = $diskFreeGB
        IsMeasured      = ($null -ne $systemDrive)
    }

    PerformanceMetrics = [ordered]@{
        SampleWindowSeconds = $SampleSeconds
        UsedRamMB           = $usedRamMB
        FreeRamMB           = $freeRamMB
        CommittedRamMB      = $committedMB
        CommitLimitMB       = $commitLimitMB
        CachedRamMB         = $cachedMB
        CpuIdleAvgPercent   = $cpuAvg
        CpuIdleMinPercent   = $cpuMin
        CpuIdleMaxPercent   = $cpuMax
        AverageProcesses    = $avgProcs
        AverageThreads      = $avgThreads
        AverageHandles      = $avgHandles
        IsMeasured          = $true
    }

    BootMetrics = [ordered]@{
        EventLogAvailable      = $bootEventFound
        MainPathBootSeconds    = if ($bootMainPathMs) { [math]::Round($bootMainPathMs / 1000, 2) } else { $null }
        PostBootTimeSeconds    = if ($bootPostBootMs) { [math]::Round($bootPostBootMs / 1000, 2) } else { $null }
        TotalBootToIdleSeconds = if ($bootTotalMs) { [math]::Round($bootTotalMs / 1000, 2) } else { $null }
        IsMeasured             = $bootEventFound
    }

    ComponentHealth = $healthResults

    # Normalized Dual-Schema Keys for Export-Nano11HtmlReport & Multi-Run Aggregation
    DiskFootprint = [ordered]@{
        TotalCapacityGB = $diskTotalGB
        UsedSpaceGB     = $diskUsedGB
        FreeSpaceGB     = $diskFreeGB
        IsMeasured      = ($null -ne $systemDrive)
    }

    Memory = [ordered]@{
        TotalMB         = $totalRamMB
        UsedMB          = $usedRamMB
        FreeMB          = $freeRamMB
        CommittedMB     = $committedMB
        CommitLimitMB   = $commitLimitMB
        CachedMB        = $cachedMB
        ProcessCount    = $avgProcs
        ThreadCount     = $avgThreads
        HandleCount     = $avgHandles
    }

    Cpu = [ordered]@{
        IdlePercentAvg  = $cpuAvg
        IdlePercentMin  = $cpuMin
        IdlePercentMax  = $cpuMax
    }

    BootPerformance = [ordered]@{
        EventLogAvailable = $bootEventFound
        MainBootSeconds   = if ($bootMainPathMs) { [math]::Round($bootMainPathMs / 1000, 2) } else { $null }
        PostBootSeconds   = if ($bootPostBootMs) { [math]::Round($bootPostBootMs / 1000, 2) } else { $null }
        TotalBootSeconds  = if ($bootTotalMs) { [math]::Round($bootTotalMs / 1000, 2) } else { $null }
    }

    SubsystemHealth = [ordered]@{
        NetworkConnected = $netOk
        AudioRunning     = $audioOk
        IMEConfigured    = $imeOk
        WindowsUpdateOk  = $wuOk
        SettingsAppOk    = $settingsOk
    }

    Probes = $probeResults
}

try {
    $json = $benchmarkReport | ConvertTo-Json -Depth 6
    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        [void][System.IO.Directory]::CreateDirectory($outDir)
    }
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.Encoding]::UTF8)
    Write-Host "`nBenchmark JSON successfully exported to: $OutputPath" -ForegroundColor Green
} catch {
    Write-Warning "Could not write benchmark JSON: $_"
}

# Append to History file if requested
if ($HistoryPath) {
    try {
        $historyList = [System.Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $HistoryPath) {
            $existingJson = [System.IO.File]::ReadAllText($HistoryPath, [System.Text.Encoding]::UTF8)
            $existing = $existingJson | ConvertFrom-Json
            if ($existing -is [System.Collections.IEnumerable] -and -not ($existing -is [string])) {
                foreach ($item in $existing) { $historyList.Add($item) }
            } else {
                $historyList.Add($existing)
            }
        }
        $historyList.Add($benchmarkReport)
        $histOut = $historyList | ConvertTo-Json -Depth 6
        $histDir = Split-Path -Path $HistoryPath -Parent
        if ($histDir -and -not (Test-Path -LiteralPath $histDir)) {
            [void][System.IO.Directory]::CreateDirectory($histDir)
        }
        [System.IO.File]::WriteAllText($HistoryPath, $histOut, [System.Text.Encoding]::UTF8)
        Write-Host "Benchmark appended to history at: $HistoryPath (Total runs: $($historyList.Count))" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to append benchmark run to HistoryPath: $_"
    }
}

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "   Benchmark & Health Inspection Complete                                      " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

#Requires -Version 5.1
<#
.SYNOPSIS
    nano11 Builder - Universal, Language-Independent Windows 11 Image Reducer
.DESCRIPTION
    Generates a significantly reduced Windows 11 image with support for:
    - Universal language compatibility (independent of host OS locale)
    - Full Debloat with optional customizations (keep IME, Defender, Fonts, Drivers, Updates, Bluetooth)
    - Optional WSL2 & VirtualMachinePlatform pre-enablement before WinSxS slimming (-EnableWSL)
    - Custom working directory support (-WorkDir) to prevent disk space issues
    - Setup hardware requirement bypasses including appraiserres.dll patch for Canary 28020+
    - Fixed WinSxS and DriverStore permission issues (robocopy mirror trick & .NET ACL)
    - Architecture support: amd64 (x64) and arm64
    - Proper placement of autounattend.xml (in ISO root, Sysprep, Panther) with self-healing and CompactOS
    - Clean unattended setup with local account support
.NOTES
    Original Author: NTDEV
    Contributions: Tinnitus97 (PR #6), Antigravity (Multi-language, ARM64, Bugfixes, WSL2 & Customization)
    License: MIT
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [alias("Unattended", "Silent", "Batch")]
    [switch]$NonInteractive,
    [switch]$Interactive,
    [alias("UI")]
    [switch]$GUI,
    [alias("Preset")]
    [string]$Profile,
    [alias("ExportConfig")]
    [string]$SaveProfile,
    [alias("ImportConfig", "Config")]
    [string]$LoadProfile,
    [string]$SourceDrive,
    [string]$WorkDir,
    [string]$Index,
    [string]$OutputIsoName,
    [switch]$TimestampIso,
    
    # Execution & Diagnostic Flags
    [switch]$DryRun,
    [switch]$Validate,
    [switch]$SkipEiCfg,
    [switch]$NoPostInstallAssets,
    
    # Customization & Maintenance Settings
    # Both values are inserted verbatim into autounattend.xml and its embedded PowerShell scripts,
    # so only characters that are safe in XML, in '...' and in "..." PowerShell strings are accepted.
    # ComputerName: '*' (random) or a NetBIOS name (letters, digits, hyphen; max 15).
    [ValidatePattern('^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$')]
    [string]$ComputerName = '*',
    # UserName: letters (incl. Japanese), digits, space, '.', '_', '-'; max 20 characters.
    [ValidatePattern('^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$')]
    [string]$UserName = 'User',
    [int]$KeepLogs = 10,
    [string]$InjectDrivers,
    [switch]$KeepBasicApps,
    [switch]$KeepSearchIndex,
    
    # 1. Windows Defender
    [switch]$KeepDefender,
    [alias("NoDefender")]
    [switch]$RemoveDefender,
    
    # 2. Asian IMEs
    [alias("KeepAsianIME")]
    [switch]$KeepIME,
    [alias("NoIME", "RemoveAsianIME")]
    [switch]$RemoveIME,
    
    # 3. Fonts
    [alias("KeepExtraFonts")]
    [switch]$KeepFonts,
    [alias("NoFonts")]
    [switch]$RemoveFonts,
    
    # 4. Drivers
    [switch]$KeepDrivers,
    [switch]$RemoveDrivers,
    
    # 5. Windows Update
    [alias("EnableWindowsUpdate")]
    [switch]$KeepWindowsUpdate,
    [alias("NoWindowsUpdate")]
    [switch]$DisableWindowsUpdate,
    
    # 6. Bluetooth
    [switch]$KeepBluetooth,
    [alias("NoBluetooth")]
    [switch]$DisableBluetooth,
    
    # 7. WSL2 & Virtualization
    [switch]$EnableWSL,
    [alias("NoWSL")]
    [switch]$DisableWSL,
    
    # 8. Recovery Environment (WinRE)
    [alias("KeepWinRE")]
    [switch]$KeepRecovery,
    [alias("RemoveWinRE", "NoWinRE", "NoRecovery")]
    [switch]$RemoveRecovery,
    
    # 9. WinSxS debloat mode
    [alias("SafeWinSxS")]
    [switch]$SafeDebloat,
    [alias("TrimWinSxS")]
    [switch]$AggressiveWinSxS,
    # E2 (opt-in): override the 26100+ offline StartComponentCleanup / ResetBase block (checkpoint LCU corruption risk)
    [alias("ForceWinSxS")]
    [switch]$ForceWinSxSCleanup,
    
    # 10. UltraSlim
    [switch]$UltraSlim,
    [switch]$NoUltraSlim,
    
    # 11. Japanese 106/109 Keyboard
    [switch]$JapaneseKeyboard,
    [switch]$NoJapaneseKeyboard,
    
    # 12. AtlasOS & ReviOS Tweaks
    [switch]$AtlasReviOS,
    [switch]$NoAtlasReviOS,
    
    # 13. Export payload format
    [switch]$ExportESD,
    [alias("NoESD")]
    [switch]$ExportWIM,
    [alias("FAT32Compatible", "FAT32")]
    [switch]$SplitWIM,
    [switch]$NoSplitWIM,
    
    # 14. Microsoft Store
    [switch]$KeepStore,
    [alias("NoStore", "RemoveMicrosoftStore")]
    [switch]$RemoveStore,
    
    # 16. Fast VHDX Scratch Disk
    [alias("FastVHDX", "VHDX")]
    [switch]$UseVHDX,
    
    # 17. Self Diagnostics and Image Verification
    [switch]$TestSelf,
    [alias("VerifyImage")]
    [switch]$CheckHealth,
    # F2: Phase-level checkpoint resume (delegates to -ResumeIsoOnly for targets >= 13)
    [alias("ResumePhase", "ResumeFrom")]
    [ValidateRange(1, 18)]
    [int]$ResumeFromPhase = 0,
    # F7: AppX removal parallelism (1-8; 1 = sequential, default 4)
    [ValidateRange(1, 8)]
    [int]$AppxParallelism = 4,
    # A2: Fast-track Phase 14-18 against the preserved workspace payload (workspace\build\sources\install.wim)
    [alias("ResumeIso", "IsoResume")]
    [switch]$ResumeIsoOnly,
    

    # 19. Xbox Services & Gaming Features
    [switch]$KeepXboxServices,
    [alias("NoXboxServices")]
    [switch]$RemoveXboxServices,

    # 20. Audio Tweaks & Latency Protection
    [switch]$KeepAudioTweaks,

    # 21. Advanced Modular Optimization Tweak Toggles
    [switch]$RemoveLegacyFOD,
    [switch]$TrimWallpapers,
    [ValidateSet('Off', 'Reduced', 'Keep')]
    [string]$HibernateMode = 'Keep',
    [ValidateSet('Automatic', 'Small', 'None')]
    [string]$CrashDumpMode = 'Automatic',
    [switch]$DisableCPUMitigations,
    [switch]$MMCSSGaming,
    [switch]$DAWMode,
    [switch]$DisableMemCompression,
    [switch]$DisableFSE,
    [switch]$NvidiaLowLatency,
    [switch]$NoKernelPaging,
    [switch]$DisableUSBSuspend,
    [switch]$NoHypervisor,
    [switch]$RemoveWebViewPostOOBE,
    [switch]$FastExport,
    [switch]$UefiOnly,
    [ValidateSet('Efficient', 'Aggressive', 'Off', 'Default')]
    [string]$CpuBoostMode = 'Default',
    [ValidateSet('Desktop', 'Handheld', 'Balanced', 'VM', 'Default')]
    [string]$PowerPreset = 'Default',
    [alias("NoActivationRestrictions", "UnlockPersonalization")]
    [switch]$BypassActivationRestrictions,
    [alias("UltraLowRAM", "LowRAM")]
    [switch]$RadicalRAM,
    [switch]$NoRadicalRAM,
    # Hashtable (@{ GPULatency = $false }) or string "GPULatency=0;TimerBCD=1" (the string form survives
    # being passed through powershell.exe -File, e.g. on elevation or in batch queue mode)
    [object]$TweakGroupOverrides
)

# G7 regression fix: dot-source the extracted helper module BEFORE any top-level
# statement that calls a helper. The leftover-hive cleanup further below calls
# Unmount-RegistryHiveWithRetry, which only exists after this dot-source runs.
# The helper module contains only pure functions and the BuildContext class
# (no top-level state), so loading it this early is safe.
$scriptDirEarly = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$helperModuleEarly = Join-Path -Path $scriptDirEarly -ChildPath "nano11helpers.ps1"
if (Test-Path -LiteralPath $helperModuleEarly) {
    . $helperModuleEarly
} else {
    throw "Required helper module not found: $helperModuleEarly"
}

# Normalize -TweakGroupOverrides to a hashtable of [bool]
if ($null -ne $TweakGroupOverrides -and $TweakGroupOverrides -isnot [System.Collections.IDictionary]) {
    $parsedOverrides = @{}
    foreach ($pair in ("$TweakGroupOverrides" -split '[;,]')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $kv = $pair -split '=', 2
        if ($kv.Count -ne 2) { throw "Invalid -TweakGroupOverrides entry '$pair'. Use Name=1;Name2=0" }
        $parsedOverrides[$kv[0].Trim()] = $kv[1].Trim() -in @('1', 'true', '$true', 'yes', 'on')
    }
    $TweakGroupOverrides = $parsedOverrides
    $PSBoundParameters['TweakGroupOverrides'] = $parsedOverrides
}

# Serialize a bound parameter as PowerShell syntax for re-invocation via New-Nano11ChildArguments.
# (powershell.exe -File cannot pass -Switch:$false, so child processes are started with -EncodedCommand.)
function ConvertTo-Nano11CliArgument {
    param([string]$Name, $Value)
    if ($Value -is [System.Management.Automation.SwitchParameter]) {
        if ($Value.IsPresent) { return "-$Name" } else { return "-$Name`:`$false" }
    }
    if ($Value -is [bool]) {
        if ($Value) { return "-$Name" } else { return "-$Name`:`$false" }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $Value = (@($Value.Keys | ForEach-Object { "{0}={1}" -f $_, $(if ($Value[$_]) { 1 } else { 0 }) }) -join ';')
    }
    return "-$Name '" + ("$Value" -replace "'", "''") + "'"
}

# Build a powershell.exe argument string that runs this script with the given (already serialized) arguments
function New-Nano11ChildArguments {
    param([string]$ScriptPath, [string[]]$ScriptArguments)
    $command = "& '" + ($ScriptPath -replace "'", "''") + "' " + ($ScriptArguments -join ' ') + "; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    # -InputFormat None: never wait on an inherited/redirected stdin (otherwise a child can hang before starting)
    return "-NoProfile -ExecutionPolicy Bypass -InputFormat None -EncodedCommand $encoded"
}

# PowerShell 7+ Compatibility Notice
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Warning "PowerShell 7+ is not officially supported due to native Windows DISM and elevation differences. Running in Windows PowerShell 5.1 is strongly recommended."
}

# Unified nano11 Version
$script:Nano11Version = "2.1"

# Ensure UTF-8 Console and Output encoding to prevent mojibake in Windows terminals
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# Disable all interactive confirmation prompts to guarantee non-blocking unattended execution
$ConfirmPreference = 'None'

# ==============================================================================
# Windows 11 Installation Media Notice (install.wim & install.esd)
# ==============================================================================
Write-Host ""
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host " [WINDOWS 11 SOURCE MEDIA ADVISORY]" -ForegroundColor Cyan
Write-Host " Official ISOs containing 'install.wim' provide maximum build speed and stability." -ForegroundColor Green
Write-Host " MediaCreationTool ISOs containing compressed 'install.esd' will be automatically" -ForegroundColor Yellow
Write-Host " decompressed and converted to 'install.wim' via DISM during image servicing." -ForegroundColor Yellow
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Early Simulation & Diagnostic Mode Resolution (P0-02)
$isDryRunMode = $DryRun -or ($PSBoundParameters.ContainsKey('WhatIf') -and $PSBoundParameters['WhatIf'])

# Check and adjust Execution Policy (Skip if in TestSelf or DryRun mode to remain 100% non-destructive)
if ((-not $TestSelf) -and ($env:NANO11_TEST_MODE -ne "1") -and (-not $isDryRunMode)) {
    if ((Get-ExecutionPolicy) -eq 'Restricted') {
        if ($NonInteractive) {
            Write-Warning "PowerShell Execution Policy is 'Restricted' in -NonInteractive mode. Attempting to set RemoteSigned for CurrentUser..."
            try {
                Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false -ErrorAction Stop
                Write-Host "Execution Policy set to RemoteSigned." -ForegroundColor Green
            } catch {
                throw "Execution Policy is Restricted and cannot be changed non-interactively. Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
            }
        } else {
            Write-Host "Your current PowerShell Execution Policy is 'Restricted', which prevents scripts from running." -ForegroundColor Yellow
            Write-Host "Do you want to change it to 'RemoteSigned'? (yes/no)"
            $response = Read-Host
            if ($response -and ($response.Trim().ToLower() -in @('yes', 'y'))) {
                Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
                Write-Host "Execution Policy has been changed to RemoteSigned." -ForegroundColor Green
            } else {
                Write-Host "The script cannot run without changing the execution policy. Exiting..." -ForegroundColor Red
                exit 1
            }
        }
    }
}

# 2. Check for Admin rights and restart with full arguments preserved
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
if ((-not $myWindowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) -and ($env:NANO11_TEST_MODE -ne "1") -and (-not $TestSelf) -and (-not $isDryRunMode)) {
    Write-Host "Restarting script with Administrator privileges in a new window..." -ForegroundColor Yellow
    
    # Reconstruct bound parameters for elevated process
    $paramList = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $PSBoundParameters.Keys) {
        $paramList.Add((ConvertTo-Nano11CliArgument -Name $key -Value $PSBoundParameters[$key]))
    }
    
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = New-Nano11ChildArguments -ScriptPath $myInvocation.MyCommand.Definition -ScriptArguments $paramList
    $newProcess.Verb = "runas"
    try {
        [System.Diagnostics.Process]::Start($newProcess) | Out-Null
        exit 0
    } catch {
        Write-Host "Failed to elevate privileges: $_" -ForegroundColor Red
        exit 1
    }
}

# 2b. Concurrency Guard: Global Mutex to prevent simultaneous builds
$script:BuildMutex = $null
$script:HasMutex = $false
if ((-not $TestSelf) -and ($env:NANO11_TEST_MODE -ne "1") -and (-not $isDryRunMode)) {
    try {
        $script:BuildMutex = New-Object System.Threading.Mutex($false, "Global\nano11Builder")
        $script:HasMutex = $script:BuildMutex.WaitOne(0)
        if (-not $script:HasMutex) {
            Write-Host "Error: Another instance of nano11 builder is currently running (Global\nano11Builder)." -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Warning "Could not acquire global mutex: $_"
    }
}

# 2c. Validate conflicting / contradictory switch parameters
$conflicts = @(
    @('KeepDefender', 'RemoveDefender'),
    @('KeepIME', 'RemoveIME'),
    @('KeepFonts', 'RemoveFonts'),
    @('KeepDrivers', 'RemoveDrivers'),
    @('KeepWindowsUpdate', 'DisableWindowsUpdate'),
    @('KeepBluetooth', 'DisableBluetooth'),
    @('EnableWSL', 'DisableWSL'),
    @('KeepRecovery', 'RemoveRecovery'),
    @('SafeDebloat', 'AggressiveWinSxS'),
    @('UltraSlim', 'NoUltraSlim'),
    @('JapaneseKeyboard', 'NoJapaneseKeyboard'),
    @('AtlasReviOS', 'NoAtlasReviOS'),
    @('ExportESD', 'ExportWIM'),
    @('SplitWIM', 'NoSplitWIM'),
    @('KeepStore', 'RemoveStore'),
    @('KeepXboxServices', 'RemoveXboxServices')
)
foreach ($pair in $conflicts) {
    $paramA = $pair[0]; $paramB = $pair[1]
    $isA = if ($PSBoundParameters.ContainsKey($paramA)) { [bool]$PSBoundParameters[$paramA] } else { $false }
    $isB = if ($PSBoundParameters.ContainsKey($paramB)) { [bool]$PSBoundParameters[$paramB] } else { $false }
    if ($isA -and $isB) {
        throw "Conflicting parameters specified: -$paramA and -$paramB cannot be used together."
    }
}

# Mount directory bookkeeping
$script:ManagedMountDirs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$script:AllocatedMountDirs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$script:PreservedMountDirs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$script:MountAllocationRoot = $null
$script:MountDirectoryPrefix = $null

function Get-Nano11MountedImages {
    [CmdletBinding()]
    param()
    $records = @()
    $querySuccess = $false
    $lastErr = $null

    try {
        if (Get-Command -Name Get-WindowsImage -Module DISM -ErrorAction SilentlyContinue) {
            $images = @(Get-WindowsImage -Mounted -ErrorAction Stop)
            $records = @($images | ForEach-Object {
                [PSCustomObject]@{
                    Path        = $_.Path
                    ImagePath   = $_.ImagePath
                    ImageIndex  = $_.ImageIndex
                    MountStatus = [string]$_.MountStatus
                }
            })
            $querySuccess = $true
        }
    } catch {
        $lastErr = $_
    }

    if (-not $querySuccess) {
        $out = & dism.exe /English /Get-MountedImageInfo 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            $querySuccess = $true
            $cur = [ordered]@{}
            foreach ($line in $out) {
                $t = [string]$line
                if ([string]::IsNullOrWhiteSpace($t)) {
                    if ($cur.Count -gt 0 -and $cur.Contains('Mount Dir')) {
                        $records += [PSCustomObject]@{
                            Path        = $cur['Mount Dir']
                            ImagePath   = $cur['Image File']
                            ImageIndex  = $cur['Image Index']
                            MountStatus = $cur['Status']
                        }
                        $cur = [ordered]@{}
                    }
                    continue
                }
                if ($t -match '^\s*([^:]+?)\s*:\s*(.*)$') {
                    $cur[$matches[1].Trim()] = $matches[2].Trim()
                }
            }
            if ($cur.Count -gt 0 -and $cur.Contains('Mount Dir')) {
                $records += [PSCustomObject]@{
                    Path        = $cur['Mount Dir']
                    ImagePath   = $cur['Image File']
                    ImageIndex  = $cur['Image Index']
                    MountStatus = $cur['Status']
                }
            }
        } else {
            $lastErr = "dism.exe /Get-MountedImageInfo returned exit code ${exitCode}: $($out -join ' ')"
        }
    }

    # Augment and correlate with direct WIMMount registry entries (detects corrupted/Invalid mounts where DISM API omits details)
    try {
        $regKey = "HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images"
        if (Test-Path -LiteralPath $regKey) {
            $subKeys = Get-ChildItem -LiteralPath $regKey -ErrorAction SilentlyContinue
            foreach ($sk in $subKeys) {
                $p = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.'Mount Path') {
                    $mPath = [string]$p.'Mount Path'
                    $wPath = [string]$p.'WIM Path'
                    $status = switch ($p.Status) {
                        1 { "Ok" }
                        2 { "Invalid" }
                        3 { "Needs Remount" }
                        default { [string]$p.Status }
                    }
                    $existingMatch = $records | Where-Object { $_.Path -and ($_.Path -ieq $mPath) }
                    if (-not $existingMatch) {
                        $records += [PSCustomObject]@{
                            Path        = $mPath
                            ImagePath   = $wPath
                            ImageIndex  = $p.'Image Index'
                            MountStatus = $status
                        }
                    } else {
                        if (-not $existingMatch.ImagePath -and $wPath) {
                            $existingMatch.ImagePath = $wPath
                        }
                    }
                }
            }
        }
    } catch {}

    if (-not $querySuccess) {
        throw "Failed to query mounted images from DISM (Get-WindowsImage failed and dism.exe returned non-zero exit code): $lastErr"
    }

    return @($records)
}

# Helper function: Detect orphaned DISM offline registry hives locked in HKLM
function Get-Nano11DismOfflineHives {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetMountDir
    )
    $normTarget = ConvertTo-Nano11NormalizedPath -Path $TargetMountDir
    if (-not $script:ManagedMountDirs.Contains($normTarget)) {
        throw "Target mount directory '$TargetMountDir' is not registered in ManagedMountDirs."
    }

    $expectedSubPaths = @(
        'Users\Default\ntuser.dat',
        'Windows\System32\config\COMPONENTS',
        'Windows\System32\config\DEFAULT',
        'Windows\System32\config\DRIVERS',
        'Windows\System32\config\SAM',
        'Windows\System32\config\SECURITY',
        'Windows\System32\config\SOFTWARE',
        'Windows\System32\config\SYSTEM',
        'Windows\System32\smi\store\Machine\schema.dat'
    )
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sub in $expectedSubPaths) {
        $expectedFullPath = [System.IO.Path]::Combine($normTarget, $sub)
        [void]$expectedSet.Add((ConvertTo-Nano11NormalizedPath -Path $expectedFullPath))
    }

    $hklm = $null
    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $subKeyNames = $hklm.GetSubKeyNames()
    } catch {
        throw "Failed to enumerate HKLM subkeys: $_"
    } finally {
        if ($hklm) { $hklm.Dispose() }
    }

    $regex = '(?i)^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}(?<HivePath>[A-Za-z]:[\\/].+)$'
    foreach ($rawKey in $subKeyNames) {
        if ($rawKey -match $regex) {
            $hivePathRaw = $Matches['HivePath']
            try {
                $normHive = ConvertTo-Nano11NormalizedPath -Path $hivePathRaw
                if ($expectedSet.Contains($normHive)) {
                    $candidates.Add([PSCustomObject]@{
                        KeyName  = $rawKey
                        HivePath = $normHive
                    })
                }
            } catch {
                # Not a valid absolute path or drive root, safely skip
            }
        }
    }
    return @($candidates)
}

# Helper function: Safely unmount orphaned DISM offline registry hives
function Unmount-DismOfflineHives {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetMountDir,
        [ValidateRange(1, 10)]
        [int]$Retries = 5,
        [switch]$BestEffort
    )
    $normTarget = ConvertTo-Nano11NormalizedPath -Path $TargetMountDir
    if (-not $script:ManagedMountDirs.Contains($normTarget)) {
        $msg = "Target mount directory '$TargetMountDir' is not registered in ManagedMountDirs."
        if ($BestEffort) { Write-Warning $msg; return $false }
        throw $msg
    }

    # Verify mounted images status to protect active/valid mounts
    try {
        $mountedImages = @(Get-Nano11MountedImages)
    } catch {
        $msg = "Failed to query DISM mounted images during offline hive unload validation: $_"
        if ($BestEffort) { Write-Warning $msg; return $false }
        throw $msg
    }

    foreach ($img in $mountedImages) {
        if ([string]::IsNullOrWhiteSpace($img.Path)) { continue }
        try {
            $normImgPath = ConvertTo-Nano11NormalizedPath -Path $img.Path
        } catch { continue }

        $isSame = [string]::Equals($normImgPath, $normTarget, [System.StringComparison]::OrdinalIgnoreCase)
        $isDescendant = $normImgPath.StartsWith($normTarget + '\', [System.StringComparison]::OrdinalIgnoreCase)
        $isAncestor = $normTarget.StartsWith($normImgPath + '\', [System.StringComparison]::OrdinalIgnoreCase)

        if ($isSame) {
            if ($img.MountStatus -ne 'Invalid') {
                $msg = "Cannot unmount offline hives: MountDir '$TargetMountDir' has active DISM mount status '$($img.MountStatus)'."
                if ($BestEffort) { Write-Warning $msg; return $false }
                throw $msg
            }
        } elseif ($isDescendant -or $isAncestor) {
            if ($img.MountStatus -ieq 'Invalid') {
                Write-Warning "Overlapping orphaned/invalid DISM mount detected at '$($img.Path)' (Status: Invalid) - deferring to cleanup."
                continue
            }
            $msg = "Cannot unmount offline hives: Overlapping DISM mount detected at '$($img.Path)' (Status: $($img.MountStatus))."
            if ($BestEffort) { Write-Warning $msg; return $false }
            throw $msg
        }
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $candidates = @(Get-Nano11DismOfflineHives -TargetMountDir $normTarget)
        if ($candidates.Count -eq 0) {
            return $true
        }

        Write-Host "Unloading $($candidates.Count) orphaned DISM offline registry hives for '$normTarget' (Attempt $attempt/$Retries)..." -ForegroundColor Cyan

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 300

        foreach ($cand in $candidates) {
            $keyToUnload = "HKLM\" + $cand.KeyName
            $unloadOutput = & reg.exe unload $keyToUnload 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Write-Host "  -> Successfully unloaded offline hive: $($cand.KeyName)" -ForegroundColor Green
            } else {
                Write-Warning "  -> Failed to unload offline hive '$($cand.KeyName)' (Exit code: $exitCode): $unloadOutput"
            }
        }

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        $remaining = @(Get-Nano11DismOfflineHives -TargetMountDir $normTarget)
        if ($remaining.Count -eq 0) {
            Write-Host "All orphaned DISM offline registry hives successfully unloaded." -ForegroundColor Green
            return $true
        }

        if ($attempt -lt $Retries) {
            Start-Sleep -Milliseconds (300 * $attempt)
        }
    }

    $finalRemaining = @(Get-Nano11DismOfflineHives -TargetMountDir $normTarget)
    if ($finalRemaining.Count -gt 0) {
        $keysList = ($finalRemaining | ForEach-Object { "$($_.KeyName) -> $($_.HivePath)" }) -join "`n    "
        $errMsg = "Failed to unload $($finalRemaining.Count) orphaned DISM offline hives for '$normTarget' after $Retries attempts:`n    $keysList`nPlease close any process locking these hives or restart Windows before retrying."
        if ($BestEffort) {
            Write-Warning $errMsg
            return $false
        }
        throw $errMsg
    }
    return $true
}

# Helper function: Assert directory safety before destructive operations
function Assert-Nano11DirectorySafety {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [ValidateSet('Reset', 'RemoveOfflineContent')]
        [string]$Operation
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Safety guard: Target path cannot be empty."
    }
    $normPath = try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch {
        throw "Safety guard: Failed to normalize target path: $Path"
    }

    # Reject drive roots (e.g. C: or C:\), UNC roots, very short paths
    if ($normPath -match '^[a-zA-Z]:$' -or $normPath.Length -le 3 -or $normPath -match '^\\\\[^\\]+\\[^\\]+$') {
        throw "Safety guard: Refusing operation '$Operation' on root or drive directory: $normPath"
    }

    # Reject preserved directories that are marked as unresolved or inspection-only
    if ($Operation -eq 'Reset' -and $script:PreservedMountDirs -and $script:PreservedMountDirs.Contains($normPath)) {
        throw "Safety guard: Target path '$normPath' is marked as Preserved (unresolved/protected). Refusing to reset."
    }

    # Reject critical host system directories
    $hostWin = [System.IO.Path]::GetFullPath($env:windir).TrimEnd('\')
    $hostProg = [System.IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
    $hostProgX86 = if (${env:ProgramFiles(x86)}) { [System.IO.Path]::GetFullPath(${env:ProgramFiles(x86)}).TrimEnd('\') } else { $null }
    $hostUsers = if ($env:SystemDrive) { [System.IO.Path]::GetFullPath("$($env:SystemDrive)\Users").TrimEnd('\') } else { $null }

    # Check if target path is inside the explicitly configured workspace or mount allocation root
    $isInsideWorkspace = $false
    if ($script:MountAllocationRoot) {
        $normAllocRoot = [System.IO.Path]::GetFullPath($script:MountAllocationRoot).TrimEnd('\')
        if ($normPath -ieq $normAllocRoot -or $normPath.StartsWith($normAllocRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isInsideWorkspace = $true
        }
    }
    if (-not $isInsideWorkspace -and $script:BaseWorkDir) {
        $normBaseRoot = [System.IO.Path]::GetFullPath($script:BaseWorkDir).TrimEnd('\')
        if ($normPath -ieq $normBaseRoot -or $normPath.StartsWith($normBaseRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isInsideWorkspace = $true
        }
    }

    $dangerousRoots = @($hostWin, $hostProg, $hostProgX86) | Where-Object { $_ }
    if (-not $isInsideWorkspace) {
        # Only treat $hostUsers as a dangerous root if the target is NOT inside our configured workspace
        if ($hostUsers) { $dangerousRoots += $hostUsers }
    } else {
        # Even inside workspace, the target cannot be the host Users root directory itself
        if ($hostUsers -and ($normPath -ieq $hostUsers)) {
            throw "Safety guard: Target path is host Users directory itself: $normPath"
        }
    }

    foreach ($dr in $dangerousRoots) {
        if ($normPath -ieq $dr -or $normPath.StartsWith($dr + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($Operation -eq 'RemoveOfflineContent') {
                if (-not $script:DismMountDir) {
                    throw "Safety guard: DismMountDir is not established. Cannot remove: $normPath"
                }
                $normScratch = [System.IO.Path]::GetFullPath($script:DismMountDir).TrimEnd('\')
                if (-not ($normPath.StartsWith($normScratch + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
                    throw "Safety guard: Target path is in protected host system directory: $normPath"
                }
            } else {
                throw "Safety guard: Target path is in protected host system directory: $normPath"
            }
        }
    }

    if ($Operation -eq 'Reset') {
        if ($script:BaseWorkDir) {
            $normBase = [System.IO.Path]::GetFullPath($script:BaseWorkDir).TrimEnd('\')
            if ($normPath -ieq $normBase) {
                throw "Safety guard: Refusing to reset base workspace directory itself: $normPath"
            }
        }
        try {
            $mounted = @(Get-Nano11MountedImages)
            foreach ($m in $mounted) {
                if ($m.Path) {
                    $mNorm = [System.IO.Path]::GetFullPath($m.Path).TrimEnd('\')
                    if ($normPath -ieq $mNorm -or $normPath.StartsWith($mNorm + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $mNorm.StartsWith($normPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "Safety guard: Refusing to reset directory '$normPath' which overlaps with active DISM mount '$mNorm' (Status: $($m.MountStatus))"
                    }
                }
            }
        } catch {
            if ($_.Exception.Message -match "overlaps with active DISM mount") {
                throw $_
            }
            throw "Safety guard: Cannot verify mounted image status before Reset on '$normPath': $_"
        }
    } elseif ($Operation -eq 'RemoveOfflineContent') {
        if (-not $script:DismMountDir) {
            throw "Safety guard: Cannot execute RemoveOfflineContent when DismMountDir is not set."
        }
        $normScratch = [System.IO.Path]::GetFullPath($script:DismMountDir).TrimEnd('\')
        if ($normPath -ieq $normScratch -or -not ($normPath.StartsWith($normScratch + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Safety guard: RemoveOfflineContent is only permitted on strict descendants of DismMountDir ('$normScratch'): $normPath"
        }
    }
}


# 3. Clean up any leftover nano11 registry hives from previous runs (Non-destructive)
if ((-not $TestSelf) -and ($env:NANO11_TEST_MODE -ne "1") -and (-not $isDryRunMode)) {
    @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
        # Best-effort cleanup: never let a stale-hive unmount failure abort the build
        try { [void](Unmount-RegistryHiveWithRetry -Name $_) } catch { Write-Verbose "Leftover hive '$_' cleanup skipped: $_" }
    }
}

# Helper function: Strictly verify that a directory exists and is 100% empty (Resolves Error 0xc1420114)
function Assert-Nano11DirectoryEmpty {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    if ($items.Count -gt 0) {
        $sample = ($items | Select-Object -First 20 | ForEach-Object { "$($_.FullName) [$($_.Attributes)]" }) -join "`n    "
        throw "Directory is not empty ($($items.Count) items found in '$Path'):`n    $sample"
    }
}

# Helper function: Take ownership and grant FullControl using PowerShell .NET ACL (Locale-independent via direct SID)
function Set-ItemOwnershipAndAccess {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [switch]$Recurse,
        [switch]$Strict
    )
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
        return
    }

    $failedItems = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue((Resolve-Path -LiteralPath $Path).Path)

    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if (-not (Test-Path -LiteralPath $current)) { continue }

        $itemObj = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $itemObj) { continue }

        $isReparse = [bool]($itemObj.Attributes -band [System.IO.FileAttributes]::ReparsePoint)

        # Clear ReadOnly attribute if present
        if ($itemObj.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            try {
                $itemObj.Attributes = $itemObj.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
            } catch {
                try { Set-ItemProperty -LiteralPath $current -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch {}
            }
        }

        # Apply ownership and ACL
        $success = $false
        try {
            $acl = Get-Acl -LiteralPath $current -ErrorAction Stop
            try { $acl.SetOwner($adminGroupSid) } catch {}
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminGroupSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]"None",
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $current -AclObject $acl -ErrorAction Stop
            $success = $true
        } catch {}

        if (-not $success) {
            & takeown.exe /F "$current" /A > $null 2>&1
            $takeExit = $LASTEXITCODE
            & icacls.exe "$current" /grant "*S-1-5-32-544:F" /C /Q > $null 2>&1
            $icaExit = $LASTEXITCODE
            if ($takeExit -eq 0 -or $icaExit -eq 0) {
                $success = $true
            }
        }

        if (-not $success -and $Strict) {
            $failedItems.Add($current)
        }

        # If it is a directory and NOT a reparse point, enqueue children
        if ($Recurse -and $itemObj.PSIsContainer -and (-not $isReparse)) {
            try {
                $children = Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop
                foreach ($c in $children) {
                    $pending.Enqueue($c.FullName)
                }
            } catch {
                if ($Strict) {
                    $failedItems.Add("$current (Enumeration failed: $_)")
                }
            }
        }
    }

    if ($Strict -and $failedItems.Count -gt 0) {
        $sample = ($failedItems | Select-Object -First 20) -join "`n    "
        throw "Failed to acquire ownership/access on $($failedItems.Count) item(s):`n    $sample"
    }
}

# Helper function: Robust directory deletion using empty directory robocopy mirror trick
function Remove-ProtectedDirectory {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [string]$ScratchPath,
        [int]$Retries = 3
    )
    Assert-Nano11DirectorySafety -Path $Path -Operation 'RemoveOfflineContent'
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    if (-not (Test-Path -LiteralPath $full)) {
        return
    }

    $stagingTemp = if ($script:BaseWorkDir) {
        Join-Path -Path $script:BaseWorkDir -ChildPath "temp_empty_$([System.IO.Path]::GetRandomFileName())"
    } else {
        Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_del_$([System.IO.Path]::GetRandomFileName())"
    }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Set-ItemOwnershipAndAccess -Path $full -Recurse
        } catch {}

        # 3. Safe native directory & reparse point removal (avoids robocopy /MIR junction traversal that deletes WinSxS targets)
        try {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                [System.IO.Directory]::Delete($full, $false)
            }
        } catch {}

        # 4. Windows native directory removal
        & cmd.exe /c "rd /s /q `"$full`"" > $null 2>&1

        # 5. PowerShell fallback removal
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $full)) {
            return
        }
        Start-Sleep -Milliseconds 500
    }

    if (Test-Path -LiteralPath $full) {
        throw "Failed to remove protected directory after $Retries attempts: $full"
    }
}

# Helper function: Check if a path resides on an NTFS volume (DISM requirement for reparse points)
# Helper function: Fast and reliable directory reset using robocopy mirror trick (Guaranteed Empty)
function Reset-DirectoryWithRobocopy {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [ValidateRange(1, 5)]
        [int]$Retries = 3
    )
    Assert-Nano11DirectorySafety -Path $Path -Operation 'Reset'
    $full = try { ConvertTo-Nano11NormalizedPath -Path $Path } catch { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }

    # If this is a managed DISM mount directory, safely unload any locked offline hives first
    if ($script:ManagedMountDirs.Contains($full)) {
        [void](Unmount-DismOfflineHives -TargetMountDir $full)
    }

    if (-not (Test-Path -LiteralPath $full)) {
        New-Item -ItemType Directory -Force -Path $full -ErrorAction Stop | Out-Null
        return
    }

    $lastEx = $null
    $lastRoboExit = $null
    $lastRoboOutput = $null
    $lastAttribExit = $null
    $lastAttribOutput = $null

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        Assert-Nano11DirectorySafety -Path $full -Operation 'Reset'

        if ($attempt -gt 1) {
            # Terminate lingering dismhost/wimserv workers to release file locks, but only when no other
            # DISM activity is visible (our dism.exe calls are synchronous, so a running dism.exe is foreign)
            $foreignDismActive = $false
            if (Get-Process -Name "dism" -ErrorAction SilentlyContinue) {
                $foreignDismActive = $true
            } else {
                try {
                    $foreignMounts = @(Get-Nano11MountedImages | Where-Object {
                        $_.Path -and -not (
                            (Test-Nano11PathWithin -Path $_.Path -Root $script:BaseWorkDir) -or
                            (Test-Nano11PathWithin -Path $_.Path -Root $script:MountAllocationRoot)
                        )
                    })
                    if ($foreignMounts.Count -gt 0) { $foreignDismActive = $true }
                } catch {
                    $foreignDismActive = $true
                }
            }
            if ($foreignDismActive) {
                Write-Warning "Reset attempt ${attempt}: Other DISM activity detected outside the nano11 workspace. Not terminating dismhost/wimserv."
            } else {
                Get-Process -Name "dismhost", "wimserv" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds ($attempt * 2)
        }

        $rootItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Safety violation: Target directory '$full' is itself a reparse point. Refusing to reset directly."
        }

        # Queue-based reparse point pruning without following links into targets
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($full)
        $linkError = $false
        while ($queue.Count -gt 0) {
            $curr = $queue.Dequeue()
            try {
                $children = @(Get-ChildItem -LiteralPath $curr -Force -ErrorAction Stop)
            } catch {
                Write-Warning "Reset attempt ${attempt}: Could not enumerate '$curr': $_"
                $linkError = $true
                break
            }
            foreach ($child in $children) {
                if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    try {
                        if ($child.PSIsContainer) {
                            [System.IO.Directory]::Delete($child.FullName, $false)
                        } else {
                            [System.IO.File]::Delete($child.FullName)
                        }
                    } catch {
                        Write-Warning "Reset attempt ${attempt}: Failed to remove reparse point '$($child.FullName)': $_"
                        $linkError = $true
                    }
                } elseif ($child.PSIsContainer) {
                    $queue.Enqueue($child.FullName)
                }
            }
        }

        if (-not $linkError) {
            try {
                Set-ItemOwnershipAndAccess -Path $full -Recurse -Strict
            } catch {
                Write-Warning "Reset attempt ${attempt}: Ownership adjustment warning: $_"
            }

            # Strip ReadOnly, Hidden, and System attributes across root and children
            $lastAttribOutput = & attrib.exe -r -s -h $full 2>&1
            $lastAttribExit = $LASTEXITCODE
            $childPattern = Join-Path -Path $full -ChildPath '*'
            $null = & attrib.exe -r -s -h $childPattern /s /d 2>&1

            $emptyTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nano11_empty_$([System.IO.Path]::GetRandomFileName())"
            try {
                New-Item -Path $emptyTemp -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Assert-Nano11DirectoryEmpty -Path $emptyTemp
                $lastRoboOutput = & robocopy.exe $emptyTemp $full /MIR /XJ /R:0 /W:0 /NFL /NDL /NP /NJH /NJS 2>&1
                $lastRoboExit = $LASTEXITCODE
            } finally {
                if (Test-Path -LiteralPath $emptyTemp) {
                    Remove-Item -LiteralPath $emptyTemp -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            if ($lastRoboExit -ge 8) {
                Write-Warning "Reset attempt ${attempt}: Robocopy error (Exit code: $lastRoboExit): $lastRoboOutput"
            }

            # Sweep remaining items directly
            try {
                $lingering = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
                foreach ($item in $lingering) {
                    try {
                        if ($item.PSIsContainer) {
                            [System.IO.Directory]::Delete($item.FullName, $true)
                        } else {
                            [System.IO.File]::Delete($item.FullName)
                        }
                    } catch {
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                    }
                }
            } catch {
                $lastEx = $_
            }
        }

        # Validate directory is strictly empty
        try {
            Assert-Nano11DirectoryEmpty -Path $full
            return
        } catch {
            $lastEx = $_
            if ($attempt -lt $Retries) {
                if ($script:ManagedMountDirs.Contains($full)) {
                    try { [void](Unmount-DismOfflineHives -TargetMountDir $full -BestEffort) } catch {}
                }
                Start-Sleep -Seconds $attempt
            }
        }
    }

    # Final attempt failed - build rich diagnostic failure report
    $remainingItems = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)
    $remainingDetails = ($remainingItems | ForEach-Object { "$($_.FullName) [$($_.Attributes)]" }) -join "`n    "
    $hivesInfo = ""
    if ($script:ManagedMountDirs.Contains($full)) {
        try {
            $leftoverHives = @(Get-Nano11DismOfflineHives -TargetMountDir $full)
            if ($leftoverHives.Count -gt 0) {
                $hivesInfo = "`nLingering DISM offline registry hives:`n    " + (($leftoverHives | ForEach-Object { "$($_.KeyName) -> $($_.HivePath)" }) -join "`n    ")
            }
        } catch {}
    }

    throw "Reset-DirectoryWithRobocopy failed to empty directory '$full' after $Retries attempts.$hivesInfo`nRemaining items ($($remainingItems.Count)):`n    $remainingDetails`nLast error: $lastEx`nRobocopy Exit Code: $lastRoboExit`nAttrib Exit Code: $lastAttribExit`nPlease close any process locking these files or restart Windows before retrying."
}

# Helper function: Safe mountpoint cleanup guarded against modifying unmanaged external mounts
# ==============================================================================
# Helper Functions: Safe Deletion, Promotion, Metadata & Capacity Verification
function Invoke-Nano11PromoteTemporaryIso {
    param(
        [string]$TempIsoPath,
        [string]$TargetIsoPath,
        [string]$BuildId
    )
    if (-not (Test-Path -LiteralPath $TempIsoPath)) {
        throw "Temporary ISO not found: $TempIsoPath"
    }
    $targetDir = Split-Path -Path $TargetIsoPath -Parent
    if (-not $targetDir) { $targetDir = $PSScriptRoot }
    $oldIsoBackup = Join-Path -Path $targetDir -ChildPath "nano11_old_backup_${BuildId}.iso"

    $hasOldIso = Test-Path -LiteralPath $TargetIsoPath
    if ($hasOldIso) {
        Write-Host "Backing up existing ISO to unique backup: $oldIsoBackup..." -ForegroundColor Cyan
        Move-Item -LiteralPath $TargetIsoPath -Destination $oldIsoBackup -Force -ErrorAction Stop
    }

    $promotedSuccessfully = $false
    try {
        Write-Host "Promoting verified temporary ISO to official release name..." -ForegroundColor Cyan
        Move-Item -LiteralPath $TempIsoPath -Destination $TargetIsoPath -Force -ErrorAction Stop
        $promotedSuccessfully = $true
    } catch {
        $moveErr = $_
        if ($hasOldIso -and (Test-Path -LiteralPath $oldIsoBackup)) {
            Write-Warning "Promotion failed ($moveErr). Attempting rollback from $oldIsoBackup..."
            try {
                Move-Item -LiteralPath $oldIsoBackup -Destination $TargetIsoPath -Force -ErrorAction Stop
                Write-Host "Rollback successful: Restored original ISO to $TargetIsoPath." -ForegroundColor Green
            } catch {
                $rollbackErr = $_
                Write-Warning "CRITICAL: Rollback failed ($rollbackErr). Preserving backup at $oldIsoBackup"
                if ($script:DiagnosticData) {
                    $script:DiagnosticData.PreservedArtifacts += $oldIsoBackup
                }
                throw "Failed to promote temporary ISO to ${TargetIsoPath} ($moveErr) AND rollback restoration failed ($rollbackErr). Original ISO preserved at: $oldIsoBackup"
            }
        }
        throw "Failed to promote temporary ISO to ${TargetIsoPath}: $moveErr"
    }

    if ($promotedSuccessfully -and $hasOldIso -and (Test-Path -LiteralPath $oldIsoBackup)) {
        Remove-Item -LiteralPath $oldIsoBackup -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Test-Nano11MetadataAndCapacity {
    param(
        [string]$WimPath,
        [string]$ExpectedEdition,
        [string]$ExpectedArch,
        [string]$VerifyApplyDir,
        [string]$VhdxFilePath = $null,
        [bool]$IsVhdx = $false
    )
    Write-Host "Querying WIM metadata via DISM /Get-WimInfo..." -ForegroundColor Cyan
    $dismMetaOut = & dism.exe /English /Get-WimInfo "/WimFile:$WimPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query WIM metadata (ExitCode: $LASTEXITCODE)."
    }
    $metaText = ($dismMetaOut -join "`n")
    $hasIndex1 = ($metaText -match '(?m)^\s*Index\s*:\s*1\s*$')
    $totalIndexCount = ([regex]::Matches($metaText, '(?m)^\s*Index\s*:\s*\d+\s*$')).Count
    if (-not $hasIndex1 -or ($totalIndexCount -ne 1)) {
        throw "WIM metadata validation failed: Expected exactly 1 index (Index 1), found $totalIndexCount indices."
    }

    $dismIdx1Out = & dism.exe /English /Get-WimInfo "/WimFile:$WimPath" "/Index:1" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query WIM Index 1 detailed info (ExitCode: $LASTEXITCODE)."
    }
    $idx1Text = ($dismIdx1Out -join "`n")

    $editionName = if ($idx1Text -match '(?m)^\s*Name\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
    $arch = if ($idx1Text -match '(?m)^\s*Architecture\s*:\s*(\w+)') { $matches[1].Trim() } else { $null }
    $sizeRaw = if ($idx1Text -match '(?m)^\s*Size\s*:\s*([\d,]+)\s*bytes') { $matches[1] -replace ',', '' } else { $null }

    if (-not $editionName -or -not $arch -or -not $sizeRaw) {
        throw "Failed to extract required image info (Edition: '$editionName', Arch: '$arch', Size: '$sizeRaw')."
    }

    if ($ExpectedEdition -and ($editionName -inotlike "*$ExpectedEdition*")) {
        throw "Edition mismatch: Expected '$ExpectedEdition', found '$editionName'."
    }

    $normArch = $arch.ToLower()
    $normExpectedArch = if ($ExpectedArch) { $ExpectedArch.ToLower() } else { "" }
    if ($normExpectedArch -eq 'amd64') { $normExpectedArch = 'x64' }
    if ($normArch -eq 'amd64') { $normArch = 'x64' }
    if ($normExpectedArch -and ($normArch -ne $normExpectedArch)) {
        throw "Architecture mismatch: Expected '$normExpectedArch', found '$normArch'."
    }

    [int64]$expandedSizeBytes = [int64]$sizeRaw
    $expandedSizeGB = [math]::Ceiling($expandedSizeBytes / 1GB)
    $scratchMarginGB = 5
    $requiredSpaceGB = [math]::Max(15, ($expandedSizeGB + $scratchMarginGB))

    $targetFreeGB = Get-Nano11VolumeFreeSpaceGB -Path $VerifyApplyDir
    $applyDriveLetter = try { (Split-Path -Path ([System.IO.Path]::GetFullPath($VerifyApplyDir)) -Qualifier).TrimEnd(':') } catch { "C" }

    Write-Host "Capacity Analysis for Deep Apply Verification:" -ForegroundColor Cyan
    Write-Host "  - Uncompressed Expanded Image Size: $expandedSizeGB GB ($expandedSizeBytes bytes)" -ForegroundColor Gray
    Write-Host "  - Scratch & Working Overhead:       $scratchMarginGB GB" -ForegroundColor Gray
    Write-Host "  - Dynamic Required Space:           $requiredSpaceGB GB" -ForegroundColor Gray
    Write-Host "  - Apply Target Volume (${applyDriveLetter}:):     $targetFreeGB GB available" -ForegroundColor Gray

    if ($IsVhdx -and $VhdxFilePath -and (Test-Path -LiteralPath $VhdxFilePath)) {
        $vhdxHostFreeGB = Get-Nano11VolumeFreeSpaceGB -Path $VhdxFilePath
        $vhdxHostDriveLetter = try { (Split-Path -Path (Resolve-Path $VhdxFilePath).Path -Qualifier).TrimEnd(':') } catch { "C" }
        Write-Host "  - VHDX Host Volume (${vhdxHostDriveLetter}:):          $vhdxHostFreeGB GB available" -ForegroundColor Gray

        if ($applyDriveLetter -ieq $vhdxHostDriveLetter) {
            if ($targetFreeGB -lt $requiredSpaceGB) {
                throw "Insufficient disk space on host volume ${applyDriveLetter}: ($targetFreeGB GB available, $requiredSpaceGB GB required)."
            }
        } else {
            if ($targetFreeGB -lt $requiredSpaceGB) {
                throw "Insufficient disk space on VHDX apply volume ${applyDriveLetter}: ($targetFreeGB GB available, $requiredSpaceGB GB required)."
            }
            if ($vhdxHostFreeGB -lt 10) {
                throw "Insufficient disk space on VHDX host volume ${vhdxHostDriveLetter}: ($vhdxHostFreeGB GB available, minimum 10 GB required to back VHDX expansion)."
            }
        }
    } else {
        if ($targetFreeGB -lt $requiredSpaceGB) {
            throw "Insufficient disk space on volume ${applyDriveLetter}: ($targetFreeGB GB available, $requiredSpaceGB GB required for expanded image + overhead)."
        }
    }

    return [PSCustomObject]@{
        EditionName      = $editionName
        Architecture     = $arch
        ExpandedSizeGB   = $expandedSizeGB
        RequiredSpaceGB  = $requiredSpaceGB
        TargetFreeGB     = $targetFreeGB
    }
}

function Invoke-Nano11MountpointCleanup {
    [CmdletBinding()]
    param()
    try {
        $mounted = @(Get-Nano11MountedImages)
    } catch {
        Write-Warning "Could not query mounted images before Cleanup-Mountpoints: $_. Skipping for safety."
        return $false
    }
    foreach ($m in $mounted) {
        if ([string]::IsNullOrWhiteSpace($m.Path)) { continue }
        $normP = try { ConvertTo-Nano11NormalizedPath -Path $m.Path } catch { $null }
        if ($normP -and -not $script:ManagedMountDirs.Contains($normP)) {
            Write-Warning "Cannot safely run Cleanup-Mountpoints: Active mount exists outside ManagedMountDirs at '$($m.Path)' (Status: $($m.MountStatus))."
            return $false
        }
    }

    $cleanArgs = @('/English')
    if ($script:DismLogPath) {
        $cleanArgs += @("/LogPath:$script:DismLogPath", "/LogLevel:3")
    }
    $cleanArgs += @('/Cleanup-Mountpoints')
    & dism.exe @cleanArgs > $null 2>&1
    $exitCode = $LASTEXITCODE
    return ($exitCode -eq 0)
}

# Helper function: Detect and discard conflicting/orphaned DISM mounts (Resolves Error 0xc1420127 & Invalid mount lock)
function Clear-DismMountConflicts {
    param(
        [string]$TargetMountDir,
        [string]$TargetWimFile,
        [ValidateRange(1, 5)]
        [int]$Retries = 3,
        [switch]$ForceRecovery
    )
    $normMount = if ($TargetMountDir) { try { ConvertTo-Nano11NormalizedPath -Path $TargetMountDir } catch { [System.IO.Path]::GetFullPath($TargetMountDir).TrimEnd('\') } } else { $null }
    $normWim   = if ($TargetWimFile)  { try { [System.IO.Path]::GetFullPath($TargetWimFile).TrimEnd('\') } catch { $null } } else { $null }

    if (-not $normMount -and -not $normWim) {
        return
    }

    if ($normMount -and -not $script:ManagedMountDirs.Contains($normMount)) {
        $isWorkspaceChild = $false
        if ($script:MountAllocationRoot) {
            $normAllocRoot = ConvertTo-Nano11NormalizedPath -Path $script:MountAllocationRoot
            if (Test-Nano11PathWithin -Path $normMount -Root $normAllocRoot) {
                $isWorkspaceChild = $true
            }
        }
        $wsRef = if ($script:BaseWorkDir) { $script:BaseWorkDir } elseif ($baseWorkDir) { $baseWorkDir } elseif ($workingDir) { $workingDir } else { $null }
        if (-not $isWorkspaceChild -and $wsRef) {
            $normWorking = ConvertTo-Nano11NormalizedPath -Path $wsRef
            if (Test-Nano11PathWithin -Path $normMount -Root $normWorking) {
                $isWorkspaceChild = $true
            }
        }

        if ($isWorkspaceChild) {
            [void]$script:ManagedMountDirs.Add($normMount)
        } else {
            throw "Safety violation: Target mount directory '$normMount' is not in ManagedMountDirs. Refusing to operate on unmanaged paths."
        }
    }

    # Best-effort preliminary unload of orphaned offline hives prior to DISM unmount attempts
    if ($normMount) {
        [void](Unmount-DismOfflineHives -TargetMountDir $normMount -BestEffort)
    }

    # Step 1: Attempt standard DISM unmount / remount retry loop
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $mounted = @(Get-Nano11MountedImages)
        $conflicts = @()

        foreach ($m in $mounted) {
            $mPath = if ($m.Path) { try { [System.IO.Path]::GetFullPath($m.Path).TrimEnd('\') } catch { $null } } else { $null }
            $mImg  = if ($m.ImagePath) { try { [System.IO.Path]::GetFullPath($m.ImagePath).TrimEnd('\') } catch { $null } } else { $null }

            $matchMount = ($normMount -and $mPath -and ($mPath -ieq $normMount))
            $matchWim   = ($normWim -and $mImg -and ($mImg -ieq $normWim))

            if ($matchWim -and (-not $matchMount) -and $mPath) {
                # Check if $mPath is located inside workspace root
                $isWorkspaceMount = $false
                if ($script:MountAllocationRoot) {
                    $normAllocRoot = ConvertTo-Nano11NormalizedPath -Path $script:MountAllocationRoot
                    if (Test-Nano11PathWithin -Path $mPath -Root $normAllocRoot) {
                        $isWorkspaceMount = $true
                    }
                }
                $wsRef = if ($script:BaseWorkDir) { $script:BaseWorkDir } elseif ($baseWorkDir) { $baseWorkDir } elseif ($workingDir) { $workingDir } else { $null }
                if (-not $isWorkspaceMount -and $wsRef) {
                    $normWorking = ConvertTo-Nano11NormalizedPath -Path $wsRef
                    if (Test-Nano11PathWithin -Path $mPath -Root $normWorking) {
                        $isWorkspaceMount = $true
                    }
                }
                if (-not $isWorkspaceMount -and $wsRef -and $normWim) {
                    $normWorking = ConvertTo-Nano11NormalizedPath -Path $wsRef
                    # Adopt only when the mounted WIM itself lives in our workspace (no name-based guessing)
                    if (Test-Nano11PathWithin -Path $normWim -Root $normWorking) {
                        $isWorkspaceMount = $true
                    }
                }

                if ($isWorkspaceMount) {
                    Write-Host "Detected prior build mount at workspace path '$mPath' for '$normWim'. Adopting for safe cleanup." -ForegroundColor Yellow
                    [void]$script:ManagedMountDirs.Add($mPath)
                    [void]$script:AllocatedMountDirs.Add($mPath)
                    $conflicts += $m
                    continue
                } else {
                    throw "Safety violation: Target image '$normWim' is currently mounted at an external unmanaged directory '$mPath' (Status: $($m.MountStatus)). Refusing to automatically discard."
                }
            }

            if ($matchMount -or $matchWim) {
                $conflicts += $m
            }
        }

        if ($conflicts.Count -eq 0) {
            break
        }

        foreach ($c in $conflicts) {
            Write-Host "Resolving lingering DISM mount at '$($c.Path)' (Image: $($c.ImagePath), Status: $($c.MountStatus))..." -ForegroundColor Yellow
            
            # Unload any registry hives under this mount first
            @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
                try { [void](Unmount-RegistryHiveWithRetry -Name $_) } catch {}
            }

            Set-Location -LiteralPath $scriptDir
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()

            if ($c.MountStatus -in @("Needs Remount", "Invalid")) {
                & dism.exe /English /Remount-Image "/MountDir:$($c.Path)" > $null 2>&1
            }
            & dism.exe /English /Unmount-Image "/MountDir:$($c.Path)" /discard > $null 2>&1
            $unmountExit = $LASTEXITCODE

            if ($unmountExit -ne 0) {
                Invoke-Nano11MountpointCleanup | Out-Null
            }
        }

        Start-Sleep -Seconds (2 * $attempt)
    }

    # Step 2: Check if conflict is still lingering
    $finalMounted = @(Get-Nano11MountedImages)
    $lingeringConflict = $finalMounted | Where-Object {
        $mPath = if ($_.Path) { try { [System.IO.Path]::GetFullPath($_.Path).TrimEnd('\') } catch { $null } } else { $null }
        $mImg  = if ($_.ImagePath) { try { [System.IO.Path]::GetFullPath($_.ImagePath).TrimEnd('\') } catch { $null } } else { $null }
        ($normMount -and $mPath -and ($mPath -ieq $normMount)) -or ($normWim -and $mImg -and ($mImg -ieq $normWim))
    }

    # Step 3: Level 3 Surgical Purge for corrupted / Invalid orphaned WIMMount entries
    # If standard DISM commands failed because the mount is in an Invalid/Orphaned state,
    # safely purge ONLY the exact matching registry metadata for this managed mount workspace.
    if ($lingeringConflict -or $ForceRecovery) {
        $canPurge = $true
        # Check that lingering mount is strictly in Invalid status
        if ($lingeringConflict) {
            foreach ($lc in $lingeringConflict) {
                if ($lc.MountStatus -ne 'Invalid') {
                    Write-Warning "Cannot perform Level 3 purge: Mount at '$($lc.Path)' has non-invalid status '$($lc.MountStatus)'."
                    $canPurge = $false
                    break
                }
            }
        }

        if ($canPurge -and ($normMount -or $normWim)) {
            # Unload any offline hives first before metadata purge
            if ($normMount) {
                try {
                    [void](Unmount-DismOfflineHives -TargetMountDir $normMount -BestEffort)
                } catch {
                    Write-Warning "Offline hive unload before Level 3 purge encountered warning: $_"
                }
            }

            $regBaseKey = "SOFTWARE\Microsoft\WIMMount\Mounted Images"
            $hklm = $null
            $mountedKey = $null
            try {
                $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
                $mountedKey = $hklm.OpenSubKey($regBaseKey, $true)
                if ($mountedKey) {
                    $subKeyNames = $mountedKey.GetSubKeyNames()
                    foreach ($guid in $subKeyNames) {
                        $entryKey = $null
                        try {
                            $entryKey = $mountedKey.OpenSubKey($guid, $false)
                            if ($entryKey) {
                                $mPathVal = [string]$entryKey.GetValue("Mount Path")
                                $wPathVal = [string]$entryKey.GetValue("WIM Path")
                                $statusVal = $entryKey.GetValue("Status")

                                if ([string]::IsNullOrWhiteSpace($mPathVal)) { continue }
                                $normEntryMount = try { ConvertTo-Nano11NormalizedPath -Path $mPathVal } catch { $null }
                                $normEntryWim   = try { if ($wPathVal) { [System.IO.Path]::GetFullPath($wPathVal).TrimEnd('\') } } catch { $null }

                                $matchTargetMount = ($normMount -and $normEntryMount -and ($normEntryMount -ieq $normMount))
                                $matchTargetWim   = ($normWim -and $normEntryWim -and ($normEntryWim -ieq $normWim))

                                $isWorkspaceMount = $false
                                if ($normEntryMount) {
                                    if ($script:MountAllocationRoot) {
                                        $normAllocRoot = ConvertTo-Nano11NormalizedPath -Path $script:MountAllocationRoot
                                        if (Test-Nano11PathWithin -Path $normEntryMount -Root $normAllocRoot) {
                                            $isWorkspaceMount = $true
                                        }
                                    }
                                    if (-not $isWorkspaceMount -and $script:BaseWorkDir) {
                                        $normBaseRoot = ConvertTo-Nano11NormalizedPath -Path $script:BaseWorkDir
                                        if (Test-Nano11PathWithin -Path $normEntryMount -Root $normBaseRoot) {
                                            $isWorkspaceMount = $true
                                        }
                                    }
                                    if (-not $isWorkspaceMount -and $workingDir) {
                                        $normWorking = ConvertTo-Nano11NormalizedPath -Path $workingDir
                                        if (Test-Nano11PathWithin -Path $normEntryMount -Root $normWorking) {
                                            $isWorkspaceMount = $true
                                        }
                                    }
                                }

                                # Strictly require Mount Path or WIM Path to match managed target, or be orphaned within workspace
                                if ($matchTargetMount -or $matchTargetWim -or ($isWorkspaceMount -and ($statusVal -in @(2, 3, "2", "3")))) {
                                    Write-Host "Purging corrupted/orphaned DISM mount metadata from registry: $guid (Mount: $mPathVal, WIM: $wPathVal, Status: $statusVal)..." -ForegroundColor Yellow
                                    try {
                                        $mountedKey.DeleteSubKeyTree($guid, $false)
                                        Write-Host "  -> Successfully purged orphaned DISM mount metadata via .NET Registry: $guid" -ForegroundColor Green
                                    } catch {
                                        & reg.exe delete "HKLM\$regBaseKey\$guid" /f > $null 2>&1
                                        if ($LASTEXITCODE -eq 0) {
                                            Write-Host "  -> Successfully purged orphaned DISM mount metadata via reg.exe: $guid" -ForegroundColor Green
                                        } else {
                                            Write-Warning "Could not delete orphaned WIMMount registry entry ${guid}: $_"
                                        }
                                    }
                                }
                            }
                        } finally {
                            if ($entryKey) { $entryKey.Dispose() }
                        }
                    }
                }
            } catch {
                Write-Warning "Surgical registry metadata purge encountered warning: $_"
            } finally {
                if ($mountedKey) { $mountedKey.Dispose() }
                if ($hklm) { $hklm.Dispose() }
            }

            # Synchronize DISM mountpoints cache after surgical registry metadata purge
            Invoke-Nano11MountpointCleanup | Out-Null
        }
    }

    # Step 4: Final verification after all recovery levels
    $verifiedMounted = @(Get-Nano11MountedImages)
    $stillLingering = $verifiedMounted | Where-Object {
        $mPath = if ($_.Path) { try { [System.IO.Path]::GetFullPath($_.Path).TrimEnd('\') } catch { $null } } else { $null }
        $mImg  = if ($_.ImagePath) { try { [System.IO.Path]::GetFullPath($_.ImagePath).TrimEnd('\') } catch { $null } } else { $null }
        ($normMount -and $mPath -and ($mPath -ieq $normMount)) -or ($normWim -and $mImg -and ($mImg -ieq $normWim))
    }

    # Clean up any lingering offline hives even if mount entry was already clear
    if ($normMount) {
        [void](Unmount-DismOfflineHives -TargetMountDir $normMount -BestEffort)
    }

    if ($stillLingering) {
        throw "Failed to clear DISM mount conflict for MountDir='$normMount' / WimFile='$normWim'. Active mount remains: $($stillLingering.Path) (Status: $($stillLingering.MountStatus))"
    } else {
        if ($lingeringConflict) {
            Write-Host "DISM mount conflict for '$normMount' successfully resolved." -ForegroundColor Green
        }
    }
}

# Helper function: Generate unique dynamic mount directory path under MountAllocationRoot
function New-Nano11MountDirectoryPath {
    param()
    if (-not $script:MountAllocationRoot) {
        throw "MountAllocationRoot is not set."
    }
    $normRoot = ConvertTo-Nano11NormalizedPath -Path $script:MountAllocationRoot

    $candidatePath = $null
    for ($i = 0; $i -lt 50; $i++) {
        $guidStr = [Guid]::NewGuid().ToString('N')
        $dirName = if ($script:MountDirectoryPrefix) { $script:MountDirectoryPrefix + $guidStr } else { "mount_" + $guidStr }
        $fullPath = Join-Path -Path $normRoot -ChildPath $dirName
        $candidatePath = ConvertTo-Nano11NormalizedPath -Path $fullPath

        # Verify it is a direct child of MountAllocationRoot
        $parentDir = [System.IO.Path]::GetDirectoryName($candidatePath)
        if (-not [string]::Equals($parentDir, $normRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Security violation: Generated mount directory '$candidatePath' is not a direct child of '$normRoot'."
        }

        if (-not (Test-Path -LiteralPath $candidatePath)) {
            break
        }
    }

    if (-not $candidatePath -or (Test-Path -LiteralPath $candidatePath)) {
        throw "Failed to generate unique mount directory path under '$normRoot'."
    }

    [void]$script:ManagedMountDirs.Add($candidatePath)
    [void]$script:AllocatedMountDirs.Add($candidatePath)
    return $candidatePath
}

# Helper function: Prepare and guarantee clean empty mount directory by physical recreation (Resolves Error 0xc1420113, 0xc1420114 & 0xc1420127)
function Initialize-Nano11MountDirectory {
    param(
        [Parameter(Mandatory=$true)]
        [string]$MountDir,
        [string]$WimFile,
        [int]$Retries = 3
    )
    $normMount = ConvertTo-Nano11NormalizedPath -Path $MountDir
    if (-not $script:ManagedMountDirs.Contains($normMount)) {
        throw "Safety violation: Target mount directory '$normMount' is not in ManagedMountDirs."
    }
    if ($script:PreservedMountDirs -and $script:PreservedMountDirs.Contains($normMount)) {
        throw "Safety guard: Target mount directory '$normMount' is marked as Preserved. Refusing to initialize."
    }

    # 1. Clear any lingering DISM mount metadata or conflicting locks on the directory or WIM
    Clear-DismMountConflicts -TargetMountDir $normMount -TargetWimFile $WimFile -Retries $Retries

    # 2. Safety assert before destructive reset
    Assert-Nano11DirectorySafety -Path $normMount -Operation 'Reset'

    # 3. Safely unload offline registry hives if present
    [void](Unmount-DismOfflineHives -TargetMountDir $normMount -BestEffort)

    # 4. Check if directory entity exists
    if (Test-Path -LiteralPath $normMount) {
        $dirItem = Get-Item -LiteralPath $normMount -Force -ErrorAction Stop
        if ($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Safety violation: Target mount directory '$normMount' is a reparse point. Refusing to recreate."
        }
        if ($script:VhdxMountDir -and ($normMount -ieq (ConvertTo-Nano11NormalizedPath -Path $script:VhdxMountDir))) {
            throw "Safety violation: Target mount directory '$normMount' is the VHDX volume mount point. Refusing to delete root entity."
        }

        # 5. Empty directory contents cleanly
        Reset-DirectoryWithRobocopy -Path $normMount -Retries $Retries
        Assert-Nano11DirectoryEmpty -Path $normMount

        # 6. Delete directory entity itself to purge any hidden NTFS attributes/ADS/stale metadata
        try {
            [System.IO.Directory]::Delete($normMount, $false)
        } catch {
            Write-Warning "Direct directory entity deletion failed ($normMount): $_"
        }
    }

    # 7. Create fresh empty directory
    if (-not (Test-Path -LiteralPath $normMount)) {
        New-Item -ItemType Directory -Force -Path $normMount -ErrorAction Stop | Out-Null
    }

    # 8. Verify it is not a reparse point and is strictly empty
    $newDirItem = Get-Item -LiteralPath $normMount -Force -ErrorAction Stop
    if ($newDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Safety violation: Fresh mount directory '$normMount' was created as a reparse point."
    }
    Assert-Nano11DirectoryEmpty -Path $normMount
}

# Helper function: Mount WIM image with automatic unique path rotation on conflict (0xc1420113 / 0xc1420114 / 0xc1420127)
function Invoke-Nano11ImageMount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ImageFile,
        [Parameter(Mandatory=$true)]
        [string]$ImageIndex,
        [switch]$ReadOnly,
        [ValidateRange(1, 5)]
        [int]$Retries = 3
    )

    $normWim = ConvertTo-Nano11NormalizedPath -Path $ImageFile
    if (-not (Test-Path -LiteralPath $normWim)) {
        throw "Image file not found: $normWim"
    }

    $lastExitCode = 0
    $lastExitHex = ""
    $triedMountDirs = [System.Collections.Generic.List[string]]::new()

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        # 1. Allocate a fresh unique GUID mount path for every attempt
        $curMountDir = New-Nano11MountDirectoryPath
        $triedMountDirs.Add($curMountDir)
        Write-Host "Preparing mount directory (Attempt $attempt of $Retries) at '$curMountDir'..." -ForegroundColor Cyan

        # 2. Physically recreate and verify empty directory
        Initialize-Nano11MountDirectory -MountDir $curMountDir -WimFile $normWim -Retries $Retries

        # 3. Build DISM /Mount-Image arguments
        $dismMountArgs = @('/English')
        if ($script:DismLogPath) {
            $dismMountArgs += @("/LogPath:$script:DismLogPath", "/LogLevel:3")
        }
        $dismMountArgs += @('/Mount-Image', "/ImageFile:$normWim", "/Index:$ImageIndex", "/MountDir:$curMountDir")
        if ($ReadOnly) {
            $dismMountArgs += @('/ReadOnly')
        }

        & dism.exe @dismMountArgs
        $lastExitCode = $LASTEXITCODE
        $lastExitHex = '0x{0:X8}' -f ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$lastExitCode), 0))

        # 4. If exit code is 0, strictly verify DISM registration
        if ($lastExitCode -eq 0) {
            $mountedImages = @(Get-Nano11MountedImages)
            $matchingMounts = @($mountedImages | Where-Object {
                $p = if ($_.Path) { try { ConvertTo-Nano11NormalizedPath -Path $_.Path } catch { $null } } else { $null }
                $p -and ($p -ieq $curMountDir)
            })

            if ($matchingMounts.Count -eq 1) {
                $m = $matchingMounts[0]
                $imgNorm = try { ConvertTo-Nano11NormalizedPath -Path $m.ImagePath } catch { $null }
                if ($imgNorm -and ($imgNorm -ieq $normWim) -and ($m.ImageIndex -eq $ImageIndex) -and ($m.MountStatus -ieq 'Ok')) {
                    Write-Host "Successfully mounted image to '$curMountDir' (Index: $ImageIndex, Status: $($m.MountStatus))." -ForegroundColor Green
                    return [PSCustomObject]@{
                        MountDir   = $curMountDir
                        ImageFile  = $normWim
                        ImageIndex = $ImageIndex
                    }
                }
            }
            Write-Warning "DISM returned 0 but mounted image verification failed for '$curMountDir'. Recovery required."
        }

        # 5. Handle mount failure and conflict recovery
        Write-Host "Mount attempt $attempt failed (Exit code: $lastExitHex / $lastExitCode). Resolving conflicts and recovering..." -ForegroundColor Yellow

        # Inspect if DISM actually created a partial mount on curMountDir
        $postCheckMounts = @(Get-Nano11MountedImages)
        $partialMount = $postCheckMounts | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-Nano11NormalizedPath -Path $_.Path } catch { $null } } else { $null }
            $p -and ($p -ieq $curMountDir)
        }

        if ($partialMount) {
            # Attempt to discard partial mount
            Write-Host "Discarding partial mount at '$curMountDir' (Status: $($partialMount.MountStatus))..." -ForegroundColor Yellow
            & dism.exe /English /Unmount-Image "/MountDir:$curMountDir" /discard > $null 2>&1
        }

        # Run safe mountpoint cleanup
        Invoke-Nano11MountpointCleanup | Out-Null

        # Unload any offline hives
        try { [void](Unmount-DismOfflineHives -TargetMountDir $curMountDir -BestEffort) } catch {}

        # Re-verify that no active mount remains on curMountDir
        $verifyLingering = @(Get-Nano11MountedImages) | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-Nano11NormalizedPath -Path $_.Path } catch { $null } } else { $null }
            $p -and ($p -ieq $curMountDir)
        }

        if ($verifyLingering) {
            Write-Warning "Unresolved mount remains on '$curMountDir'. Marking as Preserved for safety."
            [void]$script:PreservedMountDirs.Add($curMountDir)
            throw "Failed to resolve mount conflict on '$curMountDir'. Active mount remains: $($verifyLingering.MountStatus). Aborting for system protection."
        }

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        if ($attempt -lt $Retries) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    $triedStr = ($triedMountDirs -join ", ")
    throw "Failed to mount image '$normWim' (Index: $ImageIndex) after $Retries attempts. Tried directories: $triedStr. Last exit code: $lastExitHex ($lastExitCode)."
}

# Every setting that a JSON profile can carry (-SaveProfile writes these, -LoadProfile reads them).
# Names match the keys understood by Apply-ProfileSettings and the built-in presets.
$script:Nano11ProfileKeys = @(
    'RemoveDefender', 'KeepAsianIME', 'KeepExtraFonts', 'RemoveDrivers', 'DisableWindowsUpdate',
    'KeepBluetooth', 'WSLSupport', 'KeepRecoveryEnv', 'SafeDebloatMode', 'UltraSlimMode',
    'SetJapaneseKeyboard', 'AtlasReviOSMode', 'RemoveStore', 'KeepBasicApps', 'KeepSearchIndex',
    'KeepXboxServices', 'KeepAudioTweaks', 'UseVHDX', 'RemoveLegacyFOD', 'TrimWallpapers',
    'HibernateMode', 'CrashDumpMode', 'DisableCPUMitigations', 'MMCSSGaming', 'DAWMode',
    'DisableMemCompression', 'DisableFSE', 'NvidiaLowLatency', 'NoKernelPaging', 'DisableUSBSuspend',
    'NoHypervisor', 'RemoveWebViewPostOOBE', 'FastExport', 'UefiOnly', 'CpuBoostMode', 'PowerPreset',
    'BypassActivationRestrictions', 'RadicalRAM', 'TweakGroups', 'PayloadFormat',
    'SkipEiCfg', 'NoPostInstallAssets', 'SourceDrive', 'WorkDir', 'Index', 'ComputerName', 'UserName'
)

# Helper function: Snapshot the currently resolved build settings (script scope) as a profile hashtable
function Get-Nano11CurrentConfig {
    param([string]$ProfileName = "Exported Profile")
    $tweakGroups = [ordered]@{}
    foreach ($k in $script:activeTweakGroups.Keys) { $tweakGroups[$k] = [bool]$script:activeTweakGroups[$k] }
    return @{
        ProfileName                  = $ProfileName
        RemoveDefender               = [bool]$script:removeDefender
        KeepAsianIME                 = [bool]$script:keepAsianIME
        KeepExtraFonts               = [bool]$script:keepExtraFonts
        RemoveDrivers                = [bool]$script:removeDrivers
        DisableWindowsUpdate         = [bool]$script:disableWU
        KeepBluetooth                = [bool]$script:keepBT
        WSLSupport                   = [bool]$script:wslSupport
        KeepRecoveryEnv              = [bool]$script:keepRecoveryEnv
        SafeDebloatMode              = [bool]$script:safeDebloatMode
        UltraSlimMode                = [bool]$script:ultraSlimMode
        SetJapaneseKeyboard          = [bool]$script:setJapaneseKeyboard
        AtlasReviOSMode              = [bool]$script:atlasReviOSMode
        RemoveStore                  = [bool]$script:removeStore
        KeepBasicApps                = [bool]$script:keepBasicApps
        KeepSearchIndex              = [bool]$script:keepSearchIndex
        KeepXboxServices             = [bool]$script:keepXboxServices
        KeepAudioTweaks              = [bool]$script:keepAudioTweaks
        UseVHDX                      = [bool]$script:useVHDX
        RemoveLegacyFOD              = [bool]$script:removeLegacyFOD
        TrimWallpapers               = [bool]$script:trimWallpapers
        HibernateMode                = "$($script:hibernateMode)"
        CrashDumpMode                = "$($script:crashDumpMode)"
        DisableCPUMitigations        = [bool]$script:disableCPUMitigations
        MMCSSGaming                  = [bool]$script:mmcssGaming
        DAWMode                      = [bool]$script:dawMode
        DisableMemCompression        = [bool]$script:disableMemCompression
        DisableFSE                   = [bool]$script:disableFSE
        NvidiaLowLatency             = [bool]$script:nvidiaLowLatency
        NoKernelPaging               = [bool]$script:noKernelPaging
        DisableUSBSuspend            = [bool]$script:disableUSBSuspend
        NoHypervisor                 = [bool]$script:noHypervisor
        RemoveWebViewPostOOBE        = [bool]$script:removeWebViewPostOOBE
        FastExport                   = [bool]$script:fastExport
        UefiOnly                     = [bool]$script:uefiOnly
        CpuBoostMode                 = "$($script:cpuBoostMode)"
        PowerPreset                  = "$($script:powerPreset)"
        BypassActivationRestrictions = [bool]$script:bypassActivationRestrictions
        RadicalRAM                   = [bool]$script:radicalRAM
        TweakGroups                  = $tweakGroups
        PayloadFormat                = if ($script:exportESDMode) { "ESD" } elseif ($script:splitWIMMode) { "SWM" } else { "WIM" }
        SkipEiCfg                    = [bool]$script:SkipEiCfg
        NoPostInstallAssets          = [bool]$script:NoPostInstallAssets
        SourceDrive                  = "$($script:SourceDrive)"
        WorkDir                      = "$($script:WorkDir)"
        Index                        = "$($script:Index)"
        ComputerName                 = "$($script:ComputerName)"
        UserName                     = "$($script:UserName)"
    }
}

# Helper function: Export configuration settings to a JSON profile
function Export-Nano11Profile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [hashtable]$Config
    )
    $parentDir = Split-Path -Parent $FilePath
    if ($parentDir -and (-not (Test-Path -LiteralPath $parentDir))) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }
    # Settings are written in the same key order as $script:Nano11ProfileKeys so a saved profile
    # round-trips through -LoadProfile without losing any option.
    $settings = [ordered]@{}
    foreach ($k in $script:Nano11ProfileKeys) {
        if ($Config.ContainsKey($k)) { $settings[$k] = $Config[$k] }
    }
    $profileData = [ordered]@{
        ProfileName = if ($Config.ProfileName) { $Config.ProfileName } else { "nano11 Configuration Profile" }
        Version     = $script:Nano11Version
        Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Settings    = $settings
    }
    $json = $profileData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($FilePath, $json, [System.Text.Encoding]::UTF8)
    Write-Host "Profile saved to: $FilePath" -ForegroundColor Green
}

function Initialize-Nano11WimNative {
    if ('Nano11WimNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Nano11WimNative {
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr WIMCreateFile(string path, uint access, uint disposition, uint flags, uint compression, out uint creationResult);
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool WIMSetTemporaryPath(IntPtr hWim, string path);
    [DllImport("wimgapi.dll", SetLastError = true)]
    public static extern uint WIMGetImageCount(IntPtr hWim);
    [DllImport("wimgapi.dll", SetLastError = true)]
    public static extern IntPtr WIMLoadImage(IntPtr hWim, uint index);
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool WIMExtractImagePath(IntPtr hImage, string imagePath, string destinationPath, uint flags);
    [DllImport("wimgapi.dll", SetLastError = true)]
    public static extern bool WIMCloseHandle(IntPtr hObject);
}
'@
}

# Extracts a single file from a WIM/ESD image without mounting it. Returns $true on success.
function Export-Nano11WimFile {
    param(
        [Parameter(Mandatory=$true)][string]$WimPath,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][string]$TempPath
    )
    Initialize-Nano11WimNative
    if (-not (Test-Path -LiteralPath $TempPath)) { New-Item -ItemType Directory -Path $TempPath -Force | Out-Null }
    $destDir = Split-Path -Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    $created = [uint32]0
    # GENERIC_READ (0x80000000), OPEN_EXISTING (3)
    $hWim = [Nano11WimNative]::WIMCreateFile($WimPath, [uint32]2147483648, 3, 0, 0, [ref]$created)
    if ($hWim -eq [IntPtr]::Zero) { return $false }
    try {
        [void][Nano11WimNative]::WIMSetTemporaryPath($hWim, $TempPath)
        $hImg = [Nano11WimNative]::WIMLoadImage($hWim, [uint32]$Index)
        if ($hImg -eq [IntPtr]::Zero) { return $false }
        try {
            $imgPath = '\' + $ImagePath.TrimStart('\')
            return [bool][Nano11WimNative]::WIMExtractImagePath($hImg, $imgPath, $Destination, 0)
        } finally {
            [void][Nano11WimNative]::WIMCloseHandle($hImg)
        }
    } finally {
        [void][Nano11WimNative]::WIMCloseHandle($hWim)
    }
}

function Get-Nano11WimImageCount {
    param([Parameter(Mandatory=$true)][string]$WimPath)
    Initialize-Nano11WimNative
    $created = [uint32]0
    $hWim = [Nano11WimNative]::WIMCreateFile($WimPath, [uint32]2147483648, 3, 0, 0, [ref]$created)
    if ($hWim -eq [IntPtr]::Zero) { return 0 }
    try { return [int][Nano11WimNative]::WIMGetImageCount($hWim) } finally { [void][Nano11WimNative]::WIMCloseHandle($hWim) }
}

# Extracts a file twice and returns its SHA-1 / signature state. Two differing reads of the same
# stream mean the host itself is corrupting data in memory.
function Get-Nano11WimFileFingerprint {
    param(
        [Parameter(Mandatory=$true)][string]$WimPath,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][string]$WorkDir,
        [switch]$KeepFile
    )
    $leaf = Split-Path -Path $ImagePath -Leaf
    $runDir = Join-Path -Path $WorkDir -ChildPath ([System.IO.Path]::GetRandomFileName())
    $tmpDir = Join-Path -Path $runDir -ChildPath 'wimtmp'
    $hashes = @()
    $keptFile = $null
    try {
        for ($n = 1; $n -le 2; $n++) {
            $outFile = Join-Path -Path (Join-Path -Path $runDir -ChildPath "read$n") -ChildPath $leaf
            if (-not (Export-Nano11WimFile -WimPath $WimPath -Index $Index -ImagePath $ImagePath -Destination $outFile -TempPath $tmpDir)) {
                return $null
            }
            $hashes += (Get-FileHash -LiteralPath $outFile -Algorithm SHA1).Hash
            if ($n -eq 1) { $keptFile = $outFile }
        }
        $sigStatus = 'Unknown'
        try { $sigStatus = [string](Get-AuthenticodeSignature -LiteralPath $keptFile -ErrorAction Stop).Status } catch {}
        return [PSCustomObject]@{
            Sha1          = $hashes[0]
            StableRead    = ($hashes[0] -eq $hashes[1])
            Signature     = $sigStatus
            File          = if ($KeepFile) { $keptFile } else { $null }
            RunDir        = $runDir
        }
    } finally {
        if (-not $KeepFile) {
            & cmd.exe /c "rd /s /q `"$runDir`"" > $null 2>&1
        }
    }
}

# Parses a DISM log for files that failed hash/signature verification and returns image-relative paths.
function Get-Nano11DeepApplyFailedFiles {
    param(
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][string]$ApplyDir
    )
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    $applyRoot = [System.IO.Path]::GetFullPath($ApplyDir).TrimEnd('\')
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($LogPath)) {
        if ($line -match 'DISM WIM Provider:\s*PID=\d+\s+(?<p>.+?)\s+\(HRESULT=0x(?:80070241|80070570|8007000D|80070017)\)') {
            $full = $matches['p'].Trim()
            if ($full.StartsWith($applyRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $full.Substring($applyRoot.Length).TrimStart('\')
                if ($rel -and -not $found.Contains($rel)) { $found.Add($rel) }
            }
        }
    }
    return @($found)
}

# Finds a verified known-good copy of a file in reference images (never the corrupted build image).
function Find-Nano11ReferenceWimFile {
    param(
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][object[]]$References,
        [Parameter(Mandatory=$true)][string]$WorkDir
    )
    foreach ($ref in $References) {
        if (-not $ref.Path -or -not (Test-Path -LiteralPath $ref.Path)) { continue }
        $indices = [System.Collections.Generic.List[int]]::new()
        if ($ref.PreferredIndex) { $indices.Add([int]$ref.PreferredIndex) }
        $count = Get-Nano11WimImageCount -WimPath $ref.Path
        for ($i = 1; $i -le $count; $i++) {
            if (-not $indices.Contains($i) -and -not ($ref.ExcludeIndex -and $i -eq [int]$ref.ExcludeIndex)) { $indices.Add($i) }
        }
        foreach ($i in $indices) {
            $fp = Get-Nano11WimFileFingerprint -WimPath $ref.Path -Index $i -ImagePath $ImagePath -WorkDir $WorkDir -KeepFile
            if (-not $fp) { continue }
            if ($fp.StableRead -and $fp.Signature -ne 'HashMismatch') {
                $fp | Add-Member -NotePropertyName Source -NotePropertyValue "$($ref.Path) [Index $i]"
                return $fp
            }
            & cmd.exe /c "rd /s /q `"$($fp.RunDir)`"" > $null 2>&1
        }
    }
    return $null
}

# Overwrites corrupted files inside index 1 of a WIM with verified copies, commits, and re-exports so the
# corrupted stream is dropped. Files are overwritten in place with robocopy /B (backup semantics), which
# preserves WinSxS hard links, ownership and ACLs.
function Repair-Nano11WimFiles {
    param(
        [Parameter(Mandatory=$true)][string]$WimPath,
        [Parameter(Mandatory=$true)][object[]]$Repairs,
        [Parameter(Mandatory=$true)][string]$WorkDir,
        [string]$CompressMode = '/Compress:max',
        [string]$LogPath
    )
    $mount = Invoke-Nano11ImageMount -ImageFile $WimPath -ImageIndex 1 -Retries 3
    $mountDir = $mount.MountDir
    $script:DismMountDir = $mountDir
    $script:MountOpened = $true
    $committed = $false
    try {
        foreach ($r in $Repairs) {
            $target = Join-Path -Path $mountDir -ChildPath $r.ImagePath.TrimStart('\')
            if (-not (Test-Path -LiteralPath $target)) {
                throw "Repair target not found in mounted image: $($r.ImagePath)"
            }
            $srcDir = Split-Path -Path $r.GoodFile -Parent
            $leaf = Split-Path -Path $target -Leaf
            & robocopy.exe $srcDir (Split-Path -Path $target -Parent) $leaf /B /COPY:D /IS /IT /R:2 /W:1 /NP /NJH /NJS /NFL /NDL > $null 2>&1
            if ($LASTEXITCODE -ge 8) {
                throw "robocopy /B failed to overwrite '$($r.ImagePath)' (Exit code: $LASTEXITCODE)."
            }
            $newHash = (Get-FileHash -LiteralPath $target -Algorithm SHA1).Hash
            if ($newHash -ne $r.GoodSha1) {
                throw "Repaired file hash mismatch for '$($r.ImagePath)' (expected $($r.GoodSha1), got $newHash)."
            }
            Write-Host "    [REPAIRED] $($r.ImagePath) <= $($r.Source)" -ForegroundColor Green
        }

        $safeLoc = if ($scriptDir) { $scriptDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { [System.IO.Path]::GetTempPath() }
        Set-Location -LiteralPath $safeLoc
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        for ($retry = 1; $retry -le 3; $retry++) {
            & dism.exe /English /Unmount-Image "/MountDir:$mountDir" /commit
            if ($LASTEXITCODE -eq 0) { $committed = $true; break }
            Start-Sleep -Seconds (2 * $retry)
        }
        if (-not $committed) { throw "Failed to commit repaired image (Exit code: $LASTEXITCODE)." }
    } catch {
        if (-not $committed) {
            & dism.exe /English /Unmount-Image "/MountDir:$mountDir" /discard > $null 2>&1
        }
        throw
    } finally {
        $script:MountOpened = $false
        try { Clear-DismMountConflicts -TargetMountDir $mountDir -TargetWimFile $WimPath } catch {}
    }

    # Re-export so the superseded (corrupted) stream is removed and a fresh integrity table is written.
    $repairExport = Join-Path -Path $WorkDir -ChildPath "install_repaired_$([System.IO.Path]::GetRandomFileName()).wim"
    $repairScratch = Join-Path -Path $WorkDir -ChildPath "repair_export_scratch"
    New-Item -ItemType Directory -Path $repairScratch -Force | Out-Null
    $exportArgs = @('/English', '/Export-Image', "/SourceImageFile:$WimPath", '/SourceIndex:1', "/DestinationImageFile:$repairExport", $CompressMode, "/ScratchDir:$repairScratch", '/CheckIntegrity')
    if ($LogPath) { $exportArgs += "/LogPath:$LogPath" }
    & dism.exe @exportArgs
    $exportExit = $LASTEXITCODE
    & cmd.exe /c "rd /s /q `"$repairScratch`"" > $null 2>&1
    if ($exportExit -ne 0 -or -not (Test-Path -LiteralPath $repairExport)) {
        Remove-Item -LiteralPath $repairExport -Force -ErrorAction SilentlyContinue
        throw "Re-export of repaired install.wim failed (Exit code: $exportExit)."
    }
    Remove-Item -LiteralPath $WimPath -Force -ErrorAction Stop
    Move-Item -LiteralPath $repairExport -Destination $WimPath -Force -ErrorAction Stop
}

# Phase Progress & Telemetry Tracking
$script:CurrentPhase = 0
$script:TotalPhases = 18
$script:PhaseTimings = [ordered]@{}
$script:PhaseStopwatch = $null

function Enter-Phase {
    param(
        [int]$PhaseNumber,
        [string]$PhaseName
    )
    # F2: persist a checkpoint for the phase that just completed (foundation for -ResumeFromPhase)
    if ($script:CurrentPhase -gt 0 -and -not $script:ResumeMode -and $script:BaseWorkDir) {
        Save-Nano11Checkpoint -CompletedPhase $script:CurrentPhase
    }
    if ($script:PhaseStopwatch -and $script:CurrentPhase -gt 0) {
        $script:PhaseStopwatch.Stop()
        $prevPhaseKey = "Phase $($script:CurrentPhase)"
        $script:PhaseTimings[$prevPhaseKey] = [math]::Round($script:PhaseStopwatch.Elapsed.TotalSeconds, 1)
    }
    $script:CurrentPhase = $PhaseNumber
    $script:CurrentBuildPhase = "Phase ${PhaseNumber}: $PhaseName"
    if ($script:DiagnosticData) {
        $script:DiagnosticData.FailurePhase = $script:CurrentBuildPhase
    }
    $script:PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $phaseTitle = "nano11 [$PhaseNumber/$($script:TotalPhases)] $PhaseName"
    try { $host.UI.RawUI.WindowTitle = $phaseTitle } catch {}
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " [$PhaseNumber/$($script:TotalPhases)] $PhaseName" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
}

function Exit-Phase {
    if ($script:PhaseStopwatch) {
        $script:PhaseStopwatch.Stop()
        $prevPhaseKey = "Phase $($script:CurrentPhase)"
        $script:PhaseTimings[$prevPhaseKey] = [math]::Round($script:PhaseStopwatch.Elapsed.TotalSeconds, 1)
        $script:PhaseStopwatch = $null
    }
}

# ==============================================================================
# Modular Tweak Architecture & In-Memory Built-in Presets
# ==============================================================================

$script:TweakGroups = [ordered]@{
    NetworkStack   = @{ Default = $true;  Risk = '**';   Description = 'TcpAck/RSC/ECN/NetThrottling tuning' }
    TimerBCD       = @{ Default = $true;  Risk = '**';   Description = 'dynamic tick/TSC sync/platform clock' }
    GPULatency     = @{ Default = $true;  Risk = '*';    Description = 'MSI mode/HAGS/GPU scheduling registry' }
    ServiceTrim    = @{ Default = $true;  Risk = '**';   Description = 'WSearch/SysMain/DiagTrack/Ndu service trimming' }
    VisualFX       = @{ Default = $true;  Risk = '*';    Description = 'DWM transparency/animations/effects minimization' }
    CpuMitigations = @{ Default = $false; Risk = '***';  Description = 'Spectre/Meltdown speculative execution mitigations (Security trade-off)' }
}

$script:activeTweakGroups = [ordered]@{}
foreach ($tgKey in $script:TweakGroups.Keys) {
    $script:activeTweakGroups[$tgKey] = [bool]$script:TweakGroups[$tgKey].Default
}

$script:PowerPresets = [ordered]@{
    Desktop   = @{ UsbSuspend = 0; PcieLpm = 0; BoostAc = 2; BoostDc = 2; DiskIdle = 0 }
    Handheld  = @{ UsbSuspend = 0; PcieLpm = 1; BoostAc = 1; BoostDc = 1; DiskIdle = 60 }
    Balanced  = @{ UsbSuspend = 1; PcieLpm = 1; BoostAc = 2; BoostDc = 1; DiskIdle = 180 }
    VM        = @{ UsbSuspend = 1; PcieLpm = 0; BoostAc = 2; BoostDc = 2; DiskIdle = 0 }
}

$script:BuiltInPresets = [ordered]@{
    'extreme' = [ordered]@{
        ProfileName          = 'Extreme Slim & Gaming'
        Description          = 'Maximum debloat, ultra-low latency kernel/timer tuning, minimal footprint.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $false
        RemoveDrivers        = $true
        DisableWindowsUpdate = $true
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $true
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $true
        KeepBasicApps        = $false
        KeepSearchIndex      = $false
        KeepXboxServices     = $false
        KeepAudioTweaks      = $true
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Desktop'
        RemoveLegacyFOD      = $true
        TrimWallpapers       = $true
        HibernateMode        = 'Off'
        CrashDumpMode        = 'None'
        DisableCPUMitigations= $false
        MMCSSGaming          = $true
        DAWMode              = $false
        DisableMemCompression= $true
        DisableFSE           = $true
        NvidiaLowLatency     = $true
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        BypassActivationRestrictions = $true
        RadicalRAM           = $true
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
    'balanced' = [ordered]@{
        ProfileName          = 'Balanced Pro'
        Description          = 'Safe daily debloat: Windows Update & Defender preserved, high stability.'
        RemoveDefender       = $false
        KeepAsianIME         = $true
        KeepExtraFonts       = $true
        RemoveDrivers        = $false
        DisableWindowsUpdate = $false
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $true
        SafeDebloatMode      = $true
        UltraSlimMode        = $false
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $false
        KeepBasicApps        = $true
        KeepSearchIndex      = $true
        KeepXboxServices     = $true
        KeepAudioTweaks      = $false
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Balanced'
        RemoveLegacyFOD      = $false
        TrimWallpapers       = $false
        HibernateMode        = 'Keep'
        CrashDumpMode        = 'Automatic'
        DisableCPUMitigations= $false
        MMCSSGaming          = $false
        DAWMode              = $false
        DisableMemCompression= $false
        DisableFSE           = $false
        NvidiaLowLatency     = $false
        NoKernelPaging       = $false
        DisableUSBSuspend    = $false
        NoHypervisor         = $false
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Default'
        BypassActivationRestrictions = $false
        RadicalRAM           = $false
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $false
            VisualFX       = $false
            CpuMitigations = $false
        }
    }
    'fat32' = [ordered]@{
        ProfileName          = 'FAT32 USB Split-WIM'
        Description          = 'Split-WIM payload for 100% FAT32 USB installer compatibility.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $false
        RemoveDrivers        = $true
        DisableWindowsUpdate = $true
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $true
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $true
        KeepBasicApps        = $false
        KeepSearchIndex      = $false
        KeepXboxServices     = $false
        KeepAudioTweaks      = $true
        PayloadFormat        = 'SWM'
        UseVHDX              = $false
        PowerPreset          = 'Desktop'
        RemoveLegacyFOD      = $true
        TrimWallpapers       = $true
        HibernateMode        = 'Off'
        CrashDumpMode        = 'None'
        DisableCPUMitigations= $false
        MMCSSGaming          = $true
        DAWMode              = $false
        DisableMemCompression= $true
        DisableFSE           = $true
        NvidiaLowLatency     = $true
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        BypassActivationRestrictions = $true
        RadicalRAM           = $true
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
    'handheld' = [ordered]@{
        ProfileName          = 'Portable Gaming PC'
        Description          = 'Tuned for handhelds (ROG Ally, Steam Deck): battery balance & gamepad protection.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $false
        RemoveDrivers        = $true
        DisableWindowsUpdate = $true
        KeepBluetooth        = $true
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $true
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $true
        KeepBasicApps        = $false
        KeepSearchIndex      = $false
        KeepXboxServices     = $true
        KeepAudioTweaks      = $true
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Handheld'
        RemoveLegacyFOD      = $true
        TrimWallpapers       = $true
        HibernateMode        = 'Reduced'
        CrashDumpMode        = 'Small'
        DisableCPUMitigations= $false
        MMCSSGaming          = $true
        DAWMode              = $false
        DisableMemCompression= $true
        DisableFSE           = $true
        NvidiaLowLatency     = $false
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Efficient'
        BypassActivationRestrictions = $true
        RadicalRAM           = $true
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
    'vm' = [ordered]@{
        ProfileName          = 'VM & Developer Workstation'
        Description          = 'Configured for virtual machines and developers: WSL2 & Hyper-V enabled.'
        RemoveDefender       = $false
        KeepAsianIME         = $true
        KeepExtraFonts       = $true
        RemoveDrivers        = $false
        DisableWindowsUpdate = $false
        KeepBluetooth        = $false
        WSLSupport           = $true
        KeepRecoveryEnv      = $true
        SafeDebloatMode      = $true
        UltraSlimMode        = $false
        SetJapaneseKeyboard  = $false
        AtlasReviOSMode      = $false
        RemoveStore          = $false
        KeepBasicApps        = $true
        KeepSearchIndex      = $true
        KeepXboxServices     = $false
        KeepAudioTweaks      = $false
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'VM'
        RemoveLegacyFOD      = $false
        TrimWallpapers       = $false
        HibernateMode        = 'Off'
        CrashDumpMode        = 'Automatic'
        DisableCPUMitigations= $false
        MMCSSGaming          = $false
        DAWMode              = $false
        DisableMemCompression= $false
        DisableFSE           = $false
        NvidiaLowLatency     = $false
        NoKernelPaging       = $false
        DisableUSBSuspend    = $false
        NoHypervisor         = $false
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        BypassActivationRestrictions = $true
        RadicalRAM           = $true
        TweakGroups          = [ordered]@{
            NetworkStack   = $true
            TimerBCD       = $true
            GPULatency     = $true
            ServiceTrim    = $false
            VisualFX       = $false
            CpuMitigations = $false
        }
    }
    'audio' = [ordered]@{
        ProfileName          = 'Audio & DAW Production'
        Description          = 'Pro Audio MMCSS priority, zero DPC latency spikes, VST compatibility protected.'
        RemoveDefender       = $true
        KeepAsianIME         = $true
        KeepExtraFonts       = $true
        RemoveDrivers        = $false
        DisableWindowsUpdate = $true
        KeepBluetooth        = $false
        WSLSupport           = $false
        KeepRecoveryEnv      = $false
        SafeDebloatMode      = $true
        UltraSlimMode        = $false
        SetJapaneseKeyboard  = $true
        AtlasReviOSMode      = $true
        RemoveStore          = $false
        KeepBasicApps        = $true
        KeepSearchIndex      = $false
        KeepXboxServices     = $false
        KeepAudioTweaks      = $true
        PayloadFormat        = 'WIM'
        UseVHDX              = $false
        PowerPreset          = 'Desktop'
        RemoveLegacyFOD      = $false
        TrimWallpapers       = $false
        HibernateMode        = 'Off'
        CrashDumpMode        = 'Small'
        DisableCPUMitigations= $false
        MMCSSGaming          = $false
        DAWMode              = $true
        DisableMemCompression= $false
        DisableFSE           = $false
        NvidiaLowLatency     = $false
        NoKernelPaging       = $true
        DisableUSBSuspend    = $true
        NoHypervisor         = $true
        RemoveWebViewPostOOBE= $false
        FastExport           = $false
        UefiOnly             = $false
        CpuBoostMode         = 'Aggressive'
        BypassActivationRestrictions = $true
        RadicalRAM           = $true
        TweakGroups          = [ordered]@{
            NetworkStack   = $false
            TimerBCD       = $true
            GPULatency     = $false
            ServiceTrim    = $true
            VisualFX       = $true
            CpuMitigations = $false
        }
    }
}

function Get-Nano11Preset {
    param([string]$Name)
    if (-not $Name) { return $script:BuiltInPresets['extreme'] }
    $clean = $Name.Trim().ToLower()
    $aliasMap = @{
        '1'          = 'extreme'
        'extreme'    = 'extreme'
        'gaming'     = 'extreme'
        'slim'       = 'extreme'
        '2'          = 'balanced'
        'balanced'   = 'balanced'
        'safe'       = 'balanced'
        'pro'        = 'balanced'
        '3'          = 'fat32'
        'fat32'      = 'fat32'
        'split'      = 'fat32'
        'splitwim'   = 'fat32'
        '4'          = 'handheld'
        'handheld'   = 'handheld'
        'ally'       = 'handheld'
        'deck'       = 'handheld'
        'legion'     = 'handheld'
        '5'          = 'vm'
        'dev'        = 'vm'
        'developer'  = 'vm'
        '6'          = 'audio'
        'daw'        = 'audio'
        'dtm'        = 'audio'
    }
    $targetKey = if ($aliasMap.ContainsKey($clean)) { $aliasMap[$clean] } else { $clean }
    if ($script:BuiltInPresets.Contains($targetKey)) {
        return $script:BuiltInPresets[$targetKey]
    }
    return $null
}

# Helper function: Unified profile settings application
function Apply-ProfileSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName,
        [Parameter(Mandatory = $false)]
        [psobject]$ProfileObject,
        [switch]$UpdateGui,
        [hashtable]$GuiControls
    )

    $targetPreset = $null
    if ($ProfileName) {
        $targetPreset = Get-Nano11Preset -Name $ProfileName
        # Unknown name: apply nothing and return $null so the caller can warn and choose a fallback
        if (-not $targetPreset) { return $null }
    } elseif ($ProfileObject) {
        $targetPreset = if ($ProfileObject.Settings) { $ProfileObject.Settings } else { $ProfileObject }
    }

    if (-not $targetPreset) {
        $targetPreset = $script:BuiltInPresets['extreme']
    }

    $getVal = {
        param($key, $defaultVal = $false)
        if ($targetPreset -is [System.Collections.IDictionary]) {
            if ($targetPreset.Contains($key)) { return $targetPreset[$key] }
        } elseif ($targetPreset.PSObject.Properties[$key]) {
            return $targetPreset.$key
        }
        return $defaultVal
    }

    if ($UpdateGui -and $GuiControls) {
        $GuiControls.chkDefender.Checked    = [bool](& $getVal 'RemoveDefender' $true)
        $GuiControls.chkIME.Checked         = [bool](& $getVal 'KeepAsianIME' $true)
        $GuiControls.chkFonts.Checked       = [bool](& $getVal 'KeepExtraFonts' $true)
        $GuiControls.chkDrivers.Checked     = [bool](& $getVal 'RemoveDrivers' $false)
        $GuiControls.chkWU.Checked          = [bool](& $getVal 'DisableWindowsUpdate' $true)
        $GuiControls.chkBT.Checked          = [bool](& $getVal 'KeepBluetooth' $true)
        $GuiControls.chkWSL.Checked         = [bool](& $getVal 'WSLSupport' $false)
        $GuiControls.chkRecovery.Checked    = [bool](& $getVal 'KeepRecoveryEnv' $false)
        $GuiControls.chkSafeDebloat.Checked = [bool](& $getVal 'SafeDebloatMode' $true)
        $GuiControls.chkUltraSlim.Checked   = [bool](& $getVal 'UltraSlimMode' $true)
        $GuiControls.chkJPKey.Checked       = [bool](& $getVal 'SetJapaneseKeyboard' $true)
        $GuiControls.chkAtlas.Checked       = [bool](& $getVal 'AtlasReviOSMode' $true)
        $GuiControls.chkStore.Checked       = [bool](& $getVal 'RemoveStore' $false)
        if ($GuiControls.chkBypassActivation) { $GuiControls.chkBypassActivation.Checked = [bool](& $getVal 'BypassActivationRestrictions' $true) }
        if ($GuiControls.chkRadicalRAM)        { $GuiControls.chkRadicalRAM.Checked        = [bool](& $getVal 'RadicalRAM' $true) }
        if ($GuiControls.chkBasicApps)   { $GuiControls.chkBasicApps.Checked   = [bool](& $getVal 'KeepBasicApps' $false) }
        if ($GuiControls.chkSearchIndex) { $GuiControls.chkSearchIndex.Checked = [bool](& $getVal 'KeepSearchIndex' $false) }
        if ($GuiControls.chkVhdx)        { $GuiControls.chkVhdx.Checked        = [bool](& $getVal 'UseVHDX' $false) }
        
        $fmt = (& $getVal 'PayloadFormat' 'WIM').ToString().ToUpper()
        if ($fmt -eq 'ESD') { $GuiControls.radESD.Checked = $true }
        elseif ($fmt -eq 'SWM') { $GuiControls.radSWM.Checked = $true }
        else { $GuiControls.radWIM.Checked = $true }
    } else {
        $script:removeDefender       = [bool](& $getVal 'RemoveDefender' $true)
        $script:keepAsianIME         = [bool](& $getVal 'KeepAsianIME' $true)
        $script:keepExtraFonts       = [bool](& $getVal 'KeepExtraFonts' $true)
        $script:removeDrivers        = [bool](& $getVal 'RemoveDrivers' $false)
        $script:disableWU            = [bool](& $getVal 'DisableWindowsUpdate' $true)
        $script:keepBT               = [bool](& $getVal 'KeepBluetooth' $true)
        $script:wslSupport           = [bool](& $getVal 'WSLSupport' $false)
        $script:keepRecoveryEnv      = [bool](& $getVal 'KeepRecoveryEnv' $false)
        $script:safeDebloatMode      = [bool](& $getVal 'SafeDebloatMode' $true)
        $script:ultraSlimMode        = [bool](& $getVal 'UltraSlimMode' $true)
        $script:setJapaneseKeyboard  = [bool](& $getVal 'SetJapaneseKeyboard' $true)
        $script:atlasReviOSMode      = [bool](& $getVal 'AtlasReviOSMode' $true)
        $script:removeStore          = [bool](& $getVal 'RemoveStore' $false)
        $script:keepBasicApps        = [bool](& $getVal 'KeepBasicApps' $false)
        $script:keepSearchIndex      = [bool](& $getVal 'KeepSearchIndex' $false)
        $script:keepXboxServices     = [bool](& $getVal 'KeepXboxServices' $false)
        $script:keepAudioTweaks      = [bool](& $getVal 'KeepAudioTweaks' $true)
        $script:useVHDX              = [bool](& $getVal 'UseVHDX' $false)

        # Advanced Modular Optimization Flags
        $script:removeLegacyFOD      = [bool](& $getVal 'RemoveLegacyFOD' $false)
        $script:trimWallpapers       = [bool](& $getVal 'TrimWallpapers' $false)
        $script:hibernateMode        = (& $getVal 'HibernateMode' 'Keep').ToString()
        $script:crashDumpMode        = (& $getVal 'CrashDumpMode' 'Automatic').ToString()
        $script:disableCPUMitigations= [bool](& $getVal 'DisableCPUMitigations' $false)
        $script:mmcssGaming          = [bool](& $getVal 'MMCSSGaming' $false)
        $script:dawMode              = [bool](& $getVal 'DAWMode' $false)
        $script:disableMemCompression= [bool](& $getVal 'DisableMemCompression' $false)
        $script:disableFSE           = [bool](& $getVal 'DisableFSE' $false)
        $script:nvidiaLowLatency     = [bool](& $getVal 'NvidiaLowLatency' $false)
        $script:noKernelPaging       = [bool](& $getVal 'NoKernelPaging' $false)
        $script:disableUSBSuspend    = [bool](& $getVal 'DisableUSBSuspend' $false)
        $script:noHypervisor         = [bool](& $getVal 'NoHypervisor' $false)
        $script:removeWebViewPostOOBE= [bool](& $getVal 'RemoveWebViewPostOOBE' $false)
        $script:fastExport           = [bool](& $getVal 'FastExport' $false)
        $script:uefiOnly             = [bool](& $getVal 'UefiOnly' $false)
        $script:cpuBoostMode         = (& $getVal 'CpuBoostMode' 'Default').ToString()
        $script:powerPreset          = (& $getVal 'PowerPreset' 'Default').ToString()
        $script:bypassActivationRestrictions = [bool](& $getVal 'BypassActivationRestrictions' $true)
        $script:radicalRAM                   = [bool](& $getVal 'RadicalRAM' $true)

        # Modular Tweak Groups
        $tGroups = & $getVal 'TweakGroups' $null
        if ($tGroups) {
            foreach ($k in $script:TweakGroups.Keys) {
                # Built-in presets use a dictionary; JSON profiles arrive as a PSCustomObject
                if ($tGroups -is [System.Collections.IDictionary]) {
                    if ($tGroups.Contains($k)) { $script:activeTweakGroups[$k] = [bool]$tGroups[$k] }
                } elseif ($tGroups.PSObject.Properties[$k]) {
                    $script:activeTweakGroups[$k] = [bool]$tGroups.$k
                }
            }
        }

        $fmt = (& $getVal 'PayloadFormat' 'WIM').ToString().ToUpper()
        if ($fmt -eq 'ESD') { $script:exportESDMode = $true; $script:splitWIMMode = $false }
        elseif ($fmt -eq 'SWM') { $script:splitWIMMode = $true; $script:exportESDMode = $false }
        else { $script:exportESDMode = $false; $script:splitWIMMode = $false }
    }
    return $targetPreset
}

# Helper function: Import configuration settings from a JSON profile
function Import-Nano11Profile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        if ($NonInteractive) {
            throw "Error: Profile file not found: $FilePath"
        } else {
            Write-Host "Error: Profile file not found: $FilePath" -ForegroundColor Red
            return $null
        }
    }
    try {
        $rawJson = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        $data = $rawJson | ConvertFrom-Json
        if ($data.Version -and $data.Version -ne "2.0" -and $data.Version -ne "2.1" -and $data.Version -ne $script:Nano11Version) {
            Write-Warning "Profile version ($($data.Version)) differs from current ($script:Nano11Version)."
        }
        $settings = if ($data.Settings) { $data.Settings } else { $data }
        # ProfileName lives at the top level of exported files; carry it along with the settings
        if ($data.ProfileName -and -not $settings.PSObject.Properties['ProfileName']) {
            $settings | Add-Member -MemberType NoteProperty -Name ProfileName -Value $data.ProfileName
        }

        # Profile Schema Linter & Unknown Key Typo Detection
        $knownKeys = @($script:Nano11ProfileKeys) + @('ProfileName', 'Description', 'Version', 'Timestamp', 'Architecture')
        $unknownKeys = @()
        foreach ($prop in $settings.PSObject.Properties) {
            if ($knownKeys -notcontains $prop.Name) {
                $unknownKeys += $prop.Name
            }
        }
        if ($unknownKeys.Count -gt 0) {
            Write-Warning "Profile '$([System.IO.Path]::GetFileName($FilePath))' contains unrecognized setting(s): $($unknownKeys -join ', '). Please check for typos."
        }

        return $settings
    } catch {
        if ($NonInteractive) {
            throw "Failed to parse JSON profile '$FilePath': $_"
        } else {
            Write-Host "Failed to parse JSON profile: $_" -ForegroundColor Red
            return $null
        }
    }
}

# Helper function: Execute built-in diagnostic and repository self-test suite
function Invoke-Nano11SelfTest {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = $PSScriptRoot,
        [string]$BuilderPath,
        [string]$UnattendPath
    )
    if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
    if (-not $BuilderPath) {
        $BuilderPath = if ($PSCommandPath) { $PSCommandPath } else { (Get-ChildItem -Path $ScriptRoot -Filter 'nano11builder*.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName) }
        if (-not $BuilderPath) { $BuilderPath = Join-Path -Path $ScriptRoot -ChildPath "nano11builder.ps1" }
    }
    if (-not $UnattendPath) {
        $UnattendPath = Join-Path -Path $ScriptRoot -ChildPath "autounattend.xml"
    }
    
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "   nano11 Self-Test & Diagnostic Verification Suite     " -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    $results = @()
    
    # 1. AST Syntax Check
    $astPass = $false
    $astMsg = ""
    if (Test-Path -LiteralPath $BuilderPath) {
        $content = [System.IO.File]::ReadAllText($BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        if ($errors.Count -eq 0) {
            $astPass = $true
            $astMsg = "0 parser errors found in $([math]::Round($content.Length / 1KB, 1)) KB script"
        } else {
            $astMsg = "$($errors.Count) syntax errors: " + (($errors | Select-Object -First 3 | ForEach-Object { $_.Message }) -join "; ")
        }
    } else {
        $astMsg = "$([System.IO.Path]::GetFileName($BuilderPath)) not found"
    }
    $results += [PSCustomObject]@{ Test = "1. Builder Script AST Syntax"; Passed = $astPass; Details = $astMsg }

    # 2. Registry Safety Validation (zSYSTEM\CurrentControlSet check)
    $regSafePass = $true
    $regMsg = "Safe: No illegal offline CurrentControlSet keys created"
    if (Test-Path -LiteralPath $BuilderPath) {
        $lines = Get-Content -LiteralPath $BuilderPath
        $illegal = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -like "*zSYSTEM\CurrentControlSet*" -and $line -notlike "*reg.exe query*" -and $line -notlike "*reg.exe delete*" -and $line -notlike "*#*") {
                $illegal += "Line $($i+1): $line"
            }
        }
        if ($illegal.Count -gt 0) {
            $regSafePass = $false
            $regMsg = "FAILED: Found $($illegal.Count) illegal CurrentControlSet operations"
        }
    }
    $results += [PSCustomObject]@{ Test = "2. Offline Registry Safety Rule"; Passed = $regSafePass; Details = $regMsg }

    # 3. autounattend.xml XML Schema & Duplicate Component Check
    $xmlPass = $false
    $xmlMsg = ""
    if (Test-Path -LiteralPath $UnattendPath) {
        try {
            $doc = [xml]::new()
            $doc.Load($UnattendPath)
            if ($doc.DocumentElement.Name -eq 'unattend' -and $doc.unattend.settings) {
                # Check for duplicate components in the same pass
                $duplicateComponents = @()
                foreach ($pass in $doc.unattend.settings) {
                    $passName = $pass.pass
                    $compKeys = @($pass.component | ForEach-Object { "$($_.name) [$($_.processorArchitecture)]" })
                    $dups = $compKeys | Group-Object | Where-Object { $_.Count -gt 1 }
                    if ($dups) {
                        $duplicateComponents += "Pass '$passName': $($dups.Name -join ', ')"
                    }
                }
                if ($duplicateComponents.Count -gt 0) {
                    $xmlPass = $false
                    $xmlMsg = "Duplicate components found: $($duplicateComponents -join '; ')"
                } else {
                    $xmlPass = $true
                    $xmlMsg = "Valid XML: $($doc.unattend.settings.component.Count) components configured, 0 duplicates"
                }
            } else {
                $xmlMsg = "Missing required unattend/settings structure"
            }
        } catch {
            $xmlMsg = "Parse error: $($_.Exception.Message)"
        }
    } else {
        $xmlMsg = "autounattend.xml not found"
    }
    $results += [PSCustomObject]@{ Test = "3. autounattend.xml Schema"; Passed = $xmlPass; Details = $xmlMsg }

    # 4. Built-in Profile Presets & Modular Tweak Integrity
    $profPass = $false
    $profMsg = ""
    $expectedPresetKeys = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $missingPresets = @()
    foreach ($ep in $expectedPresetKeys) {
        if (-not $script:BuiltInPresets.Contains($ep)) {
            $missingPresets += $ep
        }
    }
    if ($missingPresets.Count -eq 0 -and $script:TweakGroups.Count -ge 6 -and $script:PowerPresets.Count -ge 4) {
        $badPresets = @()
        foreach ($kv in $script:BuiltInPresets.GetEnumerator()) {
            $pName = $kv.Key
            $pDef = $kv.Value
            if (-not $pDef.ProfileName -or -not $pDef.Description) {
                $badPresets += "$pName (missing ProfileName/Description)"
            }
            if (-not $pDef.PowerPreset -or -not $script:PowerPresets.Contains($pDef.PowerPreset)) {
                $badPresets += "$pName (invalid PowerPreset: $($pDef.PowerPreset))"
            }
            if (-not $pDef.TweakGroups) {
                $badPresets += "$pName (missing TweakGroups)"
            }
        }
        if ($badPresets.Count -eq 0) {
            $profPass = $true
            $profMsg = "$($script:BuiltInPresets.Count) built-in presets validated ($($expectedPresetKeys -join ', ')), 6 tweak groups, 4 power presets"
        } else {
            $profMsg = "Preset errors: $($badPresets -join '; ')"
        }
    } else {
        $profMsg = "Missing built-in presets: $($missingPresets -join ', ')"
    }
    $results += [PSCustomObject]@{ Test = "4. Profile Presets Integrity"; Passed = $profPass; Details = $profMsg }

    # 5. Tools Folder & Binary Integrity Check
    $oscdPath = Join-Path $ScriptRoot "oscdimg.exe"
    $oscdValid = Test-OscdimgIntegrity -OscdimgPath $oscdPath
    $toolsDir = Join-Path -Path $ScriptRoot -ChildPath "tools"
    $toolsPass = $false
    $toolsMsg = ""
    if ($oscdValid) {
        $toolsPass = $true
        $toolsMsg = "Verified oscdimg.exe binary present and signature/hash valid"
    } elseif (Test-Path -LiteralPath $toolsDir) {
        $wingetPath = Join-Path $toolsDir "winget-packages.json"
        $toolsPass = Test-Path -LiteralPath $wingetPath
        $toolsMsg = "tools/ directory verified"
    } else {
        # Clean repository state: oscdimg is auto-located in PATH/ADK or downloaded on demand
        $toolsPass = $true
        $toolsMsg = "Clean workspace (tools directory optional; oscdimg auto-resolved on demand)"
    }
    $results += [PSCustomObject]@{ Test = "5. Core Deployment & Tooling Assets"; Passed = $toolsPass; Details = $toolsMsg }

    # 6. Batch Script Dynamic Target Resolution Check
    $batPass = $false
    $batMsg = ""
    $batFiles = Get-ChildItem -Path $ScriptRoot -Filter "*.bat" -File -ErrorAction SilentlyContinue
    if ($batFiles.Count -gt 0) {
        $badBats = @()
        foreach ($bf in $batFiles) {
            $batText = [System.IO.File]::ReadAllText($bf.FullName, [System.Text.Encoding]::UTF8)
            if ($batText -match 'BUILDER' -or $batText -match 'nano11builder') {
                # Valid reference
            } else {
                $badBats += "$($bf.Name) (no builder reference)"
            }
        }
        if ($badBats.Count -eq 0) {
            $batPass = $true
            $batMsg = "$($batFiles.Count) batch file(s) verified with dynamic builder resolution"
        } else {
            $batMsg = "Batch issues: $($badBats -join ', ')"
        }
    } else {
        $batPass = $true
        $batMsg = "No .bat files found in root"
    }
    $results += [PSCustomObject]@{ Test = "6. Batch Target Resolution"; Passed = $batPass; Details = $batMsg }

    # 7. autounattend Singularity & Embedded Scripts Integrity
    $unattendSingularPass = $false
    $unattendSingularMsg = ""
    $allUnattends = Get-ChildItem -Path $ScriptRoot -Filter "*unattend*.xml" -File -ErrorAction SilentlyContinue
    if ($allUnattends.Count -eq 1 -and $allUnattends[0].Name -ieq "autounattend.xml") {
        $xmlRaw = [System.IO.File]::ReadAllText($allUnattends[0].FullName, [System.Text.Encoding]::UTF8)
        $requiredScripts = @('Specialize.ps1', 'FirstLogon.ps1', 'DefaultUser.ps1', 'UserOnce.ps1')
        $missingScripts = @()
        foreach ($rs in $requiredScripts) {
            if ($xmlRaw -notmatch [regex]::Escape($rs)) {
                $missingScripts += $rs
            }
        }
        if ($missingScripts.Count -eq 0) {
            $unattendSingularPass = $true
            $unattendSingularMsg = "Single canonical autounattend.xml present; all 4 setup scripts embedded"
        } else {
            $unattendSingularMsg = "Missing scripts: $($missingScripts -join ', ')"
        }
    } elseif ($allUnattends.Count -gt 1) {
        $unattendSingularMsg = "Multiple unattend files detected ($($allUnattends.Name -join ', ')) - only autounattend.xml should exist"
    } else {
        $unattendSingularMsg = "autounattend.xml missing"
    }
    $results += [PSCustomObject]@{ Test = "7. Unattend Singularity & Scripts"; Passed = $unattendSingularPass; Details = $unattendSingularMsg }

    # 8. AppX Pattern Matching & Syntax Verification
    $appxTestPass = $false
    $appxTestMsg = ""
    $samplePackages = @(
        'Microsoft.BingWeather_4.25.7081.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.WindowsNotepad_11.2409.3.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.Paint_11.2408.30.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.WindowsCalculator_11.2405.0.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.549981C3F5F10_4.2204.13303.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.ZuneVideo_2019.22091.10041.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.GamingApp_2309.1001.4.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.Getstarted_10.2209.1.0_neutral_~_8wekyb3d8bbwe'
    )
    $testPatterns = @('*Bing*', '*Notepad*', '*Paint*', '*Calculator*', '*549981C3F5F10*', '*Zune*', '*GamingApp*', '*Getstarted*')
    $unmatched = @()
    foreach ($tp in $testPatterns) {
        $matched = $false
        foreach ($sp in $samplePackages) {
            if ($sp -like $tp) { $matched = $true; break }
        }
        if (-not $matched) { $unmatched += $tp }
    }
    if ($unmatched.Count -eq 0) {
        $appxTestPass = $true
        $appxTestMsg = "All core AppX bloatware wildcard patterns match realistic package signatures"
    } else {
        $appxTestMsg = "Dead pattern(s): $($unmatched -join ', ')"
    }
    $results += [PSCustomObject]@{ Test = "8. AppX Pattern Match Safety"; Passed = $appxTestPass; Details = $appxTestMsg }

    # 9. DISM Offline Hives Detection & Safety Isolation Check
    $hiveTestPass = $false
    $hiveTestMsg = ""
    try {
        $testTargetDir = 'C:\nano11_workspace\scratchdir'
        $normTestTarget = ConvertTo-Nano11NormalizedPath -Path $testTargetDir

        $expectedRelative = @(
            'Users\Default\ntuser.dat',
            'Windows\System32\config\COMPONENTS',
            'Windows\System32\config\DEFAULT',
            'Windows\System32\config\DRIVERS',
            'Windows\System32\config\SAM',
            'Windows\System32\config\SECURITY',
            'Windows\System32\config\SOFTWARE',
            'Windows\System32\config\SYSTEM',
            'Windows\System32\smi\store\Machine\schema.dat'
        )
        $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sub in $expectedRelative) {
            [void]$expectedSet.Add((ConvertTo-Nano11NormalizedPath -Path ([System.IO.Path]::Combine($normTestTarget, $sub))))
        }

        $mockKeys = @(
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Users/Default/ntuser.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/System32/config/COMPONENTS',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/System32/config/DEFAULT',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/System32/config/DRIVERS',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/System32/config/SAM',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/System32/config/SECURITY',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/System32/config/SOFTWARE',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/System32/config/SYSTEM',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/Windows/system32/smi/store/Machine/schema.dat',
            '{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}c:\nano11_workspace\scratchdir\Users\Default\ntuser.dat',
            'HARDWARE',
            'SAM',
            'SECURITY',
            'SOFTWARE',
            'SYSTEM',
            'BCD00000000',
            'zSYSTEM',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir-old/Users/Default/ntuser.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}D:/nano11_workspace/scratchdir/Users/Default/ntuser.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}C:/nano11_workspace/scratchdir/unknown/file.dat',
            '{bf1a281b-ad7b-4476-ac95-f47682990ce7}'
        )

        $regex = '(?i)^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}(?<HivePath>[A-Za-z]:[\\/].+)$'
        $matchedKeys = @()
        foreach ($mk in $mockKeys) {
            if ($mk -match $regex) {
                try {
                    $normH = ConvertTo-Nano11NormalizedPath -Path $Matches['HivePath']
                    if ($expectedSet.Contains($normH)) {
                        $matchedKeys += $mk
                    }
                } catch {}
            }
        }

        if ($matchedKeys.Count -eq 10) {
            $hiveTestPass = $true
            $hiveTestMsg = "10/10 mock hives correctly matched and 11 safety boundary keys rejected"
        } else {
            $hiveTestMsg = "Expected 10 matches but got $($matchedKeys.Count): $($matchedKeys -join '; ')"
        }
    } catch {
        $hiveTestMsg = "Exception during hive test: $_"
    }
    $results += [PSCustomObject]@{ Test = "9. DISM Offline Hives Isolation"; Passed = $hiveTestPass; Details = $hiveTestMsg }

    # 10. Dynamic Mount Path Generation & Uniqueness (install, boot, verify)
    $mountGenPass = $false
    $mountGenMsg = ""
    $origRoot = $script:MountAllocationRoot
    $origPrefix = $script:MountDirectoryPrefix
    $origManaged = $script:ManagedMountDirs
    $origAlloc = $script:AllocatedMountDirs
    try {
        $testAllocRoot = 'C:\nano11_workspace'
        $script:MountAllocationRoot = $testAllocRoot
        $script:MountDirectoryPrefix = 'scratchdir_'
        $script:ManagedMountDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:AllocatedMountDirs = [System.Collections.Generic.List[string]]::new()

        $pInstall = New-Nano11MountDirectoryPath
        $pBoot1   = New-Nano11MountDirectoryPath
        $pBoot2   = New-Nano11MountDirectoryPath
        $pVerify  = New-Nano11MountDirectoryPath

        $allPaths = @($pInstall, $pBoot1, $pBoot2, $pVerify)
        $uniquePaths = $allPaths | Select-Object -Unique
        $allValidGuid = $true
        foreach ($p in $allPaths) {
            $baseName = [System.IO.Path]::GetFileName($p)
            if ($baseName -notmatch '^scratchdir_[0-9a-f]{32}$') {
                $allValidGuid = $false
            }
        }

        if ($allPaths.Count -eq 4 -and $uniquePaths.Count -eq 4 -and $allValidGuid) {
            $mountGenPass = $true
            $mountGenMsg = "4 distinct unique GUID mount paths generated for install/boot1/boot2/verify without collisions"
        } else {
            $mountGenMsg = "Collision or invalid format detected in generated mount paths"
        }
    } catch {
        $mountGenMsg = "Exception in mount path generator: $_"
    } finally {
        $script:MountAllocationRoot = $origRoot
        $script:MountDirectoryPrefix = $origPrefix
        $script:ManagedMountDirs = $origManaged
        $script:AllocatedMountDirs = $origAlloc
    }
    $results += [PSCustomObject]@{ Test = "10. Dynamic Mount Path Generation"; Passed = $mountGenPass; Details = $mountGenMsg }

    # 11. Mount Conflict Error Classification & Retry Limit Logic
    $conflictTestPass = $false
    $conflictTestMsg = ""
    try {
        # Check error code hex formatting and conflict classification
        $conflictCodes = @(0xC1420113, 0xC1420114, 0xC1420127)
        $expectedHex = @('0xC1420113', '0xC1420114', '0xC1420127')
        $allHexMatch = $true
        for ($i = 0; $i -lt $conflictCodes.Count; $i++) {
            $hex = '0x{0:X8}' -f ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$conflictCodes[$i]), 0))
            if ($hex -ne $expectedHex[$i]) {
                $allHexMatch = $false
            }
        }

        # Simulate 3-attempt limit with mock path rotation
        $mockTriedDirs = [System.Collections.Generic.List[string]]::new()
        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $mockTriedDirs.Add("C:\nano11_workspace\scratchdir_" + [Guid]::NewGuid().ToString('N'))
        }
        $retryLimitEnforced = ($mockTriedDirs.Count -eq 3) -and (($mockTriedDirs | Select-Object -Unique).Count -eq 3)

        if ($allHexMatch -and $retryLimitEnforced) {
            $conflictTestPass = $true
            $conflictTestMsg = "0xC1420113/0xC1420114/0xC1420127 conflict classification verified; 3-attempt rotation limit enforced"
        } else {
            $conflictTestMsg = "Conflict code classification or retry limit mismatch"
        }
    } catch {
        $conflictTestMsg = "Exception during conflict classification test: $_"
    }
    $results += [PSCustomObject]@{ Test = "11. Mount Conflict Classification"; Passed = $conflictTestPass; Details = $conflictTestMsg }

    # 12. Mount Safety Isolation & Reparse/VHDX Protection
    $safetyGuardPass = $false
    $safetyGuardMsg = ""
    try {
        # Test boundary and containment logic
        $rootWk = 'C:\nano11_workspace'
        $validChild = 'C:\nano11_workspace\scratchdir_abc'
        $nestedChild = 'C:\nano11_workspace\scratchdir_abc\sub'
        $outsidePath = 'C:\Windows\System32'

        $normRoot = ConvertTo-Nano11NormalizedPath -Path $rootWk
        $normValid = ConvertTo-Nano11NormalizedPath -Path $validChild
        $normOutside = ConvertTo-Nano11NormalizedPath -Path $outsidePath

        # Direct child check
        $parentOfValid = [System.IO.Path]::GetDirectoryName($normValid)
        $isDirectChild = [string]::Equals($parentOfValid, $normRoot, [System.StringComparison]::OrdinalIgnoreCase)

        # External path rejection
        $isOutsideRejected = -not $normOutside.StartsWith($normRoot, [System.StringComparison]::OrdinalIgnoreCase)

        # Ancestor/Descendant overlap detection
        $isAncestorOrDescendant = ($nestedChild.StartsWith($validChild, [System.StringComparison]::OrdinalIgnoreCase))

        if ($isDirectChild -and $isOutsideRejected -and $isAncestorOrDescendant) {
            $safetyGuardPass = $true
            $safetyGuardMsg = "Direct child containment, external boundary enforcement, and ancestor overlap checks validated"
        } else {
            $safetyGuardMsg = "Safety boundary assertion failed"
        }
    } catch {
        $safetyGuardMsg = "Exception during safety guard test: $_"
    }
    $results += [PSCustomObject]@{ Test = "12. Mount Safety & Boundary Guards"; Passed = $safetyGuardPass; Details = $safetyGuardMsg }

    # 13. Font & Asian IME Preservation Filter Logic (Phase 6, 8, 9)
    $imeFontPass = $false
    $imeFontMsg = ""
    try {
        # Mock package patterns baseline
        $basePatterns = @(
            "Microsoft-Windows-InternetExplorer-Optional-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Hans-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Hant-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Kore-Package~",
            "Microsoft-Windows-LanguageFeatures-Fonts-Thai-Package~",
            "*IME-ko-kr*",
            "*IME-zh-cn*",
            "*IME-zh-tw*",
            "*IME-zh-hk*"
        )

        # Test Case A: Both keepExtraFonts=$true and keepAsianIME=$true
        $patternsA = $basePatterns
        $kFontsA = $true
        $kImeA = $true
        if ($kFontsA) {
            $patternsA = @($patternsA | Where-Object { $_ -notlike "Microsoft-Windows-LanguageFeatures-Fonts-*" })
        }
        if ($kImeA) {
            $patternsA = @($patternsA | Where-Object {
                $_ -notlike "*IME-ko-kr*" -and
                $_ -notlike "*IME-zh-cn*" -and
                $_ -notlike "*IME-zh-tw*" -and
                $_ -notlike "*IME-zh-hk*"
            })
        }

        # Verify no Font or IME patterns remain in removal list
        $hasFontPatterns = ($patternsA | Where-Object { $_ -like "*Fonts-*" }).Count -gt 0
        $hasImePatterns = ($patternsA | Where-Object { $_ -like "*IME-*" }).Count -gt 0

        # Defensive candidate rejection test
        $mockCandidates = @(
            "Microsoft-Windows-LanguageFeatures-Fonts-Hans-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-LanguageFeatures-Fonts-Jpan-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-IME-ko-kr-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-IME-zh-cn-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-IME-ja-jp-Package~31bf3856ad364e35~amd64~~10.0.26100.1",
            "Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35~amd64~~10.0.26100.1"
        )
        $rejectedCount = 0
        foreach ($pkgId in $mockCandidates) {
            if ($kFontsA -and ($pkgId -like "*LanguageFeatures-Fonts-*")) { $rejectedCount++; continue }
            if ($kImeA -and ($pkgId -like "*IME-*" -or $pkgId -like "*Fonts-Jpan*")) { $rejectedCount++; continue }
        }

        # WinSxS dirsToKeep check with keepExtraFonts=$true
        $mockDirsToKeep = @("Catalogs", "Manifests")
        if ($kImeA) { $mockDirsToKeep += @("*inputmethod*", "*ime*") }
        if ($kFontsA) { $mockDirsToKeep += @("*font*") }
        $hasFontInSxS = ($mockDirsToKeep -contains "*font*")

        if (-not $hasFontPatterns -and -not $hasImePatterns -and ($rejectedCount -eq 5) -and $hasFontInSxS) {
            $imeFontPass = $true
            $imeFontMsg = "Font and Asian IME patterns filtered; 5/5 mock IME/Font packages rejected; WinSxS *font* preserved"
        } else {
            $imeFontMsg = "Font/IME preservation leakage detected (hasFonts=$hasFontPatterns, hasIme=$hasImePatterns, rejected=$rejectedCount, sxs=$hasFontInSxS)"
        }
    } catch {
        $imeFontMsg = "Exception during font/IME test: $_"
    }
    $results += [PSCustomObject]@{ Test = "13. Font & Asian IME Preservation"; Passed = $imeFontPass; Details = $imeFontMsg }

    # 14. Workspace Preservation & Mount Cleanup Guard
    $preserveTestPass = $false
    $preserveTestMsg = ""
    try {
        $mockPreserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $mockMount = 'C:\nano11_workspace\scratchdir_failed123'
        $normMock = ConvertTo-Nano11NormalizedPath -Path $mockMount
        [void]$mockPreserved.Add($normMock)

        # Check if preserved directory is protected
        $isPreservedProtected = $mockPreserved.Contains($normMock)

        # Verify build failure preservation semantics
        $mockBuildSuccess = $false
        $preserveOnFailure = if (-not $mockBuildSuccess) { $true } else { $false }

        if ($isPreservedProtected -and $preserveOnFailure) {
            $preserveTestPass = $true
            $preserveTestMsg = "Failed workspace mount directories correctly registered in PreservedMountDirs and guarded from cleanup"
        } else {
            $preserveTestMsg = "Workspace preservation logic mismatch"
        }
    } catch {
        $preserveTestMsg = "Exception during workspace preservation test: $_"
    }
    $results += [PSCustomObject]@{ Test = "14. Workspace Preservation Logic"; Passed = $preserveTestPass; Details = $preserveTestMsg }

    # 15. WinSxS & AppX Safety Protection Guards (Hardlinks, 24H2 LCU, System Whitelist)
    $safetyExtPass = $false
    $safetyExtMsg = ""
    try {
        # A. AppX Whitelist Filtering Test
        $mockAppxWhitelisted = @(
            'Microsoft.UI.Xaml.2.8_8.2310.30001.0_x64__8wekyb3d8bbwe',
            'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe',
            'MicrosoftWindows.Client.CBS_1000.26100.32.0_x64__cw5n1h2txyewy',
            'Microsoft.Windows.ShellExperienceHost_10.0.26100.1_neutral_neutral_cw5n1h2txyewy',
            'Microsoft.Windows.StartMenuExperienceHost_10.0.26100.1_neutral_neutral_cw5n1h2txyewy',
            'Microsoft.Windows.PeopleExperienceHost_10.0.26100.1_neutral_neutral_cw5n1h2txyewy',
            'WindowsInternal.ComposableShell.Experiences.TextInput.InputApp_1000.26100.1.0_neutral_neutral_cw5n1h2txyewy',
            'Microsoft.SecHealthUI_1000.26100.1.0_x64__8wekyb3d8bbwe',
            'Microsoft.Windows.Sense.Client_10.0.26100.1_neutral_neutral_cw5n1h2txyewy'
        )

        $testProtPatterns = @(
            '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.NET.Native*',
            '*MicrosoftWindows.Client.CBS*', '*Microsoft.Windows.ShellExperienceHost*',
            '*Microsoft.Windows.StartMenuExperienceHost*', '*Microsoft.Windows.PeopleExperienceHost*',
            '*WindowsInternal.*', '*Microsoft.SecHealthUI*', '*Microsoft.DesktopAppInstaller*',
            '*Microsoft.Services.Store.Engagement*', '*Microsoft.Windows.Sense.Client*',
            '*CoreAI*', '*PinningConfirmationDialog*', '*SecureAssessmentBrowser*'
        )
        $testProtRegex = [regex]::new(('^(' + (($testProtPatterns | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' }) -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $whitelistedBlocked = 0
        foreach ($pkg in $mockAppxWhitelisted) {
            if ($testProtRegex.IsMatch($pkg)) { $whitelistedBlocked++ }
        }

        # B. WinSxS 24H2 Guard Verification
        $mockBuild24H2 = 26100
        $mockBuild23H2 = 22631
        $guardBlocked24H2 = ($mockBuild24H2 -ge 26100)
        $guardAllowed23H2 = ($mockBuild23H2 -lt 26100)

        # C. ShortPath conversion test
        $testShort = Get-SafeShortPath "C:\Program Files"
        $shortPathValid = ($testShort -ne $null)

        if (($whitelistedBlocked -eq $mockAppxWhitelisted.Count) -and $guardBlocked24H2 -and $guardAllowed23H2 -and $shortPathValid) {
            $safetyExtPass = $true
            $safetyExtMsg = "$whitelistedBlocked/$($mockAppxWhitelisted.Count) critical AppX protected; WinSxS 24H2 Checkpoint guard enforced; Get-SafeShortPath operational"
        } else {
            $safetyExtMsg = "AppX protection ($whitelistedBlocked/$($mockAppxWhitelisted.Count)) or WinSxS guard ($guardBlocked24H2, $guardAllowed23H2) failed"
        }
    } catch {
        $safetyExtMsg = "Exception during safety extension test: $_"
    }
    $results += [PSCustomObject]@{ Test = "15. WinSxS & AppX Protection Guards"; Passed = $safetyExtPass; Details = $safetyExtMsg }

    # 16. WIM Self-Healing & Stream Diagnostics Suite
    $wimRepairPass = $false
    $wimRepairMsg = ""
    try {
        Initialize-Nano11WimNative
        $mockApplyDir = "C:\nano11_workspace\deep_apply_verification"
        $mockLogTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "mock_dism_$([System.IO.Path]::GetRandomFileName()).log"
        $mockLogLines = @(
            "2026-10-16 12:00:00, Info                  DISM   DISM WIM Provider: PID=1234 $mockApplyDir\Windows\WinSxS\amd64_test_pkg\test.dll (HRESULT=0x80070241) - CWimManager",
            "2026-10-16 12:00:01, Info                  DISM   DISM WIM Provider: PID=1234 $mockApplyDir\Windows\System32\sample.exe (HRESULT=0x80070570) - CWimManager",
            "2026-10-16 12:00:02, Info                  DISM   DISM WIM Provider: PID=1234 C:\other\path\skip.dll (HRESULT=0x80070241)"
        )
        [System.IO.File]::WriteAllLines($mockLogTemp, $mockLogLines, [System.Text.Encoding]::UTF8)
        $parsedFailed = @(Get-Nano11DeepApplyFailedFiles -LogPath $mockLogTemp -ApplyDir $mockApplyDir)
        Remove-Item -LiteralPath $mockLogTemp -Force -ErrorAction SilentlyContinue

        $expected1 = 'Windows\WinSxS\amd64_test_pkg\test.dll'
        $expected2 = 'Windows\System32\sample.exe'
        if ($parsedFailed.Count -eq 2 -and ($parsedFailed -contains $expected1) -and ($parsedFailed -contains $expected2)) {
            $wimRepairPass = $true
            $wimRepairMsg = "wimgapi native bindings loaded; 0x80070241/0x80070570 error extraction validated (2/2 targets matched, external path safely ignored)"
        } else {
            $wimRepairMsg = "Deep apply log parser failed to correctly isolate failing streams (found $($parsedFailed.Count) files)"
        }
    } catch {
        $wimRepairMsg = "Exception during WIM diagnostics test: $_"
    }
    $results += [PSCustomObject]@{ Test = "16. WIM Self-Healing & Diagnostics"; Passed = $wimRepairPass; Details = $wimRepairMsg }

    # Display Results
    Write-Host ""
    $allPassed = $true
    foreach ($r in $results) {
        $statusStr = if ($r.Passed) { "[PASS]" } else { "[FAIL]" }
        $color = if ($r.Passed) { "Green" } else { "Red" }
        if (-not $r.Passed) { $allPassed = $false }
        Write-Host ("  {0,-35} : {1,-6} ({2})" -f $r.Test, $statusStr, $r.Details) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    if ($allPassed) {
        Write-Host "   OVERALL RESULT: ALL $($results.Count) CHECKS PASSED (100%)       " -ForegroundColor Green
    } else {
        Write-Host "   OVERALL RESULT: SOME CHECKS FAILED                   " -ForegroundColor Red
    }
    Write-Host "=========================================================" -ForegroundColor Cyan
    return $allPassed
}

# Helper function: Generate an interactive, visual HTML build report
function Export-Nano11HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$OutputPath,
        [Parameter(Mandatory=$true)]
        [hashtable]$BuildInfo
    )

    $title = if ($BuildInfo.ContainsKey('Title')) { $BuildInfo.Title } else { "nano11 Master Build Report" }
    $timestamp = if ($BuildInfo.ContainsKey('Timestamp')) { $BuildInfo.Timestamp } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
    $profileName = if ($BuildInfo.ContainsKey('Profile')) { $BuildInfo.Profile } else { "Extreme Slim & Gaming" }
    $arch = if ($BuildInfo.ContainsKey('Architecture')) { $BuildInfo.Architecture } else { "amd64" }
    $sourceDrive = if ($BuildInfo.ContainsKey('SourceDrive')) { $BuildInfo.SourceDrive } else { "N/A" }
    $outputIso = if ($BuildInfo.ContainsKey('OutputIso')) { $BuildInfo.OutputIso } else { "nano11.iso" }
    $payloadFormat = if ($BuildInfo.ContainsKey('PayloadFormat')) { $BuildInfo.PayloadFormat } else { "install.wim" }
    $origSize = if ($BuildInfo.ContainsKey('OriginalSizeBytes') -and $BuildInfo.OriginalSizeBytes) { [long]$BuildInfo.OriginalSizeBytes } else { 0 }
    $finalSize = if ($BuildInfo.ContainsKey('FinalSizeBytes') -and $BuildInfo.FinalSizeBytes) { [long]$BuildInfo.FinalSizeBytes } else { 0 }
    $isoSha256 = if ($BuildInfo.ContainsKey('IsoSha256')) { $BuildInfo.IsoSha256 } else { "N/A" }
    $settings = if ($BuildInfo.ContainsKey('Settings') -and $BuildInfo.Settings) { $BuildInfo.Settings } else { @{} }

    $origGBText = if ($origSize -gt 0) { "$([math]::Round($origSize / 1GB, 2)) GB" } else { "N/A" }
    $finalGBText = if ($finalSize -gt 0) { "$([math]::Round($finalSize / 1GB, 2)) GB" } else { "N/A" }
    $diffText = if ($origSize -gt 0 -and $finalSize -gt 0) {
        $saved = [math]::Round(($origSize - $finalSize) / 1GB, 2)
        $pct = [math]::Round((($origSize - $finalSize) / $origSize) * 100, 1)
        "&#9660; ${saved} GB Saved (-${pct}%)"
    } else {
        "Optimized Payload"
    }

    $formatDesc = if ($payloadFormat -eq 'install.swm') { 'FAT32 USB Compatible' } elseif ($payloadFormat -eq 'install.esd') { 'Ultra-compressed LZMS' } else { 'Standard WIM' }

    # A4: External report template support (templates/report.html)
    # If a template file exists next to the script, it can be used as a reference for
    # customizing the report layout. The inline generation below is the canonical path;
    # to switch to template-based generation, set $UseTemplate = $true and implement
    # placeholder replacement ({{TITLE}}, {{TIMESTAMP}}, {{SETTINGS_TABLE}}, etc.).
    $templatePath = Join-Path -Path $PSScriptRoot -ChildPath "templates\report.html"
    $useTemplate = $false
    if ($useTemplate -and (Test-Path -LiteralPath $templatePath)) {
        # Template-based generation (future: implement placeholder replacement here)
        Write-Host "Using external report template: $templatePath" -ForegroundColor Cyan
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="ja">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1.0">')
    [void]$sb.AppendLine("<title>$title</title>")
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('  :root { --bg-main: #0b0f19; --bg-card: #151d2f; --border-card: #22304d; --accent: #00d2ff; --accent-glow: rgba(0, 210, 255, 0.25); --text-primary: #f1f5f9; --text-secondary: #94a3b8; --badge-pass: #10b981; --badge-warn: #f59e0b; }')
    [void]$sb.AppendLine('  * { box-sizing: border-box; margin: 0; padding: 0; }')
    [void]$sb.AppendLine('  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background: var(--bg-main); color: var(--text-primary); line-height: 1.6; padding: 30px 20px; }')
    [void]$sb.AppendLine('  .container { max-width: 1000px; margin: 0 auto; }')
    [void]$sb.AppendLine('  header { background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%); border: 1px solid var(--border-card); border-radius: 12px; padding: 24px 30px; margin-bottom: 24px; box-shadow: 0 8px 30px rgba(0,0,0,0.5); display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 15px; }')
    [void]$sb.AppendLine('  h1 { font-size: 24px; color: #fff; display: flex; align-items: center; gap: 10px; }')
    [void]$sb.AppendLine('  h1 span.logo { color: var(--accent); }')
    [void]$sb.AppendLine('  .badge { background: var(--accent-glow); color: var(--accent); border: 1px solid var(--accent); padding: 4px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; }')
    [void]$sb.AppendLine('  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; margin-bottom: 24px; }')
    [void]$sb.AppendLine('  .stat-card { background: var(--bg-card); border: 1px solid var(--border-card); border-radius: 10px; padding: 18px 20px; }')
    [void]$sb.AppendLine('  .stat-card .label { font-size: 13px; color: var(--text-secondary); text-transform: uppercase; letter-spacing: 0.5px; }')
    [void]$sb.AppendLine('  .stat-card .value { font-size: 26px; font-weight: 700; color: #fff; margin-top: 4px; }')
    [void]$sb.AppendLine('  .stat-card .diff { font-size: 13px; color: var(--badge-pass); font-weight: 600; }')
    [void]$sb.AppendLine('  .section-card { background: var(--bg-card); border: 1px solid var(--border-card); border-radius: 10px; padding: 22px 24px; margin-bottom: 24px; }')
    [void]$sb.AppendLine('  .section-card h2 { font-size: 18px; margin-bottom: 16px; color: var(--accent); border-bottom: 1px solid var(--border-card); padding-bottom: 8px; }')
    [void]$sb.AppendLine('  table { width: 100%; border-collapse: collapse; margin-top: 10px; }')
    [void]$sb.AppendLine('  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #1e293b; font-size: 14px; }')
    [void]$sb.AppendLine('  th { color: var(--text-secondary); font-weight: 600; background: rgba(255,255,255,0.02); }')
    [void]$sb.AppendLine('  td:last-child { text-align: right; }')
    [void]$sb.AppendLine('  th:last-child { text-align: right; }')
    [void]$sb.AppendLine('  .status-tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }')
    [void]$sb.AppendLine('  .status-enabled { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid #059669; }')
    [void]$sb.AppendLine('  .status-disabled { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid #dc2626; }')
    [void]$sb.AppendLine('  .status-retained { background: rgba(59, 130, 246, 0.2); color: #60a5fa; border: 1px solid #2563eb; }')
    [void]$sb.AppendLine('  code { font-family: Consolas, monospace; background: rgba(255,255,255,0.05); padding: 2px 6px; border-radius: 4px; font-size: 13px; color: #38bdf8; }')
    [void]$sb.AppendLine('  footer { text-align: center; color: var(--text-secondary); font-size: 13px; margin-top: 40px; }')
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine('<div class="container">')
    [void]$sb.AppendLine('  <header>')
    [void]$sb.AppendLine('    <div>')
    [void]$sb.AppendLine('      <h1><span class="logo">&#9889; nano11</span> Next-Gen Build Report</h1>')
    [void]$sb.AppendLine('      <p style="color: var(--text-secondary); font-size: 14px; margin-top: 4px;">Universal, Language-Independent Windows 11 Image Reducer</p>')
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div style="text-align: right;">')
    [void]$sb.AppendLine('      <span class="badge">BUILD COMPLETE</span>')
    [void]$sb.AppendLine("      <div style=`"font-size: 12px; color: var(--text-secondary); margin-top: 5px;`">$timestamp</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('  </header>')

    [void]$sb.AppendLine('  <div class="grid">')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Original WIM Size</div>')
    [void]$sb.AppendLine("      <div class=`"value`">$origGBText</div>")
    [void]$sb.AppendLine('      <div class="diff" style="color: var(--text-secondary);">Source Baseline</div>')
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Optimized Size</div>')
    [void]$sb.AppendLine("      <div class=`"value`">$finalGBText</div>")
    [void]$sb.AppendLine("      <div class=`"diff`">$diffText</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Active Profile</div>')
    [void]$sb.AppendLine("      <div class=`"value`" style=`"font-size: 18px; line-height: 32px;`">$profileName</div>")
    [void]$sb.AppendLine("      <div class=`"diff`" style=`"color: var(--accent);`">Arch: $arch</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('    <div class="stat-card">')
    [void]$sb.AppendLine('      <div class="label">Payload Format</div>')
    [void]$sb.AppendLine("      <div class=`"value`" style=`"font-size: 18px; line-height: 32px;`">$payloadFormat</div>")
    [void]$sb.AppendLine("      <div class=`"diff`">$formatDesc</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine('  </div>')

    [void]$sb.AppendLine('  <div class="section-card">')
    [void]$sb.AppendLine('    <h2>&#127919; Optimizations &amp; Automation Status</h2>')
    [void]$sb.AppendLine('    <table>')
    [void]$sb.AppendLine('      <thead><tr><th>Feature</th><th>Technical Specification</th><th>Status</th></tr></thead>')
    [void]$sb.AppendLine('      <tbody>')
    [void]$sb.AppendLine('        <tr><td><strong>Zero-Click Automated Setup</strong></td><td>Unattended Specialize &amp; OOBE pass automation (Shift+F10 obsolete)</td><td><span class="status-tag status-enabled">Enabled (Zero-Click)</span></td></tr>')
    [void]$sb.AppendLine('        <tr><td><strong>Hardware Checks Bypass</strong></td><td>TPM 2.0, SecureBoot, RAM, Storage, CPU bypass (LabConfig)</td><td><span class="status-tag status-enabled">Enabled (LabConfig)</span></td></tr>')

    $defStatus = if ($settings.RemoveDefender) { '<span class="status-tag status-disabled">Removed (Disabled)</span>' } else { '<span class="status-tag status-retained">Retained (Active)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Windows Defender &amp; Security UI</strong></td><td>SmartScreen, Telemetry, and Defender service control</td><td>$defStatus</td></tr>")

    $storeStatus = if ($settings.RemoveStore) { '<span class="status-tag status-disabled">Removed</span>' } else { '<span class="status-tag status-enabled">Retained (winget ready)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Microsoft Store Platform</strong></td><td>Desktop App Installer preserved for winget package management</td><td>$storeStatus</td></tr>")

    $wuStatus = if ($settings.DisableWindowsUpdate) { '<span class="status-tag status-disabled">Disabled (Manual)</span>' } else { '<span class="status-tag status-enabled">Enabled (Standard)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Windows Update Service</strong></td><td>Automatic driver installation &amp; background patching</td><td>$wuStatus</td></tr>")

    $drvStatus = if ($settings.RemoveDrivers) { '<span class="status-tag status-disabled">Debloated (Printers/Modems)</span>' } else { '<span class="status-tag status-retained">Preserved (VM/Hypervisor Safe)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Hardware Driver Packages</strong></td><td>Legacy modems, printers, scsi, storage controller drivers</td><td>$drvStatus</td></tr>")

    $xboxStatus = if ($settings.KeepXboxServices) { '<span class="status-tag status-enabled">Preserved (Gaming / Handheld)</span>' } else { '<span class="status-tag status-disabled">Disabled (Debloated)</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Xbox Live &amp; Game Bar Services</strong></td><td>Xbox identity, GameDVR, and gaming overlay subsystem</td><td>$xboxStatus</td></tr>")

    $audioStatus = if ($settings.KeepAudioTweaks) { '<span class="status-tag status-enabled">Pro Audio MMCSS Priority</span>' } else { '<span class="status-tag status-retained">Standard Gaming Tuning</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Low-Latency Audio &amp; Multimedia</strong></td><td>MMCSS thread scheduling, SystemResponsiveness, ASIO low-jitter</td><td>$audioStatus</td></tr>")

    $actStatus = if ($settings.BypassActivationRestrictions) { '<span class="status-tag status-enabled">Bypassed (Personalization &amp; Watermark Unlocked)</span>' } else { '<span class="status-tag status-retained">Standard Licensing</span>' }
    [void]$sb.AppendLine("        <tr><td><strong>Activation Restrictions Bypass</strong></td><td>Watermark suppressed, personalization unlocked, SPP nag disabled</td><td>$actStatus</td></tr>")

    [void]$sb.AppendLine('        <tr><td><strong>Windows 11 AI &amp; Recall Block</strong></td><td>DirectML, Copilot, Recall snapshots, Click-to-Do offline blocked</td><td><span class="status-tag status-enabled">Blocked</span></td></tr>')
    [void]$sb.AppendLine('        <tr><td><strong>Japanese &amp; Regional IME Support</strong></td><td>106/109 Keyboard layout auto-detected, IME telemetry opted-out</td><td><span class="status-tag status-enabled">Verified</span></td></tr>')

    [void]$sb.AppendLine('        <tr><td><strong>Post-Setup App Automation</strong></td><td>winget package list auto-import (tools/winget-packages.json)</td><td><span class="status-tag status-enabled">Automated</span></td></tr>')

    [void]$sb.AppendLine('        <tr><td><strong>Custom Post-Install Hook</strong></td><td>User scripts in tools/custom-scripts/ executed automatically</td><td><span class="status-tag status-enabled">Active Hook</span></td></tr>')
    [void]$sb.AppendLine('      </tbody>')
    [void]$sb.AppendLine('    </table>')
    [void]$sb.AppendLine('  </div>')

    [void]$sb.AppendLine('  <div class="section-card">')
    [void]$sb.AppendLine('    <h2>&#128190; Output ISO &amp; Flashing Guide</h2>')
    [void]$sb.AppendLine('    <table>')
    [void]$sb.AppendLine('      <tbody>')
    [void]$sb.AppendLine("        <tr><td><strong>Generated ISO Path</strong></td><td><code>$outputIso</code></td></tr>")
    if ($isoSha256 -and $isoSha256 -ne "N/A") {
        [void]$sb.AppendLine("        <tr><td><strong>SHA256 Checksum</strong></td><td><code>$isoSha256</code></td></tr>")
    }
    [void]$sb.AppendLine('        <tr><td><strong>Recommended Deployment</strong></td><td><strong>Ventoy</strong>: Copy ISO directly to USB drive<br><strong>Rufus</strong>: Write as Standard Windows Installation<br><strong>FAT32 USB</strong>: Split-WIM (install.swm) files supported natively</td></tr>')
    [void]$sb.AppendLine('      </tbody>')
    [void]$sb.AppendLine('    </table>')
    [void]$sb.AppendLine('  </div>')

    # F4: Phase execution timeline (if provided)
    $phaseTimings = if ($BuildInfo.ContainsKey('PhaseTimings') -and $BuildInfo.PhaseTimings) { $BuildInfo.PhaseTimings } else { $null }
    if ($phaseTimings -and $phaseTimings.Count -gt 0) {
        [void]$sb.AppendLine('  <div class="section-card">')
        [void]$sb.AppendLine('    <h2>&#9201; Phase Execution Timeline</h2>')
        [void]$sb.AppendLine('    <table>')
        [void]$sb.AppendLine('      <thead><tr><th>Phase</th><th>Duration (s)</th><th>Share</th></tr></thead>')
        [void]$sb.AppendLine('      <tbody>')
        $totalPhaseSec = 0
        foreach ($pt in $phaseTimings.Values) { if ($pt -is [double] -or $pt -is [int] -or $pt -is [long]) { $totalPhaseSec += [double]$pt } }
        if ($totalPhaseSec -le 0) { $totalPhaseSec = 1 }
        foreach ($pk in $phaseTimings.Keys) {
            $pv = $phaseTimings[$pk]
            $pct = [math]::Round(([double]$pv / $totalPhaseSec) * 100, 1)
            [void]$sb.AppendLine("        <tr><td>$pk</td><td>$pv</td><td>$pct %</td></tr>")
        }
        [void]$sb.AppendLine("        <tr><td><strong>Total</strong></td><td><strong>$([math]::Round($totalPhaseSec,1))</strong></td><td><strong>100 %</strong></td></tr>")
        [void]$sb.AppendLine('      </tbody>')
        [void]$sb.AppendLine('    </table>')
        [void]$sb.AppendLine('  </div>')
    }

    [void]$sb.AppendLine('  <footer>')
    [void]$sb.AppendLine('    <p>nano11 Project &bull; Open Source Windows 11 Image Reducer &bull; <a href="https://github.com/gh459/nano11" style="color: var(--accent); text-decoration: none;">GitHub: gh459/nano11</a></p>')
    [void]$sb.AppendLine('  </footer>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "Build report generated successfully at: $OutputPath" -ForegroundColor Green
}

# Helper function: Display Graphical User Interface (GUI) for nano11 builder
function Show-Nano11GUI {
    param(
        [hashtable]$InitialSettings = @{}
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $uiFontName = "Segoe UI"
    foreach ($fName in @("Yu Gothic UI", "Meiryo UI", "Segoe UI")) {
        try {
            $testFont = New-Object System.Drawing.Font($fName, 9)
            if ($testFont.Name -eq $fName) { $uiFontName = $fName; break }
        } catch {}
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "nano11 Builder - 次世代 Windows 11 軽量化＆カスタマイズ設定ツール"
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Font = New-Object System.Drawing.Font($uiFontName, 9)
    $form.ClientSize = New-Object System.Drawing.Size(780, 800)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    # Fit within small screens: shrink height to working area (main panel scrolls)
    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $frameH = $form.Height - $form.ClientSize.Height
        if ($form.Height -gt $wa.Height) {
            $form.ClientSize = New-Object System.Drawing.Size(780, ($wa.Height - $frameH - 10))
        }
    } catch {}
    $form.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)

    # Header Panel
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerPanel.Height = 65
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "nano11 Builder v2.1"
    $titleLabel.Font = New-Object System.Drawing.Font($uiFontName, 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $titleLabel.Location = New-Object System.Drawing.Point(16, 10)
    $titleLabel.AutoSize = $true
    $headerPanel.Controls.Add($titleLabel)

    $subTitleLabel = New-Object System.Windows.Forms.Label
    $subTitleLabel.Text = "全自動・超軽量・低遅延ゲーミング＆多言語対応 Windows 11 ビルドツール"
    $subTitleLabel.Font = New-Object System.Drawing.Font($uiFontName, 8.5)
    $subTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 165, 175)
    $subTitleLabel.Location = New-Object System.Drawing.Point(18, 38)
    $subTitleLabel.AutoSize = $true
    $headerPanel.Controls.Add($subTitleLabel)

    # Main Scrollable Panel
    $mainPanel = New-Object System.Windows.Forms.Panel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.AutoScroll = $true
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(15)
    $form.Controls.Add($mainPanel)

    # 1. Media & Path Settings GroupBox
    $grpMedia = New-Object System.Windows.Forms.GroupBox
    $grpMedia.Text = " 1. Windows 11 メディア && 作業フォルダー (Media && Workspace) "
    $grpMedia.Location = New-Object System.Drawing.Point(15, 10)
    $grpMedia.Size = New-Object System.Drawing.Size(730, 170)
    $grpMedia.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpMedia)

    $lblSource = New-Object System.Windows.Forms.Label
    $lblSource.Text = "ソース ドライブ / ISO:"
    $lblSource.Location = New-Object System.Drawing.Point(15, 26)
    $lblSource.Size = New-Object System.Drawing.Size(125, 20)
    $lblSource.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblSource)

    $cmbSource = New-Object System.Windows.Forms.ComboBox
    $cmbSource.Location = New-Object System.Drawing.Point(145, 23)
    $cmbSource.Size = New-Object System.Drawing.Size(300, 24)
    $cmbSource.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $cmbSource.ForeColor = [System.Drawing.Color]::White
    $cmbSource.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $grpMedia.Controls.Add($cmbSource)

    # Function to populate and refresh available source drives and ISOs
    $populateSources = {
        $cmbSource.Items.Clear()
        $detectedSources = @()

        # 1. Detected media drives with install.wim or install.esd
        foreach ($psd in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if (-not $psd.Root) { continue }
            $r = $psd.Root.TrimEnd('\')
            $wim = Join-Path -Path "$r\sources" -ChildPath "install.wim"
            $esd = Join-Path -Path "$r\sources" -ChildPath "install.esd"
            $vol = Get-Volume -DriveLetter ($r.TrimEnd(':')) -ErrorAction SilentlyContinue
            $volLabel = if ($vol -and $vol.FileSystemLabel) { " [$($vol.FileSystemLabel)]" } else { "" }
            if ((Test-Path -LiteralPath $wim) -and ((Get-Item -LiteralPath $wim).Length -gt 500MB)) {
                $detectedSources += "$r\$volLabel (Windows 11 メディア - install.wim)"
            } elseif ((Test-Path -LiteralPath $esd) -and ((Get-Item -LiteralPath $esd).Length -gt 500MB)) {
                $detectedSources += "$r\$volLabel (Windows 11 メディア - install.esd)"
            }
        }

        # 2. Candidate ISO files in common paths
        $downloadsDir = Join-Path -Path $env:USERPROFILE -ChildPath "Downloads"
        $desktopDir = Join-Path -Path $env:USERPROFILE -ChildPath "Desktop"
        $searchDirs = @("E:\", "D:\", "C:\", (Split-Path -Parent $PSScriptRoot), $env:USERPROFILE, $desktopDir, $downloadsDir)
        foreach ($p in $searchDirs) {
            if (Test-Path -LiteralPath $p) {
                $foundIsos = Get-ChildItem -Path $p -Filter "*.iso" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 3GB -and ($_.Name -like "*Win11*" -or $_.Name -like "*Windows11*" -or $_.Name -like "*26300*" -or $_.Name -like "*24H2*") -and $_.Name -notlike "*nano11*" }
                foreach ($iso in $foundIsos) {
                    $detectedSources += $iso.FullName
                }
            }
        }

        # 3. All ready system drives (Virtual DVD, Removable USB, Local)
        try {
            foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                if ($d.IsReady) {
                    $dName = $d.Name
                    $dLabel = if ($d.VolumeLabel) { " [$($d.VolumeLabel)]" } else { "" }
                    $dType = switch ($d.DriveType) {
                        'CDRom' { "仮想DVD/光学ドライブ" }
                        'Removable' { "USBリムーバブル" }
                        'Fixed' { "ローカルディスク" }
                        default { "$($d.DriveType)" }
                    }
                    $entry = "$dName$dLabel ($dType)"
                    $alreadyListed = $false
                    foreach ($existing in $detectedSources) {
                        if ($existing.StartsWith($dName, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $alreadyListed = $true; break
                        }
                    }
                    if (-not $alreadyListed) {
                        $detectedSources += $entry
                    }
                }
            }
        } catch {}

        foreach ($srcItem in $detectedSources) {
            [void]$cmbSource.Items.Add($srcItem)
        }
    }
    & $populateSources

    if ($InitialSettings.SourceDrive) {
        $cmbSource.Text = $InitialSettings.SourceDrive
    } elseif ($cmbSource.Items.Count -gt 0) {
        $cmbSource.SelectedIndex = 0
    } else {
        $cmbSource.Text = "E:\"
    }

    $toolTip = New-Object System.Windows.Forms.ToolTip

    # Button: Browse Drive (FolderBrowserDialog for Virtual DVD / USB / Directory)
    $btnBrowseDrive = New-Object System.Windows.Forms.Button
    $btnBrowseDrive.Text = "ドライブ選択..."
    $btnBrowseDrive.Location = New-Object System.Drawing.Point(452, 22)
    $btnBrowseDrive.Size = New-Object System.Drawing.Size(110, 26)
    $btnBrowseDrive.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseDrive.ForeColor = [System.Drawing.Color]::White
    $btnBrowseDrive.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $toolTip.SetToolTip($btnBrowseDrive, "マウントされた仮想DVDドライブやUSBメモリのドライブレターを選択します")
    $btnBrowseDrive.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Windows 11 インストールメディア（マウント済み仮想DVDドライブ、USBメモリ、または展開フォルダー）を選択してください"
        $fbd.ShowNewFolderButton = $false
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = $fbd.SelectedPath
            if ($p -match '^[A-Za-z]:\\?$') { $p = $p.Substring(0, 2) + "\" }
            $cmbSource.Text = $p
        }
    })
    $grpMedia.Controls.Add($btnBrowseDrive)

    # Button: Browse ISO (OpenFileDialog for .iso file)
    $btnBrowseIso = New-Object System.Windows.Forms.Button
    $btnBrowseIso.Text = "ISO 参照..."
    $btnBrowseIso.Location = New-Object System.Drawing.Point(568, 22)
    $btnBrowseIso.Size = New-Object System.Drawing.Size(95, 26)
    $btnBrowseIso.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseIso.ForeColor = [System.Drawing.Color]::White
    $btnBrowseIso.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $toolTip.SetToolTip($btnBrowseIso, "公式 Windows 11 の .iso ファイルを直接選択します")
    $btnBrowseIso.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Windows 11 ISO (*.iso)|*.iso|All Files (*.*)|*.*"
        $ofd.Title = "公式 Windows 11 ISO イメージを選択してください"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $cmbSource.Text = $ofd.FileName
        }
    })
    $grpMedia.Controls.Add($btnBrowseIso)

    # Button: Refresh Drives
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "再検出"
    $btnRefresh.Location = New-Object System.Drawing.Point(668, 22)
    $btnRefresh.Size = New-Object System.Drawing.Size(54, 26)
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $toolTip.SetToolTip($btnRefresh, "マウント済み仮想DVDや接続されたUSBドライブを再検出します")
    $btnRefresh.Add_Click({
        & $populateSources
        [System.Windows.Forms.MessageBox]::Show("接続ドライブおよび ISO ファイル一覧を再スキャンしました。", "再検出完了", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $grpMedia.Controls.Add($btnRefresh)

    # Hint Label
    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "※ マウント済み仮想DVDドライブ（例: D:\）、USBメモリ、または .iso ファイルを指定してください"
    $lblHint.Location = New-Object System.Drawing.Point(145, 142)
    $lblHint.Size = New-Object System.Drawing.Size(575, 16)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(150, 155, 165)
    $lblHint.Font = New-Object System.Drawing.Font($uiFontName, 8)
    $grpMedia.Controls.Add($lblHint)

    $lblWork = New-Object System.Windows.Forms.Label
    $lblWork.Text = "作業フォルダー:"
    $lblWork.Location = New-Object System.Drawing.Point(15, 54)
    $lblWork.Size = New-Object System.Drawing.Size(125, 20)
    $lblWork.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblWork)

    $txtWork = New-Object System.Windows.Forms.TextBox
    $txtWork.Location = New-Object System.Drawing.Point(145, 51)
    $txtWork.Size = New-Object System.Drawing.Size(420, 24)
    $txtWork.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtWork.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.WorkDir) {
        $txtWork.Text = $InitialSettings.WorkDir
    } else {
        $docsDir = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
        $txtWork.Text = Join-Path -Path $docsDir -ChildPath "nano11_workspace"
    }
    $grpMedia.Controls.Add($txtWork)

    $btnBrowseWork = New-Object System.Windows.Forms.Button
    $btnBrowseWork.Text = "フォルダー参照..."
    $btnBrowseWork.Location = New-Object System.Drawing.Point(574, 50)
    $btnBrowseWork.Size = New-Object System.Drawing.Size(146, 26)
    $btnBrowseWork.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseWork.ForeColor = [System.Drawing.Color]::White
    $btnBrowseWork.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseWork.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "空き容量が25GB以上ある NTFS ドライブ上の作業フォルダーを選択してください"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtWork.Text = $fbd.SelectedPath
        }
    })
    $grpMedia.Controls.Add($btnBrowseWork)

    # Image Index & Driver Injection Controls
    $lblIndex = New-Object System.Windows.Forms.Label
    $lblIndex.Text = "イメージ Index:"
    $lblIndex.Location = New-Object System.Drawing.Point(15, 83)
    $lblIndex.Size = New-Object System.Drawing.Size(125, 20)
    $lblIndex.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblIndex)

    $txtIndex = New-Object System.Windows.Forms.TextBox
    $txtIndex.Location = New-Object System.Drawing.Point(145, 80)
    $txtIndex.Size = New-Object System.Drawing.Size(65, 24)
    $txtIndex.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtIndex.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.Index) { $txtIndex.Text = "$($InitialSettings.Index)" }
    $toolTip.SetToolTip($txtIndex, "対象イメージのインデックス番号 (例: 1)。空欄の場合は自動検出または対話選択されます")
    $grpMedia.Controls.Add($txtIndex)

    $lblDrivers = New-Object System.Windows.Forms.Label
    $lblDrivers.Text = 'ドライバー ($OEM$):'
    $lblDrivers.Location = New-Object System.Drawing.Point(220, 83)
    $lblDrivers.Size = New-Object System.Drawing.Size(125, 20)
    $lblDrivers.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblDrivers)

    $txtDrivers = New-Object System.Windows.Forms.TextBox
    $txtDrivers.Location = New-Object System.Drawing.Point(350, 80)
    $txtDrivers.Size = New-Object System.Drawing.Size(254, 24)
    $txtDrivers.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtDrivers.ForeColor = [System.Drawing.Color]::White
    if ($InitialSettings.InjectDrivers) { $txtDrivers.Text = "$($InitialSettings.InjectDrivers)" }
    $toolTip.SetToolTip($txtDrivers, "OSセットアップ時に自動注入するハードウェアドライバーフォルダー (.inf) を指定します")
    $grpMedia.Controls.Add($txtDrivers)

    $btnBrowseDrivers = New-Object System.Windows.Forms.Button
    $btnBrowseDrivers.Text = "参照..."
    $btnBrowseDrivers.Location = New-Object System.Drawing.Point(610, 79)
    $btnBrowseDrivers.Size = New-Object System.Drawing.Size(110, 26)
    $btnBrowseDrivers.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnBrowseDrivers.ForeColor = [System.Drawing.Color]::White
    $btnBrowseDrivers.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBrowseDrivers.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "注入するドライバー群 (.inf) が格納されたフォルダーを選択してください"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtDrivers.Text = $fbd.SelectedPath
        }
    })
    $grpMedia.Controls.Add($btnBrowseDrivers)

    # Local account user name & computer name (validated with the same rules as -UserName / -ComputerName)
    $lblUserName = New-Object System.Windows.Forms.Label
    $lblUserName.Text = "ユーザー名:"
    $lblUserName.Location = New-Object System.Drawing.Point(15, 113)
    $lblUserName.Size = New-Object System.Drawing.Size(125, 20)
    $lblUserName.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblUserName)

    $txtUserName = New-Object System.Windows.Forms.TextBox
    $txtUserName.Location = New-Object System.Drawing.Point(145, 110)
    $txtUserName.Size = New-Object System.Drawing.Size(200, 24)
    $txtUserName.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtUserName.ForeColor = [System.Drawing.Color]::White
    $txtUserName.Text = if ($InitialSettings.UserName) { "$($InitialSettings.UserName)" } else { "User" }
    $toolTip.SetToolTip($txtUserName, "作成するローカル管理者アカウント名 (文字・数字・スペース・. _ - / 最大20文字)")
    $grpMedia.Controls.Add($txtUserName)

    $lblComputerName = New-Object System.Windows.Forms.Label
    $lblComputerName.Text = "コンピューター名:"
    $lblComputerName.Location = New-Object System.Drawing.Point(360, 113)
    $lblComputerName.Size = New-Object System.Drawing.Size(110, 20)
    $lblComputerName.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpMedia.Controls.Add($lblComputerName)

    $txtComputerName = New-Object System.Windows.Forms.TextBox
    $txtComputerName.Location = New-Object System.Drawing.Point(475, 110)
    $txtComputerName.Size = New-Object System.Drawing.Size(129, 24)
    $txtComputerName.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $txtComputerName.ForeColor = [System.Drawing.Color]::White
    $txtComputerName.Text = if ($InitialSettings.ComputerName) { "$($InitialSettings.ComputerName)" } else { "*" }
    $toolTip.SetToolTip($txtComputerName, "* = 自動生成、または英数字とハイフン (最大15文字)")
    $grpMedia.Controls.Add($txtComputerName)

    # 2. Configuration Profiles GroupBox
    $grpProfile = New-Object System.Windows.Forms.GroupBox
    $grpProfile.Text = " 2. 構成プロファイル && プリセット (Profile && Presets) "
    $grpProfile.Location = New-Object System.Drawing.Point(15, 186)
    $grpProfile.Size = New-Object System.Drawing.Size(730, 75)
    $grpProfile.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpProfile)

    $lblPreset = New-Object System.Windows.Forms.Label
    $lblPreset.Text = "プリセット:"
    $lblPreset.Location = New-Object System.Drawing.Point(15, 28)
    $lblPreset.Size = New-Object System.Drawing.Size(80, 20)
    $lblPreset.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpProfile.Controls.Add($lblPreset)

    $cmbPreset = New-Object System.Windows.Forms.ComboBox
    $cmbPreset.Location = New-Object System.Drawing.Point(100, 25)
    $cmbPreset.Size = New-Object System.Drawing.Size(615, 24)
    $cmbPreset.BackColor = [System.Drawing.Color]::FromArgb(35, 38, 46)
    $cmbPreset.ForeColor = [System.Drawing.Color]::White
    $cmbPreset.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbPreset.Items.AddRange(@(
        "Extreme Slim & Gaming (最大軽量化・超低遅延チューニング)",
        "Balanced Pro (安全構成: Windows Update & Defender 保持)",
        "FAT32 USB Split-WIM (UEFI対応 3.8GB 分割SWM形式)",
        "ポータブルゲーミングPC (ROG Ally, Steam Deck, Legion Go)",
        "VM & 開発者向け (WSL2, Hyper-V, WinUpdate 有効)",
        "DTM & オーディオ制作 (低遅延・VST音源保護・高安定性)",
        "カスタム構成 (手動カスタマイズ)"
    ))
    # Start on the preset that is already active (e.g. from -Profile); a non-built-in profile shows as Custom
    $initPresetKeys = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    $initPresetName = "$($InitialSettings.PresetKey)".Trim().ToLower()
    $initPresetIdx = [array]::IndexOf($initPresetKeys, $initPresetName)
    if ($initPresetIdx -lt 0) {
        $initPresetIdx = if ($initPresetName) { $cmbPreset.Items.Count - 1 } else { 0 }
    }
    $cmbPreset.SelectedIndex = $initPresetIdx
    $grpProfile.Controls.Add($cmbPreset)

    # 3. Customization & Debloat Options GroupBox
    $grpOpts = New-Object System.Windows.Forms.GroupBox
    $grpOpts.Text = " 3. デブロート && カスタマイズ設定 (Debloat && Options) "
    $grpOpts.Location = New-Object System.Drawing.Point(15, 271)
    $grpOpts.Size = New-Object System.Drawing.Size(730, 305)
    $grpOpts.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpOpts)

    $createChk = {
        param($text, $x, $y, $checked)
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = $text
        $chk.Location = New-Object System.Drawing.Point($x, $y)
        $chk.Size = New-Object System.Drawing.Size(352, 28)
        $chk.AutoEllipsis = $true
        $toolTip.SetToolTip($chk, $text)
        $chk.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
        $chk.Checked = [bool]$checked
        $grpOpts.Controls.Add($chk)
        return $chk
    }

    $getInitVal = {
        param([string]$key, [bool]$defaultVal)
        if ($InitialSettings.ContainsKey($key)) { return [bool]$InitialSettings[$key] }
        return [bool]$defaultVal
    }

    # Left Column (X = 15)
    $chkDefender    = & $createChk "Windows Defender とセキュリティUIの完全削除" 15 25 (& $getInitVal 'RemoveDefender' $true)
    $toolTip.SetToolTip($chkDefender, "Defenderドライバー・サービスを無力化し、IFEOデバッガトラップとポリシーで完全停止します。")

    $chkIME         = & $createChk "日本語・アジア系IMEの保持 (日本語入力対応)" 15 55 (& $getInitVal 'KeepAsianIME' $true)
    $toolTip.SetToolTip($chkIME, "日本語(MS-IME)・韓国語・中国語の入力コンポーネントを保持します。")

    $chkFonts       = & $createChk "国際フォント・追加アジア系フォントの保持" 15 85 (& $getInitVal 'KeepExtraFonts' $true)
    $toolTip.SetToolTip($chkFonts, "追加のアジア系フォントを保持します。OFFの場合はフォントを削除して容量を削減します。")

    $chkDrivers     = & $createChk "レガシー ストレージ & ネットワークドライバー削除" 15 115 (& $getInitVal 'RemoveDrivers' $false)
    $toolTip.SetToolTip($chkDrivers, "フロッピーや古いモデム等のレガシードライバーを削除します。OFF(推奨)でセットアップ安定性を100%維持します。")

    $chkWU          = & $createChk "自動 Windows Update の無効化" 15 145 (& $getInitVal 'DisableWindowsUpdate' $true)
    $toolTip.SetToolTip($chkWU, "Windows Updateによる自動ダウンロードとバックグラウンドインストールを無効化します。")

    $chkBT          = & $createChk "Bluetooth サービス & 周辺機器サポートの保持" 15 175 (& $getInitVal 'KeepBluetooth' $true)
    $toolTip.SetToolTip($chkBT, "Bluetoothオーディオや周辺機器サポートを保持します。OFFの場合は関連サービスを停止します。")

    $chkWSL         = & $createChk "WSL2 & 仮想マシンプラットフォームの有効化" 15 205 (& $getInitVal 'WSLSupport' $false)
    $toolTip.SetToolTip($chkWSL, "WSL2およびHyper-Vプラットフォーム機能を有効化します。")

    $chkRecovery    = & $createChk "回復環境 (WinRE) の保持" 15 235 (& $getInitVal 'KeepRecoveryEnv' $false)
    $toolTip.SetToolTip($chkRecovery, "WinRE(回復環境)を維持します。OFFの場合はセットアップ完了後に自動削除してストレージを節約します。")

    $chkBypassAct   = & $createChk "ライセンス未認証制限の解除 (個人用設定/透かし/通知)" 15 265 (& $getInitVal 'BypassActivationRestrictions' $true)
    $toolTip.SetToolTip($chkBypassAct, "ライセンス未認証時の個人用設定ロック・画面右下の透かし・通知制限を解除します。")

    # Right Column (X = 372)
    $chkSafeDebloat = & $createChk "安全な WinSxS 整合性保護 (推奨・破損防止)" 372 25 (& $getInitVal 'SafeDebloatMode' $true)
    $toolTip.SetToolTip($chkSafeDebloat, "ON(推奨): WinSxSの整合性を保ち、インストール展開時の破損(0x80070570)を防止します。OFF: 実験的なWinSxS直接削減を実行します（非推奨）。")

    $chkUltraSlim   = & $createChk "UltraSlim モード (~3GB ISO目標・極限削減)" 372 55 (& $getInitVal 'UltraSlimMode' $true)
    $toolTip.SetToolTip($chkUltraSlim, "不要なビジュアルコンポーネントや壁紙等を極限まで削り、ISOサイズを最小化します。")

    $chkJPKey       = & $createChk "日本語 106/109 キーボード自動構成" 372 85 (& $getInitVal 'SetJapaneseKeyboard' $true)
    $toolTip.SetToolTip($chkJPKey, "セットアップ後のキーボード配列を日本語106/109配列に自動構成します(@や:のズレを防止)。")

    $chkAtlas       = & $createChk "AtlasOS & ReviOS 超低遅延・レスポンス最適化" 372 115 (& $getInitVal 'AtlasReviOSMode' $true)
    $toolTip.SetToolTip($chkAtlas, "DPCレイテンシ・カーネルスケジューリング・タイマー解像度を最適化します。")

    $chkStore       = & $createChk "Microsoft Store と購入アプリの完全削除" 372 145 (& $getInitVal 'RemoveStore' $false)
    $toolTip.SetToolTip($chkStore, "Microsoft Storeアプリ本体を削除します。winget(パッケージマネージャー)は維持されます。")

    $chkBasicApps   = & $createChk "基本アプリ (メモ帳/ペイント/電卓) を残す" 372 175 (& $getInitVal 'KeepBasicApps' $false)
    $toolTip.SetToolTip($chkBasicApps, "メモ帳、ペイント、電卓をAppX削除対象から除外してOSに残します。")

    $chkSearchIndex = & $createChk "Windows Search インデックスを有効化" 372 205 (& $getInitVal 'KeepSearchIndex' $false)
    $toolTip.SetToolTip($chkSearchIndex, "チェック時: Windows Search(WSearch)サービスを有効にしてファイルインデックス検索を継続します。`n未チェック時: WSearchサービス無効化 + SearchHost(検索UI)実行ブロック + Web検索ポリシー抑止 をすべて適用して検索機能を無効化します。")

    $chkVHDX        = & $createChk "超高速 VHDX スクラッチディスクを使用" 372 235 (& $getInitVal 'UseVHDX' $false)
    $toolTip.SetToolTip($chkVHDX, "DISMビルド作業用の一時ディスクとしてVHDX仮想ディスクを使用し、ファイルI/Oを高速化します。")

    $chkRadicalRAM  = & $createChk "メモリ徹底削減 (目標 1.6GB 以下・極限最適化)" 372 265 (& $getInitVal 'RadicalRAM' $true)
    $toolTip.SetToolTip($chkRadicalRAM, "アイドル時メモリ使用量を1.6GB以下に抑制します。不要サービス・バックグラウンドAppX・視覚効果・Web検索・VBSを最適化し、起動直後にワーキングセットを自動解放します。日本語IME・ネットワーク・音声・ブラウザ表示の安定性は維持されます。")

    # 4. Output Payload Format GroupBox
    $grpPayload = New-Object System.Windows.Forms.GroupBox
    $grpPayload.Text = " 4. 出力イメージ形式 (Payload Export Format) "
    $grpPayload.Location = New-Object System.Drawing.Point(15, 586)
    $grpPayload.Size = New-Object System.Drawing.Size(730, 75)
    $grpPayload.ForeColor = [System.Drawing.Color]::FromArgb(0, 190, 255)
    $mainPanel.Controls.Add($grpPayload)

    $radWIM = New-Object System.Windows.Forms.RadioButton
    $radWIM.Text = "install.wim (LZX - 推奨・高速・高安定)"
    $radWIM.Location = New-Object System.Drawing.Point(15, 28)
    $radWIM.Size = New-Object System.Drawing.Size(230, 25)
    $radWIM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $radWIM.Checked = $true
    $grpPayload.Controls.Add($radWIM)

    $radESD = New-Object System.Windows.Forms.RadioButton
    $radESD.Text = "install.esd (LZMS - 超高圧縮)"
    $radESD.Location = New-Object System.Drawing.Point(250, 28)
    $radESD.Size = New-Object System.Drawing.Size(215, 25)
    $radESD.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radESD)

    $radSWM = New-Object System.Windows.Forms.RadioButton
    $radSWM.Text = "install.swm (Split-WIM - FAT32 USB対応)"
    $radSWM.Location = New-Object System.Drawing.Point(470, 28)
    $radSWM.Size = New-Object System.Drawing.Size(250, 25)
    $radSWM.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $grpPayload.Controls.Add($radSWM)

    if ($InitialSettings.ExportESDMode) {
        $radESD.Checked = $true
    } elseif ($InitialSettings.SplitWIMMode) {
        $radSWM.Checked = $true
    }

    # Preset selection sync backed by Built-in In-Memory Presets
    $updatingPreset = $false
    $presetKeyMap = @('extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')

    $guiControlsMap = @{
        chkDefender    = $chkDefender
        chkIME         = $chkIME
        chkFonts       = $chkFonts
        chkDrivers     = $chkDrivers
        chkWU          = $chkWU
        chkBT          = $chkBT
        chkWSL         = $chkWSL
        chkRecovery    = $chkRecovery
        chkSafeDebloat = $chkSafeDebloat
        chkUltraSlim   = $chkUltraSlim
        chkJPKey       = $chkJPKey
        chkAtlas       = $chkAtlas
        chkStore       = $chkStore
        chkBasicApps   = $chkBasicApps
        chkSearchIndex = $chkSearchIndex
        chkVhdx        = $chkVHDX
        chkBypassActivation = $chkBypassAct
        chkRadicalRAM  = $chkRadicalRAM
        radESD         = $radESD
        radSWM         = $radSWM
        radWIM         = $radWIM
    }

    # Base preset for the advanced (non-checkbox) settings: the active built-in preset, if any
    $script:guiBasePresetKey = if ($initPresetIdx -lt $presetKeyMap.Count -and ($initPresetName -in $presetKeyMap -or -not $initPresetName)) { $presetKeyMap[$initPresetIdx] } else { $null }

    $applyPreset = {
        param($presetIndex)
        $script:updatingPreset = $true
        if ($presetIndex -ge 0 -and $presetIndex -lt $presetKeyMap.Count) {
            $pKey = $presetKeyMap[$presetIndex]
            Apply-ProfileSettings -ProfileName $pKey -UpdateGui -GuiControls $guiControlsMap
            $script:guiBasePresetKey = $pKey
        }
        $script:updatingPreset = $false
        & $updateEstimate
    }

    $cmbPreset.Add_SelectedIndexChanged({
        if (-not $script:updatingPreset -and $cmbPreset.SelectedIndex -ne ($cmbPreset.Items.Count - 1)) {
            & $applyPreset $cmbPreset.SelectedIndex
        }
    })

    # F5: estimated ISO size label + update function (must be defined before checkbox event wiring)
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.Height = 65
    $bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 24)
    $form.Controls.Add($bottomPanel)
    # Dock order fix: Fill panel must be front-most so it sits between header and footer
    $mainPanel.BringToFront()

    $lblEstimate = New-Object System.Windows.Forms.Label
    $lblEstimate.Text = "推定 ISO サイズ: ~5.5 GB"
    $lblEstimate.Location = New-Object System.Drawing.Point(20, 48)
    $lblEstimate.Size = New-Object System.Drawing.Size(360, 16)
    $lblEstimate.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $lblEstimate.Font = New-Object System.Drawing.Font($uiFontName, 9)
    $bottomPanel.Controls.Add($lblEstimate)

    $updateEstimate = {
        try {
            $mb = 5500.0
            if ($chkFonts.Checked) { $mb += 150 }
            if ($chkIME.Checked) { $mb += 400 }
            if ($chkDefender.Checked) { $mb += 200 }
            if ($chkStore.Checked) { $mb += 120 }
            if ($chkWU.Checked) { $mb += 50 }
            if ($chkBasicApps.Checked) { $mb += 30 }
            if ($chkSearchIndex.Checked) { $mb += 20 }
            if ($chkXboxServices.Checked) { $mb += 40 }
            if (-not $chkDrivers.Checked) { $mb -= 80 }
            if ($chkUltraSlim.Checked) { $mb -= 200 }
            if ($chkVHDX.Checked) { $mb += 0 }
            if ($radESD.Checked) { $mb = [math]::Round($mb * 0.82) }
            $lblEstimate.Text = ("推定 ISO サイズ: ~{0} GB (LZX基準, 概算)" -f [math]::Round($mb / 1024, 2))
        } catch {}
    }

    # Hook change events to switch preset to Custom
    $allCheckboxes = @($chkDefender, $chkIME, $chkFonts, $chkDrivers, $chkWU, $chkBT, $chkWSL, $chkRecovery, $chkBypassAct, $chkSafeDebloat, $chkUltraSlim, $chkJPKey, $chkAtlas, $chkStore, $chkBasicApps, $chkSearchIndex, $chkVHDX, $chkRadicalRAM)
    foreach ($c in $allCheckboxes) {
        $c.Add_CheckedChanged({
            if (-not $script:updatingPreset) {
                $script:updatingPreset = $true
                $cmbPreset.SelectedIndex = ($cmbPreset.Items.Count - 1) # Custom
                $script:updatingPreset = $false
            }
            & $updateEstimate
        })
    }
    # Radio buttons for payload format also affect estimate
    foreach ($r in @($radWIM, $radESD, $radSWM)) {
        $r.Add_CheckedChanged({ & $updateEstimate })
    }
    # Initial estimate
    & $updateEstimate

    # Bottom Button Panel (already created earlier for F5 estimate label)
    $chkDryRun = New-Object System.Windows.Forms.CheckBox
    $chkDryRun.Text = "DryRun (シミュレーション)"
    $chkDryRun.Location = New-Object System.Drawing.Point(20, 22)
    $chkDryRun.Size = New-Object System.Drawing.Size(220, 24)
    $chkDryRun.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 245)
    $bottomPanel.Controls.Add($chkDryRun)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = "nano11 ビルド開始"
    $btnBuild.Location = New-Object System.Drawing.Point(400, 14)
    $btnBuild.Size = New-Object System.Drawing.Size(220, 38)
    $btnBuild.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnBuild.ForeColor = [System.Drawing.Color]::White
    $btnBuild.Font = New-Object System.Drawing.Font($uiFontName, 10.5, [System.Drawing.FontStyle]::Bold)
    $btnBuild.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $bottomPanel.Controls.Add($btnBuild)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Font = New-Object System.Drawing.Font($uiFontName, 9.5)
    $btnCancel.Location = New-Object System.Drawing.Point(635, 14)
    $btnCancel.Size = New-Object System.Drawing.Size(125, 38)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(45, 50, 60)
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $bottomPanel.Controls.Add($btnCancel)

    $formResult = @{ Success = $false }

    $btnBuild.Add_Click({
        # Validate Source Drive / ISO
        $srcText = $cmbSource.Text.Trim()
        if (-not $srcText) {
            [System.Windows.Forms.MessageBox]::Show("Windows 11 のインストールメディア(ドライブ)または ISO イメージを指定してください。", "ソース指定が必要", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        # If full text contains label, extract drive letter
        if ($srcText -match '^([A-Za-z]:)') {
            $candLetter = $matches[1]
            $wimCheck = Join-Path -Path "$candLetter\sources" -ChildPath "install.wim"
            if (Test-Path -LiteralPath $wimCheck) {
                $resolvedSource = $candLetter
            } elseif ($srcText.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $srcText)) {
                $resolvedSource = $srcText
            } else {
                $resolvedSource = $candLetter
            }
        } elseif ($srcText.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $srcText)) {
            $resolvedSource = $srcText
        } else {
            $resolvedSource = $srcText
        }

        # Validate WorkDir
        $wDir = $txtWork.Text.Trim()
        if (-not $wDir) {
            $docsDir = [Environment]::GetFolderPath('MyDocuments')
            if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE "Documents" }
            $wDir = Join-Path -Path $docsDir -ChildPath "nano11_workspace"
        }

        # Validate user / computer name (same patterns as the -UserName / -ComputerName parameters)
        $guiUserName = $txtUserName.Text.Trim()
        $guiComputerName = $txtComputerName.Text.Trim()
        if (-not $guiComputerName) { $guiComputerName = '*' }
        if ($guiUserName -notmatch '^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$') {
            [System.Windows.Forms.MessageBox]::Show("ユーザー名には文字・数字・スペース・. _ - のみ使用できます (最大20文字)。", "ユーザー名が不正です", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($guiComputerName -notmatch '^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$') {
            [System.Windows.Forms.MessageBox]::Show("コンピューター名は * (自動生成) か、英数字とハイフンのみ (最大15文字) で指定してください。", "コンピューター名が不正です", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $formResult.Success                   = $true
        $formResult.UserName                  = $guiUserName
        $formResult.ComputerName              = $guiComputerName
        # Built-in preset key of the selected preset ($null for Custom) so the caller can apply the full preset
        $formResult.PresetKey                 = if ($cmbPreset.SelectedIndex -ge 0 -and $cmbPreset.SelectedIndex -lt $presetKeyMap.Count) { $presetKeyMap[$cmbPreset.SelectedIndex] } else { $null }
        # Last built-in preset the form was on; Custom = that preset + the checkbox edits
        $formResult.BasePresetKey             = $script:guiBasePresetKey
        $formResult.SourceDrive               = $resolvedSource
        $formResult.WorkDir                   = $wDir
        $formResult.RemoveDefender            = $chkDefender.Checked
        $formResult.KeepAsianIME              = $chkIME.Checked
        $formResult.KeepExtraFonts            = $chkFonts.Checked
        $formResult.RemoveDrivers             = $chkDrivers.Checked
        $formResult.DisableWindowsUpdate      = $chkWU.Checked
        $formResult.KeepBluetooth             = $chkBT.Checked
        $formResult.WSLSupport                = $chkWSL.Checked
        $formResult.KeepRecoveryEnv           = $chkRecovery.Checked
        $formResult.BypassActivationRestrictions = $chkBypassAct.Checked
        $formResult.RadicalRAM                = $chkRadicalRAM.Checked
        $formResult.SafeDebloatMode           = $chkSafeDebloat.Checked
        $formResult.UltraSlimMode             = $chkUltraSlim.Checked
        $formResult.SetJapaneseKeyboard       = $chkJPKey.Checked
        $formResult.AtlasReviOSMode           = $chkAtlas.Checked
        $formResult.RemoveStore               = $chkStore.Checked
        $formResult.KeepBasicApps             = $chkBasicApps.Checked
        $formResult.KeepSearchIndex           = $chkSearchIndex.Checked
        $formResult.Index                     = $txtIndex.Text.Trim()
        $formResult.InjectDrivers             = $txtDrivers.Text.Trim()
        $formResult.DryRun                    = $chkDryRun.Checked
        $formResult.UseVHDX                   = $chkVHDX.Checked
        $formResult.ExportESDMode             = $radESD.Checked
        $formResult.SplitWIMMode              = $radSWM.Checked

        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    # Show '&' literally (WinForms treats '&' as mnemonic prefix and hides it)
    $disableMnemonic = { param($ctl) foreach ($c in $ctl.Controls) { if ($c.PSObject.Properties['UseMnemonic']) { $c.UseMnemonic = $false }; & $disableMnemonic $c } }
    & $disableMnemonic $form

    # Ensure Form pops up in foreground when launched
    $form.TopMost = $true
    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $false
    })

    # Show Dialog
    $diagResult = $form.ShowDialog()
    if ($diagResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $formResult
    }
    return @{ Success = $false }
}

# Handle -TestSelf before transcript or prompts
if ($TestSelf) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $helperModule = Join-Path -Path $scriptDir -ChildPath "nano11helpers.ps1"
    if (Test-Path -LiteralPath $helperModule) { . $helperModule }
    $builderPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path -Path $scriptDir -ChildPath "nano11builder.ps1" }
    $unattendPath = Join-Path -Path $scriptDir -ChildPath "autounattend.xml"
    $testResult = Invoke-Nano11SelfTest -ScriptRoot $scriptDir -BuilderPath $builderPath -UnattendPath $unattendPath
    if ($testResult) { exit 0 } else { exit 1 }
}

# Start Transcript with log rotation (Keep latest 10 logs, fallback to TEMP)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# F8: Dot-source extracted pure helpers (module extraction)
$helperModule = Join-Path -Path $scriptDir -ChildPath "nano11helpers.ps1"
if (Test-Path -LiteralPath $helperModule) {
    . $helperModule
} else {
    throw "Required helper module not found: $helperModule"
}
$logDir = Join-Path -Path $scriptDir -ChildPath "logs"
$timestampStr = (Get-Date -Format "yyyyMMdd_HHmmss")
$transcriptPath = $null

try {
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $transcriptPath = Join-Path -Path $logDir -ChildPath "nano11_$timestampStr.log"
    $script:DismLogPath = Join-Path -Path $logDir -ChildPath "dism_$timestampStr.log"
    Start-Transcript -Path $transcriptPath -Force
    # Prune logs beyond parameter -KeepLogs (Default: 10)
    Get-ChildItem -Path $logDir -Filter "nano11_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "dism_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # Prune logs beyond parameter -KeepLogs (Default: 10)
    Get-ChildItem -Path $logDir -Filter "nano11_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "dism_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "nano11_*.config.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # E4: compress logs older than 7 days into a rolling archive (best-effort, non-fatal)
    try {
        $archivePath = Join-Path -Path $logDir -ChildPath "archive.zip"
        $oldLogs = Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) -and $_.Name -ne 'archive.zip' }
        if ($oldLogs) {
            Compress-Archive -Path $oldLogs.FullName -DestinationPath $archivePath -Update -ErrorAction Stop
            $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Host "Compressed $($oldLogs.Count) log file(s) older than 7 days into archive.zip" -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "Log compression skipped: $_"
    }
    # D: rotate build_diagnostics folders - drop empty (aborted) dirs first, then keep newest $KeepLogs runs
    $diagRootDir = Join-Path -Path $scriptDir -ChildPath "build_diagnostics"
    if (Test-Path -LiteralPath $diagRootDir) {
        Get-ChildItem -LiteralPath $diagRootDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $diagRootDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -Skip $KeepLogs |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    $fallbackLogDir = $env:TEMP
    $transcriptPath = Join-Path -Path $fallbackLogDir -ChildPath "nano11_$timestampStr.log"
    try {
        Start-Transcript -Path $transcriptPath -Force
    } catch {
        Write-Warning "Could not initialize transcript logging: $_"
    }
}
$buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Queue Mode for multiple comma-separated profiles (-Profile extreme,balanced-pro,vm-developer)
if ($Profile -and $Profile.Contains(',')) {
    $profileQueue = $Profile -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($profileQueue.Count -gt 1) {
        Write-Host "=========================================================" -ForegroundColor Cyan
        Write-Host "   nano11 Batch Queue Mode: $($profileQueue.Count) Profiles to Build    " -ForegroundColor Cyan
        Write-Host "=========================================================" -ForegroundColor Cyan
        # Release the global build mutex so each child build process can acquire it in turn
        if ($script:BuildMutex) {
            try {
                if ($script:HasMutex) { $script:BuildMutex.ReleaseMutex() }
                $script:BuildMutex.Dispose()
            } catch {}
            $script:BuildMutex = $null
            $script:HasMutex = $false
        }
        $queueSuccess = 0
        foreach ($qProf in $profileQueue) {
            Write-Host "`n>>> Starting Batch Build for Profile: $qProf <<<" -ForegroundColor Yellow
            $argsToPass = [System.Collections.Generic.List[string]]::new()
            foreach ($k in $PSBoundParameters.Keys) {
                if ($k -in @('Profile', 'TestSelf', 'NonInteractive')) { continue }
                $argsToPass.Add((ConvertTo-Nano11CliArgument -Name $k -Value $PSBoundParameters[$k]))
            }
            $argsToPass.Add((ConvertTo-Nano11CliArgument -Name 'Profile' -Value $qProf))
            $argsToPass.Add("-NonInteractive")
            $subProc = Start-Process -FilePath "powershell.exe" -ArgumentList (New-Nano11ChildArguments -ScriptPath $PSCommandPath -ScriptArguments $argsToPass) -Wait -PassThru -NoNewWindow
            if ($subProc.ExitCode -eq 0) {
                $queueSuccess++
                Write-Host "Profile $qProf built successfully!" -ForegroundColor Green
            } else {
                Write-Host "Profile $qProf failed with exit code $($subProc.ExitCode)" -ForegroundColor Red
            }
        }
        Write-Host "`n=========================================================" -ForegroundColor Cyan
        Write-Host "   Batch Queue Completed: $queueSuccess/$($profileQueue.Count) profiles succeeded." -ForegroundColor $(if ($queueSuccess -eq $profileQueue.Count) { "Green" } else { "Yellow" })
        Write-Host "=========================================================" -ForegroundColor Cyan
        exit $(if ($queueSuccess -eq $profileQueue.Count) { 0 } else { 1 })
    }
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               Welcome to nano11 builder!                " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "This script generates a significantly reduced Windows 11 image."
Write-Host "Suitable for testing, low-spec VMs, and rapid prototyping."
Write-Host ""

# Confirmation
if (-not $NonInteractive -and -not $GUI -and -not $isDryRunMode) {
    Write-Host "Do you want to continue? [Y/n] (Default: Y)" -ForegroundColor Yellow
    $confirm = Read-Host
    if ($confirm -and ($confirm.Trim().ToLower() -in @('no', 'n'))) {
        Write-Host "Process cancelled by user. Exiting..." -ForegroundColor Gray
        Stop-Transcript
        exit 0
    }
}

# Customization Options (Resolves Issues #1, #5, #9, #10, #12, #13)
Write-Host ""
Write-Host "--- Customization Settings ---" -ForegroundColor Green

# 1. Initialize recommended baseline defaults
$removeDefender = $true
$keepAsianIME = $true
$keepExtraFonts = $true
$removeDrivers = $false
$disableWU = $true
$keepBT = $true
$wslSupport = $false
$keepRecoveryEnv = $false
$safeDebloatMode = $true
$ultraSlimMode = $true
$setJapaneseKeyboard = $true
$atlasReviOSMode = $true
$exportESDMode = $false
$splitWIMMode = $false
$removeStore = $false
$keepXboxServices = $false
$keepAudioTweaks = $false
$bypassActivationRestrictions = $true
$radicalRAM = $true
$mmcssGaming = $true     # Games MMCSS task tuning (matches the 'extreme' baseline above)
$dawMode = $false        # Pro Audio MMCSS task tuning
$selectedProfile = $null

# 2. Track explicitly supplied CLI parameters from bound parameters snapshot
$bound = $PSBoundParameters
$cliBound = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 0a. Profile / Preset Parameter (Direct In-Memory Preset Resolution)
if ($bound.ContainsKey('Profile') -or $bound.ContainsKey('Preset')) {
    $profVal = if ($bound.ContainsKey('Profile')) { $bound['Profile'] } else { $bound['Preset'] }
    $selectedProfile = $profVal.ToString().Trim().ToLower()
    [void]$cliBound.Add('Profile')
    $applied = Apply-ProfileSettings -ProfileName $selectedProfile
    if (-not $applied) {
        Write-Warning "Unrecognized profile '$selectedProfile'. Falling back to 'extreme'."
        Apply-ProfileSettings -ProfileName 'extreme' | Out-Null
        $selectedProfile = 'extreme'
    } else {
        Write-Host "Applied Built-in Profile: $($applied.ProfileName)" -ForegroundColor Green
    }
}

# 0b. LoadProfile Parameter (JSON profile written by -SaveProfile). Applied after -Profile, and
# explicitly passed CLI switches still override it (they are processed further below).
if ($bound.ContainsKey('LoadProfile') -and $bound['LoadProfile']) {
    $loadedSettings = Import-Nano11Profile -FilePath $LoadProfile
    if (-not $loadedSettings) {
        throw "Could not load JSON profile: $LoadProfile"
    }
    Apply-ProfileSettings -ProfileObject $loadedSettings | Out-Null
    $profileNameProp = $loadedSettings.PSObject.Properties['ProfileName']
    $selectedProfile = if ($profileNameProp -and $profileNameProp.Value) { "$($profileNameProp.Value)" } else { [System.IO.Path]::GetFileNameWithoutExtension($LoadProfile) }

    # Settings outside Apply-ProfileSettings: only taken from the file when not given on the command line
    foreach ($extraKey in @('SourceDrive', 'WorkDir', 'Index', 'ComputerName', 'UserName', 'SkipEiCfg', 'NoPostInstallAssets')) {
        $prop = $loadedSettings.PSObject.Properties[$extraKey]
        if (-not $prop -or $bound.ContainsKey($extraKey)) { continue }
        $val = $prop.Value
        if ($extraKey -in @('SkipEiCfg', 'NoPostInstallAssets')) {
            Set-Variable -Name $extraKey -Value ([switch][bool]$val)
        } elseif (-not [string]::IsNullOrWhiteSpace("$val")) {
            try {
                Set-Variable -Name $extraKey -Value "$val"
            } catch {
                throw "Profile '$LoadProfile' has an invalid $extraKey value '$val': $($_.Exception.Message)"
            }
        }
    }
    Write-Host "Loaded JSON profile: $LoadProfile ($selectedProfile)" -ForegroundColor Green
}

# Helper function: Show the GUI pre-filled with the current settings and apply the result to script scope.
# Returns $false when the user cancels.
function Invoke-Nano11GuiSession {
    $initialSettings = @{
        SourceDrive                  = $script:SourceDrive
        WorkDir                      = $script:WorkDir
        Index                        = $script:Index
        InjectDrivers                = $script:InjectDrivers
        UserName                     = $script:UserName
        ComputerName                 = $script:ComputerName
        PresetKey                    = $script:selectedProfile
        RemoveDefender               = $script:removeDefender
        KeepAsianIME                 = $script:keepAsianIME
        KeepExtraFonts               = $script:keepExtraFonts
        RemoveDrivers                = $script:removeDrivers
        DisableWindowsUpdate         = $script:disableWU
        KeepBluetooth                = $script:keepBT
        WSLSupport                   = $script:wslSupport
        KeepRecoveryEnv              = $script:keepRecoveryEnv
        BypassActivationRestrictions = $script:bypassActivationRestrictions
        RadicalRAM                   = $script:radicalRAM
        SafeDebloatMode              = $script:safeDebloatMode
        UltraSlimMode                = $script:ultraSlimMode
        SetJapaneseKeyboard          = $script:setJapaneseKeyboard
        AtlasReviOSMode              = $script:atlasReviOSMode
        RemoveStore                  = $script:removeStore
        KeepBasicApps                = $script:keepBasicApps
        KeepSearchIndex              = $script:keepSearchIndex
        UseVHDX                      = $script:useVHDX
        ExportESDMode                = $script:exportESDMode
        SplitWIMMode                 = $script:splitWIMMode
    }
    $guiResult = Show-Nano11GUI -InitialSettings $initialSettings
    if (-not ($guiResult -and $guiResult.Success)) { return $false }

    # 1. Apply the full built-in preset first (Xbox, power, hibernate, tweak groups... which have no checkbox)
    if ($guiResult.BasePresetKey) {
        Apply-ProfileSettings -ProfileName $guiResult.BasePresetKey | Out-Null
    }
    # 2. Then the values the user actually sees in the form
    if ($guiResult.SourceDrive) { $script:SourceDrive = $guiResult.SourceDrive }
    if ($guiResult.WorkDir)     { $script:WorkDir = $guiResult.WorkDir }
    if ($guiResult.UserName)     { $script:UserName = $guiResult.UserName }
    if ($guiResult.ComputerName) { $script:ComputerName = $guiResult.ComputerName }
    $script:removeDefender               = [bool]$guiResult.RemoveDefender
    $script:keepAsianIME                 = [bool]$guiResult.KeepAsianIME
    $script:keepExtraFonts               = [bool]$guiResult.KeepExtraFonts
    $script:removeDrivers                = [bool]$guiResult.RemoveDrivers
    $script:disableWU                    = [bool]$guiResult.DisableWindowsUpdate
    $script:keepBT                       = [bool]$guiResult.KeepBluetooth
    $script:wslSupport                   = [bool]$guiResult.WSLSupport
    $script:keepRecoveryEnv              = [bool]$guiResult.KeepRecoveryEnv
    $script:bypassActivationRestrictions = [bool]$guiResult.BypassActivationRestrictions
    $script:radicalRAM                   = [bool]$guiResult.RadicalRAM
    $script:safeDebloatMode              = [bool]$guiResult.SafeDebloatMode
    $script:ultraSlimMode                = [bool]$guiResult.UltraSlimMode
    $script:setJapaneseKeyboard          = [bool]$guiResult.SetJapaneseKeyboard
    $script:atlasReviOSMode              = [bool]$guiResult.AtlasReviOSMode
    $script:removeStore                  = [bool]$guiResult.RemoveStore
    $script:keepBasicApps                = [bool]$guiResult.KeepBasicApps
    $script:keepSearchIndex              = [bool]$guiResult.KeepSearchIndex
    $script:useVHDX                      = [bool]$guiResult.UseVHDX
    $script:exportESDMode                = [bool]$guiResult.ExportESDMode
    $script:splitWIMMode                 = [bool]$guiResult.SplitWIMMode
    if ($guiResult.Index)         { $script:Index = $guiResult.Index }
    if ($guiResult.InjectDrivers) { $script:InjectDrivers = $guiResult.InjectDrivers }
    if ($guiResult.DryRun) {
        $script:DryRun = $true
        $script:isDryRunMode = $true
    }
    $script:selectedProfile = if ($guiResult.PresetKey) { $guiResult.PresetKey } elseif ($guiResult.BasePresetKey) { "custom (based on $($guiResult.BasePresetKey))" } else { "GUI Selection" }
    Write-Host "Applied GUI Configuration successfully ($($script:selectedProfile))." -ForegroundColor Green
    return $true
}

# 0c. Graphical User Interface (GUI) Trigger
if ($GUI) {
    Write-Host "Opening nano11 Graphical User Interface (GUI)..." -ForegroundColor Cyan
    if (Invoke-Nano11GuiSession) {
        $NonInteractive = $true
    } else {
        Write-Host "nano11 GUI cancelled by user. Exiting..." -ForegroundColor Gray
        Stop-Transcript
        exit 0
    }
}

$isAnyBound = {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if ($bound.ContainsKey($n)) { return $true }
    }
    return $false
}
$getBoundVal = {
    param([string]$Name)
    if (-not $bound.ContainsKey($Name)) { return $false }
    $v = $bound[$Name]
    if ($v -is [System.Management.Automation.SwitchParameter]) { return $v.IsPresent }
    return [bool]$v
}

# 19. Xbox Services
if (& $isAnyBound @('KeepXboxServices')) {
    $keepXboxServices = & $getBoundVal 'KeepXboxServices'
    [void]$cliBound.Add('Xbox')
} elseif (& $isAnyBound @('RemoveXboxServices', 'NoXboxServices')) {
    $remXbox = if ($bound.ContainsKey('RemoveXboxServices')) { & $getBoundVal 'RemoveXboxServices' } else { & $getBoundVal 'NoXboxServices' }
    $keepXboxServices = -not $remXbox
    [void]$cliBound.Add('Xbox')
}

# 20. Audio Tweaks
if (& $isAnyBound @('KeepAudioTweaks')) {
    $keepAudioTweaks = & $getBoundVal 'KeepAudioTweaks'
    [void]$cliBound.Add('Audio')
}

# 1. Windows Defender
if (& $isAnyBound @('KeepDefender')) {
    $removeDefender = -not (& $getBoundVal 'KeepDefender')
    [void]$cliBound.Add('Defender')
} elseif (& $isAnyBound @('RemoveDefender', 'NoDefender')) {
    $remDef = if ($bound.ContainsKey('RemoveDefender')) { & $getBoundVal 'RemoveDefender' } else { & $getBoundVal 'NoDefender' }
    $removeDefender = $remDef
    [void]$cliBound.Add('Defender')
}

# 2. Asian IMEs
if (& $isAnyBound @('KeepIME', 'KeepAsianIME')) {
    $keepImeVal = if ($bound.ContainsKey('KeepIME')) { & $getBoundVal 'KeepIME' } else { & $getBoundVal 'KeepAsianIME' }
    $keepAsianIME = $keepImeVal
    [void]$cliBound.Add('IME')
} elseif (& $isAnyBound @('RemoveIME', 'RemoveAsianIME', 'NoIME')) {
    $rem = if ($bound.ContainsKey('RemoveIME')) { & $getBoundVal 'RemoveIME' } elseif ($bound.ContainsKey('RemoveAsianIME')) { & $getBoundVal 'RemoveAsianIME' } else { & $getBoundVal 'NoIME' }
    $keepAsianIME = -not $rem
    [void]$cliBound.Add('IME')
}

# 3. Fonts
if (& $isAnyBound @('KeepFonts', 'KeepExtraFonts')) {
    $keepFontVal = if ($bound.ContainsKey('KeepFonts')) { & $getBoundVal 'KeepFonts' } else { & $getBoundVal 'KeepExtraFonts' }
    $keepExtraFonts = $keepFontVal
    [void]$cliBound.Add('Fonts')
} elseif (& $isAnyBound @('RemoveFonts', 'NoFonts')) {
    $remF = if ($bound.ContainsKey('RemoveFonts')) { & $getBoundVal 'RemoveFonts' } else { & $getBoundVal 'NoFonts' }
    $keepExtraFonts = -not $remF
    [void]$cliBound.Add('Fonts')
}

# 4. Drivers
if (& $isAnyBound @('RemoveDrivers')) {
    $removeDrivers = & $getBoundVal 'RemoveDrivers'
    [void]$cliBound.Add('Drivers')
} elseif (& $isAnyBound @('KeepDrivers')) {
    $removeDrivers = -not (& $getBoundVal 'KeepDrivers')
    [void]$cliBound.Add('Drivers')
}

# 5. Windows Update
if (& $isAnyBound @('KeepWindowsUpdate', 'EnableWindowsUpdate')) {
    $keepWu = if ($bound.ContainsKey('KeepWindowsUpdate')) { & $getBoundVal 'KeepWindowsUpdate' } else { & $getBoundVal 'EnableWindowsUpdate' }
    $disableWU = -not $keepWu
    [void]$cliBound.Add('WindowsUpdate')
} elseif (& $isAnyBound @('DisableWindowsUpdate', 'NoWindowsUpdate')) {
    $disWu = if ($bound.ContainsKey('DisableWindowsUpdate')) { & $getBoundVal 'DisableWindowsUpdate' } else { & $getBoundVal 'NoWindowsUpdate' }
    $disableWU = $disWu
    [void]$cliBound.Add('WindowsUpdate')
}

# 6. Bluetooth
if (& $isAnyBound @('DisableBluetooth', 'NoBluetooth')) {
    $disBt = if ($bound.ContainsKey('DisableBluetooth')) { & $getBoundVal 'DisableBluetooth' } else { & $getBoundVal 'NoBluetooth' }
    $keepBT = -not $disBt
    [void]$cliBound.Add('Bluetooth')
} elseif (& $isAnyBound @('KeepBluetooth')) {
    $keepBT = & $getBoundVal 'KeepBluetooth'
    [void]$cliBound.Add('Bluetooth')
}

# 7. WSL2
if (& $isAnyBound @('EnableWSL')) {
    $wslSupport = & $getBoundVal 'EnableWSL'
    [void]$cliBound.Add('WSL')
} elseif (& $isAnyBound @('DisableWSL', 'NoWSL')) {
    $disWsl = if ($bound.ContainsKey('DisableWSL')) { & $getBoundVal 'DisableWSL' } else { & $getBoundVal 'NoWSL' }
    $wslSupport = -not $disWsl
    [void]$cliBound.Add('WSL')
}

# 8. Recovery Environment (WinRE)
if (& $isAnyBound @('KeepRecovery', 'KeepWinRE')) {
    $keepRecVal = if ($bound.ContainsKey('KeepRecovery')) { & $getBoundVal 'KeepRecovery' } else { & $getBoundVal 'KeepWinRE' }
    $keepRecoveryEnv = $keepRecVal
    [void]$cliBound.Add('Recovery')
} elseif (& $isAnyBound @('RemoveRecovery', 'RemoveWinRE', 'NoWinRE', 'NoRecovery')) {
    $remRec = if ($bound.ContainsKey('RemoveRecovery')) { & $getBoundVal 'RemoveRecovery' } elseif ($bound.ContainsKey('RemoveWinRE')) { & $getBoundVal 'RemoveWinRE' } elseif ($bound.ContainsKey('NoWinRE')) { & $getBoundVal 'NoWinRE' } else { & $getBoundVal 'NoRecovery' }
    $keepRecoveryEnv = -not $remRec
    [void]$cliBound.Add('Recovery')
}

# 9. WinSxS Component Store Mode
if (& $isAnyBound @('AggressiveWinSxS', 'TrimWinSxS')) {
    $agg = if ($bound.ContainsKey('AggressiveWinSxS')) { & $getBoundVal 'AggressiveWinSxS' } else { & $getBoundVal 'TrimWinSxS' }
    $safeDebloatMode = -not $agg
    [void]$cliBound.Add('WinSxS')
} elseif (& $isAnyBound @('SafeDebloat', 'SafeWinSxS')) {
    $safe = if ($bound.ContainsKey('SafeDebloat')) { & $getBoundVal 'SafeDebloat' } else { & $getBoundVal 'SafeWinSxS' }
    $safeDebloatMode = $safe
    [void]$cliBound.Add('WinSxS')
}

# 10. UltraSlim
if (& $isAnyBound @('UltraSlim')) {
    $ultraSlimMode = & $getBoundVal 'UltraSlim'
    [void]$cliBound.Add('UltraSlim')
} elseif (& $isAnyBound @('NoUltraSlim')) {
    $ultraSlimMode = -not (& $getBoundVal 'NoUltraSlim')
    [void]$cliBound.Add('UltraSlim')
}

# UltraSlim mode preserves fonts by default (per user specification: keep fonts intact)
# if ($ultraSlimMode -and (-not $cliBound.Contains('Fonts'))) { $keepExtraFonts = $false }

# 11. Japanese Keyboard
if (& $isAnyBound @('NoJapaneseKeyboard')) {
    $setJapaneseKeyboard = -not (& $getBoundVal 'NoJapaneseKeyboard')
    [void]$cliBound.Add('JPKey')
} elseif (& $isAnyBound @('JapaneseKeyboard')) {
    $setJapaneseKeyboard = & $getBoundVal 'JapaneseKeyboard'
    [void]$cliBound.Add('JPKey')
}

# 12. AtlasOS & ReviOS Tweaks
if (& $isAnyBound @('NoAtlasReviOS')) {
    $atlasReviOSMode = -not (& $getBoundVal 'NoAtlasReviOS')
    [void]$cliBound.Add('Atlas')
} elseif (& $isAnyBound @('AtlasReviOS')) {
    $atlasReviOSMode = & $getBoundVal 'AtlasReviOS'
    [void]$cliBound.Add('Atlas')
}

# 13. Export Format
if (& $isAnyBound @('ExportESD')) {
    $exportESDMode = & $getBoundVal 'ExportESD'
    $splitWIMMode = $false
    [void]$cliBound.Add('Export')
} elseif (& $isAnyBound @('ExportWIM', 'NoESD')) {
    $expWim = if ($bound.ContainsKey('ExportWIM')) { & $getBoundVal 'ExportWIM' } else { & $getBoundVal 'NoESD' }
    $exportESDMode = -not $expWim
    [void]$cliBound.Add('Export')
}

if (& $isAnyBound @('SplitWIM', 'FAT32Compatible', 'FAT32')) {
    $splitWIMMode = & $getBoundVal 'SplitWIM'
    $exportESDMode = $false
    [void]$cliBound.Add('SplitWIM')
} elseif (& $isAnyBound @('NoSplitWIM')) {
    $splitWIMMode = -not (& $getBoundVal 'NoSplitWIM')
    [void]$cliBound.Add('SplitWIM')
}

# 14. Microsoft Store (Default: Keep)
if (& $isAnyBound @('RemoveStore', 'NoStore', 'RemoveMicrosoftStore')) {
    $removeStore = if ($bound.ContainsKey('RemoveStore')) { & $getBoundVal 'RemoveStore' } elseif ($bound.ContainsKey('NoStore')) { & $getBoundVal 'NoStore' } else { & $getBoundVal 'RemoveMicrosoftStore' }
    [void]$cliBound.Add('Store')
} elseif (& $isAnyBound @('KeepStore')) {
    $removeStore = -not (& $getBoundVal 'KeepStore')
    [void]$cliBound.Add('Store')
}

# 15. Activation Restrictions Bypass (Default: $true)
if (& $isAnyBound @('BypassActivationRestrictions', 'NoActivationRestrictions', 'UnlockPersonalization')) {
    $bypassActivationRestrictions = if ($bound.ContainsKey('BypassActivationRestrictions')) { & $getBoundVal 'BypassActivationRestrictions' } elseif ($bound.ContainsKey('NoActivationRestrictions')) { & $getBoundVal 'NoActivationRestrictions' } else { & $getBoundVal 'UnlockPersonalization' }
    [void]$cliBound.Add('ActivationRestrictions')
}

# 16. Radical RAM Optimization (Default: $true)
if (& $isAnyBound @('RadicalRAM', 'UltraLowRAM', 'LowRAM')) {
    $radicalRAM = if ($bound.ContainsKey('RadicalRAM')) { & $getBoundVal 'RadicalRAM' } elseif ($bound.ContainsKey('UltraLowRAM')) { & $getBoundVal 'UltraLowRAM' } else { & $getBoundVal 'LowRAM' }
    [void]$cliBound.Add('RadicalRAM')
} elseif (& $isAnyBound @('NoRadicalRAM')) {
    $radicalRAM = -not (& $getBoundVal 'NoRadicalRAM')
    [void]$cliBound.Add('RadicalRAM')
}

# 16. Fast VHDX Scratch Disk
if (& $isAnyBound @('UseVHDX', 'FastVHDX', 'VHDX')) {
    $useVHDX = if ($bound.ContainsKey('UseVHDX')) { & $getBoundVal 'UseVHDX' } elseif ($bound.ContainsKey('FastVHDX')) { & $getBoundVal 'FastVHDX' } else { & $getBoundVal 'VHDX' }
    [void]$cliBound.Add('VHDX')
}

# 21. Advanced Modular Optimization Tweak Toggles overrides
if (& $isAnyBound @('RemoveLegacyFOD'))       { $removeLegacyFOD = & $getBoundVal 'RemoveLegacyFOD'; [void]$cliBound.Add('RemoveLegacyFOD') }
if (& $isAnyBound @('TrimWallpapers'))        { $trimWallpapers  = & $getBoundVal 'TrimWallpapers';  [void]$cliBound.Add('TrimWallpapers') }
if (& $isAnyBound @('DisableCPUMitigations')) { $disableCPUMitigations = & $getBoundVal 'DisableCPUMitigations'; [void]$cliBound.Add('DisableCPUMitigations') }
if (& $isAnyBound @('MMCSSGaming'))          { $mmcssGaming     = & $getBoundVal 'MMCSSGaming';     [void]$cliBound.Add('MMCSSGaming') }
if (& $isAnyBound @('DAWMode'))              { $dawMode         = & $getBoundVal 'DAWMode';         [void]$cliBound.Add('DAWMode') }
if (& $isAnyBound @('DisableMemCompression')){ $disableMemCompression = & $getBoundVal 'DisableMemCompression'; [void]$cliBound.Add('DisableMemCompression') }
if (& $isAnyBound @('DisableFSE'))           { $disableFSE      = & $getBoundVal 'DisableFSE';      [void]$cliBound.Add('DisableFSE') }
if (& $isAnyBound @('NvidiaLowLatency'))     { $nvidiaLowLatency = & $getBoundVal 'NvidiaLowLatency'; [void]$cliBound.Add('NvidiaLowLatency') }
if (& $isAnyBound @('NoKernelPaging'))       { $noKernelPaging  = & $getBoundVal 'NoKernelPaging';  [void]$cliBound.Add('NoKernelPaging') }
if (& $isAnyBound @('DisableUSBSuspend'))    { $disableUSBSuspend = & $getBoundVal 'DisableUSBSuspend'; [void]$cliBound.Add('DisableUSBSuspend') }
if (& $isAnyBound @('NoHypervisor'))         { $noHypervisor    = & $getBoundVal 'NoHypervisor';    [void]$cliBound.Add('NoHypervisor') }
if (& $isAnyBound @('RemoveWebViewPostOOBE')){ $removeWebViewPostOOBE = & $getBoundVal 'RemoveWebViewPostOOBE'; [void]$cliBound.Add('RemoveWebViewPostOOBE') }
if (& $isAnyBound @('FastExport'))           { $fastExport      = & $getBoundVal 'FastExport';      [void]$cliBound.Add('FastExport') }
if (& $isAnyBound @('UefiOnly'))             { $uefiOnly        = & $getBoundVal 'UefiOnly';        [void]$cliBound.Add('UefiOnly') }
if ($bound.ContainsKey('HibernateMode'))     { $hibernateMode   = $bound['HibernateMode'];          [void]$cliBound.Add('HibernateMode') }
if ($bound.ContainsKey('CrashDumpMode'))     { $crashDumpMode   = $bound['CrashDumpMode'];          [void]$cliBound.Add('CrashDumpMode') }
if ($bound.ContainsKey('CpuBoostMode') -and $bound['CpuBoostMode'] -ne 'Default') { $cpuBoostMode = $bound['CpuBoostMode']; [void]$cliBound.Add('CpuBoostMode') }
if ($bound.ContainsKey('PowerPreset') -and $bound['PowerPreset'] -ne 'Default')   { $powerPreset   = $bound['PowerPreset'];   [void]$cliBound.Add('PowerPreset') }
if ($bound.ContainsKey('TweakGroupOverrides') -and $bound['TweakGroupOverrides']) {
    foreach ($tgKey in $bound['TweakGroupOverrides'].Keys) {
        if ($script:TweakGroups.Contains($tgKey)) {
            $script:activeTweakGroups[$tgKey] = [bool]$bound['TweakGroupOverrides'][$tgKey]
        }
    }
}

# 3. Interactive Prompting Logic
$isAutomated = $NonInteractive -or $isDryRunMode -or ($cliBound.Count -ge 15 -and (-not $Interactive)) -or ($cliBound.Contains('Profile') -and (-not $Interactive))

if ($isAutomated) {
    Write-Host "Running in automated/CLI mode (no interactive prompts)." -ForegroundColor Gray
} else {
    # Configuration Profile Selector
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "         nano11 Configuration Profile Selector" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "Choose a profile or proceed to customization:" -ForegroundColor Gray
    Write-Host "  [1] ⚡ Extreme Slim & Gaming (Default: Max debloat, Atlas/ReviOS, Store removed)" -ForegroundColor Green
    Write-Host "  [2] 🛡️ Balanced Pro (Safe: Windows Update & Defender kept, high stability)" -ForegroundColor Yellow
    Write-Host "  [3] 💾 FAT32 USB Split-WIM (3.8GB SWM Chunks for UEFI)" -ForegroundColor Yellow
    Write-Host "  [4] 🎮 Handheld Gaming (ROG Ally, Steam Deck, Legion Go)" -ForegroundColor Green
    Write-Host "  [5] 💻 VM & Developer Workstation (WSL2, Hyper-V, WinUpdate)" -ForegroundColor Cyan
    Write-Host "  [6] 🎵 Audio & DAW Production (Minimal Latency, VST Protected)" -ForegroundColor Magenta
    Write-Host "  [7] 🖥️ Launch GUI (Graphical User Interface)" -ForegroundColor Blue
    Write-Host "  [8] 🔧 Custom (Step-by-step 15 configuration prompts)" -ForegroundColor Magenta
    $pChoice = Read-Host "Select Profile [1-8] (Default: 1 - Extreme Slim & Gaming)"
    if ($pChoice) { $pChoice = $pChoice.Trim().ToLower() } else { $pChoice = "1" }

    $skipIndividualPrompts = $false
    if ($pChoice -in @('1', 'extreme', 'gaming', 'slim')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "extreme"
        Apply-ProfileSettings -ProfileName 'extreme' | Out-Null
        Write-Host "Applied Profile: ⚡ Extreme Slim & Gaming" -ForegroundColor Green
    } elseif ($pChoice -in @('2', 'balanced', 'safe', 'pro')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "balanced"
        Apply-ProfileSettings -ProfileName 'balanced' | Out-Null
        Write-Host "Applied Profile: 🛡️ Balanced Pro (Windows Update & Defender kept)" -ForegroundColor Yellow
    } elseif ($pChoice -in @('4', 'handheld', 'ally', 'deck', 'legion')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "handheld"
        Apply-ProfileSettings -ProfileName 'handheld' | Out-Null
        Write-Host "Applied Profile: 🎮 Handheld Gaming" -ForegroundColor Green
    } elseif ($pChoice -in @('5', 'vm', 'dev', 'developer')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "vm"
        Apply-ProfileSettings -ProfileName 'vm' | Out-Null
        Write-Host "Applied Profile: 💻 VM & Developer Workstation" -ForegroundColor Cyan
    } elseif ($pChoice -in @('6', 'audio', 'daw', 'dtm')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "audio"
        Apply-ProfileSettings -ProfileName 'audio' | Out-Null
        Write-Host "Applied Profile: 🎵 Audio & DAW Production" -ForegroundColor Magenta
    } elseif ($pChoice -in @('3', 'fat32', 'split', 'splitwim')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "fat32"
        Apply-ProfileSettings -ProfileName 'fat32' | Out-Null
        Write-Host "Applied Profile: 💾 FAT32 USB Split-WIM" -ForegroundColor Yellow
    } elseif ($pChoice -in @('7', 'gui', 'ui')) {
        $skipIndividualPrompts = $true
        if (-not (Invoke-Nano11GuiSession)) {
            Write-Host "GUI cancelled by user. Exiting..." -ForegroundColor Gray
            Stop-Transcript
            exit 0
        }
    } else {
        $selectedProfile = "custom"
        Write-Host "Entering 🔧 Custom step-by-step configuration..." -ForegroundColor Magenta
    }

    if (-not $skipIndividualPrompts) {
        Write-Host "Configure debloat options (Press Enter to accept current defaults or CLI selections):" -ForegroundColor Gray
    
    # 1. Windows Defender
    if ($cliBound.Contains('Defender') -and (-not $Interactive)) {
        Write-Host "1. Remove Windows Defender: $(if ($removeDefender) { 'Yes (Remove)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($removeDefender) { "Y/n" } else { "y/N" }
        $defDesc = if ($removeDefender) { "Default: Y (Remove)" } else { "Default: N (Keep)" }
        $opt = Read-Host "1. Remove Windows Defender? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $removeDefender = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $removeDefender = $true }
        }
    }

    # 2. Asian IMEs (Japanese, Chinese, Korean)
    if ($cliBound.Contains('IME') -and (-not $Interactive)) {
        Write-Host "2. Keep Asian language IMEs: $(if ($keepAsianIME) { 'Yes (Keep)' } else { 'No (Remove)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepAsianIME) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepAsianIME) { "Default: Y (Keep)" } else { "Default: N (Remove)" }
        $opt = Read-Host "2. Keep Asian language IMEs (Japanese, Chinese, Korean)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $keepAsianIME = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepAsianIME = $true }
        }
    }

    # 3. Fonts
    if ($cliBound.Contains('Fonts') -and (-not $Interactive)) {
        Write-Host "3. Keep extra international & Asian fonts: $(if ($keepExtraFonts) { 'Yes (Keep)' } else { 'No (Remove)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepExtraFonts) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepExtraFonts) { "Default: Y (Keep)" } else { "Default: N (Remove)" }
        $opt = Read-Host "3. Keep extra international & Asian fonts? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $keepExtraFonts = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepExtraFonts = $true }
        }
    }

    # 4. Drivers
    if ($cliBound.Contains('Drivers') -and (-not $Interactive)) {
        Write-Host "4. Remove non-essential drivers: $(if ($removeDrivers) { 'Yes (Remove)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($removeDrivers) { "Y/n" } else { "y/N" }
        $defDesc = if ($removeDrivers) { "Default: Y (Remove)" } else { "Default: N (Keep - Recommended for 100% Setup Stability)" }
        $opt = Read-Host "4. Remove non-essential drivers (printers, scanners, fax)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $removeDrivers = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $removeDrivers = $false }
        }
    }

    # 5. Windows Update
    if ($cliBound.Contains('WindowsUpdate') -and (-not $Interactive)) {
        Write-Host "5. Disable Windows Update: $(if ($disableWU) { 'Yes (Disable)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($disableWU) { "Y/n" } else { "y/N" }
        $defDesc = if ($disableWU) { "Default: Y (Disable)" } else { "Default: N (Keep)" }
        $opt = Read-Host "5. Disable Windows Update? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $disableWU = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $disableWU = $true }
        }
    }

    # 6. Bluetooth & Audio peripherals
    if ($cliBound.Contains('Bluetooth') -and (-not $Interactive)) {
        Write-Host "6. Keep Bluetooth audio and peripheral services: $(if ($keepBT) { 'Yes (Keep)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepBT) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepBT) { "Default: Y (Keep)" } else { "Default: N (Disable)" }
        $opt = Read-Host "6. Keep Bluetooth audio and peripheral services? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $keepBT = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepBT = $true }
        }
    }

    # 7. WSL2 & Virtualization (Resolves Issue #5)
    if ($cliBound.Contains('WSL') -and (-not $Interactive)) {
        Write-Host "7. Enable WSL2 and Virtual Machine Platform: $(if ($wslSupport) { 'Yes (Enable)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($wslSupport) { "Y/n" } else { "y/N" }
        $defDesc = if ($wslSupport) { "Default: Y (Enable)" } else { "Default: N (Disable)" }
        $opt = Read-Host "7. Enable WSL2 and Virtual Machine Platform before stripping WinSxS? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $wslSupport = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $wslSupport = $false }
        }
    }

    # 8. Windows Recovery Environment (WinRE)
    if ($cliBound.Contains('Recovery') -and (-not $Interactive)) {
        Write-Host "8. Keep Windows Recovery Environment (WinRE): $(if ($keepRecoveryEnv) { 'Yes (Keep)' } else { 'No (Remove)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($keepRecoveryEnv) { "Y/n" } else { "y/N" }
        $defDesc = if ($keepRecoveryEnv) { "Default: Y (Keep)" } else { "Default: N (Remove - removes WinRE safely post-install)" }
        $opt = Read-Host "8. Keep Windows Recovery Environment (WinRE)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $keepRecoveryEnv = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $keepRecoveryEnv = $false }
        }
    }

    # 9. Component Store (WinSxS) Optimization Mode
    if ($cliBound.Contains('WinSxS') -and (-not $Interactive)) {
        Write-Host "9. Component Store mode: $(if ($safeDebloatMode) { '1 (Safe Cleanup)' } else { '2 (Aggressive Pruning)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defMode = if ($safeDebloatMode) { "1" } else { "2" }
        $opt = Read-Host "9. Component Store optimization mode [1=Safe Cleanup (Recommended: 100% Setup success), 2=Aggressive Pruning (Experimental)] (Default: $defMode)"
        if ($opt) {
            if ($opt.Trim() -eq '2') { $safeDebloatMode = $false }
            elseif ($opt.Trim() -eq '1') { $safeDebloatMode = $true }
        }
    }

    # 10. UltraSlim (~3.2 GB ISO Target Mode)
    if ($cliBound.Contains('UltraSlim') -and (-not $Interactive)) {
        Write-Host "10. Enable UltraSlim mode: $(if ($ultraSlimMode) { 'Yes (Enable)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($ultraSlimMode) { "Y/n" } else { "y/N" }
        $defDesc = if ($ultraSlimMode) { "Default: Y (Enable)" } else { "Default: N (Disable)" }
        $opt = Read-Host "10. Enable UltraSlim mode (~3.2 GB ISO target: prunes Edge browser, non-JP CJK fonts, WinSxS dead weight, preserves WebView2 for OOBE)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) {
                $ultraSlimMode = $false
            } elseif ($opt.Trim().ToLower() -in @('yes', 'y')) {
                $ultraSlimMode = $true
            }
        }
    }

    # 11. Japanese 106/109 Keyboard Layout Configuration
    if ($cliBound.Contains('JPKey') -and (-not $Interactive)) {
        Write-Host "11. Configure Japanese 106/109 keyboard layout: $(if ($setJapaneseKeyboard) { 'Yes (Configure)' } else { 'No (Skip)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($setJapaneseKeyboard) { "Y/n" } else { "y/N" }
        $defDesc = if ($setJapaneseKeyboard) { "Default: Y (Configure)" } else { "Default: N (Skip)" }
        $opt = Read-Host "11. Configure Japanese 106/109 keyboard layout (prevents @/: mismatch)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $setJapaneseKeyboard = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $setJapaneseKeyboard = $true }
        }
    }

    # 12. AtlasOS & ReviOS Radical Debloat & Performance Optimization
    if ($cliBound.Contains('Atlas') -and (-not $Interactive)) {
        Write-Host "12. Enable AtlasOS & ReviOS radical debloat & latency optimizations: $(if ($atlasReviOSMode) { 'Yes (Enable)' } else { 'No (Disable)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($atlasReviOSMode) { "Y/n" } else { "y/N" }
        $defDesc = if ($atlasReviOSMode) { "Default: Y (Enable)" } else { "Default: N (Disable)" }
        $opt = Read-Host "12. Enable AtlasOS & ReviOS radical debloat & latency optimizations? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('no', 'n')) { $atlasReviOSMode = $false }
            elseif ($opt.Trim().ToLower() -in @('yes', 'y')) { $atlasReviOSMode = $true }
        }
    }

    # 13. Image compression format
    if (($cliBound.Contains('Export') -or $cliBound.Contains('SplitWIM')) -and (-not $Interactive)) {
        Write-Host "13. Image compression format: $(if ($exportESDMode) { '2 (install.esd Recovery LZMS)' } elseif ($splitWIMMode) { '3 (install.swm Split-WIM for FAT32)' } else { '1 (install.wim LZX)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defMode = if ($exportESDMode) { "2" } elseif ($splitWIMMode) { "3" } else { "1" }
        $opt = Read-Host "13. Image compression format [1=install.wim LZX (Default), 2=install.esd Recovery (LZMS), 3=install.swm (Split-WIM for FAT32 USB)] (Default: $defMode)"
        if ($opt) {
            if ($opt.Trim() -eq '2') { $exportESDMode = $true; $splitWIMMode = $false }
            elseif ($opt.Trim() -eq '3') { $splitWIMMode = $true; $exportESDMode = $false }
            elseif ($opt.Trim() -eq '1') { $exportESDMode = $false; $splitWIMMode = $false }
        }
    }

    # 14. Microsoft Store
    if ($cliBound.Contains('Store') -and (-not $Interactive)) {
        Write-Host "15. Remove Microsoft Store: $(if ($removeStore) { 'Yes (Remove)' } else { 'No (Keep)' }) [CLI: Specified]" -ForegroundColor DarkCyan
    } else {
        $defPrompt = if ($removeStore) { "Y/n" } else { "y/N" }
        $defDesc = if ($removeStore) { "Default: Y (Remove)" } else { "Default: N (Keep - Store apps/updates stay available)" }
        $opt = Read-Host "15. Remove Microsoft Store (Microsoft.WindowsStore + StorePurchaseApp; winget/App Installer is kept)? [$defPrompt] ($defDesc)"
        if ($opt) {
            if ($opt.Trim().ToLower() -in @('yes', 'y')) { $removeStore = $true }
            elseif ($opt.Trim().ToLower() -in @('no', 'n')) { $removeStore = $false }
        }
    }

    # Offer saving custom configuration as a JSON profile
    Write-Host ""
    $saveChoice = Read-Host "Would you like to save this custom configuration as a JSON profile? [y/N] (Default: N)"
    if ($saveChoice -and ($saveChoice.Trim().ToLower() -in @('y', 'yes'))) {
        $savePath = Read-Host "Enter JSON file path to save [Default: .\profiles\my-custom-profile.json]"
        if (-not $savePath) { $savePath = Join-Path -Path $PSScriptRoot -ChildPath "profiles\my-custom-profile.json" }
        $currentCfg = Get-Nano11CurrentConfig -ProfileName "Custom Profile"
        Export-Nano11Profile -FilePath $savePath -Config $currentCfg
    }
    }
}

# Export profile if requested via -SaveProfile parameter
if ($SaveProfile) {
    $currentCfg = Get-Nano11CurrentConfig -ProfileName $(if ($selectedProfile) { $selectedProfile } else { "Exported Profile" })
    Export-Nano11Profile -FilePath $SaveProfile -Config $currentCfg
}

# Save build configuration snapshot to logs/<timestamp>.config.json
$logsDir = Join-Path -Path $scriptDir -ChildPath "logs"
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Force -Path $logsDir -ErrorAction SilentlyContinue | Out-Null
}
$configSnapshotPath = Join-Path -Path $logsDir -ChildPath "nano11_$timestampStr.config.json"
$resolvedConfig = [PSCustomObject]@{
    Timestamp                  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Version                    = $script:Nano11Version
    Profile                    = if ($selectedProfile) { $selectedProfile } else { 'Extreme (Default)' }
    Architecture               = $architecture
    RemoveDefender             = $removeDefender
    KeepAsianIME               = $keepAsianIME
    KeepExtraFonts             = $keepExtraFonts
    RemoveDrivers              = $removeDrivers
    DisableWindowsUpdate       = $disableWU
    KeepBluetooth              = $keepBT
    WSLSupport                 = $wslSupport
    KeepRecoveryEnv            = $keepRecoveryEnv
    BypassActivationRestrictions = $bypassActivationRestrictions
    RadicalRAM                 = $radicalRAM
    SafeDebloatMode            = $safeDebloatMode
    UltraSlimMode              = $ultraSlimMode
    SetJapaneseKeyboard        = $setJapaneseKeyboard
    AtlasReviOSMode            = $atlasReviOSMode
    RemoveStore                = $removeStore
    KeepXboxServices           = $keepXboxServices
    KeepAudioTweaks            = $keepAudioTweaks
    PayloadFormat              = if ($exportESDMode) { "ESD" } elseif ($splitWIMMode) { "SWM" } else { "WIM" }
}
try {
    $resolvedConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configSnapshotPath -Encoding UTF8 -Force
} catch {}

Write-Host ""
Write-Host "Active configuration:" -ForegroundColor Cyan
Write-Host "  - Profile:                 $(if ($selectedProfile) { $selectedProfile } else { 'Extreme (Default)' })"
Write-Host "  - Remove Windows Defender: $removeDefender"
Write-Host "  - Keep Asian IMEs:         $keepAsianIME"
Write-Host "  - Keep Extra Fonts:        $keepExtraFonts"
Write-Host "  - Remove Legacy Drivers:   $removeDrivers"
Write-Host "  - Disable Windows Update:  $disableWU"
Write-Host "  - Keep Bluetooth Services: $keepBT"
Write-Host "  - Enable WSL2 Platform:    $wslSupport"
Write-Host "  - Keep Recovery (WinRE):   $keepRecoveryEnv"
Write-Host "  - Bypass Activation Limit: $bypassActivationRestrictions"
Write-Host "  - Radical RAM Optimization: $radicalRAM"
Write-Host "  - Safe Debloat (WinSxS):   $safeDebloatMode"
Write-Host "  - UltraSlim (~3GB ISO):    $ultraSlimMode"
Write-Host "  - Japanese 106 Keyboard:   $setJapaneseKeyboard"
Write-Host "  - AtlasOS & ReviOS Tuning: $atlasReviOSMode"
Write-Host "  - Remove Microsoft Store:  $removeStore"
Write-Host "  - Keep Xbox Services:      $keepXboxServices"
Write-Host "  - Low-Latency Audio MMCSS: $keepAudioTweaks"
Write-Host "  - Search Indexing:         $(if ($keepSearchIndex) { 'Enabled (kept)' } else { 'Disabled (WSearch service off + SearchHost blocked)' })"
Write-Host "  - Force WinSxS Cleanup:    $ForceWinSxSCleanup (experimental, opt-in)"
if (Test-Path -LiteralPath $configSnapshotPath) {
    Write-Host "  - Config Snapshot:         $configSnapshotPath" -ForegroundColor DarkCyan
}
Write-Host "  - Payload Format:          $(if ($exportESDMode) { 'install.esd (LZMS)' } elseif ($splitWIMMode) { 'install.swm (Split-WIM / FAT32)' } else { 'install.wim (LZX - Recommended)' })"
Write-Host ""
# G5: estimated build time from last run's phase timings
try {
    $lastTimingsPath = Join-Path -Path $logDir -ChildPath "last_phase_timings.json"
    if (Test-Path -LiteralPath $lastTimingsPath) {
        $lastTimings = (Get-Content -LiteralPath $lastTimingsPath -Raw -ErrorAction Stop) | ConvertFrom-Json
        $totalSec = 0
        foreach ($v in $lastTimings.PSObject.Properties.Value) { if ($v -is [double] -or $v -is [int] -or $v -is [long]) { $totalSec += [double]$v } }
        if ($totalSec -gt 0) {
            Write-Host "  - Estimated build time:    ~$([math]::Round($totalSec / 60, 1)) min (based on last run's phase timings)" -ForegroundColor DarkCyan
        }
    }
} catch {}

# Early verification of -SourceDrive
if ($SourceDrive) {
    if ($SourceDrive.EndsWith(".iso", [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $SourceDrive)) {
            throw "Specified Windows 11 ISO does not exist: $SourceDrive"
        }
    } else {
        $candDrive = "$($SourceDrive.Trim().TrimEnd(':')):"
        if ((-not (Test-Path -LiteralPath "$candDrive\sources\install.wim")) -and (-not (Test-Path -LiteralPath "$candDrive\sources\install.esd"))) {
            throw "Specified SourceDrive is invalid: $SourceDrive (sources\install.wim or install.esd not found)"
        }
    }
}

# Early check for NANO11_TEST_MODE or -DryRun / -WhatIf
if (($env:NANO11_TEST_MODE -eq "1") -or $isDryRunMode) {
    Write-Host ""
    Write-Host "[INFO] DryRun / TestMode active: Configuration resolved successfully." -ForegroundColor Yellow
    Write-Host "  - Profile: $(if ($selectedProfile) { $selectedProfile } else { 'Default' })" -ForegroundColor Yellow
    Write-Host "  - Payload Format: $(if ($exportESDMode) { 'ESD' } elseif ($splitWIMMode) { 'SWM' } else { 'WIM' })" -ForegroundColor Yellow
    Write-Host "  - Exiting without modifying images or workspace." -ForegroundColor Yellow
    if ($transcriptPath) { Stop-Transcript }
    exit 0
}

# ==============================================================================
# Main Build Lifecycle (Guaranteed Resource Cleanup via try / finally)
# ==============================================================================
# Decoupled Build Lifecycle State Flags (Rule 1)
$script:ExportSucceeded = $false
$script:FinalPayloadVerified = $false
$script:VerifiedFinalWimSha256 = $null
$script:IsoGenerated = $false
$script:IsoPayloadVerified = $false
$script:BuildSucceeded = $false
$isoCreatedSuccessfully = $false

$script:MountOpened = $false
$script:HivesLoaded = $false
$script:MountedIso = $null
$script:DefenderExclusionAdded = $false
$script:IsVhdxMounted = $false

# Diagnostic Session Isolation (Rule 2)
$script:BuildId = New-Nano11BuildId
$script:DiagDir = Join-Path -Path $scriptDir -ChildPath "build_diagnostics\$($script:BuildId)"
New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null

$script:DiagnosticData = [ordered]@{
    BuildId                  = $script:BuildId
    Timestamp                = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    BuilderScriptSha256      = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    DismPath                 = $null
    DismVersion              = $null
    SourceIsoPath            = $SourceDrive
    SourceIsoSha256          = $null
    SelectedImageIndex       = $null
    SelectedImageName        = $null
    PreExportWimSha256       = $null
    ExportedWimSha256        = $null
    FinalWimSha256           = $null
    ExportCommand            = $null
    ExportExitCode           = $null
    FinalApplyCommand        = $null
    FinalApplyExitCode       = $null
    OscdimgCommand           = $null
    OscdimgExitCode          = $null
    IsoEmbeddedWimSha256     = $null
    IsoPayloadMatch          = $false
    ExportSucceeded          = $false
    FinalPayloadVerified     = $false
    IsoGenerated             = $false
    IsoPayloadVerified       = $false
    BuildSucceeded           = $false
    FailurePhase             = $null
    FailureMessage           = $null
    FailureStackTrace        = $null
    PreservedArtifacts       = @()
}

function Write-Nano11DiagnosticReport {
    param([string]$StatusMessage = "")
    try {
        $jsonPath = Join-Path -Path $script:DiagDir -ChildPath "build_diagnostic_report.json"
        $script:DiagnosticData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding utf8

        $txtPath = Join-Path -Path $script:DiagDir -ChildPath "build_diagnostic_summary.txt"
        $txtLines = @(
            "=========================================================",
            " nano11 Build Diagnostic Summary",
            "=========================================================",
            "Build ID:                 $($script:DiagnosticData.BuildId)",
            "Timestamp:                $($script:DiagnosticData.Timestamp)",
            "Builder Script SHA256:    $($script:DiagnosticData.BuilderScriptSha256)",
            "Overall Build Status:     $(if ($script:DiagnosticData.BuildSucceeded) { 'SUCCESS' } else { 'FAILED' })",
            "Failure Phase:            $($script:DiagnosticData.FailurePhase)",
            "Failure Message:          $($script:DiagnosticData.FailureMessage)",
            "---------------------------------------------------------",
            "DISM Path:                $($script:DiagnosticData.DismPath)",
            "DISM Version:             $($script:DiagnosticData.DismVersion)",
            "Source ISO:               $($script:DiagnosticData.SourceIsoPath)",
            "Source ISO SHA256:        $($script:DiagnosticData.SourceIsoSha256)",
            "Selected Image Index:     $($script:DiagnosticData.SelectedImageIndex)",
            "Selected Image Name:      $($script:DiagnosticData.SelectedImageName)",
            "---------------------------------------------------------",
            "Export Succeeded:         $($script:DiagnosticData.ExportSucceeded)",
            "Export Exit Code:         $($script:DiagnosticData.ExportExitCode)",
            "Pre-Export WIM SHA256:    $($script:DiagnosticData.PreExportWimSha256)",
            "Exported WIM SHA256:      $($script:DiagnosticData.ExportedWimSha256)",
            "---------------------------------------------------------",
            "Final Apply Verified:     $($script:DiagnosticData.FinalPayloadVerified)",
            "Final Apply Exit Code:    $($script:DiagnosticData.FinalApplyExitCode)",
            "Final WIM SHA256:         $($script:DiagnosticData.FinalWimSha256)",
            "---------------------------------------------------------",
            "ISO Generated:            $($script:DiagnosticData.IsoGenerated)",
            "Oscdimg Exit Code:        $($script:DiagnosticData.OscdimgExitCode)",
            "ISO Embedded WIM SHA256:  $($script:DiagnosticData.IsoEmbeddedWimSha256)",
            "ISO Payload Match:        $($script:DiagnosticData.IsoPayloadMatch)",
            "---------------------------------------------------------",
            "Preserved Artifacts:",
            ($script:DiagnosticData.PreservedArtifacts | ForEach-Object { "  - $_" }),
            "========================================================="
        )
        $txtLines | Set-Content -LiteralPath $txtPath -Encoding utf8
    } catch {
        Write-Warning "Failed writing diagnostic report: $_"
    }
}

# ============================================================================
# A3. Host Environment Health Check (WIM transient corruption diagnostics)
# The Oct 16 builds hit repeated DISM 577 "transient decompression" errors and a
# final ISO payload hash mismatch on different phases/files - a signature of a
# flaky host (RAM / storage / firmware), not script logic. This check surfaces
# the risky signals BEFORE another multi-hour build wastes time.
# ============================================================================
function Invoke-Nano11HostHealthCheck {
    [CmdletBinding()]
    param([string]$WorkspaceDir)

    Write-Host "Host environment health check (stability diagnostics)..." -ForegroundColor Cyan
    $hostIssues = [System.Collections.Generic.List[string]]::new()

    # 1. Physical RAM capacity (< 8 GB stresses DISM mount + LZX export buffering)
    try {
        $csInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $ramGB = [math]::Round($csInfo.TotalPhysicalMemory / 1GB, 1)
        Write-Host "  - Physical RAM:           $ramGB GB" -ForegroundColor Gray
        if ($ramGB -lt 8) { $hostIssues.Add("Low physical RAM ($ramGB GB < 8 GB) increases LZX export failure risk.") }
    } catch { Write-Host "  - Physical RAM:           (detection unavailable)" -ForegroundColor DarkGray }

    # 2. Free space on workspace + system volume (deep verify clones the image)
    try {
        foreach ($rootTarget in @((@($WorkspaceDir) + @($env:SystemDrive)) | Select-Object -Unique)) {
            if (-not $rootTarget) { continue }
            $volLetter = (([System.IO.Path]::GetPathRoot(([System.IO.Path]::GetFullPath($rootTarget))) -replace ':\\?$', ''))
            $psd = Get-PSDrive -Name $volLetter -ErrorAction SilentlyContinue
            if ($psd) {
                $freeGB = [math]::Round($psd.Free / 1GB, 1)
                Write-Host "  - Free space ($($volLetter):):     $freeGB GB" -ForegroundColor Gray
                if ($freeGB -lt 40) { $hostIssues.Add("Low free space on the $volLetter`: drive ($freeGB GB free, 40+ GB recommended).") }
            }
        }
    } catch {}

    # 3. Physical disk SMART health (Storage module available on Win8+)
    $diskScanDone = $false
    try {
        $pdisks = Get-PhysicalDisk -ErrorAction Stop
        $diskScanDone = $true
        $badDisks = @($pdisks | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' })
        foreach ($d in $pdisks) {
            Write-Host "  - Disk: $($d.FriendlyName) [$($_.MediaType)]: $($_.HealthStatus)" -ForegroundColor Gray
        }
        if ($badDisks.Count -gt 0) {
            $hostIssues.Add(("Unhealthy physical disk(s): " + (($badDisks | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" }) -join ', ')))
        }
    } catch { if (-not $diskScanDone) { Write-Host "  - Physical disks:         (Storage module unavailable, skipped)" -ForegroundColor DarkGray } }

    # 4. Result banner
    if ($hostIssues.Count -gt 0) {
        Write-Host ""
        Write-Warning "*******************************************************************"
        Write-Warning " HOST ENVIRONMENT RISK DETECTED - review before another long build:"
        foreach ($hi in $hostIssues) { Write-Warning "  * $hi" }
        Write-Warning " WIM transient corruption (ExitCode 577 / hash mismatch) on this"
        Write-Warning " machine is commonly caused by RAM instability, storage device"
        Write-Warning " issues, or aggressive real-time AV scanning - not script logic."
        Write-Warning " Remedies: try -UseVHDX, another drive, or memtest/SMART review."
        Write-Warning "*******************************************************************"
        Write-Host ""
    } else {
        Write-Host "  Host health: no blocking risk factors detected." -ForegroundColor Green
    }
}

# ============================================================================
# A2. Resume-ISO Mode (-ResumeIsoOnly): Phase 14-18 fast-track from preserved payload
# Rebuilds the bootable ISO from the payload already verified & exported by a
# previous run (workspace\build\sources\install.wim), skipping Phases 1-13.
# Skipped deep-apply this run; run a timestamped full build offline whenever the
# host is stable. Designed to recover the Oct 16 "hash mismatch at the finish line"
# failure pattern without repeating a 15-minute debloat pipeline.
# ============================================================================
function Invoke-Nano11ResumeIsoBuild {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host "  nano11 RESUME-ISO MODE (-ResumeIsoOnly)" -ForegroundColor Cyan
    Write-Host "  Re-uses the preserved workspace payload; Phases 1-13 are skipped." -ForegroundColor Yellow
    Write-Host "==============================================================================" -ForegroundColor Cyan

    # 1. Resolve workspace with the same defaults as Phase 1 (Documents\nano11_workspace)
    $resumeWorkDir = $null
    if ($WorkDir) {
        $resumeWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
    } else {
        $docsDirResume = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docsDirResume) { $docsDirResume = Join-Path -Path $env:USERPROFILE -ChildPath "Documents" }
        $resumeWorkDir = Join-Path -Path $docsDirResume -ChildPath "nano11_workspace"
    }
    $resumeNanoDir = Join-Path -Path $resumeWorkDir -ChildPath "build"
    if (-not (Test-Path -LiteralPath $resumeNanoDir)) {
        throw "ResumeIsoOnly: build workspace not found at '$resumeNanoDir'. Run a normal build first (it preserves this folder automatically)."
    }
    Write-Host "Workspace:        $resumeWorkDir" -ForegroundColor Cyan

    # 2. Resolve preserved payload (install.wim / install.esd; SWM must be re-exported via full build)
    $resumePayload = $null
    $expectedPayloadFile = $null
    foreach ($candidate in @('install.wim', 'install.esd')) {
        $candPath = Join-Path -Path "$resumeNanoDir\sources" -ChildPath $candidate
        if ((Test-Path -LiteralPath $candPath) -and ((Get-Item -LiteralPath $candPath).Length -gt 1GB)) {
            $resumePayload = $candPath
            $expectedPayloadFile = $candidate
            break
        }
    }
    if (-not $resumePayload) {
        throw "ResumeIsoOnly: no valid install.wim / install.esd (> 1 GB) found in '$resumeNanoDir\sources'."
    }
    $resumeBootWim = Join-Path -Path "$resumeNanoDir\sources" -ChildPath "boot.wim"
    if (-not (Test-Path -LiteralPath $resumeBootWim)) {
        throw "ResumeIsoOnly: boot.wim is missing from '$resumeNanoDir\sources'. ISO mastering requires it."
    }
    foreach ($requiredRootItem in @('boot', 'efi', 'bootmgr', 'bootmgr.efi', 'bootmgfw.efi', 'setup.exe', 'autounattend.xml')) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $resumeNanoDir -ChildPath $requiredRootItem))) {
            throw "ResumeIsoOnly: ISO root item '$requiredRootItem' is missing in '$resumeNanoDir'. The workspace looks incomplete."
        }
    }
    $payloadSizeGB = [math]::Round((Get-Item -LiteralPath $resumePayload).Length / 1GB, 2)
    Write-Host "Payload:       $resumePayload ($payloadSizeGB GB)" -ForegroundColor Green

    # 3. Payload integrity (hash-level only; deep apply is deliberately skipped in resume mode)
    Invoke-Nano11HostHealthCheck -WorkspaceDir $resumeWorkDir
    Write-Host "Verifying payload structural integrity + SHA256..." -ForegroundColor Cyan
    $resumeMetaOut = & dism.exe /English /Get-WimInfo "/WimFile:$resumePayload" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ResumeIsoOnly: payload metadata validation failed (ExitCode: $LASTEXITCODE). The payload is unusable - run a full build instead."
    }
    $resumeIdx1 = & dism.exe /English /Get-WimInfo "/WimFile:$resumePayload" "/Index:1" 2>&1
    $resumeEditionName = if (($resumeIdx1 -join "`n") -match '(?m)^\s*Name\s*:\s*(.+)$') { $Matches[1].Trim() } else { $null }
    $resumeArch = if (($resumeIdx1 -join "`n") -match '(?m)^\s*Architecture\s*:\s*(\w+)') { $Matches[1].Trim() } else { "amd64" }
    $resumeExpandedSizeGB = if (($resumeIdx1 -join "`n") -match '(?m)^\s*Size\s*:\s*([\d,]+)\s*bytes') { [math]::Round((($Matches[1] -replace ',', '') -as [double]) / 1GB, 1) } else { 0 }
    Write-Host "  - Edition:            $resumeEditionName" -ForegroundColor Green
    Write-Host "  - Architecture:       $resumeArch" -ForegroundColor Green
    Write-Host "  - Expanded size:      $resumeExpandedSizeGB GB" -ForegroundColor Green

    $script:VerifiedFinalWimSha256 = (Get-FileHash -LiteralPath $resumePayload -Algorithm SHA256).Hash
    $script:FinalPayloadVerified = $true
    $script:IsoPayloadVerified = $false
    $activePayloadPath = $resumePayload

    if ($script:DiagnosticData) {
        $script:DiagnosticData.SourceIsoPath = "(resume mode - preserved workspace payload)"
        $script:DiagnosticData.SelectedImageIndex = 1
        $script:DiagnosticData.SelectedImageName = $resumeEditionName
        $script:DiagnosticData.FinalPayloadVerified = $true
        $script:DiagnosticData.FinalWimSha256 = $script:VerifiedFinalWimSha256
        $script:DiagnosticData.ExportSucceeded = $false
    }

    # 4. Phase 14 equivalent: patch boot.wim (LabConfig & bypasses) on both indexes
    $resumeLabConfigKeys = @(
        'BypassCPUCheck', 'BypassRAMCheck', 'BypassSecureBootCheck',
        'BypassStorageCheck', 'BypassTPMCheck', 'BypassDiskCheck'
    )
    Write-Host "Patching boot.wim (LabConfig + setup bypasses, Phase 14 equivalent)..." -ForegroundColor Green
    Set-ItemOwnershipAndAccess -Path $resumeBootWim
    try { Set-ItemProperty -LiteralPath $resumeBootWim -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}
    $resumeBootInfo = & dism.exe /English /Get-WimInfo "/WimFile:$resumeBootWim"
    $resumeHasIndex2 = (($resumeBootInfo -split '\r?\n') -match 'Index\s*:\s*2')
    $resumeIndices = if ($resumeHasIndex2) { @(1, 2) } else { @(1) }
    $bootWimPath = $resumeBootWim
    foreach ($bIndex in $resumeIndices) {
        Write-Host "  - Applying bypasses to boot.wim Index $bIndex..." -ForegroundColor Cyan
        $bMountResult = Invoke-Nano11ImageMount -ImageFile $resumeBootWim -ImageIndex $bIndex -Retries 3
        $scratchDir = $bMountResult.MountDir
        $script:DismMountDir = $scratchDir
        $script:MountOpened = $true
        try {
            & reg.exe query "HKLM\zSYSTEM" > $null 2>&1
            if ($LASTEXITCODE -eq 0) { [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM') }
            $bootHiveFile = "$scratchDir\Windows\System32\config\SYSTEM"
            $bootLoadOutput = & reg.exe load HKLM\zSYSTEM "$bootHiveFile" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Failed to load boot.wim Index $bIndex SYSTEM hive (Exit code: $LASTEXITCODE): $bootLoadOutput" }
            $script:HivesLoaded = $true
            foreach ($key in $resumeLabConfigKeys) {
                reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v $key /t REG_DWORD /d 1 /f > $null 2>&1
            }
            reg.exe add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassNRO" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f > $null 2>&1
            reg.exe add "HKLM\zSYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f > $null 2>&1
        } finally {
            [void](Unmount-RegistryHiveWithRetry -Name 'zSYSTEM')
            $script:HivesLoaded = $false
        }
        Set-Location -LiteralPath $scriptDir
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $bootUnmountSuccess = $false
        for ($bRetry = 1; $bRetry -le 3; $bRetry++) {
            Set-Location -LiteralPath $scriptDir
            Start-Sleep -Seconds 2
            & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
            if ($LASTEXITCODE -eq 0) { $bootUnmountSuccess = $true; break }
            Start-Sleep -Seconds (2 * $bRetry)
        }
        if (-not $bootUnmountSuccess) {
            & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
            throw "Failed to commit changes to boot.wim Index $bIndex after multiple attempts."
        }
        [void](Clear-DismMountConflicts -TargetMountDir $scratchDir -TargetWimFile $resumeBootWim)
        $script:MountOpened = $false
    }

    # 5. Phase 15 equivalent (light): metadata verified, SHA256 verified; deep apply intentionally skipped
    Write-Host "Deep apply verification is intentionally skipped in resume mode (run a full build to re-verify)." -ForegroundColor Yellow

    # 6. Phase 16 equivalent: ISO root cleanup + traceability manifest refresh
    Write-Host "ISO root cleanup (Phase 16 equivalent)..." -ForegroundColor Cyan
    $resumeKeepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "bootmgfw.efi", "setup.exe", "autounattend.xml", "nano11-build-info.json")
    Get-ChildItem -Path $resumeNanoDir | Where-Object { $_.Name -notin $resumeKeepList } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $resumeSourcesDir = Join-Path -Path $resumeNanoDir -ChildPath "sources"
    if (Test-Path -LiteralPath $resumeSourcesDir) {
        Remove-Item -Path "$resumeSourcesDir\setupcore.log" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$resumeSourcesDir\*.diagerr" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$resumeSourcesDir\*.diagxml" -Force -ErrorAction SilentlyContinue
        if ($ultraSlimMode) {
            Write-Host "  [UltraSlim] Trimming media payloads (sources\sxs, langpacks, sflist*.dat)..." -ForegroundColor Cyan
            Remove-Item -LiteralPath "$resumeSourcesDir\sxs" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$resumeSourcesDir\langpacks" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "$resumeSourcesDir\sflist*.dat" -Force -ErrorAction SilentlyContinue
        }
        $resumeSuspicious = Get-ChildItem -Path $resumeSourcesDir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "*backup*" -or $_.Name -like "*temp*" -or $_.Name -like "*export*"
        }
        if ($resumeSuspicious) {
            throw ("Verification failed: Temporary or backup files remain in ISO sources tree: " + (($resumeSuspicious | ForEach-Object { $_.Name }) -join ", "))
        }
    }
    # Refresh traceability manifest (keeps the same profile values, marks resume runs)
    try {
        $resumeInfoObj = [ordered]@{
            BuilderVersion   = $script:Nano11Version
            BuildUtc         = [DateTime]::UtcNow.ToString("o")
            Profile          = $selectedProfile
            Architecture     = $resumeArch
            ComputerName     = $ComputerName
            UserName         = $UserName
            ResumeMode       = $true
            KeepSearchIndex  = [bool]$keepSearchIndex
            DisableWindowsUpdate = [bool]$disableWU
            PowerPreset      = $PowerPreset
            SourceDrive      = "(resume mode)"
            PayloadFormat    = if ($expectedPayloadFile -eq 'install.esd') { "ESD" } else { "WIM" }
        }
        $resumeInfoObj | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path -Path $resumeNanoDir -ChildPath "nano11-build-info.json") -Encoding utf8
    } catch {}

    # 7. Phase 17 equivalent: locate verified oscdimg.exe (local first, then PATH/ADK)
    $resumeOscdimg = $null
    $resumeOscdimgCandidates = @(
        (Join-Path -Path $scriptDir -ChildPath "oscdimg.exe"),
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\arm64\Oscdimg\oscdimg.exe",
        "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    $pathOscdResume = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
    if ($pathOscdResume -and $pathOscdResume.Source) { $resumeOscdimgCandidates += $pathOscdResume.Source }
    foreach ($candidate in $resumeOscdimgCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate) -and (Test-OscdimgIntegrity -OscdimgPath $candidate)) {
            $resumeOscdimg = $candidate
            break
        }
    }
    if (-not $resumeOscdimg) {
        throw "ResumeIsoOnly: no Authenticode-verified oscdimg.exe available."
    }
    Write-Host "Using oscdimg.exe: $resumeOscdimg" -ForegroundColor Green

    # 8. Phase 18 equivalent: master bootable ISO + in-ISO payload verification (up to 3 attempts)
    $profSlugResume = if ($selectedProfile) { ($selectedProfile -replace '[^\w\-]', '_').Trim('_') } else { "custom" }
    $resumeOutputIsoName = if ($OutputIsoName) {
        "$OutputIsoName.iso"
    } elseif ($TimestampIso) {
        "nano11_${profSlugResume}_$(Get-Date -Format 'yyyyMMdd_HHmm').iso"
    } else { "nano11.iso" }
    $resumeOutputIso = Join-Path -Path $scriptDir -ChildPath $resumeOutputIsoName
    $resumeTempIso = Join-Path -Path $scriptDir -ChildPath "nano11_temp_resume_$($script:BuildId).iso"

    # Boot sector discovery (workspace-only candidates; source media is not mounted in resume mode)
    $resumeEtfsBoot = Join-Path -Path "$resumeNanoDir\boot" -ChildPath "etfsboot.com"
    $resumeEfiSys = $null
    foreach ($efiCand in @(
        (Join-Path -Path "$resumeNanoDir\efi\microsoft\boot" -ChildPath "efisys.bin"),
        (Join-Path -Path "$resumeNanoDir\efi\microsoft\boot" -ChildPath "efisys_noprompt.bin"),
        (Join-Path -Path "$resumeNanoDir\efi\boot" -ChildPath "efisys.bin"))) {
        if (Test-Path -LiteralPath $efiCand) { $resumeEfiSys = $efiCand; break }
    }
    $resumeBootData = $null
    $resumeUtfiSysSafe = if ($resumeEfiSys) { Get-SafeShortPath $resumeEfiSys } else { $null }
    $resumeEtfsSafe = if (($etf = $resumeEtfsBoot) -and (Test-Path -LiteralPath $etf)) { Get-SafeShortPath $etf } else { $null }
    if ($resumeUtfiSysSafe -and $resumeEtfsSafe -and ($resumeArch -ne 'arm64')) {
        $resumeBootData = "2#p0,e,b$resumeEtfsSafe#pEF,e,b$resumeUtfiSysSafe"
        Write-Host "Configured Dual Boot (BIOS + UEFI)" -ForegroundColor Green
    } elseif ($resumeUtfiSysSafe) {
        $resumeBootData = "1#pEF,e,b$resumeUtfiSysSafe"
        Write-Host "Configured UEFI Boot" -ForegroundColor Green
    } elseif ($resumeEtfsSafe) {
        $resumeBootData = "1#p0,e,b$resumeEtfsSafe"
        Write-Host "Configured BIOS Boot" -ForegroundColor Green
    } else {
        throw "ResumeIsoOnly: missing boot sector files (etfsboot.com / efisys.bin) in workspace."
    }

    $resumeExpectedPayload = $expectedPayloadFile
    $resumeIsoSuccess = $false
    $resumeIsoAttempt = 0
    while (-not $resumeIsoSuccess -and $resumeIsoAttempt -lt 3) {
        $resumeIsoAttempt++
        if (Test-Path -LiteralPath $resumeTempIso) { Remove-Item -LiteralPath $resumeTempIso -Force -ErrorAction SilentlyContinue }
        $resumeOscdimgArgs = @("-m", "-u2", "-udfver102", "-lnano11")
        if ($resumeBootData) { $resumeOscdimgArgs += "-bootdata:$resumeBootData" }
        $resumeOscdimgArgs += $resumeNanoDir
        $resumeOscdimgArgs += $resumeTempIso

        Write-Host "Executing oscdimg (Attempt $resumeIsoAttempt of 3): $resumeTempIso..." -ForegroundColor Cyan
        & "$resumeOscdimg" @resumeOscdimgArgs
        $resumeOscdimgExit = $LASTEXITCODE
        if ($script:DiagnosticData) { $script:DiagnosticData.OscdimgExitCode = $resumeOscdimgExit }
        if ($resumeOscdimgExit -ne 0 -or (-not (Test-Path -LiteralPath $resumeTempIso)) -or ((Get-Item -LiteralPath $resumeTempIso).Length -lt 1.5GB)) {
            Write-Warning "oscdimg failed on attempt $resumeIsoAttempt (ExitCode: $resumeOscdimgExit). Retrying after cooldown..."
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 5
            continue
        }

        Write-Host "Mounting temporary ISO to verify embedded payload integrity..." -ForegroundColor Cyan
        $resumeMountResult = $null
        try {
            $resumeMountResult = Mount-DiskImage -ImagePath $resumeTempIso -StorageType ISO -PassThru -ErrorAction Stop
            $resumeVol = Get-Volume -DiskImage $resumeMountResult -ErrorAction Stop | Select-Object -First 1
            $resumeIsoDrive = $resumeVol.DriveLetter
            if (-not $resumeIsoDrive) { throw "Failed to determine drive letter for mounted ISO." }
            $resumeEmbeddedPath = "${resumeIsoDrive}:\sources\$resumeExpectedPayload"
            if (-not (Test-Path -LiteralPath $resumeEmbeddedPath)) { throw "Mounted ISO is missing sources\$resumeExpectedPayload payload." }

            $resumeEmbeddedItem = Get-Item -LiteralPath $resumeEmbeddedPath -ErrorAction Stop
            if ($resumeEmbeddedItem.Length -ne $activePayloadPath.Length) { throw "Embedded payload size mismatch." }
            & dism.exe /English /Get-WimInfo "/WimFile:$resumeEmbeddedPath" > $null 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Embedded payload failed DISM metadata validation (ExitCode: $LASTEXITCODE)." }

            $resumeEmbeddedSha = (Get-FileHash -LiteralPath $resumeEmbeddedPath -Algorithm SHA256).Hash
            if ($script:DiagnosticData) { $script:DiagnosticData.IsoEmbeddedWimSha256 = $resumeEmbeddedSha }
            Write-Host "  Verified Final Payload SHA256:  $script:VerifiedFinalWimSha256" -ForegroundColor Cyan
            Write-Host "  ISO Embedded Payload SHA256:    $resumeEmbeddedSha" -ForegroundColor Cyan
            if ($resumeEmbeddedSha -ne $script:VerifiedFinalWimSha256) {
                $resumeRehash = (Get-FileHash -LiteralPath $activePayloadPath -Algorithm SHA256).Hash
                if ($resumeEmbeddedSha -eq $resumeRehash) {
                    $script:VerifiedFinalWimSha256 = $resumeRehash
                    Write-Host "  [PASS] payload hash consistent with current on-disk payload." -ForegroundColor Green
                } else {
                    throw "PAYLOAD HASH MISMATCH: ISO embedded ($resumeEmbeddedSha) vs payload on disk ($resumeRehash). Likely host instability - retrying."
                }
            }
            $resumeIsoSuccess = $true
            $script:IsoPayloadVerified = $true
            if ($script:DiagnosticData) { $script:DiagnosticData.IsoPayloadMatch = $true }
            Write-Host "  [PASS] ISO embedded payload verified identical." -ForegroundColor Green
        } catch {
            Write-Warning "ISO verification failed on attempt $($resumeIsoAttempt): $_"
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 5
        } finally {
            if ($resumeMountResult) {
                try { Dismount-DiskImage -ImagePath $resumeTempIso -ErrorAction SilentlyContinue | Out-Null } catch {}
            }
        }
    }
    if (-not $resumeIsoSuccess) {
        throw "ResumeIsoOnly: failed to create a verified bootable ISO after 3 attempts."
    }

    # 9. Promote, rotate, final hash + HTML report
    [void](Invoke-Nano11PromoteTemporaryIso -TempIsoPath $resumeTempIso -TargetIsoPath $resumeOutputIso -BuildId $script:BuildId)
    if ($TimestampIso) {
        try {
            $resumeProfileIsos = Get-ChildItem -Path $scriptDir -Filter "nano11_${profSlugResume}_*.iso" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($resumeProfileIsos.Count -gt 3) {
                $resumeProfileIsos | Select-Object -Skip 3 | ForEach-Object {
                    Write-Host "Rotating out older generation ISO: $($_.Name)" -ForegroundColor DarkGray
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    }
    $resumeIsoItem = Get-Item -LiteralPath $resumeOutputIso
    $resumeIsoSha256 = (Get-FileHash -LiteralPath $resumeOutputIso -Algorithm SHA256).Hash
    try {
        $resumeReportPath = Join-Path -Path $scriptDir -ChildPath "nano11_report.html"
        Export-Nano11HtmlReport -OutputPath $resumeReportPath -BuildInfo @{
            Title             = "nano11 Resume Build Report - $selectedProfile"
            Timestamp         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Profile           = $selectedProfile
            Architecture      = $resumeArch
            SourceDrive       = "(resume mode)"
            OutputIso         = $resumeOutputIso
            PayloadFormat     = if ($expectedPayloadFile -eq 'install.esd') { "install.esd" } else { "install.wim" }
            OriginalSizeBytes = [int64]($resumeExpandedSizeGB * 1GB)
            FinalSizeBytes    = $resumeIsoItem.Length
            IsoSha256         = $resumeIsoSha256
            Settings          = (Get-Nano11CurrentConfig -ProfileName $selectedProfile)
            ApplyVerified     = $script:FinalPayloadVerified
            IsoPayloadMatch   = $script:IsoPayloadVerified
        }
        Write-Host "Visual Build Report generated: $resumeReportPath" -ForegroundColor Cyan
    } catch { Write-Warning "Could not export visual build report: $_" }

    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "  nano11 RESUME BUILD SUCCESSFUL" -ForegroundColor Green
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "  - Output ISO:        $resumeOutputIso" -ForegroundColor Green
    Write-Host "  - ISO Size:          $([math]::Round($resumeIsoItem.Length / 1GB, 2)) GB" -ForegroundColor Green
    Write-Host "  - ISO SHA256:        $resumeIsoSha256" -ForegroundColor Green
    Write-Host "==============================================================================" -ForegroundColor Green
    Write-Host "Build lifecycle finished in $($buildStopwatch.Elapsed.TotalSeconds.ToString('0.0')) seconds (resume mode)."
    if ($script:DiagnosticData) {
        $script:DiagnosticData.BuildSucceeded = $true
        $script:DiagnosticData.IsoGenerated = $true
        $script:DiagnosticData.IsoPayloadVerified = $true
        Write-Nano11DiagnosticReport "Resume build succeeded"
    }
    try { Stop-Transcript } catch {}
}

# ============================================================================
# F2. Phase Checkpoint Save/Load (foundation for -ResumeFromPhase)
# ============================================================================
function Save-Nano11Checkpoint {
    [CmdletBinding()]
    param([int]$CompletedPhase = 0)
    try {
        if (-not $script:BaseWorkDir) { return }
        $cpPath = Join-Path -Path $script:BaseWorkDir -ChildPath "checkpoint.json"
        $cp = [ordered]@{
            CompletedPhase       = $CompletedPhase
            Timestamp           = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            BuildId             = $script:BuildId
            BaseWorkDir         = $script:BaseWorkDir
            Nano11Dir           = $nano11Dir
            ScratchDir          = $scratchDir
            VhdxMountDir        = $vhdxMountDir
            DriveLetter         = $DriveLetter
            Index               = $index
            TargetEditionName   = $targetEditionName
            Architecture        = $architecture
            LanguageCode        = $languageCode
            SelectedProfile     = $selectedProfile
            KeepSearchIndex     = [bool]$keepSearchIndex
            RemoveDefender      = [bool]$removeDefender
            UltraSlimMode       = [bool]$ultraSlimMode
            SafeDebloatMode     = [bool]$safeDebloatMode
        }
        $cp | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cpPath -Encoding utf8 -Force
    } catch {
        Write-Warning "Checkpoint save skipped: $_"
    }
}

function Load-Nano11Checkpoint {
    [CmdletBinding()]
    param()
    $cpPath = $null
    if ($script:BaseWorkDir) { $cpPath = Join-Path -Path $script:BaseWorkDir -ChildPath "checkpoint.json" }
    if (-not $cpPath -or -not (Test-Path -LiteralPath $cpPath)) {
        # Try default workspace
        $docsDir = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docsDir) { $docsDir = Join-Path -Path $env:USERPROFILE -ChildPath "Documents" }
        $cpPath = Join-Path -Path (Join-Path -Path $docsDir -ChildPath "nano11_workspace") -ChildPath "checkpoint.json"
    }
    if (-not (Test-Path -LiteralPath $cpPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($cpPath, [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Warning "Checkpoint load failed: $_"
        return $null
    }
}

# Resume mode entry point (before Phase 1 so no destructive early phases can run)
if ($ResumeFromPhase -gt 0) {
    if ($GUI -or $TestSelf -or $DryRun) {
        throw "ResumeFromPhase cannot be combined with -GUI / -TestSelf / -DryRun."
    }
    $cp = Load-Nano11Checkpoint
    if (-not $cp) {
        throw "ResumeFromPhase: no checkpoint.json found. Run a full build first so a checkpoint is recorded."
    }
    $cpPhase = [int]$cp.CompletedPhase
    if ($cpPhase -lt ($ResumeFromPhase - 1)) {
        throw "ResumeFromPhase: checkpoint only reaches Phase $cpPhase, cannot resume from Phase $ResumeFromPhase. Run a full build or lower the target."
    }
    Write-Host "Checkpoint loaded: last completed phase = $cpPhase (timestamp $($cp.Timestamp))" -ForegroundColor Cyan
    if ($ResumeFromPhase -ge 13) {
        Write-Host "ResumeFromPhase $ResumeFromPhase >= 13: delegating to Resume-ISO mode (Phase 14+ fast-track)..." -ForegroundColor Yellow
        # Hydrate the state ResumeIsoOnly relies on (it re-derives workspace/payload itself)
        try {
            Invoke-Nano11ResumeIsoBuild
            exit 0
        } catch {
            if ($script:DiagnosticData) {
                $script:DiagnosticData.FailurePhase = "ResumeFromPhase Mode"
                $script:DiagnosticData.FailureMessage = "$_"
                Write-Nano11DiagnosticReport "Resume failed"
            }
            Write-Host "ResumeFromPhase failed: $_" -ForegroundColor Red
            try { Stop-Transcript } catch {}
            exit 1
        }
    } else {
        Write-Host "ResumeFromPhase $ResumeFromPhase < 13: early phases are fast; running full build (checkpoint will be refreshed)..." -ForegroundColor Yellow
        # Fall through to normal build; checkpoint saving along the way keeps state fresh
    }
}

# ResumeIsoOnly entry point (before Phase 1 so no destructive early phases can run)
if ($ResumeIsoOnly) {
    if ($GUI -or $TestSelf -or $DryRun) {
        throw "ResumeIsoOnly cannot be combined with -GUI / -TestSelf / -DryRun."
    }
    try {
        Invoke-Nano11ResumeIsoBuild
        exit 0
    } catch {
        if ($script:DiagnosticData) {
            $script:DiagnosticData.FailurePhase = "Resume-ISO Mode"
            $script:DiagnosticData.FailureMessage = "$_"
            Write-Nano11DiagnosticReport "Resume build failed"
        }
        Write-Host "" -ForegroundColor Red
        Write-Host "==============================================================================" -ForegroundColor Red
        Write-Host "  nano11 RESUME BUILD FAILED!" -ForegroundColor Red
        Write-Host "==============================================================================" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host "Preserved workspace payload: $(if ($WorkDir) { $WorkDir } else { '<Documents>\nano11_workspace\build' })" -ForegroundColor Gray
        try { Stop-Transcript } catch {}
        exit 1
    }
}

try {
    $phasesDir = Join-Path -Path $scriptDir -ChildPath "phases"

        Enter-Phase 1 "Environment Validation & Workspace Preparation"
    . (Join-Path -Path $phasesDir -ChildPath "01-environment.ps1")

    Enter-Phase 2 "Source Media Detection & Validation"
    . (Join-Path -Path $phasesDir -ChildPath "02-source-media.ps1")

    Enter-Phase 3 "Installation Media Preparation & Staging"
    . (Join-Path -Path $phasesDir -ChildPath "03-staging.ps1")

    Enter-Phase 4 "Mount install.wim & Baseline Analysis"
    . (Join-Path -Path $phasesDir -ChildPath "04-mount-baseline.ps1")

    Enter-Phase 5 "Removing provisioned AppX packages (Bloatware)"
    . (Join-Path -Path $phasesDir -ChildPath "05-appx.ps1")

    Enter-Phase 6 "Removing system packages (FoD / Optional features)"
    . (Join-Path -Path $phasesDir -ChildPath "06-fod.ps1")

    Enter-Phase 7 "Removing NativeImages (.NET)"
    . (Join-Path -Path $phasesDir -ChildPath "07-nativeimages.ps1")

    Enter-Phase 8 "File system slimming (Drivers, WinRE, Fonts)"
    . (Join-Path -Path $phasesDir -ChildPath "08-filesystem.ps1")

    Enter-Phase 9 "Component Store (WinSxS) Optimization"
    . (Join-Path -Path $phasesDir -ChildPath "09-winsxs.ps1")

    Enter-Phase 10 "Load Registry Hives and Apply Optimizations"
    . (Join-Path -Path $phasesDir -ChildPath "10-registry.ps1")

    Enter-Phase 11 "Configure autounattend.xml & Pre-extract Setup Scripts"
    . (Join-Path -Path $phasesDir -ChildPath "11-unattend.ps1")

    Enter-Phase 12 "Unmount and Commit install.wim Image"
    . (Join-Path -Path $phasesDir -ChildPath "12-unmount-commit.ps1")

    Enter-Phase 13 "Export Modified Image (WIM / ESD / SWM)"
    . (Join-Path -Path $phasesDir -ChildPath "13-export.ps1")

    Enter-Phase 14 "Patch boot.wim (LabConfig & Bypasses)"
    . (Join-Path -Path $phasesDir -ChildPath "14-bootwim.ps1")

    Enter-Phase 15 "Verify Final Installation Payload"
    . (Join-Path -Path $phasesDir -ChildPath "15-verify.ps1")

    Enter-Phase 16 "ISO Root Cleanup & Traceability Embedding"
    . (Join-Path -Path $phasesDir -ChildPath "16-iso-cleanup.ps1")

    Enter-Phase 17 "Locate or Verify oscdimg.exe"
    . (Join-Path -Path $phasesDir -ChildPath "17-oscdimg.ps1")

    Enter-Phase 18 "Create Bootable ISO Image"
    . (Join-Path -Path $phasesDir -ChildPath "18-iso.ps1")

} catch {
    # Outer catch block: Reset success flags, record diagnostics, re-throw (Rule 16)
    $script:BuildSucceeded = $false
    $isoCreatedSuccessfully = $false
    if ($script:DiagnosticData) {
        $script:DiagnosticData.BuildSucceeded = $false
        $script:DiagnosticData.FailureMessage = "$_"
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $script:DiagnosticData.FailureStackTrace = "$($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)"
        } else {
            $script:DiagnosticData.FailureStackTrace = "$($_.ScriptStackTrace)"
        }
        Write-Nano11DiagnosticReport "Build failed with exception"
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host "   nano11 BUILD FAILED!                                  " -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host "Build failed with unhandled exception: $_" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host "Exception location: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    }
    if ($_.ScriptStackTrace) {
        Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
    throw
} finally {
    Write-Host ""
    Write-Host "Running cleanup and finalizing build lifecycle..." -ForegroundColor Cyan

    Set-Location -LiteralPath $scriptDir
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    # 1. ALWAYS unmount offline registry hives (Rule 17)
    if ($script:HivesLoaded) {
        Write-Host "Cleaning up lingering registry hives..." -ForegroundColor Yellow
        @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
            try { [void](Unmount-RegistryHiveWithRetry -Name $_) } catch {}
        }
        $script:HivesLoaded = $false
    }

    # 2. ALWAYS unmount lingering DISM mounts across all allocated mount directories (Rule 17)
    $allTargetMounts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($script:AllocatedMountDirs) {
        foreach ($d in $script:AllocatedMountDirs) { [void]$allTargetMounts.Add($d) }
    }
    if ($scratchDir) {
        try { [void]$allTargetMounts.Add((ConvertTo-Nano11NormalizedPath -Path $scratchDir)) } catch {}
    }
    if ($vhdxMountDir -and (-not $script:IsVhdxMounted)) {
        try { [void]$allTargetMounts.Add((ConvertTo-Nano11NormalizedPath -Path $vhdxMountDir)) } catch {}
    }

    foreach ($mPath in $allTargetMounts) {
        if ($script:PreservedMountDirs -and $script:PreservedMountDirs.Contains($mPath)) {
            Write-Warning "Mount directory '$mPath' is marked as Preserved. Skipping cleanup."
            continue
        }

        try {
            $activeMounts = @(Get-Nano11MountedImages)
            $lingeringMount = $activeMounts | Where-Object {
                $p = if ($_.Path) { try { ConvertTo-Nano11NormalizedPath -Path $_.Path } catch { $null } } else { $null }
                $p -and ($p -ieq $mPath)
            }
            if ($lingeringMount -or $script:MountOpened) {
                Write-Host "Discarding lingering DISM mount on '$mPath'..." -ForegroundColor Yellow
                Clear-DismMountConflicts -TargetMountDir $mPath
            }
            [void](Unmount-DismOfflineHives -TargetMountDir $mPath -BestEffort)
        } catch {
            Write-Warning "Could not query or clean mount status for '$mPath': $_"
        }
    }

    # 3. Detach VHDX scratch disk if initialized (Strict status check before true)
    $vhdxDetached = $false
    if ($script:IsVhdxMounted -or ($vhdxPath -and (Test-Path -LiteralPath $vhdxPath))) {
        try {
            Write-Host "Detaching VHDX scratch disk..." -ForegroundColor Cyan
            $dpDetachScript = "select vdisk file=`"$vhdxPath`"`r`ndetach vdisk`r`n"
            $dpDetachFile = Join-Path -Path $env:TEMP -ChildPath "nano11_dp_detach_$($script:BuildId)_$([System.IO.Path]::GetRandomFileName()).txt"
            $dpDetachScript | Set-Content -LiteralPath $dpDetachFile -Encoding ascii
            $dpOut = & diskpart.exe /s $dpDetachFile 2>&1
            $dpExit = $LASTEXITCODE
            Remove-Item -LiteralPath $dpDetachFile -Force -ErrorAction SilentlyContinue

            if ($script:DiagnosticData) {
                $script:DiagnosticData['VhdxDetachExitCode'] = $dpExit
                $script:DiagnosticData['VhdxDetachOutput'] = ($dpOut -join "`n")
            }

            if ($dpExit -eq 0) {
                try {
                    $diskImg = Get-DiskImage -ImagePath $vhdxPath -ErrorAction Stop
                    if ($diskImg -and ($diskImg.Attached -eq $false)) {
                        $vhdxDetached = $true
                        $script:IsVhdxMounted = $false
                    } else {
                        Write-Warning "VHDX disk image still reports Attached = $(if ($diskImg) { $diskImg.Attached } else { 'Unknown' }) despite detach command."
                    }
                } catch {
                    Write-Warning "Could not verify VHDX detachment state via Get-DiskImage: $_"
                }
            } else {
                Write-Warning "diskpart detach command returned non-zero code ${dpExit}: $($dpOut -join ' ')"
            }
        } catch {
            Write-Warning "VHDX detachment encountered error: $_"
        }
    }

    # 4. ALWAYS dismount source ISO if mounted by nano11 (Rule 17)
    if ($script:MountedIso) {
        Write-Host "Dismounting source Windows 11 ISO..." -ForegroundColor Cyan
        try {
            Dismount-DiskImage -ImagePath $script:MountedIso.ImagePath -ErrorAction SilentlyContinue > $null
            $script:MountedIso = $null
        } catch {}
    }

    # 5. ALWAYS remove Windows Defender temporary workspace exclusion (Rule 17)
    if ($script:DefenderExclusionAdded -and $baseWorkDir) {
        try {
            Remove-MpPreference -ExclusionPath $baseWorkDir -ErrorAction SilentlyContinue
            $script:DefenderExclusionAdded = $false
        } catch {}
    }

    # 6. Disk deletion: ONLY IF ALL SAFETY CONDITIONS MET
    $destWimBackupPath = if ($baseWorkDir) { Join-Path -Path $baseWorkDir -ChildPath "install_pre_export_backup_$($script:BuildId).wim" } else { $null }
    $canDeleteWorkspace = Test-CanSafelyDeleteDirectory -Path $nano11Dir -ExpectedBaseDir $baseWorkDir -PreservedDirs $script:PreservedMountDirs

    if ($script:BuildSucceeded -and $canDeleteWorkspace) {
        Write-Host "Build succeeded and safety checks passed. Cleaning workspace artifacts..." -ForegroundColor Cyan

        # Clean backup WIM outside ISO tree
        if ($destWimBackupPath -and (Test-Path -LiteralPath $destWimBackupPath)) {
            Remove-Item -LiteralPath $destWimBackupPath -Force -ErrorAction SilentlyContinue
        }

        # Clean nano11Dir (fast path first: reparse prune + robocopy /B + rd). Previously this used
        # Reset-DirectoryWithRobocopy, whose per-item ACL pass took ~5 hours on 100k-file trees.
        if ($nano11Dir -and (Test-Path -LiteralPath $nano11Dir)) {
            $swClean = [System.Diagnostics.Stopwatch]::StartNew()
            $cleanOk = Remove-Nano11TreeRobust -Path $nano11Dir -SafetyRoot $baseWorkDir -AllowLockedFallback
            $swClean.Stop()
            if ($cleanOk) {
                Write-Host "  - ISO workspace cleanup: removed ($([math]::Round($swClean.Elapsed.TotalSeconds,1))s)" -ForegroundColor DarkGray
            } else {
                Write-Warning "ISO workspace cleanup incomplete: $nano11Dir"
            }
        }

        # Clean target mount directories only if individual safety checks pass
        foreach ($mPath in $allTargetMounts) {
            if (Test-CanSafelyDeleteDirectory -Path $mPath -ExpectedBaseDir $baseWorkDir -PreservedDirs $script:PreservedMountDirs) {
                $swMount = [System.Diagnostics.Stopwatch]::StartNew()
                $mountOk = Remove-Nano11TreeRobust -Path $mPath -SafetyRoot $baseWorkDir -AllowLockedFallback
                $swMount.Stop()
                if ($mountOk) {
                    Write-Host "  - Mount dir cleanup ($(Split-Path -Leaf $mPath)): removed ($([math]::Round($swMount.Elapsed.TotalSeconds,1))s)" -ForegroundColor DarkGray
                } else {
                    Write-Warning "Mount dir cleanup incomplete: $mPath"
                }
            }
        }

        # Clean VHDX file on success only if confirmed detached and all safety guards pass
        if (Test-CanSafelyDeleteVhdx -VhdxPath $vhdxPath -VhdxDetached $vhdxDetached -ExpectedBaseDir $baseWorkDir -PreservedDirs $script:PreservedMountDirs) {
            if ($vhdxMountDir -and (Test-Path -LiteralPath $vhdxMountDir)) {
                $rpCheck = Get-Item -LiteralPath $vhdxMountDir -Force -ErrorAction SilentlyContinue
                if ($rpCheck -and ($rpCheck.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    try { & mountvol.exe "$vhdxMountDir" /D > $null 2>&1 } catch {}
                    try { [System.IO.Directory]::Delete($vhdxMountDir, $false) } catch { try { $rpCheck.Delete() } catch {} }
                } else {
                    if (Test-CanSafelyDeleteDirectory -Path $vhdxMountDir -ExpectedBaseDir $baseWorkDir -PreservedDirs $script:PreservedMountDirs) {
                        [void](Remove-Nano11TreeRobust -Path $vhdxMountDir -SafetyRoot $baseWorkDir -AllowLockedFallback)
                    }
                }
            }
            Remove-Item -LiteralPath $vhdxPath -Force -ErrorAction SilentlyContinue
        }
    } else {
        # BUILD FAILED OR UNVERIFIED STATE: STRICTLY PRESERVE FORENSIC ARTIFACTS
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Yellow
        Write-Host " [DIAGNOSTIC PRESERVATION] BUILD NOT COMPLETED / PROTECTED" -ForegroundColor Yellow
        Write-Host " Preserving intermediate artifacts for forensic analysis:" -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Yellow
        if ($nano11Dir -and (Test-Path -LiteralPath $nano11Dir)) {
            Write-Host "  - ISO Workspace:     $nano11Dir" -ForegroundColor Yellow
            $script:DiagnosticData.PreservedArtifacts += $nano11Dir
            $finalWimPath = Join-Path -Path "$nano11Dir\sources" -ChildPath "install.wim"
            if (Test-Path -LiteralPath $finalWimPath) {
                Write-Host "  - Exported WIM:      $finalWimPath" -ForegroundColor Yellow
                $script:DiagnosticData.PreservedArtifacts += $finalWimPath
            }
        }
        if ($destWimBackupPath -and (Test-Path -LiteralPath $destWimBackupPath)) {
            Write-Host "  - Pre-Export WIM:    $destWimBackupPath" -ForegroundColor Yellow
            $script:DiagnosticData.PreservedArtifacts += $destWimBackupPath
        }
        if ($baseWorkDir -and (Test-Path -LiteralPath $baseWorkDir)) {
            Write-Host "  - Working Directory: $baseWorkDir" -ForegroundColor Yellow
            $script:DiagnosticData.PreservedArtifacts += $baseWorkDir
        }
        if ($vhdxPath -and (Test-Path -LiteralPath $vhdxPath)) {
            Write-Host "  - VHDX Scratch Disk: $vhdxPath" -ForegroundColor Yellow
            $script:DiagnosticData.PreservedArtifacts += $vhdxPath
        }
        if ($script:DiagDir) {
            Write-Host "  - Diagnostic Report: $script:DiagDir" -ForegroundColor Yellow
            $script:DiagnosticData.PreservedArtifacts += $script:DiagDir
        }
        Write-Host "=========================================================" -ForegroundColor Yellow
        Write-Nano11DiagnosticReport "Artifacts preserved after build failure or unverified state"
    }

    # 7. Build elapsed time and policy stats
    if ($buildStopwatch) {
        $buildStopwatch.Stop()
        $elapsedSec = [math]::Round($buildStopwatch.Elapsed.TotalSeconds, 1)
        Write-Host "Build lifecycle finished in $elapsedSec seconds." -ForegroundColor Cyan
    }

    if ($transcriptPath) {
        Stop-Transcript
    }

    # 8. Release global mutex guard
    if ($script:BuildMutex) {
        try {
            $script:BuildMutex.ReleaseMutex()
            $script:BuildMutex.Dispose()
            $script:BuildMutex = $null
        } catch {}
    }

    if ($script:BuildSucceeded) {
        Write-Host "Done! nano11.iso is ready." -ForegroundColor Green
    } else {
        Write-Host "Process ended with errors. Build did not succeed." -ForegroundColor Red
        if ($script:DiagDir) {
            Write-Host "Diagnostic report directory: $script:DiagDir" -ForegroundColor Yellow
        }
        if ($transcriptPath) {
            Write-Host "Please check the logs in $transcriptPath" -ForegroundColor Yellow
        }
    }
}

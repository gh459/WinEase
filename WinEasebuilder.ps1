#Requires -Version 5.1
<#
.SYNOPSIS
    WinEase Builder - Universal, Language-Independent Windows 11 Image Reducer
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

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'isoCreatedSuccessfully', Justification = 'Read by New-BuildContextFromScriptScope and the phases in script scope')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = '-Profile is the public preset parameter; renaming it would break the command line')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'UserPassword is an unattended setup string parameter')]
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [alias("Unattended", "Silent", "Batch")]
    [switch]$NonInteractive,
    [switch]$Interactive,
    [alias("UI")]
    [switch]$GUI,
    # Display language of the GUI windows (display only; default: the saved choice, else the OS language)
    [ValidateSet("en", "ja")]
    [string]$UiLanguage,
    # Use the classic WinForms window even when the WinUI 3 window (gui\winui) is built
    [switch]$ClassicGui,
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
    [switch]$StrictDependencyCheck,
    [switch]$NoPostInstallAssets,
    # E1: Explicit opt-in gate for destructive physical debloat (Phase 9.5, 09-physical-debloat.ps1).
    # Advanced Debloat selections arriving from a profile or GUI are NOT sufficient by themselves.
    [switch]$AllowPhysicalDebloat,

    # Customization & Maintenance Settings
    # Both values are inserted verbatim into autounattend.xml and its embedded PowerShell scripts,
    # so only characters that are safe in XML, in '...' and in "..." PowerShell strings are accepted.
    # ComputerName: '*' (random) or a NetBIOS name (letters, digits, hyphen; max 15).
    [ValidatePattern('^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$')]
    [string]$ComputerName = '*',
    # UserName: letters (incl. Japanese), digits, space, '.', '_', '-'; max 20 characters.
    [ValidatePattern('^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$')]
    [string]$UserName = 'User',
    [string]$UserPassword = '',
    [int]$KeepLogs = 10,
    [string]$InjectDrivers,
    [switch]$KeepBasicApps,
    [switch]$KeepSearchIndex,
    [switch]$IncludeMigrationAssistant,
    [switch]$IncludeMigrationBackup,
    [string]$ComparePreset,

    # 1. Windows Defender
    # NOTE: "-NoDefender" used to be an alias of "-RemoveDefender", i.e. it meant
    # "remove Defender" while every other "-NoXXX" switch in this script means
    # "keep XXX" (e.g. -NoIME keeps the IME, -RemoveIME removes it). That inversion
    # was a footgun, so "-NoDefender" now means "keep Defender" and is handled as
    # the inverse of "-RemoveDefender" by the switch-resolution block below.
    [switch]$KeepDefender,
    [switch]$NoDefender,
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

    # 14b. Preinstalled AppX bloatware (the inbox apps of the image)
    [switch]$KeepAppxBloatware,
    [alias("NoAppxBloatware")]
    [switch]$RemoveAppxBloatware,
    [switch]$RemoveCameraApp,
    [switch]$RemovePhotosApp,
    [switch]$RemoveScreenSketchApp,

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
    [alias("NoActivationRestrictions", "UnlockPersonalization")]
    [switch]$BypassActivationRestrictions,
    [alias("UltraLowRAM", "LowRAM")]
    [switch]$RadicalRAM,

    # 22. Settings that were applied by the phases but had no CLI switch of their own.
    # Each of these used to be referenced from a phase through Test-TweakEnabled with a
    # hard-coded default, which meant the phase branch was permanently on (or permanently
    # off) and the user could not influence it. They are proper switches now.
    [switch]$ConfigureWinlogon,
    [switch]$EnableScripts,
    [switch]$DisableWindowsAI,
    [switch]$DisableDeliveryOptimization,
    [switch]$DisablePowerThrottling,
    [switch]$EnableHAGS,
    [switch]$NtfsDisable8dot3,
    [switch]$ThreadDpcEnable,
    [switch]$NetworkTuning,
    [switch]$DisableIdleMaintenance,
    [switch]$SvcHostConsolidation,
    [switch]$DisableSearchWebView2,
    [switch]$HideSearchBox,
    [switch]$MenuShowDelayZero,
    [switch]$DisableSnapAssist,
    [switch]$DisableNotificationBanners,
    [switch]$HideExplorerHomeGallery,
    [switch]$HideAltTabEdgeTabs,
    [switch]$HideTaskViewButton,
    [switch]$TaskbarNeverCombine,
    [switch]$DisableGameMode,
    [switch]$ShowBatteryPercentage,
    [switch]$AlwaysShowScrollbars,
    [switch]$DisableLogonBlur,
    [switch]$HideOneDriveNavPane,
    [switch]$DisableAccessibilityHotkeys,
    [switch]$DisableMouseAcceleration,
    [switch]$DisableKeyboardDelay,
    # Removal options (polarity: OFF = keep, ON = remove). These used to run
    # unconditionally on every build.
    [switch]$RemoveHelpFiles,
    [switch]$RemoveEdge,
    [switch]$RemoveWindowsBackup,
    [switch]$RemoveWebExperienceHost,
    [switch]$RemoveOfflineCacheFiles,
    [switch]$RemoveRecall,
    [switch]$RemoveInternetExplorer,
    [switch]$RemoveWordPad,
    [switch]$RemoveStepsRecorder,
    [switch]$RemoveSnippingTool,
    [switch]$RemovePaint,
    [switch]$RemoveXpsViewer,
    [switch]$RemovePowerShellISE,
    [switch]$RemoveOpenSSHClient,
    [switch]$RemoveHelloFace,
    [switch]$RemoveBitLockerFeature,
    [switch]$RemoveNarratorApp,
    [switch]$RemoveMagnifierApp,
    [switch]$RemoveMediaPlayerFeature,
    [switch]$RemoveTabletPCMath,
    [switch]$RemoveWebcamExperience,
    [switch]$RemoveWallpaperContent,
    [switch]$RemoveSearchEngineClient,
    [switch]$RemovePrintingManagement,
    [switch]$RemoveMpeg2Decoder,
    [switch]$RemoveWmic,
    [switch]$RemoveWirelessDisplay,
    [switch]$RemoveSnmpClient,
    [switch]$RemoveTelnetClient,
    [switch]$RemoveSimpleTcpClient,
    [switch]$RemoveRdc,
    [switch]$RemoveFaxClient,
    [switch]$RemoveUserExperienceVirt,
    [switch]$RemoveDeviceManagementEnt,
    [switch]$RemoveNotepad,
    [switch]$RemoveMathRecognizer,
    [switch]$RemovePrintingWfs,
    [switch]$RemoveKernelLA57,
    [switch]$RemoveTpmWmiProvider,
    # Language packs (OFF = protected, ON = may be removed)
    [switch]$RemoveLanguageJaJP,
    [switch]$RemoveLanguageKoKR,
    [switch]$RemoveLanguageZhCN,
    [switch]$RemoveLanguageZhTW,
    # Post-install (first logon) options
    [switch]$EnableCompactOS,
    [switch]$EnableNtfs8dot3Disable,
    [switch]$EnableUltimatePerformancePower,
    [switch]$EnableMsiMode,
    [switch]$DisableAccessibilityTools,
    [switch]$DisableWindowsSearchProcess,
    [switch]$DisableComputerRestore,
    [switch]$NoRadicalRAM,
    # Hashtable (@{ GPULatency = $false }) or string "GPULatency=0;TimerBCD=1" (the string form survives
    # being passed through powershell.exe -File, e.g. on elevation or in batch queue mode)
    [object]$TweakGroupOverrides,

    # 22. Granular Security & Bypass Toggles
    [switch]$BypassHardwareRequirements,
    [switch]$BypassNetworkRequirement,
    [switch]$BypassNRO,
    [switch]$DisableUAC,
    [switch]$DisableSmartScreen,
    [switch]$DisableVBS,
    [switch]$DisableWPBT,
    [switch]$HardenSystemSecurity,
    [switch]$PreventDeviceEncryption,

    # 23. Granular Privacy & AI Toggles
    [switch]$DisableCopilot,
    [switch]$DisableWebSearch,
    [switch]$DisableWidgets,
    [switch]$DisableCrossDevice,
    [switch]$DisableAdvertisingId,
    [switch]$DisableErrorReporting,
    [switch]$DisableIMETelemetry,
    [switch]$DisableCloudContent,
    [switch]$DisableAppPrivacy,
    [switch]$DisableTelemetryAndDiagnostics,
    [switch]$DisableDefenderSecurityCenter,
    [switch]$DisableCortana,
    [switch]$DisableActivityHistory,
    [switch]$DisableTimeline,
    [switch]$DisableDiagnosticData,

    # 24. Granular Performance Toggles
    [switch]$DisableFTH,
    [switch]$DisablePCA,
    [switch]$TuneMemoryAndPaging,
    [switch]$GamingNetworkTweaks,
    [switch]$LowLatencyAudioMMCSS,
    [switch]$DisableBackgroundApps,
    [switch]$DisableGameDVR,
    [switch]$DisableSuperfetch,
    [switch]$DisableWindowsSearchIndexing,
    [switch]$DisableFastStartup,

    # 25. Granular UI & Shell Toggles
    [switch]$EnableClassicContextMenu,
    [switch]$EnableDarkTheme,
    [switch]$ShowFileExtensions,
    [switch]$ShowHiddenFiles,
    [switch]$LaunchToThisPC,
    [switch]$TaskbarEndTask,
    [switch]$TaskbarAlignLeft,
    [switch]$HideMeetNow,
    [switch]$HideSyncNotifications,
    [switch]$HideRecommendedSection,
    [switch]$DisableStartupSound,
    [switch]$DisableLockScreen,
    [switch]$DisableSleepOption,
    [switch]$DisableBSODEmoticon,
    [switch]$EnableLongPaths,
    [switch]$TransparentShortcutOverlay,
    [switch]$PhotoViewerAssociations,
    [switch]$TakeOwnershipContextMenu,
    [switch]$CmdAsAdminContextMenu,
    [switch]$OptimizeVisualEffects,
    [switch]$CleanContextMenus,

    # 26. Template acquisition safety (P1-01)
    [switch]$AllowTemplateDownload,

    # 27. Granular Tweak Settings Object / Hashtable
    [object]$TweakSettings
)

# G7 regression fix: dot-source the extracted helper module BEFORE any top-level
# statement that calls a helper. The leftover-hive cleanup further below calls
# Unmount-RegistryHiveWithRetry, which only exists after this dot-source runs.
# The helper module contains only pure functions and the BuildContext class
# (no top-level state), so loading it this early is safe.
$scriptDirEarly = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# The moment this builder was started. The rotation of the build_diagnostics folders
# uses it to tell the diagnostic directory of a build that is still running from an
# abandoned one: a build that starts while another one is still running must not
# delete the diagnostic directory of that other build.
$script:BuilderStartTime = Get-Date
$helperModuleEarly = Join-Path -Path $scriptDirEarly -ChildPath "WinEasehelpers.ps1"
if (Test-Path -LiteralPath $helperModuleEarly) {
    . $helperModuleEarly
} else {
    throw "Required helper module not found: $helperModuleEarly"
}
# M2: dot-source the extension module early (functions needed before AllTweakDefs init); the PC migration engine lives in tools\migrator and is not part of the ISO build
$extModuleEarly = Join-Path -Path $scriptDirEarly -ChildPath "lib\WinEaseExtensions.ps1"
if (Test-Path -LiteralPath $extModuleEarly) { . $extModuleEarly }
# Plugin host (lib\WinEasePlugins.ps1): loads the allow-listed plugin DLLs and calls them around the phases.
$pluginModuleEarly = Join-Path -Path $scriptDirEarly -ChildPath "lib\WinEasePlugins.ps1"
if (Test-Path -LiteralPath $pluginModuleEarly) { . $pluginModuleEarly }
# The Advanced Debloat engine table and the safe per-target handlers (lib\WinEaseDebloat.ps1).
# The phases call these, so the module has to be loaded before the first phase runs.
$debloatModuleEarly = Join-Path -Path $scriptDirEarly -ChildPath "lib\WinEaseDebloat.ps1"
if (Test-Path -LiteralPath $debloatModuleEarly) {
    . $debloatModuleEarly
} else {
    throw "Required debloat module not found: $debloatModuleEarly"
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

# Serialize a bound parameter as PowerShell syntax for re-invocation via New-WinEaseChildArguments.
# (powershell.exe -File cannot pass -Switch:$false, so child processes are started with -EncodedCommand.)
function ConvertTo-WinEaseCliArgument {
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
function New-WinEaseChildArguments {
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

# Unified WinEase Version
$script:WinEaseVersion = "2.1"

# Ensure UTF-8 Console and Output encoding to prevent mojibake in Windows terminals
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

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

# P1-01: Template download opt-in gate for Phase 11 (11-unattend.ps1)
$script:AllowTemplateDownload = [bool]$AllowTemplateDownload

# E1: Physical debloat opt-in gate for Phase 9.5 (09-physical-debloat.ps1). Set from the CLI
# switch here; an interactive GUI session can additionally grant it via a consent dialog.
$script:allowPhysicalDebloat = [bool]$AllowPhysicalDebloat

# Check and adjust Execution Policy (Skip if in TestSelf or DryRun mode to remain 100% non-destructive)
if ((-not $TestSelf) -and ($env:WINEASE_TEST_MODE -ne "1") -and (-not $isDryRunMode)) {
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
if ((-not $myWindowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) -and ($env:WINEASE_TEST_MODE -ne "1") -and (-not $TestSelf) -and (-not $isDryRunMode)) {
    Write-Host "Restarting script with Administrator privileges in a new window..." -ForegroundColor Yellow

    # Reconstruct bound parameters for elevated process.
    # S-M1: UserPassword is deliberately NOT serialized here. The argument list is
    # turned into a -EncodedCommand process argument (New-WinEaseChildArguments),
    # and Base64 is not encryption: any local process can read and decode another
    # process's command line. The elevated process therefore starts without the
    # password; if it is needed (e.g. ConfigureWinlogon), it must be supplied again
    # in the elevated session instead of being inherited through the command line.
    $paramList = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -eq 'UserPassword') {
            Write-Host "Note: -UserPassword is not forwarded to the elevated process (it would be readable in the process command line). Please supply it again in the elevated session if prompted." -ForegroundColor Yellow
            continue
        }
        $paramList.Add((ConvertTo-WinEaseCliArgument -Name $key -Value $PSBoundParameters[$key]))
    }

    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = New-WinEaseChildArguments -ScriptPath $myInvocation.MyCommand.Definition -ScriptArguments $paramList
    $newProcess.Verb = "runas"
    try {
        $null = [System.Diagnostics.Process]::Start($newProcess)
        exit 0
    } catch {
        Write-Host "Failed to elevate privileges: $_" -ForegroundColor Red
        exit 1
    }
}

# 2b. Concurrency Guard: Global Mutex to prevent simultaneous builds
$script:BuildMutex = $null
$script:HasMutex = $false
if ((-not $TestSelf) -and ($env:WINEASE_TEST_MODE -ne "1") -and (-not $isDryRunMode)) {
    try {
        $script:BuildMutex = New-Object System.Threading.Mutex($false, "Global\WinEaseBuilder")
        $script:HasMutex = $script:BuildMutex.WaitOne(0)
        if (-not $script:HasMutex) {
            Write-Host "Error: Another instance of WinEase builder is currently running (Global\WinEaseBuilder)." -ForegroundColor Red
            exit 1
        }
    } catch [System.Threading.AbandonedMutexException] {
        # The previous owner exited without releasing the mutex. Per .NET semantics
        # this exception means THIS thread now owns the mutex, so the build may
        # continue - but the previous run may have left mounts / workspace state
        # behind, so say so loudly instead of treating it as a plain failure.
        $script:HasMutex = $true
        Write-Host "Warning: The global build mutex was abandoned by a previous run; this process now owns it. Leftover mounts or workspace state from that run may exist." -ForegroundColor Yellow
    } catch {
        # C-H2 (fail-closed): this used to only warn and let the build continue
        # without any lock, so two builds could race on the same workspace and the
        # DISM mount registry. Acquisition failure now stops the build instead.
        Write-Host "Error: Could not acquire the global build mutex (Global\WinEaseBuilder): $_" -ForegroundColor Red
        Write-Host "Refusing to build without the concurrency lock. Close any other WinEase builder process and retry." -ForegroundColor Red
        if ($script:BuildMutex) {
            try { $script:BuildMutex.Dispose() } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            $script:BuildMutex = $null
        }
        exit 1
    }
}

# 2c. Validate conflicting / contradictory switch parameters
$conflicts = @(
    @('KeepDefender', 'RemoveDefender'),
    @('KeepDefender', 'NoDefender'),
    @('NoDefender', 'RemoveDefender'),
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

# Low-level DISM mount / offline hive, offline registry access (reg.exe wrapper, config\registry tables), WIM, telemetry and GUI-session helpers (function definitions only).
# WinEaseFileSystem.ps1 is loaded by WinEasehelpers.ps1 with the other split helper modules.
foreach ($WinEaseLibFile in @('WinEaseMount.ps1', 'WinEaseRegistry.ps1', 'WinEaseSecrets.ps1', 'WinEaseWim.ps1', 'WinEaseTelemetry.ps1', 'WinEaseGuiSession.ps1', 'WinEaseBuildPlan.ps1', 'WinEaseInputValidation.ps1')) {
    . (Join-Path -Path (Join-Path -Path $scriptDirEarly -ChildPath "lib") -ChildPath $WinEaseLibFile)
}

# 3. Clean up any leftover WinEase registry hives from previous runs (Non-destructive)
if ((-not $TestSelf) -and ($env:WINEASE_TEST_MODE -ne "1") -and (-not $isDryRunMode)) {
    @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | ForEach-Object {
        # Best-effort cleanup: never let a stale-hive unmount failure abort the build
        try { [void](Unmount-RegistryHiveWithRetry -Name $_) } catch { Write-Verbose "Leftover hive '$_' cleanup skipped: $_" }
    }
}

# Every tweak and component setting is defined once, in config\schema.psd1. The tables below
# are derived from it; add or rename a setting there, never here.
$script:WinEaseSettingsDefPath = Join-Path -Path $scriptDirEarly -ChildPath "config\schema.psd1"
if (-not (Test-Path -LiteralPath $script:WinEaseSettingsDefPath)) {
    throw "Settings definition file not found: $($script:WinEaseSettingsDefPath)"
}
$script:WinEaseSettingsDef = Import-PowerShellDataFile -LiteralPath $script:WinEaseSettingsDefPath

# Tweak settings shown on GUI tabs 2-5 (Key -> Category / Default / Description)
$script:AllTweakDefs = [ordered]@{}
# Legacy tweak key names (older profiles, -TweakSettings hashtables) -> current AllTweakDefs key
$script:TweakKeyAliases = [ordered]@{}
# Tweak keys that phases consume through a script variable instead of Test-TweakEnabled
$script:TweakVariableMap = [ordered]@{}
foreach ($td in $script:WinEaseSettingsDef.Tweaks) {
    $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description }
    foreach ($alias in @($td.Aliases)) { if ($alias) { $script:TweakKeyAliases[$alias] = $td.Key } }
    if ($td.Variable) { $script:TweakVariableMap[$td.Key] = $td.Variable }
}

# M2: Import user-defined tweaks/presets/custom scripts (in-place, preserves single-assignment contract)
try {
    $script:UserExtensionsResult = Import-WinEaseUserExtensions
} catch {
    Write-Warning "User extensions import failed: $($_.Exception.Message)"
    $script:UserExtensionsResult = [PSCustomObject]@{ Loaded = $false; UserTweakCount = 0; UserPresetCount = 0; CustomScriptCount = 0; Errors = @($_.Exception.Message) }
}

# R7: plugins (DLLs listed with their SHA256 in plugins\builtin\builtin.lock.psd1 / config\user\plugins.lock.psd1).
# A plugin that cannot be loaded is reported and skipped; it never stops the build.
$script:PluginImportResult = $null
if (Get-Command -Name Import-WinEasePlugins -ErrorAction SilentlyContinue) {
    if (-not $TestSelf) {
        try {
            $script:PluginImportResult = Import-WinEasePlugins -RepoRoot $scriptDirEarly
        } catch {
            Write-Warning "Plugin import failed: $($_.Exception.Message)"
        }
    }
}

# Component settings (Key -> Variable / Type / Default / Gui), in profile key order
$script:ComponentDefs = [ordered]@{}
foreach ($cd in $script:WinEaseSettingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }

# Execution engine of every Advanced Debloat target (item text -> Engines / Default / RustKey / Phase).
# config\schema.psd1 is the single source of truth; the GUI, the profile format, the
# lib\WinEaseDebloat.ps1 helpers and phases\09-physical-debloat.ps1 all read this table.
$script:WinEaseDebloatEngines = [ordered]@{}
$script:WinEaseDebloatLegacyMap = [ordered]@{}
foreach ($de in @($script:WinEaseSettingsDef.DebloatEngines)) {
    if (-not $de -or -not $de.Item) { continue }
    $script:WinEaseDebloatEngines[[string]$de.Item] = $de
    foreach ($legacyItem in @($de.Legacy)) {
        if ($legacyItem) { $script:WinEaseDebloatLegacyMap[[string]$legacyItem] = [string]$de.Item }
    }
}

# The engine the user picked for a target (item text -> 'PowerShell' | 'Rust'). A target
# that is not listed here runs on the engine registered in config\schema.psd1.
$script:DebloatEngineSelection = [ordered]@{}

# The explicit settings of the user (command line, JSON profile, GUI). They are the
# highest layer of the configuration: a preset never overrules them.
$script:ConfigOverrides = [ordered]@{}
$script:TweakOverrides  = [ordered]@{}

$script:TweakSettings = [ordered]@{}
foreach ($tk in $script:AllTweakDefs.Keys) {
    $script:TweakSettings[$tk] = [bool]$script:AllTweakDefs[$tk].Default
}

function Resolve-WinEaseTweakKey {
    param([string]$Name)
    if ($null -ne $script:TweakKeyAliases -and $script:TweakKeyAliases.Contains($Name)) { return $script:TweakKeyAliases[$Name] }
    return $Name
}

# Copy TweakSettings values onto the script variables listed in $script:TweakVariableMap
function Sync-WinEaseTweakVariables {
    foreach ($tk in $script:TweakVariableMap.Keys) {
        if ($script:TweakSettings.Contains($tk)) {
            Set-Variable -Name $script:TweakVariableMap[$tk] -Scope Script -Value ([bool]$script:TweakSettings[$tk])
        }
    }
}

# Helper function to evaluate individual toggle settings.
# This is the single canonical definition of the helper. It has to live here, in the
# builder's script scope, and not in one of the phases: phases 05, 06 and 08 and
# lib\WinEaseDebloat.ps1 call it, but phase 10 (which carries a guarded fallback copy)
# runs long after them - a helper that is only defined in phase 10 is therefore not
# resolvable when phase 05 asks for it.
# Phases 10 and 11 keep their own guarded copy so that they still work when they are
# dot-sourced on their own; during a normal build the guard keeps them from
# redefining this one.
function Test-TweakEnabled {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [bool]$Default = $true
    )
    if ($null -ne $script:TweakSettings -and $script:TweakSettings.Contains($Name)) {
        return [bool]$script:TweakSettings[$Name]
    }
    # Legacy key names (older profiles / -TweakSettings hashtables) that map onto this GUI key
    if ($null -ne $script:TweakSettings -and $script:TweakKeyAliases) {
        foreach ($alias in $script:TweakKeyAliases.Keys) {
            if ($script:TweakKeyAliases[$alias] -eq $Name -and $script:TweakSettings.Contains($alias)) {
                return [bool]$script:TweakSettings[$alias]
            }
        }
    }
    $varName = "Tweak_$Name"
    $v = Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $v) { return [bool]$v.Value }
    return $Default
}

# Profile key order: component settings first, then every tweak key (-SaveProfile writes these,
# -LoadProfile accepts them). The debloat engine selection is not a component, it is added here.
$script:WinEaseProfileKeys = @($script:ComponentDefs.Keys) + @($script:AllTweakDefs.Keys) + @('DebloatEngineSelection')

# Read a component's script variable typed as its definition says (Bool -> [bool], String -> [string])
function Get-WinEaseComponentValue {
    param([Parameter(Mandatory = $true)][hashtable]$Def)
    $val = Get-Variable -Name $Def.Variable -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($Def.Type -eq 'String') { return "$val" }
    return [bool]$val
}

# Helper function: Snapshot the currently resolved build settings (script scope) as a profile hashtable
function Get-WinEaseCurrentConfig {
    param([string]$ProfileName = "Exported Profile")
    $tweakGroups = [ordered]@{}
    foreach ($k in $script:activeTweakGroups.Keys) { $tweakGroups[$k] = [bool]$script:activeTweakGroups[$k] }
    $config = @{ ProfileName = $ProfileName }
    foreach ($cd in $script:ComponentDefs.Values) {
        # Secret components (UserPassword) are never part of a saved profile
        if ($cd.Type -ne 'Special' -and -not $cd.Secret) { $config[$cd.Key] = Get-WinEaseComponentValue -Def $cd }
    }
    $engineSel = [ordered]@{}
    foreach ($k in $script:DebloatEngineSelection.Keys) { $engineSel[$k] = [string]$script:DebloatEngineSelection[$k] }
    $config += @{
        TweakGroups                  = $tweakGroups
        PayloadFormat                = if ($script:exportESDMode) { "ESD" } elseif ($script:splitWIMMode) { "SWM" } else { "WIM" }
        AdvancedDebloatStandard      = @($script:advancedDebloatStandard)
        AdvancedDebloatExperimental  = @($script:advancedDebloatExperimental)
        DebloatEngineSelection       = $engineSel
        TweakSettings                = $script:TweakSettings
    }
    return $config
}

# Helper function: Export configuration settings to a JSON profile
function Export-WinEaseProfile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [hashtable]$Config
    )
    if ($null -eq $Config) { $Config = @{} }
    $parentDir = Split-Path -Parent $FilePath
    if ($parentDir -and (-not (Test-Path -LiteralPath $parentDir))) {
        $null = New-Item -ItemType Directory -Force -Path $parentDir
    }
    # Settings are written in the same key order as $script:WinEaseProfileKeys so a saved profile
    # round-trips through -LoadProfile without losing any option.
    $settings = [ordered]@{}
    # Secret components (UserPassword) are never written to disk, even if a caller passes them in:
    # a profile is meant to be shared and committed. Pass -UserPassword on the command line instead.
    $secretKeys = @($script:ComponentDefs.Values | Where-Object { $_.Secret } | ForEach-Object { $_.Key })
    foreach ($k in $script:WinEaseProfileKeys) {
        if ($secretKeys -contains $k) { continue }
        if ($Config.ContainsKey($k)) { $settings[$k] = $Config[$k] }
    }
    $profileData = [ordered]@{
        ProfileName = if ($Config.ProfileName) { $Config.ProfileName } else { "WinEase Configuration Profile" }
        Version     = $script:WinEaseVersion
        Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Settings    = $settings
    }
    $json = $profileData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($FilePath, $json, [System.Text.Encoding]::UTF8)
    Write-Host "Profile saved to: $FilePath" -ForegroundColor Green
}

# Phase Progress & Telemetry Tracking
$script:CurrentPhase = [double]0
$script:TotalPhases = 18
$script:PhaseTimings = [ordered]@{}
$script:PhaseStopwatch = $null

function Enter-Phase {
    param(
        # C-H4: [double], not [int] - Phase 9.5 exists, and an [int] parameter silently
        # rounded it to a neighbouring integer, which collided with Phase 10 in the
        # timing keys and in the checkpoint's CompletedPhase. All phase-number
        # representations (this parameter, $script:CurrentPhase, timing keys,
        # CompletedPhase, the failure record) are [double] now.
        [double]$PhaseNumber,
        [string]$PhaseName
    )
    # F2: persist a checkpoint for the phase that just completed (foundation for -ResumeFromPhase)
    if ($script:CurrentPhase -gt 0 -and -not $script:ResumeMode -and $script:BaseWorkDir) {
        Save-WinEaseCheckpoint -CompletedPhase $script:CurrentPhase
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
    $phaseTitle = "WinEase [$PhaseNumber/$($script:TotalPhases)] $PhaseName"
    if ($null -ne $host.UI.RawUI) {
        try { $host.UI.RawUI.WindowTitle = $phaseTitle } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    if (Get-Command -Name Send-WinEaseGuiProgress -ErrorAction SilentlyContinue) {
        $progress = @{ Phase = $PhaseNumber; Total = $script:TotalPhases; Name = $PhaseName }
        if (-not $script:ProgressEstimateSent) {
            try {
                $est = Get-WinEaseLastRunTotalSeconds -TimingsPath (Join-Path -Path $logDir -ChildPath 'last_phase_timings.json')
                if ($est -gt 0) { $progress.EstimatedSeconds = $est }
            } catch { Write-Verbose "No previous phase timings: $($_.Exception.Message)" }
            $script:ProgressEstimateSent = $true
        }
        Send-WinEaseGuiProgress -Event phase -Data $progress
        # Phase 15 is the payload verification; everything else is plain running
        Send-WinEaseGuiState -State $(if ($PhaseNumber -eq 15) { 'Verifying' } else { 'Running' })
        Send-WinEaseGuiLogLine -Text "[$PhaseNumber/$($script:TotalPhases)] $PhaseName"
    }
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host " [$PhaseNumber/$($script:TotalPhases)] $PhaseName" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
}

# Records a build failure once: exception and phase go to <diagnostics>\build_errors.log (secrets masked),
# the failure data is kept for the final 'done' event, and an open window gets the 'failure' event at once.
# A failure that cannot be recorded is reported as a warning, never swallowed silently.
function Register-WinEaseBuildFailure {
    param([Parameter(Mandatory)]$ErrorRecord)
    if ($script:BuildFailureData) { return }
    $phaseNumber = [double]$script:CurrentPhase
    $phaseLabel = if ($script:CurrentBuildPhase) { [string]$script:CurrentBuildPhase } else { 'Preparing' }
    $diagDir = if ($script:DiagDir) { [string]$script:DiagDir } else { '' }
    $errorLog = if ($diagDir) { Join-Path -Path $diagDir -ChildPath 'build_errors.log' } else { '' }
    $summary = Get-WinEaseExceptionSummary -ErrorRecord $ErrorRecord
    if ($errorLog) {
        try {
            if (-not (Test-Path -LiteralPath $diagDir)) { $null = New-Item -ItemType Directory -Path $diagDir -Force }
            $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
            $stack = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { "$($ErrorRecord.ScriptStackTrace)" } else { '' }
            $entry = @(
                "=== Build failure $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===",
                "Phase:     $phaseLabel",
                "Exception: $($ex.GetType().FullName)",
                "Message:   $(Hide-WinEaseSecretText -Text ([string]$ex.Message))",
                "Stack:",
                (Hide-WinEaseSecretText -Text $stack),
                ''
            ) -join "`r`n"
            [System.IO.File]::AppendAllText($errorLog, $entry, [System.Text.Encoding]::UTF8)
        } catch {
            Write-Warning "Could not write the build error log '$errorLog': $($_.Exception.Message)"
        }
    }
    $logPath = if ($transcriptPath) { [string]$transcriptPath } else { $errorLog }
    $summaryFile = if ($diagDir) { Join-Path -Path $diagDir -ChildPath 'build_diagnostic_summary.txt' } else { '' }
    $script:BuildFailureData = New-WinEaseFailureData -ErrorRecord $ErrorRecord -FailedPhase $phaseLabel -FailedPhaseNumber $phaseNumber `
        -LogPath $logPath -ReportPath $summaryFile -OutputPath ([string]$script:BuildOutputIsoPath) -DiagnosticsPath $diagDir `
        -DocsPath (Join-Path -Path $scriptDir -ChildPath 'docs\KNOWN_ISSUES.md')
    if (Get-Command -Name Send-WinEaseGuiProgress -ErrorAction SilentlyContinue) {
        Send-WinEaseGuiProgress -Event failure -Data $script:BuildFailureData
        Send-WinEaseGuiLogLine -Text "FAILED in ${phaseLabel}: $summary"
    }
}

function Exit-Phase {
    if ($script:PhaseStopwatch) {
        $script:PhaseStopwatch.Stop()
        $prevPhaseKey = "Phase $($script:CurrentPhase)"
        $script:PhaseTimings[$prevPhaseKey] = [math]::Round($script:PhaseStopwatch.Elapsed.TotalSeconds, 1)
        $script:PhaseStopwatch = $null
    }
}

function Save-WinEasePhaseTimings {
    # G5/F3: persist per-phase durations for the next run's build-time estimate.
    # The final phase needs an explicit Exit-Phase close-out (no later Enter-Phase will
    # record it), so this writer runs both mid-Phase-18 and after the phase completes.
    try {
        $timingsPath = Join-Path -Path $logDir -ChildPath "last_phase_timings.json"
        if ($script:PhaseTimings -and $script:PhaseTimings.Count -gt 0) {
            $script:PhaseTimings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $timingsPath -Encoding utf8 -Force
        }
    } catch {
        Write-Warning "Could not persist phase timings: $_"
    }
}

function Get-WinEaseLastRunTotalSeconds {
    # G5: total wall-clock seconds of the previous run's phases (build-time estimate input).
    # PS 5.1's ConvertFrom-Json yields System.Decimal for JSON decimals, so the numeric check
    # must accept decimal as well as double/int/long - without it every fractional duration
    # was silently skipped and the estimate always displayed "~0 min" (verified: a table
    # summing to ~840 s evaluated as 1 s).
    param([string]$TimingsPath)
    $lastTimings = (Get-Content -LiteralPath $TimingsPath -Raw -ErrorAction Stop) | ConvertFrom-Json
    $totalSec = 0
    foreach ($v in $lastTimings.PSObject.Properties.Value) {
        if ($v -is [double] -or $v -is [decimal] -or $v -is [int] -or $v -is [long]) { $totalSec += [double]$v }
    }
    return $totalSec
}

# ==============================================================================
# Modular Tweak Architecture & In-Memory Built-in Presets
# ==============================================================================

$script:TweakGroups = [ordered]@{
    NetworkStack   = @{ Default = $true;  Risk = '**';   Description = 'TcpAck/RSC/ECN/NetThrottling tuning' }
    TimerBCD       = @{ Default = $true;  Risk = '**';   Description = 'dynamic tick/TSC sync/platform clock' }
    GPULatency     = @{ Default = $true;  Risk = '*';    Description = 'MSI mode/HAGS/GPU scheduling registry' }
    ServiceTrim    = @{ Default = $true;  Risk = '**';   Description = 'WSearch/SysMain/DiagTrack/Ndu service trimming' }
    # NOTE: the former "VisualFX" and "CpuMitigations" groups were dead definitions - no phase
    # read them. Their work is covered by the OptimizeVisualEffects tweak and the
    # DisableCPUMitigations tweak respectively, so the groups were removed instead of being
    # wired up to a second, parallel switch.
}

$script:activeTweakGroups = [ordered]@{}
foreach ($tgKey in $script:TweakGroups.Keys) {
    $script:activeTweakGroups[$tgKey] = [bool]$script:TweakGroups[$tgKey].Default
}

# The built-in presets live in config\presets.psd1 - the single source of truth for them.
# A preset is only the list of the individual options it switches on; it never forces a
# value on its own (Resolve-WinEaseConfiguration applies the user settings on top).
$script:BuiltInPresetsPath = Join-Path -Path $scriptDirEarly -ChildPath "config\presets.psd1"
if (-not (Test-Path -LiteralPath $script:BuiltInPresetsPath)) {
    throw "Required preset file not found: $script:BuiltInPresetsPath"
}
$presetFile = Import-PowerShellDataFile -LiteralPath $script:BuiltInPresetsPath
$script:BuiltInPresets = [ordered]@{}
foreach ($presetKey in @($presetFile.PresetOrder)) {
    if ($presetFile.Presets.Contains($presetKey)) { $script:BuiltInPresets[$presetKey] = $presetFile.Presets[$presetKey] }
}
# a preset that is not in the order list is still valid (a user preset for example)
foreach ($presetKey in @($presetFile.Presets.Keys)) {
    if (-not $script:BuiltInPresets.Contains($presetKey)) { $script:BuiltInPresets[$presetKey] = $presetFile.Presets[$presetKey] }
}
# The descriptive names of the presets (config\presets.psd1 -> Aliases) plus the numbered
# shortcuts of the interactive menu.
$script:BuiltInPresetAliases = [ordered]@{
    '1' = 'extreme'
    '2' = 'balanced'
    '3' = 'fat32'
    '4' = 'handheld'
    '5' = 'vm'
    '6' = 'audio'
}
foreach ($aliasKey in @($presetFile.Aliases.Keys)) { $script:BuiltInPresetAliases[[string]$aliasKey] = [string]$presetFile.Aliases[$aliasKey] }

# M2: Load user presets now that BuiltInPresets is defined
try {
    if (Get-Command -Name Import-WinEaseUserExtensions -ErrorAction SilentlyContinue) {
        $null = Import-WinEaseUserExtensions -PresetsOnly
    }
} catch {
    Write-Verbose "Ignored: $($_.Exception.Message)"
}

function Get-WinEasePreset {
    param([string]$Name)
    if (-not $Name) { return $script:BuiltInPresets['extreme'] }
    $clean = $Name.Trim().ToLower()
    # The descriptive names and the numbered shortcuts come from config\presets.psd1.
    $aliasMap = $script:BuiltInPresetAliases
    $targetKey = if ($aliasMap.Contains($clean)) { $aliasMap[$clean] } else { $clean }
    if ($script:BuiltInPresets.Contains($targetKey)) {
        return $script:BuiltInPresets[$targetKey]
    }
    return $null
}

function Get-WinEaseProfileValue {
    param(
        $TargetPreset,
        [string]$Key,
        $DefaultValue = $false
    )
    if ($TargetPreset -is [System.Collections.IDictionary]) {
        if ($TargetPreset.Contains($Key)) { return $TargetPreset[$Key] }
    } elseif ($TargetPreset -and $TargetPreset.PSObject.Properties[$Key]) {
        return $TargetPreset.$Key
    }
    return $DefaultValue
}

function Apply-WinEaseProfileComponents {
    param(
        $TargetPreset,
        [bool]$SourceIsProfile
    )
    # The effective configuration is resolved in one place (Resolve-WinEaseConfiguration):
    # the base defaults, then the preset, then the explicit settings of the user. An
    # individual setting always wins, so a preset never overrules it.
    $baseComponents = [ordered]@{}
    $presetComponents = [ordered]@{}
    $overrideComponents = [ordered]@{}
    foreach ($cd in $script:ComponentDefs.Values) {
        # Components without a Default (SourceDrive, SkipEiCfg, ...) are not applied from a profile
        if ($cd.Type -eq 'Special' -or -not $cd.ContainsKey('Default')) { continue }
        $baseComponents[$cd.Key] = if ($cd.Type -eq 'String') { [string]$cd.Default } else { [bool]$cd.Default }
        $raw = Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key $cd.Key -DefaultValue $null
        if ($null -eq $raw) { continue }
        if ($SourceIsProfile) { $overrideComponents[$cd.Key] = $raw } else { $presetComponents[$cd.Key] = $raw }
    }
    # the explicit settings of the user (command line) win over everything
    foreach ($k in $script:ConfigOverrides.Keys) { $overrideComponents[$k] = $script:ConfigOverrides[$k] }
    $resolvedComponents = Resolve-WinEaseConfiguration -Base $baseComponents -Preset $presetComponents -Overrides $overrideComponents
    foreach ($k in $resolvedComponents.Components.Keys) {
        $cd = $script:ComponentDefs[$k]
        $val = if ($cd.Type -eq 'String') { "$($resolvedComponents.Components[$k])" } else { [bool]$resolvedComponents.Components[$k] }
        Set-Variable -Name $cd.Variable -Scope Script -Value $val
    }
}

function Apply-WinEaseProfileDebloat {
    param($TargetPreset)

    $advStd = Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key 'AdvancedDebloatStandard' -DefaultValue $null
    if ($advStd) { $script:advancedDebloatStandard = @($advStd) } else { $script:advancedDebloatStandard = @() }
    $advExp = Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key 'AdvancedDebloatExperimental' -DefaultValue $null
    if ($advExp) { $script:advancedDebloatExperimental = @($advExp) } else { $script:advancedDebloatExperimental = @() }

    # Older profiles still contain the "Physical: <target>" entries that were merged into
    # the standard list. They are mapped onto the canonical target and keep the Rust engine.
    $legacyEngines = [ordered]@{}
    $normStd = @()
    foreach ($raw in @($script:advancedDebloatStandard)) {
        $item = ConvertTo-WinEaseDebloatTarget -Item ([string]$raw)
        if (-not $item) { continue }
        if ($item -ne [string]$raw) { $legacyEngines[$item] = 'Rust' }
        $normStd += $item
    }
    $normExp = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in @($script:advancedDebloatExperimental)) {
        $item = ConvertTo-WinEaseDebloatTarget -Item ([string]$raw)
        if (-not $item) { continue }
        if ($item -ne [string]$raw) { $legacyEngines[$item] = 'Rust' }
        $normExp.Add($item)
    }
    $script:advancedDebloatStandard     = @($normStd | Where-Object { $_ } | Select-Object -Unique)
    $script:advancedDebloatExperimental = @($normExp | Where-Object { $_ } | Select-Object -Unique)

    # Engine selection (PowerShell <-> Rust) per target
    $script:DebloatEngineSelection = [ordered]@{}
    $engineSel = Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key 'DebloatEngineSelection' -DefaultValue $null
    if ($engineSel) {
        $map = @{}
        if ($engineSel -is [System.Collections.IDictionary]) {
            foreach ($k in $engineSel.Keys) { $map[[string]$k] = [string]$engineSel[$k] }
        } else {
            foreach ($p in $engineSel.PSObject.Properties) { $map[[string]$p.Name] = [string]$p.Value }
        }
        Set-WinEaseDebloatEngineSelection -Selection $map
    }
    # A merged legacy entry always keeps the Rust engine, unless the profile picked one
    foreach ($k in $legacyEngines.Keys) {
        if (-not $script:DebloatEngineSelection.Contains($k)) { $script:DebloatEngineSelection[$k] = $legacyEngines[$k] }
    }
}

function Apply-WinEaseProfileTweakGroupsAndFormat {
    param($TargetPreset)

    # Modular Tweak Groups
    $tGroups = Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key 'TweakGroups' -DefaultValue $null
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

    $fmt = (Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key 'PayloadFormat' -DefaultValue 'WIM').ToString().ToUpper()
    if ($fmt -eq 'ESD') { $script:exportESDMode = $true; $script:splitWIMMode = $false }
    elseif ($fmt -eq 'SWM') { $script:splitWIMMode = $true; $script:exportESDMode = $false }
    else { $script:exportESDMode = $false; $script:splitWIMMode = $false }
}

function Apply-WinEaseProfileTweaks {
    param(
        $TargetPreset,
        [bool]$SourceIsProfile
    )

    # The individual tweaks follow the same three layers as the components.
    $tweakBase = [ordered]@{}
    $tweakPreset = [ordered]@{}
    $tweakOverride = [ordered]@{}
    foreach ($tk in $script:AllTweakDefs.Keys) {
        $tweakBase[$tk] = [bool]$script:AllTweakDefs[$tk].Default
    }
    $tweakOverrides = Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key 'TweakSettings' -DefaultValue $null
    if ($tweakOverrides) {
        if ($tweakOverrides -is [System.Collections.IDictionary]) {
            foreach ($k in $tweakOverrides.Keys) {
                $rk = Resolve-WinEaseTweakKey $k
                if ($script:AllTweakDefs.Contains($rk)) {
                    if ($SourceIsProfile) { $tweakOverride[$rk] = [bool]$tweakOverrides[$k] } else { $tweakPreset[$rk] = [bool]$tweakOverrides[$k] }
                }
            }
        } elseif ($tweakOverrides.PSObject) {
            foreach ($prop in $tweakOverrides.PSObject.Properties) {
                $rk = Resolve-WinEaseTweakKey $prop.Name
                if ($script:AllTweakDefs.Contains($rk)) {
                    if ($SourceIsProfile) { $tweakOverride[$rk] = [bool]$prop.Value } else { $tweakPreset[$rk] = [bool]$prop.Value }
                }
            }
        }
    }
    foreach ($k in $script:AllTweakDefs.Keys) {
        $val = Get-WinEaseProfileValue -TargetPreset $TargetPreset -Key $k -DefaultValue $null
        if ($null -ne $val) {
            $tweakOverride[$k] = [bool]$val
        }
    }
    # The resolved tweaks are written back into $script:TweakSettings and onto the
    # script variables: without this the layers are only collected and a preset or a
    # profile never reaches the build.
    $resolvedTweaks = Resolve-WinEaseConfiguration -TweakBase $tweakBase -TweakPreset $tweakPreset -TweakOverrides $tweakOverride
    foreach ($k in $resolvedTweaks.Tweaks.Keys) { $script:TweakSettings[$k] = [bool]$resolvedTweaks.Tweaks[$k] }
    Sync-WinEaseTweakVariables
}

# Helper function: Unified profile settings application
function Apply-ProfileSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName,
        [Parameter(Mandatory = $false)]
        [psobject]$ProfileObject
    )

    $targetPreset = $null
    if ($ProfileName) {
        $targetPreset = Get-WinEasePreset -Name $ProfileName
        # Unknown name: apply nothing and return $null so the caller can warn and choose a fallback
        if (-not $targetPreset) { return $null }
    } elseif ($ProfileObject) {
        $targetPreset = if ($ProfileObject.Settings) { $ProfileObject.Settings } else { $ProfileObject }
    }

    if (-not $targetPreset) {
        $targetPreset = $script:BuiltInPresets['extreme']
    }

    $sourceIsProfile = [bool]$ProfileObject

    Apply-WinEaseProfileComponents -TargetPreset $targetPreset -SourceIsProfile $sourceIsProfile
    Apply-WinEaseProfileDebloat -TargetPreset $targetPreset
    Apply-WinEaseProfileTweakGroupsAndFormat -TargetPreset $targetPreset
    Apply-WinEaseProfileTweaks -TargetPreset $targetPreset -SourceIsProfile $sourceIsProfile

    return $targetPreset
}

# Helper function: Import configuration settings from a JSON profile
function Import-WinEaseProfile {
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
        if ($data.Version -and $data.Version -ne "2.0" -and $data.Version -ne "2.1" -and $data.Version -ne $script:WinEaseVersion) {
            Write-Warning "Profile version ($($data.Version)) differs from current ($script:WinEaseVersion)."
        }
        $settings = if ($data.Settings) { $data.Settings } else { $data }
        # ProfileName lives at the top level of exported files; carry it along with the settings
        if ($data.ProfileName -and -not $settings.PSObject.Properties['ProfileName']) {
            $settings | Add-Member -MemberType NoteProperty -Name ProfileName -Value $data.ProfileName
        }

        # Profile Schema Linter & Unknown Key Typo Detection
        $knownKeys = @($script:WinEaseProfileKeys) + @('ProfileName', 'Description', 'Version', 'Timestamp', 'Architecture')
        $unknownKeys = @()
        foreach ($prop in $settings.PSObject.Properties) {
            if ($knownKeys -notcontains $prop.Name) {
                $unknownKeys += $prop.Name
            }
        }
        if ($unknownKeys.Count -gt 0) {
            Write-Warning "Profile '$([System.IO.Path]::GetFileName($FilePath))' contains unrecognized setting(s): $($unknownKeys -join ', '). Please check for typos."
        }

        # Value types: Apply-ProfileSettings casts with [bool], and [bool]"false" is $true, so a
        # quoted or nested value would silently switch a removal option on. Refuse such a file.
        $typeErrors = @()
        foreach ($cd in $script:ComponentDefs.Values) {
            if ($cd.Type -ne 'Bool') { continue }
            $prop = $settings.PSObject.Properties[$cd.Key]
            if ($prop -and $null -ne $prop.Value -and $prop.Value -isnot [bool]) { $typeErrors += "$($cd.Key) (expected true/false, got '$($prop.Value)')" }
        }
        $tsProp = $settings.PSObject.Properties['TweakSettings']
        if ($tsProp -and $null -ne $tsProp.Value) {
            foreach ($prop in $tsProp.Value.PSObject.Properties) {
                if ($null -ne $prop.Value -and $prop.Value -isnot [bool]) { $typeErrors += "TweakSettings.$($prop.Name) (expected true/false, got '$($prop.Value)')" }
            }
        }
        if ($typeErrors.Count -gt 0) {
            throw "Profile '$([System.IO.Path]::GetFileName($FilePath))' has setting(s) of the wrong type: $($typeErrors -join '; ')"
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

. (Join-Path -Path (Join-Path -Path $scriptDirEarly -ChildPath "lib") -ChildPath "WinEaseReport.ps1")

# Handle -TestSelf before transcript or prompts
if ($TestSelf) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $helperModule = Join-Path -Path $scriptDir -ChildPath "WinEasehelpers.ps1"
    if (Test-Path -LiteralPath $helperModule) { . $helperModule }
    . (Join-Path -Path $scriptDir -ChildPath "lib\WinEaseSelfTest.ps1")
    $builderPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path -Path $scriptDir -ChildPath "WinEasebuilder.ps1" }
    $unattendPath = Join-Path -Path $scriptDir -ChildPath "autounattend.xml"
    $testResult = Invoke-WinEaseSelfTest -ScriptRoot $scriptDir -BuilderPath $builderPath -UnattendPath $unattendPath
    if ($testResult) { exit 0 } else { exit 1 }
}

# Start Transcript with log rotation (Keep latest 10 logs, fallback to TEMP)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# F8: Dot-source extracted pure helpers (module extraction)
$helperModule = Join-Path -Path $scriptDir -ChildPath "WinEasehelpers.ps1"
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
        $null = New-Item -ItemType Directory -Force -Path $logDir
    }
    $transcriptPath = Join-Path -Path $logDir -ChildPath "WinEase_$timestampStr.log"
    $script:DismLogPath = Join-Path -Path $logDir -ChildPath "dism_$timestampStr.log"
    Start-Transcript -Path $transcriptPath -Force
    # Prune logs beyond parameter -KeepLogs (Default: 10)
    Get-ChildItem -Path $logDir -Filter "WinEase_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "dism_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # Prune logs beyond parameter -KeepLogs (Default: 10)
    Get-ChildItem -Path $logDir -Filter "WinEase_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "dism_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLogs |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDir -Filter "WinEase_*.config.json" -File -ErrorAction SilentlyContinue |
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
    # A build that starts while another one is still running must not delete the diagnostic
    # directory of that other build: the directory of a running build is still empty, so the
    # "drop empty dirs" rule would pick it up and the report of the running build would be
    # lost. Only the directories that existed before this build started are rotated.
    # Dry runs and test-mode invocations are not builds and must never rotate the
    # diagnostics of a real build that is running in parallel.
    $diagRootDir = Join-Path -Path $scriptDir -ChildPath "build_diagnostics"
    if ((-not $isDryRunMode) -and ($env:WINEASE_TEST_MODE -ne "1") -and (Test-Path -LiteralPath $diagRootDir)) {
        $rotatableDirs = @(Get-ChildItem -LiteralPath $diagRootDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $script:BuilderStartTime })
        $rotatableDirs |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $rotatableDirs |
            Sort-Object Name -Descending |
            Select-Object -Skip $KeepLogs |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    $fallbackLogDir = $env:TEMP
    $transcriptPath = Join-Path -Path $fallbackLogDir -ChildPath "WinEase_$timestampStr.log"
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
        Write-Host "   WinEase Batch Queue Mode: $($profileQueue.Count) Profiles to Build    " -ForegroundColor Cyan
        Write-Host "=========================================================" -ForegroundColor Cyan
        # Release the global build mutex so each child build process can acquire it in turn
        if ($script:BuildMutex) {
            try {
                if ($script:HasMutex) { $script:BuildMutex.ReleaseMutex() }
                $script:BuildMutex.Dispose()
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            $script:BuildMutex = $null
            $script:HasMutex = $false
        }
        $queueSuccess = 0
        foreach ($qProf in $profileQueue) {
            Write-Host "`n>>> Starting Batch Build for Profile: $qProf <<<" -ForegroundColor Yellow
            $argsToPass = [System.Collections.Generic.List[string]]::new()
            # S-M1: UserPassword is excluded from the serialized arguments for the same
            # reason as in the elevation path above: the arguments become a
            # -EncodedCommand process argument, and Base64 is readable by any local
            # process. Batch child builds therefore run without the password; a
            # profile in the queue that needs one (ConfigureWinlogon) must not rely
            # on it being inherited from the parent process.
            if ($PSBoundParameters.ContainsKey('UserPassword')) {
                Write-Host "Note: -UserPassword is not forwarded to batch child builds (it would be readable in the child process command line)." -ForegroundColor Yellow
            }
            foreach ($k in $PSBoundParameters.Keys) {
                if ($k -in @('Profile', 'TestSelf', 'NonInteractive', 'UserPassword')) { continue }
                $argsToPass.Add((ConvertTo-WinEaseCliArgument -Name $k -Value $PSBoundParameters[$k]))
            }
            $argsToPass.Add((ConvertTo-WinEaseCliArgument -Name 'Profile' -Value $qProf))
            $argsToPass.Add("-NonInteractive")
            $subProc = Start-Process -FilePath "powershell.exe" -ArgumentList (New-WinEaseChildArguments -ScriptPath $PSCommandPath -ScriptArguments $argsToPass) -Wait -PassThru -NoNewWindow
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
Write-Host "               Welcome to WinEase builder!                " -ForegroundColor Cyan
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

# 1. The defaults of the components come from config\schema.psd1 - the single source of
#    truth. A preset (config\presets.psd1), a profile or the command line overwrites them
#    below; an explicit setting of the user always wins (Resolve-WinEaseConfiguration).
foreach ($cd in $script:ComponentDefs.Values) {
    if ($cd.Type -eq 'Special' -or -not $cd.ContainsKey('Default')) { continue }
    $val = if ($cd.Type -eq 'String') { [string]$cd.Default } else { [bool]$cd.Default }
    Set-Variable -Name $cd.Variable -Scope Script -Value $val
}
$exportESDMode = $false
$splitWIMMode = $false
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
        $null = Apply-ProfileSettings -ProfileName 'extreme'
        $selectedProfile = 'extreme'
    } else {
        Write-Host "Applied Built-in Profile: $($applied.ProfileName)" -ForegroundColor Green
    }
}

# 0b. LoadProfile Parameter (JSON profile written by -SaveProfile). Applied after -Profile, and
# explicitly passed CLI switches still override it (they are processed further below).
if ($bound.ContainsKey('LoadProfile') -and $bound['LoadProfile']) {
    $loadedSettings = Import-WinEaseProfile -FilePath $LoadProfile
    if (-not $loadedSettings) {
        throw "Could not load JSON profile: $LoadProfile"
    }
    $null = Apply-ProfileSettings -ProfileObject $loadedSettings
    $profileNameProp = $loadedSettings.PSObject.Properties['ProfileName']
    $selectedProfile = if ($profileNameProp -and $profileNameProp.Value) { "$($profileNameProp.Value)" } else { [System.IO.Path]::GetFileNameWithoutExtension($LoadProfile) }

    # Settings outside Apply-ProfileSettings: only taken from the file when not given on the command line
    foreach ($extraKey in @('SourceDrive', 'WorkDir', 'Index', 'ComputerName', 'UserName', 'UserPassword', 'SkipEiCfg', 'NoPostInstallAssets')) {
        $prop = $loadedSettings.PSObject.Properties[$extraKey]
        if (-not $prop -or $bound.ContainsKey($extraKey)) { continue }
        $val = $prop.Value
        if ($extraKey -eq 'UserPassword' -and -not [string]::IsNullOrEmpty("$val")) {
            # Old profiles may still carry the password in plain text. It is still honored (compatibility),
            # never logged, and a new -SaveProfile no longer writes it.
            Write-Warning "Profile '$([System.IO.Path]::GetFileName($LoadProfile))' contains a plain-text UserPassword. It is still used for this build, but remove it from the file (profiles are meant to be shared) and pass -UserPassword on the command line instead."
        }
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

# The WinForms GUI (Show-WinEaseGUI) lives in gui\WinEaseGui.ps1 and is loaded only when a GUI
# can be shown: -GUI below, or option [7] of the interactive profile menu.
$script:WinEaseGuiPath = Join-Path -Path $scriptDirEarly -ChildPath "gui\WinEaseGui.ps1"

# 0c. Graphical User Interface (GUI) Trigger
if ($GUI) {
    . $script:WinEaseGuiPath
    Write-Host "Opening WinEase Graphical User Interface (GUI)..." -ForegroundColor Cyan
    if (Invoke-WinEaseGuiSession) {
        $NonInteractive = $true
    } else {
        Write-Host "WinEase GUI cancelled by user. Exiting..." -ForegroundColor Gray
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

# Paired Keep/Remove-style switches, driven by CliBindings in config\schema.psd1
foreach ($cb in $script:WinEaseSettingsDef.CliBindings) {
    foreach ($grp in $cb.Switches) {
        $hit = @($grp.Names | Where-Object { $bound.ContainsKey($_) }) | Select-Object -First 1
        if (-not $hit) { continue }
        $val = & $getBoundVal $hit
        if ($grp.Invert) { $val = -not $val }
        Set-Variable -Name $cb.Variable -Value $val
        # The command line is the explicit setting of the user: a preset that is applied
        # later must not overrule it.
        foreach ($cd in $script:ComponentDefs.Values) {
            if ($cd.Variable -eq $cb.Variable) { $script:ConfigOverrides[$cd.Key] = $val }
        }
        if ($grp.Also) { foreach ($ak in $grp.Also.Keys) { Set-Variable -Name $ak -Value $grp.Also[$ak] } }
        [void]$cliBound.Add($cb.Tag)
        break
    }
}

# 21. Advanced Modular Optimization Tweak Toggles overrides
# Components marked CliSwitch in config\schema.psd1: a [switch] named like the key sets its variable
foreach ($cd in $script:ComponentDefs.Values) {
    if ($cd.CliSwitch -and (& $isAnyBound @($cd.Key))) {
        $cdValue = (& $getBoundVal $cd.Key)
        Set-Variable -Name $cd.Variable -Scope Script -Value $cdValue
        $script:ConfigOverrides[$cd.Key] = $cdValue
        [void]$cliBound.Add($cd.Key)
    }
}
if ($bound.ContainsKey('HibernateMode'))     { $hibernateMode   = $bound['HibernateMode'];          [void]$cliBound.Add('HibernateMode') }
if ($bound.ContainsKey('CrashDumpMode'))     { $crashDumpMode   = $bound['CrashDumpMode'];          [void]$cliBound.Add('CrashDumpMode') }

# Override script:TweakSettings from CLI switches or -TweakSettings argument
if ($bound.ContainsKey('TweakSettings') -and $bound['TweakSettings']) {
    if ($bound['TweakSettings'] -is [hashtable]) {
        foreach ($k in $bound['TweakSettings'].Keys) {
            $rk = Resolve-WinEaseTweakKey $k
            $script:TweakSettings[$rk] = [bool]$bound['TweakSettings'][$k]
            $script:TweakOverrides[$rk] = [bool]$bound['TweakSettings'][$k]
        }
    } elseif ($bound['TweakSettings'] -is [PSCustomObject]) {
        foreach ($p in $bound['TweakSettings'].PSObject.Properties) {
            $rk = Resolve-WinEaseTweakKey $p.Name
            $script:TweakSettings[$rk] = [bool]$p.Value
            $script:TweakOverrides[$rk] = [bool]$p.Value
        }
    }
}
if ($script:AllTweakDefs) {
    foreach ($tk in $script:AllTweakDefs.Keys) {
        if ($bound.ContainsKey($tk)) {
            $script:TweakSettings[$tk] = [bool]$bound[$tk]
            $script:TweakOverrides[$tk] = [bool]$bound[$tk]
        }
    }
}
# Keep variable-backed tweaks consistent: a dedicated CLI switch wins, otherwise an explicit -TweakSettings entry
$cliTweakSettingKeys = @()
if ($bound.ContainsKey('TweakSettings') -and $bound['TweakSettings']) {
    $cliTweakSettingKeys = if ($bound['TweakSettings'] -is [hashtable]) { @($bound['TweakSettings'].Keys) } else { @($bound['TweakSettings'].PSObject.Properties.Name) }
    $cliTweakSettingKeys = @($cliTweakSettingKeys | ForEach-Object { Resolve-WinEaseTweakKey $_ })
}
foreach ($tk in $script:TweakVariableMap.Keys) {
    $cliName = if ($tk -eq 'BypassActivationRestrictions') { 'ActivationRestrictions' } else { $tk }
    $varName = $script:TweakVariableMap[$tk]
    if ($cliBound.Contains($cliName)) {
        $script:TweakSettings[$tk] = [bool](Get-Variable -Name $varName -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    } elseif ($cliTweakSettingKeys -contains $tk) {
        Set-Variable -Name $varName -Scope Script -Value ([bool]$script:TweakSettings[$tk])
    }
}
if ($bound.ContainsKey('AllowPhysicalDebloat')) {
    $allowPhysicalDebloat = [bool]$bound['AllowPhysicalDebloat']
}
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
    Write-Host "         WinEase Configuration Profile Selector" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "Choose a profile or proceed to customization:" -ForegroundColor Gray
    Write-Host "  [1] Extreme Slim & Gaming (Default: Max debloat, Atlas/ReviOS, Store removed)" -ForegroundColor Green
    Write-Host "  [2] Balanced Pro (Safe: Windows Update & Defender kept, high stability)" -ForegroundColor Yellow
    Write-Host "  [3] FAT32 USB Split-WIM (3.8GB SWM Chunks for UEFI)" -ForegroundColor Yellow
    Write-Host "  [4] Handheld Gaming (ROG Ally, Steam Deck, Legion Go)" -ForegroundColor Green
    Write-Host "  [5] VM & Developer Workstation (WSL2, Hyper-V, WinUpdate)" -ForegroundColor Cyan
    Write-Host "  [6] Audio & DAW Production (Minimal Latency, VST Protected)" -ForegroundColor Magenta
    Write-Host "  [7] Launch GUI (Graphical User Interface)" -ForegroundColor Blue
    Write-Host "  [8] Custom (Step-by-step 15 configuration prompts)" -ForegroundColor Magenta
    $pChoice = Read-Host "Select Profile [1-8] (Default: 1 - Extreme Slim & Gaming)"
    if ($pChoice) { $pChoice = $pChoice.Trim().ToLower() } else { $pChoice = "1" }

    $skipIndividualPrompts = $false
    if ($pChoice -in @('1', 'extreme', 'gaming', 'slim')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "extreme"
        $null = Apply-ProfileSettings -ProfileName 'extreme'
        Write-Host "Applied Profile: Extreme Slim & Gaming" -ForegroundColor Green
    } elseif ($pChoice -in @('2', 'balanced', 'safe', 'pro')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "balanced"
        $null = Apply-ProfileSettings -ProfileName 'balanced'
        Write-Host "Applied Profile: Balanced Pro (Windows Update & Defender kept)" -ForegroundColor Yellow
    } elseif ($pChoice -in @('4', 'handheld', 'ally', 'deck', 'legion')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "handheld"
        $null = Apply-ProfileSettings -ProfileName 'handheld'
        Write-Host "Applied Profile: Handheld Gaming" -ForegroundColor Green
    } elseif ($pChoice -in @('5', 'vm', 'dev', 'developer')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "vm"
        $null = Apply-ProfileSettings -ProfileName 'vm'
        Write-Host "Applied Profile: VM & Developer Workstation" -ForegroundColor Cyan
    } elseif ($pChoice -in @('6', 'audio', 'daw', 'dtm')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "audio"
        $null = Apply-ProfileSettings -ProfileName 'audio'
        Write-Host "Applied Profile: Audio & DAW Production" -ForegroundColor Magenta
    } elseif ($pChoice -in @('3', 'fat32', 'split', 'splitwim')) {
        $skipIndividualPrompts = $true
        $selectedProfile = "fat32"
        $null = Apply-ProfileSettings -ProfileName 'fat32'
        Write-Host "Applied Profile: FAT32 USB Split-WIM" -ForegroundColor Yellow
    } elseif ($pChoice -in @('7', 'gui', 'ui')) {
        . $script:WinEaseGuiPath
        $skipIndividualPrompts = $true
        if (-not (Invoke-WinEaseGuiSession)) {
            Write-Host "GUI cancelled by user. Exiting..." -ForegroundColor Gray
            Stop-Transcript
            exit 0
        }
    } else {
        $selectedProfile = "custom"
        Write-Host "Entering Custom step-by-step configuration..." -ForegroundColor Magenta
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
        $currentCfg = Get-WinEaseCurrentConfig -ProfileName "Custom Profile"
        Export-WinEaseProfile -FilePath $savePath -Config $currentCfg
    }
    }
}

# Export profile if requested via -SaveProfile parameter
if ($SaveProfile) {
    $currentCfg = Get-WinEaseCurrentConfig -ProfileName $(if ($selectedProfile) { $selectedProfile } else { "Exported Profile" })
    Export-WinEaseProfile -FilePath $SaveProfile -Config $currentCfg
}

# -ComparePreset: show the difference between the current configuration and a preset (name or JSON path), then exit.
# No build or disk operation is performed.
if ($ComparePreset) {
    $cmpCfg = Get-WinEaseCurrentConfig -ProfileName $(if ($selectedProfile) { $selectedProfile } else { "Current Configuration" })
    $cmpDiff = Compare-WinEaseConfig -ReferenceConfig $cmpCfg -DifferenceConfig $ComparePreset
    Write-Host ""
    Write-Host (Format-WinEaseConfigDiff -DiffResult $cmpDiff)
    if ($transcriptPath) { Stop-Transcript }
    exit 0
}

# Save build configuration snapshot to logs/<timestamp>.config.json
$logsDir = Join-Path -Path $scriptDir -ChildPath "logs"
if (-not (Test-Path -LiteralPath $logsDir)) {
    [void](New-Item -ItemType Directory -Force -Path $logsDir -ErrorAction SilentlyContinue)
}
$configSnapshotPath = Join-Path -Path $logsDir -ChildPath "WinEase_$timestampStr.config.json"
# Use the normalized current configuration instead of the individual script variables.
# A [switch] that arrived through a GUI/profile object can otherwise be serialized as
# {"IsPresent":true} and the snapshot then lies about booleans.
$snapshotSource = Get-WinEaseCurrentConfig -ProfileName $(if ($selectedProfile) { $selectedProfile } else { 'Extreme (Default)' })
$snapshotTweaks = [ordered]@{}
if ($snapshotSource.TweakSettings) {
    foreach ($tk in $snapshotSource.TweakSettings.Keys) { $snapshotTweaks[[string]$tk] = [bool]$snapshotSource.TweakSettings[$tk] }
}
$resolvedConfig = [PSCustomObject]@{
    Timestamp                  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Version                    = $script:WinEaseVersion
    Profile                    = if ($selectedProfile) { $selectedProfile } else { 'Extreme (Default)' }
    Architecture               = $architecture
    RemoveDefender             = [bool]$snapshotSource.RemoveDefender
    KeepAsianIME               = [bool]$snapshotSource.KeepAsianIME
    KeepExtraFonts             = [bool]$snapshotSource.KeepExtraFonts
    RemoveDrivers              = [bool]$snapshotSource.RemoveDrivers
    DisableWindowsUpdate       = [bool]$snapshotSource.DisableWindowsUpdate
    KeepBluetooth              = [bool]$snapshotSource.KeepBluetooth
    WSLSupport                 = [bool]$snapshotSource.WSLSupport
    KeepRecoveryEnv            = [bool]$snapshotSource.KeepRecoveryEnv
    BypassActivationRestrictions = [bool]$snapshotSource.BypassActivationRestrictions
    RadicalRAM                 = [bool]$snapshotSource.RadicalRAM
    SafeDebloatMode            = [bool]$snapshotSource.SafeDebloatMode
    UltraSlimMode              = [bool]$snapshotSource.UltraSlimMode
    SetJapaneseKeyboard        = [bool]$snapshotSource.SetJapaneseKeyboard
    AtlasReviOSMode            = [bool]$snapshotSource.AtlasReviOSMode
    RemoveStore                = [bool]$snapshotSource.RemoveStore
    KeepXboxServices           = [bool]$snapshotSource.KeepXboxServices
    RemoveAppxBloatware        = [bool]$snapshotSource.RemoveAppxBloatware
    RemoveCameraApp            = [bool]$snapshotSource.RemoveCameraApp
    RemovePhotosApp            = [bool]$snapshotSource.RemovePhotosApp
    RemoveScreenSketchApp      = [bool]$snapshotSource.RemoveScreenSketchApp
    IncludeMigrationAssistant  = [bool]$snapshotSource.IncludeMigrationAssistant
    IncludeMigrationBackup     = [bool]$snapshotSource.IncludeMigrationBackup
    KeepAudioTweaks            = [bool]$snapshotSource.KeepAudioTweaks
    AllowPhysicalDebloat       = [bool]$allowPhysicalDebloat
    AdvancedDebloatStandard    = @($script:advancedDebloatStandard)
    AdvancedDebloatExperimental = @($script:advancedDebloatExperimental)
    PayloadFormat              = if ($exportESDMode) { "ESD" } elseif ($splitWIMMode) { "SWM" } else { "WIM" }
    TweakSettings              = $snapshotTweaks
}
try {
    $configJson = $resolvedConfig | ConvertTo-Json -Depth 6
    [void](Write-WinEaseTextFileAtomic -Path $configSnapshotPath -Content $configJson -Encoding utf8)
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

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
Write-Host "  - Remove AppX Bloatware:   $removeAppxBloatware"
Write-Host "  - Remove Camera app:       $removeCameraApp"
Write-Host "  - Remove Photos app:       $removePhotosApp"
Write-Host "  - Remove Screen Sketch:    $removeScreenSketchApp"
Write-Host "  - Include Migration Tool:  $includeMigrationAssistant"
Write-Host "  - Bundle Migration Backup: $includeMigrationBackup"
Write-Host "  - Low-Latency Audio MMCSS: $keepAudioTweaks"
Write-Host "  - Search Indexing:         $(if ($keepSearchIndex) { 'Enabled (kept)' } else { 'Disabled (WSearch service off + SearchHost blocked)' })"
Write-Host "  - Force WinSxS Cleanup:    $ForceWinSxSCleanup (experimental, opt-in)"
if ($removeDefender) {
    Write-Host "  [!] Defender is removed: the installed system has NO antivirus protection." -ForegroundColor Yellow
    Write-Host "      Recovery: Defender cannot be re-enabled in place; use a repair install or reinstall (see docs\SECURITY_OPTIONS.md)." -ForegroundColor Yellow
}
if ($disableWU) {
    Write-Host "  [!] Windows Update is disabled: the installed system receives no patches until it is re-enabled." -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $configSnapshotPath) {
    Write-Host "  - Config Snapshot:         $configSnapshotPath" -ForegroundColor DarkCyan
}
Write-Host "  - Payload Format:          $(if ($exportESDMode) { 'install.esd (LZMS)' } elseif ($splitWIMMode) { 'install.swm (Split-WIM / FAT32)' } else { 'install.wim (LZX - Recommended)' })"
# Build plan from the GUI's final confirmation: log it and compare it with what was just resolved (throws on a critical mismatch)
$planResolved = [ordered]@{}
foreach ($rp in $resolvedConfig.PSObject.Properties) { $planResolved[$rp.Name] = $rp.Value }
$planResolved['UseVHDX'] = [bool]$useVHDX
$planResolved['DryRun'] = [bool]$isDryRunMode
[void](Invoke-WinEaseBuildPlanCheck -Plan $script:GuiBuildPlan -Resolved $planResolved -LogDirectory $logsDir -BaseName "WinEase_$timestampStr")
Write-Host ""
# G5: estimated build time from last run's phase timings
try {
    $lastTimingsPath = Join-Path -Path $logDir -ChildPath "last_phase_timings.json"
    if (Test-Path -LiteralPath $lastTimingsPath) {
        $totalSec = Get-WinEaseLastRunTotalSeconds -TimingsPath $lastTimingsPath
        if ($totalSec -gt 0) {
            Write-Host "  - Estimated build time:    ~$([math]::Round($totalSec / 60, 1)) min (based on last run's phase timings)" -ForegroundColor DarkCyan
        }
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

# Dependency & feature-impact pre-flight check
try {
    $depCfg = Get-WinEaseCurrentConfig -ProfileName $(if ($selectedProfile) { $selectedProfile } else { "Current Configuration" })
    $depResult = Test-WinEaseDependencies -Config $depCfg
    Write-Host ""
    Write-Host "Dependency & feature-impact analysis:" -ForegroundColor Cyan
    $depText = Format-WinEaseDependencyReport -Result $depResult
    if ($depText) {
        foreach ($ln in ($depText -split "`r?`n")) {
            if ($ln -match '^\[DEPENDENCY CONFLICT\]') { Write-Host $ln -ForegroundColor Red }
            elseif ($ln -match '^\[DEPENDENCY UNKNOWN') { Write-Host $ln -ForegroundColor Magenta }
            elseif ($ln -match '^\[FEATURE IMPACT\]') { Write-Host $ln -ForegroundColor Yellow }
            else { Write-Host $ln }
        }
    } else {
        Write-Host "  (no conflicts, unknowns or impacts detected)" -ForegroundColor Green
    }
    if ($StrictDependencyCheck -and ($depResult.Conflicts.Count -gt 0 -or $depResult.Unknowns.Count -gt 0)) {
        throw "Dependency check failed: $($depResult.Conflicts.Count) conflict(s) and $($depResult.Unknowns.Count) unknown(s) detected. Aborting build (-StrictDependencyCheck)."
    }
} catch {
    if ($_.Exception.Message -match 'Dependency check failed') { throw }
    Write-Warning "Dependency check skipped: $($_.Exception.Message)"
}

# Recovery readiness check (advisory only; never stops the build)
try {
    $recoveryResult = Test-WinEaseRecoveryReadiness -Config $resolvedConfig
    Write-Host ""
    Write-Host "Recovery readiness:" -ForegroundColor Cyan
    if ($recoveryResult) { Write-Host (($recoveryResult | Format-List | Out-String).TrimEnd()) }
} catch {
    Write-Warning "Recovery readiness check skipped: $($_.Exception.Message)"
}

# M2: Custom scripts (PreBuild stage)
if (Get-Command -Name Invoke-WinEaseCustomScriptsStage -ErrorAction SilentlyContinue) {
    try {
        $null = Invoke-WinEaseCustomScriptsStage -Stage 'PreBuild' -Context @{ Config = $resolvedConfig; ScriptRoot = $scriptDir } -DryRun:$isDryRunMode
    } catch { Write-Warning "PreBuild custom scripts failed: $($_.Exception.Message)" }
}

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

# Input check (lib\WinEaseInputValidation.ps1, the same function both GUI windows run): source, workspace / output folders and
# their collisions, drivers, names and the edition index, before any destructive step. A dry run / test mode skips the
# write probe so it stays free of side effects.
$inputIssues = @(Test-WinEaseBuildInputs -SourceDrive $SourceDrive -WorkDir $WorkDir -OutputDir $scriptDir -OutputIsoName $OutputIsoName `
        -Index $Index -InjectDrivers $InjectDrivers -UserName $UserName -ComputerName $ComputerName `
        -SkipWriteProbe:($isDryRunMode -or ($env:WINEASE_TEST_MODE -eq '1')))
foreach ($inputIssue in @($inputIssues | Where-Object { $_.Severity -eq 'Warning' })) {
    Write-Warning "$($inputIssue.Field): $(Get-WinEaseInputIssueText -Issue $inputIssue)"
}
if (Test-WinEaseInputHasError -Issues $inputIssues) {
    throw "Input validation failed:`n$(Format-WinEaseInputIssues -Issues @($inputIssues | Where-Object { $_.Severity -eq 'Error' }))"
}

# Early check for WINEASE_TEST_MODE or -DryRun / -WhatIf
if (($env:WINEASE_TEST_MODE -eq "1") -or $isDryRunMode) {
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
$script:BuildCancelled = $false
$script:CancelCleanupProblems = @()
$isoCreatedSuccessfully = $false
# Progress protocol: failure data for the 'done' event and the paths the window can open.
# The output folder is known before phase 18; phase 18 replaces this with the real ISO path.
$script:BuildFailureData = $null
$script:BuildOutputIsoPath = if ($OutputIsoName) {
    $plannedIsoName = if ($OutputIsoName.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) { $OutputIsoName } else { "$OutputIsoName.iso" }
    Join-Path -Path $scriptDir -ChildPath $plannedIsoName
} else {
    Join-Path -Path $scriptDir -ChildPath 'WinEase.iso'
}
$script:BuildReportPath = ''

$script:MountOpened = $false
$script:HivesLoaded = $false
$script:MountedIso = $null
$script:DefenderExclusionAdded = $false
$script:IsVhdxMounted = $false

# Diagnostic Session Isolation (Rule 2)
$script:BuildId = New-WinEaseBuildId
$script:DiagDir = Join-Path -Path $scriptDir -ChildPath "build_diagnostics\$($script:BuildId)"
$null = New-Item -ItemType Directory -Path $script:DiagDir -Force

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

function Write-WinEaseDiagnosticReport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'StatusMessage', Justification = 'Callers pass a status message; kept for compatibility')]
    param([string]$StatusMessage = "")
    try {
        # The diagnostic directory is created when the build starts, but it can be
        # removed again while the build runs (the rotation of a build that starts in
        # parallel). It is therefore created again before the report is written, so a
        # failed build always leaves its report behind.
        if (-not (Test-Path -LiteralPath $script:DiagDir)) {
            $null = New-Item -ItemType Directory -Path $script:DiagDir -Force
        }
        $jsonPath = Join-Path -Path $script:DiagDir -ChildPath "build_diagnostic_report.json"
        # R7: the plugins that took part in this build (loaded) and the ones that were refused
        if (Get-Command -Name Get-WinEaseLoadedPlugins -ErrorAction SilentlyContinue) {
            $script:DiagnosticData['Plugins'] = @(Get-WinEaseLoadedPlugins | ForEach-Object { [ordered]@{ Id = $_.Id; Version = $_.Version; Source = $_.Source; File = $_.File; Sha256 = $_.Sha256; OnError = $_.OnError } })
            $script:DiagnosticData['PluginsRejected'] = @($script:WinEasePluginRejected | ForEach-Object { [ordered]@{ Source = $_.Source; File = $_.File; Reason = $_.Reason } })
            $script:DiagnosticData['PluginRuns'] = @($script:WinEasePluginRunLog | ForEach-Object { [ordered]@{ Plugin = $_.Plugin; Phase = $_.Phase; Stage = $_.Stage; Status = $_.Status } })
        }
        $script:DiagnosticData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding utf8

        $txtPath = Join-Path -Path $script:DiagDir -ChildPath "build_diagnostic_summary.txt"
        $txtLines = @(
            "=========================================================",
            " WinEase Build Diagnostic Summary",
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
            "Plugins loaded:           $(if ($script:DiagnosticData['Plugins']) { (@($script:DiagnosticData['Plugins']) | ForEach-Object { "$($_.Id) $($_.Version) [$($_.Sha256)]" }) -join '; ' } else { '(none)' })",
            "Plugins refused:          $(if ($script:DiagnosticData['PluginsRejected']) { (@($script:DiagnosticData['PluginsRejected']) | ForEach-Object { "$($_.File): $($_.Reason)" }) -join '; ' } else { '(none)' })",
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
function Invoke-WinEaseHostHealthCheck {
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
                if ($freeGB -lt (Get-WinEaseRecommendedFreeGB)) { $hostIssues.Add("Low free space on the $volLetter`: drive ($freeGB GB free, $(Get-WinEaseRecommendedFreeGB)+ GB recommended).") }
            }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

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

. (Join-Path -Path (Join-Path -Path $scriptDirEarly -ChildPath "lib") -ChildPath "WinEaseResume.ps1")

# Resume mode entry point (before Phase 1 so no destructive early phases can run)
if ($ResumeFromPhase -gt 0) {
    if ($GUI -or $TestSelf -or $DryRun) {
        throw "ResumeFromPhase cannot be combined with -GUI / -TestSelf / -DryRun."
    }
    $cp = Load-WinEaseCheckpoint
    if (-not $cp) {
        throw "ResumeFromPhase: no checkpoint.json found. Run a full build first so a checkpoint is recorded."
    }
    $cpPhase = [double]$cp.CompletedPhase
    if ($cpPhase -lt ($ResumeFromPhase - 1)) {
        throw "ResumeFromPhase: checkpoint only reaches Phase $cpPhase, cannot resume from Phase $ResumeFromPhase. Run a full build or lower the target."
    }
    Write-Host "Checkpoint loaded: last completed phase = $cpPhase (timestamp $($cp.Timestamp))" -ForegroundColor Cyan
    if ($ResumeFromPhase -ge 13) {
        Write-Host "ResumeFromPhase $ResumeFromPhase >= 13: delegating to Resume-ISO mode (Phase 14+ fast-track)..." -ForegroundColor Yellow
        # Hydrate the state ResumeIsoOnly relies on (it re-derives workspace/payload itself)
        try {
            Invoke-WinEaseResumeIsoBuild
            exit 0
        } catch {
            if ($script:DiagnosticData) {
                $script:DiagnosticData.FailurePhase = "ResumeFromPhase Mode"
                $script:DiagnosticData.FailureMessage = "$_"
                Write-WinEaseDiagnosticReport "Resume failed"
            }
            Write-Host "ResumeFromPhase failed: $_" -ForegroundColor Red
            try { Stop-Transcript } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
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
        Invoke-WinEaseResumeIsoBuild
        exit 0
    } catch {
        if ($script:DiagnosticData) {
            $script:DiagnosticData.FailurePhase = "Resume-ISO Mode"
            $script:DiagnosticData.FailureMessage = "$_"
            Write-WinEaseDiagnosticReport "Resume build failed"
        }
        Write-Host "" -ForegroundColor Red
        Write-Host "==============================================================================" -ForegroundColor Red
        Write-Host "  WinEase RESUME BUILD FAILED!" -ForegroundColor Red
        Write-Host "==============================================================================" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host "Preserved workspace payload: $(if ($WorkDir) { $WorkDir } else { '<Documents>\WinEase_workspace\build' })" -ForegroundColor Gray
        try { Stop-Transcript } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        exit 1
    }
}

try {
    $phasesDir = Join-Path -Path $scriptDir -ChildPath "phases"

    # Check the configuration for contradictions. The check itself only reports: it never
    # changes a setting of the user (the "auto resolve" of an earlier version silently
    # rewrote e.g. the Windows Update switch - AUD-14).
    Write-Host "Checking configuration conflict matrix..." -ForegroundColor Cyan
    $conflictCheck = Test-WinEaseConfigConflicts -Config $resolvedConfig
    if ($conflictCheck.Conflicts.Count -gt 0) {
        Write-Host "  Detected $($conflictCheck.Conflicts.Count) configuration conflict(s):" -ForegroundColor Yellow
        foreach ($cf in $conflictCheck.Conflicts) {
            Write-Host "    - [$($cf.Type)] $($cf.Rule): $($cf.Details) -> $($cf.Resolution)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No configuration conflicts detected." -ForegroundColor Green
    }

    # The safeguards are applied here and reported: a "keep" request always wins over a
    # selected debloat target, and the physical debloat needs its explicit consent.
    $removedBySafeguard = [System.Collections.Generic.List[string]]::new()
    foreach ($cf in $conflictCheck.Conflicts) {
        if (-not $cf.Safeguard) { continue }
        if ($cf.Safeguard.Action -eq 'ClearExperimental') {
            # The cast to [string[]] is required: AddRange takes an IEnumerable<string>,
            # and a plain Object[] is not converted by the method binder (it throws a
            # MethodException), so the build died here whenever the physical debloat
            # needed its consent.
            $removedBySafeguard.AddRange([string[]]@($script:advancedDebloatExperimental))
            $script:advancedDebloatExperimental = @()
            if ($script:TweakSettings.Contains('PhysicalDebloat')) { $script:TweakSettings['PhysicalDebloat'] = $false }
            Write-Host "  [Safety] The physical debloat needs the explicit consent (-AllowPhysicalDebloat): the experimental deletions were cleared." -ForegroundColor Yellow
            continue
        }
        if ($cf.Safeguard.Action -eq 'RemoveItems') {
            foreach ($item in @($cf.Safeguard.Items)) { if ($item) { $removedBySafeguard.Add([string]$item) } }
        }
    }
    if ($removedBySafeguard.Count -gt 0) {
        $script:advancedDebloatStandard     = @($script:advancedDebloatStandard     | Where-Object { $removedBySafeguard -notcontains $_ })
        $script:advancedDebloatExperimental = @($script:advancedDebloatExperimental | Where-Object { $removedBySafeguard -notcontains $_ })
        Write-Host "  [Safety] $($removedBySafeguard.Count) debloat target(s) were removed because a 'keep' request contradicts them." -ForegroundColor Yellow
    }
    # Sync resolved settings back to execution variables
    if ($conflictCheck.ResolvedConfig) {
        $rCfg = $conflictCheck.ResolvedConfig
        if ($rCfg.PSObject.Properties['KeepAsianIME'])                 { $keepAsianIME                 = [bool]$rCfg.KeepAsianIME }
        if ($rCfg.PSObject.Properties['KeepExtraFonts'])               { $keepExtraFonts               = [bool]$rCfg.KeepExtraFonts }
        if ($rCfg.PSObject.Properties['KeepRecoveryEnv'])              { $keepRecoveryEnv              = [bool]$rCfg.KeepRecoveryEnv }
        if ($rCfg.PSObject.Properties['KeepBluetooth'])                { $keepBT                       = [bool]$rCfg.KeepBluetooth }
        if ($rCfg.PSObject.Properties['KeepXboxServices'])             { $keepXboxServices             = [bool]$rCfg.KeepXboxServices }
        if ($rCfg.PSObject.Properties['KeepAudioTweaks'])              { $keepAudioTweaks              = [bool]$rCfg.KeepAudioTweaks }
        if ($rCfg.PSObject.Properties['DisableWindowsUpdate'])         { $disableWU                    = [bool]$rCfg.DisableWindowsUpdate }
        if ($rCfg.PSObject.Properties['RemoveStore'])                  { $removeStore                  = [bool]$rCfg.RemoveStore }
        if ($rCfg.PSObject.Properties['SafeDebloatMode'])              { $safeDebloatMode              = [bool]$rCfg.SafeDebloatMode }
        if ($rCfg.PSObject.Properties['UltraSlimMode'])                { $ultraSlimMode                = [bool]$rCfg.UltraSlimMode }
        if ($rCfg.PSObject.Properties['AllowPhysicalDebloat'])         { $allowPhysicalDebloat         = [bool]$rCfg.AllowPhysicalDebloat }
        if ($rCfg.PSObject.Properties['TweakSettings'] -and $rCfg.TweakSettings) {
            $script:TweakSettings = $rCfg.TweakSettings
        }
    }

    # C-H3: when resuming, the configuration resolved for THIS run must match the
    # checkpoint it resumes from. Save-WinEaseCheckpoint records ResolvedConfigHash
    # (a hash of the resolved TweakSettings + selected profile); a checkpoint made
    # by a different configuration must not silently drive this build. Checkpoints
    # written before this field existed carry no hash and are accepted as-is.
    if ($ResumeFromPhase -gt 0 -and $cp -and $cp.PSObject.Properties['ResolvedConfigHash'] -and $cp.ResolvedConfigHash) {
        $currentConfigHash = Get-WinEaseCheckpointConfigHash
        if ($currentConfigHash -and ($currentConfigHash -ine [string]$cp.ResolvedConfigHash)) {
            throw "ResumeFromPhase: the resolved configuration does not match the checkpoint (ResolvedConfigHash mismatch). Run a full build, or resume with the same settings that produced the checkpoint."
        }
    }

    # Every phase runs as: Enter-Phase -> plugin hooks (Before) -> the phase script -> plugin hooks (After).
    # The phase scripts are dot-sourced here, in the script scope, because they share its variables; this is
    # why the loop is not a function. A plugin can only run before and after a phase: it cannot replace one,
    # so the safety gates and the mount handling of the phases always run.
    $buildPhases = @(
        @{ Number = 1;   Name = "Environment Validation & Workspace Preparation";     File = "01-environment.ps1" }
        @{ Number = 2;   Name = "Source Media Detection & Validation";                File = "02-source-media.ps1" }
        @{ Number = 3;   Name = "Installation Media Preparation & Staging";           File = "03-staging.ps1" }
        @{ Number = 4;   Name = "Mount install.wim & Baseline Analysis";              File = "04-mount-baseline.ps1" }
        @{ Number = 5;   Name = "Removing provisioned AppX packages (Bloatware)";     File = "05-appx.ps1" }
        @{ Number = 6;   Name = "Removing system packages (FoD / Optional features)"; File = "06-fod.ps1" }
        @{ Number = 7;   Name = "Removing NativeImages (.NET)";                       File = "07-nativeimages.ps1" }
        @{ Number = 8;   Name = "File system slimming (Drivers, WinRE, Fonts)";       File = "08-filesystem.ps1" }
        @{ Number = 9;   Name = "Component Store (WinSxS) Optimization";              File = "09-winsxs.ps1" }
        @{ Number = 9.5; Name = "Physical Debloat (Experimental - Rust-based)";       File = "09-physical-debloat.ps1" }
        @{ Number = 10;  Name = "Load Registry Hives and Apply Optimizations";        File = "10-registry.ps1" }
        @{ Number = 11;  Name = "Configure autounattend.xml & Pre-extract Setup Scripts"; File = "11-unattend.ps1" }
        @{ Number = 12;  Name = "Unmount and Commit install.wim Image";               File = "12-unmount-commit.ps1" }
        @{ Number = 13;  Name = "Export Modified Image (WIM / ESD / SWM)";            File = "13-export.ps1" }
        @{ Number = 14;  Name = "Patch boot.wim (LabConfig & Bypasses)";              File = "14-bootwim.ps1" }
        @{ Number = 15;  Name = "Verify Final Installation Payload";                  File = "15-verify.ps1" }
        @{ Number = 16;  Name = "ISO Root Cleanup & Traceability Embedding";          File = "16-iso-cleanup.ps1" }
        @{ Number = 17;  Name = "Locate or Verify oscdimg.exe";                       File = "17-oscdimg.ps1" }
        @{ Number = 18;  Name = "Create Bootable ISO Image";                          File = "18-iso.ps1" }
    )
    # Cancel (D2): tell the window how to ask for a cancel; the request is looked at only between phases.
    Register-WinEaseCancelChannel -DiagnosticsDir $script:DiagDir
    Send-WinEaseGuiState -State 'Preparing'
    foreach ($buildPhase in $buildPhases) {
        # Phase boundary: a requested cancel stops the build before the next phase starts. A running phase (DISM/WIM
        # call) is never interrupted. The throw goes to the outer handler; the finally block is the cleanup.
        if (Test-WinEaseCancelRequested) { throw (New-WinEaseCancelException) }
        $phaseFile = Join-Path -Path $phasesDir -ChildPath $buildPhase.File
        $phaseId = [System.IO.Path]::GetFileNameWithoutExtension($buildPhase.File)
        Enter-Phase $buildPhase.Number $buildPhase.Name
        try {
            if (-not (Test-Path -LiteralPath $phaseFile)) {
                # Only the optional physical debloat phase may be absent.
                if ($buildPhase.Number -eq 9.5) {
                    Write-Host "  [Phase 9.5] $($buildPhase.File) not found. Skipping." -ForegroundColor DarkGray
                    continue
                }
                throw "Phase script not found: $phaseFile"
            }
            if (Get-Command -Name Invoke-WinEasePluginHook -ErrorAction SilentlyContinue) {
                Invoke-WinEasePluginHook -Phase $phaseId -Stage Before -DryRun:$isDryRunMode
            }
            . $phaseFile
            if (Get-Command -Name Invoke-WinEasePluginHook -ErrorAction SilentlyContinue) {
                Invoke-WinEasePluginHook -Phase $phaseId -Stage After -DryRun:$isDryRunMode
            }
        } catch {
            # Record the exception and the phase (secrets masked), tell the window, then let the outer
            # handler run the normal failure path: the error is never swallowed.
            Register-WinEaseBuildFailure -ErrorRecord $_
            throw
        }
    }
    # F3: close out the final phase and persist the complete timings table. No
    # Enter-Phase 19 will ever arrive to record Phase 18, and the snapshot written
    # inside 18-iso.ps1 was taken while the phase was still running.
    Exit-Phase
    Save-WinEasePhaseTimings

} catch {
  if (Test-WinEaseCancelException -ErrorRecord $_) {
    # Cancel at a phase boundary (D2): not a failure. The finally block below runs the normal cleanup
    # (unmount with discard, unload hives, detach VHDX, dismount ISO, remove the Defender exclusion).
    $script:BuildSucceeded = $false
    $isoCreatedSuccessfully = $false
    $script:BuildCancelled = $true
    Write-Host ""
    Write-Host "Cancel requested: stopping before Phase $($script:CurrentPhase + 1). Running cleanup..." -ForegroundColor Yellow
    Send-WinEaseGuiState -State 'Cancelling'
    Send-WinEaseGuiLogLine -Text 'Cancel requested: stopping at a safe point and cleaning up.'
    if ($script:DiagnosticData) { $script:DiagnosticData.FailurePhase = "Cancelled before the next phase (after $($script:CurrentBuildPhase))" }
  } else {
    # Outer catch block: Reset success flags, record diagnostics, re-throw (Rule 16)
    $script:BuildSucceeded = $false
    $isoCreatedSuccessfully = $false
    Register-WinEaseBuildFailure -ErrorRecord $_
    if ($script:DiagnosticData) {
        $script:DiagnosticData.BuildSucceeded = $false
        $script:DiagnosticData.FailureMessage = Hide-WinEaseSecretText -Text "$_"
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $script:DiagnosticData.FailureStackTrace = Hide-WinEaseSecretText -Text "$($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)"
        } else {
            $script:DiagnosticData.FailureStackTrace = Hide-WinEaseSecretText -Text "$($_.ScriptStackTrace)"
        }
        Write-WinEaseDiagnosticReport "Build failed with exception"
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host "   WinEase BUILD FAILED!                                  " -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host "Build failed with unhandled exception: $(Hide-WinEaseSecretText -Text "$_")" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host "Exception location: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    }
    if ($_.ScriptStackTrace) {
        Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
    throw
  }
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
            try { [void](Unmount-RegistryHiveWithRetry -Name $_) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
        $script:HivesLoaded = $false
    }

    # 2. ALWAYS unmount lingering DISM mounts across all allocated mount directories (Rule 17)
    $allTargetMounts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($script:AllocatedMountDirs) {
        foreach ($d in $script:AllocatedMountDirs) { [void]$allTargetMounts.Add($d) }
    }
    if ($scratchDir) {
        try { [void]$allTargetMounts.Add((ConvertTo-WinEaseNormalizedPath -Path $scratchDir)) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    if ($vhdxMountDir -and (-not $script:IsVhdxMounted)) {
        try { [void]$allTargetMounts.Add((ConvertTo-WinEaseNormalizedPath -Path $vhdxMountDir)) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    foreach ($mPath in $allTargetMounts) {
        if ($script:PreservedMountDirs -and $script:PreservedMountDirs.Contains($mPath)) {
            Write-Warning "Mount directory '$mPath' is marked as Preserved. Skipping cleanup."
            continue
        }

        try {
            $activeMounts = @(Get-WinEaseMountedImages)
            $lingeringMount = $activeMounts | Where-Object {
                $p = if ($_.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $_.Path } catch { $null } } else { $null }
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
            $dpDetachFile = Join-Path -Path $env:TEMP -ChildPath "WinEase_dp_detach_$($script:BuildId)_$([System.IO.Path]::GetRandomFileName()).txt"
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

    # 4. ALWAYS dismount source ISO if mounted by WinEase (Rule 17)
    if ($script:MountedIso) {
        Write-Host "Dismounting source Windows 11 ISO..." -ForegroundColor Cyan
        try {
            Dismount-DiskImage -ImagePath $script:MountedIso.ImagePath -ErrorAction SilentlyContinue > $null
            $script:MountedIso = $null
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    # 5. ALWAYS remove Windows Defender temporary workspace exclusion (Rule 17)
    if ($script:DefenderExclusionAdded -and $baseWorkDir) {
        try {
            Remove-MpPreference -ExclusionPath $baseWorkDir -ErrorAction SilentlyContinue
            $script:DefenderExclusionAdded = $false
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    # 5b. After a cancel: report what the cleanup left behind, so 'Cancelled' is never claimed over a half-cleaned state
    $script:CancelCleanupProblems = @()
    if ($script:BuildCancelled) {
        $lingeringMountList = [System.Collections.Generic.List[string]]::new()
        foreach ($mPath in $allTargetMounts) {
            try {
                foreach ($am in @(Get-WinEaseMountedImages)) {
                    $ap = if ($am.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $am.Path } catch { $null } } else { $null }
                    if ($ap -and ($ap -ieq $mPath)) { $lingeringMountList.Add($mPath) }
                }
            } catch { $lingeringMountList.Add("$mPath (status could not be read)") }
        }
        $stillLoadedHives = @(@('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | Where-Object { Test-Path -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$_" })
        $script:CancelCleanupProblems = Get-WinEaseCancelCleanupProblems -LoadedHives $stillLoadedHives -LingeringMounts $lingeringMountList `
            -VhdxStillAttached ([bool]$script:IsVhdxMounted) -IsoStillMounted ([bool]$script:MountedIso)
        if ($script:DiagnosticData) {
            $script:DiagnosticData['Cancelled'] = $true
            $script:DiagnosticData['CancelCleanupProblems'] = @($script:CancelCleanupProblems)
        }
    }

    # 5c. P1-02: Check for cleanup residues and generate explicit remediation commands on failure or cancel
    if ($script:BuildCancelled -or -not $script:BuildSucceeded) {
        $lingeringMountListAll = [System.Collections.Generic.List[string]]::new()
        foreach ($mPath in $allTargetMounts) {
            try {
                foreach ($am in @(Get-WinEaseMountedImages)) {
                    $ap = if ($am.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $am.Path } catch { $null } } else { $null }
                    if ($ap -and ($ap -ieq $mPath)) { $lingeringMountListAll.Add($mPath) }
                }
            } catch { $lingeringMountListAll.Add("$mPath (status could not be read)") }
        }
        $stillLoadedHivesAll = @(@('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') | Where-Object { Test-Path -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$_" })
        if (Get-Command -Name Get-WinEaseCleanupRemediation -ErrorAction SilentlyContinue) {
            $cleanupRemediations = Get-WinEaseCleanupRemediation -LoadedHives $stillLoadedHivesAll -LingeringMounts $lingeringMountListAll `
                -VhdxStillAttached ([bool]$script:IsVhdxMounted) -VhdxPath "$vhdxPath" `
                -IsoStillMounted ([bool]$script:MountedIso) -IsoPath $(if ($script:MountedIso) { "$($script:MountedIso.ImagePath)" } else { '' })
            if ($script:DiagnosticData) {
                $script:DiagnosticData['CleanupRemediations'] = @($cleanupRemediations)
            }
            if ($cleanupRemediations.Count -gt 0) {
                Write-Host ""
                Write-Host "Leftover resources detected. Remediation commands:" -ForegroundColor Yellow
                foreach ($rem in $cleanupRemediations) {
                    Write-Host "  - [$($rem.Type)] $($rem.Target): $($rem.Remediation)" -ForegroundColor White
                }
            }
        }
    }

    # 6. Disk deletion: ONLY IF ALL SAFETY CONDITIONS MET
    $destWimBackupPath = if ($baseWorkDir) { Join-Path -Path $baseWorkDir -ChildPath "install_pre_export_backup_$($script:BuildId).wim" } else { $null }
    $canDeleteWorkspace = Test-CanSafelyDeleteDirectory -Path $WinEaseDir -ExpectedBaseDir $baseWorkDir -PreservedDirs $script:PreservedMountDirs

    if ($script:BuildSucceeded -and $canDeleteWorkspace) {
        Write-Host "Build succeeded and safety checks passed. Cleaning workspace artifacts..." -ForegroundColor Cyan

        # Clean backup WIM outside ISO tree
        if ($destWimBackupPath -and (Test-Path -LiteralPath $destWimBackupPath)) {
            Remove-Item -LiteralPath $destWimBackupPath -Force -ErrorAction SilentlyContinue
        }

        # Clean WinEaseDir (fast path first: reparse prune + robocopy /B + rd). Previously this used
        # Reset-DirectoryWithRobocopy, whose per-item ACL pass took ~5 hours on 100k-file trees.
        if ($WinEaseDir -and (Test-Path -LiteralPath $WinEaseDir)) {
            $swClean = [System.Diagnostics.Stopwatch]::StartNew()
            $cleanOk = Remove-WinEaseTreeRobust -Path $WinEaseDir -SafetyRoot $baseWorkDir -AllowLockedFallback
            $swClean.Stop()
            if ($cleanOk) {
                Write-Host "  - ISO workspace cleanup: removed ($([math]::Round($swClean.Elapsed.TotalSeconds,1))s)" -ForegroundColor DarkGray
            } else {
                Write-Warning "ISO workspace cleanup incomplete: $WinEaseDir"
            }
        }

        # Clean target mount directories only if individual safety checks pass
        foreach ($mPath in $allTargetMounts) {
            if (Test-CanSafelyDeleteDirectory -Path $mPath -ExpectedBaseDir $baseWorkDir -PreservedDirs $script:PreservedMountDirs) {
                $swMount = [System.Diagnostics.Stopwatch]::StartNew()
                $mountOk = Remove-WinEaseTreeRobust -Path $mPath -SafetyRoot $baseWorkDir -AllowLockedFallback
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
                    try { & mountvol.exe "$vhdxMountDir" /D > $null 2>&1 } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
                    try { [System.IO.Directory]::Delete($vhdxMountDir, $false) } catch { try { $rpCheck.Delete() } catch { Write-Verbose "Ignored: $($_.Exception.Message)" } }
                } else {
                    if (Test-CanSafelyDeleteDirectory -Path $vhdxMountDir -ExpectedBaseDir $baseWorkDir -PreservedDirs $script:PreservedMountDirs) {
                        [void](Remove-WinEaseTreeRobust -Path $vhdxMountDir -SafetyRoot $baseWorkDir -AllowLockedFallback)
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
        if ($WinEaseDir -and (Test-Path -LiteralPath $WinEaseDir)) {
            Write-Host "  - ISO Workspace:     $WinEaseDir" -ForegroundColor Yellow
            $script:DiagnosticData.PreservedArtifacts += $WinEaseDir
            $finalWimPath = Join-Path -Path "$WinEaseDir\sources" -ChildPath "install.wim"
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
        Write-WinEaseDiagnosticReport "Artifacts preserved after build failure or unverified state"
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

    # 8. Release global mutex guard (C-H2: release only when this process actually
    # owns the mutex - the same HasMutex rule the batch-queue path already used.
    # ReleaseMutex on a mutex the thread does not own throws ApplicationException.)
    if ($script:BuildMutex) {
        try {
            if ($script:HasMutex) { $script:BuildMutex.ReleaseMutex() }
            $script:BuildMutex.Dispose()
            $script:BuildMutex = $null
            $script:HasMutex = $false
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    if (Get-Command -Name Close-WinEaseGuiProgress -ErrorAction SilentlyContinue) {
        # Success is reported as verified only when phase 15 (deep apply) AND phase 18 (ISO payload hash)
        # really passed; an existing ISO file alone is not a result.
        $doneLog = if ($transcriptPath) { [string]$transcriptPath } elseif ($script:BuildFailureData) { [string]$script:BuildFailureData.LogPath } else { '' }
        $doneReport = if ($script:BuildSucceeded -and $script:BuildReportPath) { [string]$script:BuildReportPath } elseif ($script:DiagDir) { Join-Path -Path $script:DiagDir -ChildPath 'build_diagnostic_summary.txt' } else { '' }
        $doneData = New-WinEaseDoneData -BuildSucceeded ([bool]$script:BuildSucceeded) -PayloadVerified $script:FinalPayloadVerified -IsoVerified $script:IsoPayloadVerified `
            -Failure $script:BuildFailureData -LogPath $doneLog -ReportPath $doneReport -OutputPath ([string]$script:BuildOutputIsoPath) `
            -DiagnosticsPath ([string]$script:DiagDir) -DocsPath (Join-Path -Path $scriptDir -ChildPath 'docs\KNOWN_ISSUES.md') `
            -Cancelled ([bool]$script:BuildCancelled) -CleanupProblems @($script:CancelCleanupProblems)
        Send-WinEaseGuiState -State $doneData.State
        Close-WinEaseGuiProgress -Success ([bool]$script:BuildSucceeded) -Message $(if ($script:BuildSucceeded) { 'WinEase.iso is ready.' } else { "$script:DiagDir" }) -Extra $doneData
    }
    if ($script:BuildCancelled) {
        if (@($script:CancelCleanupProblems).Count -eq 0) {
            Write-Host "Build cancelled. Cleanup completed. Partly built files stay in the work folder (see docs\KNOWN_ISSUES.md)." -ForegroundColor Yellow
        } else {
            Write-Host "Build cancelled, but the cleanup did not finish:" -ForegroundColor Red
            foreach ($cp in $script:CancelCleanupProblems) { Write-Host "  - $cp" -ForegroundColor Red }
            Write-Host "See docs\KNOWN_ISSUES.md ('Cancelling and interrupted builds') before building again." -ForegroundColor Red
        }
    } elseif ($script:BuildSucceeded) {
        Write-Host "Done! WinEase.iso is ready." -ForegroundColor Green
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

# Distinct exit code for a cancelled build (0 = success, 1 = failure, 3 = cancelled and cleaned up).
# A cancel whose cleanup failed is a failure (1).
if ($script:BuildCancelled) {
    if (@($script:CancelCleanupProblems).Count -eq 0) { exit $script:WinEaseCancelExitCode }
    exit 1
}

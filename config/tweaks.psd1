# nano11 settings - the single source of truth for every tweak and component setting.
#
# nano11builder.ps1 derives from this file:
#   Tweaks     -> $script:AllTweakDefs (GUI tabs 2-5, -TweakSettings, profile keys),
#                 $script:TweakKeyAliases (Aliases), $script:TweakVariableMap (Variable)
#   Components -> $script:Nano11ProfileKeys (profile key order), Apply-ProfileSettings,
#                 Get-Nano11CurrentConfig, the CLI switch block, the GUI "Services & Apps"
#                 tab (Gui) and the GUI session hand-off
#   CliBindings -> the paired Keep/Remove-style CLI switches (see the section comment)
#
# Tweak fields:
#   Key          setting name used in profiles, presets, CLI and the GUI
#   Category     GUI tab: Security | Privacy | Performance | UI
#   Default      value when no profile/preset overrides it
#   Description  GUI checkbox text and tooltip
#   Aliases      legacy key names still accepted from profiles and -TweakSettings (optional)
#   Variable     phases read this script variable instead of Test-TweakEnabled '<Key>' (optional)
#   CliSwitch    $true when nano11builder.ps1 has a [switch] parameter named <Key> (optional)
#
# Component fields:
#   Key          setting name used in profiles, presets and the GUI
#   Variable     script variable the build reads (empty for Type = Special)
#   Type         Bool | String | Special (Special keys are handled by hand in nano11builder.ps1)
#   Default      value Apply-ProfileSettings uses when a profile omits the key
#                (omitted = Apply-ProfileSettings leaves the variable alone)
#   CliSwitch    $true when a [switch] parameter named <Key> sets the variable directly (optional)
#   Gui          @{ Order; Text; Description; Default } - checkbox on the GUI "Services & Apps"
#                tab, sorted by Order (optional)
@{
    Tweaks = @(
        # Security
        @{ Key = 'BypassHardwareRequirements'; Category = 'Security'; Default = $true; Description = 'Bypass TPM 2.0, SecureBoot, RAM, CPU and Storage checks'; Aliases = @('BypassRequirements'); CliSwitch = $true }
        @{ Key = 'BypassNetworkRequirement'; Category = 'Security'; Default = $true; Description = 'Bypass mandatory OOBE internet connection requirement'; CliSwitch = $true }
        @{ Key = 'BypassNRO'; Category = 'Security'; Default = $true; Description = 'Enable BypassNRO registry policy for local account creation'; CliSwitch = $true }
        @{ Key = 'BypassActivationRestrictions'; Category = 'Security'; Default = $true; Description = 'Unlock personalization, suppress watermarks and licensing nags'; Variable = 'bypassActivationRestrictions'; CliSwitch = $true }
        @{ Key = 'DisableUAC'; Category = 'Security'; Default = $false; Description = 'Disable User Account Control (UAC) consent prompts'; CliSwitch = $true }
        @{ Key = 'DisableSmartScreen'; Category = 'Security'; Default = $false; Description = 'Disable SmartScreen filter for apps and downloads'; CliSwitch = $true }
        @{ Key = 'DisableVBS'; Category = 'Security'; Default = $false; Description = 'Disable Virtualization-Based Security (VBS / Core Isolation)'; CliSwitch = $true }
        @{ Key = 'DisableWPBT'; Category = 'Security'; Default = $false; Description = 'Disable Windows Platform Binary Table (OEM backdoor prevention)'; CliSwitch = $true }
        @{ Key = 'PreventDeviceEncryption'; Category = 'Security'; Default = $false; Description = 'Prevent automatic BitLocker device encryption on OOBE'; CliSwitch = $true }
        @{ Key = 'DisableCPUMitigations'; Category = 'Security'; Default = $false; Description = 'Disable Spectre/Meltdown CPU mitigations for raw throughput'; Variable = 'disableCPUMitigations'; CliSwitch = $true }
        @{ Key = 'ConfigureWinlogon'; Category = 'Security'; Default = $true; Description = 'Allow blank-password local logon and pre-configure the Winlogon auto-logon account'; CliSwitch = $true }
        @{ Key = 'EnableScripts'; Category = 'Security'; Default = $true; Description = 'Relax the PowerShell script execution policy to RemoteSigned'; CliSwitch = $true }

        # Privacy
        @{ Key = 'DisableCopilot'; Category = 'Privacy'; Default = $true; Description = 'Disable Windows Copilot AI integration'; CliSwitch = $true }
        @{ Key = 'DisableWebSearch'; Category = 'Privacy'; Default = $true; Description = 'Disable Bing web search in Start Menu'; CliSwitch = $true }
        @{ Key = 'DisableWidgets'; Category = 'Privacy'; Default = $true; Description = 'Disable Windows Widgets board and news feed'; CliSwitch = $true }
        @{ Key = 'DisableCrossDevice'; Category = 'Privacy'; Default = $true; Description = 'Disable Cross Device Experience Host (Phone Link)'; CliSwitch = $true }
        @{ Key = 'DisableAdvertisingId'; Category = 'Privacy'; Default = $true; Description = 'Disable targeted Advertising Identifier'; CliSwitch = $true }
        @{ Key = 'DisableErrorReporting'; Category = 'Privacy'; Default = $true; Description = 'Disable Windows Error Reporting (WER)'; CliSwitch = $true }
        @{ Key = 'DisableIMETelemetry'; Category = 'Privacy'; Default = $true; Description = 'Opt out of cloud IME learning data collection'; CliSwitch = $true }
        @{ Key = 'DisableCloudContent'; Category = 'Privacy'; Default = $true; Description = 'Disable cloud consumer features and promoted apps'; CliSwitch = $true }
        @{ Key = 'DisableAppPrivacy'; Category = 'Privacy'; Default = $true; Description = 'Restrict background access to location, mic, and contacts'; CliSwitch = $true }
        @{ Key = 'DisableTelemetryAndDiagnostics'; Category = 'Privacy'; Default = $true; Description = 'Set telemetry to 0 (Security) and stop DiagTrack service'; Aliases = @('DisableTelemetry'); CliSwitch = $true }
        @{ Key = 'DisableDefenderSecurityCenter'; Category = 'Privacy'; Default = $true; Description = 'Hide Security Center systray notifications'; CliSwitch = $true }
        @{ Key = 'DisableCortana'; Category = 'Privacy'; Default = $true; Description = 'Disable Cortana digital assistant'; CliSwitch = $true }
        @{ Key = 'DisableActivityHistory'; Category = 'Privacy'; Default = $true; Description = 'Disable User Activity tracking and synchronization'; CliSwitch = $true }
        @{ Key = 'DisableTimeline'; Category = 'Privacy'; Default = $true; Description = 'Disable Windows Timeline feature'; CliSwitch = $true }
        @{ Key = 'DisableDiagnosticData'; Category = 'Privacy'; Default = $true; Description = 'Disable diagnostic feedback and sample submissions'; CliSwitch = $true }
        @{ Key = 'DisableWindowsAI'; Category = 'Privacy'; Default = $true; Description = 'Disable Windows AI, Recall and Click-To-Do policies'; CliSwitch = $true }
        @{ Key = 'DisableDeliveryOptimization'; Category = 'Privacy'; Default = $true; Description = 'Disable Delivery Optimization P2P upload'; CliSwitch = $true }

        # Performance
        @{ Key = 'DisableFTH'; Category = 'Performance'; Default = $true; Description = 'Disable Fault Tolerant Heap to reduce gaming latency'; CliSwitch = $true }
        @{ Key = 'DisablePCA'; Category = 'Performance'; Default = $true; Description = 'Disable Program Compatibility Assistant'; CliSwitch = $true }
        @{ Key = 'RadicalRAM'; Category = 'Performance'; Default = $true; Description = 'Radical RAM optimization targeting sub-1.6GB idle memory'; Variable = 'radicalRAM'; CliSwitch = $true }
        @{ Key = 'TuneMemoryAndPaging'; Category = 'Performance'; Default = $true; Description = 'Skip clearing the pagefile on shutdown and keep standard system cache'; CliSwitch = $true }
        @{ Key = 'GamingNetworkTweaks'; Category = 'Performance'; Default = $true; Description = 'Disable multimedia network throttling and MSMQ Nagle (TCPNoDelay)'; CliSwitch = $true }
        @{ Key = 'LowLatencyAudioMMCSS'; Category = 'Performance'; Default = $true; Description = 'Optimize MMCSS thread scheduling for low audio jitter'; Aliases = @('DAWMode'); CliSwitch = $true }
        @{ Key = 'DisableBackgroundApps'; Category = 'Performance'; Default = $true; Description = 'Disable background execution of UWP apps'; CliSwitch = $true }
        @{ Key = 'DisableGameDVR'; Category = 'Performance'; Default = $true; Description = 'Disable GameDVR background video recording'; CliSwitch = $true }
        @{ Key = 'DisableSuperfetch'; Category = 'Performance'; Default = $true; Description = 'Disable SysMain (Superfetch) service for NVMe/SSD'; CliSwitch = $true }
        @{ Key = 'DisableWindowsSearchIndexing'; Category = 'Performance'; Default = $true; Description = 'Disable Windows Search indexing service (WSearch)'; Aliases = @('DisableSearchIndex'); CliSwitch = $true }
        @{ Key = 'DisableFastStartup'; Category = 'Performance'; Default = $false; Description = 'Disable Fast Startup to guarantee clean reboots'; CliSwitch = $true }
        @{ Key = 'DisableMemCompression'; Category = 'Performance'; Default = $true; Description = 'Disable in-memory paging compression'; Variable = 'disableMemCompression'; CliSwitch = $true }
        @{ Key = 'NoKernelPaging'; Category = 'Performance'; Default = $true; Description = 'Lock NT kernel executive in physical RAM'; Variable = 'noKernelPaging'; CliSwitch = $true }
        @{ Key = 'DisableUSBSuspend'; Category = 'Performance'; Default = $true; Description = 'Disable selective USB power suspend'; Variable = 'disableUSBSuspend'; CliSwitch = $true }
        @{ Key = 'NoHypervisor'; Category = 'Performance'; Default = $true; Description = 'Set hypervisorlaunchtype to Off for bare-metal performance'; Variable = 'noHypervisor'; CliSwitch = $true }
        @{ Key = 'DisablePowerThrottling'; Category = 'Performance'; Default = $true; Description = 'Disable Windows power throttling'; CliSwitch = $true }
        @{ Key = 'EnableHAGS'; Category = 'Performance'; Default = $true; Description = 'Enable Hardware-Accelerated GPU Scheduling'; CliSwitch = $true }
        @{ Key = 'NtfsDisable8dot3'; Category = 'Performance'; Default = $true; Description = 'Disable NTFS 8.3 short names and last-access timestamp updates'; CliSwitch = $true }
        @{ Key = 'ThreadDpcEnable'; Category = 'Performance'; Default = $false; Description = 'Enable DPC thread tweaking and foreground quantum scheduling'; CliSwitch = $true }
        @{ Key = 'NetworkTuning'; Category = 'Performance'; Default = $false; Description = 'Tune TCP timeouts, port range, TTL and DNS behaviour'; CliSwitch = $true }
        @{ Key = 'DisableIdleMaintenance'; Category = 'Performance'; Default = $false; Description = 'Disable Windows scheduled idle maintenance'; CliSwitch = $true }
        @{ Key = 'SvcHostConsolidation'; Category = 'Performance'; Default = $false; Description = 'Consolidate svchost processes to reduce idle RAM'; CliSwitch = $true }

        # UI
        @{ Key = 'EnableClassicContextMenu'; Category = 'UI'; Default = $true; Description = 'Restore classic Windows 10 style full context menus'; CliSwitch = $true }
        @{ Key = 'EnableDarkTheme'; Category = 'UI'; Default = $true; Description = 'Enable system-wide Dark Theme for apps and system'; CliSwitch = $true }
        @{ Key = 'ShowFileExtensions'; Category = 'UI'; Default = $true; Description = 'Show file extensions in File Explorer'; CliSwitch = $true }
        @{ Key = 'ShowHiddenFiles'; Category = 'UI'; Default = $false; Description = 'Show hidden files and folders in File Explorer'; CliSwitch = $true }
        @{ Key = 'LaunchToThisPC'; Category = 'UI'; Default = $true; Description = 'Open File Explorer to This PC instead of Home'; CliSwitch = $true }
        @{ Key = 'TaskbarEndTask'; Category = 'UI'; Default = $true; Description = 'Enable End Task on taskbar right-click context menu'; CliSwitch = $true }
        @{ Key = 'TaskbarAlignLeft'; Category = 'UI'; Default = $true; Description = 'Align Start button and taskbar icons to the left'; CliSwitch = $true }
        @{ Key = 'HideMeetNow'; Category = 'UI'; Default = $true; Description = 'Hide Meet Now icon from taskbar'; CliSwitch = $true }
        @{ Key = 'HideSyncNotifications'; Category = 'UI'; Default = $true; Description = 'Hide sync provider notifications in File Explorer'; CliSwitch = $true }
        @{ Key = 'HideRecommendedSection'; Category = 'UI'; Default = $true; Description = 'Hide Recommended section in Start Menu'; CliSwitch = $true }
        @{ Key = 'HideSearchBox'; Category = 'UI'; Default = $true; Description = 'Hide the taskbar search box'; CliSwitch = $true }
        @{ Key = 'MenuShowDelayZero'; Category = 'UI'; Default = $true; Description = 'Remove the hover delay on Start menu entries'; CliSwitch = $true }
        @{ Key = 'DisableStartupSound'; Category = 'UI'; Default = $true; Description = 'Disable Windows startup audio chime'; CliSwitch = $true }
        @{ Key = 'DisableLockScreen'; Category = 'UI'; Default = $false; Description = 'Skip lock screen directly to login prompt'; CliSwitch = $true }
        @{ Key = 'DisableSleepOption'; Category = 'UI'; Default = $false; Description = 'Remove Sleep option from power menu'; CliSwitch = $true }
        @{ Key = 'DisableBSODEmoticon'; Category = 'UI'; Default = $false; Description = 'Remove sad face emoticon from BSOD crash screen'; CliSwitch = $true }
        @{ Key = 'EnableLongPaths'; Category = 'UI'; Default = $true; Description = 'Enable Win32 long paths (> 260 characters)'; CliSwitch = $true }
        @{ Key = 'TransparentShortcutOverlay'; Category = 'UI'; Default = $false; Description = 'Remove shortcut arrow icon overlay on desktop icons'; CliSwitch = $true }
        @{ Key = 'PhotoViewerAssociations'; Category = 'UI'; Default = $true; Description = 'Restore classic Windows Photo Viewer file associations'; CliSwitch = $true }
        @{ Key = 'TakeOwnershipContextMenu'; Category = 'UI'; Default = $true; Description = 'Add Take Ownership right-click context menu'; CliSwitch = $true }
        @{ Key = 'CmdAsAdminContextMenu'; Category = 'UI'; Default = $true; Description = 'Add Command Prompt as Administrator to context menu'; CliSwitch = $true }
        @{ Key = 'OptimizeVisualEffects'; Category = 'UI'; Default = $true; Description = 'Optimize visual effects for maximum performance'; CliSwitch = $true }
        @{ Key = 'CleanContextMenus'; Category = 'UI'; Default = $true; Description = 'Hide Share, Give access to and Cast to Device context menu entries'; CliSwitch = $true }
    )

    Components = @(
        @{ Key = 'RemoveDefender'; Variable = 'removeDefender'; Type = 'Bool'; Default = $true; Gui = @{ Order = 1; Text = 'Remove Windows Defender & Security UI'; Description = 'Disable and remove Defender AV, Security Center UI and background scanning'; Default = $true } }
        @{ Key = 'KeepAsianIME'; Variable = 'keepAsianIME'; Type = 'Bool'; Default = $true; Gui = @{ Order = 2; Text = 'Keep Asian IMEs (Japanese, Korean, Chinese)'; Description = 'Preserve MS-IME and regional input method components'; Default = $true } }
        @{ Key = 'KeepExtraFonts'; Variable = 'keepExtraFonts'; Type = 'Bool'; Default = $true; Gui = @{ Order = 3; Text = 'Keep Extra International & Regional Fonts'; Description = 'Preserve supplementary international fonts'; Default = $true } }
        @{ Key = 'RemoveDrivers'; Variable = 'removeDrivers'; Type = 'Bool'; Default = $false; Gui = @{ Order = 4; Text = 'Remove Legacy Storage & Network Drivers'; Description = 'Prune obsolete legacy floppy, modem, and tape drivers'; Default = $false } }
        @{ Key = 'DisableWindowsUpdate'; Variable = 'disableWU'; Type = 'Bool'; Default = $true; Gui = @{ Order = 5; Text = 'Disable Automatic Windows Update'; Description = 'Prevent automated background patching and driver updates'; Default = $true } }
        @{ Key = 'KeepBluetooth'; Variable = 'keepBT'; Type = 'Bool'; Default = $true; Gui = @{ Order = 6; Text = 'Keep Bluetooth Services & Peripheral Stack'; Description = 'Preserve Bluetooth audio, keyboard, and peripheral connectivity'; Default = $true } }
        @{ Key = 'WSLSupport'; Variable = 'wslSupport'; Type = 'Bool'; Default = $false; Gui = @{ Order = 7; Text = 'Enable WSL2 & Virtual Machine Platform'; Description = 'Pre-enable WSL2 subsystem and virtual machine components'; Default = $false } }
        @{ Key = 'KeepRecoveryEnv'; Variable = 'keepRecoveryEnv'; Type = 'Bool'; Default = $false; Gui = @{ Order = 8; Text = 'Keep Recovery Environment (WinRE)'; Description = 'Preserve WinRE recovery image partition'; Default = $false } }
        @{ Key = 'SafeDebloatMode'; Variable = 'safeDebloatMode'; Type = 'Bool'; Default = $true; Gui = @{ Order = 19; Text = 'Safe WinSxS Component Store Debloat'; Description = 'Maintain WinSxS component consistency to prevent 0x80070570 setup errors'; Default = $true } }
        @{ Key = 'UltraSlimMode'; Variable = 'ultraSlimMode'; Type = 'Bool'; Default = $true; Gui = @{ Order = 20; Text = 'UltraSlim Mode (~3GB ISO Reduction Target)'; Description = 'Extensive pruning targeting minimal installation ISO size'; Default = $true } }
        @{ Key = 'SetJapaneseKeyboard'; Variable = 'setJapaneseKeyboard'; Type = 'Bool'; Default = $true; Gui = @{ Order = 12; Text = 'Configure Japanese 106/109 Keyboard Layout'; Description = 'Auto-configure keyboard hardware layout for Japanese 106/109 keys'; Default = $true } }
        @{ Key = 'AtlasReviOSMode'; Variable = 'atlasReviOSMode'; Type = 'Bool'; Default = $true; Gui = @{ Order = 13; Text = 'AtlasOS & ReviOS Low-Latency Kernel Tuning'; Description = 'Apply timer resolution, DPC and MMCSS low-latency optimizations'; Default = $true } }
        @{ Key = 'RemoveStore'; Variable = 'removeStore'; Type = 'Bool'; Default = $false; Gui = @{ Order = 9; Text = 'Remove Microsoft Store & Purchased UWP'; Description = 'Remove Store app package while keeping winget package manager'; Default = $false } }
        @{ Key = 'KeepBasicApps'; Variable = 'keepBasicApps'; Type = 'Bool'; Default = $false; Gui = @{ Order = 10; Text = 'Keep Basic Apps (Notepad, Paint, Calculator)'; Description = 'Preserve essential inbox utility applications'; Default = $false } }
        @{ Key = 'KeepSearchIndex'; Variable = 'keepSearchIndex'; Type = 'Bool'; Default = $false; Gui = @{ Order = 11; Text = 'Keep Windows Search Indexing Active'; Description = 'Keep WSearch indexing service running in background'; Default = $false } }
        @{ Key = 'KeepXboxServices'; Variable = 'keepXboxServices'; Type = 'Bool'; Default = $false; Gui = @{ Order = 14; Text = 'Keep Xbox Services & Gaming Overlay'; Description = 'Preserve Xbox identity, gaming overlay and Game Bar services'; Default = $false } }
        @{ Key = 'KeepAudioTweaks'; Variable = 'keepAudioTweaks'; Type = 'Bool'; Default = $true; Gui = @{ Order = 15; Text = 'Low-Latency Audio MMCSS Priority'; Description = 'Optimize multimedia class scheduler thread priority for low audio jitter'; Default = $true } }
        @{ Key = 'UseVHDX'; Variable = 'useVHDX'; Type = 'Bool'; Default = $false }
        @{ Key = 'RemoveLegacyFOD'; Variable = 'removeLegacyFOD'; Type = 'Bool'; Default = $true; CliSwitch = $true; Gui = @{ Order = 16; Text = 'Remove Legacy Optional Features (FOD)'; Description = 'Prune legacy Fax, XPS Viewer, WordPad and obsolete packages'; Default = $true } }
        @{ Key = 'TrimWallpapers'; Variable = 'trimWallpapers'; Type = 'Bool'; Default = $true; CliSwitch = $true; Gui = @{ Order = 17; Text = 'Trim Default Wallpapers & Screen Savers'; Description = 'Remove heavy high-res 4K background images to save image space'; Default = $true } }
        @{ Key = 'HibernateMode'; Variable = 'hibernateMode'; Type = 'String'; Default = 'Keep' }
        @{ Key = 'CrashDumpMode'; Variable = 'crashDumpMode'; Type = 'String'; Default = 'Automatic' }
        @{ Key = 'MMCSSGaming'; Variable = 'mmcssGaming'; Type = 'Bool'; Default = $false; CliSwitch = $true }
        @{ Key = 'DAWMode'; Variable = 'dawMode'; Type = 'Bool'; Default = $false; CliSwitch = $true }
        @{ Key = 'DisableFSE'; Variable = 'disableFSE'; Type = 'Bool'; Default = $false; CliSwitch = $true }
        @{ Key = 'NvidiaLowLatency'; Variable = 'nvidiaLowLatency'; Type = 'Bool'; Default = $false; CliSwitch = $true }
        @{ Key = 'RemoveWebViewPostOOBE'; Variable = 'removeWebViewPostOOBE'; Type = 'Bool'; Default = $false; CliSwitch = $true; Gui = @{ Order = 18; Text = 'Remove WebView2 Post-OOBE'; Description = 'Uninstall Edge WebView2 runtime after initial setup completes'; Default = $false } }
        @{ Key = 'FastExport'; Variable = 'fastExport'; Type = 'Bool'; Default = $false; CliSwitch = $true }
        @{ Key = 'UefiOnly'; Variable = 'uefiOnly'; Type = 'Bool'; Default = $false; CliSwitch = $true }
        @{ Key = 'CpuBoostMode'; Variable = 'cpuBoostMode'; Type = 'String'; Default = 'Default' }
        @{ Key = 'PowerPreset'; Variable = 'powerPreset'; Type = 'String'; Default = 'Default' }
        @{ Key = 'TweakGroups'; Variable = ''; Type = 'Special' }
        @{ Key = 'TweakSettings'; Variable = ''; Type = 'Special' }
        @{ Key = 'PayloadFormat'; Variable = ''; Type = 'Special' }
        @{ Key = 'SkipEiCfg'; Variable = 'SkipEiCfg'; Type = 'Bool' }
        @{ Key = 'NoPostInstallAssets'; Variable = 'NoPostInstallAssets'; Type = 'Bool' }
        @{ Key = 'SourceDrive'; Variable = 'SourceDrive'; Type = 'String' }
        @{ Key = 'WorkDir'; Variable = 'WorkDir'; Type = 'String' }
        @{ Key = 'Index'; Variable = 'Index'; Type = 'String' }
        @{ Key = 'ComputerName'; Variable = 'ComputerName'; Type = 'String' }
        @{ Key = 'UserName'; Variable = 'UserName'; Type = 'String' }
        @{ Key = 'AdvancedDebloatStandard'; Variable = ''; Type = 'Special' }
        @{ Key = 'AdvancedDebloatExperimental'; Variable = ''; Type = 'Special' }
        @{ Key = 'IncludeMigrationAssistant'; Variable = 'includeMigrationAssistant'; Type = 'Bool'; Default = $false; CliSwitch = $true; Gui = @{ Tab = 'Migration'; Order = 21; Text = 'Include Migration Assistant (PC-to-PC transfer tools)'; Description = 'Bundle the Nano11-Migrator tool into the image for post-install PC migration'; Default = $false } }
    )

    # CLI switch pairs nano11builder.ps1 applies in this order. For each entry the first
    # Switches group with a bound switch wins: the variable gets that switch's value
    # (negated when Invert), the Also variables are overridden, and Tag is recorded as
    # set from the command line. Names may include parameter aliases for readability;
    # $PSBoundParameters only ever holds the canonical name.
    CliBindings = @(
        @{ Tag = 'Xbox'; Variable = 'keepXboxServices'; Switches = @(
            @{ Names = @('KeepXboxServices') }
            @{ Names = @('RemoveXboxServices', 'NoXboxServices'); Invert = $true }) }
        @{ Tag = 'Audio'; Variable = 'keepAudioTweaks'; Switches = @(
            @{ Names = @('KeepAudioTweaks') }) }
        @{ Tag = 'Defender'; Variable = 'removeDefender'; Switches = @(
            @{ Names = @('KeepDefender', 'NoDefender'); Invert = $true }
            @{ Names = @('RemoveDefender') }) }
        @{ Tag = 'IME'; Variable = 'keepAsianIME'; Switches = @(
            @{ Names = @('KeepIME', 'KeepAsianIME') }
            @{ Names = @('RemoveIME', 'RemoveAsianIME', 'NoIME'); Invert = $true }) }
        @{ Tag = 'Fonts'; Variable = 'keepExtraFonts'; Switches = @(
            @{ Names = @('KeepFonts', 'KeepExtraFonts') }
            @{ Names = @('RemoveFonts', 'NoFonts'); Invert = $true }) }
        @{ Tag = 'Drivers'; Variable = 'removeDrivers'; Switches = @(
            @{ Names = @('RemoveDrivers') }
            @{ Names = @('KeepDrivers'); Invert = $true }) }
        @{ Tag = 'WindowsUpdate'; Variable = 'disableWU'; Switches = @(
            @{ Names = @('KeepWindowsUpdate', 'EnableWindowsUpdate'); Invert = $true }
            @{ Names = @('DisableWindowsUpdate', 'NoWindowsUpdate') }) }
        @{ Tag = 'Bluetooth'; Variable = 'keepBT'; Switches = @(
            @{ Names = @('DisableBluetooth', 'NoBluetooth'); Invert = $true }
            @{ Names = @('KeepBluetooth') }) }
        @{ Tag = 'WSL'; Variable = 'wslSupport'; Switches = @(
            @{ Names = @('EnableWSL') }
            @{ Names = @('DisableWSL', 'NoWSL'); Invert = $true }) }
        @{ Tag = 'Recovery'; Variable = 'keepRecoveryEnv'; Switches = @(
            @{ Names = @('KeepRecovery', 'KeepWinRE') }
            @{ Names = @('RemoveRecovery', 'RemoveWinRE', 'NoWinRE', 'NoRecovery'); Invert = $true }) }
        @{ Tag = 'WinSxS'; Variable = 'safeDebloatMode'; Switches = @(
            @{ Names = @('AggressiveWinSxS', 'TrimWinSxS'); Invert = $true }
            @{ Names = @('SafeDebloat', 'SafeWinSxS') }) }
        @{ Tag = 'UltraSlim'; Variable = 'ultraSlimMode'; Switches = @(
            @{ Names = @('UltraSlim') }
            @{ Names = @('NoUltraSlim'); Invert = $true }) }
        @{ Tag = 'JPKey'; Variable = 'setJapaneseKeyboard'; Switches = @(
            @{ Names = @('NoJapaneseKeyboard'); Invert = $true }
            @{ Names = @('JapaneseKeyboard') }) }
        @{ Tag = 'Atlas'; Variable = 'atlasReviOSMode'; Switches = @(
            @{ Names = @('NoAtlasReviOS'); Invert = $true }
            @{ Names = @('AtlasReviOS') }) }
        @{ Tag = 'Export'; Variable = 'exportESDMode'; Switches = @(
            @{ Names = @('ExportESD'); Also = @{ splitWIMMode = $false } }
            @{ Names = @('ExportWIM', 'NoESD'); Invert = $true }) }
        @{ Tag = 'SplitWIM'; Variable = 'splitWIMMode'; Switches = @(
            @{ Names = @('SplitWIM', 'FAT32Compatible', 'FAT32'); Also = @{ exportESDMode = $false } }
            @{ Names = @('NoSplitWIM'); Invert = $true }) }
        @{ Tag = 'Store'; Variable = 'removeStore'; Switches = @(
            @{ Names = @('RemoveStore', 'NoStore', 'RemoveMicrosoftStore') }
            @{ Names = @('KeepStore'); Invert = $true }) }
        @{ Tag = 'ActivationRestrictions'; Variable = 'bypassActivationRestrictions'; Switches = @(
            @{ Names = @('BypassActivationRestrictions', 'NoActivationRestrictions', 'UnlockPersonalization') }) }
        @{ Tag = 'RadicalRAM'; Variable = 'radicalRAM'; Switches = @(
            @{ Names = @('RadicalRAM', 'UltraLowRAM', 'LowRAM') }
            @{ Names = @('NoRadicalRAM'); Invert = $true }) }
        @{ Tag = 'VHDX'; Variable = 'useVHDX'; Switches = @(
            @{ Names = @('UseVHDX', 'FastVHDX', 'VHDX') }) }
    )
}

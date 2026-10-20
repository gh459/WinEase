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

        # --- Removal options (polarity: OFF = keep / nothing happens, ON = remove) -------
        # These replace the previously unconditional deletions. Every one of them used to
        # run on every build, so the user could not keep the affected component.
        @{ Key = 'RemoveHelpFiles'; Category = 'Privacy'; Default = $true; Description = 'Remove the Windows Help files folder'; CliSwitch = $true }
        @{ Key = 'RemoveEdge'; Category = 'Privacy'; Default = $true; Description = 'Remove the Edge browser (the WebView2 runtime is kept for OOBE)'; CliSwitch = $true }
        @{ Key = 'RemoveWindowsBackup'; Category = 'Privacy'; Default = $true; Description = 'Remove the Windows Backup app and its scheduled task'; CliSwitch = $true }
        @{ Key = 'RemoveWebExperienceHost'; Category = 'Privacy'; Default = $true; Description = 'Remove the Web Experience (Widgets) host app'; CliSwitch = $true }
        @{ Key = 'RemoveOfflineCacheFiles'; Category = 'Privacy'; Default = $true; Description = 'Clear build-time caches (Temp, Prefetch, Panther, event logs, Minidump)'; CliSwitch = $true }

        # --- Optional-feature / FoD removal options (OFF = keep) ----------------------
        # These used to be removed unconditionally on every build.
        @{ Key = 'RemoveRecall'; Category = 'Privacy'; Default = $true; Description = 'Disable and remove the Windows Recall optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveInternetExplorer'; Category = 'Privacy'; Default = $true; Description = 'Remove the Internet Explorer optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveWordPad'; Category = 'Privacy'; Default = $true; Description = 'Remove the WordPad optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveStepsRecorder'; Category = 'Privacy'; Default = $true; Description = 'Remove the Steps Recorder optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveSnippingTool'; Category = 'Privacy'; Default = $true; Description = 'Remove the Snipping Tool optional feature'; CliSwitch = $true }
        @{ Key = 'RemovePaint'; Category = 'Privacy'; Default = $true; Description = 'Remove the MS Paint optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveXpsViewer'; Category = 'Privacy'; Default = $true; Description = 'Remove the XPS Viewer optional feature'; CliSwitch = $true }
        @{ Key = 'RemovePowerShellISE'; Category = 'Privacy'; Default = $true; Description = 'Remove the Windows PowerShell ISE optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveOpenSSHClient'; Category = 'Privacy'; Default = $true; Description = 'Remove the OpenSSH client optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveHelloFace'; Category = 'Privacy'; Default = $true; Description = 'Remove the Hello Face optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveBitLockerFeature'; Category = 'Privacy'; Default = $true; Description = 'Remove the BitLocker Drive Encryption optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveNarratorApp'; Category = 'Privacy'; Default = $true; Description = 'Remove the Narrator optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveSearchEngineClient'; Category = 'Privacy'; Default = $true; Description = 'Remove the Search Engine Client optional feature'; CliSwitch = $true }
        @{ Key = 'RemovePrintingManagement'; Category = 'Privacy'; Default = $true; Description = 'Remove the printing management optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveWebcamExperience'; Category = 'Privacy'; Default = $true; Description = 'Remove the Webcam Experience optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveMediaPlayerFeature'; Category = 'Privacy'; Default = $true; Description = 'Remove the Media Player optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveWallpaperContent'; Category = 'Privacy'; Default = $true; Description = 'Remove the extended wallpaper content optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveMagnifierApp'; Category = 'Privacy'; Default = $true; Description = 'Remove the Magnifier optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveTabletPCMath'; Category = 'Privacy'; Default = $true; Description = 'Remove the Tablet PC Math optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveMpeg2Decoder'; Category = 'Privacy'; Default = $true; Description = 'Remove the MPEG-2 decoder optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveWmic'; Category = 'Privacy'; Default = $true; Description = 'Remove the WMIC optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveWirelessDisplay'; Category = 'Privacy'; Default = $true; Description = 'Remove the Wireless Display (Miracast) optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveSnmpClient'; Category = 'Privacy'; Default = $true; Description = 'Remove the SNMP client optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveTelnetClient'; Category = 'Privacy'; Default = $true; Description = 'Remove the Telnet client optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveSimpleTcpClient'; Category = 'Privacy'; Default = $true; Description = 'Remove the Simple TCP client optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveRdc'; Category = 'Privacy'; Default = $true; Description = 'Remove the Remote Desktop Connection client optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveFaxClient'; Category = 'Privacy'; Default = $true; Description = 'Remove the Fax client optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveUserExperienceVirt'; Category = 'Privacy'; Default = $true; Description = 'Remove the User Experience Virtualization optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveDeviceManagementEnt'; Category = 'Privacy'; Default = $true; Description = 'Remove the Device Management Enterprise optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveNotepad'; Category = 'Privacy'; Default = $true; Description = 'Remove the Notepad optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveMathRecognizer'; Category = 'Privacy'; Default = $true; Description = 'Remove the Math Recognizer optional feature'; CliSwitch = $true }
        @{ Key = 'RemovePrintingWfs'; Category = 'Privacy'; Default = $true; Description = 'Remove the Printing Workgroup Fax optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveKernelLA57'; Category = 'Privacy'; Default = $true; Description = 'Remove the Kernel LA57 optional feature'; CliSwitch = $true }
        @{ Key = 'RemoveTpmWmiProvider'; Category = 'Privacy'; Default = $true; Description = 'Remove the TPM WMI provider optional feature'; CliSwitch = $true }
        # Language packs. OFF = the pack is protected and stays in the image, ON = the pack
        # may be removed when the removal is requested (the Advanced Debloat item
        # "Remove non-Japanese language packs"). The language of the image is always kept.
        @{ Key = 'RemoveLanguageJaJP'; Category = 'Privacy'; Default = $false; Description = 'Allow removing the Japanese language pack'; CliSwitch = $true }
        @{ Key = 'RemoveLanguageKoKR'; Category = 'Privacy'; Default = $true; Description = 'Allow removing the Korean language pack'; CliSwitch = $true }
        @{ Key = 'RemoveLanguageZhCN'; Category = 'Privacy'; Default = $true; Description = 'Allow removing the Simplified Chinese language pack'; CliSwitch = $true }
        @{ Key = 'RemoveLanguageZhTW'; Category = 'Privacy'; Default = $true; Description = 'Allow removing the Traditional Chinese language pack'; CliSwitch = $true }

        # --- Post-install (first logon) options -----------------------------------------
        # These used to run unconditionally on the installed system. They are now bound to
        # individual options so that "keep" really keeps.
        @{ Key = 'EnableCompactOS'; Category = 'Performance'; Default = $true; Description = 'Enable CompactOS NTFS compression on the installed system'; CliSwitch = $true }
        @{ Key = 'EnableNtfs8dot3Disable'; Category = 'Performance'; Default = $true; Description = 'Disable NTFS 8.3 short names and last-access timestamp tracking'; CliSwitch = $true }
        @{ Key = 'EnableUltimatePerformancePower'; Category = 'Performance'; Default = $true; Description = 'Activate the Ultimate Performance power plan after setup'; CliSwitch = $true }
        @{ Key = 'EnableMsiMode'; Category = 'Performance'; Default = $true; Description = 'Enable Message Signaled Interrupts for detected PCI hardware'; CliSwitch = $true }
        @{ Key = 'DisableAccessibilityTools'; Category = 'Privacy'; Default = $false; Description = 'Block the on-screen keyboard, Narrator and Magnifier from launching (IFEO)'; CliSwitch = $true }
        @{ Key = 'DisableWindowsSearchProcess'; Category = 'Privacy'; Default = $true; Description = 'Stop the SearchHost background process after setup'; CliSwitch = $true }
        @{ Key = 'DisableComputerRestore'; Category = 'Privacy'; Default = $true; Description = 'Disable System Restore on the system drive after setup'; CliSwitch = $true }
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

    # Execution engine for every Advanced Debloat target.
    #
    # Each entry binds one logical target to the engine that removes it:
    #   PowerShell - the safe engine (DISM / service Start values / registry / file delete)
    #   Rust       - the forced physical engine (takes ownership and deletes the binaries)
    #
    # The invariants are enforced in phases\09-physical-debloat.ps1:
    #   * the target is not selected -> neither engine runs, nothing is touched
    #   * the target is selected     -> exactly the selected engine runs
    #   * engine "PowerShell"        -> the target is never handed to the Rust binary
    #   * engine "Rust"              -> the target is handed to the Rust binary and only
    #                                   that one key is dispatched
    #
    # Item      the exact English text of the list entry (the value phases\09 matches and
    #           the key config\dependencies.psd1 uses for the same target)
    # Engines   the engines that can remove the target
    # Default   the engine that runs when the user did not choose one
    # RustKey   the key the Rust binary understands (only set when Rust is possible)
    # Legacy    older list entries for the same target; they are still accepted in saved
    #           profiles and are mapped onto Item with the Rust engine
    # Execution engine for every Advanced Debloat target.
    #
    # Each entry binds one logical target to the engine that removes it:
    #   PowerShell - the safe engine (DISM / service Start values / registry / file delete)
    #   Rust       - the forced physical engine (takes ownership and deletes the binaries)
    #
    # The invariants are enforced in lib\WinEaseDebloat.ps1 and phases\09-physical-debloat.ps1:
    #   * the target is not selected -> neither engine runs, nothing is touched
    #   * the target is selected     -> exactly the selected engine runs
    #   * engine "PowerShell"        -> the target is never handed to the Rust binary
    #   * engine "Rust"              -> the target is handed to the Rust binary and only
    #                                   that one key is dispatched
    #
    # Item      the exact English text of the list entry (the value phases\09 matches and
    #           the key config\dependencies.psd1 uses for the same target)
    # Engines   the engines that can remove the target
    # Default   the engine that runs when the user did not choose one
    # RustKey   the key the Rust binary understands (only set when Rust is possible)
    # Phase     the phase that owns the target: it runs the safe work, so one work item
    #           has exactly one implementation (no second run in phase 09)
    # Legacy    older list entries for the same target; they are still accepted in saved
    #           profiles and are mapped onto Item with the Rust engine

    # What every option removes. The same option ID is used by the safe engine (the
    # phase that owns the target) and by the Rust engine (the physical key), so one
    # entry describes both sides of the option.
    #
    # FoDPackages   the servicing packages of the option (phase 06 removes them)
    Targets = @{
        'RemoveInternetExplorer' = @{ FoDPackages = @('Microsoft-Windows-InternetExplorer-Optional-Package~') }
        'RemoveMediaPlayerFeature' = @{ FoDPackages = @('Microsoft-Windows-MediaPlayer-Package~') }
        'RemoveWordPad' = @{ FoDPackages = @('Microsoft-Windows-WordPad-FoD-Package~') }
        'RemoveStepsRecorder' = @{ FoDPackages = @('Microsoft-Windows-StepsRecorder-Package~') }
        'RemovePaint' = @{ FoDPackages = @('Microsoft-Windows-MSPaint-FoD-Package~', 'Microsoft-Windows-Paint-FoD-Package~') }
        'RemoveSnippingTool' = @{ FoDPackages = @('Microsoft-Windows-SnippingTool-FoD-Package~') }
        'RemoveTabletPCMath' = @{ FoDPackages = @('Microsoft-Windows-TabletPCMath-Package~') }
        'RemoveXpsViewer' = @{ FoDPackages = @('Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~') }
        'RemovePowerShellISE' = @{ FoDPackages = @('Microsoft-Windows-PowerShell-ISE-FOD-Package~') }
        'RemoveOpenSSHClient' = @{ FoDPackages = @('OpenSSH-Client-Package~') }
        'RemoveSearchEngineClient' = @{ FoDPackages = @('Microsoft-Windows-Search-Engine-Client-Package~') }
        'RemoveHelloFace' = @{ FoDPackages = @('Microsoft-Windows-Hello-Face-Package~', 'Microsoft-Windows-Hello-BioEnrollment-Package~') }
        'RemoveBitLockerFeature' = @{ FoDPackages = @('Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~') }
        'RemoveTpmWmiProvider' = @{ FoDPackages = @('Microsoft-Windows-TPM-WMI-Provider-Package~') }
        'RemoveNarratorApp' = @{ FoDPackages = @('Microsoft-Windows-Narrator-App-Package~') }
        'RemoveMagnifierApp' = @{ FoDPackages = @('Microsoft-Windows-Magnifier-App-Package~') }
        'RemovePrintingManagement' = @{ FoDPackages = @('Microsoft-Windows-Printing-PMCPPC-FoD-Package~') }
        'RemoveWebcamExperience' = @{ FoDPackages = @('Microsoft-Windows-WebcamExperience-Package~') }
        'RemoveMpeg2Decoder' = @{ FoDPackages = @('Microsoft-Media-MPEG2-Decoder-Package~') }
        'RemoveWallpaperContent' = @{ FoDPackages = @('Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~') }
        'RemoveWmic' = @{ FoDPackages = @('Microsoft-Windows-WMIC-FoD-Package~') }
        'RemoveWirelessDisplay' = @{ FoDPackages = @('Microsoft-Windows-WirelessDisplay-FOD-Package~') }
        'RemoveSnmpClient' = @{ FoDPackages = @('Microsoft-Windows-SNMP-Client-Package~') }
        'RemoveTelnetClient' = @{ FoDPackages = @('Telnet-Client-Package~') }
        'RemoveSimpleTcpClient' = @{ FoDPackages = @('SimpleTCP-Client-Package~') }
        'RemoveRdc' = @{ FoDPackages = @('Microsoft-Windows-RDC-Package~') }
        'RemoveFaxClient' = @{ FoDPackages = @('Microsoft-Windows-Fax-Client-Package~') }
        'RemoveRecall' = @{ FoDPackages = @('Microsoft-Windows-Recall-FoD-Package~') }
        'RemoveUserExperienceVirt' = @{ FoDPackages = @('Microsoft-Windows-User-Experience-Virtualization-Package~') }
        'RemoveDeviceManagementEnt' = @{ FoDPackages = @('Microsoft-Windows-Device-Management-Enterprise-Package~') }
        'RemoveNotepad' = @{ FoDPackages = @('Microsoft-Windows-Notepad-FoD-Package~') }
        'RemoveMathRecognizer' = @{ FoDPackages = @('Microsoft-Windows-MathRecognizer-Package~') }
        'RemovePrintingWfs' = @{ FoDPackages = @('Microsoft-Windows-Printing-WFS-FoD-Package~') }
        'RemoveKernelLA57' = @{ FoDPackages = @('Microsoft-Windows-Kernel-LA57-FoD-Package~') }
    }
    DebloatEngines = @(
        # --- Standard targets (safe engine by default) ---
        @{ Item = 'Remove WinRE (reagentc /disable + file delete) [500-700MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '08-filesystem' }
        @{ Item = 'Remove PatchCache (dir delete) [200-500MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_patchcache'; Legacy = @('Physical: Installer cache PatchCache (complete removal) [varies]'); SupportsRustPhysical = $true; Phase = '08-filesystem' }
        @{ Item = 'Remove Delivery Optimization cache (dir delete) [100-500MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_delivery_optimization'; Legacy = @('Physical: Delivery Optimization (complete removal) [varies]'); SupportsRustPhysical = $true; Phase = '08-filesystem' }
        @{ Item = 'Remove non-Japanese language packs (DISM) [200-500MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod' }
        @{ Item = 'Remove non-essential fonts (file delete) [50-100MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '08-filesystem' }
        @{ Item = 'WinSxS cleanup (/StartComponentCleanup /ResetBase) [1-3GB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '09-winsxs' }
        @{ Item = 'Remove pagefile.sys (pagefile disable) [4-16GB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_pagefile'; Legacy = @('Physical: pagefile.sys (disable + delete) [4-16GB]'); SupportsRustPhysical = $true; Phase = '11-unattend' }
        @{ Item = 'Remove hiberfil.sys (powercfg /h off) [4-16GB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_hiberfil'; Legacy = @('Physical: hiberfil.sys (disable + delete) [4-16GB]'); SupportsRustPhysical = $true; Phase = '11-unattend' }
        @{ Item = 'Remove swapfile.sys (pagefile disable) [256MB-1GB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_swapfile'; Legacy = @('Physical: swapfile.sys (disable + delete) [256MB-1GB]'); SupportsRustPhysical = $true; Phase = '11-unattend' }
        @{ Item = 'Remove Provisioned AppX (list-based) [100-300MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '05-appx' }
        @{ Item = 'Remove Windows Media Player (component) [50-100MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_media_player'; Legacy = @('Physical: Windows Media Player (complete removal) [~50-100MB]'); SupportsRustPhysical = $true; Phase = '06-fod'  ; Option = 'RemoveMediaPlayerFeature' }
        @{ Item = 'Remove Remote Desktop host (service + binary) [30-50MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_rdp'; Legacy = @('Physical: Remote Desktop host (complete removal) [~30-50MB]'); SupportsRustPhysical = $true; Phase = '10-registry' }
        @{ Item = 'Remove Bluetooth stack (service + binary) [20-40MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_bluetooth'; Legacy = @('Physical: Bluetooth stack (complete removal) [~20-40MB]'); SupportsRustPhysical = $true; Phase = '10-registry' }
        @{ Item = 'Remove Print Spooler (service + binary) [20-30MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_spooler'; Legacy = @('Physical: Print Spooler (complete removal) [~20-30MB]'); SupportsRustPhysical = $true; Phase = '10-registry' }
        @{ Item = 'Remove touch/pen/ink components [20-30MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_touch_pen'; Legacy = @('Physical: Touch/Pen/Ink (complete removal) [~20-30MB]'); SupportsRustPhysical = $true; Phase = '10-registry' }
        @{ Item = 'Remove accessibility tools [15-25MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_accessibility'; Legacy = @('Physical: Accessibility tools (complete removal) [~15-25MB]'); SupportsRustPhysical = $true; Phase = '11-unattend'; Option = 'DisableAccessibilityTools' }
        @{ Item = 'Remove help files [10-20MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_help'; Legacy = @('Physical: Help files (complete removal) [~10-20MB]'); SupportsRustPhysical = $true; Phase = '08-filesystem'  ; Option = 'RemoveHelpFiles' }
        @{ Item = 'Remove non-Japanese IME [5-15MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '08-filesystem' }
        @{ Item = 'Remove event logs [10-50MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '08-filesystem'  ; Option = 'RemoveOfflineCacheFiles' }
        @{ Item = 'Remove crash dumps [varies]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_crash_dumps'; Legacy = @('Physical: Crash dumps (complete removal) [varies]'); SupportsRustPhysical = $true; Phase = '08-filesystem'  ; Option = 'RemoveOfflineCacheFiles' }
        @{ Item = 'Remove Windows Store cache [varies]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '08-filesystem' }
        @{ Item = 'Remove Provisioning packages [5-10MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_provisioning'; Legacy = @('Physical: Provisioning packages (complete removal) [~5-10MB]'); SupportsRustPhysical = $true; Phase = '08-filesystem' }
        @{ Item = 'Remove Windows Sandbox [10-20MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_sandbox'; Legacy = @('Physical: Windows Sandbox (complete removal) [~10-20MB]'); SupportsRustPhysical = $true; Phase = '06-fod' }
        @{ Item = 'Remove WSL / VM Platform [20-40MB]'; Engines = @('PowerShell','Rust'); Default = 'PowerShell'; RustKey = 'physical_wsl'; Legacy = @('Physical: WSL / VM Platform (complete removal) [~20-40MB]'); SupportsRustPhysical = $true; Phase = '06-fod' }
        @{ Item = 'Remove .NET Framework 3.5 [100MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod' }
        @{ Item = 'Remove Windows PowerShell ISE [5MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod'  ; Option = 'RemovePowerShellISE' }
        @{ Item = 'Remove Steps Recorder [2MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod'  ; Option = 'RemoveStepsRecorder' }
        @{ Item = 'Remove Telnet/TFTP client [1MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod'  ; Option = 'RemoveTelnetClient' }
        @{ Item = 'Remove SNMP service [2MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod'  ; Option = 'RemoveSnmpClient' }
        @{ Item = 'Remove Windows Identity Foundation [10MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod' }
        @{ Item = 'Remove Fax service [5MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod'  ; Option = 'RemoveFaxClient' }
        @{ Item = 'Remove XPS Viewer [5MB]'; Engines = @('PowerShell'); Default = 'PowerShell'; SupportsRustPhysical = $false; Phase = '06-fod'  ; Option = 'RemoveXpsViewer' }
        # --- Physical targets (forced engine by default) ---
        @{ Item = 'Physical: Edge / WebView2 (complete removal) [~200MB]'; Engines = @('Rust'); Default = 'Rust'; RustKey = 'physical_edge'; SupportsRustPhysical = $true; Phase = '09-physical-debloat' }
        @{ Item = 'Physical: Defender (complete removal) [~50MB]'; Engines = @('Rust'); Default = 'Rust'; RustKey = 'physical_defender'; SupportsRustPhysical = $true; Phase = '09-physical-debloat' }
        @{ Item = 'Physical: Cortana / Search (complete removal) [~100MB]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_cortana'; SupportsRustPhysical = $true; Phase = '05-appx' }
        @{ Item = 'Physical: OneDrive (complete removal) [~50MB]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_onedrive'; SupportsRustPhysical = $true; Phase = '08-filesystem' }
        @{ Item = 'Physical: Telemetry/DiagTrack (complete removal) [~30MB]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_telemetry'; SupportsRustPhysical = $true; Phase = '08-filesystem' }
        @{ Item = 'Physical: Hyper-V / Virtualization stack [~200-400MB]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_hyperv'; SupportsRustPhysical = $true; Phase = '06-fod' }
        @{ Item = 'Physical: IIS (Web server) [~50-100MB]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_iis'; SupportsRustPhysical = $true; Phase = '06-fod' }
        @{ Item = 'Physical: Windows Firewall (complete removal) [~20-40MB]'; Engines = @('Rust'); Default = 'Rust'; RustKey = 'physical_firewall'; SupportsRustPhysical = $true; Phase = '09-physical-debloat' }
        @{ Item = 'Physical: BitLocker (complete removal) [~30-50MB]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_bitlocker'; SupportsRustPhysical = $true; Phase = '10-registry'  ; Option = 'RemoveBitLockerFeature' }
        @{ Item = 'Physical: Windows Search index (complete removal) [varies]'; Engines = @('Rust'); Default = 'Rust'; RustKey = 'physical_search_index'; SupportsRustPhysical = $true; Phase = '09-physical-debloat' }
        @{ Item = 'Physical: Windows.old (complete removal) [varies]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_windows_old'; SupportsRustPhysical = $true; Phase = '08-filesystem' }
        @{ Item = 'Physical: Temp files (complete removal) [varies]'; Engines = @('PowerShell','Rust'); Default = 'Rust'; RustKey = 'physical_temp_files'; SupportsRustPhysical = $true; Phase = '08-filesystem' }
        @{ Item = 'Physical: Memory.dmp (complete removal) [varies]'; Engines = @('Rust'); Default = 'Rust'; RustKey = 'physical_memory_dmp'; SupportsRustPhysical = $true; Phase = '09-physical-debloat' }
        @{ Item = 'Physical: Minidump (complete removal) [varies]'; Engines = @('Rust'); Default = 'Rust'; RustKey = 'physical_minidump'; SupportsRustPhysical = $true; Phase = '09-physical-debloat' }
    )
}

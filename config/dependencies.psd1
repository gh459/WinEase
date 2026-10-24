# WinEase dependency catalog - single source of truth for deletion/optimization impact analysis.
#
# Consumed by Test-WinEaseDependencies (lib\WinEaseDependencies.ps1). Each entry describes one
# deletion/disabling toggle:
#   TriggerValue     value that means "removed / disabled" (for AdvancedDebloat items the
#                    trigger is "present in the selected list")
#   Status           'Known'  -> affected features are listed in AffectedFeatures
#                    'Safe'    -> no functional impact on other features
#                    'Unknown' -> dependency cannot be determined (environment/legacy)
#   Summary          short human-readable description
#   AffectedFeatures list of features/apps that stop working
#   Reversible       (optional) $true / $false when docs\SECURITY_OPTIONS.md documents whether the installed system can undo it;
#                    absent = not documented (the build plan then says so, it never guesses)
#   Recovery         (optional) the documented way back, shown next to Reversible
#   ConflictsWith    list of other setting keys / AdvancedDebloat item strings that
#                    contradict this one when both are enabled
# Component-level rules (the design's "ComponentRules") are kept in Components - no separate section.
@{
    Version = '1.0'

    Components = @{
        'RemoveDefender' = @{ TriggerValue = $true; Status = 'Known'; Reversible = $false; Recovery = 'No supported in-place re-enable; repair install or reinstall of Windows (docs\SECURITY_OPTIONS.md)'; Summary = 'Removes Windows Defender AV, Security Center UI and background scanning'; AffectedFeatures = @('Windows Security UI','Real-time protection','Smart App Control','Definition updates (KB2267602)'); ConflictsWith = @() }
        'KeepAsianIME' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Removes Asian (Japanese/Korean/Chinese) MS-IME input methods'; AffectedFeatures = @('Japanese/Korean/Chinese MS-IME kanji conversion','Handwriting input','Voice input','TTS speech synthesis'); ConflictsWith = @() }
        'KeepExtraFonts' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Removes extra international and regional fonts'; AffectedFeatures = @('CJK/Thai/Arabic/Hindi font rendering (Japanese and Latin fonts are kept)'); ConflictsWith = @() }
        'RemoveDrivers' = @{ TriggerValue = $true; Status = 'Unknown'; Summary = 'Removes legacy storage and network drivers; safety depends on the target PC peripherals (printers, smart cards, serial/modem devices) and cannot be assured'; AffectedFeatures = @('Legacy printer/scanner/MFD/fax/modem/smart-card PnP auto-detection'); ConflictsWith = @() }
        'AllowPhysicalDebloat' = @{ TriggerValue = $true; Status = 'Unknown'; Summary = 'Physically deletes WinSxS/System32 files; impact on future updates is unknown'; AffectedFeatures = @('Future cumulative updates (LCU)','SFC / DISM repair'); ConflictsWith = @() }
        'DisableWindowsUpdate' = @{ TriggerValue = $true; Status = 'Known'; Reversible = $true; Recovery = 'Re-enable the wuauserv service and the update policy on the installed system (docs\SECURITY_OPTIONS.md)'; Summary = 'Disables automatic Windows Update'; AffectedFeatures = @('Windows Update auto-patching','Microsoft Store app install/update (wuauserv)','FOD/language pack additions'); ConflictsWith = @() }
        'KeepBluetooth' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Removes Bluetooth services and peripheral stack'; AffectedFeatures = @('Bluetooth audio (A2DP/HFP)','Bluetooth mouse/keyboard','Wireless controllers','Phone Link'); ConflictsWith = @('Remove Bluetooth stack (service + binary) [20-40MB]') }
        'WSLSupport' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Enables WSL2 / Virtual Machine Platform'; AffectedFeatures = @('WSL2, WSA, Hyper-V VMs, Windows Sandbox, Docker Desktop, Core Isolation (HVCI)'); ConflictsWith = @('NoHypervisor','Remove WSL / VM Platform [20-40MB]','Physical: Hyper-V / Virtualization stack [~200-400MB]') }
        'KeepRecoveryEnv' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Removes Windows Recovery Environment (WinRE)'; AffectedFeatures = @('WinRE','Reset this PC','Startup Repair','Troubleshooting screen'); ConflictsWith = @() }
        'SafeDebloatMode' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Aggressive WinSxS cleanup (disables Safe mode)'; AffectedFeatures = @('WinSxS component consistency (sfc /scannow, cumulative updates, feature additions may fail)'); ConflictsWith = @() }
        'UltraSlimMode' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'UltraSlim pruning of speech/TTS/OCR FODs and fonts'; AffectedFeatures = @('Offline speech recognition (Win+H)','CJK narrator TTS voices','OCR','standard 4K wallpapers'); ConflictsWith = @() }
        'SetJapaneseKeyboard' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Skips Japanese 106/109 keyboard layout configuration'; AffectedFeatures = @('JIS keyboard layout detection (@ and : key mapping on Japanese hardware)'); ConflictsWith = @() }
        'AtlasReviOSMode' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'AtlasOS/ReviOS low-latency kernel tuning'; AffectedFeatures = @('CPU core parking (idle power draw slightly increases)','Scheduled maintenance tasks'); ConflictsWith = @() }
        'RemoveStore' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Microsoft Store and purchased UWP apps'; AffectedFeatures = @('Microsoft Store app','Store app install/licensing','PC Game Pass integration (winget is kept)'); ConflictsWith = @('KeepXboxServices') }
        'KeepBasicApps' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Removes basic inbox apps'; AffectedFeatures = @('Notepad','Paint','Calculator','Snipping Tool'); ConflictsWith = @() }
        'KeepSearchIndex' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Disables Windows Search indexing (WSearch)'; AffectedFeatures = @('Explorer/Start Menu fast indexed search','Outlook desktop fast search'); ConflictsWith = @('DisableWindowsSearchIndexing','Physical: Cortana / Search (complete removal) [~100MB]','Physical: Windows Search index (complete removal) [varies]') }
        'KeepXboxServices' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Removes Xbox services and gaming overlay'; AffectedFeatures = @('Xbox app','PC Game Pass sign-in (XblAuthManager)','Cloud saves (XblGameSave)','Game Bar (Win+G)'); ConflictsWith = @('RemoveStore','DisableGameDVR') }
        'KeepAudioTweaks' = @{ TriggerValue = $false; Status = 'Safe'; Summary = 'Disables low-latency audio MMCSS tuning'; AffectedFeatures = @(); ConflictsWith = @() }
        'UseVHDX' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (VHDX output), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveLegacyFOD' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes legacy optional features (FOD)'; AffectedFeatures = @('VBScript (.vbs)','PowerShell ISE','Legacy WMP','SMB1 (old NAS)','WordPad'); ConflictsWith = @() }
        'TrimWallpapers' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Trims default wallpapers and screen savers'; AffectedFeatures = @(); ConflictsWith = @() }
        'HibernateMode' = @{ TriggerValue = 'Off'; Status = 'Known'; Summary = 'Disables hibernation / fast startup'; AffectedFeatures = @('Hibernation','Fast Startup (Hiberboot)'); ConflictsWith = @() }
        'CrashDumpMode' = @{ TriggerValue = 'None'; Status = 'Known'; Summary = 'Disables crash dump output'; AffectedFeatures = @('BSOD minidump / memory.dmp output and crash analysis'); ConflictsWith = @() }
        'DisableCPUMitigations' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'CPU mitigation toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'MMCSSGaming' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Performance tuning toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'DAWMode' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Audio DAW mode toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableMemCompression' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Memory compression toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableFSE' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Fullscreen optimizations toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'NvidiaLowLatency' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'NVIDIA low-latency toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'NoKernelPaging' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Kernel paging toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableUSBSuspend' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'USB suspend toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'NoHypervisor' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Hypervisor toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWebViewPostOOBE' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Edge WebView2 runtime after OOBE'; AffectedFeatures = @('WebView2-dependent apps (Discord, Steam, Spotify, PowerToys, Office add-ins, Widgets)'); ConflictsWith = @() }
        'FastExport' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (fast export), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'UefiOnly' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'UEFI-only boot (no legacy BIOS/CSM)'; AffectedFeatures = @('Legacy BIOS (CSM/MBR) PC boot from ISO'); ConflictsWith = @() }
        'BypassActivationRestrictions' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Activation bypass toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'RadicalRAM' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Radical RAM toggle (handled as a tweak)'; AffectedFeatures = @(); ConflictsWith = @() }
        'TweakGroups' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Internal tweak group container'; AffectedFeatures = @(); ConflictsWith = @() }
        'TweakSettings' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Internal per-tweak settings container'; AffectedFeatures = @(); ConflictsWith = @() }
        'PayloadFormat' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (payload format), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'SkipEiCfg' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (skip ei.cfg), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'NoPostInstallAssets' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (skip post-install assets), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'SourceDrive' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (source drive), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'WorkDir' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (working directory), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'Index' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (image index), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'ComputerName' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (computer name), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'UserName' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (user name), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'UserPassword' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (user password), not a deletion'; AffectedFeatures = @(); ConflictsWith = @() }
        'AdvancedDebloatStandard' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Internal advanced debloat list container'; AffectedFeatures = @(); ConflictsWith = @() }
        'AdvancedDebloatExperimental' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Internal advanced debloat list container'; AffectedFeatures = @(); ConflictsWith = @() }
        'IncludeMigrationAssistant' = @{ TriggerValue = $null; Status = 'Safe'; Summary = 'Build option (include migration assistant tool)'; AffectedFeatures = @(); ConflictsWith = @() }
        'IncludeMigrationBackup' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Copies the default migration backup into C:\WinEaseBackup (restore stays manual)'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveAppxBloatware' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes the preinstalled AppX inbox apps of the image (Zune, Clipchamp, Xbox, sponsored apps)'; AffectedFeatures = @('Inbox media apps (Zune Music / Zune Video / Clipchamp)','Xbox app and Game Bar companion apps','Sponsored and OEM preinstalled apps (Spotify, Candy Crush, Disney+)','Teams, To Do, Outlook for Windows, Sticky Notes'); ConflictsWith = @('KeepBasicApps','KeepXboxServices') }
        'RemoveCameraApp' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes the Camera AppX package independently of the general bloatware list'; AffectedFeatures = @('Windows Camera app','Webcam capture through the Camera app'); ConflictsWith = @() }
        'RemovePhotosApp' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes the Photos AppX package independently of the general bloatware list'; AffectedFeatures = @('Photos app','Photos-based image viewing/editing'); ConflictsWith = @() }
        'RemoveScreenSketchApp' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes the Screen Sketch / Snipping Tool AppX package independently of the general bloatware list'; AffectedFeatures = @('Snipping Tool / Screen Sketch app','Win+Shift+S capture UI'); ConflictsWith = @() }
    }

    Tweaks = @{
        'BypassHardwareRequirements' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Bypasses TPM/SecureBoot/RAM/CPU/storage checks'; AffectedFeatures = @(); ConflictsWith = @() }
        'BypassNetworkRequirement' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Bypasses mandatory OOBE internet connection'; AffectedFeatures = @(); ConflictsWith = @() }
        'BypassNRO' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Enables BypassNRO for local account creation'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableUAC' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables UAC consent prompts'; AffectedFeatures = @('Administrator elevation consent prompt','UAC virtualization for legacy apps','Drag-and-drop permission boundary'); ConflictsWith = @() }
        'DisableSmartScreen' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables SmartScreen filter'; AffectedFeatures = @('SmartScreen warnings for unknown apps/downloads','Phishing site warnings'); ConflictsWith = @() }
        'DisableVBS' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Virtualization-Based Security'; AffectedFeatures = @('Core Isolation (HVCI)','Credential Guard','VBS-dependent anti-cheat'); ConflictsWith = @() }
        'DisableWPBT' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Windows Platform Binary Table'; AffectedFeatures = @('OEM UEFI-embedded tool auto-install (e.g. Armoury Crate)'); ConflictsWith = @() }
        'HardenSystemSecurity' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Offline security hardening (Harden-Windows-Security subset: LSA protection, WDigest off, NTLMv2 only, anonymous restrictions, Remote Assistance/AutoRun off, script block logging)'; AffectedFeatures = @('Unsigned LSA plug-ins / password filters (LSA protection)','NTLMv1/LM-only NAS, printers and legacy SMB servers','Anonymous share/account enumeration by legacy tools','Remote Assistance (Quick Assist is not affected)','AutoRun/AutoPlay of USB drives and discs'); ConflictsWith = @('DisableVBS','DisableUAC','DisableSmartScreen','DisableCPUMitigations') }
        'PreventDeviceEncryption' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Prevents automatic BitLocker device encryption on OOBE'; AffectedFeatures = @('OOBE automatic device encryption'); ConflictsWith = @() }
        'DisableCopilot' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Windows Copilot AI'; AffectedFeatures = @('Windows Copilot','Edge Copilot sidebar','Notepad/Paint AI features','Teams auto-install'); ConflictsWith = @() }
        'DisableWebSearch' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Bing web search in Start Menu'; AffectedFeatures = @('Bing web search results and suggestions in Start'); ConflictsWith = @() }
        'DisableWidgets' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Widgets board'; AffectedFeatures = @('Taskbar Widgets board (weather/news feed)'); ConflictsWith = @() }
        'DisableCrossDevice' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Cross Device Experience Host'; AffectedFeatures = @('Phone Link','Cross-device clipboard','Send to phone'); ConflictsWith = @() }
        'DisableAdvertisingId' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables targeted advertising identifier'; AffectedFeatures = @('Targeted advertising ID'); ConflictsWith = @() }
        'DisableErrorReporting' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Windows Error Reporting'; AffectedFeatures = @('WER service','Crash report submission'); ConflictsWith = @() }
        'DisableIMETelemetry' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Opts out of cloud IME learning'; AffectedFeatures = @('MS-IME cloud conversion candidates'); ConflictsWith = @() }
        'DisableCloudContent' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables cloud consumer features'; AffectedFeatures = @('Windows Spotlight lock screen','Start Menu promoted app suggestions'); ConflictsWith = @() }
        'DisableAppPrivacy' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Restricts app access to location/mic/contacts'; AffectedFeatures = @('App location/mic/contacts access (Zoom/Discord may need manual permission)'); ConflictsWith = @() }
        'DisableTelemetryAndDiagnostics' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Sets telemetry to 0 and stops DiagTrack'; AffectedFeatures = @('DiagTrack service','Windows Insider Program participation/build receiving'); ConflictsWith = @() }
        'DisableDefenderSecurityCenter' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Hides Security Center systray notifications'; AffectedFeatures = @('Security Center systray notifications'); ConflictsWith = @() }
        'DisableCortana' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Cortana'; AffectedFeatures = @('Cortana digital assistant'); ConflictsWith = @() }
        'DisableActivityHistory' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables activity history tracking'; AffectedFeatures = @('Activity history recording','Cloud settings sync (Windows Backup sync)'); ConflictsWith = @() }
        'DisableTimeline' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Windows Timeline'; AffectedFeatures = @('Windows Timeline feature'); ConflictsWith = @() }
        'DisableDiagnosticData' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables diagnostic feedback submissions'; AffectedFeatures = @('Diagnostic feedback and sample submissions'); ConflictsWith = @() }
        'ConfigureWinlogon' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Allows blank-password local logon and pre-configures the auto-logon account'; AffectedFeatures = @('Local account sign-in without a password'); ConflictsWith = @() }
        'EnableScripts' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Relaxes the PowerShell execution policy to RemoteSigned'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableWindowsAI' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Windows AI, Recall and Click-To-Do policies'; AffectedFeatures = @('Windows Recall','Windows AI features','Click-To-Do'); ConflictsWith = @() }
        'DisableDeliveryOptimization' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Disables Delivery Optimization P2P upload'; AffectedFeatures = @('Peer-to-peer update distribution'); ConflictsWith = @() }
        'DisablePowerThrottling' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Windows power throttling'; AffectedFeatures = @('Power throttling on battery (background task throttling)'); ConflictsWith = @() }
        'EnableHAGS' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Enables Hardware-Accelerated GPU Scheduling'; AffectedFeatures = @('GPU scheduling (requires a supported GPU and driver)'); ConflictsWith = @() }
        'NtfsDisable8dot3' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Disables NTFS 8.3 short names and last-access timestamp updates'; AffectedFeatures = @(); ConflictsWith = @() }
        'ThreadDpcEnable' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Enables DPC thread tweaking and foreground quantum scheduling'; AffectedFeatures = @('Sustained CPU load can raise DPC latency'); ConflictsWith = @() }
        'NetworkTuning' = @{ TriggerValue = $false; Status = 'Safe'; Summary = 'Tunes TCP timeouts, port range, TTL and DNS behaviour'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableIdleMaintenance' = @{ TriggerValue = $false; Status = 'Safe'; Summary = 'Disables Windows scheduled idle maintenance'; AffectedFeatures = @(); ConflictsWith = @() }
        'SvcHostConsolidation' = @{ TriggerValue = $false; Status = 'Known'; Summary = 'Consolidates svchost processes to reduce idle RAM'; AffectedFeatures = @('svchost process isolation (one service crash can affect co-hosted services)'); ConflictsWith = @() }
        'DisableSearchWebView2' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Stops SearchHost from starting a WebView2 runtime for the search box'; AffectedFeatures = @('Web content inside the Windows search box (search results stay local)'); ConflictsWith = @() }
        'NoHypervisor' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Sets hypervisorlaunchtype to Off'; AffectedFeatures = @('WSL2','WSA','Hyper-V VMs','Windows Sandbox','Docker Desktop','Core Isolation (HVCI)','VBS'); ConflictsWith = @('WSLSupport') }
        'BypassActivationRestrictions' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Unlocks personalization and suppresses licensing nags'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableCPUMitigations' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Spectre/Meltdown CPU mitigations'; AffectedFeatures = @('CPU speculative execution mitigations (security trade-off)'); ConflictsWith = @() }
        'RadicalRAM' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Radical RAM optimization (svchost consolidation)'; AffectedFeatures = @('svchost process isolation (one service crash can affect co-hosted services)'); ConflictsWith = @() }
        'DisableMemCompression' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables in-memory paging compression'; AffectedFeatures = @('Memory compression (more pagefile use on low-RAM systems)'); ConflictsWith = @() }
        'NoKernelPaging' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Locks NT kernel in physical RAM'; AffectedFeatures = @('Kernel paging (less free physical RAM on low-memory systems)'); ConflictsWith = @() }
        'DisableUSBSuspend' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables USB selective suspend'; AffectedFeatures = @('USB selective suspend (controller and DAC power management)'); ConflictsWith = @() }
        'HideSearchBox' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides the taskbar search box'; AffectedFeatures = @(); ConflictsWith = @() }
        'MenuShowDelayZero' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes the hover delay on Start menu entries'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableSnapAssist' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Snap Layouts and snap suggestions'; AffectedFeatures = @('Snap Layouts / Snap Assist'); ConflictsWith = @() }
        'DisableNotificationBanners' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Turns off notification banners'; AffectedFeatures = @('Notification banners (toasts)'); ConflictsWith = @() }
        'HideExplorerHomeGallery' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides Home and Gallery in Explorer'; AffectedFeatures = @(); ConflictsWith = @() }
        'HideAltTabEdgeTabs' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides browser tabs from Alt+Tab'; AffectedFeatures = @(); ConflictsWith = @() }
        'HideTaskViewButton' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides the Task View button'; AffectedFeatures = @(); ConflictsWith = @() }
        'TaskbarNeverCombine' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Never combines taskbar buttons'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableGameMode' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Turns off Game Mode'; AffectedFeatures = @('Game Mode'); ConflictsWith = @() }
        'ShowBatteryPercentage' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Shows the battery percentage'; AffectedFeatures = @(); ConflictsWith = @() }
        'AlwaysShowScrollbars' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Always shows scrollbars'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableLogonBlur' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Disables the sign-in screen blur'; AffectedFeatures = @(); ConflictsWith = @() }
        'HideOneDriveNavPane' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides OneDrive in Explorer'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableAccessibilityHotkeys' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables the StickyKeys / FilterKeys / ToggleKeys / MouseKeys accessibility hotkeys'; AffectedFeatures = @('StickyKeys (5x Shift)','FilterKeys','ToggleKeys','MouseKeys','Keyboard Response','input language and layout hotkeys'); ConflictsWith = @() }
        'DisableMouseAcceleration' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Turns off mouse pointer acceleration'; AffectedFeatures = @('pointer precision setting'); ConflictsWith = @() }
        'DisableKeyboardDelay' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes the keyboard character repeat delay'; AffectedFeatures = @('keyboard repeat delay setting'); ConflictsWith = @() }
        'RemoveHelpFiles' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Windows Help files folder'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveEdge' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Edge browser (the WebView2 runtime is kept for OOBE)'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWindowsBackup' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Windows Backup app and its scheduled task'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWebExperienceHost' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Web Experience (Widgets) host app'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveOfflineCacheFiles' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Clear build-time caches (Temp, Prefetch, Panther, event logs, Minidump)'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveRecall' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disable and remove the Windows Recall optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveInternetExplorer' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Internet Explorer optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWordPad' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the WordPad optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveStepsRecorder' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Steps Recorder optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveSnippingTool' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Snipping Tool optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemovePaint' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the MS Paint optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveXpsViewer' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the XPS Viewer optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemovePowerShellISE' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Windows PowerShell ISE optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveOpenSSHClient' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the OpenSSH client optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveHelloFace' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Hello Face optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveBitLockerFeature' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the BitLocker Drive Encryption optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveNarratorApp' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Narrator optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveMagnifierApp' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Magnifier optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveMediaPlayerFeature' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Media Player optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveTabletPCMath' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Tablet PC Math optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWebcamExperience' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Webcam Experience optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWallpaperContent' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the extended wallpaper content optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveSearchEngineClient' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Search Engine Client optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemovePrintingManagement' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the printing management optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveMpeg2Decoder' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the MPEG-2 decoder optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWmic' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the WMIC optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveWirelessDisplay' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Wireless Display (Miracast) optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveSnmpClient' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the SNMP client optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveTelnetClient' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Telnet client optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveSimpleTcpClient' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Simple TCP client optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveRdc' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Remote Desktop Connection client optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveFaxClient' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Fax client optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveUserExperienceVirt' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the User Experience Virtualization optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveDeviceManagementEnt' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Device Management Enterprise optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveNotepad' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Notepad optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveMathRecognizer' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Math Recognizer optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemovePrintingWfs' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Printing Workgroup Fax optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveKernelLA57' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the Kernel LA57 optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveTpmWmiProvider' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Remove the TPM WMI provider optional feature'; AffectedFeatures = @(); ConflictsWith = @() }
        'RemoveLanguageJaJP' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Allows removing the Japanese language pack'; AffectedFeatures = @('Japanese display language and IME resources'); ConflictsWith = @() }
        'RemoveLanguageKoKR' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Allows removing the Korean language pack'; AffectedFeatures = @('Korean display language and IME resources'); ConflictsWith = @() }
        'RemoveLanguageZhCN' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Allows removing the Simplified Chinese language pack'; AffectedFeatures = @('Simplified Chinese display language and IME resources'); ConflictsWith = @() }
        'RemoveLanguageZhTW' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Allows removing the Traditional Chinese language pack'; AffectedFeatures = @('Traditional Chinese display language and IME resources'); ConflictsWith = @() }
        'EnableCompactOS' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Enables CompactOS NTFS compression on the installed system'; AffectedFeatures = @('Installed disk footprint (read speed trade-off)'); ConflictsWith = @() }
        'EnableNtfs8dot3Disable' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Disables NTFS 8.3 short names and last-access timestamp tracking'; AffectedFeatures = @(); ConflictsWith = @() }
        'EnableUltimatePerformancePower' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Activates the Ultimate Performance power plan after setup'; AffectedFeatures = @('Power plan (heat and power draw increase)'); ConflictsWith = @() }
        'EnableMsiMode' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Enables Message Signaled Interrupts for detected PCI hardware'; AffectedFeatures = @('PCI interrupt handling (some older drivers misbehave)'); ConflictsWith = @() }
        'DisableAccessibilityTools' = @{ TriggerValue = $false; Status = 'Safe'; Summary = 'Blocks the on-screen keyboard, Narrator and Magnifier from launching'; AffectedFeatures = @('On-screen keyboard','Narrator','Magnifier'); ConflictsWith = @() }
        'DisableWindowsSearchProcess' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Stops the SearchHost background process after setup'; AffectedFeatures = @('Windows Search (WSearch) background indexing'); ConflictsWith = @('KeepSearchIndex') }
        'DisableComputerRestore' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Disables System Restore on the system drive after setup'; AffectedFeatures = @('System Restore (rollback safety net)'); ConflictsWith = @() }
        'DisableFTH' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Fault Tolerant Heap'; AffectedFeatures = @('Fault Tolerant Heap (crash mitigation for heap-corrupting legacy apps)'); ConflictsWith = @() }
        'DisablePCA' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Program Compatibility Assistant'; AffectedFeatures = @('Program Compatibility Assistant (auto compat mode for old apps)'); ConflictsWith = @() }
        'TuneMemoryAndPaging' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Skips pagefile clear on shutdown, keeps standard cache'; AffectedFeatures = @(); ConflictsWith = @() }
        'GamingNetworkTweaks' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Disables multimedia network throttling and Nagle'; AffectedFeatures = @(); ConflictsWith = @() }
        'LowLatencyAudioMMCSS' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Optimizes MMCSS for low audio jitter'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableBackgroundApps' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables background execution of UWP apps'; AffectedFeatures = @('UWP app background execution and notifications (Mail, Alarms, Xbox)'); ConflictsWith = @() }
        'DisableGameDVR' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables GameDVR recording'; AffectedFeatures = @('Game Bar screen recording (Win+Alt+G / Win+Alt+R)'); ConflictsWith = @('KeepXboxServices') }
        'DisableSuperfetch' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables SysMain (Superfetch)'; AffectedFeatures = @('SysMain prefetch (app launch speed on HDD)'); ConflictsWith = @() }
        'DisableWindowsSearchIndexing' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Windows Search indexing service'; AffectedFeatures = @('Windows Search indexing (WSearch)'); ConflictsWith = @('KeepSearchIndex') }
        'DisableFastStartup' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables Fast Startup'; AffectedFeatures = @('Fast Startup (Hiberboot)'); ConflictsWith = @() }
        'EnableClassicContextMenu' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Restores classic context menus'; AffectedFeatures = @(); ConflictsWith = @() }
        'EnableDarkTheme' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Enables system-wide dark theme'; AffectedFeatures = @(); ConflictsWith = @() }
        'ShowFileExtensions' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Shows file extensions in Explorer'; AffectedFeatures = @(); ConflictsWith = @() }
        'ShowHiddenFiles' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Shows hidden files and folders'; AffectedFeatures = @(); ConflictsWith = @() }
        'LaunchToThisPC' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Opens Explorer to This PC'; AffectedFeatures = @(); ConflictsWith = @() }
        'TaskbarEndTask' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Enables End Task on taskbar'; AffectedFeatures = @(); ConflictsWith = @() }
        'TaskbarAlignLeft' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Aligns taskbar icons to the left'; AffectedFeatures = @(); ConflictsWith = @() }
        'HideMeetNow' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides Meet Now icon'; AffectedFeatures = @(); ConflictsWith = @() }
        'HideSyncNotifications' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides sync provider notifications'; AffectedFeatures = @(); ConflictsWith = @() }
        'HideRecommendedSection' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Hides Recommended section in Start'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableStartupSound' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Disables startup sound'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableLockScreen' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Skips lock screen to login'; AffectedFeatures = @(); ConflictsWith = @() }
        'DisableSleepOption' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Sleep option from power menu'; AffectedFeatures = @('Sleep option in power menu'); ConflictsWith = @() }
        'DisableBSODEmoticon' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes sad face from BSOD'; AffectedFeatures = @(); ConflictsWith = @() }
        'EnableLongPaths' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Enables Win32 long paths'; AffectedFeatures = @(); ConflictsWith = @() }
        'TransparentShortcutOverlay' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes shortcut arrow overlay'; AffectedFeatures = @(); ConflictsWith = @() }
        'PhotoViewerAssociations' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Restores classic Photo Viewer'; AffectedFeatures = @(); ConflictsWith = @() }
        'TakeOwnershipContextMenu' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Adds Take Ownership context menu'; AffectedFeatures = @(); ConflictsWith = @() }
        'CmdAsAdminContextMenu' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Adds Command Prompt as Admin context menu'; AffectedFeatures = @(); ConflictsWith = @() }
        'OptimizeVisualEffects' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Optimizes visual effects for performance'; AffectedFeatures = @(); ConflictsWith = @() }
        'CleanContextMenus' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Hides Share/Give access/Cast context menu entries'; AffectedFeatures = @('Share, Give access to, Cast to Device context menu entries'); ConflictsWith = @() }
    }

    AdvancedDebloat = @{
        'Remove PatchCache (dir delete) [200-500MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes MSI installer patch cache'; AffectedFeatures = @('MSI app repair/change/uninstall for installed apps'); ConflictsWith = @() }
        'Remove Delivery Optimization cache (dir delete) [100-500MB]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes Delivery Optimization cache'; AffectedFeatures = @(); ConflictsWith = @() }
        'Remove non-Japanese language packs (DISM) [200-500MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes non-Japanese language packs'; AffectedFeatures = @('Non-Japanese display language packs'); ConflictsWith = @() }
        'Remove non-essential fonts (file delete) [50-100MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes non-essential fonts'; AffectedFeatures = @('Supplementary international font rendering'); ConflictsWith = @() }
        'WinSxS cleanup (/StartComponentCleanup /ResetBase) [1-3GB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Resets WinSxS component store base'; AffectedFeatures = @('WinSxS component consistency (sfc, cumulative updates, feature additions)'); ConflictsWith = @() }
        'Remove pagefile.sys (pagefile disable) [4-16GB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables and removes pagefile.sys'; AffectedFeatures = @('Virtual memory (OOM crashes on RAM-exceeding workloads/large games)'); ConflictsWith = @() }
        'Remove hiberfil.sys (powercfg /h off) [4-16GB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables hibernation and removes hiberfil.sys'; AffectedFeatures = @('Hibernation','Fast Startup (Hiberboot)'); ConflictsWith = @() }
        'Remove swapfile.sys (pagefile disable) [256MB-1GB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Disables the paging file, which removes the swap file with it'; AffectedFeatures = @('UWP app swap under memory pressure','Virtual memory (the paging file is switched off as well)'); ConflictsWith = @() }
        'Remove Provisioned AppX (list-based) [100-300MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes provisioned AppX packages'; AffectedFeatures = @('Provisioned UWP apps for new user profiles'); ConflictsWith = @() }
        'Remove Windows Media Player (component) [50-100MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Windows Media Player'; AffectedFeatures = @('wmplayer.exe','WMP ActiveX/codec-dependent legacy game movie playback'); ConflictsWith = @() }
        'Remove Remote Desktop host (service + binary) [30-50MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Remote Desktop host'; AffectedFeatures = @('Remote Desktop connections (mstsc/TermService)','Hyper-V enhanced session','Quick Assist'); ConflictsWith = @() }
        'Remove Bluetooth stack (service + binary) [20-40MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Bluetooth stack'; AffectedFeatures = @('All Bluetooth device pairing and connectivity'); ConflictsWith = @('KeepBluetooth') }
        'Remove Print Spooler (service + binary) [20-30MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Print Spooler'; AffectedFeatures = @('Physical printer printing','Microsoft Print to PDF','Spooler-dependent accounting/reporting apps'); ConflictsWith = @() }
        'Remove touch/pen/ink components [20-30MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes touch/pen/ink components'; AffectedFeatures = @('Touch panel','Stylus pen (Windows Ink)','Touch keyboard'); ConflictsWith = @() }
        'Remove accessibility tools [15-25MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes accessibility tools'; AffectedFeatures = @('Narrator, Magnifier, On-Screen Keyboard, Voice Access, Live Captions'); ConflictsWith = @() }
        'Remove help files [10-20MB]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes help files'; AffectedFeatures = @(); ConflictsWith = @() }
        'Remove non-Japanese IME [5-15MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes non-Japanese IME'; AffectedFeatures = @('Non-Japanese input method editors'); ConflictsWith = @() }
        'Remove event logs [10-50MB]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes event logs'; AffectedFeatures = @(); ConflictsWith = @() }
        'Remove crash dumps [varies]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Removes crash dumps'; AffectedFeatures = @(); ConflictsWith = @() }
        'Remove Provisioning packages [5-10MB]' = @{ TriggerValue = $true; Status = 'Unknown'; Summary = 'Removes provisioning packages'; AffectedFeatures = @(); ConflictsWith = @() }
        'Remove Windows Sandbox [10-20MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Windows Sandbox'; AffectedFeatures = @('Windows Sandbox'); ConflictsWith = @() }
        'Remove WSL / VM Platform [20-40MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes WSL / VM Platform'; AffectedFeatures = @('WSL2','WSA','Docker Desktop (WSL2 backend)'); ConflictsWith = @('WSLSupport') }
        'Remove .NET Framework 3.5 [100MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes .NET Framework 3.5'; AffectedFeatures = @('.NET 2.0/3.0/3.5-dependent legacy apps and games'); ConflictsWith = @() }
        'Remove Windows PowerShell ISE [5MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes PowerShell ISE'; AffectedFeatures = @('powershell_ise.exe'); ConflictsWith = @() }
        'Remove Steps Recorder [2MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Steps Recorder'; AffectedFeatures = @('psr.exe (Steps Recorder)'); ConflictsWith = @() }
        'Remove Telnet/TFTP client [1MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Telnet/TFTP client'; AffectedFeatures = @('telnet.exe'); ConflictsWith = @() }
        'Remove SNMP service [2MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes SNMP service'; AffectedFeatures = @('SNMP monitoring'); ConflictsWith = @() }
        'Remove Windows Identity Foundation [10MB]' = @{ TriggerValue = $true; Status = 'Unknown'; Summary = 'Removes Windows Identity Foundation'; AffectedFeatures = @(); ConflictsWith = @() }
        'Remove Fax service [5MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes Fax service'; AffectedFeatures = @('WFS.exe (Windows Fax and Scan)'); ConflictsWith = @() }
        'Remove XPS Viewer [5MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Removes XPS Viewer'; AffectedFeatures = @('XPS Viewer and XPS printing'); ConflictsWith = @() }
        'Physical: Edge / WebView2 (complete removal) [~200MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes Edge / WebView2'; AffectedFeatures = @('OOBE crash risk','WebView2-dependent apps (Discord, Steam, PowerToys, Office add-ins)'); ConflictsWith = @() }
        'Physical: Defender (complete removal) [~50MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes Defender'; AffectedFeatures = @('Windows Security UI','Real-time protection'); ConflictsWith = @() }
        'Physical: Cortana / Search (complete removal) [~100MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes Cortana / Search'; AffectedFeatures = @('Cortana','Windows Search'); ConflictsWith = @('KeepSearchIndex') }
        'Physical: OneDrive (complete removal) [~50MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes OneDrive'; AffectedFeatures = @('OneDrive sync client'); ConflictsWith = @() }
        'Physical: Telemetry/DiagTrack (complete removal) [~30MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes Telemetry/DiagTrack'; AffectedFeatures = @('DiagTrack service','Telemetry collection'); ConflictsWith = @() }
        'Physical: Hyper-V / Virtualization stack [~200-400MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes Hyper-V stack'; AffectedFeatures = @('Hyper-V','WSL2','Windows Sandbox','Docker Desktop','Core Isolation (HVCI)'); ConflictsWith = @('WSLSupport') }
        'Physical: IIS (Web server) [~50-100MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes IIS'; AffectedFeatures = @('IIS local web server (inetsrv)'); ConflictsWith = @() }
        'Physical: Windows Firewall (complete removal) [~20-40MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes Windows Firewall'; AffectedFeatures = @('Windows Firewall (MpsSvc/BFE)','VPN clients (WireGuard/Tailscale)','Store communication'); ConflictsWith = @() }
        'Physical: BitLocker (complete removal) [~30-50MB]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes BitLocker'; AffectedFeatures = @('BitLocker drive encryption','BitLocker To Go unlock'); ConflictsWith = @() }
        'Physical: Windows Search index (complete removal) [varies]' = @{ TriggerValue = $true; Status = 'Known'; Summary = 'Physically removes Windows Search index'; AffectedFeatures = @('Windows Search indexing'); ConflictsWith = @('KeepSearchIndex') }
        'Physical: Windows.old (complete removal) [varies]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Physically removes Windows.old'; AffectedFeatures = @(); ConflictsWith = @() }
        'Physical: Temp files (complete removal) [varies]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Physically removes temp files'; AffectedFeatures = @(); ConflictsWith = @() }
        'Physical: Memory.dmp (complete removal) [varies]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Physically removes memory dump handling'; AffectedFeatures = @(); ConflictsWith = @() }
        'Physical: Minidump (complete removal) [varies]' = @{ TriggerValue = $true; Status = 'Safe'; Summary = 'Physically removes minidump handling'; AffectedFeatures = @(); ConflictsWith = @() }
    }
}

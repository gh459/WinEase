# Upstream sync 2026-10

Tweaks added or changed by the latest releases of the tools credited in the README
("Optimization & Debloat Tool Integrations"), reviewed against WinEase on 2026-10-21.
Baseline: the last release of each tool before 2025-10-21. Only tweak definitions were
compared (registry values, services, Appx packages, tasks); the upstream code was read as
data and never run.

Decision: **adopted** (ported to WinEase), **present** (WinEase already does it),
**skipped** (with the reason).

## ChrisTitusTech/winutil 25.10.06 -> 26.10.07

Source: `config/tweaks.json`. Most of the diff is renamed tweaks (`WPFTweaksTele` ->
`WPFTweaksTelemetry`, ...); only items that exist nowhere in 25.10.06 are listed.

| Item | Decision | Where |
|---|---|---|
| `InputPersonalization\TrainedDataStore\HarvestContacts=0` | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `Personalization\Settings\AcceptedPrivacyPolicy=0` | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `Explorer\Advanced\Start_TrackProgs=0` | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `POWERSHELL_TELEMETRY_OPTOUT=1` (machine environment) | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `Policies\WindowsNotepad\DisableAIFeatures=1` | adopted | 10-registry, DisableWindowsAI |
| `SettingsPageVisibility=hide:aicomponents` | adopted | 10-registry, DisableWindowsAI |
| `Edge\DefaultBrowserSettingsCampaignEnabled=0` | adopted | 10-registry, DisableCloudContent |
| Appx `Microsoft.WidgetsPlatformRuntime` | adopted | schema.psd1 AppxRemoval (AI) |
| AdvertisingInfo, TailoredExperiences, OnlineSpeechPrivacy, TIPC, Ink/Text collection, Siuf | present | 10-registry |
| `EnableActivityFeed`, `PreventDeviceMetadataFromNetwork`, `NoLockScreen`, `DisableWpbtExecution`, `TaskbarEndTask`, `SubmitSamplesConsent` | present | 10-registry |
| Services `lfsvc`, `CscService`, `MapsBroker`, `SharedAccess`, `WSAIFabricSvc` | present | 10-registry service trims |
| Reserved storage (`DISM /Set-ReservedStorageState`) | present | `ReserveManager\ShippedWithReserves=0` |
| Appx `MicrosoftWindows.Client.CoreAI` (EndOfLife + remove) | skipped | protected on purpose in 05-appx: shell dependency |
| `Diagnostics wermgr` service | skipped | `wermgr` is a process, not a service; WER is already off by policy |
| Brave policies | skipped | Brave is not part of the image |
| Edge `ExtensionInstallBlocklist\1` | skipped | unverified extension id |
| RDP unsigned file warning off | skipped | lowers security |
| Start menu old layout (`FeatureManagement\Overrides\8\3036241548`) | skipped | velocity id changes between builds |
| `SystemRestorePointCreationFrequency=0`, StorageSense `01=0` | skipped | depends on the running system |
| Toggles: battery percentage, scrollbars, Game Mode, logon blur, Home/Gallery | adopted (new UI options, default off) | ShowBatteryPercentage, AlwaysShowScrollbars, DisableGameMode, DisableLogonBlur, HideExplorerHomeGallery |
| Toggles: standby network, MPO | skipped | hardware dependent |
| Store search `icacls` on `store.db`, Edge removal | skipped | needs the running system; Edge removal has its own WinEase option |

## Raphire/Win11Debloat 2025.10.06 -> 2026.08.24

Source: `Regfiles/*.reg` (value by value) and `Config/Apps.json` (apps selected by default)
against the old `Appslist.txt`.

| Item | Decision | Where |
|---|---|---|
| Edge `DefaultBrowserSettingEnabled`, `ShowRecommendationsEnabled`, `SpotlightExperiencesAndRecommendationsEnabled`, `UserFeedbackAllowed`, `ShowAcrobatSubscriptionButton`, `WalletDonationEnabled` = 0 | adopted | 10-registry, DisableCloudContent |
| `Windows.SystemToast.BackupReminder\Enabled=0` | adopted | 10-registry, DisableCloudContent |
| `SearchSettings\IsDynamicSearchBoxEnabled=0`, `IsDeviceSearchHistoryEnabled=0` | adopted | 10-registry, DisableWebSearch |
| Appx `flaregamesGmbH.RoyalRevolt`, `Microsoft.PCManager` | adopted | schema.psd1 AppxRemoval |
| Appx `Microsoft.Windows.AIHub`, Netflix, TikTok, Disney, Facebook, Instagram, Spotify | present | matched by `*Windows.Ai*` and the Sponsor patterns |
| `WSAIFabricSvc`, `PreventDeviceEncryption`, `PreventDeviceMetadataFromNetwork`, `DODownloadMode`, `AppCaptureEnabled`, `SubscribedContent-353698Enabled`, `HideRecommendedSection` (HKCU) | present | 10-registry |
| Edge `HideFirstRunExperience=0` | skipped | the value 0 keeps the first run experience, so it removes nothing |
| `IsContinuousInnovationOptedIn=0` | skipped | already the Windows default |
| `LocationAndSensors\DisableLocation=1` | skipped | `lfsvc` is already disabled; the policy also breaks automatic time zone |
| `FindMyDevice\AllowFindMyDevice=0` | skipped | theft recovery feature, not bloat |
| `ms-gamebar` protocol redirect, `UseNexusForGameBarEnabled` | skipped | Game Bar is handled by KeepXboxServices |
| Notifications off (`ToastEnabled=0`), snap, Alt+Tab tabs, taskbar combine, OneDrive nav pane | adopted (new UI options, default off) | DisableNotificationBanners, DisableSnapAssist, HideAltTabEdgeTabs, TaskbarNeverCombine, HideOneDriveNavPane |
| Drive letters, This PC folders, Start "All apps" view, Storage Sense, auto reboot | skipped | user preferences with no WinEase option |
| Brave policies, `S-1-5-20` Delivery Optimization | skipped | Brave not in the image; the NetworkService hive is not loaded offline and the DO policy is present |

## farag2/Sophia-Script-for-Windows 6.9.2 -> 8.0.0 (Windows 11 module)

Source: the function names and the registry writes of `src/Sophia_Script_for_Windows_11/Module`.
8.0.0 splits the module into `Private/*.ps1`; most of the diff is that move.

| Item | Decision | Where |
|---|---|---|
| `Start\ShowRecentList=0`, `Start\ShowFrequentList=0`, `Explorer\Advanced\Start_TrackDocs=0` | adopted | 10-registry, HideRecommendedSection |
| `WindowsAI -Disable`: Recall feature, `Microsoft.Copilot` Appx | present | RemoveRecall (FoD package) / AppxRemoval `*Copilot*` |
| `WindowsAI` removing the WindowsAI / Copilot / Store policies | skipped | Sophia avoids policies on purpose; WinEase sets them |
| DNS over HTTPS (`DohPolicy`, per adapter `DohTemplate`) | skipped | adapter GUIDs only exist on the running system |
| Location consent `Allow`, `AllowTelemetry=1/3`, `FilterAdministratorToken` | skipped | the "enable" side of a toggle |
| Start "All apps" view, cursors, `ConfigureStartPinsJSON`, OneDrive `DisableFileSyncNGSC` | skipped | user preferences / OneDrive has its own WinEase option |

## Atlas-OS/Atlas 0.4.1 -> 0.5.0-hotfix

0.5.0 shipped on 2025-10-19, two days before the baseline, so the comparison starts at
0.4.1 (the previous release, 2024-10) to cover the actual 0.5 changes. Source: the
`!registryValue`, `!registryKey`, `!service`, `!appx` and `!scheduledTask` entries of
`src/playbook/Configuration/**/*.yml`.

| Item | Decision | Where |
|---|---|---|
| Tasks `DiskDiagnosticDataCollector`, CEIP `Consolidator`, `UsbCeip` | present | autounattend.xml FirstLogon, "Safe Telemetry & CEIP Scheduled Tasks Suppression" |
| `CrossDeviceResume\Configuration\IsResumeAllowed=0`, PolicyManager `DisableCrossDeviceResume` | present | 10-registry, DisableCrossDevice (policy + per-user value) |
| Classic context menu `{86ca1aa0-...}\InprocServer32` | present | 10-registry, EnableClassicContextMenu |
| `WdBoot` service key deleted with Defender | present | 10-registry Defender block (ELAM driver neutralised and `SupportElamHive=0`) |
| `ExecutionPolicy=RemoteSigned` | present | 10-registry, EnableScripts |
| Appx `Ink.Handwriting.Main.Store.en-US1.0` | skipped | English handwriting pack; WinEase keeps input packs to the language options |
| Atlas theme file, RunOnce script | skipped | Atlas-specific branding |

## meetrevision/revision-tool 2.4.2 -> 2.14.1

Source: every `r'<registry path>', '<value>', <data>` triple of `src/lib/**/*.dart` (the
tool was rewritten in this range, so the comparison is by registry value, not by file).

| Item | Decision | Where |
|---|---|---|
| Service `diagsvc` Start=4 | adopted | 10-registry service trims (next to `DPS`, `WdiServiceHost`, `WdiSystemHost`) |
| `Session Manager\Power\SleepStudyDisabled=1` | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `EMDMgmt\GroupPolicyDisallowCaches=1`, `AllowNewCachesByDefault=0` (ReadyBoost) | adopted | 10-registry, DisableSuperfetch |
| `WdiServiceHost`, `WdiSystemHost`, `MDCoreSvc`, Defender `HideSystray`, Home/Gallery CLSIDs | present | 10-registry / Defender removal |
| VBS / HVCI (`DeviceGuard`) | present | 10-registry, DisableVBS (opt-in) |
| `Input\InputServiceEnabled=0`, `TextInputManagementService` ServiceDll swap | skipped | breaks the Japanese IME |
| `PlatformAoAcOverride=0` | skipped | turns Modern Standby off; hardware dependent |
| `EnablePrefetcher` / `EnableSuperfetch`, `NtfsMemoryUsage`, `RefsDisableLastAccessUpdate` | skipped | SysMain is already disabled; NTFS/ReFS memory tuning is workload dependent |
| Driver search via Windows Update off, `ExcludeWUDriversInQualityUpdate` | skipped | needed on fresh installs without vendor drivers |
| `RawMouseThrottle*`, power scheme indices, keyboard `LowerFilters` | skipped | user preferences / hardware dependent |

## SysAdminDoc/Debloat-Win11 v2.3.8

The first release (v1.1.0) is from 2026-04, so the whole tool is new. Source: every
`Set-Reg` call and policy table of `Modules/*.ps1|psd1`, and the `servicesToDisable` list.

| Item | Decision | Where |
|---|---|---|
| `UserProfileEngagement\ScoobeSystemSettingEnabled=0`, `Start_AccountNotifications=0`, `AccountNotifications\EnableAccountNotifications=0` | adopted | 10-registry, DisableCloudContent |
| `CloudContent\DisableWindowsSpotlightOnDesktop=1` | adopted | 10-registry, DisableCloudContent |
| `WindowsAI\AllowRecallExport=0`, `DisableRecallDataProviders=1` (user) | adopted | 10-registry, DisableWindowsAI |
| Paint `DisableCocreator`, `DisableGenerativeFill`, `DisableImageCreator` = 1 | adopted | 10-registry, DisableWindowsAI, written to `SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint` (the key the Paint guides document; Debloat-Win11 uses `SOFTWARE\Policies\Microsoft\Paint`) |
| `System\EnableSmartClipboard=0` | adopted | 10-registry, DisableWindowsAI |
| `WindowsAI\RemoveMicrosoftCopilotApp=1`, Edge `CopilotCDPPageContext=0` | adopted | 10-registry, DisableCopilot |
| `WindowsBackup\DisableBackupUI=1`, `DisableMonitoring=1` | adopted | 10-registry, DisableActivityHistory |
| Edge `DiagnosticData=0`, `PersonalizationReportingEnabled=0` | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| Service `IsoEnvBroker` (agent workspaces) | adopted | 10-registry service trims |
| ContentDeliveryManager values, AI policies (`DisableAIDataAnalysis`, `DisableClickToDo`, ...), service list | present | 10-registry |
| `DisableAgentConnectors` / `DisableAgentWorkspaces` / `DisableRemoteAgentConnectors` = 2 | skipped | WinEase writes 1; no public documentation of 2, kept as is |
| Services `NPSMSvc`, `RmSvc`, `OneSyncSvc`, `lmhosts`, `GamingServices*` | skipped | media flyout, airplane mode, Mail/Calendar sync, SMB name resolution; Gaming Services follows KeepXboxServices |
| `Lsa` (`LmCompatibilityLevel`, `RestrictAnonymous*`), WDigest, Remote Assistance, AutoRun, script block logging | skipped | security hardening, see Harden-Windows-Security |
| Windows Update deferrals, active hours, `AUOptions=2` | skipped | update policy belongs to DisableWindowsUpdate |
| `M365Copilot`, `Shell\Copilot\IsCopilotAvailable` | skipped | undocumented per-user values |
| Explorer / taskbar / snap / accessibility flags, clipboard history | skipped | user preferences |

## builtbybel/Bloatynosy 1.0.20.522 -> 1.01.103

1.01 replaced the C# feature classes by a rule catalogue (`Data/WinRules.ini`,
`Data/AppRules.ini`), so every rule was compared against WinEase.

| Item | Decision | Where |
|---|---|---|
| Edge `EdgeEntraCopilotPageContext`, `Microsoft365CopilotChatIconEnabled`, `EdgeHistoryAISearchEnabled`, `ComposeInlineEnabled`, `NewTabPageBingChatEnabled` = 0, `GenAILocalFoundationalModelSettings=1` | adopted | 10-registry, DisableCopilot |
| `RotatingLockScreenOverlayEnabled=0`, `RotatingLockScreenEnabled=0` | adopted | 10-registry, DisableCloudContent |
| Edge `EdgeShoppingAssistantEnabled=0`, `StartupBoostEnabled=0`, `HideFirstRunExperience=1` | adopted | 10-registry, DisableCloudContent |
| User policy `CloudContent\DisableTailoredExperiencesWithDiagnosticData=1` | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `Policies\Microsoft\InputPersonalization\AllowInputPersonalization=0`, Narrator `OnlineServicesEnabled=0` | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `Windows Feeds\EnableFeeds=0` | adopted | 10-registry, DisableWidgets |
| Appx `Microsoft.Office.OneNote`, `Microsoft.SkypeApp`, `Microsoft.Microsoft3DViewer`, `king.com.*` | adopted | schema.psd1 AppxRemoval |
| Paint `DisableGenerativeErase`, `DisableRemoveBackground` | skipped | no documentation that Paint reads these values |
| Chrome AI policies | skipped | Chrome is not part of the image |
| Edge sign-in, collections, top sites, quick links, gamer mode, import on launch | skipped | user preferences |
| Hibernation, shutdown timeout, `SystemResponsiveness`, mouse precision, tray icons, snap, transparency, Start layout, Windows Update choices | skipped | user preferences / covered by other WinEase options |

## builtbybel/Crapfixer 1.18.200 -> 2.01.41

2.x downloads its catalogue at run time from the `main` branch (`Wintweak2.ini`,
`Winappx.ini`); that catalogue was compared on 2026-10-21. Every registry tweak in it is
either present in WinEase or the same rule as Bloatynosy above (same author).

| Item | Decision | Where |
|---|---|---|
| Appx `Microsoft.MicrosoftStickyNotes` | adopted (fix) | schema.psd1: the existing pattern `*Microsoft.StickyNotes*` never matched the real package name |
| Appx `Microsoft.Messaging`, `Microsoft.Whiteboard` | adopted | schema.psd1 AppxRemoval (Legacy) |
| Appx `Microsoft.OneDriveSync` | skipped | OneDrive has its own WinEase option |
| Appx `Microsoft.WindowsCamera` | skipped | used by webcams; not bloat |

## builtbybel/FluentCleaner 26.09.01

First release 2026-04, so the whole tool is new. Its cleaner rules (`Winapp2.ini`) clean
caches of a running system and do not apply to an offline image. Its debloat module
reads the same `Winappx.ini` as Crapfixer (see above). Nothing further to port.

## ionuttbara/windows-defender-remover release_def_12_8_4 -> release13-rev1

Source: every value of `script/**/*.reg`, compared with the RemoveDefender block of
10-registry (the old release's files were restructured, so the new set was compared with
WinEase directly). Everything here applies only when RemoveDefender is on (opt-in).

| Item | Decision | Where |
|---|---|---|
| Services `MsSecCore`, `MsSecFlt`, `MsSecWfp` | adopted (Start=4, only when present) | 10-registry, RemoveDefender; disabled instead of deleted because they are boot-start filters |
| Autologgers `DefenderApiLogger`, `DefenderAuditLogger` | adopted (key deleted) | 10-registry, RemoveDefender |
| `Ubpm\CriticalMaintenance_DefenderCleanup`, `CriticalMaintenance_DefenderVerification` | adopted (value deleted) | 10-registry, RemoveDefender |
| `SettingsPageVisibility=hide:windowsdefender` | adopted | 10-registry, RemoveDefender; merged with `aicomponents` from DisableWindowsAI into one value |
| Services `WinDefend`, `WdNisSvc`, `SecurityHealthService`, `wscsvc`, `webthreatdefsvc`, `webthreatdefusersvc`, `SgrmBroker`, `SgrmAgent`, `whesvc`, ELAM drivers, Tamper Protection, Defender policies, `SecurityHealth` Run entry | present | 10-registry, RemoveDefender |
| Services `Hsp`, `PlutonHeci`, `PlutonHsp2` | skipped | Pluton security processor; not Defender |
| `VulnerableDriverBlocklistEnable=0`, LSA `RunAsPPL=0`, kernel `MitigationOptions`, SEHOP, svchost mitigations | skipped | lowers system security beyond removing Defender; DisableVBS is the existing opt-in for this area |
| Defender CLSIDs, shell associations, firewall rules, TaskCache GUIDs | skipped | per-build GUIDs; the Appx/package removal already drops the shell parts |
| `Windows.SystemToast.SecurityAndMaintenance` off | skipped | also hides non-Defender maintenance warnings |

## HotCakeX/Harden-Windows-Security HardenSystemSecurity-v1.0.97.0

A hardening tool: it turns protections **on** (LSA protection, ASR rules, SMB signing,
TLS, BitLocker, App Control, ...). None of it removes bloat; the registry-only part
was ported into the new opt-in tweak `HardenSystemSecurity` (default off, no preset
enables it).

| Item | Decision | Where |
|---|---|---|
| LSA protection `RunAsPPL` (2, no UEFI lock) | present | 10-registry, HardenSystemSecurity |
| WDigest `UseLogonCredential=0` | present | 10-registry, HardenSystemSecurity |
| NTLMv2 only `LmCompatibilityLevel=5` | present | 10-registry, HardenSystemSecurity |
| `RestrictAnonymous` / `RestrictAnonymousSAM` = 1 | present | 10-registry, HardenSystemSecurity |
| Remote Assistance off (`fAllowToGetHelp=0`, system + policy) | present | 10-registry, HardenSystemSecurity |
| AutoRun / AutoPlay off (`NoDriveTypeAutoRun=255`, `NoAutorun`, `NoAutoplayfornonVolume`) | present | 10-registry, HardenSystemSecurity |
| PowerShell script block logging | present | 10-registry, HardenSystemSecurity |
| ASR rules, Defender settings, BitLocker, App Control, TLS ciphers, SMB signing, firewall, user rights, country IP blocking | skipped | need the running system (Defender/WMI/cmdlets), or break compatibility too broadly for an image default |
| Conflicts with WinEase | reported | RemoveDefender, DisableVBS, DisableUAC, DisableSmartScreen, DisableCPUMitigations are listed in `ConflictsWith` of HardenSystemSecurity (config/dependencies.psd1); DisableVBS and DisableSmartScreen are now described in SECURITY_OPTIONS.md |

## Not reviewed in detail (no release since the baseline)

| Tool | Latest release | Note |
|---|---|---|
| Sophia-Community/SophiApp | 1.0.97 (2023-07-27) | no change since the baseline |
| hellzerg/optimizer | 16.7 (2024-08-18) | no change since the baseline |
| undergroundwires/privacy.sexy | 0.13.8 (2025-03-13) | no change since the baseline |

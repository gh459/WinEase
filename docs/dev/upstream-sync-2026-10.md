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

---

# Second pass (2026-10-22)

The first pass above compared the releases up to 2026-10-21. This pass re-checked the
same list on 2026-10-22 and added the tools that publish their tweak catalogue at run
time (WinUtil's `config/tweaks.json`, Crapfixer's `Wintweak2.ini` / `Winappx.ini`,
Bloatynosy's `Data\*.ini`, Sophia's module and the ReviOS playbook), because those
catalogues are what the tools actually apply on a running system. The upstream code was
again read as data and never run.

## Release status on 2026-10-22

| Tool | README (reviewed 2026-10-21) | Latest release | Default branch | Result |
|---|---|---|---|---|
| ChrisTitusTech/winutil | 26.10.07 | 26.10.07 | 30 commits ahead | 4 changes, see below |
| farag2/Sophia-Script-for-Windows | 8.0.0 | 8.0.0 | 17 commits ahead | no new tweaks |
| Sophia-Community/SophiApp | 1.0.97 | 1.0.97 | ahead | no tweak content |
| hellzerg/optimizer | 16.7 | 16.7 | ahead of the tag | 2 changes, see below |
| builtbybel/Bloatynosy | 1.01.103 | 1.01.103 | 2 commits ahead | no rule changed |
| meetrevision/revision-tool | 2.14.1 | **2.14.3** | ahead | new release, see below |
| meetrevision/playbook (ReviOS) | not reviewed | **26.10** | ahead | first review, see below |
| atlas-os/atlas | 0.5.0-hotfix | 0.5.0-hotfix | ahead | 1 change, see below |
| raphire/win11debloat | 2026.08.24 | 2026.08.24 | ahead | 1 change, see below |
| ionuttbara/windows-defender-remover | release13-rev1 | release13-rev1 | unchanged | nothing new |
| undergroundwires/privacy.sexy | 0.13.8 | 0.13.8 | unchanged | nothing new |
| builtbybel/Crapfixer | 2.01.41 | 2.01.41 | unchanged since 2026-10-08 | catalogue unchanged |
| builtbybel/FluentCleaner | 26.09.01 | 26.09.01 | unchanged | nothing new |
| SysAdminDoc/Debloat-Win11 | v2.3.8 | v2.3.8 | ahead | 2 changes, see below |
| HotCakeX/Harden-Windows-Security | HardenSystemSecurity-v1.0.97.0 | same | ahead | only UI files |

## meetrevision/revision-tool 2.14.1 -> 2.14.3

Source: the diff of `src/lib/core/services/win_registry_command.dart`,
`win_registry_service.dart` and `src/lib/features/winsxs/domain/win_package_service.dart`.

| Item | Decision | Where |
|---|---|---|
| The feature IDs `61199980` (WindowsAppRuntime_FallbackToStableFix) and `40012896` (Servicing_FileExplorerRibbonFallbackFix) added to the AI removal | skipped | WinEase keeps `Microsoft.AIFabric.CBS`, so Explorer never falls back to the legacy ribbon; `MicrosoftWindows.Client.CBS` and `*CoreAI*` are on the protection list of phase 05 |
| The feature override mechanism itself (an obfuscated ID written to `FeatureManagement\Overrides`) | adopted (partly) | `WinEasehelpers.ps1` (`ConvertTo-WinEaseFeatureIdOverride`), `phases/10-registry.ps1` (`DisableSearchWebView2`) |
| `deleteFeatureOverride` renamed to `resetFeature`, the new `registry feature enable/disable/reset` CLI | skipped | WinEase only ever disables a feature inside the image; it never has to re-enable one |

## meetrevision/playbook (ReviOS) 26.04 -> 26.10 -> main

Source: `src/Configuration/Tasks/registry/**/*.yml`, `src/Configuration/Tasks/packages/*.yml`
and the `meetrevision/packages` catalogue. The playbook had never been reviewed before (the
first pass only read the Revision Tool's Dart sources), so the whole 26.04 -> 26.10 range
was compared.

| Item | Decision | Where |
|---|---|---|
| `FeatureManagement\Overrides` `3369582732` = 0 (SearchWebView2_Master, feature 43998308) | adopted | 10-registry, `DisableSearchWebView2` |
| `FeatureManagement\Overrides` `1694661260` = 0 (feature 37926450, main branch) | adopted | 10-registry, `DisableSearchWebView2` |
| `ShellUIHosts\CrossDeviceResumeHost\ProcessPath` = `%SystemRoot%\system32\ShellHost.exe` | adopted | 10-registry, DisableCrossDevice |
| `Spynet\SubmitSamplesConsent` = 2 | adopted (fix) | 10-registry, DisableDiagnosticData and RemoveDefender; the old value 0 meant "always prompt" |
| `AppPrivacy\LetAppsAccessSystemAIModels` = 2, `LetAppsAccessGenerativeAI` = 2 | adopted | 10-registry, DisableWindowsAI |
| `SearchSettings\IsWebSuggestionsEnabled` = 0, `IsStoreSuggestionsEnabled` = 0 | adopted | 10-registry, DisableWebSearch |
| `WinStore.Tasks.WindowsSearchTask` `ActivationType` = 0xFFFFFFFF, `Server` = '' | adopted | 10-registry, DisableWebSearch |
| `MRT\DontReportInfectionInformation` = 1 | adopted | 10-registry, DisableDiagnosticData |
| `WindowsMediaPlayer\DisableAutoUpdate` = 1 | adopted | 10-registry, DisableCloudContent |
| `FeatureManagement\Overrides` `1387020943` (CrossDeviceResume) and the IFEO redirect of `CrossDeviceResume.exe` | skipped | 26.10 replaced both with the shell host redirect above; WinEase keeps the IFEO block as the second layer |
| `DisableAutomaticRestartSignOn` = 1 | skipped | 26.10 removed it and WinEase never had it |
| The `telemetry-removal` package (utcapi / utcutil / sqmapi stubs) | skipped | needs signed stub binaries; an offline image cannot ship them |
| The `ai-removal` package (`Microsoft-AIFabric-CBS-1-6`, `Microsoft-OneCore-IsoEnvBroker`, the `Microsoft-Windows-AIComponentMgmt` component) | skipped | WinEase removes the FoD packages instead of replacing them with CBS components |
| The Appx removal moved from `APPX-REMOVER.ps1` to `revitool.exe` | skipped | infrastructure of the upstream tool, not a tweak |

## ChrisTitusTech/winutil (main, 30 commits ahead of 26.10.07)

Source: `config/tweaks.json` and `config/applications.json`.

| Item | Decision | Where |
|---|---|---|
| The new tweak `WPFTweaksSvcHostSplitting` (`SvcHostSplitThresholdInKB`) | present | WinEase sets the same value in 10-registry (SvcHostConsolidation). WinUtil derives it from the memory of the running machine, WinEase uses a fixed 64 GB, because the value has to fit the target PC and not the build host |
| `Siuf\Rules\PeriodInNanoSeconds` removed | adopted | 10-registry, DisableDiagnosticData |
| `Control Panel\Keyboard\KeyboardDelay` changed from REG_DWORD to REG_SZ | adopted | 10-registry, `DisableKeyboardDelay` (new, off by default) |
| `Control Panel\Mouse\MouseSpeed` / `MouseThreshold1` / `MouseThreshold2` changed from REG_DWORD to REG_SZ | adopted | 10-registry, `DisableMouseAcceleration` (new, off by default) |
| `WPFTweaksDisplay` / `WPFTweaksServices` / `WPFOOSUbutton`: the descriptions changed | skipped | no behaviour change |
| `applications.json`: `imhex`, `opencode` and `pstools` added, package ids corrected | skipped | the catalogue of the software installer, not part of an image build |

## hellzerg/optimizer (master, ahead of the 16.7 tag)

| Item | Decision | Where |
|---|---|---|
| `Edge\Edge3PSerpTelemetryEnabled` = 0 | adopted | 10-registry, DisableTelemetryAndDiagnostics |
| `Edge\ExtensionManifestV2Availability` = 2 | skipped | allows Manifest V2 extensions - a feature, not a debloat |
| `Chrome\ExtensionManifestV2Availability` = 2 | skipped | Chrome is not part of the image |
| `Session Manager\Configuration Manager\EnablePeriodicBackup` = 1 | skipped | enables a feature of the running system |

## atlas-os/atlas (main, ahead of 0.5.0-hotfix)

| Item | Decision | Where |
|---|---|---|
| `Qol.psm1`: the accessibility `Flags` and the keyboard hotkeys changed from REG_DWORD to REG_SZ | adopted | 10-registry, `DisableAccessibilityHotkeys` (new, off by default) |
| `Qol.psm1`: `Control Panel\Accessibility\HighContrast\Flags` = 0 | skipped | High Contrast is a visual accessibility mode and not a hotkey; switching it off would work against the users who need it |
| `DISABLEPNP.ps1` and the network discovery command file | skipped | quoting and file format only |

## SysAdminDoc/Debloat-Win11 (main, ahead of v2.3.8)

Source: the new `Modules/PolicyCatalog.psd1` and the changed modules.

| Item | Decision | Where |
|---|---|---|
| `DisableAgentConnectors` / `DisableAgentWorkspaces` / `DisableRemoteAgentConnectors` = 2 | adopted (fix) | 10-registry, DisableWindowsAI; the value was 1 |
| `Shell\Copilot\IsCopilotAvailable` = 0 (user scope) | adopted | 10-registry, DisableCopilot |
| `InputPersonalization\RestrictImplicitTextCollection` / `RestrictImplicitInkCollection` = 1 | present | 10-registry, DisableTelemetryAndDiagnostics |
| `PolicyCatalog.psd1` consolidates the values of the old `WindowsAiPolicies.psd1` and `HkcuTweaks.psd1` | skipped | structure of the upstream tool |
| The error handling, the hive mounting and the new test tooling | skipped | infrastructure of the upstream tool |

## raphire/win11debloat (master, ahead of 2026.08.24)

| Item | Decision | Where |
|---|---|---|
| The new feature `DisableChromeAI` (16 Chrome policies) | skipped | Chrome is not part of the image |
| `Disable_Search_Highlights.reg` and `Disable_Search_History.reg` removed | skipped | the values moved into the GUI of the tool; WinEase already writes them |
| The localisation refactor (`Config\Languages\*`) | skipped | structure of the upstream tool |

## No change since the last review

| Tool | Latest release | Note |
|---|---|---|
| Sophia-Community/SophiApp | 1.0.97 (2023-07-27) | WPF front end, no tweak content |
| undergroundwires/privacy.sexy | 0.13.8 (2025-03-13) | no change since the baseline |
| builtbybel/FluentCleaner | 26.09.01 | no change since the baseline |
| builtbybel/Bloatynosy | 1.01.103 | the rule catalogue `Data\WinRules.ini` and `Data\AppRules.ini` is byte identical to the release |
| builtbybel/Crapfixer | 2.01.41 | the catalogue it downloads at run time (`Wintweak2.ini`, `Winappx.ini`) has not changed since 2026-10-08 |
| ionuttbara/windows-defender-remover | release13-rev1 | no change since the baseline |
| HotCakeX/Harden-Windows-Security | HardenSystemSecurity-v1.0.97.0 | only the UI files of the app changed |
| farag2/Sophia-Script-for-Windows | 8.0.0 | only the supported build number (26300) and the localisations changed |

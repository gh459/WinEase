# **WinEase 🔬**

A PowerShell script to build a heavily trimmed-down, lightning-fast Windows 11 image.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Architecture: x64 | ARM64](https://img.shields.io/badge/Architecture-x64%20%7C%20ARM64-blue.svg)](#)
[![OS: Windows 11 23H2 / 24H2 / LTSC / Canary](https://img.shields.io/badge/Windows%2011-23H2%20%7C%2024H2%20%7C%20LTSC%20%7C%20Canary-brightgreen.svg)](#)

---

## **Introduction**

Introducing **WinEase builder**, a powerful PowerShell script that creates an ultra-minimal Windows 11 image!

The goal of WinEase is to automate the creation of a streamlined Windows 11 image. The script uses native DISM capabilities and official deployment tools (`oscdimg.exe`) to create a bootable ISO with no third-party binary dependencies. An included unattended answer file bypasses Microsoft Account requirements during setup, enables automatic local administrator logon, enables CompactOS compression, and configures a clean, bloatware-free desktop.

---

## **✨ Features & Improvements in this Fork**

- **⚡ Zero-Click Setup Automation (100% Shift+F10 Free)**:
  - Completely eliminates the manual `Shift + F10` prompt and "Windows could not complete the installation" dialog by orchestrating `ChildCompletion\setup.exe = 3`, `SetupType = 0`, `SystemSetupInProgress = 0`, and `OOBEInProgress = 0` across `windowsPE`, `specialize`, `SetupComplete.cmd`, offline `zSYSTEM`, and `FirstLogon.ps1`. Setup transitions directly to the lightweight desktop with zero user clicks.
- **🎮 Low-Latency & Next-Gen Gaming Engine (AtlasOS / ReviOS Aligned)**:
  - **Hardware-Accelerated GPU Scheduling (HAGS)** enabled by default (`HwSchMode = 2`).
  - **Message Signaled Interrupts (MSI)** automatically enabled across all PCI devices to eliminate interrupt sharing latency.
  - **CPU Core Scheduling & Unparking**: Neutralizes micro-stutter on hybrid Intel P/E-core and AMD 3D V-Cache architectures by disabling core parking and tuning Energy Performance Preference (`EPP = 0`).
  - **Windows Update Driver Protection**: Excludes generic GPU/chipset drivers from Windows Update (`ExcludeWUDriversInQualityUpdate = 1`), preventing vendor driver rollbacks.
- **🚫 Modern AI, Recall & 24H2/26H2 Canary Bloatware Offline Block**:
  - Offline policy blocks for DirectML, Windows AI, Windows Copilot, and Recall snapshotting (`TurnOffRecall = 1`, `DisableAIDataAnalysis = 1`).
  - Edge Copilot sidebar and startup boost neutralized.
  - Edge Update auto-reinstallation blocked while strictly safeguarding the embedded WebView2 runtime required for Discord, Steam, and desktop apps.
  - Japanese IME cloud candidate telemetry opted-out.
- **💽 High-Speed VHDX Scratch Disk Engine (`-UseVHDX` / `-FastVHDX`)**:
  - Dynamically mounts an expandable 30 GB VHDX volume as the DISM scratch directory, eliminating host NTFS fragmentation and accelerating image unpacking and exporting.
- **📊 Visual HTML Build Report & Test Suite**:
  - Automatically exports a dark-themed visual report (`WinEase_report.html`) summarizing baseline vs optimized WIM sizes, saved GB, compression percentage, and feature status.
  - Includes built-in self-test diagnostics (`-TestSelf`) and a complete Pester test suite (`tests/`, split by area).
- **📁 Custom Post-Install Scripts Hook**:
  - Place custom `.ps1`, `.bat`, `.cmd`, or `.reg` files in `tools/custom-scripts/` to have them automatically extracted and executed sequentially during post-install first logon (a metadata header can set the order, a tweak condition, the error policy and the description — in the comment syntax of the file type).
  - Manage the same folder from **Tab 10 "Custom Scripts"**: add, remove, reorder, edit the metadata and preview where each file lands in the image without touching the file system by hand.
- **🌐 Universal Language Independence (PR #6 by Tinnitus97)**:
  - Works on any host operating system language/locale without permission or translation errors.
  - Replaces localized tools (`takeown`/`icacls`) with native .NET Access Control Lists (`Set-Acl` via Well-Known Administrator SID `S-1-5-32-544`).
- **🛡️ Customization Options (Issues #1, #9, #10, #12, #13)**:
  - **Complete User Account Control (UAC) Deactivation**: UAC elevation prompts and secure desktop dimming are completely disabled (`ConsentPromptBehaviorAdmin = 0`, `PromptOnSecureDesktop = 0`) across both offline registry hives and the unattended answer file, eliminating permission popups for administrators.
  - **Japanese Keyboard (106/109) Guarantee**: Prevents the common Windows clean install issue where Japanese keyboards are misdetected as 101/104 English keyboards (causing `@` and `:` key mapping mismatch) by injecting verified `kbd106.dll` and `PCAT_106KEY` configurations. Toggle with `-JapaneseKeyboard` / `-NoJapaneseKeyboard`.
  - **Windows 11 24H2 & AI Bloatware Neutralization**: Automatically disables 24H2 mandatory BitLocker device encryption (`PreventDeviceEncryption = 1`), TCG hardware security activation, and eliminates background AI telemetry (Copilot Provider, Windows Recall, Click-to-Do, and DevHome).
  - **Automatic Media Drive Detection**: Automatically detects connected official Windows 11 ISO/USB installation drives containing `sources\install.wim`, eliminating manual drive letter entry.
  - **Keep Asian IMEs**: Retain Japanese input method (`ja-JP`) while cleanly decoupling and trimming foreign Asian IMEs (`ko-KR`, `zh-CN`, `zh-TW`) and gigabytes of unneeded foreign voice packages.
  - **Windows Defender Toggle**: Option to keep Windows Defender active or remove it completely.
  - **Fonts & Drivers**: Option to preserve international font collections and essential hardware drivers.
  - **Windows Update**: Option to keep Windows Update enabled or disabled.
  - **Bluetooth & Audio**: Preserves Bluetooth audio transport and peripheral services by default so wireless headphones and controllers function properly.
  - **Recovery Environment (WinRE)**: Retain Windows RE with `-KeepRecovery` or `-KeepWinRE`. By default, WinRE is kept intact during installation so Windows Setup SafeOS staging succeeds 100%, then safely disabled and deleted online on first logon.
- **⚡ High-Speed ISO Modification & Zero-Stall Mounting Engine**:
  - **Recursive Ownership Bottleneck Eliminated**: Removed recursive `takeown /R` and `icacls /T` commands over 100,000+ files in `WinSxS`, `DriverStore`, and `WindowsApps` that stalled DISM operations for 45-90 minutes. Targeted directory deletion now handles ACL permissions on-demand.
  - **Sub-Second Workspace Purge via Robocopy Mirror**: Replaced slow and lock-prone PowerShell recursive deletions with an empty-directory mirroring engine (`Reset-DirectoryWithRobocopy`), wiping 50,000+ dirty files in < 1 second and preventing DISM mount errors (`0x80070130`).
  - **NTFS Volume Safety Verification**: Automatically verifies the workspace drive format (`Test-IsNtfsVolume`), preventing DISM reparse point failures (`0xc142011f`) when users run the script from exFAT drives (e.g. Ventoy USB drives).
  - **Real-Time DISM Progress Visibility**: Removed stdout suppression from DISM component cleanup and exports, exposing live progress percentages.
  - **Automated Windows Defender Exclusion**: Automatically adds temporary Defender exclusions for build workspaces during execution to prevent real-time file scanning slowdowns on 100,000+ image files.
- **📦 Radical ISO Size Reduction (~3.2 GB – 3.8 GB, Perplexity-Verified Safe)**:
  - **Decoupled Japanese IME & Foreign Language Stripping**: Purges heavy foreign Asian IMEs (Korean `ko-KR`, Chinese `zh-CN`/`zh-TW`), foreign speech models (`zh-*`, `ko-*`, `de-*`, `fr-*`, `es-*`, `it-*`, `pt-*`, `ru-*`), and foreign Handwriting/OCR packages, saving over 800 MB – 1.2 GB in the installation image while strictly safeguarding Japanese IME (`*IME-ja-jp*`), Japanese fonts (`meiryo*`, `yugoth*`, `msgoth*`, `msmin*`, `yumin*`), and Text Services Framework (`ctfmon.exe`).
  - **Foreign Supplemental Fonts Trimmed**: Safely purges non-Latin/non-Japanese font collections (Chinese Hans/Hant, Korean Kore, Devanagari, Thai, Ethiopic, Syriac, Cherokee, etc.), saving ~200 MB.
  - **Obsolete FOD Packages Removed**: Purges deprecated and unused optional features including `WMIC` (deprecated in 24H2), `Printing-WFS` (Fax & Scan), `WirelessDisplay` (Miracast Connect), `SNMP`, `Telnet`, `SimpleTCP`, and `RDC`.
  - **Offline System Caches & Setup Logs Cleaned**: Wipes build-time update caches (`SoftwareDistribution\Download`), `System32\LogFiles`, `Prefetch`, and setup temporary files before unmounting.
  - **High-Speed Stable LZX install.wim Export & Setup Error 0x8007000D Fix**: Defaults to rock-solid LZX `/Compress:max` export to `sources\install.wim` (exports in ~20 seconds), preventing the known Windows 11 24H2 DISM `WIMGAPI.DLL` crash (`0xc0000005`) that occurred during LZMS solid recovery compression. Eliminates the critical bug where a crashed 208-byte `install.esd` remnant caused the valid `install.wim` to be deleted, which resulted in Windows Setup error `0x8007000D - 0x4002C` (ERROR_INVALID_DATA). Includes strict payload (> 1 GB) and ISO (> 1.5 GB) size validation, with an optional `-ExportESD` flag for systems that support solid LZMS export.
  - **Zero Setup-Breaking Hacks**: Strictly keeps `winre.wim` intact during offline build (preventing `0x80070002` SafeOS staging failures) and keeps `boot.wim` under LZX `/Compress:max` (avoiding `0xc0000001` unbootable media), with CBS component integrity guaranteed via official DISM `StartComponentCleanup /ResetBase`.
- **🚫 Safe Debloat & Suppression of Target Components**:
  - **Windows Backup**: Complete policy suppression (`DisableBackupRestore = 1`, `DisableCloudBackup = 1`, `DisableConsumerAccountStateContent = 1`), `AppListBackup` scheduled task removal, and concealment from Settings (`hide:backup`). Avoids breaking `Client.CBS` system dependencies.
  - **Windows Security & Defender**: With `RemoveDefender`, the engine and payload are removed, the `WinDefend` / `WdNisSvc` / `SecurityHealthService` service keys are deleted, the `WdBoot` / `WdFilter` / `WdNisDrv` drivers are taken out of the boot path (`Start=4`), the `Microsoft.SecHealthUI` package is removed, and the Settings page is hidden (`hide:windowsdefender`). If Defender is kept, the hardening option only sets the real-time/antispyware policies and removes the tray entry.
  - **Accessibility (Voice Access / Magnifier / On-Screen Keyboard / Narrator / Live Captions)**: Preserves essential binaries (`osk.exe`, `Narrator.exe`, `magnify.exe`) in `System32` during setup to ensure 100% OOBE pass stability, while hotkeys (Win+Enter, 5x Shift StickyKeys, FilterKeys, ToggleKeys), auto-launch flags, and settings pages are suppressed. Post-OOBE IFEO redirection is safely applied in `FirstLogon.ps1` to prevent any execution on the desktop.
  - **Get Started / Tips**: Fully removed offline via DISM `Remove-AppxProvisionedPackage` with fallback cleanup across all user accounts in `FirstLogon.ps1`, coupled with `DisableSoftLanding` promotional suppression.
  - **🔄 OOBE Boot Loop & Setup Crash Fixed**: Solved the infinite boot loop at the "Please wait" screen. Root causes fully resolved:
    - **WebView2 Runtime Preserved**: Preserved `C:\Windows\System32\Microsoft-Edge-WebView` and its WinSxS packages. Windows 11 OOBE (`CloudExperienceHost`, `msoobe.exe`) strictly requires the embedded WebView2 runtime to render setup interfaces; removing it crashed OOBE on launch. Edge browser UI (`Program Files (x86)\Microsoft\Edge`) is still cleanly removed.
    - **Reboot Loop Trap Removed (`ErrorHandler.cmd`)**: Completely eliminated `ErrorHandler.cmd` and `ChildCompletion` registry overrides from the unattended answer file, preventing reboot loops and allowing Windows Setup to proceed naturally without interference.
    - **Core Accessibility Binaries Retained**: Preserves essential accessibility binaries (`osk.exe`, `Narrator.exe`, `magnify.exe`) in `System32` to prevent handle exceptions during OOBE Ease of Access subsystem initialization.
    - **Safe FontCache Lifecycle**: Defers `FontCache` and `FontCache3.0.0.0` disabling to `FirstLogon.ps1` (after desktop logon) so localized DirectWrite font rendering succeeds 100% during setup.
    - **Strict Empty Passwords & Permanent AutoAdminLogon**: Normalized all `<Password><Value></Value>` tags to strictly empty single-line elements across all architectures, eliminating whitespace and newline parsing issues where Windows Setup hashed carriage returns as actual password characters. Configures persistent registry `AutoAdminLogon = 1` with `ForceAutoLogon = 1`, and eliminates password prompts on wake/idle.
  - **🖱️ Mouse Cursor & Pointer Display Guarantee**: Preserves essential Windows cursor bitmaps in `C:\Windows\Cursors` (~5 MB), ensuring the mouse pointer (`aero_arrow.cur`) is always rendered and fully functional throughout setup and on the installed desktop.
  - **Account Collision Resolved**: Centralized local account creation cleanly into `oobeSystem` `<LocalAccount wcm:action="add">`, eliminating `ERROR_USER_EXISTS` (0x80070524) collisions with `Specialize.ps1`.
  - **Setup Pre-Finalize SafeOS Crash Fixed**: Solved the `0x80070002` / `0x8007000B` error where Windows Setup crashes at ~100% when attempting to stage missing or corrupt `winre.wim`. `winre.wim` is preserved at build time and removed cleanly via online `reagentc /disable` during `FirstLogon.ps1`.
  - **SafeDebloat Component Store Mode (Default)**: Protects CBS servicing integrity and localized (`ja-JP`) resources using official DISM `StartComponentCleanup /ResetBase` + cache pruning. Aggressive pruning mode (`-AggressiveWinSxS`) is also available with comprehensive core system and language preservation.
  - **Administrator Account Auto-Activation**: Explicitly activates the built-in Administrator account in `Specialize.ps1` for seamless unattended setup across Windows 11 Home and Pro editions.
  - **Setup Script Pre-Extraction**: Unattend scripts (`Specialize.ps1`, `DefaultUser.ps1`, etc.) are pre-extracted directly into the image during build time with robust `try/catch` error shielding, preventing specialize pass aborts.
  - **Bootable WIM Exports**: Added `/Bootable` flag to all `boot.wim` exports to prevent `0xc1510115` errors across all UEFI/BIOS firmware.
- **💿 Bundled `oscdimg.exe` & Resilient ISO Generation**:
  - **Pre-Bundled Deployment Tool**: `oscdimg.exe` is bundled directly within the repository root for offline, reliable ISO generation out-of-the-box.
  - **Multi-Mirror & DNS Fallback**: If `oscdimg.exe` is ever missing, the builder automatically falls back through multiple international CDN mirrors and Google DNS (`8.8.8.8`) resolution to resolve `msdl.microsoft.com` network lookup failures.
  - **Dynamic Bootdata (Dual BIOS + UEFI)**: Seamlessly discovers `etfsboot.com` and `efisys.bin` across candidate paths, building Dual-Boot, UEFI-only, or BIOS-only boot parameters based on available bootloaders.
  - **Robocopy Mirroring**: Uses `robocopy` with `Copy-Item` fallback to ensure 100% of directory structures and boot files are preserved from read-only ISO media.
  - **Build Integrity & Safe Cleanup**: Validates output ISO existence and size (> 1 MB), captures `oscdimg` exit codes, displays SHA256 checksums, and preserves the working directory upon error for troubleshooting.
- **⚡ Advanced Performance, Latency & Registry Optimization**:
  - **Integrated eclean & AtlasOS Optimization & Disk Cleaner**:
    - *Fault Tolerant Heap (FTH) Disabled*: Eliminates crash mitigation throttling and CPU overhead for games and intensive applications.
    - *Program Compatibility Assistant (PCA) Suppressed*: Disables PCA engine, inventory, and telemetry policies (`DisablePCA`, `DisableEngine`, `DisableInventory`, `AITEnable`).
    - *UCPD & Background Driver Pruning*: Disables Universal Consent Privacy Driver (`UCPD`) to prevent Windows from reverting user customizations, along with `GpuEnergyDrv`, `diagnosticshub`, `OneSyncSvc`, and `TrkWks`.
    - *Delivery Optimization (P2P Upload) Disabled*: Sets `DODownloadMode = 0` to prevent Windows from seeding update files to external peers.
    - *Fast Startup (Hiberboot) Disabled*: Eliminates hibernated state disk wear, dual-boot partition locks, and ensures clean cold-boot kernel state.
    - *Automated Disk Cleanup (Cleaner Logic)*: Integrates `VolumeCaches` preset configuration with `cleanmgr.exe /sagerun:64` and automatic purge of user/system Temp, CrashDumps, Minidumps, and Windows Event logs.
  - **Integrated optimizerDuck & sparkle**: Applies system latency and responsiveness optimizations, including `Win32PrioritySeparation` quantum boost (0x26), Multimedia Class Scheduler Service (MMCSS) gaming priority & GPU scheduling, and network throttling index disabling.
  - **Integrated Revo Registry Cleaner Tuner**: Full integration of all 6 optimization categories:
    - *Explorer*: Auto-complete URL/path suggestions, show drive letters first, disable info tips.
    - *Desktop & Start Menu*: Reduce hover delay times, enable classic Alt+Tab, kill hung apps faster (`WaitToKillAppTimeout = 2000`).
    - *System & Services*: `ServicesPipeTimeout` optimization, network file sharing responsiveness.
    - *Visual Effects*: Disable Mica/Acrylic transparency while keeping font smoothing enabled.
- **🚀 AtlasOS & ReviOS Radical Debloat & Latency Engine**:
  - **Low-Latency System Timer & BCD Tuning**: Configures high-resolution synthetic timers (`useplatformclock false`, `disabledynamictick yes`, `tscsyncpolicy Enhanced`, `bootux disabled`, `quietboot on`), completely eliminating dynamic tick jitter and micro-stuttering in latency-sensitive applications and games.
  - **Gaming Responsiveness & Quantum Scheduling**: Injects `Win32PrioritySeparation = 0x26` (38 decimal: short, variable quanta favoring foreground tasks), tunes MMCSS `SystemResponsiveness = 0` (0% multimedia throttling), sets gaming thread priority to 6, and sets GPU scheduling priority to 8.
  - **Ultra-Low Latency Network Stack**: Disables Nagle's algorithm (`TcpAckFrequency = 1`, `TCPNoDelay = 1`) across all active and virtual network adapters for immediate packet dispatch, lowers `TcpTimedWaitDelay = 30`, sets `MaxUserPort = 65534`, and eliminates Windows QoS 20% bandwidth reservation (`NonBestEffortLimit = 0`).
  - **Complete Hibernation Purge**: Executes `powercfg.exe /hibernate off` on first logon to eradicate `hiberfil.sys`, instantly recovering **4 GB – 16+ GB of SSD storage** and eliminating fast-startup shutdown disk thrashing.
  - **Ultimate Performance Power Scheme**: Automatically provisions and activates the hidden Windows Ultimate Performance power scheme (`e9a42b02-d5df-448d-aa00-03f14749eb61`), preventing aggressive core sleeping and frequency drops.
  - **NTFS File System Overhead Reduction**: Disables legacy 8.3 short filename generation (`NtfsDisable8dot3NameCreation = 1`) and disables NTFS last-access timestamp tracking (`NtfsDisableLastAccessUpdate = 1`), drastically cutting file I/O operations and disk overhead.
  - **Kernel Paging & Crash Dump Overhead Elimination**: Locks the core NT kernel executive in physical RAM (`DisablePagingExecutive = 1`), disables zeroing pagefile at shutdown for faster reboots, disables memory crash dump generation (`CrashDumpEnabled = 0`), and suppresses crash logging events.
  - **Deep Service & Diagnostics Stripping**: Disables 13+ unnecessary telemetry, parental, and legacy background services offline (`WpcMonSvc`, `WMPNetworkSvc`, `PhoneSvc`, `WbioSrvc`, `SharedAccess`, `RemoteRegistry`, `RetailDemo`, `shpamsvc`, etc.) and purges diagnostic scheduled tasks offline.
  - **🛠️ Post-Install Desktop Maintenance Tools**: Automatically deploys a dedicated management toolkit folder directly to `C:\Users\Public\Desktop\Atlas-ReviOS Tools` containing 6 one-click `.bat` scripts:
    1. `1. Toggle Windows Defender.bat`: Enable or disable Defender real-time protection and services on demand.
    2. `2. Toggle Windows Update.bat`: Enable or disable Windows Update services (`wuauserv`, `UsoSvc`, `BITS`).
    3. `3. Toggle Hibernation.bat`: Enable or disable hibernation and toggle `hiberfil.sys` disk footprint.
    4. `4. Toggle Bluetooth.bat`: Enable or disable Bluetooth support services (`bthserv`, `BTAGService`).
    5. `5. Toggle Print Spooler.bat`: Enable or disable the print spooler service (`Spooler`).
    6. `6. Free Memory & Clear Temp.bat`: Instant purge of temporary files, crash dumps, and Win32 working sets.
- **⚡ Radical RAM Optimization (Idle Memory Baseline ~600 MB – 800 MB, Theoretical Architectural Limit)**:
  - **SvcHost Grouping**: Sets `SvcHostSplitThresholdInKB` to 64 GB, consolidating 70–90 separate `svchost.exe` instances into 12–15 shared processes, instantly freeing 500 MB – 800 MB of RAM.
  - **Strict Kernel Paging (`DisablePagingExecutive = 0`)**: Fully eliminates kernel driver physical memory locking, allowing Windows to dynamically page inactive kernel code to disk and reclaiming 80 MB – 150 MB of physical RAM.
  - **Dynamic Kernel Memory Management**: Preserves NT Kernel dynamic pool allocation to prevent `STATUS_INSUFFICIENT_RESOURCES` driver allocation deadlocks during setup, while aggressively paging idle structures.
  - **Application Pre-Launch & Prefetch Disabling**: Neutralizes `Disable-MMAgent -ApplicationPreLaunch`, `Disable-MMAgent -ApplicationLaunchPrefetching`, and `Disable-MMAgent -OperationAPI`, preventing Windows from pre-allocating hundreds of megabytes into RAM before apps are even launched.
  - **Kernel Memory Manager & Page Combining**: Enables NT Kernel `PageCombining` (copy-on-write duplicate memory page coalescing) and prioritizes application working sets over file system cache (`LargeSystemCache = 0`, `DisablePageCombining = 0`).
  - **DWM & Visual Effects Lightweighting (Best Performance)**: Disables window transparency, acrylic blur, window dragging animations, and transition effects (`MinAnimate = 0`, `VisualFXSetting = 2`, `DragFullWindows = 0`, `UserPreferencesMask = 90 12 01 80 10 00 00 00`) while preserving ClearType font smoothing, minimizing `dwm.exe` direct composition buffers.
  - **Microsoft Edge & WebView2 Zero-RAM Background Block**: Completely blocks Edge and WebView2 runtime background processes and startup boosting (`BackgroundModeEnabled = 0`, `StartupBoostEnabled = 0`, `PreloadEdgeDefaultEngine = 0`), eliminating 150 MB – 300 MB of hidden webview consumption.
  - **Extreme Service Pruning & Demand-Start**: Disables diagnostic/telemetry daemons while safely setting per-user templates and DirectWrite services to Demand-Start (`FontCache`, `WpnService`, `UserDataSvc`, etc. at `Start = 3`), guaranteeing zero idle RAM overhead and 100% logon stability.
  - **Scheduled Task Trimming**: Disables heavy maintenance tasks (`ProcessMemoryDiagnosticEvents`, `RunFullMemoryDiagnostic`, `WinSAT`, `DiskFootprint\Diagnostics`, `ScheduledDefrag`, `Maps`, `Speech`) that wake up and consume RAM in the background.
  - **Guaranteed Stability (Zero Dangerous Hacks)**: Strictly rejects harmful placebo tweaks (Pagefile is kept system-managed; NDU network monitoring driver is preserved; `LargeSystemCache` is not forced to server mode).
  - **Desktop Maintenance Suite**: Deploys an on-demand maintenance suite on the desktop (`Atlas-ReviOS Tools`) including working set memory trimming, telemetry toggles, and junk cleaners without interfering with logon initialization.
- **📉 Radical Background & Windows Process Reduction (Perplexity-Verified Safe)**:
  - **Japanese IME (`ctfmon.exe`) Fully Preserved**: Unlike unsafe debloat scripts that disable the Text Services Framework and render Japanese typing broken, `ctfmon.exe` and input frameworks are strictly safeguarded.
  - **No Dangerous Executable Deletions**: Strictly avoids removing or killing `RuntimeBroker.exe`, `SearchHost.exe`, or core DCOM/RPC infrastructure, preserving Start Menu, Settings, and WinRT app stability.
  - **OneDrive Background Engine Suppressed**: Disables `OneDrive.exe` background file sync engine and autostart (`DisableFileSyncNGSC = 1`).
  - **GameBar & Screen Capture Stopped**: Completely stops `GameBarPresenceWriter.exe` and `bcastdvr.exe` from hooking into foreground windows and games (`AllowGameDVR = 0`, `AppCaptureEnabled = 0`, `GameDVR_Enabled = 0`).
  - **Telemetry & Census Runners Suppressed**: Disables scheduled tasks that periodically launch `CompatTelRunner.exe` and `DeviceCensus.exe` (Compatibility Appraiser, ProgramDataUpdater, UsbCeip, CEIP Consolidator, Device, DiskDiagnosticDataCollector, SIUF DmClient).
  - **Edge Background Mode & Startup Boost Disabled**: Neutralizes pre-launch background processes (`StartupBoostEnabled = 0`, `BackgroundModeEnabled = 0`, `AllowPrelaunch = 0`, `WebWidgetIsEnabled = 0`).
  - **Windows Error Reporting (WER) Disabled**: Halts `wermgr.exe` crash reporting daemon (`Disabled = 1`, `DontSendAdditionalData = 1`).
  - **Phone Link / CrossDevice Background Host Disabled**: Suppresses `PhoneExperienceHost.exe` background runtime (`EnableMmx = 0`, `AllowCrossDeviceExperience = 0`).
  - **UWP RuntimeBroker Instances Controlled**: Denies global background app access (`GlobalUserDisabled = 1`, `LetAppsRunInBackground = 2`), preventing Store apps from spawning multiple `RuntimeBroker.exe` child processes while maintaining 100% WinRT compatibility.
- **🐧 WSL2 & Virtualization Support (Issue #5)**:
  - Optional `-EnableWSL` flag pre-enables `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux` before WinSxS stripping, allowing full WSL2, Docker, and Linux containers on a lightweight WinEase installation.
- **💾 Custom Working Directory Support (Issues #27, #23)**:
  - Use `-WorkDir <Path>` to specify another partition (e.g. `D:\Build`) for extracting and building images, completely preventing DISM crashes (`0xc1510115`) caused by low C: drive SSD space.
  - Automatically selects an alternate drive with ample free space if C: has less than 25 GB.
- **⚡ Unattended Setup Fixed & Streamlined (Issues #3, #21)**:
  - Injects `autounattend.xml` directly into the **ISO root directory**, ensuring Windows Setup detects unattended configuration out-of-the-box.
  - Removed dummy product key to eliminate "Invalid Product Key" stops during setup.
  - **Self-Healing**: If `autounattend.xml` is missing locally, it will automatically download it from GitHub.
- **🗜️ Ultra-Compact Footprint via CompactOS (Issue #22)**:
  - Automatically enables `compact.exe /CompactOS:always` on first logon, achieving installed disk space of **2.5 GB – 3.0 GB**.
- **🎨 Shell & Icon Refresh (Issue #19)**:
  - Automatically invokes `ie4uinit.exe -show` on first logon to rebuild icon caches, preventing blank icons on Start Menu and Settings.
- **📱 ARM64 & Apple Silicon Support (Issues #2, #8, #20)**:
  - Dynamic architecture detection (`amd64` / `arm64`).
  - Automatically adjusts `autounattend.xml` processor architecture and generates UEFI-compliant boot records for ARM64 (Parallels Desktop, VMware Fusion, UTM).
  - ARM64 builds use UEFI-only bootdata (no BIOS boot sector) and the ADK arm64 `oscdimg.exe` candidate paths. Requires an ARM64 Windows 11 source ISO; verification on real ARM64 hardware/VM is recommended.
- **🚀 Canary 28020+ & Legacy Hardware Setup Bypass (Issue #29)**:
  - Automatically neutralizes `sources\appraiserres.dll` alongside offline registry `LabConfig` tweaks, allowing installation on unsupported CPUs, TPM 1.2/none, and older motherboards (e.g. Intel 6-series H67, 2nd-7th gen Core).
- **📄 MIT License Included (Issue #14)**:
  - Fully compliant open-source license.

---

## **☢️ BEFORE YOU BEGIN**

This is an **extreme debloat script** designed for rapid testing, lightweight virtual machines, and development environments.
By default, aggressive trimming removes the Windows Component Store (WinSxS) and non-essential background services to achieve the lowest possible footprint.

The resulting minimal OS is **not serviceable via cumulative updates** when WinSxS is stripped. If you require long-term servicing, enable the options to retain updates and Defender.

> **Security options:** every option that disables a Windows protection (Defender,
> Windows Update, UAC, the blank-password auto-logon, ...) is documented in
> [`docs/SECURITY_OPTIONS.md`](docs/SECURITY_OPTIONS.md) with its impact and the
> exact steps to restore the protection. The defaults of those options are
> conservative: **Defender, Windows Update and the blank-password auto-logon are
> off unless you ask for them** (the `extreme` preset still asks for them
> explicitly).

---

## **What can be removed?**

- **Bloatware & UWP Apps:**
  - Clipchamp, News, Weather, Xbox & Xbox Game Bar (`GameBarPresenceWriter.exe`), Solitaire, Copilot, DevHome, Teams, OneDrive.
  - Windows Calculator, Getting Started (`Tips`), Windows Backup (`AppListBackup`).
  - Mobile Devices & Cross-Device Resume (`crossdeviceresume`).
- **Heavy Assistive & Accessibility Binaries (Optional/Slimmed):**
  - Voice Access (`VoiceAccess.exe`), Live Captions (`Livecaptions.exe`), Magnifier (`magnify.exe`), On-Screen Keyboard (`osk.exe`), Narrator (`Narrator.exe`).
- **Web Browsers & Cloud Runtimes:**
  - Microsoft Edge, Edge Update, Edge Core, and Edge WebView2 runtimes from Program Files and WinSxS.
- **System Components & FoDs:**
  - Internet Explorer, WordPad, Steps Recorder, XPS Viewer, PowerShell ISE.
  - Diagnostics, telemetry, scheduled CEIP tasks, sponsored apps.
- **Optional Debloat (Configurable):**
  - Windows Defender & definition updates.
  - Asian Input Methods (IME - CHS, CHT, JPN, KOR).
  - Legacy drivers (printers, scanners, fax).
  - Windows Update background services.
  - Bluetooth services (if Bluetooth hardware is not needed).

---

## **Instructions**

### **1. Prerequisites**

> [!WARNING]
> **DO NOT USE `MediaCreationTool.exe` TO DOWNLOAD THE WINDOWS 11 ISO!**  
> `MediaCreationTool.exe` generates an ISO with solid recovery-compressed `install.esd` rather than `install.wim`. Modifying an `install.esd` image with DISM frequently causes data stream corruption (Error 1392 / 0x80070570) and missing package errors.  
> **Always download the official Windows 11 ISO directly from Microsoft's website** (choose *"Download Windows 11 Disk Image (ISO) for x64 devices"*), which includes standard, 100% reliable `sources\install.wim`.

1. Download the official Windows 11 Disk Image (ISO) containing `sources\install.wim` directly from [Microsoft Software Download](https://www.microsoft.com/software-download/windows11) (supports 23H2, 24H2, Canary, and IoT Enterprise LTSC).
2. Right-click the downloaded ISO and select **Mount**. Note the assigned drive letter (e.g. `D:`).

### **2. Running the Builder**

#### **Option A: Graphical User Interface (GUI - Recommended)**
Simply double-click **`WinEase-GUI.bat`** (or run `.\WinEasebuilder.ps1 -GUI` as Administrator).  

The settings window is a **WinUI 3** app (`gui/winui`, Windows App SDK, follows the Windows light/dark theme with Mica). It is built once with the .NET 8 SDK; `WinEase-GUI.bat` does this automatically on first launch when `dotnet` is installed, or run it yourself:

```powershell
.\gui\winui\build.ps1            # publishes gui\winui\bin\WinEaseGui.exe (self-contained, x64 or arm64)
```

When `WinEaseGui.exe` is not built, or with `-ClassicGui`, the builder shows the classic WinForms window (`gui/WinEaseGui.ps1`) with the same features. The WinUI window runs as a separate process and talks to the builder over its standard input/output (one JSON message per line, see `gui/WinEaseWinUiHost.ps1`), so presets, the dependency check, Preset Diff and the migration engine still run in PowerShell.

The GUI allows you to:
- Select an auto-detected installation media drive or browse directly to an official Windows 11 `.iso` file.
- Pick a one-click built-in profile preset (**Extreme Slim & Gaming**, **Balanced Pro**, **FAT32 USB Split-WIM**, **Portable Gaming PC**, **VM & Developer**, or **Audio & DAW Production**).
- Toggle any of the debloat, localization, hardware injection, and modular performance options. Every tab has **Select All / Clear All** buttons, including both lists on the **Advanced Debloat** tab (Select All on the destructive Experimental list asks for confirmation).
- Every switch shown in the GUI is defined in `config/schema.psd1` and is guaranteed to reach the build (covered by Pester wiring tests).
- Choose your payload format (**install.wim**, **install.esd**, or **install.swm** for FAT32 USB).
- Toggle **High-Speed VHDX Scratch Disk** (`-UseVHDX`) to eliminate host fragmentation.
- Open **Tab 8 "Migration & Backup"** to check recovery readiness, export an app inventory, estimate and run a backup/restore of personal folders, game saves and app settings, verify a backup (SHA-256), retry only failed restore tasks, diff any preset against the current window ("Preset Diff"), and switch on **Include Migration Assistant (PC-to-PC transfer tools)** (`-IncludeMigrationAssistant`). With **Bundle the default migration backup** (`-IncludeMigrationBackup`, on by default when the assistant is on), the build copies `%USERPROFILE%\WinEase_migration_backup` into the ISO as `C:\WinEaseBackup`, including personal data, and leaves the restore manual. It also shows how many user extensions were loaded and any load errors. The migration engine is loaded the first time the tab is opened.
- Open **Tab 9 "User Tweaks"** to see your own switches from `config/user/user-tweaks.psd1` whose category is not Security / Privacy / Performance / UI (those appear on tabs 2-5).
- Open **Tab 10 "Custom Scripts"** to manage `tools/custom-scripts/<Stage>/` without touching the file system by hand: add `.ps1` / `.bat` / `.cmd` / `.reg` files (they get the next order number), edit the metadata header (order, condition, error handling, description — written in the comment syntax of the file type), change the order, remove a script, and preview which file ends up in which folder of the image. See `tools/custom-scripts/README.md`.
- Pick the display language (**English / 日本語**) in the header. The window is rebuilt with everything you entered kept, and the choice is saved in `%LOCALAPPDATA%\WinEase\gui-settings.json`. Without a saved choice the OS display language is used (Japanese → 日本語, otherwise English). `-UiLanguage en|ja` overrides it for one run, also for `tools/migrator/WinEase-Migrator.ps1`. It only changes what is shown: settings, Advanced Debloat item names passed to the build, logs and reports stay English. The texts live in `config/ui-strings/en.json` and `ja.json` (UTF-8).
- Click **Start WinEase Build** to launch the build process!

#### **Option B: Interactive Console**
1. Open PowerShell as **Administrator**.
2. Navigate to the repository directory:
   ```powershell
   cd <path to your WinEase-main folder>
   ```
3. Launch `WinEasebuilder.ps1`:
   ```powershell
   .\WinEasebuilder.ps1
   ```
4. Choose a profile preset from the quick selector menu (`[1] Extreme`, `[2] Balanced`, `[3] Handheld Gaming`, `[4] VM Developer`, `[5] Audio DAW`, `[6] FAT32 Split-WIM`, `[7] Launch GUI`, `[8] Custom`), or customize settings step-by-step.
5. Once `WinEase.iso` is generated, follow the [Installation & Setup Guide](#️-installation--setup-guide-zero-click-automated-installation) below.

#### **PC Migration Tool (`tools/migrator`)**
`tools/migrator/WinEase-Migrator.ps1` backs up and restores personal folders, game saves and app settings between PCs. It is separate from the ISO build. With no `-Mode` it opens a two-tab wizard (Backup / Restore); with `-Mode` it runs on the command line:
```powershell
.\tools\migrator\WinEase-Migrator.ps1 -Mode ListRules
.\tools\migrator\WinEase-Migrator.ps1 -Mode Estimate -PackagePath D:\backup -RuleIds MyCustomGame
.\tools\migrator\WinEase-Migrator.ps1 -Mode Backup   -PackagePath D:\backup -UserFolders Documents,Desktop -DryRun
.\tools\migrator\WinEase-Migrator.ps1 -Mode Verify   -PackagePath D:\backup
.\tools\migrator\WinEase-Migrator.ps1 -Mode Restore  -PackagePath D:\backup -RetryFailedOnly
```
Modes: `ExportApps`, `Backup`, `Restore`, `Verify`, `Estimate` (plus the older `ListRules` and `RecoveryCheck`). Credential and token files are excluded unless `-IncludeSecrets` is given. Standard rules live in `tools/migrator/migration-rules.psd1`; add your own game saves and app settings in `config/user/user-migration-rules.psd1` (see [docs/EXTENSIBILITY_GUIDE.md](docs/EXTENSIBILITY_GUIDE.md) (English) / [docs/EXTENSIBILITY_GUIDE.ja.md](docs/EXTENSIBILITY_GUIDE.ja.md) (Japanese)).

### **3. Non-Interactive / CLI Automation**
You can run the builder completely unattended with built-in presets and modular optimization flags:
```powershell
# 1-Click build with built-in profile preset:
.\WinEasebuilder.ps1 -NonInteractive -Profile "extreme"

# High-performance gaming build with aggressive CPU boost, mode-2 FSE & low latency:
.\WinEasebuilder.ps1 -NonInteractive -Profile "extreme" -MMCSSGaming -NvidiaLowLatency -DisableFSE -NoKernelPaging

# Build for Handheld Gaming (ROG Ally, Steam Deck, Legion Go):
.\WinEasebuilder.ps1 -NonInteractive -Profile "handheld" -HibernateMode Reduced -CrashDumpMode Small

# Build for VM & Developer Workstations (WSL2, Hyper-V):
.\WinEasebuilder.ps1 -NonInteractive -Profile "vm"

# Pro audio production build with DAW MMCSS prioritization and USB suspend disabled:
.\WinEasebuilder.ps1 -NonInteractive -Profile "audio" -DAWMode -DisableUSBSuspend

# Fast build with /Compress:fast, dynamic VHDX scratch disk and pure UEFI boot:
.\WinEasebuilder.ps1 -NonInteractive -Profile "extreme" -UseVHDX -FastExport -UefiOnly

# Run built-in self-test diagnostics without needing an ISO:
.\WinEasebuilder.ps1 -TestSelf

# Fast-track Phase 14-18 (boot.wim patch + ISO mastering) from the payload already
# verified by the previous run - rebuilds the ISO in minutes without re-running the
# 15-minute debloat pipeline (recovers a failed final ISO generation):
.\WinEasebuilder.ps1 -ResumeIsoOnly

# Host environment stability diagnostics run automatically at every build start
# (RAM capacity, free space, SMART health - helps diagnose WIM 577 / hash-jitter).
```

### **Available Parameters:**
| Parameter | Description |
| :--- | :--- |
| `-GUI` (alias: `-UI`) | Launches the dark-themed Graphical User Interface frontend |
| `-UiLanguage <en\|ja>` | Display language of the GUI windows (display only). Default: the language saved by the GUI, else the OS display language |
| `-ClassicGui` | With `-GUI`: show the classic WinForms window even when the WinUI 3 window (`gui/winui/bin/WinEaseGui.exe`) is built |
| `-Profile <extreme\|balanced\|fat32\|handheld\|vm\|audio>` (alias: `-Preset`) | Applies an in-memory configuration preset (Built-in: zero external JSON dependency) |
| `-UseVHDX` (alias: `-FastVHDX`) | Dynamically mounts an expandable 30 GB VHDX volume as the DISM scratch directory, eliminating host fragmentation and accelerating build times |
| `-DryRun` (supports `-WhatIf`) | Resolves and verifies configuration, options, and paths without modifying disks or servicing images |
| `-Validate` | Verifies that essential binaries exist in the fully expanded final payload (checked during deep-apply verification, works for WIM / ESD / SWM) |
| `-SkipEiCfg` | Skips generating `sources\ei.cfg` (preserves OEM/LTSC channel behavior) |
| `-NoPostInstallAssets` | Omits bundling desktop and setup tool utilities into the image |
| `-CheckHealth` | Executes DISM `/Cleanup-Image /CheckHealth` verification on the mounted image |
| `-TestSelf` | Runs the built-in diagnostic and AST static analysis self-test suite |
| `-ResumeIsoOnly` (aliases: `-ResumeIso`, `-IsoResume`) | Fast-tracks Phase 14-18 (boot.wim patch + ISO mastering) against the preserved `workspace\build\sources\install.wim` from the previous run - rebuilds the bootable ISO in minutes without repeating the debloat pipeline. Deep-apply verification is intentionally skipped (hash + metadata checks run instead) |
| `-SplitWIM` (aliases: `-FAT32Compatible`, `-FAT32`) / `-NoSplitWIM` | Splits output payload into `<= 3800 MB` chunks (`sources\install.swm`, `install2.swm`) for 100% FAT32 USB UEFI compatibility |
| `-NonInteractive` (aliases: `-Silent`, `-Unattended`, `-Batch`) | Runs completely unattended without interactive prompts |
| `-Interactive` | Forces interactive prompt review for all settings |
| `-SourceDrive <Drive\|ISO>` | Windows 11 installation media drive letter or path to `.iso` file. Auto-detected and mounted if omitted |
| `-WorkDir <Path>` | Custom directory for temporary file processing (ideal if C: has < 25 GB free) |
| `-Index <Number>` | Image index inside `install.wim` to modify (e.g. `1` for Home, `3` for Pro) |
| `-KeepDefender` / `-RemoveDefender` (`-NoDefender`) | Retains or removes Windows Defender (Default: Remove) |
| `-KeepIME` / `-RemoveIME` (`-NoIME`) | Retains or removes Asian language input methods (Default: Keep) |
| `-KeepFonts` / `-RemoveFonts` (`-NoFonts`) | Retains or removes international and Asian font families |
| `-KeepDrivers` / `-RemoveDrivers` | Retains or removes printer/scanner drivers in DriverStore |
| `-KeepWindowsUpdate` / `-DisableWindowsUpdate` (`-NoWindowsUpdate`) | Retains or disables Windows Update services |
| `-KeepBluetooth` / `-DisableBluetooth` (`-NoBluetooth`) | Retains or disables Bluetooth peripheral and audio services |
| `-EnableWSL` / `-DisableWSL` (`-NoWSL`) | Pre-enables or disables WSL2 & Virtual Machine Platform |
| `-KeepRecovery` (`-KeepWinRE`) / `-RemoveRecovery` (`-NoRecovery`) | Retains or removes Windows Recovery Environment WinRE |
| `-SafeDebloat` (`-SafeWinSxS`) / `-AggressiveWinSxS` (`-TrimWinSxS`) | Component Store cleanup mode |
| `-ForceWinSxSCleanup` (`-ForceWinSxS`) | [Experimental, opt-in] Forces offline `/StartComponentCleanup` (and `/ResetBase` when combined) on Windows 11 24H2+ (26100+ Germanium), overriding the safety block. Risk: checkpoint LCU corruption (0x80070570 / 0x800f081f). Deep-apply verification + ISO payload hash check run as safety net. Off by default |
| `-UltraSlim` / `-NoUltraSlim` | Enables or disables UltraSlim target mode |
| `-JapaneseKeyboard` / `-NoJapaneseKeyboard` | Enforces or skips Japanese 106/109 keyboard layout configuration |
| `-AtlasReviOS` / `-NoAtlasReviOS` | Enables or skips AtlasOS & ReviOS debloat and low-latency tuning |
| `-ExportESD` / `-ExportWIM` (`-NoESD`) | Output image format (Default: install.wim LZX — Fast & Crash-Free) |
| `-KeepStore` / `-RemoveStore` (`-NoStore`) | Keeps or removes Microsoft Store |
| `-KeepBasicApps` | Retains native Notepad, Calculator, and Paint for daily-driver usability |
| `-KeepSearchIndex` | Retains Windows Search indexing service (`WSearch`) |
| `-RemoveLegacyFOD` | Purges legacy components: VBScript, PowerShell ISE, Windows Media Player, and SMB1 |
| `-TrimWallpapers` | Purges redundant 4K stock wallpapers and lock screen images |
| `-HibernateMode <Off\|Reduced\|Keep>` | Configures hibernation file footprint (Off, Reduced 20%, Keep) |
| `-CrashDumpMode <Automatic\|Small\|None>` | Configures kernel memory dump sizing (Automatic=7, Small=3, None=0) |
| `-DisableCPUMitigations` | [Security Trade-off: ★★★] Disables Spectre/Meltdown speculative execution mitigations |
| `-MMCSSGaming` | Enforces high multimedia scheduling quantum and responsiveness for gaming |
| `-DAWMode` | Enforces Pro Audio MMCSS and lowest DPC latency priority for audio creation |
| `-DisableMemCompression` | Disables Windows memory compression for consistent low latency |
| `-DisableFSE` | Configures Mode 2 Full-Screen Exclusive priority to bypass DWM compositor |
| `-NvidiaLowLatency` | Applies NVIDIA PowerMizer performance mode & Per-CPU Core DPC registry tuning |
| `-NoKernelPaging` | Prevents kernel paging to disk (`DisablePagingExecutive = 1`) |
| `-DisableUSBSuspend` | Prevents USB selective suspend on gaming controllers and audio DACs |
| `-NoHypervisor` | Sets `hypervisorlaunchtype off` for maximum bare-metal gaming responsiveness |
| `-RemoveWebViewPostOOBE` | Automatically uninstalls WebView2 during FirstLogon after OOBE completes |
| `-FastExport` | Uses `/Compress:fast` during DISM export for accelerated build pipelines |
| `-UefiOnly` | Configures pure UEFI bootdata without legacy BIOS boot sector fallback |
| `-AllowPhysicalDebloat` | Explicit opt-in for Advanced Debloat physical deletion (Phase 09). Selections from a profile alone do not authorize deletion; the GUI asks for the same consent |
| `-ComparePreset <name\|JSON path>` | Prints the difference between the current configuration and a built-in preset or a saved profile JSON, then exits with code 0. No build and no disk work |
| `-IncludeMigrationAssistant` | Bundles the PC migration tool (`tools/migrator`) and your `config/user/user-migration-rules.psd1` into the ISO (`Windows\Setup\Scripts\Migration`) and adds a public-desktop launcher. Also available on GUI Tab 8 |
| `-IncludeMigrationBackup` | With the assistant on, this option (on by default) copies `%USERPROFILE%\WinEase_migration_backup` to `C:\WinEaseBackup` in the image. This **includes your personal data**; restore is always started manually. Use `-IncludeMigrationBackup:$false` to ship only the tool. Also on GUI Tab 8 |
| `-StrictDependencyCheck` | Aborts the build when the dependency check (`config/dependencies.psd1`) finds any Conflict or Unknown. Without it they are reported as warnings only |
| `-TweakSettings <hashtable>` | Per-tweak overrides by key, e.g. `-TweakSettings @{ DisableCopilot = $true; User_MyTweak = $true }`. Keys defined in `config/user/user-tweaks.psd1` work too |
| `-AppxParallelism <1-8>` | Number of parallel workers for leftover `WindowsApps` folder cleanup after AppX removal (Default: 4, `1` = sequential). DISM package removal itself always runs sequentially |
| `-CpuBoostMode <Efficient\|Aggressive\|Off\|Default>` | Configures CPU power performance boost mode |
| `-PowerPreset <Desktop\|Handheld\|Balanced\|VM\|Default>` | Applies hardware-tailored power policy table |

> [!TIP]
> **CLI Option Priority Guarantee**: Specified CLI switches are strictly honored immediately. When running interactively, options already provided via CLI parameters are automatically applied and their prompts are skipped (preventing accidental overrides by pressing Enter). In unattended mode (`-NonInteractive`), all options execute deterministically without any prompt hangs.

When finished, your bootable ISO will be generated in the script directory as `WinEase.iso` with SHA256 verification hash displayed!

---

## 🛠️ Installation & Setup Guide (Zero-Click Automated Installation)

WinEase creates an ultra-minimal, high-performance Windows 11 installation by stripping redundant cloud bloatware, telemetry, and Microsoft Account requirements.

### ⚡ Zero-Click Fully Automated Installation (Default: Fully Automated, No Shift+F10 Required)
In this version, setup completion flags (`ChildCompletion\setup.exe = 3`, `SetupType = 0`, `SystemSetupInProgress = 0`, `OOBEInProgress = 0`, etc.) are pre-configured across the `specialize` pass of `autounattend.xml`, offline registry hives, and `SetupComplete.cmd` / `FirstLogon.ps1`.

As a result, **the installation proceeds 100% automatically (zero-click) from initial boot to the desktop without halting at "Windows could not complete the installation" or requiring manual `Shift + F10` intervention.**

---

### 🔧 Troubleshooting (Manual Recovery Procedure / Fallback)
In the rare event that setup pauses with "Windows could not complete the installation" (e.g., when installing manually without the answer file or in legacy environments), you can reach the desktop in under one minute using the following steps:

#### **1. Boot & Standard Installation from ISO**
- Flash the generated `WinEase.iso` to a USB drive using Rufus or Ventoy (or mount it in a virtual machine) and boot your PC.
- `autounattend.xml` will automatically handle disk partitioning, CompactOS compression, and file expansion.

#### **2. If an Error Dialog Appears**
- If setup halts with a dialog stating *"Windows could not complete the installation. To install Windows on this computer, restart the installation."*, **do NOT click [OK] yet**.

#### **3. Open Command Prompt**
- With the dialog still on screen, press **`Shift + F10`** on your keyboard.  
  *(Note: On laptops or compact keyboards, press **`Shift + Fn + F10`**).*
- A Command Prompt window (`cmd.exe`) will appear in the foreground.

#### **4. Set Setup Status (ChildCompletion) to 3**
Use either method below (GUI or single-line command) to update the registry:

- **Method A: Using Registry Editor (GUI)**
  1. In the Command Prompt, type `regedit` and press Enter to launch Registry Editor.
  2. Navigate to the following key in the left pane:
     ```
     HKEY_LOCAL_MACHINE\SYSTEM\Setup\Status\ChildCompletion
     ```
  3. In the right pane, double-click **`setup.exe`**.
  4. Change "Value data" from **`1`** to **`3`** and click "OK".
  5. Close Registry Editor and Command Prompt.

- **Method B: Instant One-Line Command (Fastest)**
  In the Command Prompt, enter (or right-click paste) the following command and press Enter:
  ```cmd
  reg add "HKLM\SYSTEM\Setup\Status\ChildCompletion" /v setup.exe /t REG_DWORD /d 3 /f
  ```
  Once "The operation completed successfully." appears, type `exit` and press Enter to close Command Prompt.

#### **5. Complete Setup and Launch the Desktop**
- Click the **[OK]** button on the original error dialog.
- The system will reboot automatically, pass completion checks, and boot directly into the Administrator desktop!

> [!NOTE]
> **Technical Background & Mechanism**:  
> A `ChildCompletion\setup.exe` value of `1` indicates that child setup tasks are still in progress or incomplete. Changing this to `3` (`STATUS_SUCCESS`) informs Windows Setup that all phases completed successfully. This avoids re-entry into unconfigured cloud OOBE flows or reboot loops and safely transitions directly to the lightweight desktop.

---

## 🎬 Original Video Demo by NTDEV

[![Here's how to use WinEase builder](https://img.youtube.com/vi/YIOesMc50Dw/maxresdefault.jpg)](https://www.youtube.com/watch?v=YIOesMc50Dw)

---

## 📝 Local Fork Revision Notes (2026-10-17)

This working copy carries the following changes on top of the upstream fork:

- **Size-first ISO reduction (④)**: language-aware decoupling of foreign Asian IMEs (ko-KR / zh-CN / zh-TW / zh-HK removed for ja-JP / en-US targets while Japanese IME + own-language fonts stay), ultraSlim trimming of self-language Speech/TextToSpeech/OCR FOD packages, `KeepExtraFonts = $false` and `RemoveStore = $true` for the extreme / fat32 / handheld presets, `RemoveDrivers = $true` (legacy printer/fax/scanner only), and ISO-side cleanup of `sources\sxs`, `langpacks`, `sflist*.dat` under ultraSlim.
- **App removal hardening**: `Microsoft.WindowsBackupApp` (Windows バックアップ, `WindowsBackupClient.exe`) and the Web Experience host (`WebExperienceHostApp.exe` = はじめに) are removed at 4 layers - provisioned Appx pattern, residual `SystemApps` folder deletion, IFEO execution block, and a FirstLogon per-user Appx fallback.
- **Windows Search disable fully enforced**: offline WSearch `Start=4` on all control sets + `DelayedAutoStart` cleanup + `disable-search.flag` staged for an online FirstLogon enforcement (Stop/Set-Service Disabled, SearchHost kill, taskbar search box hidden). Status is now visible in the `Active configuration` summary.
- **CrossDeviceResume.exe enforcement**: online FirstLogon block that kills the resume host and re-asserts the IFEO debugger redirect (the executable ships inside the protected `MicrosoftWindows.Client.CBS` shell package on 26H2, so neutralization - not deletion - is the correct approach).
- **Build reliability**: `-ResumeIsoOnly` fast re-ISO mode, extended Phase 18 verification retry cooldown, and automatic host-environment health diagnostics (RAM / free space / SMART) at every build start - aimed at the Oct 16 failure pattern (DISM 577 transient corruption + final ISO payload hash mismatch on a flaky host).
- **Repository hygiene**: `LICENSE` (MIT) restored, `tools/custom-scripts/` skeleton added, log rotation now also prunes stale `build_diagnostics` runs, and the repo is version-controlled with git.
- **Module extraction (F8)**: pure utility helpers (`ConvertTo-WinEaseNormalizedPath`, `Test-WinEasePathWithin`, `Test-IsNtfsVolume`, `Test-IsSafePathToDelete`, `New-WinEaseBuildId`) moved to `WinEasehelpers.ps1` and dot-sourced at startup, reducing the main script size and improving maintainability.
- **ARM64 (F9)**: boot.wim architecture sanity check added to Phase 14 (warns on arch mismatch); UEFI-only bootdata already used for ARM64 targets. Verification on real ARM64 hardware/VM is recommended (not yet performed in this environment).

## 📝 Local Fork Revision Notes (2026-10-19)

- **GUI settings now actually reach the build**: 24 tweak switches whose names did not match what Phase 10 read (or had no implementation), 7 variable-backed toggles such as `RadicalRAM` (previously always off), and 15 Advanced Debloat Standard items that were silently skipped are now wired through, implemented, or removed from the GUI. Older profiles using legacy key names keep working through aliases.
- **Select All / Clear All buttons fixed and extended**: the buttons on tabs 2-5 did nothing; they now work, and the Advanced Debloat tab got them too.
- **Single source of truth for settings**: every tweak and component setting lives in `config/schema.psd1`; the GUI, profiles and CLI switches are generated from it so names can no longer drift apart.
- **GUI split out**: the WinForms GUI moved to `gui/WinEaseGui.ps1` with shared control helpers (about 1,200 lines out of `WinEasebuilder.ps1`).
- **Safer AppX folder cleanup**: no more recursive `takeown /R` / `icacls /T`; junctions are removed as links so deletion never follows them out of the image.
- **Benchmark tooling**: `tools/Measure-WinEaseGuestBaseline.ps1` and `tools/Compare-WinEaseBenchmarks.ps1` measure and compare installed-system footprint, idle load and boot time.
- **Code hygiene**: `PSScriptAnalyzerSettings.psd1` added; the codebase reports zero Error/Warning findings and the Pester suite (64 tests) enforces it.
- **Toggle-state loading fixed**: GUI initialization called `ContainsKey` on `[ordered]@{}` (not implemented in Windows PowerShell 5.1), which logged 122 method-not-found errors per launch and left the per-tweak values saved in profiles unapplied; the GUI loader and Phase 10's `Test-TweakEnabled` now use `Contains`.
- **Build verification (2026-10-19)**: a full GUI-driven run completed the pipeline with "Build succeeded and safety checks passed" and produced `WinEase.iso` (7,888,314,368 bytes).
- **Dependency & impact checker (M1)**: `config/dependencies.psd1` catalog (174 entries) with Conflicts/Impacts/Unknowns detection. GUI "Check Dependencies" button, `-StrictDependencyCheck` CLI switch, HTML report section.
- **User extensibility engine (M2)**: `config/user/user-tweaks.psd1` + `lib/WinEaseExtensions.ps1` (6 functions). User tweaks/presets/custom scripts integrated into GUI, CLI, profiles. GUI Tab 8 "Migration & Backup".
- **PC migration & backup engine (M3)**: `tools/migrator/migration-rules.psd1` (15 game + 16 app rules) + `tools/migrator/WinEaseMigration.ps1` (13 functions). Custom file/folder backup preserving directory structure. `tools/migrator/WinEase-Migrator.ps1` standalone CLI/GUI wizard.
- **Extensibility guide (M4)**: `docs/EXTENSIBILITY_GUIDE.md` (English) and `docs/EXTENSIBILITY_GUIDE.ja.md` (Japanese).

## 📝 Local Fork Revision Notes (2026-10-22)

- **Upstream sync 2026-10-22**: the releases and the runtime tweak catalogues of the tools credited in the README were checked again. One tool published a new release (Revision Tool 2.14.3), the ReviOS playbook 26.10 was reviewed for the first time, and four tools had moved their default branch forward (WinUtil, optimizer, Debloat-Win11, Win11Debloat). Item by item, with the reason for every skipped tweak: [`docs/dev/upstream-sync-2026-10.md`](docs/dev/upstream-sync-2026-10.md).
- **New option `DisableSearchWebView2` (on by default)**: the two Windows feature overrides that stop `SearchHost` from starting a WebView2 runtime for the search box. The obfuscated feature IDs are computed by the new `ConvertTo-WinEaseFeatureIdOverride` helper - the same algorithm the ReviOS playbook and the Revision Tool use, so the written values are identical to theirs.
- **New options `DisableAccessibilityHotkeys`, `DisableMouseAcceleration`, `DisableKeyboardDelay` (all off by default)**: the user preferences that WinUtil and AtlasOS turned into REG_SZ values - a REG_DWORD value is ignored by Windows.
- **New AI, search and telemetry policies**: the "let apps use text and image generation" capabilities are force-denied, the agent connectors are disabled with the value the upstream tools use, the Cross Device Resume shell host is redirected to `ShellHost.exe`, the web and Microsoft Store suggestions of the search box are switched off, the Defender sample submission is never accepted and the Media Player no longer updates itself.
- **Fix**: `SubmitSamplesConsent` was `0` ("always prompt"); it is `2` ("never send") now, and it is applied whether Defender is removed or kept.

## 🔒 Development & Release Automation

| Workflow | Runs on | What it does |
|---|---|---|
| `ci.yml` | push / PR to `main` | `-TestSelf` (PowerShell 5.1 + 7), Pester (`tests\`, split by area; includes `tests\WinEase.Regression.Tests.ps1`), dry-runs of extreme / balanced / none / vm, Rust engine build |
| `lint.yml` | push / PR to `main` | PSScriptAnalyzer (errors fail) |
| `workflow-audit.yml` | changes under `.github/` | actionlint + zizmor security audit of the workflows |
| `release.yml` | `v*` tag | runs all of the above on the tagged commit, verifies the tag did not move, builds and checks the ZIP, publishes it with a `.sha256` file and a build provenance attestation |
| `claude-issue-agent.yml` | issue assigned / `@claude` from a collaborator | implements the request on a branch and opens a **draft** PR |
| `claude-pr-review.yml` | PR from a branch of this repository | **read-only, advisory** AI review comments; never approves or merges |

Verify a downloaded release: `sha256sum -c WinEase-<tag>.zip.sha256` (or `Get-FileHash`) and
`gh attestation verify WinEase-<tag>.zip -R gh459/WinEase`.

Dependency updates: Dependabot opens monthly PRs for GitHub Actions (SHA-pinned), Cargo
(`tools/winease-physical-debloat`) and NuGet (`gui/winui`). Each one goes through the full CI and
a human review; nothing is merged automatically. Security alerts: enable Dependabot alerts in
the repository settings and handle them the same way. Audit, risks and the settings that must be
made on GitHub: [`docs/dev/github-automation-audit.md`](docs/dev/github-automation-audit.md).

---

## 📁 Repository Structure

```
WinEase/
├── WinEasebuilder.ps1          # Main orchestrator (params, options, try/catch)
├── WinEasehelpers.ps1          # Compatibility loader for the split helper modules (dot-sourced at startup)
├── lib/                       # Builder function libraries (dot-sourced into the builder's scope)
│   ├── WinEaseMount.ps1        # DISM mount discovery/cleanup, mount directories, offline hives
│   ├── WinEasePathSafety.ps1   # Path normalization/containment and restore-path validation
│   ├── WinEaseSystem.ps1       # BuildContext, DISM wrapper, hive unmount, capacity and timing helpers
│   ├── WinEaseConfig.ps1       # Config conflict resolution, resume integrity, user config paths, config diff, feature-ID overrides
│   ├── WinEaseBenchmarks.ps1   # Statistical analysis and benchmark comparison
│   ├── WinEaseDependencies.ps1 # Dependency / feature-impact analysis (config/dependencies.psd1)
│   ├── WinEaseGuiSession.ps1   # Builder GUI session handling
│   ├── WinEaseGuiCore.ps1      # UI-independent GUI logic (language tables, debloat items, draft config, migration helpers)
│   ├── WinEaseFileSystem.ps1   # Directory safety checks, ownership/ACL, robust deletion, capacity
│   ├── WinEaseWim.ps1          # Native WIM export, fingerprinting and repair
│   ├── WinEaseDebloat.ps1      # Advanced Debloat engine (PowerShell / Rust) and per-target handlers
│   ├── WinEaseReport.ps1       # HTML build report (WinEase_report.html)
│   ├── WinEaseResume.ps1       # Resume-ISO mode and phase checkpoints
│   ├── WinEaseSelfTest.ps1     # Self-test suite (loaded only for -TestSelf)
│   └── WinEaseExtensions.ps1   # User extensibility engine (user tweaks, presets, custom scripts, config diff, recovery readiness)
├── gui/
│   ├── WinEaseGui.ps1          # Classic WinForms GUI, one function per tab (loaded only for -GUI / menu [7]); the migrator window reuses its parts
│   ├── WinEaseWinUiHost.ps1    # Starts the WinUI 3 window and answers its requests (JSON lines over stdin/stdout)
│   └── winui/                 # WinUI 3 window (C#, Windows App SDK); build.ps1 publishes it to winui/bin
├── phases/                    # 18 build phases (dot-sourced by orchestrator)
│   └── 01-environment.ps1 ... 18-iso.ps1   # 19 files: 09 has two (09-physical-debloat.ps1, 09-winsxs.ps1)
├── config/
│   ├── schema.psd1            # Single source of truth for every tweak/component setting, CLI switch pair and debloat engine
│   ├── presets.psd1           # Built-in presets (extreme, balanced, fat32, handheld, vm, audio)
│   ├── dependencies.psd1      # Dependency & feature-impact catalog (conflicts, impacts, unknowns)
│   ├── WinEase.config.schema.json  # JSON Schema for profile validation
│   ├── ui-strings/            # GUI strings (en.json, ja.json)
│   └── user/                  # User-edited files (all optional)
│       ├── user-tweaks.psd1          # User-defined tweaks, presets and custom scripts
│       └── user-migration-rules.psd1 # User-defined migration rules
├── tools/                     # Optional tooling
│   ├── migrator/              # PC migration tool, separate from the ISO build (bundled into the ISO with -IncludeMigrationAssistant)
│   │   ├── WinEase-Migrator.ps1    # Standalone migration & backup tool (CLI modes + two-tab GUI wizard)
│   │   ├── WinEaseMigration.ps1    # Migration engine (backup, restore, verify, app inventory, report)
│   │   └── migration-rules.psd1   # Standard migration rules (game saves, app configs)
│   ├── custom-scripts/        # User scripts by stage: PreBuild/ OfflineImage/ FirstLogon/ UserOnce/ (see its README.md)
│   ├── winease-physical-debloat/   # Rust tool for Advanced Debloat physical deletion
│   ├── Measure-WinEaseGuestBaseline.ps1  # In-guest footprint / idle load / boot-time measurement
│   ├── benchmark_winui_init.ps1          # WinUI host init-message benchmark
│   └── Compare-WinEaseBenchmarks.ps1     # Multi-run benchmark statistical comparison
├── scripts/                   # Embedded setup scripts (injected into autounattend.xml)
│   ├── Specialize.ps1
│   ├── FirstLogon.ps1
│   ├── DefaultUser.ps1
│   ├── UserOnce.ps1
│   └── Winhancements.ps1
├── templates/
│   └── report.html            # HTML report template (reference)
├── profiles/                  # Saved build profiles (JSON, incl. per-tweak TweakSettings)
├── docs/
│   ├── EXTENSIBILITY_GUIDE.md    # Extensibility guide (English): quick start + reference
│   ├── EXTENSIBILITY_GUIDE.ja.md # Same guide in Japanese
│   ├── SECURITY_OPTIONS.md    # Security-relevant options, their cost and how to revert
│   └── dev/SESSION_BRIEFS.md  # Work briefs for the S1-S12 fixes and R1-R10 restructuring
├── tests/
│   ├── _TestCommon.ps1       # Shared paths and English UI default (not a test)
│   ├── Layout.Tests.ps1
│   ├── Build.Tests.ps1
│   ├── Config.Tests.ps1
│   ├── Helpers.Tests.ps1
│   ├── Debloat.Tests.ps1
│   ├── Migration.Tests.ps1
│   ├── Gui.Tests.ps1
│   ├── Quality.Tests.ps1
│   ├── WinEase.Regression.Tests.ps1
│   └── README.md
├── .github/
│   ├── dependabot.yml
│   └── workflows/             # ci.yml (Pester), lint.yml (PSScriptAnalyzer), release.yml, claude-issue-agent.yml
├── autounattend.xml           # Unattended setup template (scripts injected at build time)
├── WinEase-GUI.bat             # GUI launcher
├── oscdimg.exe                # Bundled ISO mastering tool
├── PSScriptAnalyzerSettings.psd1  # Linter configuration
├── LICENSE                    # MIT License
├── README.md                  # This file
├── CHANGELOG.md               # Change history
├── logs/                      # Build logs (auto-rotated, gitignored)
└── build_diagnostics/         # Failed build diagnostics (auto-pruned, gitignored)
```

---

- **Original Project & Concept:** [NTDEV](https://github.com/ntdevlabs/nano11)
  - [Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2) | [Ko-fi](http://ko-fi.com/ntdev)
- **Optimization & Debloat Tool Integrations** (tweaks re-implemented in WinEase; last upstream review 2026-10-22, see [docs/dev/upstream-sync-2026-10.md](docs/dev/upstream-sync-2026-10.md)):
  - [Chris Titus Tech's WinUtil](https://github.com/ChrisTitusTech/winutil) - Open-source Windows utility & OOBE bloat mitigation (reviewed: 26.10.07 + main)
  - [Sophia Script for Windows](https://github.com/farag2/Sophia-Script-for-Windows) - Advanced Windows 11 PowerShell debloater by Dmitry Nefedov (farag2) (reviewed: 8.0.0 + main)
  - [SophiApp](https://github.com/Sophia-Community/SophiApp) - Modern WPF GUI front-end for Sophia Script (reviewed: 1.0.97)
  - [Optimizer](https://github.com/hellzerg/optimizer) - Standalone C# utility for privacy and system performance by Hellzerg (reviewed: 16.7 + master)
  - [Bloatynosy](https://github.com/builtbybel/Bloatynosy) - Windows 11 feature debloater and AI manager by Builtbybel (reviewed: 1.01.103 + main)
  - [ReviOS & Revision Tool](https://github.com/meetrevision) - Low-latency OS playbook & standalone performance optimizer (reviewed: playbook 26.10 + main, Revision Tool 2.14.3)
  - [AtlasOS](https://github.com/atlas-os/atlas) - Open-source gaming & low-latency Windows modification playbook (reviewed: 0.5.0-hotfix + main)
  - [Win11Debloat](https://github.com/raphire/win11debloat) - Lightweight PowerShell script for removing preinstalled apps and disabling telemetry by Raphire (reviewed: 2026.08.24 + master)
  - [Windows Defender Remover](https://github.com/ionuttbara/windows-defender-remover) - Script for removing Windows Defender and related components by ionuttbara (reviewed: release13-rev1)
  - [privacy.sexy](https://github.com/undergroundwires/privacy.sexy) - Open-source privacy and security hardening script generator by undergroundwires (reviewed: 0.13.8)
  - [Crapfixer](https://github.com/builtbybel/Crapfixer) - Windows 11 cleanup and privacy tweaking tool by Builtbybel (reviewed: 2.01.41 + main)
  - [FluentCleaner](https://github.com/builtbybel/FluentCleaner) - Windows system and app cache cleaner by Builtbybel (reviewed: 26.09.01)
  - [Debloat-Win11](https://github.com/SysAdminDoc/Debloat-Win11) - Windows 11 debloat script by SysAdminDoc (reviewed: v2.3.8 + main)
  - [Harden-Windows-Security](https://github.com/HotCakeX/Harden-Windows-Security) - Windows security hardening and compliance toolkit by HotCakeX (reviewed: HardenSystemSecurity-v1.0.97.0 + main)
- **Contributors:**
  - [Tinnitus97](https://github.com/Tinnitus97) (PR #6: Universal language support, robocopy WinSxS fix)
  - Community bug reports and feature requests from [nano11 Issues](https://github.com/ntdevlabs/nano11/issues)

---

## ⚖️ License

This project is licensed under the [MIT License](LICENSE).

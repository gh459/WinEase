# Changelog

All notable changes to this fork are documented here. Versions follow the upstream
WinEase scheme; entries below are local-fork additions on top of upstream 2.1.

## Unreleased (local fork, 2026-10-23) - the migration tool runs from the ISO and custom scripts have a GUI

### Changed
- **GUI logic that does not need a window moved to `lib\WinEaseGuiCore.ps1`.** Language and UI strings,
  the Advanced Debloat engine and item lists, source candidates, preset diff text, the draft config and the
  migration helpers now live there; `gui\WinEaseGui.ps1` dot-sources it, the WinUI 3 host loads only the core,
  and the Migration Assistant bundle ships it. Function names, parameters and WinForms behaviour are unchanged.
- **Setup helpers and post-install tools moved out of phase 11.** The five setup helpers
  are now files under `scripts\setup` and the Browser Grabber, Control Center and Atlas
  tools under `scripts\tools`; the phase reads them like the Defender helper. Content
  and write logic are unchanged (byte-identical, checked against recorded SHA256 values).

### Fixed
- **Camera, Photos and Snipping Tool/ScreenSketch were listed but not removed.**
  They were only removed through the broad AppX list, so clearing that one switch
  silently kept them. Each app now has its own switch (`RemoveCameraApp`,
  `RemovePhotosApp`, `RemoveScreenSketchApp`), on by default and independent of
  `RemoveAppxBloatware`; the `none` preset turns them off.
- **RemoveDefender left the engine and the Windows Security app behind.**
  `Microsoft.SecHealthUI` is protected against normal provisioned-package removal,
  so phase 05 now force-removes its payload and phase 10 clears its staged
  registration; the Defender user-mode service keys, IFEO entries and payload are
  removed rather than only disabled, and the boot-start filter drivers are taken out
  of the boot path. The online enforcement helper refuses to run unless phase 11
  staged the `remove-defender.flag`.
- **Accessibility hotkeys were disabled by removing the features.** The old
  `Flags=0` values deleted StickyKeys, FilterKeys, ToggleKeys and MouseKeys
  entirely. The image now writes the Windows "shortcut off" values
  (`506/122/58/58`) so the features stay available from Settings.
- **"Hide Recommended" did not work on Windows 11 Pro.** The Explorer policy alone
  is honoured only by Education/Enterprise; the build also writes the PolicyManager
  bridge (`Start\HideRecommendedSection` and `Education\IsEducationEnvironment`).
- **"Transparent shortcut overlay" used a visible icon.** The old
  `imageres.dll,-17` value replaced the shortcut arrow with a glyph; it now points at
  the transparent `shell32.dll,-50` resource.
- **The recovery check always reported no migration backup.** It looked for
  `Documents\WinEase_workspace\migration-manifest.json` instead of the default
  `%USERPROFILE%\WinEase_migration_backup` folder (with the old Documents location as
  a fallback).
- **Phase 13 aborted after the image had already been committed when
  `build_diagnostics` disappeared.** A parallel Pester/dry-run invocation rotated the
  diagnostics folder and removed the still-empty directory of the running build, so
  `File.AppendAllText` for the DISM export integrity report threw
  `DirectoryNotFoundException` (and DISM's `/LogPath` pointed into the missing folder).
  Phases 13 and 15 now re-create the directory before they write, and dry runs / test
  mode no longer rotate the diagnostics of a running build.
- **The bundled Migration Assistant could not start.** The bundling block of phase 11
  copied four files (`WinEase-Migrator.ps1`, `WinEaseMigration.ps1`, the rules and the
  user rules) but not `WinEasehelpers.ps1` (the safe-relative-path validator the restore
  path needs) and not `gui\WinEaseGui.ps1` (the shared WinForms parts the wizard builds
  its window from). The launcher failed with `gui\WinEaseGui.ps1 (shared WinForms parts)
  not found next to '...'` and `'Resolve-WinEaseSafeRelativePath' is not recognized`.
  Both files and the `ui-strings` folder (en/ja) are part of the bundle now, and the
  DryRun output lists them.
- **The wizard pulled the WinUI host into the image.** `gui\WinEaseGui.ps1` dot-sourced
  `WinEaseWinUiHost.ps1` unconditionally. The host is not part of the migration bundle
  (the WinUI window is a separate build), so the dot-source is conditional now: a
  bundle without the host keeps working, a repository keeps loading it.
- **Scripts of `tools/custom-scripts/` were copied into a folder nothing reads.** The
  stage runner copied a script into `Custom\<Stage>\`, but the first-logon pipeline
  reads the flat `Custom` folder with a non-recursive `Get-ChildItem -File`, so a
  `.ps1` in `Custom\FirstLogon\` was copied into the image and never ran (the folder
  was dead weight, the stage itself ran from `Custom`). Every declared script is now
  copied flat into `Custom` (FirstLogon) or `UserCustom` (UserOnce) and registered in
  `custom-scripts-manifest.json`; the `Custom\<Stage>` copy stays for the
  `FirstLogonCommands` of `autounattend.xml`.
- **A numeric prefix was doubled when a script was added or reordered.** A file named
  '01-setup.ps1' was copied as '01--setup.ps1' and reordering produced '09--move.ps1': the
  tail kept the separator the pattern had already consumed. The separator is part of the
  pattern.
- **A restore scattered the personal folders into the profile root.** The manifest keeps
  the category (`Documents`, `Desktop`, ...) next to the relative path, but the restore
  built the target from the relative path alone: `Documents\a.txt` and `Downloads\a.txt`
  both landed as `%USERPROFILE%\a.txt`, so the folders were flattened and files with the
  same name overwrote each other. The target is `<new profile>\<category>\<relative path>`
  now; the combined path is still validated against the profile.

### Added
- **The ISO can carry the default migration backup.** With the Migration
  Assistant on, `IncludeMigrationBackup` (default on) copies
  `%USERPROFILE%\WinEase_migration_backup` into the image as `C:\WinEaseBackup`.
  `restore-state.json` and temporary files are excluded; the files get
  SYSTEM/Administrators ACLs and a file count/size report. The launcher passes
  `-PackagePath "C:\WinEaseBackup"`, the migrator prefers that folder when it
  contains a manifest, and every restore still needs an explicit user action.
- **Tab 10 "Custom Scripts" (WinForms and WinUI).** Shows the scripts of a stage with
  their order, extension, size, condition, error policy and description, and offers
  Add (file picker, `.ps1` / `.bat` / `.cmd` / `.reg`, next free number), Remove,
  Edit Metadata, Change Order, Image Preview (which file lands in which image folder
  with which rights) and Open Folder. The tab edits the repository; a rebuild bundles
  the change.
- **The metadata header understands every script type.** `#` for `.ps1`, `REM` for
  `.bat` / `.cmd`, `;` for `.reg`; the writer keeps the encoding (BOM stays BOM, no BOM
  stays no BOM) and replaces a header line instead of adding a second one.
- **Helpers of the script engine**: stage map, extension list, image folder, manifest
  key, manifest writer, path resolver, header-order reader, inventory, add/remove,
  encoding probe, metadata writer, order move and image preview. The GUI and the phase
  use the same functions, so a script added in the GUI is bundled exactly like a
  hand-placed file.
- Twelve tests: the stage map and the extension list, add (next number, unsupported
  type refused), the metadata writer for `.ps1` / `.cmd` / `.reg` (comment syntax,
  replacing, no duplicate header), inventory and preview (stage, order, image path),
  order move and the refusal to delete outside the repository, the flat copy plus the
  manifest entry of both stages, Tab 10 in the WinForms window, the bundle content
  of the ISO (helpers, GUI parts, ui-strings), and a restore test that keeps the same
  file name of `Documents` and `Downloads` apart.

## Unreleased (local fork, 2026-10-22) - the Defender stays usable unless its removal was asked for

### Fixed
- **The Defender was disabled while "RemoveDefender" was off.** The conflict matrix
  (`Test-WinEaseConfigConflicts`, rule `Defender`) only looked at the *experimental*
  debloat list. A `Physical: Defender (complete removal) [~50MB]` target that reached
  the *standard* list - an older profile put the "Physical: ..." entries there - was
  therefore never seen by the rule, and phase 10 disabled `WinDefend`, `MDCoreSvc`,
  `WdNisSvc`, `Sense` and `SecurityHealthService` anyway (`Test-WinEaseDebloatTargetSelected`
  counts both lists). The payload of the target was deleted on top of that. The rule
  looks at both lists now.
- **Phase 10 has a second line of defence.** The Defender services are only disabled
  when `$removeDefender` is on, so a target that reaches the phase can never kill the
  Defender on its own. The target is not gated by `-AllowPhysicalDebloat` either, so
  the guard was the only thing between a selected target and a Defender-less image.
- **The apps of the removal list started and rendered a white window.** Phase 05 removes
  the provisioned package *and* deletes its payload folder under `Program Files\WindowsApps`,
  but the image keeps the *staged* copy of the inbox app
  (`AppxAllUserStore\InboxApp`). Windows installs that staged copy for the first user,
  so the app was registered while its payload was gone. Phase 10 now takes the staged
  registration of every removed package out of the SOFTWARE hive.
- **The per-user cleanup of the removed apps covered three of them.** Phase 11 staged
  three hardcoded names in `remove-appx-packages.flag` while the offline pass removes
  every package of the removal list (79 patterns by default). The list is now built from
  the packages phase 05 really removed, and `FirstLogon.ps1` matches the identity name
  of a package exactly (`Get-AppxPackage -Name` matches the name, not the full package
  name, so the wildcard alone never matched).
- **The safe engine deleted binaries of the system directory.** The dual-engine work
  gave the safe (PowerShell) engine the payloads of the physical targets, and those
  payloads reach into `Windows\System32`. A binary of the system directory is hardlinked
  into the component store, and deleting one of the two links desyncs the hardlink set
  of the image (the export then fails with 0x80070570 and the installer ends in a reboot
  loop). A shared library breaks even more: `wmisnmp.dll` and `snmpapi.dll` belong to
  WMI, `WinFax.dll` is the fax API of the whole system. The safe engine refuses those
  files now (Directive 2.1 of phase 08), the shared libraries left the payload of their
  targets, and the forced (Rust) engine does not delete the boot driver `mpsdrv.sys`
  and the WMI provider `wmisnmp.dll` either.

### Added
- Eleven tests: the `Defender` rule fires for the standard *and* for the experimental
  debloat list, it stays silent when the Defender is removed on purpose, phase 10 only
  disables the Defender services when the removal was asked for, phase 05 records every
  package it removed, phase 10 takes the staged registration out of the hive, phase 11
  stages the per-user cleanup of the removed packages, the first logon matches the
  identity name of a package, the safe engine recognizes the binaries of the system
  directory, the payload of a target holds no shared library, and the firewall target
  declares no payload for the safe engine.

## Unreleased (local fork, 2026-10-22) - the build no longer hangs in phase 10

### Fixed
- **The build hung in phase 10 and no ISO was produced.** The per-user UI
  preferences were a nested array literal in the phase. PowerShell's `@()`
  operator unwraps a group that holds a single entry, so a group with one entry
  arrived as four separate strings: the four fields of the entry (`Path`, `Name`,
  `Type`, `Data`) were then read one by one and `reg.exe` was called with an
  empty value name, an empty type and an empty data. A native call drops an
  empty argument, so `reg.exe` read the `/f` switch as the data and wrote a key
  named after the first character of the data (`0`, `1` or `3`) into the user
  hives, holding a single value named `/t`. On the next build that value already
  existed, `reg.exe` asked `Value /t already exists. Overwrite (Yes/No)?` and
  waited for a key press that never came - the build stopped in phase 10 and the
  ISO was never created. The UI preferences themselves were never applied.
  The table now lives in `config\ui-preferences.psd1` as a list of hashtables.
  A hashtable cannot be unwrapped by `@()`, so every entry keeps its fields, and
  the phase skips an entry with an empty field instead of calling `reg.exe`.
- **The keys that the broken table left behind are removed again.** A key whose
  only value is named `/t` is deleted from the two per-user hives, so an image
  that was built with the old code does not keep the leftovers. A real key of
  the image is never touched: the name has to be one of `0`, `1` and `3` and the
  value has to be the only one the key holds.

### Added
- `config\ui-preferences.psd1` is parsed by the self-test that checks the
  extension catalogs, so a broken table is caught before a build starts.
- Ten tests: the table holds the UI preferences, every entry is a hashtable that
  `@()` cannot unwrap, every entry names its tweak, path, value, type and data,
  every entry writes a registry type that `reg.exe` knows, every tweak of the
  table is defined in `config\schema.psd1`, the phase reads the table from the
  data file, the phase does not read the fields of a tuple by index any more,
  the phase skips an entry with an empty field, the phase removes the leftover
  keys of the old table, and every `reg.exe` call of the repository passes the
  `/f` switch - without it `reg.exe` asks `Overwrite (Yes/No)?` and waits for a
  key press.

## Unreleased (local fork, 2026-10-22) - every Advanced Debloat target can be removed by both engines

### Fixed
- **Fourteen targets of the Advanced Debloat tab could only be removed by one engine.**
  The engine column of the tab offers the engines a target declares
  (`config\schema.psd1` -> `DebloatEngines` -> `Engines`), and a target that declares
  only one engine is locked to it. Fourteen targets were in that state: the six
  physical targets the safe engine could not remove, and the eight packages the Rust
  engine could not remove. Both engines are implemented for them now:
  | Target | Engine that was missing | What the new engine removes |
  |---|---|---|
  | `Physical: Edge / WebView2 (complete removal) [~200MB]` | PowerShell | the Edge folders of `Program Files (x86)\Microsoft` and the Edge packages of `Program Files\WindowsApps` |
  | `Physical: Defender (complete removal) [~50MB]` | PowerShell | `ProgramData\Microsoft\Windows Defender` |
  | `Physical: Windows Firewall (complete removal) [~20-40MB]` | PowerShell | `mpssvc.dll` and `mpsdrv.sys` |
  | `Physical: Windows Search index (complete removal) [varies]` | PowerShell | `ProgramData\Microsoft\Search\Data` |
  | `Physical: Memory.dmp (complete removal) [varies]` | PowerShell | `Windows\Memory.dmp` |
  | `Physical: Minidump (complete removal) [varies]` | PowerShell | `Windows\Minidump` |
  | `Remove .NET Framework 3.5 [100MB]` | Rust | `physical_dotnet35`: the `v3.0` folders of `Microsoft.NET\Framework` |
  | `Remove Windows PowerShell ISE [5MB]` | Rust | `physical_powershell_ise`: `powershell_ise.exe` and the ISE module |
  | `Remove Steps Recorder [2MB]` | Rust | `physical_steps_recorder`: `psr.exe` |
  | `Remove Telnet/TFTP client [1MB]` | Rust | `physical_telnet_tftp`: `telnet.exe` and `tftp.exe` |
  | `Remove SNMP service [2MB]` | Rust | `physical_snmp_client`: `snmpapi.dll`, `snmp.exe`, `wmisnmp.dll` |
  | `Remove Windows Identity Foundation [10MB]` | Rust | `physical_identity_foundation`: the assemblies of the identity framework |
  | `Remove Fax service [5MB]` | Rust | `physical_fax`: the files of the fax client |
  | `Remove XPS Viewer [5MB]` | Rust | `physical_xps_viewer`: `xpsrch.exe`, `xpsviewer.exe` and the optional app package |
  The registered default of every target is unchanged (the safe engine for the eight
  packages, the forced engine for the six physical targets), so a build that does not
  pick an engine behaves exactly as before. The Rust engine still needs its
  `-AllowPhysicalDebloat` gate and its binary, exactly as every other physical target.
- **The services of the targets that remove a service and its binary stayed enabled.**
  The binaries of Defender, the Windows Firewall, the SNMP agent, the fax service and
  the Telnet/TFTP client are removed by the engine the user picked, so the services are
  disabled in any case - otherwise the image keeps a service whose binary is gone.
- **The six targets that cannot have both engines say why.** The component store
  (WinSxS), the three paging files, the language packs and the provisioned AppX
  packages belong to the safe engine alone: the Rust engine must not touch the
  component store, and the paging files are not part of the mounted image. The reason is
  declared per target (`DebloatEngines` -> `SingleEngineReason`) and a test keeps the
  table honest.

### Added
- **The payload of a target is declared once.** The files a target removes are named
  in the engine table (`DebloatEngines` -> `Payload`), so the safe engine and the Rust
  binary remove the same files and a test compares the two lists.
- Five tests: a target that offers one engine has a documented reason, the
  single-engine targets are the expected ones, the payload of every dual-engine target
  is the one the Rust binary deletes, the safe engine removes the payload of a target
  the Rust engine can remove, and the services of the new dual-engine targets are
  disabled on both engines.

## Unreleased (local fork, 2026-10-22) - upstream sync 2026-10-22

The releases and the runtime catalogues of the tools credited in the README were
checked again on 2026-10-22. One tool published a new release (Revision Tool 2.14.3),
the ReviOS playbook 26.10 had never been reviewed before, and four tools had moved
their default branch forward since the last sync. Item by item, with the reason for
every skipped tweak: `docs/dev/upstream-sync-2026-10.md`.

### Added
- **`DisableSearchWebView2` (new, on by default, `-DisableSearchWebView2`):** the two
  Windows feature overrides that stop `SearchHost` from starting a WebView2 runtime for
  the search box (ReviOS 26.10 / main). The obfuscated feature IDs are computed by
  `ConvertTo-WinEaseFeatureIdOverride` in `WinEasehelpers.ps1` - the same algorithm the
  ReviOS playbook and the Revision Tool use, so the written values are identical.
- **`DisableAccessibilityHotkeys`, `DisableMouseAcceleration` and `DisableKeyboardDelay`
  (new, off by default):** the user preferences that WinUtil main and AtlasOS main
  turned into REG_SZ values (a REG_DWORD value is ignored by Windows).
- **DisableWindowsAI:** the "let apps use text and image generation" capabilities are
  force-denied (`LetAppsAccessSystemAIModels`, `LetAppsAccessGenerativeAI`), and the
  agent connectors are disabled with the value the upstream tools use.
- **DisableCrossDevice:** the Cross Device Resume shell host is redirected to
  `ShellHost.exe` - the variant ReviOS 26.10 uses instead of the IFEO redirect.
- **DisableWebSearch:** the web and the Microsoft Store suggestions of the search box
  are switched off, and the activatable class of the Store search task is disabled.
- **DisableCopilot:** the per-user `IsCopilotAvailable` flag.
- **DisableTelemetryAndDiagnostics:** the telemetry sampling period is removed and
  Edge's 3P service telemetry is disabled.
- **DisableDiagnosticData:** the Defender sample submission is never accepted and the
  Malicious Software Removal Tool does not report infections.
- **DisableCloudContent:** the Media Player does not update itself.

### Fixed
- **The Defender sample submission was set to "always prompt".** `SubmitSamplesConsent = 0`
  asks the user on every sample, which is the opposite of what a debloat image should do;
  the value of ReviOS 26.10 and WinUtil is 2 (never send). The value is now applied
  whether Defender is removed or kept.
- **Three registry values were written with the wrong content.** PowerShell drops an
  empty argument of a native call, so `reg.exe add ... /d "" /f` did not write an empty
  string: reg.exe took the next switch as the value and stored `/f`. The blocked shell
  extensions of the `CleanContextMenus` option, the `Server` value of the Store search
  task and the paging file entries of the page file removal were all affected. They are
  written as the literal `'""'` now.

## Unreleased - GitHub automation hardening (2026-10-21)

Audit and details: `docs/dev/github-automation-audit.md`.

### Fixed
- **Preset and profile tweaks were ignored:** `Apply-ProfileSettings` collected the tweak
  layers but never wrote them back, so `-Profile` / `-LoadProfile` built with the schema
  default of every tweak (and legacy tweak names in profiles had no effect). They apply again.
- **Profiles with quoted booleans are refused:** `"RemoveDefender": "false"` used to be read as
  true. A value of the wrong type in a component or `TweakSettings` now stops the load.
- `config/WinEase.config.schema.json` accepts the `Settings` block and `DebloatEngineSelection`
  that `-SaveProfile` writes; four defaults now match `config/schema.psd1`.

### Added
- `tests/WinEase.Regression.Tests.ps1`: presets, CLI/profile precedence, `-NonInteractive`,
  legacy profiles, unknown keys, invalid files, save/load round trip, `-ComparePreset`, JSON
  schema, delete/restore safety.
- Workflow security audit (actionlint + zizmor), read-only AI PR review, Rust CI job,
  Dependabot for Cargo and NuGet.
- Release: tests on the tagged commit, tag/commit check, ZIP verification, SHA-256 asset,
  build provenance attestation.

### Changed
- Claude issue agent only starts for the owner, members and collaborators; permissions are
  per job; all actions are pinned to commit SHAs.

## Unreleased (local fork, 2026-10-21) - upstream sync 2026-10

The tweaks added by the latest releases of the tools credited in the README were
reviewed and the ones that fit an offline image were ported into the existing options.
Item by item, with the reason for every skipped tweak:
`docs/dev/upstream-sync-2026-10.md`. One new opt-in option (HardenSystemSecurity,
default off); no changed default.

### Added
- **11 new UI options (all off by default, GUI + CLI switch + JSON profile):**
  `DisableSnapAssist`, `DisableNotificationBanners`, `HideExplorerHomeGallery`,
  `HideAltTabEdgeTabs`, `HideTaskViewButton`, `TaskbarNeverCombine`, `DisableGameMode`,
  `ShowBatteryPercentage`, `AlwaysShowScrollbars`, `DisableLogonBlur`, `HideOneDriveNavPane`.
  These are the user-preference tweaks of the upstream tools that the sync had skipped
  because WinEase had no option for them.
- **HardenSystemSecurity (new, opt-in, default off, `-HardenSystemSecurity`):** the
  offline-applicable subset of Harden-Windows-Security 1.0.97.0 - LSA protection
  (`RunAsPPL=2`), WDigest off, NTLMv2 only, anonymous SAM/share restrictions, Remote
  Assistance off, AutoRun/AutoPlay off, PowerShell script block logging. The dependency
  check reports it as conflicting with RemoveDefender, DisableVBS, DisableUAC,
  DisableSmartScreen and DisableCPUMitigations. Documented in `docs/SECURITY_OPTIONS.md`
  together with the previously missing DisableSmartScreen and DisableVBS entries.
- **DisableTelemetryAndDiagnostics:** contact harvesting, inking/typing privacy consent,
  app launch tracking, PowerShell 7 telemetry opt-out, Sleep Study, Edge diagnostic data
  and personalization reporting, tailored experiences (user policy), online speech
  recognition policy, Narrator online services.
- **DisableWindowsAI:** Notepad AI policy, the "AI components" Settings page, Recall
  export / data providers, Paint Cocreator / generative fill / image creator, AI clipboard actions.
- **DisableCopilot:** `RemoveMicrosoftCopilotApp` policy and the Copilot features of Edge
  (page context, Microsoft 365 chat icon, history AI search, compose, Bing chat on the new
  tab, local foundational model).
- **DisableCloudContent:** Edge default-browser campaigns, recommendations, shopping
  assistant, startup boost and first run; backup reminder toast; SCOOBE and account
  notifications; lock screen Spotlight and ads; Spotlight on the desktop.
- **DisableWebSearch:** search highlights and device search history.
- **HideRecommendedSection:** the recent / most used lists of Start and recent documents.
- **DisableWidgets:** the "News and interests" feeds policy; `Microsoft.WidgetsPlatformRuntime` removed.
- **DisableActivityHistory:** Windows Backup UI and monitoring.
- **DisableSuperfetch:** ReadyBoost caches.
- **Service trims:** `diagsvc`, `IsoEnvBroker`.
- **RemoveDefender:** Microsoft Security core drivers (`MsSecCore`, `MsSecFlt`, `MsSecWfp`)
  disabled, Defender autologgers and Ubpm maintenance entries removed, Windows Security
  Settings page hidden (merged with the AI page into one `SettingsPageVisibility` value).
- **AppX removal list:** RoyalRevolt, `king.com.*`, PC Manager, OneNote (Store), Skype,
  3D Viewer, Messaging, Whiteboard.

### Fixed
- **Sticky Notes was never removed.** The pattern `*Microsoft.StickyNotes*` does not match
  the real package name `Microsoft.MicrosoftStickyNotes`; the correct pattern was added.
- **The build aborted in phase 5 with "The term 'Test-TweakEnabled' is not recognized".**
  `Test-TweakEnabled` is the accessor every phase uses to ask "is this option on?", but the
  only definition lived in `phases/10-registry.ps1` (and a copy in `phases/11-unattend.ps1`),
  both behind a `Get-Command` guard. Phases 05, 06, 08 and `lib\WinEaseDebloat.ps1` call the
  helper and run long *before* phase 10, so the command did not exist yet and the run died in
  `phases/05-appx.ps1` at the `RemoveRecall` check. The helper now has a single canonical
  definition in `WinEasebuilder.ps1`, next to the other tweak accessors and before the first
  phase is dot-sourced; the two phase-local copies stay guarded, so they only matter when a
  phase is dot-sourced on its own.
- **Four new tweaks were not registered everywhere.** `DisableSearchWebView2`,
  `DisableAccessibilityHotkeys`, `DisableMouseAcceleration` and `DisableKeyboardDelay` were
  added to `config\schema.psd1`, but not to `config\WinEase.config.schema.json` (the schema of
  the profile files - every editor that validates a profile against it rejected them) and not
  to the `none` preset of `config\presets.psd1` (which has to name every tweak). The self-test
  check "Granular Tweak Schema Alignment" failed because of it.
- **The physical debloat aborted the build on three folders that could not be emptied.**
  `tools\winease-physical-debloat` skipped every file that carries the reparse attribute,
  because it treated them as junctions. Inside a mounted WIM every file that also has a
  hardlink in the component store (WinSxS) is materialized as a *sparse placeholder* that
  carries the same attribute, so the files of `Windows\Provisioning`,
  `Windows\System32\spool` and `Windows\System32\lxss` were never deleted, the folders could
  never be emptied and the engine exited with 1 - which aborted the build. Only a reparse
  point that is a *directory* is a link now (its target can be outside the image and is
  never traversed); a file that carries the attribute is deleted like any other file. The
  ownership is also taken before a folder is read, because a refused listing was swallowed
  and left the folder untouched.
- **The diagnostic report of a failed build was not written.** The rotation of the
  `build_diagnostics` folders drops the empty ones, and the folder of a build stays empty
  until the build ends: a build that started while another one was still running therefore
  deleted the folder of that other build, and every write of the report failed with "part of
  the path could not be found". The rotation now only touches the folders that existed
  before the build started, and the report creates its folder again before it writes.
- **The errors of a failed physical debloat run were not shown.** The result file of the
  engine is now read for every exit code, so the build log names the target that did not go
  through instead of only reporting "exit code 1".

## Unreleased (local fork, 2026-10-21) - every Advanced Debloat target can be removed by the engine it offers

### Fixed
- **The engine column of the Advanced Debloat tab offered engines that could not
  remove the target.** A target declares the engines that may remove it
  (`config\schema.psd1` -> `DebloatEngines` -> `Engines`), and the window locks the
  engine cell when a target supports only one engine. Several targets advertised both
  engines although only one of them did the work:
  - The paging files (`hiberfil.sys`, `pagefile.sys`, `swapfile.sys`) are created by
    Windows on the running system and are **not part of the mounted image**, so the Rust
    engine could only ever report "file not found". The three targets are now the safe
    engine's alone, and the Rust engine lost the three keys and the three targets.
  - The services of the "service + binary" targets (Print Spooler, Bluetooth stack,
    Remote Desktop host, touch/pen/ink, BitLocker) were only disabled when the safe
    engine ran, so the forced physical deletion of the binaries left a service behind
    whose file was gone. The services are now disabled for the target itself, no matter
    which engine removes the payload.
  - The temp files of the target "Physical: Temp files" were never removed by the safe
    engine: phase 08 asked for an item name that does not exist ("Remove Temp files
    [varies]"), so the check never matched. The name is correct now.
  - The non-essential fonts and the non-Japanese input method engines were only removed
    by their option, not by the target of the Advanced Debloat tab. Both are now an
    explicit trigger of phase 08.
  - The accessibility tools were only blocked when the option
    `DisableAccessibilityTools` was on, not when the target of the Advanced Debloat tab
    was selected. Phase 11 asks the option mechanism now, so the target switches the
    IFEO block on as well.
  - The swap file is created together with the paging file, so the target now stages
    the same post-install switch as the page file (there is no separate switch for it).
- **Two toggles that no engine could remove are gone.** "Remove WinRE (reagentc /
  disable + file delete)" did nothing: the post-install cleanup of the recovery
  environment is done by the `KeepRecoveryEnv` option, and the Rust engine must not
  touch `winre.wim` (the setup needs it for the SafeOS staging). "Remove Windows Store
  cache" did nothing either: the cache lives in the user profile and does not exist in
  the offline image. Both were removed from the schema, from the window, from the
  dependency catalog and from the Japanese table.

### Added
- Six tests that keep the engine table honest: every target that offers the Rust
  engine has a key the binary accepts, every target that offers the PowerShell engine is
  removed by the shared library or by the phase that owns it, the paging files belong to
  the safe engine alone, the swap file is removed with the page file, the services of
  the service targets are disabled on both engines, and a target that no engine can
  remove does not exist.

## Unreleased (local fork, 2026-10-21) - the Japanese GUI strings were read with the wrong code page

### Fixed
- **Seven Japanese strings of the GUI were garbled.** The strings of
  `config\ui-strings\ja.json` had been read with Shift-JIS instead of UTF-8 at some
  point, so the window showed the mojibake instead of the text:
  | Key | The text the GUI shows now |
  |---|---|
  | `Debloat.Column.Engine` | エンジン |
  | `Debloat.Column.Target` | 対象 |
  | `Debloat.Engine.All` | 全対象のエンジン: |
  | `Tweak.RemoveLanguageJaJP.Description` | 日本語の言語パックを削除できる状態にする (OFF = 保護して残す) |
  | `Tweak.RemoveLanguageKoKR.Description` | 韓国語の言語パックを削除できる状態にする (OFF = 保護して残す) |
  | `Tweak.RemoveLanguageZhCN.Description` | 簡体字中国語の言語パックを削除できる状態にする (OFF = 保護して残す) |
  | `Tweak.RemoveLanguageZhTW.Description` | 繁体字中国語の言語パックを削除できる状態にする (OFF = 保護して残す) |
  The original text was recovered from the mangled bytes (the mis-decoded byte stream
  was decoded again and compared against the candidates), not rewritten, so the wording
  is the one the author wrote. Two tests keep the table free of that kind of damage:
  one rejects every string that carries the fingerprint of a wrong code page (the
  halfwidth katakana and the C1 controls), the other pins the seven texts above.

## Unreleased (local fork, 2026-10-21) - forced physical deletion for the rest of the components

### Added
- **The components that had no forced physical deletion now have one.** The Rust engine
  is the forced engine of the Advanced Debloat tab: it takes the ownership of a path
  and deletes the payload even when the file belongs to TrustedInstaller. Three
  components were still removed by the safe engine only, so their payload stayed in the
  image:
  | Target | Rust key | What the Rust engine removes |
  |---|---|---|
  | `Remove event logs [10-50MB]` | `physical_event_logs` | the log files of `Windows\System32\winevt\Logs` (the folder itself stays, the event log service needs it) |
  | `Remove non-essential fonts (file delete) [50-100MB]` | `physical_fonts` | every font of `Windows\Fonts` that is not a system font, not a Japanese font and not a font of the primary language of the image |
  | `Remove non-Japanese IME [5-15MB]` | `physical_ime` | the input method engine folders of the other languages (`CHS`, `CHT`, `KOR`); the Japanese engine and the engine of the primary language of the image stay |
  The three targets keep the safe engine as their default, so a build that does not
  select the Rust engine behaves exactly as before. The primary language of the image
  reaches the binary through the new `primary_ime_lang` field of its configuration
  file, so the Japanese and the own-language rendering never breaks.

### Fixed
- **The forced physical deletion of the Rust engine was not forced everywhere.** The
  directories were removed with a bare `RemoveDirectoryW` whose result was discarded
  (`let _ =`), so every component folder that is owned by TrustedInstaller survived the
  removal and the run reported success anyway. The subdirectories and the directory
  itself now use the same ladder as the files: the plain call, then the ownership and
  the delete right, then the delete-on-close disposition of a handle.
- **Taking the ownership did not grant the delete right.** The owner of an object only
  gets `READ_CONTROL` and `WRITE_DAC` implicitly, so a component file with a
  restrictive DACL still failed with `ERROR_ACCESS_DENIED` after the ownership was
  taken. The engine now grants full control to the built-in Administrators group
  (the existing ACEs are kept) before it retries the deletion.
- **A read-only component file could not be deleted at all.** The read-only, hidden and
  system attributes are now cleared before the deletion, and the delete-on-close step
  uses `FILE_DISPOSITION_INFO_EX` with `FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE`
  (the older `FILE_DISPOSITION_INFO` stays as the fallback).
- **The Edge removal left the updater and the core of the browser in the image.** The
  Rust target `physical_edge` now removes `Program Files (x86)\Microsoft\EdgeUpdate`
  and `Program Files (x86)\Microsoft\EdgeCore` as well, the folders that the safe
  engine already removed.

## Unreleased (local fork, 2026-10-21) - safety and quality pass

### Fixed
- **The PC migration restore could write outside the location it was supposed to
  restore.** `Restore-WinEaseCustomPaths` took the restore target straight from the
  backup manifest (`SourcePath`), so a manipulated manifest could make the restore
  write to any path of the machine. `Restore-WinEaseUserData` built its target from
  the manifest relative path without checking the boundary, and the backup side
  resolved the file to read from the same unchecked values. Every path of a manifest
  is now normalized and checked against the allowed root before a single byte is
  written: a relative path may not be absolute, drive-relative, UNC or root
  relative, may not contain a `..` segment and may not traverse a symbolic link or
  a junction. A refused path is reported as a failed entry with the reason.
- **The restore target of the custom paths is no longer taken from the manifest
  alone.** `Restore-WinEaseCustomPaths` and `Start-WinEaseMigrationRestore` take an
  allow list of the locations this restore may write to
  (`-AllowedSourcePaths` / `-AllowedCustomPaths`). The GUI passes the paths of the
  "Custom paths" box, the migrator CLI passes `-CustomPaths`. Without an allow list
  no custom path is restored (the task is reported as skipped).
- **A manifest without entries copied the whole backup directory into the user
  profile.** An empty manifest entry resolved to the backup root itself, so the
  restore copied that directory into `%USERPROFILE%`.
- **The GUI migration tab could not reach the migration engine.** The custom path
  backup and restore buttons called functions that were never loaded into the GUI
  scope, and the background job did not load `WinEasehelpers.ps1`, so the shared
  helpers (`Get-WinEaseRelativePath`, `Test-WinEasePathWithin`) were missing.
- **The provisioned AppX removal ran on every build, whatever the user chose.** The
  pattern list of `phases/05-appx.ps1` was applied unconditionally; only
  `KeepBasicApps`, `KeepXboxServices` and `RemoveStore` had any effect. The list now
  lives in `config/schema.psd1` (`AppxRemoval`), every entry names the setting that
  controls it, and the whole pass is controlled by the new `RemoveAppxBloatware`
  option. The installed and the provisioned packages are decided by the same rule
  (`Test-WinEaseAppxPackageRemovable`), and a dry run no longer removes anything.
- **The blank-password auto-logon was armed even when the option was off.** The
  `AutoLogon` section of `autounattend.xml` and the OOBE transition helpers were
  written unconditionally, while `phases/10-registry.ps1` only wrote the Winlogon
  values when `ConfigureWinlogon` was on - the option did not control the feature
  it describes. The unattend file, the registry and the helpers now follow the
  option, and the network use of a blank password stays blocked in every
  configuration. The empty password of the local account stays in the unattend file
  (an account without a password element is not documented and a setup that cannot
  create the account would leave the machine unusable); it is a console login only,
  see `docs/SECURITY_OPTIONS.md`.
- **The first logon removed AppX packages unconditionally.** The residual per-user
  removal of the Windows Backup app, the Web Experience host and Get Started now
  follows the same options as the offline removal (`remove-appx-packages.flag`).

### Changed
- **The security options have conservative defaults.** `RemoveDefender`,
  `DisableWindowsUpdate` and `ConfigureWinlogon` default to `false` now: Defender,
  Windows Update and the blank-password auto-logon stay unless the user asks for
  them. The `extreme`, `fat32`, `handheld` and `audio` presets still request them
  explicitly, so their builds behave as before. The builder prints a warning with
  the recovery commands when Defender or Windows Update are removed, and
  `docs/SECURITY_OPTIONS.md` documents every option that disables a Windows
  protection with its impact and its recovery.
- **The `none` preset means "no removals" now.** It used to keep the defaults of the
  tweaks (so Paint, Notepad, WordPad and the other optional features were still
  removed) while its description promised the opposite, and it switched the "Keep
  ..." options off (so the Asian IMEs, the extra fonts, Bluetooth and the recovery
  environment were removed as well). Every removal option is off now, every "Keep
  ..." option is on and every tweak stays at its default; only the three
  prerequisites of the unattended setup stay enabled.
- The `LimitBlankPasswordUse` value is written in every configuration, so a blank
  password never works over the network.

### Added
- `RemoveAppxBloatware` (GUI: "Remove Preinstalled AppX Bloatware", CLI:
  `-RemoveAppxBloatware` / `-KeepAppxBloatware`) removes the inbox apps of the
  image as one switch.
- `docs/SECURITY_OPTIONS.md`: what every security option does, what it costs and
  how the protection is restored.
- Regression tests for the restore path validation, the AppX target selection and
  the consistency of the security defaults.

## Unreleased (local fork, 2026-10-19)

The M1-M4 feature work and the S1-S12 follow-up sessions (design review against
`implementation_plan.md`, one theme per session) are listed together here. Commit
subjects for S1-S11 are in `git log f484228^..77cd929`; the briefs are in
`docs/dev/SESSION_BRIEFS.md`.

### Removed
- `PowerPreset` and `CpuBoostMode` were removed. Both were never implemented: they
  selected a value from a `$script:PowerPresets` table that no phase ever read, and
  the only trace of them on the installed system was a `power-preset.flag` file
  that nothing consumed. `HibernateMode` (`Off` / `Reduced` / `Keep`) is now the
  single switch for hibernation, and it is actually applied: phase 11 stages the
  mode in `hibernate-mode.flag` and `scripts/FirstLogon.ps1` turns hibernation
  off (`Off`), turns fast startup off while keeping hibernation (`Reduced`), or
  leaves the power configuration alone (`Keep`). The phase 09 "Remove
  hiberfil.sys" item used to point at `FirstLogon.ps1`, which did not handle
  hibernation at all, so `hiberfil.sys` was never removed; it is now.
- The unreferenced first-logon flags were cleaned up. `radical-ram.flag`,
  `keep-xbox.flag`, `keep-basic-apps.flag`, `keep-windows-update.flag`,
  `gpu-latency.flag` and `no-postinstall-assets.flag` were written into the image
  but never read, because each of those options is already applied offline (phase
  05 removes the AppX packages, phase 10 sets the service Start values and the GPU
  scheduler mode). Every flag that phase 11 stages is now read by a post-install
  script, and every flag a post-install script reads is staged by phase 11.

### Fixed
- The nine experimental physical-deletion targets that were registered but had an
  empty target list are now implemented. Selecting "Physical: Hyper-V", "Windows
  Firewall", "Bluetooth stack", "Print Spooler", "BitLocker", "Accessibility
  tools", "Windows Sandbox", "WSL / VM Platform" or "Remote Desktop host" in the
  Advanced Debloat tab previously did nothing at all:
  | Target | Files removed from the mounted image |
  |---|---|
  | `physical_hyperv` | `vmms.exe`, `vmwp.exe`, `vmcompute.exe`, `drivers\hvservice.sys`, `drivers\vhdmp.sys` |
  | `physical_firewall` | `mpssvc.dll`, `drivers\mpsdrv.sys` |
  | `physical_bluetooth` | `bthserv.dll`, `drivers\bthport.sys`, `drivers\bthusb.sys` |
  | `physical_spooler` | `spoolsv.exe`, `printui.exe`, `localspl.dll`, `win32spl.dll`, `spool\` |
  | `physical_bitlocker` | `manage-bde.exe`, `bdeunlock.exe`, `BitLockerWizard.exe`, `BitLockerWizardElev.exe`, `fveapi.dll`, `bdesvc.dll` |
  | `physical_accessibility` | `osk.exe`, `Narrator.exe`, `Magnify.exe`, `utilman.exe`, `atbroker.exe` |
  | `physical_sandbox` | `WindowsSandbox.exe`, `WindowsSandboxClient.exe`, `WindowsSandboxServer.exe`, `Containers\DisposableClientVM` |
  | `physical_wsl` | `wsl.exe`, `wslconfig.exe`, `wslg.exe`, `lxss` |
  | `physical_rdp` | `mstsc.exe`, `mstscax.dll`, `termsrv.dll`, `rdpclip.exe`, `rfxvmt.dll` |
  The deletion method was chosen after measuring the real image: the System32
  binaries are hard links into their WinSxS package, and deleting the System32
  link removes the shared MFT record, so the file disappears from the image
  completely. Removing all nine groups from a mounted copy of the official ISO
  (29 files and 3 directories) committed cleanly and passed
  `DISM /Apply-Image /CheckIntegrity /Verify` with exit code 0, which is the same
  gate phase 15 uses. Two new Rust unit tests assert that no experimental target
  has an empty definition, so a silently ineffective target cannot come back.
- The labels of the two targets that the Rust engine really removes were wrong:
  they said "OOBE-safe: retained" and "~0MB" although the Rust engine deletes
  the binaries. The labels, the Japanese translations and the dependency catalog
  now describe what actually happens.
- Post-install steps that ran unconditionally on every installed system are now
  bound to individual options. Phase 11 stages a flag only when the matching
  option is enabled, and the post-install scripts act on that flag:
  - `Compact.exe /CompactOS:always` -> `EnableCompactOS`
  - `fsutil behavior set disablelastaccess` / `8dot3name set 1` ->
    `EnableNtfs8dot3Disable`
  - the Ultimate Performance power plan -> `EnableUltimatePerformancePower`
  - the PCI Message Signaled Interrupts scan -> `EnableMsiMode`
  - the IFEO block for the on-screen keyboard, Narrator and Magnifier ->
    `DisableAccessibilityTools` (now off by default, so the accessibility tools
    keep working unless the user asks for them to be blocked)
  - killing `SearchHost` -> `DisableWindowsSearchProcess`
  - killing `CrossDeviceResume` -> `DisableCrossDevice`
  - `Disable-ComputerRestore` -> `DisableComputerRestore`
  - `SearchboxTaskbarMode = 0` used to be an unconditional side effect of
    disabling the search service; it now follows `HideSearchBox` on its own.
- The custom FirstLogon scripts that are registered in `autounattend.xml` were
  never written to disk: the document was saved early in phase 11, and the
  `FirstLogonCommands` nodes that were added afterwards only existed in the
  in-memory DOM, so the custom commands were silently dropped. The document is
  now saved again to all three destinations (ISO root, `Sysprep`, `Panther`)
  after the nodes are added.
- Removals that ran unconditionally on every build could not be turned off. The
  polarity is now uniform for the new removal options: `OFF` (the default for a
  removal option that a user is expected to keep) means the component is left
  alone, `ON` means it is removed. Each previously unconditional removal is now
  bound to its own option in `config\schema.psd1`:
  - Phase 08: the build-time cache cleanup (`Windows\Temp`, `Prefetch`, `Panther`,
    event logs, `Minidump`, `SoftwareDistribution\Download`, `LogFiles`,
    `Downloaded Program Files`) -> `RemoveOfflineCacheFiles`; `Windows\Help` ->
    `RemoveHelpFiles`; the Edge browser and its update/core folders -> `RemoveEdge`
    (the WebView2 runtime is still kept for OOBE); the Windows Backup app and its
    `AppListBackup` scheduled task -> `RemoveWindowsBackup`; the residual
    `WindowsBackupApp` / `Client.WebExperience` SystemApps staging folders ->
    `RemoveWindowsBackup` / `RemoveWebExperienceHost`.
  - Phase 05: the unconditional `Recall` / `Windows-Recall-Optional-Package`
    feature removal -> `RemoveRecall`.
  - Phase 06: the unconditional optional-feature (FoD) package removals ->
    one option each (`RemoveInternetExplorer`, `RemoveWordPad`,
    `RemoveStepsRecorder`, `RemoveSnippingTool`, `RemovePaint`, `RemoveXpsViewer`,
    `RemovePowerShellISE`, `RemoveOpenSSHClient`, `RemoveHelloFace`,
    `RemoveBitLockerFeature`, `RemoveNarratorApp`, `RemoveMagnifierApp`,
    `RemoveMediaPlayerFeature`, `RemoveTabletPCMath`, `RemoveWebcamExperience`,
    `RemoveWallpaperContent`, `RemoveSearchEngineClient`,
    `RemovePrintingManagement`, `RemoveMpeg2Decoder`, `RemoveWmic`,
    `RemoveWirelessDisplay`, `RemoveSnmpClient`, `RemoveTelnetClient`,
    `RemoveSimpleTcpClient`, `RemoveRdc`, `RemoveFaxClient`,
    `RemoveUserExperienceVirt`, `RemoveDeviceManagementEnt`, `RemoveNotepad`,
    `RemoveMathRecognizer`, `RemovePrintingWfs`, `RemoveKernelLA57`,
    `RemoveTpmWmiProvider`). The foreign-language font packages now follow
    `KeepExtraFonts` and the foreign Asian IME / Speech / TTS / Handwriting / OCR
    packages follow `KeepAsianIME`, instead of being removed unconditionally.
- `config/dependencies.psd1` did not parse as a PowerShell data file: the
  `NoHypervisor` key was defined three times, twice inside the same hashtable, so
  `Import-PowerShellDataFile` failed. The duplicate is resolved by keeping one
  entry per section (the component "toggle" placeholder and the detailed tweak
  entry are separate), and the missing dependency records for the toggles and
  removal options were added.
- Two new Pester checks keep this from coming back: every post-install script
  that removes a file, stops a service, kills a process or changes a setting
  must sit behind a `.flag` guard, and phase 11 must stage a flag for every
  post-install option.
- GUI switches that had no effect, and settings that could not be turned off. The
  settings tables in `config\schema.psd1` are the single source of truth, but
  several options were never wired to the phases that implement them:
  - `AtlasReviOSMode` (GUI "AtlasOS & ReviOS Low-Latency Kernel Tuning") was read
    by no phase at all, so the checkbox did nothing. It is now the umbrella switch
    for the latency kernel work in `phases/10-registry.ps1` (foreground quantum
    scheduling, the DPC tweak and the Games MMCSS task profile).
  - `DisableUSBSuspend` was likewise never read. USB selective suspend can only be
    changed on a running system, so `phases/11-unattend.ps1` now stages a
    `disable-usb-suspend.flag` and `scripts/FirstLogon.ps1` applies it with
    `powercfg`.
  - `NvidiaLowLatency` was never read either, although the README documents it as
    "NVIDIA PowerMizer performance mode & Per-CPU Core DPC". It now applies the
    PowerMizer performance-mode values and the per-processor DPC policy in
    `phases/10-registry.ps1`.
  - Fourteen phase branches read setting keys that were never declared in
    `config\schema.psd1` (`ConfigureWinlogon`, `EnableScripts`, `DisableWindowsAI`,
    `DisableDeliveryOptimization`, `ServiceTrim`, `DisablePowerThrottling`,
    `EnableHAGS`, `NtfsDisable8dot3`, `ThreadDpcEnable`, `NetworkTuning`,
    `DisableIdleMaintenance`, `SvcHostConsolidation`, `HideSearchBox`,
    `MenuShowDelayZero`). `Test-TweakEnabled` falls through to its hard-coded
    default argument for an unknown key, so ten of them were permanently on and
    four were permanently off - the user could not influence them either way.
    They are now declared as proper tweaks with a matching CLI switch.
  - `phases/11-unattend.ps1` forced the hypervisor off for the extreme, handheld
    and audio profiles regardless of the user's selection, and read
    `DisableMemCompression` / `DisableUSBSuspend` from a variable only. These now
    follow the tweak setting.
  - The physical debloat font removal ignored "Keep Extra International & Regional
    Fonts" and used a much smaller keep list than phase 08, so it deleted fonts the
    user had asked to keep. It now honours the setting and shares phase 08's keep
    list.
  - `TrimWallpapers` was overridden by `UltraSlimMode`, so turning the wallpaper
    option off had no effect. The individual setting now decides.
  - The `Windows\Help` directory was removed unconditionally in phase 08 and again
    by the phase 09 "Remove help files" item; the phase 09 handler now reports
    that it was already removed.
  - The "VisualFX" and "CpuMitigations" tweak groups were dead definitions that no
    phase read. Their work is covered by the `OptimizeVisualEffects` and
    `DisableCPUMitigations` tweaks, so the groups were removed instead of adding a
    second switch for the same setting.
  - The classic WinForms window never asked for the physical-debloat consent (the
    WinUI 3 window does), so the builder showed a second, differently worded
    confirmation for that GUI only. Both windows now ask next to the selection and
    report the answer as `PhysicalDebloatConsent`.
- Settings that were registered twice were reduced to one definition. The key
  names, defaults and the GUI placement are unchanged; only the duplicate entry
  was removed:
  - `BypassActivationRestrictions`, `DisableCPUMitigations`, `RadicalRAM`,
    `DisableMemCompression`, `NoKernelPaging`, `DisableUSBSuspend` and
    `NoHypervisor` existed in both the Tweaks and the Components table, so the two
    definitions carried different defaults and the winner depended on the order in
    which the builder applied them. The **Components** entries were removed and the
    **Tweaks** entries kept, because the presets, the GUI tabs and the
    `Sync-WinEaseTweakVariables` mapping all use the Tweak side.
  - `RemoveLegacyFOD` and `TrimWallpapers` carried a different default in the
    component definition (`Default`) than in its GUI entry (`Gui.Default`), so the
    CLI and the GUI started from a different state. The **component `Default`**
    entries were removed and the GUI default kept, which is the value the GUI
    shows and the value the presets use.
  - `ServiceTrim` existed both as a tweak group and as a phase 10 branch that
    looked it up as a tweak. The **tweak** was removed and the phase now reads the
    tweak group, so the group stays the single switch for the service trimming.
  - The three `Test-TweakEnabled` default arguments that disagreed with the
    declared default (`PreventDeviceEncryption`, `DisableWPBT`,
    `DisableBSODEmoticon`) were corrected to the declared default.
- Windows Defender was not fully removed and the engine process came back after
  installation. Measured on the built `install.wim` (read-only mount) and compared
  against the untouched source ISO:
  - The `Windows-Defender-Client-Package~` pattern in `phases/06-fod.ps1` never
    matched anything - the Defender payload is a base-OS Servicing Stack package and
    is not listed by `dism /Get-Packages`, so the removal was a no-op. The real
    payload (`windows-defender-service`: `MsMpEng.exe`, `MpClient.dll`, `MpSvc.dll`,
    `MpAsDesc.dll`) stayed in WinSxS and CBS re-staged it from
    `WinSxS\FileMaps\program_files_windows_defender_*.cdf-ms` on first boot, which
    also re-registered the `WinDefend` / `MDCoreSvc` service keys that Phase 10 had
    deleted. `phases/08-filesystem.ps1` now removes those FileMaps entries (with
    `takeown` + `icacls` first - they are TrustedInstaller-owned sparse files that
    cannot be deleted otherwise) so the re-staging cannot happen, while the WinSxS
    package folders themselves stay intact to keep the component store consistent.
  - `Remove-Item -Path '...\*' -Recurse -Force -ErrorAction SilentlyContinue` for
    `ProgramData\Microsoft\Windows Defender` did not reliably recurse into the
    wildcard root and swallowed every failure, so a failed purge looked successful.
    It now uses `Remove-ProtectedDirectory`, which takes ownership and throws when
    the directory survives.
  - `phases/10-registry.ps1` silenced every `reg.exe` call, so a service-key delete
    that failed (e.g. a key still owned by TrustedInstaller) was indistinguishable
    from a successful one. The deletion is now verified per service and reported.
    `WdBoot` is additionally taken out of the `Early-Launch` (ELAM) group and
    `WdFilter` out of the `FSFilter Anti-Virus` group, and the 24H2+ policies that
    actually work (`DisableAntiVirus`, `DisableRealtimeMonitoring`,
    `DisableBehaviorMonitoring`, `DisableOnAccessProtection`, Spynet, signature
    updates) are set - `DisableAntiSpyware` alone no longer disables the engine on
    Windows 11 24H2+.
  - `scripts/FirstLogon.ps1` had no Defender handling at all. It now stops and
    disables the Defender services, terminates `MsMpEng` / `Sense` /
    `SecurityHealthSystray` / `SecurityHealthHost` / `MpCmdRun`, re-deletes the
    service keys and re-asserts the policies after the first logon.
  - The "Windows Security" AppX package was in the AppX protection whitelist, so it
    stayed installed even with Defender gone. The protection is now lifted when
    `-RemoveDefender` is active and the package is added to the removal list.
  - The desktop "Toggle Windows Defender" tools disabled `Sense` but never re-enabled
    it, and the Atlas/ReviOS variant did not touch `WdNisSvc` / `Sense` at all.
    Both are now symmetric.
- `tools/winease-physical-debloat` enabled `SeTakeOwnershipPrivilege` but never took
  ownership, so TrustedInstaller-owned component files failed to delete, and the
  per-file errors inside `delete_directory` were discarded with `let _ =`. The tool
  now calls `SetNamedSecurityInfoW` to take ownership before deleting and reports
  the errors instead of swallowing them.
- `phases/15-verify.ps1` now verifies the Defender removal in the final payload
  (CBS re-staging maps, service keys in the offline SYSTEM hive, payload folders)
  and reports what is still present.
- `-NoDefender` used to be an alias of `-RemoveDefender`, so it meant "remove
  Defender" while every other `-NoXXX` switch in the builder means "keep XXX"
  (`-NoIME` keeps the IME, `-RemoveIME` removes it). `-NoDefender` now keeps
  Defender, and `-KeepDefender` / `-NoDefender` / `-RemoveDefender` are reported as
  mutually exclusive.

### Added
- **One master schema.** The old config/tweaks.psd1 became `config/schema.psd1`: it is the
  single source of truth for every option, the CLI bindings, the Advanced Debloat targets
  and now also for the targets an option removes (`Targets` - the FoD packages of the 34
  removal options, which phase 06 used to keep in its own table). The old file does not
  exist any more; everything (the builder, both windows, the phases, the tests)
  reads the master.
- **The presets are data, not code.** The built-in presets moved from a 280 line block in
  the builder to `config/presets.psd1`. A preset is only the list of the options it
  switches on. The descriptive names of the plan (`None`, `Standard`, `Gaming`, `UltraSlim`,
  `MinimalServices`) are accepted next to the existing keys.
- `Resolve-WinEaseConfiguration` (`WinEasehelpers.ps1`) resolves the effective
  configuration in one place: the base defaults, then the preset, then the individual
  settings of the user. An individual setting always wins - an option the user set
  explicitly to `$false` stays `$false`, even when the preset switches it on. Before this
  the resolution was spread over the builder and a preset could overrule the command line.
- `Get-WinEaseOptionPolarity` returns the polarity of an option from its key
  (`Remove*` / `Disable*` / `Enable*` / `Keep*`), so the convention is checkable.

### Changed
- The conflict check no longer rewrites anything. `Test-WinEaseConfigConflicts` used to
  take `-AutoResolve` and silently changed the settings of the user (e.g. it turned the
  Windows Update switch off when the Microsoft Store was kept). It is now a pure
  validation: it reports the contradiction and the resolution that would apply. The
  builder applies the safeguards that protect the build - a "keep" request wins over a
  selected debloat target, and the physical debloat needs its explicit consent - and says
  so. A conflict that only asks for a different combination (the Store and the Windows
  Update) is reported, not resolved.
- The defaults of the components come from the schema instead of a hard-coded list in the
  builder. The two lists had drifted apart (`KeepAudioTweaks`, `MMCSSGaming`).

### Added
- **PowerShell <-> Rust engine switch for the Advanced Debloat options.** Every debloat
  target is now bound to the engine that removes it. The binding lives in
  `config/schema.psd1` (`DebloatEngines`: the engines a target supports, its default
  engine, the key the Rust binary understands and the older list entry that was merged
  into it), so the GUI, the profile format and `phases/09-physical-debloat.ps1` all read
  the same table. The rules are enforced in the phase, not only in the UI:
  - a target that is not selected never runs, whatever engine it carries;
  - the engine `PowerShell` never hands the target to the Rust binary;
  - the engine `Rust` hands exactly that one key to the Rust binary, and only after the
    `-AllowPhysicalDebloat` gate and the offline-image check passed;
  - an engine a target does not support falls back to the registered default.
  The Rust key is now data driven, which also fixed the page file / swap file mix-up
  ("Remove swapfile.sys" used to be dispatched as `physical_pagefile`).
  Both windows show the engine next to every target: the engine cell is locked while
  the target is not selected, and a global switch applies one engine to every target
  that supports it. A profile stores the engine per target (`DebloatEngineSelection`).
- WinUI 3 settings window (`gui/winui`, C# / Windows App SDK 2.5, unpackaged and
  self-contained): navigation pane with the same nine pages, settings cards, Mica, system
  light/dark theme, English / Japanese from the same `config/ui-strings` tables.
  `WinEasebuilder.ps1 -GUI` uses it when `gui/winui/bin/WinEaseGui.exe` is built
  (`gui/winui/build.ps1`, run automatically by `WinEase-GUI.bat` when `dotnet` is present)
  and falls back to the WinForms window otherwise or with the new `-ClassicGui` switch.
  `gui/WinEaseWinUiHost.ps1` serves the window's requests (sources, dependency check, Preset
  Diff, recovery readiness, migration engine, language) inside the builder process, one JSON
  message per line over stdin/stdout. The window asks for the physical debloat consent itself.
- `config/schema.psd1`: single source of truth for every tweak and component setting
  (key, GUI tab, default, description, legacy aliases, CLI switch, backing variable).
  `AllTweakDefs`, the GUI "Services & Apps" tab, profile apply/export and the plain CLI
  switches are now all generated from it.
- Per-tweak `TweakSettings` block in profiles (`profiles/*.json`) - every switch can be
  turned on/off individually. Legacy key names (`BypassRequirements`, `DisableTelemetry`,
  `DisableSearchIndex`, `DAWMode`) are still accepted as aliases.
- `gui/WinEaseGui.ps1`: the WinForms GUI moved out of `WinEasebuilder.ps1` (loaded only for
  `-GUI` / menu option `[7]`), built from shared control helpers (`New-WinEaseButton`,
  `New-WinEaseToggleTab`, `Add-WinEaseSelectButtons`, ...).
- **Select All / Clear All** buttons on the Standard and Experimental lists of the
  Advanced Debloat tab. Select All on the Experimental list asks for confirmation.
- `tools/Measure-WinEaseGuestBaseline.ps1` (in-guest disk / RAM / CPU / boot-time /
  functionality measurement, JSON output) and `tools/Compare-WinEaseBenchmarks.ps1`
  (multi-run statistical comparison: mean, median, StdDev, IQR, % improvement).
- `config/dependencies.psd1`: dependency & feature-impact catalog (174 entries across
  Components, Tweaks and Advanced Debloat). Surfaces Conflicts, Impacts and Unknowns
  (fail-safe: unregistered items become Unknown). GUI "Check Dependencies" button,
  `-StrictDependencyCheck` CLI switch and an HTML report section.
- `lib/WinEaseExtensions.ps1`: user extensibility engine (Import-WinEaseUserExtensions,
  Invoke-WinEaseUserExtensionActions, Get-WinEaseCustomScriptMetadata,
  Invoke-WinEaseCustomScriptsStage, Compare-WinEaseConfig, Format-WinEaseConfigDiff,
  Test-WinEaseRecoveryReadiness). User tweaks, presets and custom scripts come from
  `config/user/user-tweaks.psd1`.
- PC migration & backup engine `tools/migrator/WinEaseMigration.ps1` with the standard
  rules in `tools/migrator/migration-rules.psd1` (15 game + 16 app rules) and the user
  template `config/user/user-migration-rules.psd1`.
- `tools/migrator/WinEase-Migrator.ps1`: standalone migrator. CLI modes ExportApps,
  Backup, Restore, Verify (SHA-256 against `migration-manifest.json`), Estimate, plus the
  older ListRules and RecoveryCheck; `-PackagePath` (alias `-BackupRoot`), `-UserFolders`,
  `-CustomPaths`, `-RuleIds`, `-ConflictPolicy`, `-IncludeSecrets`, `-RetryFailedOnly`,
  `-DryRun`; a 900x680 two-tab wizard when run without `-Mode`.
- Task-based restore: one task per app, backed-up folder, rule and custom path, each
  run independently with Pending/Completed/Failed/Skipped saved to `restore-state.json`
  after every task; `-RetryFailedOnly` runs only Failed and Pending tasks. The backup
  manifest now lists Entries, Folders, Rules and CustomPaths.
- Migration report: dark-theme HTML plus a matching JSON file covering succeeded items
  (file count, size, SHA-256 status), skipped items, failures with reasons, and manual
  actions (apps that cannot be reinstalled, cloud-save notices, re-login guidance). All
  dynamic values are HTML-encoded.
- `-ComparePreset <name|JSON path>`: shows the difference between the current
  configuration and a preset, then exits with code 0 without any build or disk work.
- Recovery readiness check (`Test-WinEaseRecoveryReadiness`, advisory) and the PreBuild
  custom-script stage now run in the builder right after the dependency check.
- `-IncludeMigrationAssistant` now does something: Phase 11 copies the migrator, engine
  and rule files to `Windows\Setup\Scripts\Migration` and adds a public-desktop
  launcher (DryRun only prints). No personal data is included by the assistant
  itself; the later `-IncludeMigrationBackup` option can bundle the default backup,
  which does contain personal data.
- GUI Tab 8 "Migration & Backup": recovery check (using the current window's draft
  config), app inventory export (SaveFileDialog), Estimate Size, Verify Backup Integrity,
  Retry Failed Tasks Only, Browse for the backup folder, credential exclusion and conflict
  policy inputs, a Documents / Desktop / Pictures / Videos / Downloads checklist, a rule
  list keyed by real rule Ids, and the Include Migration Assistant switch.
- GUI Tab 9 "User Tweaks" for user switches whose Category has no built-in tab
  (System / Gaming / UserCustom ...), a "Preset Diff" dialog that compares any preset or the
  current window settings, and a User Extensions card on Tab 8 (counts, load errors, a
  button that opens the extensibility guide).
- `Resolve-WinEaseUserConfigPath` and `Get-WinEaseCustomScriptFiles`: one place that decides
  where user config files and custom scripts live.
- Custom scripts run per stage from `tools/custom-scripts/<Stage>/` (PreBuild,
  OfflineImage, FirstLogon, UserOnce; each folder has a `.gitkeep`). PreBuild and
  OfflineImage scripts get a `$WinEaseContext`; FirstLogon and UserOnce scripts are copied
  into the image and checked against a SHA-256 manifest at first logon.
- `docs/EXTENSIBILITY_GUIDE.md` (English) and `docs/EXTENSIBILITY_GUIDE.ja.md` (Japanese): guide with a quick start (user tweak, user
  migration rule) and a reference (file roles, the four custom-script stages,
  `$WinEaseContext`, offline hives, `OnError`, safe verification).
- `PSScriptAnalyzerSettings.psd1` plus a Pester test that requires zero Error/Warning
  findings. The Pester suite covers GUI wiring, single-source settings, a GUI smoke test
  that clicks every Select All / Clear All button, and a Describe block per S1-S11 theme.
- Tests: source-file hygiene check that BOM-less `.ps1` / `.psd1` files are ASCII only.

### Changed
- AppX leftover folder cleanup no longer runs recursive `takeown /R` / `icacls /T`; it
  removes reparse points (junctions) as links first so deletion never follows them out
  of the image (`Remove-WinEaseTreeRobust`). Folder cleanup still runs on
  `-AppxParallelism` (1-8, default 4) RunspacePool workers; DISM removal stays sequential.
  The parallel path now also checks that each folder is inside the scratch directory and
  names failed folders in the log.
- Rewritten Rust physical-debloat tool and Phase 09 with the explicit
  `-AllowPhysicalDebloat` / GUI consent gate and mount-path safety validation.
- Folder restructure (S9): the PC migration tool moved to `tools/migrator/`, the user
  config files to `config/user/`. The builder no longer loads the migration engine; GUI
  Tab 8 loads it the first time the tab is opened. An old `config/<file>` is still read
  with a one-time warning when `config/user/<file>` does not exist. The migrator and
  engine look for rules next to themselves, so the ISO-bundled copy works too.
- Custom scripts (S9): `tools/custom-scripts/<Stage>/` is the single layout. Files directly
  in `tools/custom-scripts/` are still treated as FirstLogon and `user/` as UserOnce.
- OfflineImage custom scripts now run at the end of Phase 11 (before FirstLogon / UserOnce
  staging) with `ScratchDir`, `WinEaseDir` and `Config`; they used to run right after AppX
  removal.
- Dependency check: `RemoveDrivers` is Unknown (its safety depends on the target PC),
  `AllowPhysicalDebloat` is registered, `NoHypervisor` lists VBS among its impacts, and an
  enabled user tweak without `Impact` is Unknown (`'Safe'` reports nothing, a hashtable
  `Impact` is reported as an Impact).
- Migration backup: a `BackupRoot` inside a folder being backed up is rejected. The rule
  backup result now carries `CloudSaveNotices`, `SkipReasons`, `SecretExcludedFiles` and
  `BackedUpRules`. `Restore-WinEaseUserData` gained `-Categories` and
  `Restore-WinEaseCustomPaths` gained `-SourcePath`; CustomPath entries are no longer
  restored by the user-data path. The default backup folder moved out of Documents.
- **Phase 09 is the Rust engine only.** The safe work of an Advanced Debloat target used
  to run in phase 09 as well, so a target could be removed twice: once by its own option
  and once by the phase 09 handler chain. Every target now declares the phase that owns
  it (`config\schema.psd1` -> `DebloatEngines` -> `Phase`), the safe handlers live in one
  place (`lib\WinEaseDebloat.ps1`) and each owning phase runs its own targets
  (`Invoke-WinEaseDebloatTargets -Phase '<phase>'`). Phase 09 only dispatches the targets
  whose engine is "Rust" to the Rust binary.
  - The targets of the Advanced Debloat tab that switch on a granular option are now the
    second way to ask for the same work, not a second implementation of it
    (`DebloatEngines` -> `Option`, e.g. "Remove event logs" -> `RemoveOfflineCacheFiles`).
  - Six items of the Advanced Debloat tab did nothing at all: "Remove Remote Desktop
    host", "Remove Bluetooth stack", "Remove Print Spooler", "Remove touch/pen/ink
    components", "Remove accessibility tools" and "Remove BitLocker" only printed a
    message in phase 09 and left the services enabled. The services are now really
    disabled (`TermService` / `UmRdpService`, `bthserv` / `BthAvctpSvc` /
    `BluetoothUserService`, `Spooler` / `PrintNotify`, `TabletInputService`, `fvevc`), and
    the accessibility item switches on the IFEO block of the installed system.
  - `PrintNotify` is no longer disabled by the generic service trim; it goes away with the
    `Spooler` it belongs to (AUD-19).
  - "Remove hiberfil.sys" now really switches the hibernation mode off and
    "Remove pagefile.sys" stages a post-install switch that disables the paging file
    (before this both items only printed a message).
  - The WinSxS item of the Advanced Debloat tab asks for the aggressive variant
    (`/StartComponentCleanup /ResetBase`); the safe mode still protects the component
    store on 24H2+.
- The language packs can be protected per language. `RemoveLanguageJaJP`,
  `RemoveLanguageKoKR`, `RemoveLanguageZhCN` and `RemoveLanguageZhTW` decide whether the
  pack of that language may be removed (OFF = protected), and the language of the image
  is always kept.
- GUI structure (S10): `Show-WinEaseGUI` is split into one function per tab; colours live in
  `$script:WinEaseGuiColors`; OK message boxes go through `Show-WinEaseGuiMessage`; background
  work goes through `Invoke-WinEaseGuiBusy` / `Invoke-WinEaseGuiBackgroundJob`; the default
  backup folder is defined once (`Get-WinEaseDefaultMigrationBackupPath`); new form, combo box,
  tab control and text box parts. The migrator window is built from these shared parts
  (the control tree is identical to before). Controls, positions and handlers are unchanged.
- Builder structure (S11): `Invoke-WinEaseSelfTest` is split into one small function per
  check (output and exit code unchanged); `OutputType` declared on helpers flagged by
  PSScriptAnalyzer.
- Code hygiene (no behaviour change): empty `catch {}` blocks now log via `Write-Verbose`,
  `$null` moved to the left of comparisons, positional parameters named, unused variables
  removed, trailing whitespace stripped.
- The window starts on the safe "balanced" preset and every debloat target starts on the
  safe PowerShell engine. A preset that was chosen explicitly (a profile, the command
  line) is never overridden.
- The regenerated `WinEase_report.html` is no longer tracked by git.

### Fixed
- The Advanced Debloat tab and its standalone dialog listed the same targets twice. The
  16 "Physical: <target>" entries that duplicate a standard target (Bluetooth stack,
  Print Spooler, Touch/Pen/Ink, Accessibility tools, Windows Media Player, Remote
  Desktop host, Windows Sandbox, WSL, help files, crash dumps, provisioning packages,
  Delivery Optimization, PatchCache, pagefile.sys, hiberfil.sys, swapfile.sys) are gone;
  each target now has one entry and the engine column decides whether the safe
  PowerShell engine or the Rust engine removes it. Older profiles that still contain
  the merged entries are mapped onto the canonical target and keep the Rust engine.
- The two Advanced Debloat lists were defined twice in `gui/WinEaseGui.ps1` and the
  copies had drifted apart (the dialog listed 43 experimental items, the tab 30), so
  some options were only reachable from one of the two. There is one definition now.
- `Import-WinEaseUserExtensions -PresetsOnly` (the builder's second call) wiped the user's
  tweaks and custom scripts; the collections are now reset only when they are reloaded.
  The extension and migration libraries are no longer dot-sourced twice.
- GUI **Select All / Clear All** buttons on tabs 2-5 did nothing (the click handler
  referenced a variable that was out of scope by click time).
- 24 GUI tweak switches were never read by the build because their names differed from
  the ones Phase 10 looked up (e.g. `BypassHardwareRequirements` vs `BypassRequirements`),
  or had no implementation at all. All are now wired through or implemented.
- `RadicalRAM`, `BypassActivationRestrictions`, `DisableMemCompression`,
  `DisableUSBSuspend`, `NoHypervisor`, `NoKernelPaging`, `DisableCPUMitigations` from the
  GUI/profiles were ignored (RadicalRAM always resolved to off).
- 15 Advanced Debloat "Standard" items only logged `[SKIP] No standard handler`; they now
  have handlers, or were removed from the GUI when no safe implementation exists.
- GUI toggle initialization called `ContainsKey` on `[ordered]@{}`
  (`System.Collections.Specialized.OrderedDictionary`), which Windows PowerShell 5.1 does not
  implement: every launch logged 122 method-not-found errors and per-tweak values saved in
  profiles were not applied (the `elseif` fallback to top-level keys was used instead). The GUI
  loader now uses `Contains`, as does Phase 10's `Test-TweakEnabled` alias lookup - the same
  pattern there would have fallen back to defaults for every toggle in a real build.
- GUI Tab 8 Run Backup never passed `-FolderMap`, so personal data was not backed up; it now
  passes the folders ticked in the checklist.
- The migration backup wrote a manifest without `Entries`, which broke restore.
- `-IncludeMigrationAssistant` was wired through CLI, profile and GUI but nothing read it.
- User switches whose category had no GUI tab (System / Gaming / UserCustom) were never
  shown.
- Paths after the folder restructure (the user-config lookup now starts at the repository
  root instead of `lib/`).
- Emoji in the startup menu and in a report heading showed as mojibake in BOM-less UTF-8
  sources on Windows PowerShell 5.1; they are now ASCII.
- The migrator `-GUI` failed in a fresh process because `System.Drawing.Color` was used
  before the assembly was loaded.
- The S11 ASCII-only source test also scanned `.claude\worktrees\` on Windows (wrong
  path-separator pattern).

### Notes
- Full end-to-end build re-verified on 2026-10-19 (GUI-driven): the complete pipeline finished
  with "Build succeeded and safety checks passed" and produced `WinEase.iso` (7,888,314,368
  bytes); `WinEase_report.html` was refreshed from the same run.

## Earlier (local fork, 2026-10-17)

### Added
- `-ResumeIsoOnly` (aliases `-ResumeIso`, `-IsoResume`): fast-track Phase 14-18 (boot.wim
  patch + ISO mastering) against the preserved `workspace\build\sources\install.wim`
  left by the previous run, rebuilding the bootable ISO in minutes without repeating
  the debloat pipeline. Deep-apply verification is intentionally skipped (metadata +
  payload SHA256 checks run instead).
- `-ForceWinSxSCleanup` (alias `-ForceWinSxS`): opt-in override that runs offline
  `/StartComponentCleanup` (and `/ResetBase`) on Windows 11 24H2+ (26100+), overriding
  the safety block. Experimental; deep-apply verification and ISO payload hash check
  act as safety net.
- `tests/`: Pester suite covering AST syntax, unattend schema,
  profile preset integrity, AppX wildcard safety, IME decoupling filter logic,
  language detection, path-safety guards, and end-to-end `-TestSelf` / `-DryRun`.
- `tools/custom-scripts/` skeleton with README and a disabled example script.
- `LICENSE` (MIT) restored to match the README badge.
- Host environment health diagnostics at every build start (RAM capacity, free space,
  physical-disk SMART status) to surface WIM 577 / hash-jitter root causes.
- Build log rotation now compresses logs older than 7 days into `logs/archive.zip`
  and prunes stale `build_diagnostics` runs.

### Changed
- Size-first ISO reduction: language-aware decoupling of foreign Asian IMEs
  (ko-KR / zh-CN / zh-TW / zh-HK removed for ja-JP / en-US targets while the
  Japanese IME + own-language fonts are preserved), ultraSlim trimming of
  self-language Speech/TextToSpeech/OCR FOD packages, `KeepExtraFonts = $false` and
  `RemoveStore = $true` for the extreme / fat32 / handheld presets, `RemoveDrivers =
  $true` (legacy printer/fax/scanner only), and ISO-side cleanup of `sources\sxs`,
  `langpacks`, `sflist*.dat` under ultraSlim.
- App removal hardening at 4 layers: `Microsoft.WindowsBackupApp` (Windows Backup,
  `WindowsBackupClient.exe`) and the Web Experience host (`WebExperienceHostApp.exe`
  = はじめに) - provisioned Appx pattern, residual `SystemApps` folder deletion,
  IFEO execution block, and a FirstLogon per-user Appx fallback.
- Windows Search disable fully enforced: offline WSearch `Start=4` on all control
  sets + `DelayedAutoStart` cleanup + `disable-search.flag` staged for an online
  FirstLogon enforcement (Stop/Set-Service Disabled, SearchHost kill, taskbar search
  box hidden). Status visible in the `Active configuration` summary.
- CrossDeviceResume.exe enforcement: online FirstLogon block that kills the resume
  host and re-asserts the IFEO debugger redirect (the executable ships inside the
  protected `MicrosoftWindows.Client.CBS` shell package on 26H2, so neutralization -
  not deletion - is the correct approach).
- Phase 18 ISO verification retry cooldown extended (2s -> 5s) with forced GC to
  reduce hash-jitter false failures.
- README example path corrected and revision notes added.

### Fixed
- Inverted `keepAsianIME` IME-pattern filter: foreign IME packages are now actually
  removed for ja/en targets (previously the filter dropped them from the removal
  list, leaving all foreign IMEs in the image).
- autounattend.xml raw `&` in the Windows Search enforcement comment that broke
  XML parsing (caught by the self-test, corrected).
- `$resumeIsoAttempt:` interpolated-variable parse error in the new Resume-ISO code
  (caught by `-TestSelf`, corrected).
- Image cleanup now actually deletes expanded trees: PowerShell 5.1 `Remove-Item` and
  `rd /s /q` both fail with ACCESS DENIED on WIM-applied trees (files owned by
  TrustedInstaller, Administrators granted RX only), and the old
  `-ErrorAction SilentlyContinue` calls swallowed it - two runs leaked ~41 GB of
  `deep_apply_verification_*` directories (~135k files each). New
  `Remove-WinEaseTreeRobust` helper prunes reparse points first (applied-image
  junctions such as `Users\All Users` point at host paths like `C:\ProgramData`),
  then deletes via `robocopy /MIR /XJ /B` (backup mode bypasses the DACL) with
  `rd /s /q` plus a takeown/icacls tier as fallback. Empirically verified against
  >260-char paths, RX-only ACL trees, and junction-traversal safety.
- Final lifecycle cleanup no longer stalls for hours: the fast native first tier
  replaces `Reset-DirectoryWithRobocopy`'s per-item `Get-Acl`/`Set-Acl` pass over
  100k+ file trees (heavy reset machinery retained as an opt-in fallback for locked
  trees / loaded offline hives). Per-target cleanup elapsed times are now logged.
- Misleading "Transient artifacts cleaned (build\ preserved for -ResumeIsoOnly)"
  message no longer prints when nothing was deleted - Phase 18 F1 cleanup reports the
  real removed count and warns with paths for anything left behind.
- Cleanup hardening after live validation on the leaked trees (real-data testing):
  an access-denied directory previously aborted the prune walk, after which the
  safety gate skipped removal entirely (empty roots left behind). Verified hazards
  are now encoded as hard rules: `robocopy /MIR` purges THROUGH junctions even with
  `/XJ` (it destroyed a canary target in every tested variant), `takeown /r` and
  `icacls /T` traverse junctions, and `icacls` on a link path rewrites the link
  TARGET's ACL. The mirror purge therefore runs only on trees the walk could fully
  verify as link-free, and ACL repair is applied NON-recursively with inheritable
  `(OI)(CI)` grants (verified not to propagate across junctions), iterated so
  unreadable directories and undeletable child links are repaired one level at a
  time. Three Pester regression tests cover the denied-directory shape, a junction
  hidden inside an unreadable directory, and a link whose inherited ACL was emptied.
- Phase 18 duration is now recorded in `logs/last_phase_timings.json`; previously the
  final phase was always missing because only the next `Enter-Phase` recorded a phase's
  duration (`Exit-Phase` existed but had no call sites). The orchestrator now closes out
  Phase 18 and re-persists the complete timings table, so the next-run build-time
  estimate includes ISO mastering.
- The build-time estimate now actually sums fractional phase durations: PS 5.1's
  `ConvertFrom-Json` returns `System.Decimal` for JSON decimals, and the old reader only
  accepted double/int/long, so it silently displayed "~0 min" (verified: a timings table
  totalling ~840 s evaluated as 1 s).
- ACL repair during image cleanup works again (root cause of the 2026-10-18 17.2 GB
  leftover): the takeown tier called `takeown /f <dir> /d y`, which current Windows 11
  takeown rejects outright ("/D can only be used together with /R"; argv validation,
  exit 1, nothing changed) - and with everything piped to `$null 2>&1` the failure was
  invisible, so WIM-protected directories (owner a service account, SYSTEM-only DACL)
  were never repaired and the mirror pass stayed blocked behind the link-free gate.
  Verified counter-evidence: plain `takeown /f` succeeds, and `icacls` reports "Access
  is denied" while still exiting 0 (exit-code checks cannot detect it either). Repair is
  now done in-process: `Enable-WinEaseTokenPrivileges` enables SeTakeOwnership /
  SeRestore / SeBackup on the PowerShell token (P/Invoke), and `Repair-WinEaseDeniedAcl`
  takes ownership for Administrators, strips explicit Deny ACEs aimed at them and adds
  an inheritable FullControl grant via `Set-Acl` (real catchable exceptions; fresh
  descriptor fallback when the DACL is unreadable). Repair failures are recorded and
  surfaced in the final warning instead of being swallowed, and the prune walk captures
  enumeration errors via `-ErrorVariable` so build logs stay clean. Verified: after
  repair the walk fully enumerates the previously locked trees (SeBackupPrivilege),
  finds and prunes every reparse point, and the gate opens only after that proof. Two
  new Pester regression tests cover the SYSTEM-only DACL shape and a junction hidden
  inside such a directory.

### Notes
- The 26100+ (24H2+) offline WinSxS cleanup remains **blocked by default**; use
  `-ForceWinSxSCleanup` only after accepting the checkpoint-LCU corruption risk.
- `-ResumeIsoOnly` skips deep-apply verification; run a full build whenever the host
  is stable to re-establish the integrity baseline.
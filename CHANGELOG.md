# Changelog

All notable changes to this fork are documented here. Versions follow the upstream
nano11 scheme; entries below are local-fork additions on top of upstream 2.1.

## Unreleased (local fork, 2026-10-19)

The M1-M4 feature work and the S1-S12 follow-up sessions (design review against
`implementation_plan.md`, one theme per session) are listed together here. Commit
subjects for S1-S11 are in `git log f484228^..77cd929`; the briefs are in
`docs/dev/SESSION_BRIEFS.md`.

### Added
- `config/tweaks.psd1`: single source of truth for every tweak and component setting
  (key, GUI tab, default, description, legacy aliases, CLI switch, backing variable).
  `AllTweakDefs`, the GUI "Services & Apps" tab, profile apply/export and the plain CLI
  switches are now all generated from it.
- Per-tweak `TweakSettings` block in profiles (`profiles/*.json`) - every switch can be
  turned on/off individually. Legacy key names (`BypassRequirements`, `DisableTelemetry`,
  `DisableSearchIndex`, `DAWMode`) are still accepted as aliases.
- `gui/Nano11Gui.ps1`: the WinForms GUI moved out of `nano11builder.ps1` (loaded only for
  `-GUI` / menu option `[7]`), built from shared control helpers (`New-Nano11Button`,
  `New-Nano11ToggleTab`, `Add-Nano11SelectButtons`, ...).
- **Select All / Clear All** buttons on the Standard and Experimental lists of the
  Advanced Debloat tab. Select All on the Experimental list asks for confirmation.
- `tools/Measure-Nano11GuestBaseline.ps1` (in-guest disk / RAM / CPU / boot-time /
  functionality measurement, JSON output) and `tools/Compare-Nano11Benchmarks.ps1`
  (multi-run statistical comparison: mean, median, StdDev, IQR, % improvement).
- `config/dependencies.psd1`: dependency & feature-impact catalog (174 entries across
  Components, Tweaks and Advanced Debloat). Surfaces Conflicts, Impacts and Unknowns
  (fail-safe: unregistered items become Unknown). GUI "Check Dependencies" button,
  `-StrictDependencyCheck` CLI switch and an HTML report section.
- `lib/Nano11Extensions.ps1`: user extensibility engine (Import-Nano11UserExtensions,
  Invoke-Nano11UserExtensionActions, Get-Nano11CustomScriptMetadata,
  Invoke-Nano11CustomScriptsStage, Compare-Nano11Config, Format-Nano11ConfigDiff,
  Test-Nano11RecoveryReadiness). User tweaks, presets and custom scripts come from
  `config/user/user-tweaks.psd1`.
- PC migration & backup engine `tools/migrator/Nano11Migration.ps1` with the standard
  rules in `tools/migrator/migration-rules.psd1` (15 game + 16 app rules) and the user
  template `config/user/user-migration-rules.psd1`.
- `tools/migrator/Nano11-Migrator.ps1`: standalone migrator. CLI modes ExportApps,
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
- Recovery readiness check (`Test-Nano11RecoveryReadiness`, advisory) and the PreBuild
  custom-script stage now run in the builder right after the dependency check.
- `-IncludeMigrationAssistant` now does something: Phase 11 copies the migrator, engine
  and rule files to `Windows\Setup\Scripts\Migration` and adds a public-desktop
  launcher (DryRun only prints). No personal data is included.
- GUI Tab 8 "Migration & Backup": recovery check (using the current window's draft
  config), app inventory export (SaveFileDialog), Estimate Size, Verify Backup Integrity,
  Retry Failed Tasks Only, Browse for the backup folder, credential exclusion and conflict
  policy inputs, a Documents / Desktop / Pictures / Videos / Downloads checklist, a rule
  list keyed by real rule Ids, and the Include Migration Assistant switch.
- GUI Tab 9 "User Tweaks" for user switches whose Category has no built-in tab
  (System / Gaming / UserCustom ...), a "Preset Diff" dialog that compares any preset or the
  current window settings, and a User Extensions card on Tab 8 (counts, load errors, a
  button that opens the extensibility guide).
- `Resolve-Nano11UserConfigPath` and `Get-Nano11CustomScriptFiles`: one place that decides
  where user config files and custom scripts live.
- Custom scripts run per stage from `tools/custom-scripts/<Stage>/` (PreBuild,
  OfflineImage, FirstLogon, UserOnce; each folder has a `.gitkeep`). PreBuild and
  OfflineImage scripts get a `$Nano11Context`; FirstLogon and UserOnce scripts are copied
  into the image and checked against a SHA-256 manifest at first logon.
- `docs/EXTENSIBILITY_GUIDE.md` (English) and `docs/EXTENSIBILITY_GUIDE.ja.md` (Japanese): guide with a quick start (user tweak, user
  migration rule) and a reference (file roles, the four custom-script stages,
  `$Nano11Context`, offline hives, `OnError`, safe verification).
- `PSScriptAnalyzerSettings.psd1` plus a Pester test that requires zero Error/Warning
  findings. The Pester suite covers GUI wiring, single-source settings, a GUI smoke test
  that clicks every Select All / Clear All button, and a Describe block per S1-S11 theme.
- Tests: source-file hygiene check that BOM-less `.ps1` / `.psd1` files are ASCII only.

### Changed
- AppX leftover folder cleanup no longer runs recursive `takeown /R` / `icacls /T`; it
  removes reparse points (junctions) as links first so deletion never follows them out
  of the image (`Remove-Nano11TreeRobust`). Folder cleanup still runs on
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
  staging) with `ScratchDir`, `Nano11Dir` and `Config`; they used to run right after AppX
  removal.
- Dependency check: `RemoveDrivers` is Unknown (its safety depends on the target PC),
  `AllowPhysicalDebloat` is registered, `NoHypervisor` lists VBS among its impacts, and an
  enabled user tweak without `Impact` is Unknown (`'Safe'` reports nothing, a hashtable
  `Impact` is reported as an Impact).
- Migration backup: a `BackupRoot` inside a folder being backed up is rejected. The rule
  backup result now carries `CloudSaveNotices`, `SkipReasons`, `SecretExcludedFiles` and
  `BackedUpRules`. `Restore-Nano11UserData` gained `-Categories` and
  `Restore-Nano11CustomPaths` gained `-SourcePath`; CustomPath entries are no longer
  restored by the user-data path. The default backup folder moved out of Documents.
- GUI structure (S10): `Show-Nano11GUI` is split into one function per tab; colours live in
  `$script:Nano11GuiColors`; OK message boxes go through `Show-Nano11GuiMessage`; background
  work goes through `Invoke-Nano11GuiBusy` / `Invoke-Nano11GuiBackgroundJob`; the default
  backup folder is defined once (`Get-Nano11DefaultMigrationBackupPath`); new form, combo box,
  tab control and text box parts. The migrator window is built from these shared parts
  (the control tree is identical to before). Controls, positions and handlers are unchanged.
- Builder structure (S11): `Invoke-Nano11SelfTest` is split into one small function per
  check (output and exit code unchanged); `OutputType` declared on helpers flagged by
  PSScriptAnalyzer.
- Code hygiene (no behaviour change): empty `catch {}` blocks now log via `Write-Verbose`,
  `$null` moved to the left of comparisons, positional parameters named, unused variables
  removed, trailing whitespace stripped.
- The regenerated `nano11_report.html` is no longer tracked by git.

### Fixed
- `Import-Nano11UserExtensions -PresetsOnly` (the builder's second call) wiped the user's
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
  with "Build succeeded and safety checks passed" and produced `nano11.iso` (7,888,314,368
  bytes); `nano11_report.html` was refreshed from the same run.

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
- `tests/nano11.Tests.ps1`: Pester suite covering AST syntax, unattend schema,
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
  `Remove-Nano11TreeRobust` helper prunes reparse points first (applied-image
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
  now done in-process: `Enable-Nano11TokenPrivileges` enables SeTakeOwnership /
  SeRestore / SeBackup on the PowerShell token (P/Invoke), and `Repair-Nano11DeniedAcl`
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
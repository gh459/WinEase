English: this file / 日本語版: [EXTENSIBILITY_GUIDE.ja.md](EXTENSIBILITY_GUIDE.ja.md)

# WinEase Extensibility Guide

How to add your own settings, scripts and backup targets without editing WinEase's code.

- **Part 1: Beginner quick start** - things you can do by adding a few lines to a file
- **Part 2: Reference** - folder layout, custom scripts, error handling, safe verification

The files you edit live in `config/user/`; custom scripts live in `tools/custom-scripts/<Stage>/`.
All of them are optional. Without them WinEase runs normally.

---

# Part 1: Beginner quick start

## 1. Add your own registry setting and a GUI checkbox

Example: turn off the Sticky Keys confirmation shown when Shift is pressed five times.

### Steps

1. Open `config/user/user-tweaks.psd1` in a text editor.
2. Add an entry inside `UserTweaks = @( ... )` (or just remove the leading `#` of the sample):

   ```powershell
   UserTweaks = @(
       @{
           Key         = 'User_DisableStickyKeysPrompt'
           Category    = 'UI'
           Default     = $false
           Description = '[User] Disable Sticky Keys (Shift x5) popup shortcut'
           Impact      = 'Safe'
           Actions     = @(
               @{ Type = 'Registry'; Hive = 'zNTUSER'; Path = 'Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Kind = 'String'; Value = '506' }
           )
       }
   )
   ```

3. Save, then start the GUI with `WinEase-GUI.bat`.
4. Because `Category = 'UI'`, the checkbox appears at the bottom of tab **5. UI & Shell**.
   Categories other than `Security` / `Privacy` / `Performance` / `UI` (for example `System`, `Gaming`, `UserCustom`) appear on tab **9. User Tweaks**.
5. Tick it and build; Phase 10 (registry) writes the value into the image.
   On the command line use a hashtable: `-TweakSettings @{ User_DisableStickyKeysPrompt = $true }`.

### Fields

| Field | Meaning |
| :--- | :--- |
| `Key` | Name of the setting. Start it with `User_`. A key that already exists in `config/schema.psd1` is skipped with a warning |
| `Category` | Which GUI tab shows it (see above) |
| `Default` | Whether it is ticked initially |
| `Description` | Checkbox text |
| `DescriptionJa` | Optional. Japanese checkbox text the GUI shows in Japanese mode (display language `-UiLanguage ja`). Save the file as UTF-8 **with BOM** if it contains Japanese |
| `Impact` | How the dependency check treats it. `'Safe'` = no impact. If omitted it counts as Unknown and is warned about |
| `Actions` | What runs when the tweak is enabled (see below) |

### Registry actions

`Hive` is the name the offline image's registry is loaded under. `Path` is the key below it, without `HKLM\`.

| `Hive` | Corresponds to |
| :--- | :--- |
| `zNTUSER` | Default user profile (inherited by newly created users, like `HKCU`) |
| `zSOFTWARE` | `HKLM\SOFTWARE` |
| `zSYSTEM` | `HKLM\SYSTEM` |

`Kind` is one of `String` / `ExpandString` / `Binary` / `DWord` / `MultiString` / `QWord` (default `String`).
To change a service start type use `@{ Type = 'Service'; Name = 'ServiceName'; Value = 'Disabled' }` (`Disabled` / `Manual` / `Automatic`).

### If it does not work

- Warnings at build start (`[UserExtensions] ...`) report duplicate keys and missing required fields (`Key` / `Category` / `Description`).
- Check first with `-DryRun` (Part 2, section 4); nothing is written to a real image.

## 2. Add a game-save folder the migrator does not know

The PC migration tool (`tools/migrator/WinEase-Migrator.ps1`) supports about 30 games and apps out of the box (`tools/migrator/migration-rules.psd1`).
You can add your own.

### Steps

1. Open `config/user/user-migration-rules.psd1`.
2. Uncomment and edit a rule inside `GameRules = @( ... )`:

   ```powershell
   GameRules = @(
       @{
           Id              = 'MyCustomGame'
           Name            = 'My Custom Game Saves'
           Category        = 'GameSave'
           StorageType     = 'Local'
           SourcePaths     = @('%USERPROFILE%\Saved Games\MyGame')
           ExcludePatterns = @('*.log')
           ProcessNames    = @('MyGame')
           CloudSaveNotice = ''
           RestoreHint     = ''
       }
   )
   ```

3. Check that the rule is recognized:

   ```powershell
   .\tools\migrator\WinEase-Migrator.ps1 -Mode ListRules
   ```

4. Estimate the size and try a backup without writing anything (`D:\backup` is an example):

   ```powershell
   .\tools\migrator\WinEase-Migrator.ps1 -Mode Estimate -PackagePath D:\backup -RuleIds MyCustomGame
   .\tools\migrator\WinEase-Migrator.ps1 -Mode Backup -PackagePath D:\backup -RuleIds MyCustomGame -DryRun
   ```

   If it looks right, run it again without `-DryRun`. You can also use tab **8. Migration & Backup** of the build GUI, or the wizard that opens when you start WinEase-Migrator without arguments.

### Fields

| Field | Meaning |
| :--- | :--- |
| `Id` | Rule name (used with `-RuleIds`). Must be unique |
| `Name` | Name shown in the UI and report |
| `SourcePaths` | Folders/files to back up. Environment variables such as `%USERPROFILE%` and `%APPDATA%` work |
| `ExcludePatterns` | File name patterns to skip |
| `ProcessNames` | The game's process names. While running, the backup is skipped and you are told |
| `CloudSaveNotice` / `RestoreHint` | Notes shown in the report (cloud-save caveats, restore hints) |

App settings go in `AppConfigRules` and arbitrary folders in `CustomPathRules`, in the same format (the template has examples).
Files that look like passwords or tokens are excluded automatically by default.

---

# Part 2: Reference

## 1. Folder layout and file roles

```text
WinEase-main/
├── WinEasebuilder.ps1      Main script: parameters, configuration, calls the phases
├── WinEasehelpers.ps1      Small shared functions (path validation, config file lookup, ...)
├── lib/                   Function libraries loaded by the builder
├── phases/                Build steps (01-18)
├── gui/WinEaseGui.ps1      WinForms GUI
├── config/                Configuration files
├── scripts/               Setup scripts embedded into the image
├── tools/                 Helper tools and custom scripts
├── profiles/              Saved profiles (JSON)
├── templates/report.html  Report template
└── tests/WinEase.Tests.ps1 Pester tests
```

`WinEasebuilder.ps1` **dot-sources** `phases/*.ps1` and `lib/*.ps1` and shares variables in script scope.
Load any new file the same way (turning it into a module would hide those variables).

### lib/

| File | Role |
| :--- | :--- |
| `WinEaseMount.ps1` | DISM mount discovery/cleanup, mount directories, offline registry |
| `WinEaseFileSystem.ps1` | Directory safety checks, ownership and ACLs, robust deletion, free space |
| `WinEaseWim.ps1` | WIM export, fingerprinting, repair |
| `WinEaseReport.ps1` | HTML report (`WinEase_report.html`) |
| `WinEaseResume.ps1` | `-ResumeIsoOnly` and per-phase checkpoints |
| `WinEaseSelfTest.ps1` | `-TestSelf` diagnostics (loaded only for `-TestSelf`) |
| `WinEaseExtensions.ps1` | Extension engine (user settings, custom scripts, config diff, recovery readiness) |

### phases/

| Phase | Content |
| :--- | :--- |
| `01-environment.ps1` | Environment checks |
| `02-source-media.ps1` | Source media (ISO / drive) |
| `03-staging.ps1` | Working folder setup |
| `04-mount-baseline.ps1` | Mount the image, record the baseline |
| `05-appx.ps1` | AppX removal |
| `06-fod.ps1` | Features on Demand removal |
| `07-nativeimages.ps1` | .NET native image cleanup |
| `08-filesystem.ps1` | File and folder removal |
| `09-physical-debloat.ps1` | Advanced debloat (physical deletion). Has a consent gate and mount-path validation; requires `-AllowPhysicalDebloat` |
| `09-winsxs.ps1` | WinSxS cleanup |
| `10-registry.ps1` | Load the offline registry and apply settings (user `Registry` actions run here too) |
| `11-unattend.ps1` | Embed answer file and setup scripts, stage custom scripts, unload the registry |
| `12-unmount-commit.ps1` | Unmount and commit |
| `13-export.ps1` | Export install.wim / .esd |
| `14-bootwim.ps1` | boot.wim adjustments |
| `15-verify.ps1` | Verification |
| `16-iso-cleanup.ps1` | ISO-side cleanup |
| `17-oscdimg.ps1` | Prepare `oscdimg.exe` |
| `18-iso.ps1` | ISO creation |

### config/

| File | Role |
| :--- | :--- |
| `schema.psd1` | The **single source of truth** for every switch and component. The GUI, profiles and CLI are generated from it |
| `dependencies.psd1` | Dependency/impact catalog (used to detect Conflicts, Impacts, Unknowns) |
| `WinEase.config.schema.json` | JSON schema for profiles |
| `user/user-tweaks.psd1` | Your tweaks, presets and custom scripts |
| `user/user-migration-rules.psd1` | Your migration rules |

An old `user-*.psd1` directly under `config/` is still read, with a warning, when the new location has no file. Move it to `config/user/`.

### gui/ and tools/

| File | Role |
| :--- | :--- |
| `gui/WinEaseGui.ps1` | The GUI, split into one function per tab, plus shared control parts |
| `tools/migrator/WinEase-Migrator.ps1` | PC migration/backup tool (CLI and GUI wizard) |
| `tools/migrator/WinEaseMigration.ps1` | Migration engine (backup, restore, app inventory, report) |
| `tools/migrator/migration-rules.psd1` | Standard migration rules |
| `tools/custom-scripts/<Stage>/` | Custom script folders (next section) |
| `tools/winease-physical-debloat/` | Rust tool for physical deletion |
| `tools/Measure-WinEaseGuestBaseline.ps1` / `tools/Compare-WinEaseBenchmarks.ps1` | Post-install measurement and comparison |

GUI tab **8. Migration & Backup** loads `tools/migrator/WinEaseMigration.ps1` the first time it is opened (the builder itself does not load the migration engine).
With `-IncludeMigrationAssistant` the migrator and its rules are bundled into the ISO under `Windows\Setup\Scripts\Migration` (no personal data included).

## 2. The four custom-script stages

Put `.ps1` files in `tools/custom-scripts/<Stage>/` and they are found automatically. You can also register them in `CustomScripts` in `config/user/user-tweaks.psd1`.

| Stage | When / where | Privileges |
| :--- | :--- | :--- |
| `PreBuild` | Right at build start (after the dependency check, before source media checks), on the build PC | User running the build |
| `OfflineImage` | End of Phase 11, on the build PC, against the mounted image | User running the build |
| `FirstLogon` | At first logon after installation | Administrator |
| `UserOnce` | After the user profile is initialized | Standard user |

For `PreBuild` and `OfflineImage` the builder calls the script directly with `-WinEaseContext`.
`FirstLogon` and `UserOnce` scripts are not run at build time; they are copied into the image under `Windows\Setup\Scripts\Custom\...` and run after installation (log: `C:\ProgramData\WinEase\Logs\custom-scripts.log`; `UserOnce`: `%TEMP%\UserOnce-custom.log`).
`FirstLogon` / `UserOnce` also accept `.bat` / `.cmd` / `.reg` (see `tools/custom-scripts/README.md`).

### Script template

```powershell
# @WinEase-Id: MyScript
# @WinEase-Stage: PreBuild
# @WinEase-Order: 100
# @WinEase-OnError: Warn
# @WinEase-Description: What it does
param($WinEaseContext)
Write-Host "ScratchDir: $($WinEaseContext.ScratchDir)"
```

Metadata comments in the first 30 lines: `# @WinEase-Id` / `Stage` / `Order` / `Condition` / `OnError` / `Description`.
Scripts run by ascending `Order`, then by file name. Set `Condition` to a setting key to run only when it is enabled.

### `$WinEaseContext`

A hashtable passed to `PreBuild` / `OfflineImage` scripts.

| Stage | Contents |
| :--- | :--- |
| `PreBuild` | `Config` (current configuration), `ScriptRoot` (repository folder) |
| `OfflineImage` | `ScratchDir` (root of the mounted image), `WinEaseDir`, `Config` |

`FirstLogon` / `UserOnce` scripts get no context; they simply run on the installed PC.

### Offline registry (`HKLM:\zSOFTWARE` / `zNTUSER` / `zSYSTEM`)

In Phase 10 the builder loads the image's registry as `HKLM\zSYSTEM`, `HKLM\zSOFTWARE`, `HKLM\zDEFAULT`, `HKLM\zCOMPONENTS` and `HKLM\zNTUSER` (the default user's `ntuser.dat`), and **unloads all of them** partway through Phase 11. Therefore:

- User-tweak `Registry` actions (Part 1, section 1) run while the hives are loaded, so `Hive = 'zNTUSER'` etc. work as is.
- **When an `OfflineImage` script runs, these hives are no longer loaded.** To touch the registry, load the hive yourself and always unload it afterwards:

  ```powershell
  param($WinEaseContext)
  $hive = Join-Path $WinEaseContext.ScratchDir 'Users\Default\ntuser.dat'
  & reg.exe load HKLM\zMyNtuser $hive
  try {
      & reg.exe add 'HKLM\zMyNtuser\Software\MyApp' /v Enabled /t REG_DWORD /d 1 /f
  } finally {
      [GC]::Collect()
      & reg.exe unload HKLM\zMyNtuser
  }
  ```

  Use a name other than the builder's `zSOFTWARE` etc. (above: `zMyNtuser`) to avoid collisions.

## 3. Error handling and security notes

### `OnError`

Set it in a `CustomScripts` entry or with `# @WinEase-OnError:`. Default `Warn`.

| Value | Behavior |
| :--- | :--- |
| `Stop` | Rethrows the script's exception to the caller and skips the remaining scripts. The caller catches it (builder for `PreBuild`, Phase 11 for `OfflineImage`), so the **build as a whole does not stop** (`PreBuild` prints a warning; `OfflineImage` records it only under `-Verbose`) |
| `Warn` | Prints a warning and continues with the next script |
| `Ignore` | Continues silently (reason visible with `-Verbose`) |

It only applies to exceptions in `PreBuild` / `OfflineImage` scripts. `FirstLogon` / `UserOnce` run after installation and never stop the build.
With `Warn` / `Ignore`, remaining scripts still run. For `FirstLogon`, failures (exit code, reason) are written to the log.

### Security notes

- **Custom scripts run with the build user's (administrator) privileges at build time, and with administrator privileges for `FirstLogon`.** Only place scripts whose contents you have reviewed.
- At build time the SHA-256 of each script is recorded in `custom-scripts-manifest.json` and checked at first logon. A script not in the manifest, or modified afterwards, is refused with `[SECURITY REFUSAL]`. The check is fail-closed: with a missing or broken manifest no custom script runs at all. It shows only that the file is unchanged since the build; it does not protect against someone who can change both the script and the manifest (see `docs/SECURITY_OPTIONS.md`).
- Passwords, tokens, API keys and product keys in the logs are replaced with `[REDACTED]`. Still, do not write them into scripts.
- Backups contain personal data. Credential-like files are excluded by default (included only with `-IncludeSecrets`). Store backups somewhere safe.
- A user tweak without `Impact` counts as Unknown, and `-StrictDependencyCheck` stops the build for it.

### Current limitation

User-tweak `AppxRemove` / `FeatureDisable` / `CapabilityRemove` are accepted in the schema, but the current code only writes what it would do to the `-Verbose` log and removes nothing.
Only `Registry` and `Service` actually take effect. To remove AppX packages or features, call DISM from an `OfflineImage` custom script.

## 4. Safe verification

Before a real build (tens of minutes, needs administrator rights and disk space), check in this order:

1. **Syntax and self-test** - writes nothing to disk, needs no ISO:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinEasebuilder.ps1 -TestSelf
   ```

2. **DryRun** - resolves and prints configuration, paths and detected custom scripts without touching disks or images. `PreBuild` / `OfflineImage` scripts are not executed:

   ```powershell
   .\WinEasebuilder.ps1 -NonInteractive -Profile balanced -DryRun
   ```

3. **Strict dependency check** - stops on any Conflict or Unknown:

   ```powershell
   .\WinEasebuilder.ps1 -NonInteractive -Profile balanced -DryRun -StrictDependencyCheck
   ```

4. **Compare with a preset** - prints how the current configuration differs from a preset (name or JSON path) and exits without building:

   ```powershell
   .\WinEasebuilder.ps1 -Profile balanced -ComparePreset extreme
   ```

5. **Pester tests** - checks the repository rules (syntax, zero PSScriptAnalyzer warnings, GUI wiring, ...):

   ```powershell
   Invoke-Pester -Script .\tests\WinEase.Tests.ps1
   ```

6. **Migrator** - run `-Mode Estimate` (size estimate) and `-DryRun` (no writes) first.

If you write your own `.ps1` / `.psd1` without a BOM, keep it ASCII-only (non-ASCII text is garbled by Windows PowerShell 5.1; the tests detect this). Documents like this `.md` are exempt.

# nano11 Extensibility Guide

## Overview

nano11 supports user-defined extensions without modifying the core codebase. Three extension mechanisms are available:

1. **User Tweaks** (`config/user-tweaks.psd1`) — custom tweaks, presets and scripts
2. **Migration Rules** (`config/user-migration-rules.psd1`) — custom PC migration rules
3. **Custom Scripts** (`scripts/custom/<Stage>/*.ps1`) — stage-based hook scripts

## 1. User Tweaks

Edit `config/user-tweaks.psd1` to add custom tweaks. Each tweak becomes a first-class setting
integrated into the GUI, CLI, profiles and dependency checker.

### Schema

```powershell
@{
    SchemaVersion = '1.0'
    UserTweaks = @(
        @{
            Key         = 'User_MyTweak'           # unique id (use 'User_' prefix)
            Category    = 'UI'                     # System|Privacy|Gaming|UI|Security|UserCustom
            Default     = $false
            Description = 'My custom tweak'
            Impact      = 'Safe'                   # 'Safe' | 'Unknown' | @{ AffectedFeatures = @(...); Severity = 'Warning'; Reason = '...' }
            Actions     = @(                        # declarative actions executed when enabled
                @{ Type = 'Registry'; Hive = 'zNTUSER'; Path = 'Software\...'; Name = 'ValueName'; Kind = 'DWord'; Value = 1 }
            )
        }
    )
    UserPresets = @{
        # 'my-preset' = @{ BasePreset = 'balanced'; ProfileName = 'My Preset'; MyTweak = $true }
    }
    CustomScripts = @(
        # @{ Id = 'MyScript'; Path = 'scripts\custom\PreBuild\01-myscript.ps1'; Stage = 'PreBuild'; Order = 100; Condition = ''; OnError = 'Warn'; Enabled = $true; Description = '...' }
    )
}
```

### Action Types

| Type | PhaseType | Description |
|------|-----------|-------------|
| `Registry` | Registry | Sets a registry value on a mounted hive (zNTUSER, zSOFTWARE, zSYSTEM, etc.) |
| `Service` | Registry | Sets a service Start value (Disabled=4, Manual=3, Automatic=2) |
| `AppxRemove` | Appx | Removes a provisioned AppX package by pattern |
| `FeatureDisable` | FOD | Disables a Windows feature via DISM |
| `CapabilityRemove` | FOD | Removes a Windows capability via DISM |

### Custom Script Metadata

Place scripts in `scripts/custom/<Stage>/` (PreBuild, OfflineImage, FirstLogon, UserOnce)
or declare them in `CustomScripts`. Scripts can include metadata headers:

```powershell
# @Nano11-Id: MyScript
# @Nano11-Stage: PreBuild
# @Nano11-Order: 100
# @Nano11-Condition: User_MyTweak
# @Nano11-OnError: Warn
# @Nano11-Description: My custom pre-build check
```

## 2. Migration Rules

Edit `config/user-migration-rules.psd1` to add custom migration rules for PC-to-PC transfer.

### Game Save Rule Schema

```powershell
@{
    Id              = 'MyGameSaves'
    Name            = 'My Game Saves'
    Category        = 'GameSave'
    StorageType     = 'Local'  # 'Local' | 'HybridCloud' | 'AccountBound'
    SourcePaths     = @('%USERPROFILE%\Saved Games\MyGame')
    ExcludePatterns = @('*.log')
    ProcessNames    = @('MyGame')
    CloudSaveNotice = 'Steam Cloud syncs this folder.'
    RestoreHint     = 'Restore before launching the game.'
}
```

### App Config Rule Schema

```powershell
@{
    Id              = 'MyAppConfig'
    Name            = 'My App Config'
    Category        = 'AppConfig'
    SourcePaths     = @('%APPDATA%\MyApp\config.json')
    ExcludePatterns = @()
    ProcessNames    = @('MyApp')
    ExcludeSecrets  = $true
    RestoreHint     = 'Install MyApp first.'
    RegistryPaths   = @('HKCU:\Software\MyApp')  # optional, for registry-based config
}
```

## 3. CLI Usage

### Build with User Extensions

```powershell
.\nano11builder.ps1 -GUI
# or
.\nano11builder.ps1 -NonInteractive -Profile extreme
```

User tweaks are automatically loaded from `config/user-tweaks.psd1` if present.

### Migration Tool

```powershell
# Backup
.\tools\Nano11-Migrator.ps1 -Mode Backup -BackupRoot D:\nano11_backup

# Restore
.\tools\Nano11-Migrator.ps1 -Mode Restore -BackupRoot D:\nano11_backup

# Export app inventory
.\tools\Nano11-Migrator.ps1 -Mode ExportApps -OutputPath D:\apps-inventory.json
```

### Dependency Check (Strict)

```powershell
.\nano11builder.ps1 -DryRun -StrictDependencyCheck
```

## 4. Recovery Readiness

Run the recovery readiness diagnostic:

```powershell
. .\lib\Nano11Migration.ps1
Test-Nano11RecoveryReadiness -Config (Get-Nano11CurrentConfig)
```

## 5. Configuration Diff

Compare two presets:

```powershell
. .\lib\Nano11Extensions.ps1
$diff = Compare-Nano11Config -ReferenceConfig 'balanced' -DifferenceConfig 'extreme'
Format-Nano11ConfigDiff -DiffResult $diff
```

## 6. Safety Notes

- Secret files (cookies, credentials, tokens, private keys) are excluded by default during migration.
- Backup never deletes source files (read-only copy).
- Restore creates `.nano11.bak` backups of existing files before overwriting.
- Corrupt files (hash mismatch) are blocked from restore.
- Physical debloat requires explicit `-AllowPhysicalDebloat` consent.
- Unknown dependencies are warned, not silently ignored.

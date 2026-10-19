# user-migration-rules.psd1 - User-defined migration rules for nano11
@{
    SchemaVersion = '1.0'

    DefaultSecretExcludePatterns = @()

    GameRules = @(
        # @{
        #     Id              = 'MyCustomGame'
        #     Name            = 'My Custom Game Saves'
        #     Category        = 'GameSave'
        #     StorageType     = 'Local'
        #     SourcePaths     = @('%USERPROFILE%\Saved Games\MyGame')
        #     ExcludePatterns = @('*.log')
        #     ProcessNames    = @('MyGame')
        #     CloudSaveNotice = ''
        #     RestoreHint     = ''
        # }
    )

    AppConfigRules = @(
        # @{
        #     Id              = 'MyCustomApp'
        #     Name            = 'My Custom App Config'
        #     Category        = 'AppConfig'
        #     SourcePaths     = @('%APPDATA%\MyApp\config.json')
        #     ExcludePatterns = @()
        #     ProcessNames    = @()
        #     ExcludeSecrets  = $true
        #     RestoreHint     = ''
        # }
    )

    # Custom path rules: back up arbitrary files/folders preserving directory structure
    CustomPathRules = @(
        # @{
        #     Id              = 'MyCustomFolder'
        #     Name            = 'My Custom Folder'
        #     Category        = 'CustomPath'
        #     SourcePaths     = @('%USERPROFILE%\MyCustomFolder')
        #     ExcludePatterns = @('*.tmp','*.log')
        #     ProcessNames    = @()
        #     ExcludeSecrets  = $true
        #     RestoreHint     = 'Restores to %USERPROFILE%\MyCustomFolder'
        # }
    )
}

@{
    SchemaVersion = '1.0'
    DefaultSecretExcludePatterns = @()
    GameRules = @()
    CustomPathRules = @()
    AppConfigRules = @(
        @{
            Id = 'TestMultiRegistry'
            Name = 'Test Multi Registry'
            Category = 'AppConfig'
            SourcePaths = @()
            ExcludePatterns = @()
            ProcessNames = @()
            ExcludeSecrets = $false
            RegistryPaths = @('HKCU\Software\WinEaseRuleTest1', 'HKCU\Software\WinEaseRuleTest2')
            RestoreHint = ''
        }
    )
}
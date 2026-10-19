# user-tweaks.psd1 - User-defined tweaks, presets and custom scripts for nano11.
#
# This file is OPTIONAL. If it does not exist, nano11 runs normally without user extensions.
# Users can add their own options here without editing config/tweaks.psd1.
#
# SchemaVersion: '1.0'
# UserTweaks:    array of tweak definitions (see schema below)
# UserPresets:   hashtable of preset-name -> override hashtable
# CustomScripts: array of custom script definitions
@{
    SchemaVersion = '1.0'

    # User-defined tweaks (optional). Each entry becomes a first-class tweak:
    #   Key         unique identifier (use 'User_' prefix to avoid collisions)
    #   Category    'System' | 'Privacy' | 'Gaming' | 'UI' | 'Security' | 'UserCustom'
    #   Default     $true | $false
    #   Description GUI / CLI description text
    #   DescriptionJa (optional) Japanese text the GUI shows instead of Description in Japanese mode;
    #               save this file as UTF-8 with BOM if it contains Japanese
    #   Impact      'Safe' | 'Unknown' | @{ AffectedFeatures = @(...); Severity = 'Warning'; Reason = '...' }
    #   Actions     array of declarative actions executed when the tweak is enabled
    UserTweaks = @(
        # Example:
        # @{
        #     Key         = 'User_DisableStickyKeysPrompt'
        #     Category    = 'UI'
        #     Default     = $false
        #     Description = '[User] Disable Sticky Keys (Shift x5) popup shortcut'
        #     Impact      = 'Safe'
        #     Actions     = @(
        #         @{ Type = 'Registry'; Hive = 'zNTUSER'; Path = 'Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Kind = 'String'; Value = '506' }
        #     )
        # }
    )

    # User-defined presets (optional). Each overrides a base preset.
    # Example: 'my-workstation' = @{ BasePreset = 'balanced'; ProfileName = 'My Custom Workstation'; Description = '...'; User_ShowFileExtensionsAndHidden = $true }
    UserPresets = @{
    }

    # Custom scripts (optional). Each runs at the specified stage.
    # Alternatively, drop scripts into tools/custom-scripts/<Stage>/*.ps1 for auto-detection.
    CustomScripts = @(
        # @{
        #     Id          = 'SamplePreBuildCheck'
        #     Path        = 'tools\custom-scripts\PreBuild\01-sample-check.ps1'
        #     Stage       = 'PreBuild'     # 'PreBuild' | 'OfflineImage' | 'FirstLogon' | 'UserOnce'
        #     Order       = 100
        #     Condition   = ''             # empty = always; or a Tweak key name
        #     OnError     = 'Warn'         # 'Stop' | 'Warn' | 'Ignore'
        #     Enabled     = $false
        #     Description = 'Sample pre-build hook script'
        # }
    )
}

# config\registry\security.psd1 - Security and stability controls
#
# Applied by Invoke-WinEaseRegistryTable (lib\WinEaseRegistry.ps1) from phases\10-registry.ps1.
# Entry: @{ Tweak; Default; Hive; Path; Name; Type; Data; MinBuild; MaxBuild }
#   Tweak     key of the setting that switches the entry on (config\schema.psd1)
#   Default   value of the setting when no profile or preset sets it
#   Hive      offline hive (zSYSTEM, zSOFTWARE, zDEFAULT, zNTUSER) or a list of them
#   Path      key below the hive; never below CurrentControlSet - an offline SYSTEM hive
#             has no CurrentControlSet, the key would be created literally (Bug Check 0x67)
#   Name      value name; empty = the unnamed (default) value
#   Type      REG_SZ, REG_DWORD, REG_EXPAND_SZ, REG_BINARY or REG_NONE
#   Data      the data as reg.exe takes it; empty = the empty string
#   MinBuild / MaxBuild  optional, inclusive Windows build numbers the entry applies to (absent = no limit)
@{
    Version = '1.0'

    Entries = @(
        # --- DisableSmartScreen ------------------------------------------
        @{ Tweak = 'DisableSmartScreen'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'EnableSmartScreen'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableSmartScreen'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled'; Type = 'REG_SZ'; Data = 'Off' }
        @{ Tweak = 'DisableSmartScreen'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'SmartScreenEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableSmartScreen'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'SmartScreenPuaEnabled'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableUAC --------------------------------------------------
        @{ Tweak = 'DisableUAC'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ConsentPromptBehaviorAdmin'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableUAC'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'PromptOnSecureDesktop'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableVBS --------------------------------------------------
        @{ Tweak = 'DisableVBS'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\DeviceGuard'; Name = 'EnableVirtualizationBasedSecurity'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableVBS'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\DeviceGuard'; Name = 'RequirePlatformSecurityFeatures'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableVBS'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\DeviceGuard'; Name = 'Locked'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableVBS'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; Name = 'Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableVBS'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; Name = 'Locked'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableWPBT -------------------------------------------------
        @{ Tweak = 'DisableWPBT'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager'; Name = 'DisableWpbtExecution'; Type = 'REG_DWORD'; Data = '1' }

        # --- HardenSystemSecurity ----------------------------------------
        # LSA protection (2 = enabled without the UEFI lock, so it can still be turned off)
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Lsa'; Name = 'RunAsPPL'; Type = 'REG_DWORD'; Data = '2' }
        # No clear-text credentials in LSASS memory
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\SecurityProviders\WDigest'; Name = 'UseLogonCredential'; Type = 'REG_DWORD'; Data = '0' }
        # NTLMv2 only, refuse LM and NTLM
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Lsa'; Name = 'LmCompatibilityLevel'; Type = 'REG_DWORD'; Data = '5' }
        # No anonymous enumeration of SAM accounts and shares
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Lsa'; Name = 'RestrictAnonymous'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Lsa'; Name = 'RestrictAnonymousSAM'; Type = 'REG_DWORD'; Data = '1' }
        # Remote Assistance off
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Remote Assistance'; Name = 'fAllowToGetHelp'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fAllowToGetHelp'; Type = 'REG_DWORD'; Data = '0' }
        # AutoRun / AutoPlay off for every drive type
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun'; Type = 'REG_DWORD'; Data = '255' }
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoAutorun'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Explorer'; Name = 'NoAutoplayfornonVolume'; Type = 'REG_DWORD'; Data = '1' }
        # PowerShell script block logging (event 4104)
        @{ Tweak = 'HardenSystemSecurity'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; Name = 'EnableScriptBlockLogging'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableBSODEmoticon -----------------------------------------
        @{ Tweak = 'DisableBSODEmoticon'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\CrashControl'; Name = 'DisplayParameters'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableBSODEmoticon'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\CrashControl'; Name = 'DisableEmoticon'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableFTH --------------------------------------------------
        @{ Tweak = 'DisableFTH'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\FTH'; Name = 'Enabled'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisablePCA --------------------------------------------------
        @{ Tweak = 'DisablePCA'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppCompat'; Name = 'DisablePCA'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisablePCA'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppCompat'; Name = 'DisableEngine'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisablePCA'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppCompat'; Name = 'DisableInventory'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisablePCA'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppCompat'; Name = 'AITEnable'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisablePCA'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppCompat'; Name = 'DisableUAR'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableDeliveryOptimization ---------------------------------
        @{ Tweak = 'DisableDeliveryOptimization'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Type = 'REG_DWORD'; Data = '0' }

        # --- BypassActivationRestrictions --------------------------------
        @{ Tweak = 'BypassActivationRestrictions'; Default = $false; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Control Panel\Desktop'; Name = 'PaintDesktopVersion'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassActivationRestrictions'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Windows'; Name = 'DisplayNotGenuine'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassActivationRestrictions'; Default = $false; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'; Name = 'NoChangingWallPaper'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassActivationRestrictions'; Default = $false; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoThemesTab'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassActivationRestrictions'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoThemesTab'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassActivationRestrictions'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform'; Name = 'NoGenTicket'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassActivationRestrictions'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform'; Name = 'NotificationDisabled'; Type = 'REG_DWORD'; Data = '1' }
    )
}

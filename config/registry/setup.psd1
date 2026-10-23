# config\registry\setup.psd1 - Setup, hardware requirement bypasses, OOBE and script execution policy
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
        # --- BypassHardwareRequirements ----------------------------------
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\LabConfig'; Name = 'BypassCPUCheck'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\LabConfig'; Name = 'BypassRAMCheck'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\LabConfig'; Name = 'BypassSecureBootCheck'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\LabConfig'; Name = 'BypassStorageCheck'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\LabConfig'; Name = 'BypassTPMCheck'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\LabConfig'; Name = 'BypassDiskCheck'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\MoSetup'; Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zDEFAULT'; Path = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zDEFAULT'; Path = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zNTUSER'; Path = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'BypassHardwareRequirements'; Default = $true; Hive = 'zNTUSER'; Path = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Type = 'REG_DWORD'; Data = '0' }

        # --- BypassNRO ---------------------------------------------------
        @{ Tweak = 'BypassNRO'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassNRO'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\ReserveManager'; Name = 'ShippedWithReserves'; Type = 'REG_DWORD'; Data = '0' }

        # --- PreventDeviceEncryption -------------------------------------
        @{ Tweak = 'PreventDeviceEncryption'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'PreventDeviceEncryption'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\EnhancedStorageDevices'; Name = 'TCGSecurityActivationDisabled'; Type = 'REG_DWORD'; Data = '1' }

        # --- SetJapaneseKeyboard -----------------------------------------
        @{ Tweak = 'SetJapaneseKeyboard'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\i8042prt\Parameters'; Name = 'LayerDriver JPN'; Type = 'REG_SZ'; Data = 'kbd106.dll' }
        @{ Tweak = 'SetJapaneseKeyboard'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\i8042prt\Parameters'; Name = 'OverrideKeyboardIdentifier'; Type = 'REG_SZ'; Data = 'PCAT_106KEY' }
        @{ Tweak = 'SetJapaneseKeyboard'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\i8042prt\Parameters'; Name = 'OverrideKeyboardType'; Type = 'REG_DWORD'; Data = '7' }
        @{ Tweak = 'SetJapaneseKeyboard'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\i8042prt\Parameters'; Name = 'OverrideKeyboardSubtype'; Type = 'REG_DWORD'; Data = '2' }

        # --- EnableScripts -----------------------------------------------
        @{ Tweak = 'EnableScripts'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'; Name = 'ExecutionPolicy'; Type = 'REG_SZ'; Data = 'RemoteSigned' }
        @{ Tweak = 'EnableScripts'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\PowerShell'; Name = 'EnableScripts'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'EnableScripts'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\PowerShell'; Name = 'ExecutionPolicy'; Type = 'REG_SZ'; Data = 'RemoteSigned' }

        # --- BypassNetworkRequirement ------------------------------------
        @{ Tweak = 'BypassNetworkRequirement'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'BypassNetworkRequirement'; Default = $true; Hive = 'zSYSTEM'; Path = 'Setup\LabConfig'; Name = 'BypassNRO'; Type = 'REG_DWORD'; Data = '1' }

    )
}

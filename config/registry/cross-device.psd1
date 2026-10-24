# config\registry\cross-device.psd1 - Cross-device experience, Phone Link and Resume
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
        # --- DisableCrossDevice ------------------------------------------
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CrossDevice'; Name = 'AllowCrossDeviceExperience'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CrossDevice'; Name = 'AllowCrossDeviceResume'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CrossDevice'; Name = 'DisableResume'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CrossDevice'; Name = 'DisableCrossDeviceResume'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'EnableCdp'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'EnableMmx'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'AllowCrossDeviceClipboard'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCrossDevice'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration'; Name = 'IsResumeAllowed'; Type = 'REG_DWORD'; Data = '0' }
        # ReviOS 26.10 (registry/explorer/win-settings.yml): the shell host of the
        # Cross Device Resume app is redirected to ShellHost.exe, so the resume host
        # can never start. Upstream replaced the FeatureManagement override and the
        # IFEO redirect with this one because it is the reliable variant.
    )
}

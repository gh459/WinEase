# config\registry\defender.psd1 - Windows Defender policies written when the Defender is removed
#
# Applied by Invoke-WinEaseRegistryTable (lib\WinEaseRegistry.ps1) from phases\10-registry.ps1.
# Only the plain policy values are here. The ELAM neutralisation, the service key removal with
# its verification, the IFEO traps and the DACL elevation depend on query results and loops and
# stay in the phase. See config\registry\security.psd1 for the entry fields.
@{
    Version = '1.0'

    Entries = @(
        # --- RemoveDefender ------------------------------------------------
        # Tamper Protection must be off before the engine can be stopped or removed.
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows Defender\Features'; Name = 'TamperProtection'; Type = 'REG_DWORD'; Data = '0' }
        # DisableAntiSpyware no longer disables the engine on Windows 11 24H2+ (Microsoft removed
        # the behaviour), so it is kept only for legacy builds and the working policies below are
        # the actual mechanism.
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender'; Name = 'DisableAntiSpyware'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender'; Name = 'DisableAntiVirus'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableBehaviorMonitoring'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableOnAccessProtection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableScanOnRealtimeEnable'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\MpEngine'; Name = 'MpEngineEnableFileNameFiltering'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Spynet'; Name = 'SubmitSamplesConsent'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Spynet'; Name = 'SpynetReporting'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Spynet'; Name = 'SpynetProtection'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Signature Updates'; Name = 'SignatureUpdateInterval'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'RemoveDefender'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender'; Name = 'PUAProtection'; Type = 'REG_DWORD'; Data = '0' }
    )
}

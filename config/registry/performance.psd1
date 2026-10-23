# config\registry\performance.psd1 - Performance, power and latency
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
        # --- DisablePowerThrottling --------------------------------------
        @{ Tweak = 'DisablePowerThrottling'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableIdleMaintenance --------------------------------------
        @{ Tweak = 'DisableIdleMaintenance'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; Name = 'MaintenanceDisabled'; Type = 'REG_DWORD'; Data = '1' }

        # --- NtfsDisable8dot3 --------------------------------------------
        @{ Tweak = 'NtfsDisable8dot3'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\FileSystem'; Name = 'NtfsDisable8dot3NameCreation'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'NtfsDisable8dot3'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\FileSystem'; Name = 'NtfsDisableLastAccessUpdate'; Type = 'REG_DWORD'; Data = '1' }

        # --- EnableLongPaths ---------------------------------------------
        @{ Tweak = 'EnableLongPaths'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\FileSystem'; Name = 'LongPathsEnabled'; Type = 'REG_DWORD'; Data = '1' }

        # --- NetworkTuning -----------------------------------------------
        @{ Tweak = 'NetworkTuning'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\Tcpip\Parameters'; Name = 'TcpTimedWaitDelay'; Type = 'REG_DWORD'; Data = '30' }
        @{ Tweak = 'NetworkTuning'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\Tcpip\Parameters'; Name = 'MaxUserPort'; Type = 'REG_DWORD'; Data = '65534' }
        @{ Tweak = 'NetworkTuning'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\Tcpip\Parameters'; Name = 'DefaultTTL'; Type = 'REG_DWORD'; Data = '64' }
        @{ Tweak = 'NetworkTuning'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Services\Tcpip\Parameters'; Name = 'EnableICMPRedirect'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'NetworkTuning'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows NT\DNSClient'; Name = 'EnableMulticast'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'NetworkTuning'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows NT\DNSClient'; Name = 'DisableSmartNameResolution'; Type = 'REG_DWORD'; Data = '1' }

        # --- LowLatencyAudioMMCSS ----------------------------------------
        @{ Tweak = 'LowLatencyAudioMMCSS'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio'; Name = 'Priority'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'LowLatencyAudioMMCSS'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio'; Name = 'Scheduling Category'; Type = 'REG_SZ'; Data = 'High' }
        @{ Tweak = 'LowLatencyAudioMMCSS'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio'; Name = 'SFIO Priority'; Type = 'REG_SZ'; Data = 'High' }
        @{ Tweak = 'LowLatencyAudioMMCSS'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio'; Name = 'Background Only'; Type = 'REG_SZ'; Data = 'False' }
        @{ Tweak = 'LowLatencyAudioMMCSS'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio'; Name = 'Clock Rate'; Type = 'REG_DWORD'; Data = '10000' }
        @{ Tweak = 'LowLatencyAudioMMCSS'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio'; Name = 'GPU Priority'; Type = 'REG_DWORD'; Data = '8' }

        # --- MMCSSGaming -------------------------------------------------
        @{ Tweak = 'MMCSSGaming'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Priority'; Type = 'REG_DWORD'; Data = '6' }
        @{ Tweak = 'MMCSSGaming'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Scheduling Category'; Type = 'REG_SZ'; Data = 'High' }
        @{ Tweak = 'MMCSSGaming'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'SFIO Priority'; Type = 'REG_SZ'; Data = 'High' }
        @{ Tweak = 'MMCSSGaming'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'GPU Priority'; Type = 'REG_DWORD'; Data = '8' }
        @{ Tweak = 'MMCSSGaming'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Affinity'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'MMCSSGaming'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Background Only'; Type = 'REG_SZ'; Data = 'False' }
        @{ Tweak = 'MMCSSGaming'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Clock Rate'; Type = 'REG_DWORD'; Data = '10000' }

        # --- SvcHostConsolidation ----------------------------------------
        @{ Tweak = 'SvcHostConsolidation'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control'; Name = 'SvcHostSplitThresholdInKB'; Type = 'REG_DWORD'; Data = '67108864' }
        @{ Tweak = 'SvcHostConsolidation'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Memory Management'; Name = 'DisablePageCombining'; Type = 'REG_DWORD'; Data = '0' }

        # --- NoKernelPaging ----------------------------------------------
        @{ Tweak = 'NoKernelPaging'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Memory Management'; Name = 'DisablePagingExecutive'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableCPUMitigations ---------------------------------------
        @{ Tweak = 'DisableCPUMitigations'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Memory Management'; Name = 'FeatureSettingsOverride'; Type = 'REG_DWORD'; Data = '3' }
        @{ Tweak = 'DisableCPUMitigations'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Memory Management'; Name = 'FeatureSettingsOverrideMask'; Type = 'REG_DWORD'; Data = '3' }

        # --- DisableFSE --------------------------------------------------
        @{ Tweak = 'DisableFSE'; Default = $false; Hive = 'zNTUSER'; Path = 'System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableFSE'; Default = $false; Hive = 'zNTUSER'; Path = 'System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableFSE'; Default = $false; Hive = 'zDEFAULT'; Path = 'System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableFSE'; Default = $false; Hive = 'zDEFAULT'; Path = 'System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode'; Type = 'REG_DWORD'; Data = '1' }

        # --- EnableHAGS --------------------------------------------------
        @{ Tweak = 'EnableHAGS'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\GraphicsDrivers'; Name = 'HwSchMode'; Type = 'REG_DWORD'; Data = '2' }

        # --- DisableSuperfetch -------------------------------------------
        @{ Tweak = 'DisableSuperfetch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\EMDMgmt'; Name = 'GroupPolicyDisallowCaches'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableSuperfetch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\EMDMgmt'; Name = 'AllowNewCachesByDefault'; Type = 'REG_DWORD'; Data = '0' }

        # --- TuneMemoryAndPaging -----------------------------------------
        @{ Tweak = 'TuneMemoryAndPaging'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Memory Management'; Name = 'ClearPageFileAtShutdown'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'TuneMemoryAndPaging'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Memory Management'; Name = 'LargeSystemCache'; Type = 'REG_DWORD'; Data = '0' }

        # --- GamingNetworkTweaks -----------------------------------------
        # Per-adapter TcpAckFrequency needs interface GUIDs that only exist online; these are the offline-safe parts
        @{ Tweak = 'GamingNetworkTweaks'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Type = 'REG_DWORD'; Data = '0xffffffff' }
        @{ Tweak = 'GamingNetworkTweaks'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\MSMQ\Parameters'; Name = 'TCPNoDelay'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableGameDVR ----------------------------------------------
        @{ Tweak = 'DisableGameDVR'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableGameDVR'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'System\GameConfigStore'; Name = 'GameDVR_Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableGameDVR'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableFastStartup ------------------------------------------
        @{ Tweak = 'DisableFastStartup'; Default = $false; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Type = 'REG_DWORD'; Data = '0' }

        # --- OptimizeVisualEffects ---------------------------------------
        # "Adjust for best performance" is more than VisualFXSetting=2: Windows reads the
        # per-user UserPreferencesMask and the individual animation values. The old block
        # wrote only three values, so window/menu/taskbar animations stayed enabled.
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Type = 'REG_SZ'; Data = '0' }
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Control Panel\Desktop'; Name = 'DragFullWindows'; Type = 'REG_SZ'; Data = '0' }
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Control Panel\Desktop'; Name = 'UserPreferencesMask'; Type = 'REG_BINARY'; Data = '9012038010000000' }
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewAlphaSelect'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewShadow'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Type = 'REG_DWORD'; Data = '0' }
        # The accessibility animation switch is the setting the shell honours even when
        # a theme or an app re-enables the explorer animations.
        @{ Tweak = 'OptimizeVisualEffects'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Control Panel\Accessibility\Animation'; Name = 'Flags'; Type = 'REG_SZ'; Data = '0' }

    )
}

# config\registry\privacy.psd1 - Diagnostics, telemetry and privacy policies
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
        # --- DisableTelemetryAndDiagnostics ------------------------------
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Input\TIPC'; Name = 'Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\DataCollection'; Name = 'MaxTelemetryAllowed'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\SQMClient\Windows'; Name = 'CEIPEnable'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Device Metadata'; Name = 'PreventDeviceMetadataFromNetwork'; Type = 'REG_DWORD'; Data = '1' }
        # WinUtil 26.10.07 (WPFTweaksTelemetry): contact harvesting, the inking/typing privacy
        # consent, app launch tracking and the PowerShell 7 telemetry opt-out.
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_TrackProgs'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Environment'; Name = 'POWERSHELL_TELEMETRY_OPTOUT'; Type = 'REG_SZ'; Data = '1' }
        # Debloat-Win11 v2.3.8 (Edge.ps1): Edge diagnostic data and personalization reporting.
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'DiagnosticData'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'PersonalizationReportingEnabled'; Type = 'REG_DWORD'; Data = '0' }
        # Bloatynosy 1.01.103: tailored experiences (user policy), online speech recognition and
        # Narrator's online services.
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\InputPersonalization'; Name = 'AllowInputPersonalization'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Narrator\NoRoam'; Name = 'OnlineServicesEnabled'; Type = 'REG_DWORD'; Data = '0' }
        # Revision Tool 2.14.1: the Sleep Study power diagnostics recorder.
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSYSTEM'; Path = 'ControlSet001\Control\Session Manager\Power'; Name = 'SleepStudyDisabled'; Type = 'REG_DWORD'; Data = '1' }
        # hellzerg/optimizer (master, after 16.7): Edge's 3P service telemetry.
        @{ Tweak = 'DisableTelemetryAndDiagnostics'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'Edge3PSerpTelemetryEnabled'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableErrorReporting ---------------------------------------
        @{ Tweak = 'DisableErrorReporting'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableErrorReporting'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'DontSendAdditionalData'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableActivityHistory --------------------------------------
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Backup'; Name = 'DisableCloudBackup'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\SettingSync'; Name = 'DisableBackupRestore'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSync'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSyncUserOverride'; Type = 'REG_DWORD'; Data = '1' }
        # Debloat-Win11 v2.3.8: the Windows Backup UI and its monitoring.
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsBackup'; Name = 'DisableBackupUI'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableActivityHistory'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\WindowsBackup'; Name = 'DisableMonitoring'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableIMETelemetry -----------------------------------------
        @{ Tweak = 'DisableIMETelemetry'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\IME\15.0\IMEJP\MSIME'; Name = 'CloudCandidate'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableIMETelemetry'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\IME\15.0\IMEJP\MSIME'; Name = 'SendFeedback'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableIMETelemetry'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\IME\15.0\IMEJP\MSIME'; Name = 'CloudCandidate'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableIMETelemetry'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\IME\15.0\IMEJP\MSIME'; Name = 'SendFeedback'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableAdvertisingId ----------------------------------------
        @{ Tweak = 'DisableAdvertisingId'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableAdvertisingId'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableAppPrivacy -------------------------------------------
        @{ Tweak = 'DisableAppPrivacy'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessLocation'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableAppPrivacy'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessMicrophone'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableAppPrivacy'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessContacts'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableAppPrivacy'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessCalendar'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableAppPrivacy'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessCallHistory'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableAppPrivacy'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessMessaging'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableAppPrivacy'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessAccountInfo'; Type = 'REG_DWORD'; Data = '2' }

        # --- DisableDefenderSecurityCenter -------------------------------
        @{ Tweak = 'DisableDefenderSecurityCenter'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender Security Center\Notifications'; Name = 'DisableEnhancedNotifications'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableDefenderSecurityCenter'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender Security Center\Systray'; Name = 'HideSystray'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableCortana ----------------------------------------------
        @{ Tweak = 'DisableCortana'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortana'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCortana'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortanaAboveLock'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableTimeline ---------------------------------------------
        @{ Tweak = 'DisableTimeline'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableDiagnosticData ---------------------------------------
        @{ Tweak = 'DisableDiagnosticData'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableDiagnosticData'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDiagnosticLogCollection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableDiagnosticData'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDumpCollection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableDiagnosticData'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\DataCollection'; Name = 'DisableDiagnosticDataViewer'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableDiagnosticData'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Type = 'REG_DWORD'; Data = '0' }
        # ReviOS 26.10 (registry/security/security.yml): never send a sample to
        # Microsoft. The old WinEase value 0 means "always prompt", which is the
        # opposite of a debloat image.
        @{ Tweak = 'DisableDiagnosticData'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows Defender\Spynet'; Name = 'SubmitSamplesConsent'; Type = 'REG_DWORD'; Data = '2' }
        # ReviOS 26.10 (registry/updates/updates.yml): the Malicious Software
        # Removal Tool must not report infections.
        @{ Tweak = 'DisableDiagnosticData'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\MRT'; Name = 'DontReportInfectionInformation'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableBackgroundApps ---------------------------------------
        @{ Tweak = 'DisableBackgroundApps'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsRunInBackground'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableBackgroundApps'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name = 'GlobalUserDisabled'; Type = 'REG_DWORD'; Data = '1' }
    )
}

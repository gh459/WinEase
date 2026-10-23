# config\registry\cloud-content.psd1 - Sponsored apps, suggestions and cloud content (DisableCloudContent)
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
        # --- DisableCloudContent -----------------------------------------
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'FeatureManagementEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEverEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContentEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338387Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353698Enabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingImageOverlayEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableConsumerAccountStateContent'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightFeatures'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableAccountBasedInSettings'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\PushToInstall'; Name = 'DisablePushToInstall'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\MRT'; Name = 'DontOfferThroughWUAU'; Type = 'REG_DWORD'; Data = '1' }
        # WinUtil 26.10.07 (WPFTweaksEdgeDebloat): Edge's "make Edge your default browser" campaign.
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'DefaultBrowserSettingsCampaignEnabled'; Type = 'REG_DWORD'; Data = '0' }
        # Win11Debloat 2026.08.24 (Disable_Edge_Ads_And_Suggestions, Disable_Windows_Suggestions):
        # Edge recommendations, spotlight, feedback, Acrobat and wallet promotions, and the
        # "back up your PC" reminder toast.
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'DefaultBrowserSettingEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'ShowRecommendationsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'SpotlightExperiencesAndRecommendationsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'UserFeedbackAllowed'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'ShowAcrobatSubscriptionButton'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'WalletDonationEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder'; Name = 'Enabled'; Type = 'REG_DWORD'; Data = '0' }
        # Debloat-Win11 v2.3.8: the "finish setting up your device" (SCOOBE) page and the
        # Microsoft account notifications of Start and Settings.
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications'; Name = 'EnableAccountNotifications'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightOnDesktop'; Type = 'REG_DWORD'; Data = '1' }
        # Bloatynosy 1.01.103: lock screen ads and Spotlight, Edge shopping, startup boost and first run.
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'EdgeShoppingAssistantEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'StartupBoostEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'HideFirstRunExperience'; Type = 'REG_DWORD'; Data = '1' }
        # ReviOS 26.10 (registry/updates/updates.yml): the Media Player must not pull
        # its own updates in the background.
        @{ Tweak = 'DisableCloudContent'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\WindowsMediaPlayer'; Name = 'DisableAutoUpdate'; Type = 'REG_DWORD'; Data = '1' }

    )
}

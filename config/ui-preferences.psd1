# The per-user UI preferences of phase 10 (config\ui-preferences.psd1).
#
# Every entry is one registry value that is written to the two per-user hives
# (zNTUSER and zDEFAULT) of the mounted image.
#
# The table is data and not a nested array literal in the phase script on
# purpose. PowerShell's @() operator unwraps a group that holds a single entry,
# so a group with one entry arrived at the phase as four separate strings: the
# four fields of the entry were then read one by one, and reg.exe was called
# with an empty value name, an empty type and an empty data. An empty argument
# is dropped by a native call, so reg.exe read the '/f' switch as the data and
# wrote a key named after the first character of the data, holding a value
# named '/t'. The next build found that value, reg.exe asked
# "Overwrite (Yes/No)?" and waited for a key press - the build hung there and
# no ISO was produced.
#
# A hashtable cannot be unwrapped that way, so every entry keeps its fields.
#
# Entry fields:
#   Tweak = the key of the tweak in config\schema.psd1 that switches the entry on
#   Path  = the key path below the hive
#   Name  = the name of the value
#   Type  = REG_DWORD or REG_SZ
#   Data  = the data of the value
@{
    Version = '1.0'

    UiPreferences = @(
        @{ Tweak = 'DisableSnapAssist'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SnapAssist'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableSnapAssist'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'EnableSnapAssistFlyout'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableSnapAssist'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'EnableSnapBar'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableNotificationBanners'; Path = 'Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableNotificationBanners'; Path = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideExplorerHomeGallery'; Path = 'Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'; Name = 'System.IsPinnedToNameSpaceTree'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideExplorerHomeGallery'; Path = 'Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'; Name = 'System.IsPinnedToNameSpaceTree'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideExplorerHomeGallery'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowHome'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideExplorerHomeGallery'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowGallery'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideAltTabEdgeTabs'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'MultiTaskingAltTabFilter'; Type = 'REG_DWORD'; Data = '3' }
        @{ Tweak = 'HideTaskViewButton'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'TaskbarNeverCombine'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarGlomLevel'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'TaskbarNeverCombine'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'MMTaskbarGlomLevel'; Type = 'REG_DWORD'; Data = '2' }
        @{ Tweak = 'DisableGameMode'; Path = 'Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableGameMode'; Path = 'Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'ShowBatteryPercentage'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'IsBatteryPercentageEnabled'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'AlwaysShowScrollbars'; Path = 'Control Panel\Accessibility'; Name = 'DynamicScrollbars'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideOneDriveNavPane'; Path = 'Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'; Name = 'System.IsPinnedToNameSpaceTree'; Type = 'REG_DWORD'; Data = '0' }
        # AtlasOS main (AtlasModules/Scripts/Modules/Qol/Qol.psm1) and WinUtil main
        # (config/tweaks.json): the accessibility hotkeys and the pointer / keyboard
        # settings have to be REG_SZ, a REG_DWORD value is ignored by Windows.
        # The Flags values clear only the "hotkey active" bit (0x4) while keeping the
        # feature available: 506/122/58/58 are what Windows writes when the keyboard
        # shortcut is switched off in Settings. A value of 0 removed the whole feature.
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Type = 'REG_SZ'; Data = '506' }
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Control Panel\Accessibility\FilterKeys'; Name = 'Flags'; Type = 'REG_SZ'; Data = '122' }
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Control Panel\Accessibility\ToggleKeys'; Name = 'Flags'; Type = 'REG_SZ'; Data = '58' }
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Control Panel\Accessibility\MouseKeys'; Name = 'Flags'; Type = 'REG_SZ'; Data = '58' }
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Control Panel\Accessibility\Keyboard Response'; Name = 'Flags'; Type = 'REG_SZ'; Data = '122' }
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Keyboard Layout\Toggle'; Name = 'Hotkey'; Type = 'REG_SZ'; Data = '3' }
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Keyboard Layout\Toggle'; Name = 'Language Hotkey'; Type = 'REG_SZ'; Data = '3' }
        @{ Tweak = 'DisableAccessibilityHotkeys'; Path = 'Keyboard Layout\Toggle'; Name = 'Layout Hotkey'; Type = 'REG_SZ'; Data = '3' }
        # 0/0/0 disables pointer acceleration. The previous 1/6/10 pair is the
        # Windows default and therefore enabled it (the checkbox did nothing).
        @{ Tweak = 'DisableMouseAcceleration'; Path = 'Control Panel\Mouse'; Name = 'MouseSpeed'; Type = 'REG_SZ'; Data = '0' }
        @{ Tweak = 'DisableMouseAcceleration'; Path = 'Control Panel\Mouse'; Name = 'MouseThreshold1'; Type = 'REG_SZ'; Data = '0' }
        @{ Tweak = 'DisableMouseAcceleration'; Path = 'Control Panel\Mouse'; Name = 'MouseThreshold2'; Type = 'REG_SZ'; Data = '0' }
        @{ Tweak = 'DisableKeyboardDelay'; Path = 'Control Panel\Keyboard'; Name = 'KeyboardDelay'; Type = 'REG_SZ'; Data = '0' }
    )
}

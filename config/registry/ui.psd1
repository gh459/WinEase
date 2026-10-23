# config\registry\ui.psd1 - UI and ergonomics
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
        # --- EnableClassicContextMenu ------------------------------------
        @{ Tweak = 'EnableClassicContextMenu'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name = ''; Type = 'REG_SZ'; Data = '' }

        # --- EnableDarkTheme ---------------------------------------------
        @{ Tweak = 'EnableDarkTheme'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'EnableDarkTheme'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'EnableDarkTheme'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'EnableDarkTheme'; Default = $true; Hive = 'zNTUSER'; Path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Type = 'REG_DWORD'; Data = '0' }

        # --- ShowFileExtensions ------------------------------------------
        @{ Tweak = 'ShowFileExtensions'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Type = 'REG_DWORD'; Data = '0' }

        # --- ShowHiddenFiles ---------------------------------------------
        @{ Tweak = 'ShowHiddenFiles'; Default = $false; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Hidden'; Type = 'REG_DWORD'; Data = '1' }

        # --- LaunchToThisPC ----------------------------------------------
        @{ Tweak = 'LaunchToThisPC'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Type = 'REG_DWORD'; Data = '1' }

        # --- TaskbarEndTask ----------------------------------------------
        @{ Tweak = 'TaskbarEndTask'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableLogonBlur --------------------------------------------
        @{ Tweak = 'DisableLogonBlur'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\System'; Name = 'DisableAcrylicBackgroundOnLogon'; Type = 'REG_DWORD'; Data = '1' }

        # --- TaskbarAlignLeft --------------------------------------------
        @{ Tweak = 'TaskbarAlignLeft'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl'; Type = 'REG_DWORD'; Data = '0' }

        # --- HideMeetNow -------------------------------------------------
        @{ Tweak = 'HideMeetNow'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAMeetNow'; Type = 'REG_DWORD'; Data = '1' }

        # --- HideSyncNotifications ---------------------------------------
        @{ Tweak = 'HideSyncNotifications'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSyncProviderNotifications'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableStartupSound -----------------------------------------
        @{ Tweak = 'DisableStartupSound'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation'; Name = 'DisableStartupSound'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableLockScreen -------------------------------------------
        @{ Tweak = 'DisableLockScreen'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Personalization'; Name = 'NoLockScreen'; Type = 'REG_DWORD'; Data = '1' }

        # --- DisableSleepOption ------------------------------------------
        @{ Tweak = 'DisableSleepOption'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'; Name = 'ShowSleepOption'; Type = 'REG_DWORD'; Data = '0' }

        # --- MenuShowDelayZero -------------------------------------------
        @{ Tweak = 'MenuShowDelayZero'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Control Panel\Desktop'; Name = 'MenuShowDelay'; Type = 'REG_SZ'; Data = '0' }

        # --- TransparentShortcutOverlay ----------------------------------
        # Resource -50 in shell32.dll is the transparent icon; the previous value
        # pointed at a visible icon, so it replaced the arrow with a glyph instead
        # of removing it.
        @{ Tweak = 'TransparentShortcutOverlay'; Default = $false; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'; Name = '29'; Type = 'REG_EXPAND_SZ'; Data = '%SystemRoot%\System32\shell32.dll,-50' }

        # --- CleanContextMenus -------------------------------------------
        # Share, Give access to, Cast to Device
        # An empty Data is the empty string: the extension is blocked by an empty value.
        @{ Tweak = 'CleanContextMenus'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{e2bf9676-5f8f-435c-97eb-11607a5bedf7}'; Type = 'REG_SZ'; Data = '' }
        @{ Tweak = 'CleanContextMenus'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}'; Type = 'REG_SZ'; Data = '' }
        @{ Tweak = 'CleanContextMenus'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{7AD84985-87B4-4a16-BE58-8B72A5B390F7}'; Type = 'REG_SZ'; Data = '' }
    )
}

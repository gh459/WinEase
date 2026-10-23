# config\registry\start-search.psd1 - Start menu, web search and widgets
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
        # --- DisableWebSearch --------------------------------------------
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'EnableDynamicContentInWSB'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCloudSearch'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'AllowSearchToUseLocation'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortana'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'REG_DWORD'; Data = '1' }
        # Win11Debloat 2026.08.24 (Disable_Search_Highlights, Disable_Search_History).
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDynamicSearchBoxEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDeviceSearchHistoryEnabled'; Type = 'REG_DWORD'; Data = '0' }
        # ReviOS 26.10 / main (registry/explorer/search.yml): the web and the
        # Microsoft Store results that the Search box offers (26H2).
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsWebSuggestionsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsStoreSuggestionsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        # ReviOS 26.10 (registry/explorer/search.yml): the activatable class of the
        # Store search task is disabled outright (25H2 and newer).
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask'; Name = 'ActivationType'; Type = 'REG_DWORD'; Data = '4294967295' }
        # Empty Data = the empty string (the runner passes it to reg.exe as the literal "").
        @{ Tweak = 'DisableWebSearch'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask'; Name = 'Server'; Type = 'REG_SZ'; Data = '' }

        # --- HideSearchBox -----------------------------------------------
        @{ Tweak = 'HideSearchBox'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Type = 'REG_DWORD'; Data = '0' }

        # --- DisableWidgets ----------------------------------------------
        @{ Tweak = 'DisableWidgets'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWidgets'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Widgets'; Name = 'AllowWidgets'; Type = 'REG_DWORD'; Data = '0' }
        # Bloatynosy 1.01.103: the "News and interests" feeds policy.
        @{ Tweak = 'DisableWidgets'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWidgets'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Type = 'REG_DWORD'; Data = '0' }

        # --- HideRecommendedSection --------------------------------------
        # The Explorer policy alone is only honoured on Education/Enterprise editions.
        # The PolicyManager bridge is the documented workaround that makes the same
        # policy remove the section on Pro as well (WinUtil / elevenforum).
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\PolicyManager\current\device\Start'; Name = 'HideRecommendedSection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\PolicyManager\current\device\Education'; Name = 'IsEducationEnvironment'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations'; Type = 'REG_DWORD'; Data = '0' }
        # Sophia Script 8.0.0 (RecentlyAddedStartApps, MostUsedStartApps, StartRecommendedSection):
        # the recent / most used lists of the new Start menu and recent documents tracking.
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Start'; Name = 'ShowRecentList'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Start'; Name = 'ShowFrequentList'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'HideRecommendedSection'; Default = $true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_TrackDocs'; Type = 'REG_DWORD'; Data = '0' }
    )
}

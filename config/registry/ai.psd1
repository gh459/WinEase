# config\registry\ai.psd1 - Windows AI, Recall, Click to Do and Copilot
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
        # --- DisableWindowsAI --------------------------------------------
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallToBeEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'TurnOffRecall'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'TurnOffRecall'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'TurnOffSavingSnapshots'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'TurnOffSavingSnapshots'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableSettingsAgent'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowCopilotRuntime'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\Notepad'; Name = 'EnableAIFeatures'; Type = 'REG_DWORD'; Data = '0' }
        # WinUtil 26.10.07 (WPFTweaksWindowsAI): the machine policy for Notepad's AI features
        # and the "AI components" page of the Settings app.
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'SettingsPageVisibility'; Type = 'REG_SZ'; Data = 'hide:aicomponents' }
        # Debloat-Win11 v2.3.8 (WindowsAiPolicies.psd1, SystemTweaks_Privacy): Recall export and
        # data providers, Paint's image generation, and the AI actions of the clipboard.
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = 'zDEFAULT'; Path = 'Software\Microsoft\Paint'; Name = 'EnableCocreator'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableWindowsAI'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'RecallPin'; Type = 'REG_DWORD'; Data = '0' }
        # ReviOS 26.10 (meetrevision/packages, ai-removal-amd64.yaml): force-deny the
        # "Let Windows apps make use of text and image generation" capabilities.

        # --- DisableCopilot ----------------------------------------------
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Type = 'REG_DWORD'; Data = '1' }
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCopilotButton'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = @('zDEFAULT', 'zNTUSER'); Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'CopilotPWAPin'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'CopilotPageContext'; Type = 'REG_DWORD'; Data = '0' }
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Edge'; Name = 'ShowCopilotButton'; Type = 'REG_DWORD'; Data = '0' }
        # Debloat-Win11 v2.3.8: Copilot's page context in Edge and the policy that removes the
        # Microsoft Copilot app.
        # Bloatynosy 1.01.103 (WinRules.ini, "Disable Edge AI Features").
        @{ Tweak = 'DisableCopilot'; Default = $true; Hive = 'zSOFTWARE'; Path = 'Policies\Microsoft\Teams'; Name = 'DisableInstallation'; Type = 'REG_DWORD'; Data = '1' }
        # Debloat-Win11 main (Modules/PolicyCatalog.psd1): the per-user flag that
        # hides the Copilot entry in the shell.
    )
}

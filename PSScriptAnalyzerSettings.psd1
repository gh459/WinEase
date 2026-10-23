# PSScriptAnalyzer settings for WinEase.
# Usage: Invoke-ScriptAnalyzer -Path <file> -Settings .\PSScriptAnalyzerSettings.psd1
# The Pester suite (tests\*.Tests.ps1) runs the analyzer with this file and expects zero Error/Warning findings.
@{
    ExcludeRules = @(
        # WinEase is an interactive console tool: coloured Write-Host output is the UI, not pipeline data.
        'PSAvoidUsingWriteHost',

        # UserPassword parameter specifies default/custom local account password for unattended installation.
        'PSAvoidUsingPlainTextForPassword',

        # New-/Set-/Remove-/Update- functions are internal helpers called by the build itself
        # (GUI control factories, path builders, cleanup routines). The builder exposes its own
        # -WhatIf via [CmdletBinding(SupportsShouldProcess)] on the script; per-helper
        # ShouldProcess plumbing would add noise without giving users anything.
        'PSUseShouldProcessForStateChangingFunctions',

        # Function names are referenced across the builder, phases, GUI and tests
        # (e.g. Apply-ProfileSettings, Load-WinEaseCheckpoint, Redact-WinEaseSecret,
        # Clear-DismMountConflicts). Renaming them for approved verbs / singular nouns would be a
        # breaking churn for no behavioural gain, so the names are kept.
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',

        # WinEasebuilder.ps1 is saved as UTF-8 without BOM and contains emoji in console strings.
        # Adding a BOM changes how Windows PowerShell 5.1 decodes those strings, i.e. it would
        # change the console output, so the encoding is left as is.
        'PSUseBOMForUnicodeEncodedFile',

        # GUI uses Start-Job with $using: scope (or -ArgumentList) for background backup/restore.
        # The rule's static analysis cannot follow $using: in nested event-handler scopes.
        'PSUseUsingScopeModifierInNewRunspaces'
    )
}

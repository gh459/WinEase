# PSScriptAnalyzer settings for nano11.
# Usage: Invoke-ScriptAnalyzer -Path <file> -Settings .\PSScriptAnalyzerSettings.psd1
# tests\nano11.Tests.ps1 runs the analyzer with this file and expects zero Error/Warning findings.
@{
    ExcludeRules = @(
        # nano11 is an interactive console tool: coloured Write-Host output is the UI, not pipeline data.
        'PSAvoidUsingWriteHost',

        # New-/Set-/Remove-/Update- functions are internal helpers called by the build itself
        # (GUI control factories, path builders, cleanup routines). The builder exposes its own
        # -WhatIf via [CmdletBinding(SupportsShouldProcess)] on the script; per-helper
        # ShouldProcess plumbing would add noise without giving users anything.
        'PSUseShouldProcessForStateChangingFunctions',

        # Function names are referenced across the builder, phases, GUI and tests
        # (e.g. Apply-ProfileSettings, Load-Nano11Checkpoint, Redact-Nano11Secret,
        # Clear-DismMountConflicts). Renaming them for approved verbs / singular nouns would be a
        # breaking churn for no behavioural gain, so the names are kept.
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',

        # nano11builder.ps1 is saved as UTF-8 without BOM and contains emoji in console strings.
        # Adding a BOM changes how Windows PowerShell 5.1 decodes those strings, i.e. it would
        # change the console output, so the encoding is left as is.
        'PSUseBOMForUnicodeEncodedFile'
    )
}

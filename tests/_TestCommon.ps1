# Shared setup for the split WinEase Pester suite (Pester 3.4 / Windows PowerShell 5.1).
# Dot-sourced by every *.Tests.ps1 in this directory. Not a test file, so Pester 3.4
# discovers it only if it is renamed to *.Tests.ps1 - do not rename it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Shared variables are consumed by the test files that dot-source this file')]
param()

$script:RepoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Get-Location | Select-Object -ExpandProperty Path }
$script:BuilderPath = Join-Path -Path $script:RepoRoot -ChildPath "WinEasebuilder.ps1"
$script:GuiPath = Join-Path -Path $script:RepoRoot -ChildPath "gui\WinEaseGui.ps1"
$script:GuiCorePath = Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseGuiCore.ps1"
$script:GuiSessionPath = Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseGuiSession.ps1"

# The helper implementation is split into function-only modules. Keep this list in
# sync with the loader in WinEasehelpers.ps1; tests that inspect "the helper source"
# must read the loader plus every module, not just the loader.
$script:HelperSourceFiles = @(
    "WinEasehelpers.ps1"
    "lib\WinEasePathSafety.ps1"
    "lib\WinEaseSystem.ps1"
    "lib\WinEaseFileSystem.ps1"
    "lib\WinEaseConfig.ps1"
    "lib\WinEaseBenchmarks.ps1"
    "lib\WinEaseDependencies.ps1"
)

function Get-WinEaseHelperSourceText {
    $parts = foreach ($relative in $script:HelperSourceFiles) {
        $path = Join-Path -Path $script:RepoRoot -ChildPath $relative
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing helper source: $relative" }
        [System.IO.File]::ReadAllText($path)
    }
    return ($parts -join "`n")
}

function Get-WinEaseHelperAst {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        (Get-WinEaseHelperSourceText), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    return $ast
}
$script:UnattendPath = Join-Path -Path $script:RepoRoot -ChildPath "autounattend.xml"
# The GUI tests assume English (they match button texts like "Select All"); the
# display-language tests in Gui.Tests.ps1 set and restore their own values.
$env:WINEASE_UI_LANGUAGE = 'en'

function Get-WinEaseBuiltinPluginSourceText {
    # The C# sources of the official built-in plugins (src\WinEase.Plugins.Builtin.*) as one text.
    $parts = Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'src') -Directory -Filter 'WinEase.Plugins.Builtin.*' |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.cs' -File } |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }
    return ($parts -join "`n")
}

function Get-WinEaseUpstreamSyncRegistryEntries {
    # The registry values of the built-in UpstreamSync plugin (one hashtable per hive), read from its source.
    $path = Join-Path -Path $script:RepoRoot -ChildPath 'src\WinEase.Plugins.Builtin.UpstreamSync\UpstreamSyncPlugin.cs'
    $text = [System.IO.File]::ReadAllText($path)
    $pattern = 'Add\(list, "([^"]*)", (true|false), "([^"]*)", @"((?:[^"]|"")*)", @"((?:[^"]|"")*)", "([^"]*)", @"((?:[^"]|"")*)"\);'
    foreach ($m in [regex]::Matches($text, $pattern)) {
        @{
            Tweak = $m.Groups[1].Value; Default = ($m.Groups[2].Value -eq 'true'); Hive = $m.Groups[3].Value
            Path = $m.Groups[4].Value.Replace('""', '"'); Name = $m.Groups[5].Value.Replace('""', '"')
            Type = $m.Groups[6].Value; Data = $m.Groups[7].Value.Replace('""', '"')
        }
    }
}

function Get-WinEaseRegistryTableText {
    # The config\registry tables of phase 10 as one text: the plain registry writes that
    # moved out of phases\10-registry.ps1. Tests that look for a registry value read the
    # phase text plus this one. The values of the built-in UpstreamSync plugin follow in the
    # same notation, so a test that asks "is this value written" does not care whether a
    # table or the plugin holds it.
    $dir = Join-Path -Path $script:RepoRoot -ChildPath 'config\registry'
    $parts = @(Get-ChildItem -LiteralPath $dir -Filter '*.psd1' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
    $parts += (@(Get-WinEaseUpstreamSyncRegistryEntries | ForEach-Object {
                "@{ Tweak = '$($_.Tweak)'; Default = `$$($_.Default.ToString().ToLower()); Hive = '$($_.Hive)'; Path = '$($_.Path)'; Name = '$($_.Name)'; Type = '$($_.Type)'; Data = '$($_.Data)' }"
            }) -join "`n")
    return ($parts -join "`n")
}

# Modal dialogs must never open during the automated GUI tests: a real MessageBox blocks the run on
# any interactive desktop (CI has none, so it hid the problem there). Dot-source this scriptblock right
# after `. $script:GuiPath`; it replaces the two modal helpers with recording stubs:
#   . ([scriptblock]::Create($script:GuiNoModalStubs))
# Show-WinEaseGuiMessage appends { Text; Title; Kind } to $script:GuiTestMessages and answers yes;
# Confirm-WinEaseGuiAction records the question and returns $script:GuiTestConfirmAnswer (default $true).
$script:GuiNoModalStubs = @'
if (-not (Test-Path variable:script:GuiTestMessages)) { $script:GuiTestMessages = New-Object System.Collections.Generic.List[object] }
if (-not (Test-Path variable:script:GuiTestConfirmAnswer)) { $script:GuiTestConfirmAnswer = $true }
function Show-WinEaseGuiMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param([string]$Text, [string]$Title, [string]$Kind = 'Info', [switch]$YesNo)
    $script:GuiTestMessages.Add([pscustomobject]@{ Text = $Text; Title = $Title; Kind = $Kind })
    return $true
}
function Confirm-WinEaseGuiAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param([string]$Message, [string]$Title)
    $script:GuiTestMessages.Add([pscustomobject]@{ Text = $Message; Title = $Title; Kind = 'Confirm' })
    return [bool]$script:GuiTestConfirmAnswer
}
'@

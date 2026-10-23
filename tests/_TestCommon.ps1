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

function Get-WinEaseRegistryTableText {
    # The config\registry tables of phase 10 as one text: the plain registry writes that
    # moved out of phases\10-registry.ps1. Tests that look for a registry value read the
    # phase text plus this one.
    $dir = Join-Path -Path $script:RepoRoot -ChildPath 'config\registry'
    $parts = Get-ChildItem -LiteralPath $dir -Filter '*.psd1' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }
    return ($parts -join "`n")
}

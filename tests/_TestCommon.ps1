# Shared setup for the split WinEase Pester suite (Pester 3.4 / Windows PowerShell 5.1).
# Dot-sourced by every *.Tests.ps1 in this directory. Not a test file, so Pester 3.4
# discovers it only if it is renamed to *.Tests.ps1 - do not rename it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Shared variables are consumed by the test files that dot-source this file')]
param()

$script:RepoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Get-Location | Select-Object -ExpandProperty Path }
$script:BuilderPath = Join-Path -Path $script:RepoRoot -ChildPath "WinEasebuilder.ps1"
$script:GuiPath = Join-Path -Path $script:RepoRoot -ChildPath "gui\WinEaseGui.ps1"
$script:UnattendPath = Join-Path -Path $script:RepoRoot -ChildPath "autounattend.xml"
# The GUI tests assume English (they match button texts like "Select All"); the
# display-language tests in Gui.Tests.ps1 set and restore their own values.
$env:WINEASE_UI_LANGUAGE = 'en'

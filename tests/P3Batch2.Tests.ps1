# P3Batch2.Tests.ps1 - directory clearing without wildcards, oscdimg signer subject, phase wiring (audit PR-F, part 2)
# Run with:  Invoke-Pester -Path .\tests\P3Batch2.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

Describe "Clear-WinEaseDirectoryContents" {
    BeforeEach {
        if (-not (Get-Command -Name Clear-WinEaseDirectoryContents -ErrorAction SilentlyContinue)) { . (Join-Path $script:RepoRoot 'lib\WinEaseFileSystem.ps1') }
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('WinEase_clr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory((Join-Path $script:Dir 'sub')) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'a.txt'), 'x')
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'sub\b.txt'), 'x')
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It "empties the directory and keeps it" {
        (Clear-WinEaseDirectoryContents -Path $script:Dir) | Should Be 0
        Test-Path -LiteralPath $script:Dir | Should Be $true
        @(Get-ChildItem -LiteralPath $script:Dir -Force).Count | Should Be 0
    }
    It "treats a missing directory as nothing to do" {
        (Clear-WinEaseDirectoryContents -Path (Join-Path $script:Dir 'nope')) | Should Be 0
    }
    It "does not delete through a junction" {
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('WinEase_out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($outside) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'x')
        $link = Join-Path $script:Dir 'link'
        cmd /c mklink /J "$link" "$outside" | Out-Null
        if (Test-Path -LiteralPath $link) {
            (Clear-WinEaseDirectoryContents -Path $script:Dir -WarningAction SilentlyContinue) | Should Be 1
            Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should Be $true
            [System.IO.Directory]::Delete($link)
        }
        Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "oscdimg signer and phase wiring" {
    It "accepts only an exact Microsoft signer subject" {
        $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'lib\WinEaseSystem.ps1') -Raw
        $t | Should Not Match "Subject -match 'Microsoft'\)"
        $t | Should Match 'Microsoft \(Corporation\|Windows\)'
    }
    It "phase 8 clears the folders through the helper and phase 5 reports a listing failure" {
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\08-filesystem.ps1') -Raw) | Should Not Match 'Remove-Item -Path "\$scratchDir[^"]*\\*"'
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\05-appx.ps1') -Raw) | Should Match 'Could not list the provisioned apps'
    }
}

# RemainingFixes.Tests.ps1 - directory links keep their ACL, partial release package name, overwrite confirmation strings,
# escaped answer-file names, context-menu defaults (audit PR-H)
# Run with:  Invoke-Pester -Path .\tests\RemainingFixes.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

Describe "Set-ItemOwnershipAndAccess leaves directory links alone" {
    BeforeAll {
        if (-not (Get-Command -Name Set-ItemOwnershipAndAccess -ErrorAction SilentlyContinue)) { . (Join-Path $script:RepoRoot 'WinEasehelpers.ps1') }
    }
    It "does not touch the ACL of a junction or of its target" {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('WinEase_acl_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $target = Join-Path $root 'target'
        $link = Join-Path $root 'link'
        [System.IO.Directory]::CreateDirectory($target) | Out-Null
        cmd /c mklink /J "$link" "$target" | Out-Null
        if (Test-Path -LiteralPath $link) {
            Mock Get-Acl { throw 'Get-Acl must not be called for a directory link' }
            Mock Set-Acl { throw 'Set-Acl must not be called for a directory link' }
            { Set-ItemOwnershipAndAccess -Path $link } | Should Not Throw
            Assert-MockCalled Set-Acl -Times 0 -Scope It
            [System.IO.Directory]::Delete($link)
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Static wiring" {
    It "package-release builds under a .partial name and renames when complete" {
        $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tools\package-release.ps1') -Raw
        $t | Should Match '\$zipPath = "\$finalZipPath\.partial"'
        $t | Should Match 'Move-Item -LiteralPath \$zipPath -Destination \$finalZipPath -Force'
    }
    It "the migration Overwrite policy asks first, in both languages" {
        foreach ($l in 'en', 'ja') {
            $j = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\ui-strings\$l.json"), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
            [string]::IsNullOrWhiteSpace([string]$j.'Mig.Confirm.Overwrite') | Should Be $false
        }
        $cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'), [System.Text.Encoding]::UTF8)
        ([regex]::Matches($cs, 'ConfirmOverwriteAsync\(\)')).Count | Should BeGreaterThan 3
    }
    It "the answer file gets XML-escaped computer and user names" {
        $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\11-unattend.ps1') -Raw
        $t | Should Match 'SecurityElement\]::Escape\(\[string\]\$UserName\)'
        $t | Should Not Match "-replace '<ComputerName>WinEase</ComputerName>'"
    }
    It "TakeOwnership and CmdAsAdmin context menus are off by default" {
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\schema.psd1')
        foreach ($k in 'TakeOwnershipContextMenu', 'CmdAsAdminContextMenu') {
            ($schema.Tweaks | Where-Object { $_.Key -eq $k }).Default | Should Be $false
        }
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\10-registry.ps1') -Raw) | Should Match "Test-TweakEnabled 'TakeOwnershipContextMenu' \`$false"
    }
}

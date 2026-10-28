# P3Batch.Tests.ps1 - drive-relative paths are never safe to delete, plugin FoD wildcards, verify hive cleanup (audit PR-F)
# Run with:  Invoke-Pester -Path .\tests\P3Batch.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
if (-not (Get-Command -Name Test-IsSafePathToDelete -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

Describe "Test-IsSafePathToDelete refuses drive-relative paths" {
    It "refuses '<p>'" -TestCases @(@{ p = 'C:' }, @{ p = 'C:foo' }, @{ p = 'relative\dir' }, @{ p = '\rooted' }) {
        param($p)
        (Test-IsSafePathToDelete -Path $p) | Should Be $false
    }
    It "still accepts an absolute path below the temp directory" {
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ('WinEase_p3_' + [guid]::NewGuid().ToString('N'))
        (Test-IsSafePathToDelete -Path $p) | Should Be $true
    }
}

Describe "Static guards" {
    It "phase 15 unloads zVERIFYDEF in a finally block" {
        $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\15-verify.ps1') -Raw
        $t | Should Match 'finally \{\s+# unloaded even when[^\r\n]*\s+& reg\.exe unload "HKLM\\zVERIFYDEF"'
    }
    It "plugin FoD capability and feature names reject wildcards" {
        $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'lib\WinEasePlugins.ps1') -Raw
        $t | Should Match 'wildcards are not allowed'
    }
}

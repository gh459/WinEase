# CiGuards.Tests.ps1 - the CI workflow builds the plugins before Pester, limits skipped tests, and the
# conflict auto-resolver refuses changes outside the conflicted files (audit PR-E)
# Run with:  Invoke-Pester -Path .\tests\CiGuards.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

Describe "CI workflow guards" {
    BeforeAll {
        $script:Ci = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github\workflows\ci.yml'))
        $script:Auto = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github\workflows\auto-resolve-conflicts.yml'))
    }
    It "builds the built-in plugins in the Pester job before the tests run" {
        $pester = $script:Ci.Substring($script:Ci.IndexOf('  pester:'), $script:Ci.IndexOf('  dry-run:') - $script:Ci.IndexOf('  pester:'))
        $build = $pester.IndexOf('build-binaries.ps1 -Component Plugins')
        $build | Should BeGreaterThan 0
        $build | Should BeLessThan $pester.IndexOf('Invoke-Pester')
    }
    It "fails the Pester job when too many tests are skipped" {
        $script:Ci | Should Match '\$maxSkipped = \d+'
        $script:Ci | Should Match 'SkippedCount -gt \$maxSkipped'
    }
    It "refuses stray changes and .github conflicts before git add -A" {
        $i = $script:Auto.IndexOf("`n            git add -A")
        $i | Should BeGreaterThan 0
        $before = $script:Auto.Substring(0, $i)
        $before | Should Match 'git ls-files --others --exclude-standard'
        $before | Should Match "\^\\.github/"
    }
}

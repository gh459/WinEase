# Quality.Tests.ps1 - PSScriptAnalyzer and documentation checks
# Run with:  Invoke-Pester -Path .\tests\Quality.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


Describe "WinEase code quality - PSScriptAnalyzer" -Tags 'slow' {
    $analyzerAvailable = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
    if (-not $analyzerAvailable) {
        Write-Warning "PSScriptAnalyzer is not installed - skipping the analyzer test. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    }

    It "reports zero Error/Warning findings with PSScriptAnalyzerSettings.psd1" -Skip:(-not $analyzerAvailable) {
        $settingsPath = Join-Path -Path $script:RepoRoot -ChildPath "PSScriptAnalyzerSettings.psd1"
        $targets = @(
            (Join-Path $script:RepoRoot "WinEasebuilder.ps1"),
            (Join-Path $script:RepoRoot "WinEasehelpers.ps1"),
            $script:GuiPath
        ) + @(Get-ChildItem -Path (Join-Path $script:RepoRoot "phases"), (Join-Path $script:RepoRoot "lib"), (Join-Path $script:RepoRoot "scripts"), (Join-Path $script:RepoRoot "tools"), (Join-Path $script:RepoRoot "tests") -Filter "*.ps1" -File | ForEach-Object { $_.FullName })
        $findings = @(foreach ($target in $targets) {
            Invoke-ScriptAnalyzer -Path $target -Settings $settingsPath -Severity Error, Warning
        })
        ($findings | ForEach-Object { "$($_.RuleName) $(Split-Path -Leaf $_.ScriptPath):$($_.Line) $($_.Message)" }) -join "`n" | Should Be ''
    }
}

Describe "Documentation S12" {
    # Files the docs mention that are created at run/build time, or live outside the repo.
    $script:DocPathExclusions = @(
        'migration-manifest.json',      # written into the built ISO/image by the migration engine
        'restore-state.json',           # written at run time by the restore tooling
        'custom-scripts-manifest.json', # generated at build time from the custom scripts folder
        'SetupComplete.cmd',            # written into the image by phases\11-unattend.ps1 at build time
        'ErrorHandler.cmd',             # written into the image by phases\11-unattend.ps1 at build time
        'gui\winui\bin\WinEaseGui.exe', # WinUI build output (gui\winui\build.ps1); git-ignored, absent from a clean checkout
        'gui\winui\bin',                # the WinUI folder of the full release package (build output, git-ignored)
        'plugins\builtin',              # built-in plugin DLLs of the full release package (build output, git-ignored)
        'builtin.lock.psd1',            # built-in plugin lock file (build output, git-ignored)
        'implementation_plan.md'        # planning note outside the repository
    )

    function Get-MissingDocPath {
        param([string]$Text, [string]$RepoRoot, [string[]]$Files, [string[]]$Exclude = @())
        $topDirs = 'config|lib|phases|gui|tools|docs|scripts|templates|profiles|tests|\.github'
        $fileExt = 'ps1|psd1|psm1|json|md|xml|txt|cmd|bat|yml|yaml'
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($Text, '`([^`\r\n]+)`')) {
            $p = ($m.Groups[1].Value -replace '/', '\').TrimEnd('\')
            if ($p -notmatch '^[A-Za-z0-9_.\\-]+$') { continue }
            if ($Exclude -contains $p) { continue }
            if ($p -match ('^(' + $topDirs + ')(\\|$)')) {
                if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $p))) {
                    if ($Files.Where({ $_.Equals($p, [System.StringComparison]::OrdinalIgnoreCase) -or $_.StartsWith(($p + '\'), [System.StringComparison]::OrdinalIgnoreCase) }, 'First').Count -eq 0) { $null = $missing.Add($p) }
                }
            }
            elseif ($p -match ('^[A-Za-z0-9_.\-]+\.(' + $fileExt + ')$')) {
                # a bare file name may live anywhere in the repo
                if ($Files.Where({ $_.Equals($p, [System.StringComparison]::OrdinalIgnoreCase) -or $_.EndsWith('\' + $p, [System.StringComparison]::OrdinalIgnoreCase) }, 'First').Count -eq 0) { $null = $missing.Add($p) }
            }
        }
        $missing | Select-Object -Unique
    }

    It "repo file paths in backticks in README, CHANGELOG and the extensibility guide exist" {
        $files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\/](\.git|\.claude|logs)[\/]' } | ForEach-Object { $_.FullName.Substring($script:RepoRoot.Length).TrimStart('\').TrimStart('/') -replace '/', '\' })
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($doc in @('README.md', 'CHANGELOG.md', 'docs\EXTENSIBILITY_GUIDE.md', 'docs\EXTENSIBILITY_GUIDE.ja.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $doc))
            foreach ($p in Get-MissingDocPath -Text $text -RepoRoot $script:RepoRoot -Files $files -Exclude $script:DocPathExclusions) {
                $null = $missing.Add("${doc}: $p")
            }
        }
        ($missing | Select-Object -Unique) -join "`n" | Should Be ''
    }

    It "the doc path check detects missing paths and accepts existing ones" {
        $files = @('phases\18-iso.ps1')
        $text = 'ok `config\schema.psd1` `docs/EXTENSIBILITY_GUIDE.md` `18-iso.ps1` bad `config\does-not-exist.psd1` `nope\x.ps1` `gone.ps1` `config/*.psd1` `migration-manifest.json`'
        $r = @(Get-MissingDocPath -Text $text -RepoRoot $script:RepoRoot -Files $files -Exclude @('migration-manifest.json'))
        ($r -join '|') | Should Be 'config\does-not-exist.psd1|gone.ps1'
    }
}

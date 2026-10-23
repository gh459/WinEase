# WinEase.Regression.Tests.ps1 - regression tests for configuration resolution and file safety
# Run with:  Invoke-Pester -Path .\tests\WinEase.Regression.Tests.ps1
# Requires:  Pester 3.4 (same syntax as the split suite); the CI job runs Windows PowerShell 5.1
# Tagged slow: the local fast suite is Invoke-Pester -Path .\tests -ExcludeTag slow.
#
# These tests run the builder as a child process with -DryRun -NonInteractive, so nothing is
# mounted, built or deleted. Each run writes a configuration snapshot (logs\*.config.json) that
# records what the build would have used; the tests read it to compare the effective settings.
# Tests that work on drive-letter paths only run on Windows.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are used inside It blocks')]
param()

$script:RepoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { Get-Location | Select-Object -ExpandProperty Path }
$script:BuilderPath = Join-Path -Path $script:RepoRoot -ChildPath 'WinEasebuilder.ps1'
$script:IsWindowsHost = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$env:WINEASE_UI_LANGUAGE = 'en'

# Runs the builder in a child process of the same PowerShell edition. Standard input is
# closed right away, so a Read-Host would fail or end instead of waiting; the timeout turns a
# hang into a test failure instead of a stuck CI job.
function Invoke-WinEaseBuilderProcess {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 300
    )
    $exe = (Get-Process -Id $PID).Path
    $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BuilderPath) + @($Arguments) | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($quoted -join ' ')
    $psi.WorkingDirectory = $script:RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { try { $proc.Kill() } catch { Write-Verbose "Kill failed: $($_.Exception.Message)" } }
    $proc.WaitForExit()
    $output = $stdout.Result + "`n" + $stderr.Result
    $snapshot = $null
    $m = [regex]::Match($output, 'Config Snapshot:\s+(\S.*?\.config\.json)')
    if ($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value)) {
        $snapshot = [System.IO.File]::ReadAllText($m.Groups[1].Value, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Output = $output; TimedOut = $timedOut; Snapshot = $snapshot }
}

# The snapshot stores [switch] variables as { IsPresent = ... } and [bool] variables as plain
# booleans; this reads either form.
function Get-WinEaseSnapshotBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value.PSObject.Properties['IsPresent']) { return [bool]$Value.IsPresent }
    throw "Unexpected snapshot value: $Value"
}

function New-WinEaseTestProfile {
    param([string]$Path, $Data)
    $Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

Describe "Regression - every built-in preset resolves without prompts" -Tags 'slow' {
    $presetDef = Import-PowerShellDataFile -LiteralPath (Join-Path (Join-Path $script:RepoRoot 'config') 'presets.psd1')

    foreach ($name in @($presetDef.PresetOrder)) {
        It "preset '$name' resolves under -DryRun -NonInteractive" {
            $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-Profile', $name)
            $r.TimedOut | Should Be $false
            $r.ExitCode | Should Be 0
            $r.Output | Should Match 'Configuration resolved successfully'
            $r.Output | Should Not Match 'Unrecognized profile'
            $r.Snapshot.Profile | Should Be $name
        }
    }

    It "the TweakSettings of a preset reach the build" {
        # Apply-ProfileSettings once collected the tweak layers without writing them back,
        # so every preset and profile tweak was silently replaced by the schema default.
        foreach ($name in @('extreme', 'none')) {
            $expected = $presetDef.Presets[$name].TweakSettings
            $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-Profile', $name)
            $r.ExitCode | Should Be 0
            foreach ($k in $expected.Keys) {
                "$name.$k=$($r.Snapshot.TweakSettings.$k)" | Should Be "$name.$k=$([bool]$expected[$k])"
            }
        }
    }

    It "every preset alias names an existing preset and is accepted by -Profile" {
        foreach ($alias in $presetDef.Aliases.Keys) {
            $presetDef.Presets.ContainsKey($presetDef.Aliases[$alias]) | Should Be $true
        }
        $first = @($presetDef.Aliases.Keys)[0]
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-Profile', $first)
        $r.ExitCode | Should Be 0
        $r.Output | Should Not Match 'Unrecognized profile'
    }

    It "an unknown preset name warns and falls back to extreme instead of failing silently" {
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-Profile', 'no-such-preset')
        $r.ExitCode | Should Be 0
        $r.Output | Should Match "Unrecognized profile 'no-such-preset'"
        $r.Snapshot.Profile | Should Be 'extreme'
    }
}

Describe "Regression - command line, profiles and precedence" -Tags 'slow' {
    It "-NonInteractive never waits for the console" {
        # Standard input is closed: a prompt would either throw or hang until the timeout.
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-Profile', 'balanced') -TimeoutSeconds 240
        $r.TimedOut | Should Be $false
        $r.Output | Should Not Match 'Do you want to continue\?'
        $r.Output | Should Match 'automated/CLI mode'
    }

    It "an explicit CLI switch wins over the loaded profile" {
        $p = New-WinEaseTestProfile -Path (Join-Path $TestDrive 'cli-wins.json') -Data ([ordered]@{
            ProfileName = 'cli-wins'; Version = '2.1'
            Settings = [ordered]@{ RemoveDefender = $true; KeepBluetooth = $true }
        })
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-LoadProfile', $p, '-KeepDefender', '-DisableBluetooth')
        $r.ExitCode | Should Be 0
        (Get-WinEaseSnapshotBool $r.Snapshot.RemoveDefender) | Should Be $false
        (Get-WinEaseSnapshotBool $r.Snapshot.KeepBluetooth) | Should Be $false
    }

    It "the profile wins over the preset it is combined with" {
        $p = New-WinEaseTestProfile -Path (Join-Path $TestDrive 'profile-wins.json') -Data ([ordered]@{
            ProfileName = 'profile-wins'; Settings = [ordered]@{ RemoveDefender = $false }
        })
        # extreme removes Defender; the profile keeps it
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-Profile', 'extreme', '-LoadProfile', $p)
        $r.ExitCode | Should Be 0
        (Get-WinEaseSnapshotBool $r.Snapshot.RemoveDefender) | Should Be $false
    }

    It "a legacy flat profile with legacy tweak key names still loads" {
        # Version 2.0 files had no Settings wrapper and used the old tweak names (schema.psd1 Aliases)
        $p = New-WinEaseTestProfile -Path (Join-Path $TestDrive 'legacy.json') -Data ([ordered]@{
            ProfileName = 'legacy'; Version = '2.0'
            RemoveDefender = $false
            TweakSettings = [ordered]@{ DisableTelemetry = $false; BypassRequirements = $false }
        })
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-LoadProfile', $p)
        $r.ExitCode | Should Be 0
        $r.Output | Should Not Match 'unrecognized setting'
        $r.Snapshot.TweakSettings.DisableTelemetryAndDiagnostics | Should Be $false
        $r.Snapshot.TweakSettings.BypassHardwareRequirements | Should Be $false
    }

    It "an unknown setting key is reported as a warning and does not change the build" {
        $p = New-WinEaseTestProfile -Path (Join-Path $TestDrive 'typo.json') -Data ([ordered]@{
            ProfileName = 'typo'; Settings = [ordered]@{ RemoveDefendr = $true }
        })
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-LoadProfile', $p)
        $r.ExitCode | Should Be 0
        $r.Output | Should Match 'unrecognized setting\(s\): RemoveDefendr'
        (Get-WinEaseSnapshotBool $r.Snapshot.RemoveDefender) | Should Be $false
    }

    It "a malformed JSON profile is refused with a non-zero exit code" {
        $p = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $p -Value '{ "Settings": { "RemoveDefender": true, ' -Encoding UTF8
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-LoadProfile', $p)
        $r.ExitCode | Should Not Be 0
        $r.Output | Should Not Match 'Configuration resolved successfully'
    }

    It "a missing profile file is refused with a non-zero exit code" {
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-LoadProfile', (Join-Path $TestDrive 'does-not-exist.json'))
        $r.ExitCode | Should Not Be 0
        $r.Output | Should Match 'Profile file not found'
    }

    It "a quoted boolean is refused instead of being read as true" {
        # [bool]'false' is $true in PowerShell: before the type check this file removed Defender.
        $p = New-WinEaseTestProfile -Path (Join-Path $TestDrive 'quoted.json') -Data ([ordered]@{
            ProfileName = 'quoted'; Settings = [ordered]@{ RemoveDefender = 'false'; TweakSettings = [ordered]@{ DisableUAC = 'no' } }
        })
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-LoadProfile', $p)
        $r.ExitCode | Should Not Be 0
        $r.Output | Should Match 'wrong type'
        $r.Output | Should Match 'RemoveDefender'
        $r.Output | Should Match 'TweakSettings\.DisableUAC'
    }

    It "a profile written by -SaveProfile loads back to the same settings" {
        $saved = Join-Path $TestDrive 'roundtrip.json'
        $first = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-Profile', 'vm', '-KeepDefender', '-SaveProfile', $saved)
        $first.ExitCode | Should Be 0
        Test-Path -LiteralPath $saved | Should Be $true
        $second = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-LoadProfile', $saved)
        $second.ExitCode | Should Be 0
        $second.Output | Should Not Match 'unrecognized setting'
        foreach ($prop in $first.Snapshot.PSObject.Properties) {
            if (@('Timestamp', 'Profile', 'TweakSettings') -contains $prop.Name) { continue }
            ($second.Snapshot.($prop.Name) | ConvertTo-Json -Depth 4 -Compress) | Should Be ($prop.Value | ConvertTo-Json -Depth 4 -Compress)
        }
        foreach ($prop in $first.Snapshot.TweakSettings.PSObject.Properties) {
            "$($prop.Name)=$($second.Snapshot.TweakSettings.($prop.Name))" | Should Be "$($prop.Name)=$($prop.Value)"
        }
    }

    It "-ComparePreset prints a diff and neither writes a build snapshot nor creates the work directory" {
        $workDir = Join-Path $TestDrive 'compare-workdir'
        $logsDir = Join-Path $script:RepoRoot 'logs'
        $before = @(if (Test-Path -LiteralPath $logsDir) { Get-ChildItem -LiteralPath $logsDir -Filter '*.config.json' | ForEach-Object { $_.Name } })
        $r = Invoke-WinEaseBuilderProcess -Arguments @('-DryRun', '-NonInteractive', '-ComparePreset', 'balanced', '-WorkDir', $workDir)
        $r.ExitCode | Should Be 0
        $r.Output | Should Match 'Config diff:'
        $after = @(if (Test-Path -LiteralPath $logsDir) { Get-ChildItem -LiteralPath $logsDir -Filter '*.config.json' | ForEach-Object { $_.Name } })
        @($after | Where-Object { $before -notcontains $_ }).Count | Should Be 0
        Test-Path -LiteralPath $workDir | Should Be $false
    }
}

Describe "Regression - config\WinEase.config.schema.json matches the real profile format" -Tags 'slow' {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path (Join-Path $script:RepoRoot 'config') 'schema.psd1')
    $schemaText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $script:RepoRoot 'config') 'WinEase.config.schema.json'), [System.Text.Encoding]::UTF8)
    $schema = $schemaText | ConvertFrom-Json

    It "every Bool component and every tweak is a boolean property with the default of schema.psd1" {
        foreach ($cd in @($settingsDef.Components | Where-Object { $_.Type -eq 'Bool' })) {
            $p = $schema.properties.($cd.Key)
            "$($cd.Key):$([bool]$p)" | Should Be "$($cd.Key):True"
            "$($cd.Key):$($p.type)" | Should Be "$($cd.Key):boolean"
            if ($cd.ContainsKey('Default') -and $null -ne $p.default) { "$($cd.Key):$([bool]$p.default)" | Should Be "$($cd.Key):$([bool]$cd.Default)" }
        }
        foreach ($td in $settingsDef.Tweaks) {
            $p = $schema.properties.($td.Key)
            "$($td.Key):$([bool]$p)" | Should Be "$($td.Key):True"
            if ($null -ne $p.default) { "$($td.Key):$([bool]$p.default)" | Should Be "$($td.Key):$([bool]$td.Default)" }
        }
    }

    It "the schema accepts the Settings wrapper written by -SaveProfile" {
        $schema.properties.Settings | Should Not BeNullOrEmpty
        $schema.properties.DebloatEngineSelection | Should Not BeNullOrEmpty
    }

    It "the checked-in profiles validate against the schema (PowerShell 7 Test-Json)" {
        if ($PSVersionTable.PSVersion -lt [version]'7.4') { Set-TestInconclusive -Message 'Test-Json with draft 2020-12 needs PowerShell 7.4+' ; return }
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'profiles') -Filter '*.json') {
            $doc = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            "$($f.Name):$(Test-Json -Json $doc -Schema $schemaText -ErrorAction SilentlyContinue)" | Should Be "$($f.Name):True"
        }
        $bad = '{ "Settings": { "RemoveDefender": "false" } }'
        (Test-Json -Json $bad -Schema $schemaText -ErrorAction SilentlyContinue) | Should Be $false
        $unknown = '{ "Settings": { "RemoveDefendr": true } }'
        (Test-Json -Json $unknown -Schema $schemaText -ErrorAction SilentlyContinue) | Should Be $false
    }
}

Describe "Regression - delete and restore safety (temporary directories only)" -Tags 'slow' {
    . (Join-Path $script:RepoRoot 'WinEasehelpers.ps1')
    . (Join-Path (Join-Path (Join-Path $script:RepoRoot 'tools') 'migrator') 'WinEaseMigration.ps1')

    It "Test-IsSafePathToDelete refuses roots, system folders and the repository, and allows a scratch folder" {
        if (-not $script:IsWindowsHost) { Set-TestInconclusive -Message 'drive-letter paths: Windows only'; return }
        Test-IsSafePathToDelete -Path '' | Should Be $false
        Test-IsSafePathToDelete -Path "$($env:SystemDrive)\" | Should Be $false
        Test-IsSafePathToDelete -Path $env:windir | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path $env:windir 'System32') | Should Be $false
        Test-IsSafePathToDelete -Path $env:USERPROFILE | Should Be $false
        Test-IsSafePathToDelete -Path "$($env:SystemDrive)\Users" | Should Be $false
        $scratch = Join-Path $TestDrive 'scratch'
        New-Item -ItemType Directory -Force -Path $scratch | Out-Null
        Test-IsSafePathToDelete -Path $scratch | Should Be $true
    }

    It "Test-WinEasePathWithin compares on a directory boundary, not a string prefix" {
        if (-not $script:IsWindowsHost) { Set-TestInconclusive -Message 'drive-letter paths: Windows only'; return }
        Test-WinEasePathWithin -Path 'C:\work\image' -Root 'C:\work' | Should Be $true
        Test-WinEasePathWithin -Path 'C:\work-other\image' -Root 'C:\work' | Should Be $false
        Test-WinEasePathWithin -Path 'C:\work\..\Windows' -Root 'C:\work' | Should Be $false
        Test-WinEasePathWithin -Path 'C:/work/image' -Root 'C:\WORK' | Should Be $true
    }

    It "a tampered backup file is not restored and the existing file is left alone" {
        if (-not $script:IsWindowsHost) { Set-TestInconclusive -Message 'drive-letter paths: Windows only'; return }
        $bk = Join-Path $TestDrive 'tamper-backup'
        $userProfile = Join-Path $TestDrive 'tamper-profile'
        New-Item -ItemType Directory -Force -Path (Join-Path $bk 'Docs'), (Join-Path $userProfile 'notes') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $bk 'Docs\notes') | Out-Null
        Set-Content -LiteralPath (Join-Path $bk 'Docs\notes\a.txt') -Value 'original'
        $hash = (Get-FileHash -LiteralPath (Join-Path $bk 'Docs\notes\a.txt') -Algorithm SHA256).Hash
        [PSCustomObject]@{ Created = (Get-Date).ToString('o'); Entries = @([PSCustomObject]@{ Category = 'Docs'; RelativePath = 'notes\a.txt'; Sha256 = $hash }) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $bk 'migration-manifest.json') -Encoding UTF8
        # the payload changes after the manifest was written
        Set-Content -LiteralPath (Join-Path $bk 'Docs\notes\a.txt') -Value 'tampered'
        Set-Content -LiteralPath (Join-Path $userProfile 'notes\a.txt') -Value 'current'
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = $userProfile
            $res = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
        } finally { $env:USERPROFILE = $saved }
        $res.RestoredFiles | Should Be 0
        @($res.FailedFiles | Where-Object { $_.Error -match 'Hash mismatch' }).Count | Should Be 1
        (Get-Content -LiteralPath (Join-Path $userProfile 'notes\a.txt') -Raw).Trim() | Should Be 'current'
        Test-Path -LiteralPath (Join-Path $userProfile 'notes\a.txt.WinEase.bak') | Should Be $false
    }

    It "a manifest entry that climbs out of the backup leaves files outside the profile untouched" {
        if (-not $script:IsWindowsHost) { Set-TestInconclusive -Message 'drive-letter paths: Windows only'; return }
        $bk = Join-Path $TestDrive 'escape-backup'
        $userProfile = Join-Path $TestDrive 'escape-profile'
        $outside = Join-Path $TestDrive 'outside.txt'
        New-Item -ItemType Directory -Force -Path (Join-Path $bk 'Docs'), $userProfile | Out-Null
        Set-Content -LiteralPath $outside -Value 'keep me'
        Set-Content -LiteralPath (Join-Path $bk 'Docs\x.txt') -Value 'payload'
        [PSCustomObject]@{ Entries = @(
            [PSCustomObject]@{ Category = 'Docs'; RelativePath = '..\..\outside.txt' },
            [PSCustomObject]@{ Category = '..'; RelativePath = 'outside.txt' }
        ) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $bk 'migration-manifest.json') -Encoding UTF8
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = $userProfile
            $res = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
        } finally { $env:USERPROFILE = $saved }
        $res.RestoredFiles | Should Be 0
        @($res.FailedFiles).Count | Should Be 2
        (Get-Content -LiteralPath $outside -Raw).Trim() | Should Be 'keep me'
    }

    It "Write-WinEaseTextFileAtomic leaves no temporary file behind" {
        $dir = Join-Path $TestDrive 'atomic'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $target = Join-Path $dir 'state.json'
        Write-WinEaseTextFileAtomic -Path $target -Content '{"a":1}' | Out-Null
        Write-WinEaseTextFileAtomic -Path $target -Content '{"a":2}' | Out-Null
        ([System.IO.File]::ReadAllText($target)).Trim() | Should Be '{"a":2}'
        @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne 'state.json' }).Count | Should Be 0
    }
}

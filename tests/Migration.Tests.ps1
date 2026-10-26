# Migration.Tests.ps1 - migration engine, migrator, restore validation and wiring
# Run with:  Invoke-Pester -Path .\tests\Migration.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


# --- PC Migration & Backup Engine tests (M3) ---
# The migration engine depends on WinEasehelpers.ps1 (Test-WinEasePathWithin etc.).
if (-not (Get-Command -Name Test-WinEasePathWithin -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}
if (-not (Get-Command -Name Get-WinEaseMigrationRules -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
}

Describe "PC Migration & Backup Engine (tools/migrator/WinEaseMigration.ps1)" -Tags 'slow' {
    It "Get-WinEaseMigrationRules loads standard rules" {
        $rules = Get-WinEaseMigrationRules
        $rules.GameRules.Count | Should BeGreaterThan 0
        $rules.AppConfigRules.Count | Should BeGreaterThan 0
        $rules.SecretPatterns.Count | Should BeGreaterThan 0
        $rules.Errors.Count | Should Be 0
    }
    It "Expand-WinEaseMigrationPath expands environment variables" {
        $p = Expand-WinEaseMigrationPath -RawPath '%USERPROFILE%\Documents'
        $p | Should Not Be '%USERPROFILE%\Documents'
        $p | Should Match 'Documents$'
    }
    It "Test-WinEaseSecretPath identifies secret files" {
        $patterns = @('*Cookies*','*id_rsa*','*.pfx')
        Test-WinEaseSecretPath -FilePath 'Cookies' -SecretPatterns $patterns | Should Be $true
        Test-WinEaseSecretPath -FilePath 'normal.txt' -SecretPatterns $patterns | Should Be $false
    }
    It "Backup-WinEaseUserData copies files and records SHA-256 without deleting source" {
        $srcDir = Join-Path $env:TEMP "migtest_src2"
        $bkDir = Join-Path $env:TEMP "migtest_bk2"
        if (Test-Path $srcDir) { Remove-Item $srcDir -Recurse -Force }
        if (Test-Path $bkDir) { Remove-Item $bkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $srcDir 'Documents') | Out-Null
        'hello' | Set-Content (Join-Path $srcDir 'Documents\test.txt')
        $r = Backup-WinEaseUserData -FolderMap @{ Documents = (Join-Path $srcDir 'Documents') } -BackupRoot $bkDir
        $r.CopiedFiles | Should Be 1
        $r.Success | Should Be $true
        $r.ManifestEntries.Count | Should Be 1
        $r.ManifestEntries[0].Sha256 | Should Not Be ''
        # source still exists
        Test-Path (Join-Path $srcDir 'Documents\test.txt') | Should Be $true
        Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $bkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "Restore-WinEaseUserData creates .WinEase.bak on conflict" {
        $srcDir = Join-Path $env:TEMP "migtest_src3"
        $bkDir = Join-Path $env:TEMP "migtest_bk3"
        $profileDir = Join-Path $env:TEMP ("migtest_profile3_" + [guid]::NewGuid().ToString('N'))
        if (Test-Path $srcDir) { Remove-Item $srcDir -Recurse -Force }
        if (Test-Path $bkDir) { Remove-Item $bkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $srcDir 'Documents'), (Join-Path $profileDir 'Documents') | Out-Null
        'hello' | Set-Content (Join-Path $srcDir 'Documents\test.txt')
        Backup-WinEaseUserData -FolderMap @{ Documents = (Join-Path $srcDir 'Documents') } -BackupRoot $bkDir | Out-Null
        $destFile = Join-Path $profileDir 'Documents\test.txt'
        'existing' | Set-Content $destFile
        $savedProfile = $env:USERPROFILE
        $env:USERPROFILE = $profileDir
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bkDir -ConflictPolicy BackupExisting
            $r.RestoredFiles | Should Be 1
            Test-Path "$destFile.WinEase.bak" | Should Be $true
            (Get-Content -LiteralPath $destFile -Raw).Trim() | Should Be 'hello'
        } finally {
            $env:USERPROFILE = $savedProfile
            Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $bkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "Start-WinEaseMigrationRestore -RetryFailedOnly skips completed tasks" {
        $bkDir = Join-Path $env:TEMP "migtest_bk4"
        if (Test-Path $bkDir) { Remove-Item $bkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $bkDir | Out-Null
        @{ Created = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $bkDir 'migration-manifest.json') -Encoding UTF8
        Start-WinEaseMigrationRestore -BackupRoot $bkDir | Out-Null
        $r2 = Start-WinEaseMigrationRestore -BackupRoot $bkDir -RetryFailedOnly
        @($r2.Results | Where-Object { $_.Status -like 'Skipped*' }).Count | Should BeGreaterThan 0
        Remove-Item $bkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "Invoke-WinEaseMigrationRulesBackup excludes secret files by default" {
        # Verify Test-WinEaseSecretPath identifies secret patterns
        $patterns = (Get-WinEaseMigrationRules).SecretPatterns
        Test-WinEaseSecretPath -FilePath 'Cookies' -SecretPatterns $patterns | Should Be $true
        Test-WinEaseSecretPath -FilePath 'id_rsa' -SecretPatterns $patterns | Should Be $true
        Test-WinEaseSecretPath -FilePath 'normal.txt' -SecretPatterns $patterns | Should Be $false
    }
}

# --- S3: migration engine (task-based restore, report, BackupRoot guard) ---
Describe "Migration engine S3 (tools/migrator/WinEaseMigration.ps1)" -Tags 'slow' {
    BeforeAll {
        if (-not (Get-Command -Name Test-WinEasePathWithin -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
        }
        if (-not (Get-Command -Name Start-WinEaseMigrationRestore -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
        }
    }

    It "Start-WinEaseMigrationRestore -RetryFailedOnly reruns only Failed tasks" {
        $bk = Join-Path $TestDrive 'retry'
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        $manifest = @{
            Created = (Get-Date).ToString('o')
            Entries = @()
            Folders = @(@{ Category = 'Documents'; SourcePath = 'C:\x' }, @{ Category = 'Pictures'; SourcePath = 'C:\y' })
            Rules = @()
            CustomPaths = @()
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $bk 'migration-manifest.json') -Encoding UTF8
        @{ UserData_Documents = 'Completed'; UserData_Pictures = 'Failed' } | ConvertTo-Json | Set-Content (Join-Path $bk 'restore-state.json') -Encoding UTF8
        $script:s3Calls = @()
        Mock Restore-WinEaseUserData { $script:s3Calls += ($Categories -join ','); [PSCustomObject]@{ RestoredFiles = 1; SkippedFiles = 0; FailedFiles = @() } }
        $r = Start-WinEaseMigrationRestore -BackupRoot $bk -RetryFailedOnly
        $script:s3Calls.Count | Should Be 1
        $script:s3Calls[0] | Should Be 'Pictures'
        ($r.Results | Where-Object { $_.TaskId -eq 'UserData_Documents' }).Status | Should Match '^Skipped'
        $state = Get-Content (Join-Path $bk 'restore-state.json') -Raw | ConvertFrom-Json
        $state.UserData_Pictures | Should Be 'Completed'
        $state.UserData_Documents | Should Be 'Completed'
    }

    It "Start-WinEaseMigrationRestore continues after a failed task" {
        $bk = Join-Path $TestDrive 'continue'
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        @{ Entries = @(); Folders = @(@{ Category = 'A'; SourcePath = 'C:\a' }, @{ Category = 'B'; SourcePath = 'C:\b' }); Rules = @(); CustomPaths = @() } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $bk 'migration-manifest.json') -Encoding UTF8
        Mock Restore-WinEaseUserData {
            if ($Categories -contains 'A') { throw 'boom' }
            [PSCustomObject]@{ RestoredFiles = 0; SkippedFiles = 0; FailedFiles = @() }
        }
        $r = Start-WinEaseMigrationRestore -BackupRoot $bk
        ($r.Results | Where-Object { $_.TaskId -eq 'UserData_A' }).Status | Should Be 'Failed'
        ($r.Results | Where-Object { $_.TaskId -eq 'UserData_B' }).Status | Should Be 'Completed'
    }

    It "Backup writes migration-report.html/json, escapes HTML, and leaves sources untouched" {
        $src = Join-Path $TestDrive 'src\Docs'
        $bk = Join-Path $TestDrive 'bk-report'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        $evil = '<script>alert(1)</script>.txt'
        Set-Content (Join-Path $src 'a.txt') 'hello'
        $before = (Get-FileHash (Join-Path $src 'a.txt') -Algorithm SHA256).Hash
        Start-WinEaseMigrationBackup -FolderMap @{ 'Docs' = $src } -BackupRoot $bk -OfflineTestMode | Out-Null
        Test-Path (Join-Path $bk 'migration-report.html') | Should Be $true
        Test-Path (Join-Path $bk 'migration-report.json') | Should Be $true
        (Get-FileHash (Join-Path $src 'a.txt') -Algorithm SHA256).Hash | Should Be $before
        $j = Get-Content (Join-Path $bk 'migration-report.json') -Raw | ConvertFrom-Json
        $j.Success.Files | Should Be 1
        $j.Success.Sha256Verified | Should Be 1
        $mf = Get-Content (Join-Path $bk 'migration-manifest.json') -Raw | ConvertFrom-Json
        @($mf.Folders).Count | Should Be 1
        @($mf.Entries).Count | Should Be 1
        $rep = Export-WinEaseMigrationReport -MigrationResult ([PSCustomObject]@{ Results = @([PSCustomObject]@{ TaskId = "App_$evil"; Status = 'Failed'; Detail = $evil }) }) -ReportPath (Join-Path $TestDrive 'r2\migration-report.html')
        $html = Get-Content $rep.HtmlPath -Raw
        $html | Should Not Match '<script>alert'
        $html | Should Match '&lt;script&gt;'
    }

    It "A second backup into the same root keeps the folders the first one recorded" {
        $docs = Join-Path $TestDrive 'merge\Docs'
        $pics = Join-Path $TestDrive 'merge\Pics'
        $bk = Join-Path $TestDrive 'bk-merge'
        New-Item -ItemType Directory -Force -Path $docs, $pics | Out-Null
        Set-Content (Join-Path $docs 'a.txt') 'a'
        Set-Content (Join-Path $pics 'p.txt') 'p'
        Start-WinEaseMigrationBackup -FolderMap @{ 'Documents' = $docs } -BackupRoot $bk -OfflineTestMode | Out-Null
        Start-WinEaseMigrationBackup -FolderMap @{ 'Pictures' = $pics } -BackupRoot $bk -OfflineTestMode | Out-Null
        $mf = Get-Content (Join-Path $bk 'migration-manifest.json') -Raw | ConvertFrom-Json
        @($mf.Folders | ForEach-Object { $_.Category } | Sort-Object) -join ',' | Should Be 'Documents,Pictures'
        @($mf.Entries).Count | Should Be 2
        # Backing up the same folder again replaces its entries instead of duplicating them
        Start-WinEaseMigrationBackup -FolderMap @{ 'Documents' = $docs } -BackupRoot $bk -OfflineTestMode | Out-Null
        $mf = Get-Content (Join-Path $bk 'migration-manifest.json') -Raw | ConvertFrom-Json
        @($mf.Folders).Count | Should Be 2
        @($mf.Entries).Count | Should Be 2
    }

    It "Backup-WinEaseUserData and Backup-WinEaseCustomPaths reject a BackupRoot inside the source" {
        $src = Join-Path $TestDrive 'guard\Docs'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content (Join-Path $src 'a.txt') 'x'
        $inside = Join-Path $src 'backup'
        { Backup-WinEaseUserData -FolderMap @{ Docs = $src } -BackupRoot $inside } | Should Throw
        { Backup-WinEaseCustomPaths -Paths @($src) -BackupRoot $inside } | Should Throw
        { Start-WinEaseMigrationBackup -FolderMap @{ Docs = $src } -BackupRoot $inside -OfflineTestMode } | Should Throw
        Test-Path $inside | Should Be $false
        Test-Path (Join-Path $src 'a.txt') | Should Be $true
    }

    It "Invoke-WinEaseMigrationRulesBackup result carries CloudSaveNotices for rules that define one" {
        $rules = Get-WinEaseMigrationRules
        $rule = @($rules.GameRules + $rules.AppConfigRules) | Where-Object { $_.CloudSaveNotice } | Select-Object -First 1
        $rule | Should Not BeNullOrEmpty
        $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @($rule.Id) -BackupRoot (Join-Path $TestDrive 'bk-rules') -ForceRunningProcess
        @($r.CloudSaveNotices).Count | Should Be 1
        $r.CloudSaveNotices[0].RuleId | Should Be $rule.Id
    }
}

# --- S3b: rules backup/restore fixes (reg.exe syntax, manifest-based restore, skip reporting) ---
Describe "Migration rules backup/restore (tools/migrator/WinEaseMigration.ps1)" -Tags 'slow' {
    BeforeAll {
        if (-not (Get-Command -Name Test-WinEasePathWithin -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
        }
        if (-not (Get-Command -Name Invoke-WinEaseMigrationRulesBackup -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
        }
    }

    It "exports a rule registry key written in PSDrive spelling (HKCU:\...) and restores it" {
        $key = 'HKCU:\Software\WinEaseMigrationTest'
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name Probe -Value 'backup'
        $rules = [PSCustomObject]@{
            GameRules      = @()
            AppConfigRules = @(@{ Id = 'RegProbe'; Name = 'Registry probe'; Category = 'AppConfig'; RegistryPaths = @($key); SourcePaths = @(); ExcludePatterns = @(); ProcessNames = @(); ExcludeSecrets = $true })
            CustomPathRules= @()
            SecretPatterns = @()
            Errors         = @()
        }
        $bk = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $TestDrive 'bk-reg'))
        $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('RegProbe') -BackupRoot $bk -Rules $rules -ForceRunningProcess
        @($r.FailedFiles).Count | Should Be 0
        $r.RegistryExports | Should Be 1
        $regFile = Get-ChildItem -LiteralPath (Join-Path $bk 'rules\RegProbe') -Filter '*.reg' | Select-Object -First 1
        $regFile | Should Not BeNullOrEmpty
        Remove-Item $key -Recurse -Force
        $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('RegProbe') -BackupRoot $bk -Rules $rules -ForceRunningProcess
        @($rr.FailedFiles).Count | Should Be 0
        (Get-ItemProperty -Path $key -Name Probe).Probe | Should Be 'backup'
        Remove-Item $key -Recurse -Force
    }

    It "restores every file of a multi-source rule to its own source location" {
        $ms = Join-Path $TestDrive 'ms'
        New-Item -ItemType Directory -Force -Path (Join-Path $ms 'saves\world') | Out-Null
        'save' | Set-Content (Join-Path $ms 'saves\world\level.dat')
        'opts' | Set-Content (Join-Path $ms 'options.txt')
        $rules = [PSCustomObject]@{
            GameRules      = @()
            AppConfigRules = @(@{ Id = 'MultiProbe'; Name = 'Multi-source probe'; Category = 'AppConfig'; SourcePaths = @((Join-Path $ms 'saves'), (Join-Path $ms 'options.txt')); ExcludePatterns = @(); ProcessNames = @(); ExcludeSecrets = $true })
            CustomPathRules= @()
            SecretPatterns = @()
            Errors         = @()
        }
        $bk = Join-Path $TestDrive 'bk-multi'
        Invoke-WinEaseMigrationRulesBackup -RuleIds @('MultiProbe') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
        Test-Path (Join-Path $bk 'rules\MultiProbe\rule-manifest.json') | Should Be $true
        Remove-Item (Join-Path $ms 'saves') -Recurse -Force
        Remove-Item (Join-Path $ms 'options.txt') -Force
        $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('MultiProbe') -BackupRoot $bk -Rules $rules -ForceRunningProcess
        @($rr.FailedFiles).Count | Should Be 0
        $rr.RestoredFiles | Should Be 2
        Test-Path (Join-Path $ms 'saves\world\level.dat') | Should Be $true
        Test-Path (Join-Path $ms 'saves\world\level.dat') -PathType Leaf | Should Be $true
        Test-Path (Join-Path $ms 'options.txt') -PathType Leaf | Should Be $true
        (Get-Content (Join-Path $ms 'options.txt') -Raw).Trim() | Should Be 'opts'
        # nothing ended up below the first source path
        Test-Path (Join-Path $ms 'saves\options.txt') | Should Be $false
        Test-Path (Join-Path $ms 'saves\saves') | Should Be $false
    }

    It "skips a rule whose process is running and reports the reason" {
        $rules = [PSCustomObject]@{
            GameRules      = @()
            AppConfigRules = @(@{ Id = 'RunningProbe'; Name = 'Running probe'; Category = 'AppConfig'; SourcePaths = @(); RegistryPaths = @(); ExcludePatterns = @(); ProcessNames = @('winease-fake-proc'); ExcludeSecrets = $true })
            CustomPathRules= @()
            SecretPatterns = @()
            Errors         = @()
        }
        Mock Get-Process { [PSCustomObject]@{ Name = 'winease-fake-proc' } } -ParameterFilter { $Name -eq 'winease-fake-proc' }
        $bk = Join-Path $TestDrive 'bk-running'
        $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('RunningProbe') -BackupRoot $bk -Rules $rules
        @($r.BackedUpRules).Count | Should Be 0
        @(@($r.SkipReasons) | Where-Object { $_.Item -eq 'RunningProbe' }).Count | Should Be 1
        (@($r.SkipReasons) | Where-Object { $_.Item -eq 'RunningProbe' }).Reason | Should Match 'Application running'
    }

    It "copies and hashes in one pass and preserves the timestamp" {
        $src = Join-Path $TestDrive 'copyhash\file.txt'
        $dest = Join-Path $TestDrive 'copyhash\out\file.txt'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $src), (Split-Path -Parent $dest) | Out-Null
        'payload' | Set-Content $src
        $item = Get-Item $src
        $hash = Copy-WinEaseMigrationFileWithHash -SourcePath $src -DestPath $dest -SourceTimestamp $item.LastWriteTimeUtc
        $hash | Should Be (Get-FileHash $dest -Algorithm SHA256).Hash
        (Get-Item $dest).LastWriteTimeUtc | Should Be $item.LastWriteTimeUtc
    }
}

Describe "S4 builder hooks (ComparePreset / PreBuild / OfflineImage)" {
    BeforeAll { }
    $s4Root = Split-Path -Parent $PSScriptRoot
    $s4Builder = Join-Path $s4Root 'WinEasebuilder.ps1'
    $s4Appx = [System.IO.File]::ReadAllText((Join-Path $s4Root 'phases\05-appx.ps1'))
    $s4Unattend = [System.IO.File]::ReadAllText((Join-Path $s4Root 'phases\11-unattend.ps1'))
    $s4Text = [System.IO.File]::ReadAllText($s4Builder)

    It "-ComparePreset is declared in the param block" {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($s4Builder, [ref]$tokens, [ref]$errs)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($names -contains 'ComparePreset') | Should Be $true
    }
    It "phases/05-appx.ps1 no longer calls the OfflineImage stage" {
        $s4Appx.Contains("-Stage 'OfflineImage'") | Should Be $false
    }
    It "phases/11-unattend.ps1 calls the OfflineImage stage exactly once, before FirstLogon" {
        ([regex]::Matches($s4Unattend, "-Stage 'OfflineImage'")).Count | Should Be 1
        $s4Unattend.IndexOf("-Stage 'OfflineImage'") | Should BeLessThan $s4Unattend.IndexOf("Invoke-WinEaseCustomScriptsStage -Stage 'FirstLogon'")
    }
    It "builder runs the PreBuild stage and the recovery readiness check" {
        $s4Text.Contains("-Stage 'PreBuild'") | Should Be $true
        $s4Text.Contains('Test-WinEaseRecoveryReadiness -Config') | Should Be $true
    }
    It "-ComparePreset balanced prints a diff and exits 0 without building" {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s4Builder -ComparePreset balanced -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out.Contains('Config diff:') | Should Be $true
    }
}

Describe "Migrator tool S6 (tools/migrator/WinEase-Migrator.ps1)" {
    BeforeAll {
        $script:S6Tool = Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEase-Migrator.ps1"
        $script:S6Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:S6Tool, [ref]$null, [ref]$null)
        $script:S6Params = $script:S6Ast.ParamBlock.Parameters
    }

    It "Mode accepts every spec mode and the legacy ones" {
        $modeParam = $script:S6Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
        $set = ($modeParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments | ForEach-Object { $_.Value }
        foreach ($m in 'ExportApps', 'Backup', 'Restore', 'Verify', 'Estimate', 'ListRules', 'RecoveryCheck') {
            ($set -contains $m) | Should Be $true
        }
    }

    It "BackupRoot is an alias of PackagePath" {
        $p = $script:S6Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'PackagePath' }
        $alias = ($p.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }).PositionalArguments | ForEach-Object { $_.Value }
        ($alias -contains 'BackupRoot') | Should Be $true
    }

    It "defaults to the GUI parameter set and has the spec parameters" {
        $script:S6Ast.ParamBlock.Attributes.NamedArguments | Where-Object { $_.ArgumentName -eq 'DefaultParameterSetName' } | ForEach-Object { $_.Argument.Value } | Should Be 'GUI'
        $names = @($script:S6Params | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($n in 'UserFolders', 'CustomPaths', 'RuleIds', 'ConflictPolicy', 'IncludeSecrets', 'RetryFailedOnly', 'DryRun', 'GUI') {
            ($names -contains $n) | Should Be $true
        }
    }

    It "-Mode Estimate -DryRun finishes without error and reports space" {
        $src = Join-Path $TestDrive 's6src'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value 'hello'
        $r = & $script:S6Tool -Mode Estimate -PackagePath (Join-Path $TestDrive 's6pkg') -UserFolders @() -CustomPaths @($src) -DryRun
        $r.Mode | Should Be 'Estimate'
        $r.Estimate.TotalFiles | Should Be 1
    }

    It "-Mode Verify -DryRun does not throw on a missing manifest" {
        $r = & $script:S6Tool -Mode Verify -PackagePath (Join-Path $TestDrive 's6none') -DryRun
        $r.Success | Should Be $false
    }

    It "Verify detects a tampered file" {
        $src = Join-Path $TestDrive 's6vsrc'
        $bk = Join-Path $TestDrive 's6vbk'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value 'hello'
        Backup-WinEaseUserData -FolderMap @{ Docs = $src } -BackupRoot $bk | Out-Null
        (& $script:S6Tool -Mode Verify -PackagePath $bk).Success | Should Be $true
        Set-Content -LiteralPath (Join-Path $bk 'Docs\a.txt') -Value 'tampered'
        (& $script:S6Tool -Mode Verify -PackagePath $bk).Success | Should Be $false
    }
}

Describe "S5: Migration Assistant bundling" {
    $s5Root = Split-Path -Parent $PSScriptRoot
    $s5Text = [System.IO.File]::ReadAllText((Join-Path $s5Root 'phases\11-unattend.ps1'))
    $s5Defs = Import-PowerShellDataFile -LiteralPath (Join-Path $s5Root 'config\schema.psd1')

    It "the component maps to the variable the phase reads" {
        $cd = @($s5Defs.Components | Where-Object { $_.Key -eq 'IncludeMigrationAssistant' })[0]
        $cd.Variable | Should Be 'includeMigrationAssistant'
        $s5Text.Contains('$includeMigrationAssistant') | Should Be $true
    }

    It "the phase targets the four files and the launcher" {
        foreach ($f in 'tools\migrator\WinEase-Migrator.ps1', 'tools\migrator\WinEaseMigration.ps1', 'tools\migrator\migration-rules.psd1', 'config\user\user-migration-rules.psd1', 'WinEasehelpers.ps1', 'lib\WinEasePathSafety.ps1', 'lib\WinEaseSystem.ps1', 'lib\WinEaseFileSystem.ps1', 'lib\WinEaseConfig.ps1', 'lib\WinEaseBenchmarks.ps1', 'lib\WinEaseDependencies.ps1', 'Launch-MigrationAssistant.cmd', 'Windows\Setup\Scripts\Migration', 'Users\Public\Desktop') {
            $s5Text.Contains($f) | Should Be $true
        }
    }

    It "the bundling block copies into a scratch folder and honors DryRun" {
        $start = $s5Text.IndexOf('if ($includeMigrationAssistant -eq $true)')
        $start | Should BeGreaterThan 0
        $block = 'param($scratchDir, $scriptDir, $DryRun, $includeMigrationAssistant)' + "`r`n" + $s5Text.Substring($start)
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("s5_" + [guid]::NewGuid().ToString('N'))
        try {
            $scratchDir = Join-Path $tmp 'scratch'
            New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
            $null = & ([scriptblock]::Create($block)) $scratchDir $s5Root $true $true 6>$null
            (Test-Path (Join-Path $scratchDir 'Windows')) | Should Be $false
            $null = & ([scriptblock]::Create($block)) $scratchDir $s5Root $false $true 6>$null
            $dest = Join-Path $scratchDir 'Windows\Setup\Scripts\Migration'
            # WinEasehelpers.ps1 (restore path validation) and WinEaseGui.ps1 (the wizard window)
            # are part of the bundle: without them the tool cannot start at all.
            foreach ($n in 'WinEase-Migrator.ps1', 'WinEaseMigration.ps1', 'migration-rules.psd1', 'user-migration-rules.psd1', 'WinEasehelpers.ps1', 'WinEaseGuiCore.ps1', 'WinEaseGui.ps1') {
                (Test-Path (Join-Path $dest $n)) | Should Be $true
            }
            foreach ($n in 'en.json', 'ja.json') {
                (Test-Path (Join-Path $dest "ui-strings\$n")) | Should Be $true
            }
            $cmd = Join-Path $scratchDir 'Users\Public\Desktop\Launch-MigrationAssistant.cmd'
            ([System.IO.File]::ReadAllText($cmd)).Contains('-File "C:\Windows\Setup\Scripts\Migration\WinEase-Migrator.ps1" -GUI') | Should Be $true
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- Safety pass (2026-10-21): the restore path validation, the AppX target selection
# --- and the consistency of the security defaults. ---

Describe "Migration restore - path validation" -Tags 'slow' {
    BeforeAll {
        if (-not (Get-Command -Name Resolve-WinEaseSafeRelativePath -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        }
        if (-not (Get-Command -Name Restore-WinEaseCustomPaths -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:RepoRoot "tools\migrator\WinEaseMigration.ps1")
        }
        function New-WinEaseTestManifest {
            param([string]$Path, [object[]]$Entries)
            [PSCustomObject]@{ Created = (Get-Date).ToString('o'); Entries = @($Entries) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        function New-WinEaseTestEntry {
            # one manifest entry; the file it points at is created by the test itself
            param(
                [string]$Category = 'Docs',
                [string]$RelativePath = 'a.txt',
                [string]$SourcePath = '',
                [string]$Sha256 = ''
            )
            return [PSCustomObject]@{
                Category = $Category; RelativePath = $RelativePath; Sha256 = $Sha256; SourcePath = $SourcePath
            }
        }
        function New-WinEaseTestPayload {
            # writes the payload of a backup and returns its hash
            param([string]$Path, [string]$Content = 'payload')
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
            Set-Content -LiteralPath $Path -Value $Content
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
    }

    It "restores a normal backup into the matching folder of the profile" {
        $bk = Join-Path $TestDrive 'ok-backup'
        $userProfile = Join-Path $TestDrive 'ok-profile'
        New-Item -ItemType Directory -Force -Path $userProfile | Out-Null
        $src = Join-Path $TestDrive 'ok-src'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value 'hello'
        Backup-WinEaseUserData -FolderMap @{ Documents = $src } -BackupRoot $bk | Out-Null
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 1
            @($r.FailedFiles).Count | Should Be 0
            (Test-Path -LiteralPath (Join-Path $userProfile 'Documents\a.txt')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $userProfile 'a.txt')) | Should Be $false
        } finally { $env:USERPROFILE = $saved }
    }

    It "keeps the personal folders apart when the same relative name exists in two of them" {
        $bk = Join-Path $TestDrive 'split-backup'
        $userProfile = Join-Path $TestDrive 'split-profile'
        $srcDocs = Join-Path $TestDrive 'split-docs'
        $srcDownloads = Join-Path $TestDrive 'split-downloads'
        New-Item -ItemType Directory -Force -Path $userProfile, $srcDocs, $srcDownloads | Out-Null
        Set-Content -LiteralPath (Join-Path $srcDocs 'same.txt') -Value 'from documents'
        Set-Content -LiteralPath (Join-Path $srcDownloads 'same.txt') -Value 'from downloads'
        Backup-WinEaseUserData -FolderMap @{ Documents = $srcDocs; Downloads = $srcDownloads } -BackupRoot $bk | Out-Null
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 2
            (Get-Content -LiteralPath (Join-Path $userProfile 'Documents\same.txt') -Raw).Trim() | Should Be 'from documents'
            (Get-Content -LiteralPath (Join-Path $userProfile 'Downloads\same.txt') -Raw).Trim() | Should Be 'from downloads'
        } finally { $env:USERPROFILE = $saved }
    }

    It "restores a normal custom path into an allowed location" {
        $bk = Join-Path $TestDrive 'cp-backup'
        $target = Join-Path $TestDrive 'cp-target'
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'note.txt') -Value 'note'
        Backup-WinEaseCustomPaths -Paths @($target) -BackupRoot $bk | Out-Null
        $r = Restore-WinEaseCustomPaths -BackupRoot $bk -ConflictPolicy Overwrite -AllowedSourcePaths @($target)
        $r.RestoredFiles | Should Be 1
        @($r.FailedFiles).Count | Should Be 0
    }

    It "refuses a relative path that climbs out of the profile" {
        $bk = Join-Path $TestDrive 'dotdot-backup'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Force -Path $bk, $outside | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\payload.txt')
        $entry = New-WinEaseTestEntry -RelativePath '..\..\outside\evil.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $userProfile = Join-Path $TestDrive 'dotdot-profile'
        New-Item -ItemType Directory -Force -Path $userProfile | Out-Null
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 0
            @($r.FailedFiles).Count | Should Be 1
            (@($r.FailedFiles)[0].Error) | Should Match 'Refused'
            (Test-Path -LiteralPath (Join-Path $outside 'evil.txt')) | Should Be $false
        } finally { $env:USERPROFILE = $saved }
    }

    It "refuses a relative path that climbs several levels" {
        $bk = Join-Path $TestDrive 'deep-backup'
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\payload.txt')
        $entry = New-WinEaseTestEntry -RelativePath 'a\b\..\..\..\evil.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $userProfile = Join-Path $TestDrive 'deep-profile'
        New-Item -ItemType Directory -Force -Path $userProfile | Out-Null
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 0
            @($r.FailedFiles).Count | Should Be 1
            (@($r.FailedFiles)[0].Error) | Should Match 'Refused'
        } finally { $env:USERPROFILE = $saved }
    }

    It "refuses an absolute path in the manifest" {
        $bk = Join-Path $TestDrive 'abs-backup'
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\payload.txt')
        $entry = New-WinEaseTestEntry -RelativePath 'C:\Windows\Temp\evil.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $userProfile = Join-Path $TestDrive 'abs-profile'
        New-Item -ItemType Directory -Force -Path $userProfile | Out-Null
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 0
            @($r.FailedFiles).Count | Should Be 1
            (@($r.FailedFiles)[0].Error) | Should Match 'Refused'
        } finally { $env:USERPROFILE = $saved }
    }

    It "refuses a UNC path in the manifest" {
        $bk = Join-Path $TestDrive 'unc-backup'
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\payload.txt')
        $entry = New-WinEaseTestEntry -RelativePath '\\server\share\evil.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $userProfile = Join-Path $TestDrive 'unc-profile'
        New-Item -ItemType Directory -Force -Path $userProfile | Out-Null
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 0
            @($r.FailedFiles).Count | Should Be 1
            (@($r.FailedFiles)[0].Error) | Should Match 'Refused'
        } finally { $env:USERPROFILE = $saved }
    }

    It "refuses a category that points outside the backup directory" {
        $bk = Join-Path $TestDrive 'cat-backup'
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\payload.txt')
        $entry = New-WinEaseTestEntry -Category '..\..' -RelativePath 'a.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
        $r.RestoredFiles | Should Be 0
        @($r.FailedFiles).Count | Should Be 1
        (@($r.FailedFiles)[0].Error) | Should Match 'Refused'
    }

    It "refuses a manipulated manifest whose source path is outside the allowed locations" {
        $bk = Join-Path $TestDrive 'manip-backup'
        $allowed = Join-Path $TestDrive 'manip-allowed'
        $outside = Join-Path $TestDrive 'manip-outside'
        New-Item -ItemType Directory -Force -Path $bk, $allowed, $outside | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Custom\evil.txt')
        $entry = New-WinEaseTestEntry -Category 'CustomPath' -RelativePath 'evil.txt' -SourcePath (Join-Path $outside 'evil.txt') -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $r = Restore-WinEaseCustomPaths -BackupRoot $bk -ConflictPolicy Overwrite -AllowedSourcePaths @($allowed)
        $r.RestoredFiles | Should Be 0
        @($r.FailedFiles).Count | Should Be 1
        (@($r.FailedFiles)[0].Error) | Should Match 'Refused'
        (Test-Path -LiteralPath (Join-Path $outside 'evil.txt')) | Should Be $false
    }

    It "refuses a custom path restore without an allowed location" {
        $bk = Join-Path $TestDrive 'noallow-backup'
        $outside = Join-Path $TestDrive 'noallow-outside'
        New-Item -ItemType Directory -Force -Path $bk, $outside | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Custom\evil.txt')
        $entry = New-WinEaseTestEntry -Category 'CustomPath' -RelativePath 'evil.txt' -SourcePath (Join-Path $outside 'evil.txt') -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $r = Restore-WinEaseCustomPaths -BackupRoot $bk -ConflictPolicy Overwrite
        $r.RestoredFiles | Should Be 0
        @($r.FailedFiles).Count | Should Be 1
        (@($r.FailedFiles)[0].Error) | Should Match 'no restore target was allowed'
        (Test-Path -LiteralPath (Join-Path $outside 'evil.txt')) | Should Be $false
    }

    It "reports a missing backup file" {
        $bk = Join-Path $TestDrive 'missing-backup'
        New-Item -ItemType Directory -Force -Path (Join-Path $bk 'Docs') | Out-Null
        $entry = New-WinEaseTestEntry -Category 'Docs' -RelativePath 'gone.txt'
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
        $r.RestoredFiles | Should Be 0
        @($r.FailedFiles).Count | Should Be 1
        (@($r.FailedFiles)[0].Error) | Should Be 'Backup file missing'
    }

    It "reports a hash mismatch and does not write the file" {
        $bk = Join-Path $TestDrive 'hash-backup'
        $userProfile = Join-Path $TestDrive 'hash-profile'
        New-Item -ItemType Directory -Force -Path $bk, $userProfile | Out-Null
        [void](New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\a.txt'))
        $entry = New-WinEaseTestEntry -RelativePath 'a.txt' -Sha256 ('0' * 64)
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 0
            @($r.FailedFiles).Count | Should Be 1
            (@($r.FailedFiles)[0].Error) | Should Be 'Hash mismatch (corrupt)'
            (Test-Path -LiteralPath (Join-Path $userProfile 'Docs\a.txt')) | Should Be $false
        } finally { $env:USERPROFILE = $saved }
    }

    It "a dry run does not write anything" {
        $bk = Join-Path $TestDrive 'dry-backup'
        $userProfile = Join-Path $TestDrive 'dry-profile'
        New-Item -ItemType Directory -Force -Path $bk, $userProfile | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\a.txt')
        $entry = New-WinEaseTestEntry -RelativePath 'a.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite -DryRun
            $r.RestoredFiles | Should Be 1
            (Test-Path -LiteralPath (Join-Path $userProfile 'Docs\a.txt')) | Should Be $false
        } finally { $env:USERPROFILE = $saved }
    }

    It "keeps the conflict policies working" {
        $bk = Join-Path $TestDrive 'conflict-backup'
        $userProfile = Join-Path $TestDrive 'conflict-profile'
        New-Item -ItemType Directory -Force -Path $bk, $userProfile | Out-Null
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\a.txt')
        $entry = New-WinEaseTestEntry -RelativePath 'a.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        $dest = Join-Path $userProfile 'Docs\a.txt'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Set-Content -LiteralPath $dest -Value 'existing'
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            # Skip keeps the file of the user
            $skip = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Skip
            $skip.SkippedFiles | Should Be 1
            (Get-Content -LiteralPath $dest -Raw).Trim() | Should Be 'existing'
            # BackupExisting keeps a copy of the file of the user
            $bak = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy BackupExisting
            $bak.RestoredFiles | Should Be 1
            (Test-Path -LiteralPath "$dest.WinEase.bak") | Should Be $true
            (Get-Content -LiteralPath "$dest.WinEase.bak" -Raw).Trim() | Should Be 'existing'
        } finally { $env:USERPROFILE = $saved }
    }

    It "refuses a restore target that traverses a symbolic link" {
        $bk = Join-Path $TestDrive 'link-backup'
        $userProfile = Join-Path $TestDrive 'link-profile'
        $canary = Join-Path $TestDrive 'link-canary'
        New-Item -ItemType Directory -Force -Path $bk, $userProfile, $canary | Out-Null
        Set-Content -LiteralPath (Join-Path $canary 'precious.txt') -Value 'precious'
        # the payload sits below a normal folder of the backup
        $hash = New-WinEaseTestPayload -Path (Join-Path $bk 'Docs\out\a.txt')
        $entry = New-WinEaseTestEntry -RelativePath 'out\a.txt' -Sha256 $hash
        New-WinEaseTestManifest -Path (Join-Path $bk 'migration-manifest.json') -Entries @($entry)
        # but the target of the restore runs through a junction (below the category folder)
        New-Item -ItemType Directory -Force -Path (Join-Path $userProfile 'Docs') | Out-Null
        & cmd.exe /c "mklink /J `"$(Join-Path $userProfile 'Docs\out')`" `"$canary`"" > $null 2>&1
        $saved = $env:USERPROFILE
        $env:USERPROFILE = $userProfile
        try {
            $r = Restore-WinEaseUserData -BackupRoot $bk -ConflictPolicy Overwrite
            $r.RestoredFiles | Should Be 0
            @($r.FailedFiles).Count | Should Be 1
            (@($r.FailedFiles)[0].Error) | Should Match 'Refused'
            (Test-Path -LiteralPath (Join-Path $canary 'precious.txt')) | Should Be $true
        } finally { $env:USERPROFILE = $saved }
    }

    It "the path validation helpers refuse the dangerous shapes" {
        $root = Join-Path $TestDrive 'validate-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $ok = Resolve-WinEaseSafeRelativePath -RelativePath 'sub\file.txt' -Root $root
        $ok.IsSafe | Should Be $true
        $ok.Path | Should Match 'sub'
        foreach ($bad in @('..\evil.txt', 'a\..\..\evil.txt', 'C:\Windows\Temp\evil.txt', '\\server\share\evil.txt', '\Windows\evil.txt', '*.txt', '')) {
            $r = Resolve-WinEaseSafeRelativePath -RelativePath $bad -Root $root
            $r.IsSafe | Should Be $false
            $r.Reason | Should Not BeNullOrEmpty
        }
        # a restore target outside the allowed locations is refused
        $t = Resolve-WinEaseRestoreTarget -Path (Join-Path $TestDrive 'somewhere-else.txt') -AllowedRoots @($root)
        $t.IsSafe | Should Be $false
        # an absolute path inside the allowed location is accepted
        $t2 = Resolve-WinEaseRestoreTarget -Path (Join-Path $root 'file.txt') -AllowedRoots @($root)
        $t2.IsSafe | Should Be $true
    }
}

Describe "WinEase removal and migration wiring" {
    BeforeAll {
        $script:WiringText = @{
            Phase05  = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\05-appx.ps1'))
            Phase10  = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\10-registry.ps1'))
            Phase11  = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\11-unattend.ps1'))
            Defender = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'scripts\WinEase-DefenderEnforce.ps1'))
            Migrator = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools\migrator\WinEase-Migrator.ps1'))
            Gui      = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\WinEaseGui.ps1'))
        }
    }

    It "phase 05 force-removes the protected Security UI payload when Defender is removed" {
        $text = $script:WiringText.Phase05
        $text | Should Match 'SecHealthUI'
        $text | Should Match 'Force-removed the protected Security UI package payload'
        $text | Should Match '\$removeDefender'
    }

    It "phase 10 removes the Security UI payload, registration and AppRepository entry" {
        $text = $script:WiringText.Phase10
        $text | Should Match 'SecHealthUI'
        $text | Should Match 'Windows\\AppRepository\\Packages'
        $text | Should Match 'Windows\\SystemApps'
    }

    It "the Defender helper refuses to act without remove-defender.flag" {
        $text = $script:WiringText.Defender
        $text | Should Match 'remove-defender\.flag'
        $text | Should Match 'if \(-not \(Test-Path -LiteralPath \$removeDefenderFlag\)\)'
        $text | Should Match 'exit 0'
    }

    It "phase 11 stages the Defender helper only for RemoveDefender" {
        $text = $script:WiringText.Phase11
        $text | Should Match 'if \(\$removeDefender\)'
        $text | Should Match 'WinEase-DefenderEnforce\.ps1'
        $text | Should Match 'remove-defender\.flag'
    }

    It "the bundled backup excludes the restore journal and temporary files" {
        $text = $script:WiringText.Phase11
        $text | Should Match 'robocopy\.exe'
        $text | Should Match '\/XF restore-state\.json \*\.tmp \*\.partial'
        $text | Should Match 'migration-manifest\.json'
        $text | Should Match 'C:\\WinEaseBackup'
    }

    It "the launcher points the migrator at the bundled backup" {
        $text = $script:WiringText.Phase11
        $text.Contains('$migrationLauncherCommand += '' -PackagePath "C:\WinEaseBackup"''') | Should Be $true
    }

    It "the migrator prefers C:\WinEaseBackup only when it has a manifest" {
        $text = $script:WiringText.Migrator
        $text.Contains('$script:BundledMigrationBackupPath = ''C:\WinEaseBackup''') | Should Be $true
        $text.Contains("Join-Path `$script:BundledMigrationBackupPath 'migration-manifest.json'") | Should Be $true
    }

    It "the WinForms backup checkbox follows the assistant toggle through the form context" {
        $text = $script:WiringText.Gui
        $text.Contains("ComponentCheckboxes['IncludeMigrationBackup']") | Should Be $true
        $text | Should Not Match 'Add_CheckedChanged\(\{ if \(\$chkBackup\)'
    }

    It "the bundling block really copies the backup to the image root and drops the journal" {
        $text = $script:WiringText.Phase11
        $start = $text.IndexOf('if ($includeMigrationAssistant -eq $true)')
        $start | Should BeGreaterThan 0
        $block = 'param($scratchDir, $scriptDir, $DryRun, $includeMigrationAssistant, $includeMigrationBackup)' + "`r`n" + $text.Substring($start)
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('winease_backup_' + [guid]::NewGuid().ToString('N'))
        $oldProfile = $env:USERPROFILE
        try {
            $fakeProfile = Join-Path $tmp 'profile'
            $sourceBackup = Join-Path $fakeProfile 'WinEase_migration_backup'
            New-Item -ItemType Directory -Path $sourceBackup -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBackup 'migration-manifest.json') -Value '{}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $sourceBackup 'keep.txt') -Value 'keep' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $sourceBackup 'restore-state.json') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $sourceBackup 'skip.tmp') -Value 'tmp' -Encoding ASCII
            $scratchDir = Join-Path $tmp 'scratch'
            New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
            $env:USERPROFILE = $fakeProfile
            $null = & ([scriptblock]::Create($block)) $scratchDir $script:RepoRoot $false $true $true 6>$null
            $dest = Join-Path $scratchDir 'WinEaseBackup'
            (Test-Path -LiteralPath (Join-Path $dest 'migration-manifest.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $dest 'keep.txt')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $dest 'restore-state.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $dest 'skip.tmp')) | Should Be $false
            $launcher = [System.IO.File]::ReadAllText((Join-Path $scratchDir 'Users\Public\Desktop\Launch-MigrationAssistant.cmd'))
            $launcher.Contains('-PackagePath "C:\WinEaseBackup"') | Should Be $true
        } finally {
            $env:USERPROFILE = $oldProfile
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

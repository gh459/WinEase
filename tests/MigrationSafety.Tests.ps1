# MigrationSafety.Tests.ps1 - backup/restore safety of the migration rules engine
# Run with:  Invoke-Pester -Path .\tests\MigrationSafety.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Covers: multi-source collisions, manifest path traversal, restore-time blacklist, default
# secret protection, single-file attribute/link checks, partial source loss, browser
# profiles, Known Folder re-resolution, restore while the application runs, and the
# cache-vs-settings exclusion scope. Every test builds its own sandbox below $TestDrive.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

if (-not (Get-Command -Name Test-WinEasePathWithin -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath 'WinEasehelpers.ps1')
}
if (-not (Get-Command -Name Invoke-WinEaseMigrationRulesBackup -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath 'tools\migrator\WinEaseMigration.ps1')
}

# A file symlink needs a privilege; the tests that need one are skipped (not passed) without it.
$script:CanSymlink = $false
try {
    $probeDir = Join-Path $env:TEMP ('winease-symprobe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    Set-Content -LiteralPath (Join-Path $probeDir 't.txt') -Value 'x'
    New-Item -ItemType SymbolicLink -Path (Join-Path $probeDir 'l.txt') -Target (Join-Path $probeDir 't.txt') -ErrorAction Stop | Out-Null
    $script:CanSymlink = $true
} catch { $script:CanSymlink = $false }
if ($probeDir -and (Test-Path -LiteralPath $probeDir)) { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }

Describe "Migration safety (rules backup/restore)" -Tags 'slow' {
    BeforeAll {
        $script:Builtin = Get-WinEaseMigrationRules
        function New-TestRules {
            param([hashtable[]]$App = @(), [hashtable[]]$Game = @())
            [PSCustomObject]@{
                GameRules = $Game; AppConfigRules = $App; CustomPathRules = @()
                SecretPatterns = @($script:Builtin.SecretPatterns)
                DefaultExcludePatterns = @($script:Builtin.DefaultExcludePatterns)
                Errors = @()
            }
        }
        function New-TestRule {
            param([string]$Id, [string[]]$Sources, [string[]]$Exclude = @(), [hashtable]$Extra = @{})
            $r = @{ Id = $Id; Name = $Id; Category = 'AppConfig'; SourcePaths = $Sources; ExcludePatterns = $Exclude; ProcessNames = @(); ExcludeSecrets = $true }
            foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
            return $r
        }
        function Write-TestFile {
            param([string]$Path, [string]$Content = 'x')
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllText($Path, $Content)
        }
        function Read-TestFile { param([string]$Path) return [System.IO.File]::ReadAllText($Path) }
        # Adds hand-written entries to the rule manifest of a finished backup (a tampered manifest)
        function Add-ManifestEntry {
            param([string]$Backup, [string]$RuleId, [object[]]$Entry)
            $p = Join-Path $Backup "rules\$RuleId\rule-manifest.json"
            $m = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            $m.Entries = @(@($m.Entries) + @($Entry))
            $m | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8
        }
        function New-Sandbox { param([string]$Name) $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory -Force -Path $d | Out-Null; return $d }
    }

    # ---------------------------------------------------------------- 2. multiple sources
    Context "[P1-2] same relative path in several SourcePaths" {
        It "keeps both files in the backup, records distinct backup paths and restores each to its own source" {
            $sb = New-Sandbox 'ms1'
            $a = Join-Path $sb 'A'; $b = Join-Path $sb 'B'
            Write-TestFile (Join-Path $a 'config\settings.json') 'source-A'
            Write-TestFile (Join-Path $b 'config\settings.json') 'source-B'
            $rules = New-TestRules -App @(New-TestRule -Id 'Dup' -Sources @($a, $b))
            $bk = Join-Path $sb 'bk'
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('Dup') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            $r.CopiedFiles | Should Be 2
            @($r.FailedFiles).Count | Should Be 0
            $ruleDir = Join-Path $bk 'rules\Dup'
            $contents = @(Get-ChildItem -LiteralPath $ruleDir -Recurse -File | Where-Object { $_.Name -eq 'settings.json' } | ForEach-Object { Read-TestFile $_.FullName } | Sort-Object)
            ($contents -join ',') | Should Be 'source-A,source-B'
            $m = Get-Content -LiteralPath (Join-Path $ruleDir 'rule-manifest.json') -Raw | ConvertFrom-Json
            @($m.Entries | ForEach-Object { $_.BackupPath } | Select-Object -Unique).Count | Should Be 2
            @($m.Entries | ForEach-Object { $_.SourcePath } | Select-Object -Unique).Count | Should Be 2
            foreach ($e in @($m.Entries)) { $e.Sha256 | Should Match '^[0-9A-F]{64}$' }
            @($r.DuplicateFiles).Count | Should Be 1
            Remove-Item -LiteralPath $a, $b -Recurse -Force
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Dup') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            @($rr.FailedFiles).Count | Should Be 0
            $rr.RestoredFiles | Should Be 2
            Read-TestFile (Join-Path $a 'config\settings.json') | Should Be 'source-A'
            Read-TestFile (Join-Path $b 'config\settings.json') | Should Be 'source-B'
        }
        It "still restores a backup written by the previous (flat) layout" {
            $sb = New-Sandbox 'ms2'
            $a = Join-Path $sb 'A'
            $rules = New-TestRules -App @(New-TestRule -Id 'Flat' -Sources @($a))
            $bk = Join-Path $sb 'bk'
            Write-TestFile (Join-Path $bk 'rules\Flat\sub\old.txt') 'legacy'
            $h = (Get-FileHash -LiteralPath (Join-Path $bk 'rules\Flat\sub\old.txt') -Algorithm SHA256).Hash
            [PSCustomObject]@{ Id = 'Flat'; Entries = @([PSCustomObject]@{ RelativePath = 'sub\old.txt'; SourcePath = $a; Sha256 = $h }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $bk 'rules\Flat\rule-manifest.json') -Encoding UTF8
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Flat') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            @($rr.FailedFiles).Count | Should Be 0
            Read-TestFile (Join-Path $a 'sub\old.txt') | Should Be 'legacy'
        }
    }

    # ---------------------------------------------------------------- 3. traversal
    Context "[P1-3] tampered rule manifest" {
        $bad = @(
            '..\outside.txt', 'subdir\..\..\outside.txt', 'C:\outside.txt', '\\server\share\outside.txt',
            '/outside.txt', 'C:outside.txt', '..\..\..\..\bk-evil\evil.txt', 'a\b:c.txt'
        )
        foreach ($badPath in $bad) {
            It "rejects BackupPath '$badPath' without reading or writing outside" {
                $sb = New-Sandbox ('tr_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                $src = Join-Path $sb 'src'
                Write-TestFile (Join-Path $src 'good.txt') 'good'
                $rules = New-TestRules -App @(New-TestRule -Id 'Trav' -Sources @($src))
                $bk = Join-Path $sb 'bk'
                Invoke-WinEaseMigrationRulesBackup -RuleIds @('Trav') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
                Write-TestFile (Join-Path $sb 'outside.txt') 'OUTSIDE-SECRET'
                Write-TestFile (Join-Path $sb 'bk-evil\evil.txt') 'OUTSIDE-SECRET'
                Add-ManifestEntry -Backup $bk -RuleId 'Trav' -Entry ([PSCustomObject]@{ RelativePath = 'x.txt'; BackupPath = $badPath; SourceId = 'source-001'; SourcePath = $src; Sha256 = '' })
                Remove-Item -LiteralPath (Join-Path $src 'good.txt') -Force
                $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Trav') -BackupRoot $bk -Rules $rules -ForceRunningProcess
                $rr.RestoredFiles | Should Be 1
                Read-TestFile (Join-Path $src 'good.txt') | Should Be 'good'
                @($rr.FailedFiles).Count | Should Be 1
                $rr.FailedFiles[0].Error | Should Match '^Refused'
                $rr.FailedFiles[0].Rule | Should Be 'Trav'
                (@(Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object { Read-TestFile $_.FullName }) -contains 'OUTSIDE-SECRET') | Should Be $false
                $rr.Status | Should Not Be 'Success'
            }
        }
        It "rejects a RelativePath that climbs out of the source and does not create the file next to it" {
            $sb = New-Sandbox 'tr_dest'
            $src = Join-Path $sb 'src'
            Write-TestFile (Join-Path $src 'good.txt') 'good'
            $rules = New-TestRules -App @(New-TestRule -Id 'TravD' -Sources @($src))
            $bk = Join-Path $sb 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @('TravD') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
            Add-ManifestEntry -Backup $bk -RuleId 'TravD' -Entry ([PSCustomObject]@{ RelativePath = '..\escape.txt'; BackupPath = 'source-001\good.txt'; SourceId = 'source-001'; SourcePath = $src; Sha256 = '' })
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('TravD') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            Test-Path -LiteralPath (Join-Path $sb 'escape.txt') | Should Be $false
            (@($rr.FailedFiles | Where-Object { $_.Error -match '^Refused' }).Count) | Should Be 1
        }
        It "ignores a manifest SourcePath outside the rule and restores to the rule's own location" {
            $sb = New-Sandbox 'tr_srcpath'
            $src = Join-Path $sb 'src'; $evil = Join-Path $sb 'evil'
            Write-TestFile (Join-Path $src 'a.txt') 'A'
            $rules = New-TestRules -App @(New-TestRule -Id 'TravS' -Sources @($src))
            $bk = Join-Path $sb 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @('TravS') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
            $p = Join-Path $bk 'rules\TravS\rule-manifest.json'
            $m = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            foreach ($e in @($m.Entries)) { $e.SourcePath = $evil }
            $m | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8
            Remove-Item -LiteralPath (Join-Path $src 'a.txt') -Force
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('TravS') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            Test-Path -LiteralPath $evil | Should Be $false
            Test-Path -LiteralPath (Join-Path $src 'a.txt') | Should Be $true
        }
        It "rejects a backup path that goes through a junction out of the backup" {
            $sb = New-Sandbox 'tr_junc'
            $src = Join-Path $sb 'src'
            Write-TestFile (Join-Path $src 'good.txt') 'good'
            $rules = New-TestRules -App @(New-TestRule -Id 'TravJ' -Sources @($src))
            $bk = Join-Path $sb 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @('TravJ') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
            $outside = Join-Path $sb 'outside'
            Write-TestFile (Join-Path $outside 'secret.txt') 'OUTSIDE-SECRET'
            cmd /c mklink /J (Join-Path $bk 'rules\TravJ\junc') $outside | Out-Null
            Add-ManifestEntry -Backup $bk -RuleId 'TravJ' -Entry ([PSCustomObject]@{ RelativePath = 'secret.txt'; BackupPath = 'junc\secret.txt'; SourceId = 'source-001'; SourcePath = $src; Sha256 = '' })
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('TravJ') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            Test-Path -LiteralPath (Join-Path $src 'secret.txt') | Should Be $false
            (@($rr.FailedFiles | Where-Object { $_.Path -like '*secret.txt' -and $_.Error -match '^Refused' }).Count) | Should Be 1
            cmd /c rmdir (Join-Path $bk 'rules\TravJ\junc') | Out-Null
        }
    }

    # ---------------------------------------------------------------- 4. restore blacklist
    Context "[P1-4] blacklist is applied again at restore" {
        function New-TamperedBackup {
            param([string]$Sandbox)
            $src = Join-Path $Sandbox 'app'
            Write-TestFile (Join-Path $src 'seed.txt') 'seed'
            $rules = New-TestRules -App @(New-TestRule -Id 'Black' -Sources @($src))
            $bk = Join-Path $Sandbox 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @('Black') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
            $files = [ordered]@{ 'Cache\data.bin' = 'c'; 'app.log' = 'l'; 'LOCK' = 'k'; 'database.sqlite-wal' = 'w'; 'Cookies' = 'ck'; 'id_rsa' = 'key'; 'normal-settings.json' = 'ok' }
            $entries = @()
            foreach ($rel in $files.Keys) {
                $bp = "source-001\$rel"
                Write-TestFile (Join-Path $bk "rules\Black\$bp") $files[$rel]
                $h = (Get-FileHash -LiteralPath (Join-Path $bk "rules\Black\$bp") -Algorithm SHA256).Hash
                $entries += [PSCustomObject]@{ RelativePath = $rel; BackupPath = $bp; SourceId = 'source-001'; SourcePath = $src; Sha256 = $h }
            }
            Add-ManifestEntry -Backup $bk -RuleId 'Black' -Entry $entries
            Remove-Item -LiteralPath (Join-Path $src 'seed.txt') -Force
            return @{ Src = $src; Bk = $bk; Rules = $rules }
        }
        It "restores only the normal setting and reports every excluded file with its reason" {
            $t = New-TamperedBackup -Sandbox (New-Sandbox 'bl1')
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Black') -BackupRoot $t.Bk -Rules $t.Rules -ForceRunningProcess
            Test-Path -LiteralPath (Join-Path $t.Src 'normal-settings.json') | Should Be $true
            foreach ($n in @('Cache\data.bin', 'app.log', 'LOCK', 'database.sqlite-wal', 'Cookies', 'id_rsa')) {
                Test-Path -LiteralPath (Join-Path $t.Src $n) | Should Be $false
            }
            @($rr.ExcludedFiles).Count | Should Be 6
            foreach ($x in @($rr.ExcludedFiles)) { $x.Reason | Should Not BeNullOrEmpty }
            $rr.Status | Should Be 'PartialSuccess'
        }
        It "restores secrets only with -IncludeSecrets and never the cache/lock/log files" {
            $t = New-TamperedBackup -Sandbox (New-Sandbox 'bl2')
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Black') -BackupRoot $t.Bk -Rules $t.Rules -ForceRunningProcess -IncludeSecrets
            Test-Path -LiteralPath (Join-Path $t.Src 'Cookies') | Should Be $true
            Test-Path -LiteralPath (Join-Path $t.Src 'id_rsa') | Should Be $true
            foreach ($n in @('Cache\data.bin', 'app.log', 'LOCK', 'database.sqlite-wal')) { Test-Path -LiteralPath (Join-Path $t.Src $n) | Should Be $false }
            @($rr.ExcludedFiles).Count | Should Be 4
        }
        It "applies the built-in policy even when the caller's rule set carries no patterns" {
            $t = New-TamperedBackup -Sandbox (New-Sandbox 'bl3')
            $bare = [PSCustomObject]@{ GameRules = @(); AppConfigRules = @(New-TestRule -Id 'Black' -Sources @($t.Src)); CustomPathRules = @(); Errors = @() }
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Black') -BackupRoot $t.Bk -Rules $bare -ForceRunningProcess
            Test-Path -LiteralPath (Join-Path $t.Src 'id_rsa') | Should Be $false
            Test-Path -LiteralPath (Join-Path $t.Src 'Cache\data.bin') | Should Be $false
            Test-Path -LiteralPath (Join-Path $t.Src 'normal-settings.json') | Should Be $true
        }
    }

    # ---------------------------------------------------------------- 5. game secrets
    Context "[P1-5] secrets are excluded by default for every rule" {
        foreach ($variant in @('GameNoFlag', 'AppFlagFalse')) {
            It "excludes secret files for a rule without protection flag ($variant)" {
                $sb = New-Sandbox ('sec_' + $variant)
                $src = Join-Path $sb 'saves'
                Write-TestFile (Join-Path $src 'slot1.sav') 'save'
                Write-TestFile (Join-Path $src 'Cookies') 'cookie'
                Write-TestFile (Join-Path $src 'token.json') 'tok'
                Write-TestFile (Join-Path $src 'id_ed25519') 'key'
                if ($variant -eq 'GameNoFlag') {
                    $rules = New-TestRules -Game @(@{ Id = 'G1'; Name = 'G1'; Category = 'GameSave'; SourcePaths = @($src); ExcludePatterns = @(); ProcessNames = @() })
                } else {
                    $rules = New-TestRules -Game @(@{ Id = 'G1'; Name = 'G1'; Category = 'GameSave'; SourcePaths = @($src); ExcludePatterns = @(); ProcessNames = @(); ExcludeSecrets = $false })
                }
                $bk = Join-Path $sb 'bk'
                $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('G1') -BackupRoot $bk -Rules $rules -ForceRunningProcess
                $r.CopiedFiles | Should Be 1
                $r.SecretExcludedFiles | Should Be 3
                $names = @(Get-ChildItem -LiteralPath (Join-Path $bk 'rules\G1') -Recurse -File | ForEach-Object Name)
                ($names -contains 'slot1.sav') | Should Be $true
                ($names -contains 'Cookies') | Should Be $false
                ($names -contains 'token.json') | Should Be $false
                ($names -contains 'id_ed25519') | Should Be $false
                @($r.ExcludedFiles | Where-Object { $_.Kind -eq 'Secret' }).Count | Should Be 3
                (@($r.SkipReasons | Where-Object { $_.Reason -match 'Secret' }).Count) | Should BeGreaterThan 0
            }
        }
        It "includes secrets only with the explicit -IncludeSecrets switch" {
            $sb = New-Sandbox 'sec_inc'
            $src = Join-Path $sb 'saves'
            Write-TestFile (Join-Path $src 'slot1.sav') 'save'
            Write-TestFile (Join-Path $src 'token.json') 'tok'
            $rules = New-TestRules -Game @(@{ Id = 'G2'; Name = 'G2'; Category = 'GameSave'; SourcePaths = @($src); ExcludePatterns = @(); ProcessNames = @() })
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('G2') -BackupRoot (Join-Path $sb 'bk') -Rules $rules -ForceRunningProcess -IncludeSecrets
            $r.CopiedFiles | Should Be 2
            $r.SecretExcludedFiles | Should Be 0
        }
    }

    # ---------------------------------------------------------------- 6. single files
    Context "[P1-6] a single file given as SourcePaths gets the same checks as a folder walk" {
        It "skips Hidden and System files with a reason and backs up the normal file" {
            $sb = New-Sandbox 'sf1'
            $normal = Join-Path $sb 'normal.cfg'; $hid = Join-Path $sb 'hidden.cfg'; $sys = Join-Path $sb 'system.cfg'
            foreach ($f in @($normal, $hid, $sys)) { Write-TestFile $f 'v' }
            (Get-Item -LiteralPath $hid -Force).Attributes = 'Hidden'
            (Get-Item -LiteralPath $sys -Force).Attributes = 'System'
            $rules = New-TestRules -App @(
                (New-TestRule -Id 'F-normal' -Sources @($normal)),
                (New-TestRule -Id 'F-hidden' -Sources @($hid)),
                (New-TestRule -Id 'F-system' -Sources @($sys))
            )
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('F-normal', 'F-hidden', 'F-system') -BackupRoot (Join-Path $sb 'bk') -Rules $rules -ForceRunningProcess
            $r.CopiedFiles | Should Be 1
            @($r.BackedUpRules).Count | Should Be 1
            @($r.ExcludedFiles | Where-Object { $_.Kind -eq 'Attribute' }).Count | Should Be 2
            Test-Path -LiteralPath (Join-Path $sb 'bk\rules\F-hidden\source-001\hidden.cfg') | Should Be $false
            (Get-Item -LiteralPath $hid -Force).Attributes = 'Normal'
            (Get-Item -LiteralPath $sys -Force).Attributes = 'Normal'
        }
        It "does not copy through a file symbolic link" -Skip:(-not $script:CanSymlink) {
            $sb = New-Sandbox 'sf2'
            $target = Join-Path $sb 'outside-secret.txt'
            Write-TestFile $target 'OUTSIDE-SECRET'
            $link = Join-Path $sb 'link.cfg'
            New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
            $rules = New-TestRules -App @(New-TestRule -Id 'F-link' -Sources @($link))
            $bk = Join-Path $sb 'bk'
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('F-link') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            $r.CopiedFiles | Should Be 0
            (@(Get-ChildItem -LiteralPath $bk -Recurse -File -ErrorAction SilentlyContinue | Where-Object { (Read-TestFile $_.FullName) -eq 'OUTSIDE-SECRET' }).Count) | Should Be 0
            @($r.ExcludedFiles | Where-Object { $_.Kind -eq 'Attribute' }).Count | Should Be 1
        }
    }

    # ---------------------------------------------------------------- 7. partial sources
    Context "[P1-7] missing sources and copy failures are reported, not hidden" {
        It "reports a missing source of three as a partial success" {
            $sb = New-Sandbox 'ps1'
            $a = Join-Path $sb 'A'; $b = Join-Path $sb 'B'; $c = Join-Path $sb 'C-missing'
            Write-TestFile (Join-Path $a 'a.txt') 'a'; Write-TestFile (Join-Path $b 'b.txt') 'b'
            $rules = New-TestRules -App @(New-TestRule -Id 'Part' -Sources @($a, $b, $c))
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('Part') -BackupRoot (Join-Path $sb 'bk') -Rules $rules -ForceRunningProcess
            $r.CopiedFiles | Should Be 2
            @($r.MissingSources).Count | Should Be 1
            $r.MissingSources[0].Path | Should Be $c
            @($r.FailedFiles).Count | Should Be 0
            $r.Status | Should Be 'PartialSuccess'
            $r.Success | Should Be $false
            $r.BackedUpRules[0].Status | Should Be 'PartialSuccess'
            $o = Get-WinEaseMigrationOutcome -RulesResult $r
            $o.Success | Should Be $false
            $o.Status | Should Be 'PartialSuccess'
            $o.Message | Should Match 'C-missing'
        }
        It "reports every source missing as failed" {
            $sb = New-Sandbox 'ps2'
            $rules = New-TestRules -App @(New-TestRule -Id 'None' -Sources @((Join-Path $sb 'x'), (Join-Path $sb 'y')))
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('None') -BackupRoot (Join-Path $sb 'bk') -Rules $rules -ForceRunningProcess
            $r.CopiedFiles | Should Be 0
            @($r.MissingSources).Count | Should Be 2
            $r.Status | Should Be 'Failed'
            $r.Success | Should Be $false
            (Get-WinEaseMigrationOutcome -RulesResult $r).Success | Should Be $false
        }
        It "reports a file that cannot be read as a copy failure, distinct from a missing source" {
            $sb = New-Sandbox 'ps3'
            $a = Join-Path $sb 'A'
            Write-TestFile (Join-Path $a 'ok.txt') 'ok'
            Write-TestFile (Join-Path $a 'locked.txt') 'locked'
            $rules = New-TestRules -App @(New-TestRule -Id 'Lock' -Sources @($a))
            $fs = [System.IO.File]::Open((Join-Path $a 'locked.txt'), 'Open', 'ReadWrite', 'None')
            try {
                $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('Lock') -BackupRoot (Join-Path $sb 'bk') -Rules $rules -ForceRunningProcess
            } finally { $fs.Dispose() }
            $r.CopiedFiles | Should Be 1
            @($r.FailedFiles).Count | Should Be 1
            $r.FailedFiles[0].Rule | Should Be 'Lock'
            @($r.MissingSources).Count | Should Be 0
            $r.Status | Should Be 'PartialSuccess'
            $r.Success | Should Be $false
        }
        It "reports a clean backup as Success" {
            $sb = New-Sandbox 'ps4'
            $a = Join-Path $sb 'A'
            Write-TestFile (Join-Path $a 'a.txt') 'a'
            $rules = New-TestRules -App @(New-TestRule -Id 'Clean' -Sources @($a))
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('Clean') -BackupRoot (Join-Path $sb 'bk') -Rules $rules -ForceRunningProcess
            $r.Status | Should Be 'Success'
            $r.Success | Should Be $true
            (Get-WinEaseMigrationOutcome -RulesResult $r).Success | Should Be $true
        }
    }

    # ---------------------------------------------------------------- 8. browser profiles
    Context "[P2-8] browser profiles" {
        It "backs up and restores Default and Profile 1 side by side" {
            $sb = New-Sandbox 'br1'
            $ud = Join-Path $sb 'User Data'
            Write-TestFile (Join-Path $ud 'Default\Bookmarks') 'bm-default'
            Write-TestFile (Join-Path $ud 'Default\Preferences') 'pr-default'
            Write-TestFile (Join-Path $ud 'Profile 1\Bookmarks') 'bm-p1'
            Write-TestFile (Join-Path $ud 'Profile 1\Preferences') 'pr-p1'
            Write-TestFile (Join-Path $ud 'Profile 1\Cookies') 'COOKIE'
            Write-TestFile (Join-Path $ud 'Profile 2\Preferences') 'pr-p2'
            $rule = New-TestRule -Id 'Br' -Sources @((Join-Path $ud 'Default\Bookmarks'), (Join-Path $ud 'Default\Preferences')) -Exclude @('*Login Data*', '*Cookies*') -Extra @{ ProfileRoot = $ud; ProfilePatterns = @('Profile *'); ProfileFiles = @('Bookmarks', 'Preferences') }
            $rules = New-TestRules -App @($rule)
            $bk = Join-Path $sb 'bk'
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('Br') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            $r.CopiedFiles | Should Be 5
            @($r.MissingSources).Count | Should Be 0
            @($r.FailedFiles).Count | Should Be 0
            (@(Get-ChildItem -LiteralPath $bk -Recurse -File | Where-Object { $_.Name -eq 'Cookies' }).Count) | Should Be 0
            Remove-Item -LiteralPath (Join-Path $ud 'Default'), (Join-Path $ud 'Profile 1'), (Join-Path $ud 'Profile 2') -Recurse -Force
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Br') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            @($rr.FailedFiles).Count | Should Be 0
            Read-TestFile (Join-Path $ud 'Default\Bookmarks') | Should Be 'bm-default'
            Read-TestFile (Join-Path $ud 'Profile 1\Bookmarks') | Should Be 'bm-p1'
            Read-TestFile (Join-Path $ud 'Profile 1\Preferences') | Should Be 'pr-p1'
            Read-TestFile (Join-Path $ud 'Profile 2\Preferences') | Should Be 'pr-p2'
            Test-Path -LiteralPath (Join-Path $ud 'Profile 1\Cookies') | Should Be $false
        }
        It "works without extra profiles and does not report a false success without any profile" {
            $sb = New-Sandbox 'br2'
            $ud = Join-Path $sb 'User Data'
            Write-TestFile (Join-Path $ud 'Default\Bookmarks') 'bm'
            $rule = New-TestRule -Id 'BrOne' -Sources @((Join-Path $ud 'Default\Bookmarks')) -Extra @{ ProfileRoot = $ud; ProfilePatterns = @('Profile *'); ProfileFiles = @('Bookmarks') }
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('BrOne') -BackupRoot (Join-Path $sb 'bk') -Rules (New-TestRules -App @($rule)) -ForceRunningProcess
            $r.CopiedFiles | Should Be 1
            $r.Status | Should Be 'Success'
            $empty = Join-Path $sb 'Empty Data'
            $rule2 = New-TestRule -Id 'BrNone' -Sources @((Join-Path $empty 'Default\Bookmarks')) -Extra @{ ProfileRoot = $empty; ProfilePatterns = @('Profile *'); ProfileFiles = @('Bookmarks') }
            $r2 = Invoke-WinEaseMigrationRulesBackup -RuleIds @('BrNone') -BackupRoot (Join-Path $sb 'bk2') -Rules (New-TestRules -App @($rule2)) -ForceRunningProcess
            $r2.Status | Should Be 'Failed'
        }
        It "declares profile discovery for Chrome, Edge, Brave and Brave Origin and keeps their secret exclusions" {
            $rules = Get-WinEaseMigrationRules
            foreach ($id in @('ChromeSettings', 'EdgeSettings', 'BraveSettings', 'BraveOriginSettings')) {
                $rule = @($rules.AppConfigRules | Where-Object { $_.Id -eq $id })[0]
                $rule.ProfileRoot | Should Match 'User Data$'
                @($rule.ProfileFiles) -contains 'Bookmarks' | Should Be $true
                (@($rule.ExcludePatterns) -join ' ') | Should Match 'Cookies'
            }
        }
    }

    # ---------------------------------------------------------------- 9. known folders
    Context "[P2-9] Known Folder restore uses the destination profile" {
        BeforeEach {
            $script:SavedProfile = $env:USERPROFILE
        }
        AfterEach {
            $env:USERPROFILE = $script:SavedProfile
        }
        It "resolves %MYDOCUMENTS% on the restoring machine and never writes to the old profile" {
            $sb = New-Sandbox 'kf1'
            $oldProfile = Join-Path $sb 'OldUser'; $newProfile = Join-Path $sb 'NewUser'
            New-Item -ItemType Directory -Force -Path (Join-Path $oldProfile 'Documents'), (Join-Path $newProfile 'Documents') | Out-Null
            $rules = New-TestRules -Game @(@{ Id = 'KF'; Name = 'KF'; Category = 'GameSave'; SourcePaths = @('%MYDOCUMENTS%\KfGame'); ExcludePatterns = @(); ProcessNames = @() })
            $env:USERPROFILE = $oldProfile
            Write-TestFile (Join-Path $oldProfile 'Documents\KfGame\save.dat') 'progress'
            $bk = Join-Path $sb 'bk'
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('KF') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            $r.CopiedFiles | Should Be 1
            # a manifest written with the OLD machine's absolute path must not steer the restore
            $p = Join-Path $bk 'rules\KF\rule-manifest.json'
            $m = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            foreach ($e in @($m.Entries)) { $e.SourcePath = Join-Path $oldProfile 'Documents\KfGame' }
            $m | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8
            Remove-Item -LiteralPath (Join-Path $oldProfile 'Documents\KfGame') -Recurse -Force
            $env:USERPROFILE = $newProfile
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('KF') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            @($rr.FailedFiles).Count | Should Be 0
            Read-TestFile (Join-Path $newProfile 'Documents\KfGame\save.dat') | Should Be 'progress'
            Test-Path -LiteralPath (Join-Path $oldProfile 'Documents\KfGame') | Should Be $false
        }
        It "restores a personal folder category into the Known Folder of the destination profile" {
            $sb = New-Sandbox 'kf2'
            $oldProfile = Join-Path $sb 'OldUser'; $newProfile = Join-Path $sb 'NewUser'
            New-Item -ItemType Directory -Force -Path (Join-Path $oldProfile 'Documents'), (Join-Path $newProfile 'Documents') | Out-Null
            Write-TestFile (Join-Path $oldProfile 'Documents\note.txt') 'note'
            $env:USERPROFILE = $oldProfile
            $bk = Join-Path $sb 'bk'
            Backup-WinEaseUserData -FolderMap @{ Documents = (Join-Path $oldProfile 'Documents') } -BackupRoot $bk | Out-Null
            Remove-Item -LiteralPath (Join-Path $oldProfile 'Documents\note.txt') -Force
            $env:USERPROFILE = $newProfile
            $rr = Restore-WinEaseUserData -BackupRoot $bk
            @($rr.FailedFiles).Count | Should Be 0
            Read-TestFile (Join-Path $newProfile 'Documents\note.txt') | Should Be 'note'
            Test-Path -LiteralPath (Join-Path $oldProfile 'Documents\note.txt') | Should Be $false
        }
        It "refuses an arbitrary absolute path posing as a Known Folder category" {
            $sb = New-Sandbox 'kf3'
            $profile = Join-Path $sb 'User'
            New-Item -ItemType Directory -Force -Path (Join-Path $profile 'Documents') | Out-Null
            $env:USERPROFILE = $profile
            $bk = Join-Path $sb 'bk'
            Write-TestFile (Join-Path $bk 'C__evil\a.txt') 'a'
            [PSCustomObject]@{ Entries = @([PSCustomObject]@{ RelativePath = 'a.txt'; Category = 'C:\evil'; Sha256 = '' }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $bk 'migration-manifest.json') -Encoding UTF8
            $rr = Restore-WinEaseUserData -BackupRoot $bk
            $rr.RestoredFiles | Should Be 0
            @($rr.FailedFiles).Count | Should Be 1
        }
    }

    Context "[P2-10a] real process lookup (no mocks)" {
        It "treats a process that is really not running (real Get-Process) as not running" {
            $sb = New-Sandbox 'run0'
            $src = Join-Path $sb 'app'
            Write-TestFile (Join-Path $src 'settings.json') 'from-backup'
            $rules = New-TestRules -App @(New-TestRule -Id 'RunReal' -Sources @($src) -Extra @{ ProcessNames = @('winease-no-such-process-zz9') })
            $bk = Join-Path $sb 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @('RunReal') -BackupRoot $bk -Rules $rules | Out-Null
            Write-TestFile (Join-Path $src 'settings.json') 'live'
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('RunReal') -BackupRoot $bk -Rules $rules -ConflictPolicy Overwrite
            @($rr.FailedFiles).Count | Should Be 0
            Read-TestFile (Join-Path $src 'settings.json') | Should Be 'from-backup'
        }
    }

    # ---------------------------------------------------------------- 10. running application
    Context "[P2-10] restore while the application is running" {
        function New-RunningBackup {
            param([string]$Sandbox, [string]$Id)
            $src = Join-Path $Sandbox 'app'
            Write-TestFile (Join-Path $src 'settings.json') 'from-backup'
            $rule = New-TestRule -Id $Id -Sources @($src) -Extra @{ ProcessNames = @('winease-fake-app') }
            $rules = New-TestRules -App @($rule)
            $bk = Join-Path $Sandbox 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @($Id) -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
            Write-TestFile (Join-Path $src 'settings.json') 'live-settings'
            return @{ Src = $src; Bk = $bk; Rules = $rules }
        }
        It "leaves the files alone, marks the failure retryable and restores after the app closed" {
            $t = New-RunningBackup -Sandbox (New-Sandbox 'run1') -Id 'RunApp'
            Mock Get-Process { [PSCustomObject]@{ Name = 'winease-fake-app' } } -ParameterFilter { $Name -eq 'winease-fake-app' }
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('RunApp') -BackupRoot $t.Bk -Rules $t.Rules
            Read-TestFile (Join-Path $t.Src 'settings.json') | Should Be 'live-settings'
            $rr.RestoredFiles | Should Be 0
            @($rr.FailedFiles).Count | Should Be 1
            $rr.FailedFiles[0].Kind | Should Be 'ApplicationRunning'
            $rr.FailedFiles[0].Retryable | Should Be $true
            $rr.Status | Should Be 'Failed'
            Mock Get-Process { $null } -ParameterFilter { $Name -eq 'winease-fake-app' }
            $again = Invoke-WinEaseMigrationRulesRestore -RuleIds @('RunApp') -BackupRoot $t.Bk -Rules $t.Rules -ConflictPolicy Overwrite
            @($again.FailedFiles).Count | Should Be 0
            Read-TestFile (Join-Path $t.Src 'settings.json') | Should Be 'from-backup'
            $again.Status | Should Be 'Success'
        }
        It "does not treat an unknown process state as safe" {
            $t = New-RunningBackup -Sandbox (New-Sandbox 'run2') -Id 'RunApp2'
            Mock Get-Process { throw 'Access is denied' } -ParameterFilter { $Name -eq 'winease-fake-app' }
            Mock Get-Process { throw 'Access is denied' }
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('RunApp2') -BackupRoot $t.Bk -Rules $t.Rules -ConflictPolicy Overwrite
            Read-TestFile (Join-Path $t.Src 'settings.json') | Should Be 'live-settings'
            $rr.FailedFiles[0].Kind | Should Be 'ProcessCheckFailed'
            $rr.Status | Should Be 'Failed'
        }
        It "does not close a process unasked and reports processes that refuse to close" {
            $t = New-RunningBackup -Sandbox (New-Sandbox 'run3') -Id 'RunApp3'
            Mock Get-Process { [PSCustomObject]@{ Name = 'winease-fake-app' } } -ParameterFilter { $Name -eq 'winease-fake-app' }
            Mock Stop-WinEaseMigrationProcess { return @('winease-fake-app') }
            $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('RunApp3') -BackupRoot $t.Bk -Rules $t.Rules -ConflictPolicy Overwrite
            Assert-MockCalled Stop-WinEaseMigrationProcess -Times 0
            $rr2 = Invoke-WinEaseMigrationRulesRestore -RuleIds @('RunApp3') -BackupRoot $t.Bk -Rules $t.Rules -ConflictPolicy Overwrite -StopRunningProcess
            Assert-MockCalled Stop-WinEaseMigrationProcess -Times 1
            $rr2.FailedFiles[0].Kind | Should Be 'ApplicationRunning'
            Read-TestFile (Join-Path $t.Src 'settings.json') | Should Be 'live-settings'
        }
        It "keeps a locked file intact, reports it as retryable and still restores the others" {
            $sb = New-Sandbox 'run4'
            $src = Join-Path $sb 'app'
            Write-TestFile (Join-Path $src 'a.json') 'bk-a'
            Write-TestFile (Join-Path $src 'b.json') 'bk-b'
            $rules = New-TestRules -App @(New-TestRule -Id 'Locked' -Sources @($src))
            $bk = Join-Path $sb 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @('Locked') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
            Write-TestFile (Join-Path $src 'a.json') 'live-a'
            Write-TestFile (Join-Path $src 'b.json') 'live-b'
            $fs = [System.IO.File]::Open((Join-Path $src 'a.json'), 'Open', 'Read', 'None')
            try {
                $rr = Invoke-WinEaseMigrationRulesRestore -RuleIds @('Locked') -BackupRoot $bk -Rules $rules -ForceRunningProcess -ConflictPolicy Overwrite
            } finally { $fs.Dispose() }
            Read-TestFile (Join-Path $src 'a.json') | Should Be 'live-a'
            Read-TestFile (Join-Path $src 'b.json') | Should Be 'bk-b'
            $rr.RestoredFiles | Should Be 1
            @($rr.FailedFiles).Count | Should Be 1
            $rr.FailedFiles[0].Retryable | Should Be $true
            $rr.Status | Should Be 'PartialSuccess'
            (Test-Path -LiteralPath (Join-Path $src 'a.json.WinEase.tmp')) | Should Be $false
        }
    }

    # ---------------------------------------------------------------- 11. cache vs settings
    Context "[P2-11] exclusion scope" {
        It "drops caches, logs and locks but keeps settings and user data with similar names" {
            $sb = New-Sandbox 'ex1'
            $src = Join-Path $sb 'app'
            $keep = @('settings.json', 'cache.json', 'Cachefoo\data.txt', 'logs.json', 'saves\world1\level.dat', 'Config\app.log.bak', 'my.lockfile.json', 'Profiles\user.cfg')
            $drop = @('Cache\x.bin', 'CACHE\y.bin', 'GPUCache\g.bin', 'logs\a.txt', 'app.lock', 'debug.log', 'Default\LOCK', 'db.sqlite-wal', 'db.sqlite-shm')
            foreach ($k in ($keep + $drop)) { Write-TestFile (Join-Path $src $k) 'data' }
            $rules = New-TestRules -App @(New-TestRule -Id 'Scope' -Sources @($src))
            $bk = Join-Path $sb 'bk'
            $r = Invoke-WinEaseMigrationRulesBackup -RuleIds @('Scope') -BackupRoot $bk -Rules $rules -ForceRunningProcess
            $got = @(Get-ChildItem -LiteralPath (Join-Path $bk 'rules\Scope\source-001') -Recurse -File | ForEach-Object { $_.FullName.Substring((Join-Path $bk 'rules\Scope\source-001').Length + 1) })
            foreach ($k in $keep) { ($got -contains $k) | Should Be $true }
            foreach ($d in $drop) { ($got -contains $d) | Should Be $false }
            $r.CopiedFiles | Should Be $keep.Count
            # excluded folders and files are listed with the pattern that matched
            @($r.ExcludedFiles | Where-Object { $_.Kind -eq 'Pattern' }).Count | Should BeGreaterThan 0
            foreach ($x in @($r.ExcludedFiles | Where-Object { $_.Kind -eq 'Pattern' })) { $x.Reason | Should Match 'pattern' }
        }
        It "an app specific pattern only applies to its own rule" {
            $sb = New-Sandbox 'ex2'
            $a = Join-Path $sb 'a'; $b = Join-Path $sb 'b'
            Write-TestFile (Join-Path $a 'keep.dat') 'k'; Write-TestFile (Join-Path $a 'drop.tmpx') 'd'
            Write-TestFile (Join-Path $b 'keep.dat') 'k'; Write-TestFile (Join-Path $b 'drop.tmpx') 'd'
            $rules = New-TestRules -App @((New-TestRule -Id 'R-a' -Sources @($a) -Exclude @('*.tmpx')), (New-TestRule -Id 'R-b' -Sources @($b)))
            $bk = Join-Path $sb 'bk'
            Invoke-WinEaseMigrationRulesBackup -RuleIds @('R-a', 'R-b') -BackupRoot $bk -Rules $rules -ForceRunningProcess | Out-Null
            Test-Path -LiteralPath (Join-Path $bk 'rules\R-a\source-001\drop.tmpx') | Should Be $false
            Test-Path -LiteralPath (Join-Path $bk 'rules\R-b\source-001\drop.tmpx') | Should Be $true
        }
    }
}

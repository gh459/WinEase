# Registry phase (phases\10-registry.ps1, lib\WinEaseRegistry.ps1, config\registry\*.psd1).
# Pester 3.4 / Windows PowerShell 5.1.
. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath '_RegistryHarness.ps1')

Describe "Registry phase - snapshots per preset" {
    # tests\fixtures\registry\<preset>.txt holds the reg.exe calls the phase made for a
    # preset before its writes were moved into config\registry. The phase is compared by
    # the final state per hive / key / value, not by call order. To record a fixture
    # again after a deliberate change: $env:WINEASE_UPDATE_FIXTURES = '1'.
    foreach ($preset in $script:RegistryPresets) {
        It "writes the same final registry state for the '$preset' preset" -Skip:($script:RegistryHarnessPlugins.LoadedCount -lt 3) {
            $fixture = Join-Path $script:RepoRoot "tests\fixtures\registry\$preset.txt"
            $actualCalls = @(Invoke-WinEaseRegistryPhaseRecording -Preset $preset)
            $actualCalls | Where-Object { $_ -like 'UNPARSED*' } | Should BeNullOrEmpty
            if ($env:WINEASE_UPDATE_FIXTURES -eq '1') {
                [System.IO.File]::WriteAllText($fixture, (($actualCalls -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            }
            $expectedCalls = @([System.IO.File]::ReadAllText($fixture) -split "`r?`n" | Where-Object { $_ })
            $expected = ConvertTo-WinEaseRegistryFinalState -Calls $expectedCalls
            $actual = ConvertTo-WinEaseRegistryFinalState -Calls $actualCalls
            foreach ($d in $actual.Duplicates) { Write-Warning "[$preset] value written twice with different data: $d" }

            $problems = [System.Collections.Generic.List[string]]::new()
            foreach ($id in $expected.State.Keys) {
                if (-not $actual.State.ContainsKey($id)) { $problems.Add("missing: $id = $($expected.State[$id])") }
                elseif ($actual.State[$id] -ne $expected.State[$id]) { $problems.Add("changed: $id expected '$($expected.State[$id])' got '$($actual.State[$id])'") }
            }
            foreach ($id in $actual.State.Keys) {
                if (-not $expected.State.ContainsKey($id)) { $problems.Add("extra: $id = $($actual.State[$id])") }
            }
            ($problems -join "`n") | Should BeNullOrEmpty
        }
    }

    It "loads the five offline hives through the hive helper" -Skip:($script:RegistryHarnessPlugins.LoadedCount -lt 3) {
        $calls = @(Invoke-WinEaseRegistryPhaseRecording -Preset 'default')
        @($calls | Where-Object { $_ -like 'LOAD*' }).Count | Should Be 5
    }

    It "does not call reg.exe directly for add or delete (everything goes through Invoke-WinEaseReg)" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\10-registry.ps1'))
        [regex]::Matches($text, '(?m)^\s*(?:&\s*)?reg\.exe\s+(add|delete)\b').Count | Should Be 0
    }
}

Describe "Invoke-WinEaseReg" {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'lib\WinEaseRegistry.ps1')
        $script:RegArgs = $null
        function reg.exe { $script:RegArgs = @($args | ForEach-Object { [string]$_ }); $global:LASTEXITCODE = 0 }
    }

    AfterAll {
        Remove-Item Function:\reg.exe -ErrorAction SilentlyContinue
    }

    It "builds reg.exe add with value, type, data and /f" {
        Invoke-WinEaseReg -Action Add -Key 'HKLM\zSOFTWARE\Test' -Name 'Value One' -Type REG_DWORD -Data '1'
        ($script:RegArgs -join '|') | Should Be 'add|HKLM\zSOFTWARE\Test|/v|Value One|/t|REG_DWORD|/d|1|/f'
    }

    It "uses /ve for the default value" {
        Invoke-WinEaseReg -Action Add -Key 'HKLM\zSOFTWARE\Test' -DefaultValue -Type REG_SZ -Data '""'
        ($script:RegArgs -join '|') | Should Be 'add|HKLM\zSOFTWARE\Test|/ve|/t|REG_SZ|/d|""|/f'
    }

    It "creates a key without a value" {
        Invoke-WinEaseReg -Action Add -Key 'HKLM\zSOFTWARE\Test'
        ($script:RegArgs -join '|') | Should Be 'add|HKLM\zSOFTWARE\Test|/f'
    }

    It "deletes a value, and a key, with /f" {
        Invoke-WinEaseReg -Action Delete -Key 'HKLM\zSOFTWARE\Test' -Name 'X'
        ($script:RegArgs -join '|') | Should Be 'delete|HKLM\zSOFTWARE\Test|/v|X|/f'
        Invoke-WinEaseReg -Action Delete -Key 'HKLM\zSOFTWARE\Test'
        ($script:RegArgs -join '|') | Should Be 'delete|HKLM\zSOFTWARE\Test|/f'
    }

    It "queries without /f and reports the exit code with -PassThru" {
        (Invoke-WinEaseReg -Action Query -Key 'HKLM\zSOFTWARE\Test' -PassThru) | Should Be $true
        ($script:RegArgs -join '|') | Should Be 'query|HKLM\zSOFTWARE\Test'
    }

    It "emits nothing without -PassThru" {
        @(Invoke-WinEaseReg -Action Add -Key 'HKLM\zSOFTWARE\Test' -Name 'X' -Type REG_DWORD -Data '1').Count | Should Be 0
    }
}

Describe "config\registry tables" {
    BeforeAll {
        $script:RegistryTableDir = Join-Path $script:RepoRoot 'config\registry'
        $script:RegistryTableFiles = @(Get-ChildItem -LiteralPath $script:RegistryTableDir -Filter '*.psd1')
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'config\schema.psd1')
        # a table entry is switched by a tweak or by a component (SetJapaneseKeyboard, RemoveDefender, ...)
        $script:SchemaKeys = @($schema.Tweaks | ForEach-Object { $_.Key }) + @($schema.Components | ForEach-Object { $_.Key })
        $script:AllowedTypes = @('REG_SZ', 'REG_DWORD', 'REG_EXPAND_SZ', 'REG_BINARY', 'REG_NONE', 'REG_QWORD', 'REG_MULTI_SZ')
        $script:AllowedHives = @('zSYSTEM', 'zSOFTWARE', 'zDEFAULT', 'zNTUSER', 'zCOMPONENTS')
        $script:RegistryEntries = foreach ($file in $script:RegistryTableFiles) {
            foreach ($entry in @((Import-PowerShellDataFile -LiteralPath $file.FullName).Entries)) {
                [pscustomobject]@{ File = $file.Name; Entry = $entry }
            }
        }
    }

    It "has at least one table and every table has entries" {
        $script:RegistryTableFiles.Count | Should BeGreaterThan 0
        foreach ($file in $script:RegistryTableFiles) {
            @((Import-PowerShellDataFile -LiteralPath $file.FullName).Entries).Count | Should BeGreaterThan 0
        }
    }

    It "gives every entry the fields Tweak, Default, Hive, Path, Name, Type and Data" {
        $bad = foreach ($r in $script:RegistryEntries) {
            foreach ($field in 'Tweak', 'Default', 'Hive', 'Path', 'Name', 'Type', 'Data') {
                if (-not $r.Entry.ContainsKey($field)) { "$($r.File): $($r.Entry.Tweak) $($r.Entry.Name) lacks $field" }
            }
        }
        ($bad -join "`n") | Should BeNullOrEmpty
    }

    It "only uses Tweak keys that exist in config\schema.psd1" {
        $bad = foreach ($r in $script:RegistryEntries) {
            if ($script:SchemaKeys -notcontains $r.Entry.Tweak) { "$($r.File): unknown Tweak '$($r.Entry.Tweak)'" }
        }
        (@($bad | Select-Object -Unique) -join "`n") | Should BeNullOrEmpty
    }

    It "only uses allowed registry value types" {
        $bad = foreach ($r in $script:RegistryEntries) {
            if ($script:AllowedTypes -notcontains $r.Entry.Type) { "$($r.File): $($r.Entry.Name) has type '$($r.Entry.Type)'" }
        }
        ($bad -join "`n") | Should BeNullOrEmpty
    }

    It "only writes to the offline hives and never below zSYSTEM\CurrentControlSet (Bug Check 0x67)" {
        $bad = foreach ($r in $script:RegistryEntries) {
            foreach ($hive in @($r.Entry.Hive)) {
                if ($script:AllowedHives -notcontains $hive) { "$($r.File): unknown hive '$hive'" }
                if ($hive -eq 'zSYSTEM' -and $r.Entry.Path -match '^CurrentControlSet(\\|$)') { "$($r.File): zSYSTEM\$($r.Entry.Path)" }
            }
        }
        ($bad -join "`n") | Should BeNullOrEmpty
        foreach ($file in $script:RegistryTableFiles) {
            ([System.IO.File]::ReadAllText($file.FullName)).Contains('zSYSTEM\CurrentControlSet') | Should Be $false
        }
    }

    It "keeps MinBuild and MaxBuild consistent when they are set" {
        $bad = foreach ($r in $script:RegistryEntries) {
            $min = $r.Entry.MinBuild; $max = $r.Entry.MaxBuild
            if ($min -and $min -isnot [int]) { "$($r.File): MinBuild is not a number" }
            if ($max -and $max -isnot [int]) { "$($r.File): MaxBuild is not a number" }
            if ($min -and $max -and $min -gt $max) { "$($r.File): MinBuild $min > MaxBuild $max" }
        }
        ($bad -join "`n") | Should BeNullOrEmpty
    }

    It "warns about a value that two entries write with different data" {
        $seen = @{}
        $conflicts = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $script:RegistryEntries) {
            foreach ($hive in @($r.Entry.Hive)) {
                $id = "$hive|$($r.Entry.Path)|$($r.Entry.Name)".ToLowerInvariant()
                $value = "$($r.Entry.Type)|$($r.Entry.Data)"
                if ($seen.ContainsKey($id) -and $seen[$id] -ne $value) { $conflicts.Add("$id : $($seen[$id]) vs $value ($($r.File))") }
                $seen[$id] = $value
            }
        }
        foreach ($c in $conflicts) { Write-Warning "registry tables: duplicate key with different data: $c" }
        $true | Should Be $true
    }

    It "only gives OffData to per-user entries of settings that are on by default" {
        $bad = foreach ($r in $script:RegistryEntries) {
            if ($null -eq $r.Entry.OffData) { continue }
            if (-not [bool]$r.Entry.Default) { "$($r.File): $($r.Entry.Tweak) $($r.Entry.Name) has OffData but is off by default" }
            foreach ($hive in @($r.Entry.Hive)) {
                if ($hive -notin @('zNTUSER', 'zDEFAULT')) { "$($r.File): $($r.Entry.Tweak) $($r.Entry.Name) has OffData in hive $hive" }
            }
        }
        ($bad -join "`n") | Should BeNullOrEmpty
    }

    It "turns UAC off completely only with DisableUAC (EnableLUA) and keeps DisableUACPrompts to the prompts" {
        $uac = @($script:RegistryEntries | Where-Object { $_.Entry.Tweak -eq 'DisableUAC' } | ForEach-Object { $_.Entry })
        $prompts = @($script:RegistryEntries | Where-Object { $_.Entry.Tweak -eq 'DisableUACPrompts' } | ForEach-Object { $_.Entry })
        (@($uac | Where-Object { $_.Name -eq 'EnableLUA' -and $_.Data -eq '0' -and $_.Type -eq 'REG_DWORD' }).Count) | Should Be 1
        (@($prompts | Where-Object { $_.Name -eq 'EnableLUA' }).Count) | Should Be 0
        (@($prompts | Where-Object { $_.Name -eq 'ConsentPromptBehaviorAdmin' -and $_.Data -eq '0' }).Count) | Should Be 1
    }

    It "writes the light theme while EnableDarkTheme is off" {
        $dark = @($script:RegistryEntries | Where-Object { $_.Entry.Tweak -eq 'EnableDarkTheme' } | ForEach-Object { $_.Entry })
        $dark.Count | Should BeGreaterThan 0
        foreach ($e in $dark) { $e.OffData | Should Be '1' }
    }

    It "has a table for every Invoke-WinEaseRegistryTable -Section call of the phase" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\10-registry.ps1'))
        $sections = [regex]::Matches($text, 'Invoke-WinEaseRegistryTable -Section ([a-z-]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        @($sections).Count | Should BeGreaterThan 0
        foreach ($s in $sections) { (Test-Path -LiteralPath (Join-Path $script:RegistryTableDir "$s.psd1")) | Should Be $true }
    }

    It "has no table that the phase never applies" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\10-registry.ps1'))
        foreach ($file in $script:RegistryTableFiles) {
            $text.Contains("-Section $($file.BaseName)") | Should Be $true
        }
    }
}

Describe "Invoke-WinEaseRegistryTable" {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'lib\WinEaseRegistry.ps1')
        $script:TblRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("regtbl_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TblRoot -Force | Out-Null
        $sample = @(
            '@{'
            "    Version = '1.0'"
            '    Entries = @('
            "        @{ Tweak = 'TblOn'; Default = `$true; Hive = @('zNTUSER', 'zDEFAULT'); Path = 'Software\T'; Name = 'A'; Type = 'REG_DWORD'; Data = '1' }"
            "        @{ Tweak = 'TblOff'; Default = `$false; Hive = 'zSOFTWARE'; Path = 'T'; Name = 'B'; Type = 'REG_DWORD'; Data = '1' }"
            "        @{ Tweak = 'TblOn'; Default = `$true; Hive = 'zSOFTWARE'; Path = 'T'; Name = ''; Type = 'REG_SZ'; Data = '' }"
            "        @{ Tweak = 'TblOn'; Default = `$true; Hive = 'zSOFTWARE'; Path = 'T'; Name = 'New'; Type = 'REG_DWORD'; Data = '1'; MinBuild = 26100 }"
            "        @{ Tweak = 'TblOn'; Default = `$true; Hive = 'zSOFTWARE'; Path = 'T'; Name = 'Old'; Type = 'REG_DWORD'; Data = '1'; MaxBuild = 22631 }"
            "        @{ Tweak = 'TblDual'; Default = `$true; Hive = 'zNTUSER'; Path = 'T'; Name = 'D'; Type = 'REG_DWORD'; Data = '0'; OffData = '1' }"
            "        @{ Tweak = 'TblDual'; Default = `$true; Hive = 'zNTUSER'; Path = 'T'; Name = 'S'; Type = 'REG_DWORD'; Data = '1'; OffData = '400'; OffType = 'REG_SZ' }"
            "        @{ Tweak = 'TblDual'; Default = `$true; Hive = 'zNTUSER'; Path = 'T'; Name = 'OnlyOn'; Type = 'REG_DWORD'; Data = '1' }"
            '    )'
            '}'
        )
        Set-Content -LiteralPath (Join-Path $script:TblRoot 'sample.psd1') -Value $sample -Encoding UTF8
        $script:TblCalls = [System.Collections.Generic.List[string]]::new()
        function Test-TweakEnabled {
            param([string]$Name, [bool]$Default = $true)
            if ($script:TblSettings -and ([System.Collections.IDictionary]$script:TblSettings).Contains($Name)) { return [bool]$script:TblSettings[$Name] }
            return $Default
        }
        function Invoke-WinEaseReg {
            param($Action, $Key, $Name, [switch]$DefaultValue, $Type, $Data)
            $script:TblCalls.Add("$Action|$Key|$(if ($DefaultValue) { '(default)' } else { $Name })|$Type|$Data")
        }
        function Invoke-Table {
            param([string]$Tweak, [switch]$Unconditional)
            $script:TblCalls.Clear()
            Invoke-WinEaseRegistryTable -Section sample -TableRoot $script:TblRoot -Tweak $Tweak -Unconditional:$Unconditional
            return @($script:TblCalls)
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:TblRoot -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach { $script:TblSettings = $null; $script:WinEaseTargetBuild = $null }

    It "writes an entry to every listed hive when its tweak is on by default" {
        $calls = Invoke-Table -Tweak 'TblOn'
        ($calls -contains 'Add|HKLM\zNTUSER\Software\T|A|REG_DWORD|1') | Should Be $true
        ($calls -contains 'Add|HKLM\zDEFAULT\Software\T|A|REG_DWORD|1') | Should Be $true
    }

    It "skips an entry whose tweak is off and honours a setting" {
        @(Invoke-Table -Tweak 'TblOff').Count | Should Be 0
        $script:TblSettings = [ordered]@{ TblOff = $true; TblOn = $false }
        @(Invoke-Table -Tweak 'TblOff').Count | Should Be 1
        @(Invoke-Table -Tweak 'TblOn').Count | Should Be 0
    }

    It "-Unconditional ignores the tweak gate" {
        $script:TblSettings = [ordered]@{ TblOff = $false }
        @(Invoke-Table -Tweak 'TblOff' -Unconditional).Count | Should Be 1
    }

    It "writes OffData / OffType while the tweak is off and skips entries without OffData" {
        $script:TblSettings = [ordered]@{ TblDual = $false }
        $calls = Invoke-Table -Tweak 'TblDual'
        $calls.Count | Should Be 2
        ($calls -contains 'Add|HKLM\zNTUSER\T|D|REG_DWORD|1') | Should Be $true
        ($calls -contains 'Add|HKLM\zNTUSER\T|S|REG_SZ|400') | Should Be $true
    }

    It "writes Data / Type, never OffData, while the tweak is on or -Unconditional" {
        $calls = Invoke-Table -Tweak 'TblDual'
        $calls.Count | Should Be 3
        ($calls -contains 'Add|HKLM\zNTUSER\T|D|REG_DWORD|0') | Should Be $true
        ($calls -contains 'Add|HKLM\zNTUSER\T|S|REG_DWORD|1') | Should Be $true
        $script:TblSettings = [ordered]@{ TblDual = $false }
        $calls = Invoke-Table -Tweak 'TblDual' -Unconditional
        ($calls -contains 'Add|HKLM\zNTUSER\T|D|REG_DWORD|0') | Should Be $true
    }

    It "leaves Data out for an empty value of a non-string type" {
        $script:TblSettings = $null
        $root = Join-Path $script:TblRoot "none"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root "sample.psd1") -Value @(
            "@{ Entries = @( @{ Tweak = 'TblOn'; Default = `$true; Hive = 'zSOFTWARE'; Path = 'T'; Name = 'N'; Type = 'REG_NONE'; Data = '' } ) }"
        ) -Encoding UTF8
        $script:TblCalls.Clear()
        Invoke-WinEaseRegistryTable -Section sample -TableRoot $root
        $script:TblCalls[0] | Should Be 'Add|HKLM\zSOFTWARE\T|N|REG_NONE|'
    }

    It "writes an empty Data of a string value as the literal quotes and an empty Name as the default value" {
        $calls = Invoke-Table -Tweak 'TblOn'
        ($calls -contains 'Add|HKLM\zSOFTWARE\T|(default)|REG_SZ|""') | Should Be $true
    }

    It "applies MinBuild / MaxBuild to the target build and ignores them while the build is unknown" {
        $calls = Invoke-Table -Tweak 'TblOn'
        @($calls | Where-Object { $_ -like '*|New|*' -or $_ -like '*|Old|*' }).Count | Should Be 2
        $script:WinEaseTargetBuild = 22631
        $calls = Invoke-Table -Tweak 'TblOn'
        @($calls | Where-Object { $_ -like '*|New|*' }).Count | Should Be 0
        @($calls | Where-Object { $_ -like '*|Old|*' }).Count | Should Be 1
        $script:WinEaseTargetBuild = 26100
        $calls = Invoke-Table -Tweak 'TblOn'
        @($calls | Where-Object { $_ -like '*|New|*' }).Count | Should Be 1
        @($calls | Where-Object { $_ -like '*|Old|*' }).Count | Should Be 0
    }

    It "throws for a missing table" {
        { Invoke-WinEaseRegistryTable -Section 'does-not-exist' -TableRoot $script:TblRoot } | Should Throw
    }
}

Describe "Registry files in the bundles" {
    It "lists lib\WinEaseRegistry.ps1 and the config\registry tables in the release zip check" {
        $py = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot '.github\scripts\verify-release-zip.py'))
        $py.Contains('"lib/WinEaseRegistry.ps1"') | Should Be $true
        $py.Contains('"config/registry/') | Should Be $true
    }

    It "copies lib\WinEaseRegistry.ps1 into the flat Migration Assistant bundle" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\11-unattend.ps1'))
        $text.Contains("'lib\WinEaseRegistry.ps1'") | Should Be $true
    }

    It "is loaded by the builder with the other builder libraries" {
        $text = [System.IO.File]::ReadAllText($script:BuilderPath)
        $text.Contains("'WinEaseRegistry.ps1'") | Should Be $true
    }
}

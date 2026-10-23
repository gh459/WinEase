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
        It "writes the same final registry state for the '$preset' preset" {
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

    It "loads the five offline hives through the hive helper" {
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

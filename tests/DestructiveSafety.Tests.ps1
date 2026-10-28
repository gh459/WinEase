# DestructiveSafety.Tests.ps1 - workspace ownership marker, Defender exclusion lifecycle and registry write failures
# Run with:  Invoke-Pester -Path .\tests\DestructiveSafety.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
#
# Only per-test temp directories are touched; DISM, reg.exe and the Defender cmdlets are never run for real
# (the Defender cmdlets and Invoke-WinEaseReg are replaced by stand-ins).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock script blocks run in a different scope than the test')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
if (-not (Get-Command -Name Test-WinEaseWorkspaceResetAllowed -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}
if (-not (Get-Command -Name Get-WinEaseCleanupRemediation -ErrorAction SilentlyContinue)) {
    . $script:GuiSessionPath
}
if (-not (Get-Command -Name Assert-WinEaseRegistryWrites -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseRegistry.ps1")
}

function New-SafetyTestRoot {
    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_safety_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    return $root
}

function New-SafetyFile {
    param([string]$Path)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, 'x')
}

Describe "Workspace ownership marker (P1-03)" {
    BeforeEach {
        $script:Root = New-SafetyTestRoot
        $script:Base = Join-Path $script:Root 'MyProject'
        $script:Build = Join-Path $script:Base 'build'
        $script:Scratch = Join-Path $script:Base 'scratchdir'
        [System.IO.Directory]::CreateDirectory($script:Base) | Out-Null
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It "allows a workspace whose build and scratchdir do not exist or are empty" {
        (Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch).Allowed | Should Be $true
        [System.IO.Directory]::CreateDirectory($script:Build) | Out-Null
        (Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch).Allowed | Should Be $true
    }

    It "refuses a non-empty build folder that carries no marker" {
        New-SafetyFile -Path (Join-Path $script:Build 'src\main.c')
        $r = Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch
        $r.Allowed | Should Be $false
        $r.Reason | Should Be 'unmarked'
        @($r.Paths) -contains $script:Build | Should Be $true
    }

    It "refuses a non-empty scratchdir that carries no marker" {
        New-SafetyFile -Path (Join-Path $script:Scratch 'notes.txt')
        $r = Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch
        $r.Allowed | Should Be $false
        @($r.Paths) -contains $script:Scratch | Should Be $true
    }

    It "allows the reset with -Force and says it was forced" {
        New-SafetyFile -Path (Join-Path $script:Build 'src\main.c')
        $r = Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch -Force
        $r.Allowed | Should Be $true
        $r.Reason | Should Be 'forced'
    }

    It "allows a workspace that carries the marker" {
        New-SafetyFile -Path (Join-Path $script:Build 'sources\install.wim')
        New-SafetyFile -Path (Join-Path $script:Scratch 'anything.bin')
        [void](Write-WinEaseWorkspaceMarker -BaseWorkDir $script:Base -BuildId 'test')
        (Test-Path -LiteralPath (Join-Path $script:Base '.winease-workspace')) | Should Be $true
        $r = Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch
        $r.Allowed | Should Be $true
        $r.Reason | Should Be 'marker'
    }

    It "writes the marker once and leaves an existing marker alone" {
        [void](Write-WinEaseWorkspaceMarker -BaseWorkDir $script:Base -BuildId 'first')
        $marker = Join-Path $script:Base '.winease-workspace'
        $before = [System.IO.File]::ReadAllText($marker)
        [void](Write-WinEaseWorkspaceMarker -BaseWorkDir $script:Base -BuildId 'second')
        [System.IO.File]::ReadAllText($marker) | Should Be $before
        ($before -match '"BuildId":\s*"first"') | Should Be $true
    }

    It "still resets a workspace of an older WinEase version (default folder name)" {
        $legacyBase = Join-Path $script:Root 'WinEase_workspace'
        $legacyBuild = Join-Path $legacyBase 'build'
        New-SafetyFile -Path (Join-Path $legacyBuild 'anything.bin')
        $r = Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $legacyBase -BuildDir $legacyBuild -ScratchDir (Join-Path $legacyBase 'scratchdir')
        $r.Allowed | Should Be $true
        $r.Reason | Should Be 'default-name'
    }

    It "still resets a workspace of an older WinEase version (build\sources and a mounted image)" {
        New-SafetyFile -Path (Join-Path $script:Build 'sources\install.wim')
        New-SafetyFile -Path (Join-Path $script:Scratch 'Windows\System32\ntoskrnl.exe')
        $r = Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch
        $r.Allowed | Should Be $true
        $r.Reason | Should Be 'legacy-signature'
    }

    It "does not treat a build folder with sources but a foreign scratchdir as a WinEase workspace" {
        New-SafetyFile -Path (Join-Path $script:Build 'sources\install.wim')
        New-SafetyFile -Path (Join-Path $script:Scratch 'my-data\file.txt')
        (Test-WinEaseWorkspaceResetAllowed -BaseWorkDir $script:Base -BuildDir $script:Build -ScratchDir $script:Scratch).Allowed | Should Be $false
    }

    It "checks the workspace in phase 01 before the Defender exclusion and before any reset" {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\01-environment.ps1'))
        $check = $text.IndexOf('Test-WinEaseWorkspaceResetAllowed')
        $check | Should BeGreaterThan -1
        $check | Should BeLessThan $text.IndexOf('Add-WinEaseDefenderExclusion')
        $check | Should BeLessThan $text.IndexOf('Reset-DirectoryWithRobocopy')
    }
}

Describe "Defender exclusion lifecycle (P1-02)" {
    BeforeAll {
        # Stand-ins for the Defender cmdlets, so the tests do not depend on the module or on administrator rights.
        $script:Exclusions = [System.Collections.Generic.List[string]]::new()
        $script:AddShouldFail = $false
        $script:RemoveShouldFail = $false
        function Get-MpPreference { [PSCustomObject]@{ ExclusionPath = @($script:Exclusions) } }
        function Add-MpPreference {
            param([string[]]$ExclusionPath)
            if ($script:AddShouldFail) { throw 'Add failed' }
            foreach ($p in $ExclusionPath) { $script:Exclusions.Add($p) }
        }
        function Remove-MpPreference {
            param([string[]]$ExclusionPath)
            if ($script:RemoveShouldFail) { return }
            foreach ($p in $ExclusionPath) { [void]$script:Exclusions.Remove($p) }
        }
    }
    BeforeEach {
        $script:Exclusions.Clear()
        $script:AddShouldFail = $false
        $script:RemoveShouldFail = $false
    }

    It "adds the exclusion, reports it as ours and removes it again" {
        (Add-WinEaseDefenderExclusion -Path 'C:\Work\WinEase') | Should Be $true
        $script:Exclusions -contains 'C:\Work\WinEase' | Should Be $true
        (Remove-WinEaseDefenderExclusion -Path 'C:\Work\WinEase') | Should Be $true
        $script:Exclusions.Count | Should Be 0
    }

    It "does not claim an exclusion the user already had (so it is not removed at the end)" {
        $script:Exclusions.Add('C:\Work\WinEase\')
        (Add-WinEaseDefenderExclusion -Path 'C:\Work\WinEase') | Should Be $false
        $script:Exclusions.Count | Should Be 1
    }

    It "does not set the flag when the add fails" {
        $script:AddShouldFail = $true
        (Add-WinEaseDefenderExclusion -Path 'C:\Work\WinEase') | Should Be $false
    }

    It "does not set the flag when the exclusion is not there after the add" {
        function Add-MpPreference { param([string[]]$ExclusionPath) }
        (Add-WinEaseDefenderExclusion -Path 'C:\Work\WinEase' 3>$null) | Should Be $false
    }

    It "reports a failed removal and names the command that removes the exclusion" {
        [void](Add-WinEaseDefenderExclusion -Path 'C:\Work\WinEase')
        $script:RemoveShouldFail = $true
        $out = @(Remove-WinEaseDefenderExclusion -Path 'C:\Work\WinEase' 3>&1)
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        @($out | Where-Object { $_ -is [bool] })[0] | Should Be $false
        ($warnings -join ' ') | Should Match 'Remove-MpPreference -ExclusionPath'
    }

    It "lists a leftover exclusion among the cleanup remediations" {
        $rem = @(Get-WinEaseCleanupRemediation -DefenderExclusionPath 'C:\Work\WinEase')
        $rem.Count | Should Be 1
        $rem[0].Type | Should Be 'DefenderExclusion'
        $rem[0].Remediation | Should Match 'Remove-MpPreference'
        $none = Get-WinEaseCleanupRemediation
        @($none).Count | Should Be 0
    }
}

Describe "Registry write failures (P1-01)" {
    BeforeAll {
        $script:TblRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("WinEase_regfail_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:TblRoot -Force | Out-Null
        $sample = @(
            '@{ Entries = @('
            '    @{ Hive = ''zSOFTWARE''; Path = ''Test\A''; Name = ''First'';  Type = ''REG_DWORD''; Data = ''1'' }'
            '    @{ Hive = ''zSOFTWARE''; Path = ''Test\B''; Name = ''Second''; Type = ''REG_DWORD''; Data = ''2'' }'
            '    @{ Hive = ''zSOFTWARE''; Path = ''Test\C''; Name = ''Third'';  Type = ''REG_DWORD''; Data = ''3'' }'
            ') }'
        )
        Set-Content -LiteralPath (Join-Path $script:TblRoot 'sample.psd1') -Value $sample -Encoding UTF8
        $script:FailKey = ''
        function Invoke-WinEaseReg {
            param($Action, $Key, $Name, [switch]$DefaultValue, $Type, $Data, [switch]$PassThru)
            if ($PassThru) { return ($Key -ne $script:FailKey) }
        }
        function Test-TweakEnabled { param([string]$Name, [bool]$Default = $true) return $Default }
    }
    AfterAll { Remove-Item -LiteralPath $script:TblRoot -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:FailKey = ''
        $script:StrictRegistryWrites = $false
        $script:RegistryWriteFailures = [System.Collections.Generic.List[string]]::new()
        $script:DiagnosticData = @{}
    }

    It "records nothing when every write succeeds" {
        Invoke-WinEaseRegistryTable -Section sample -TableRoot $script:TblRoot
        $script:RegistryWriteFailures.Count | Should Be 0
        { Assert-WinEaseRegistryWrites -Strict } | Should Not Throw
    }

    It "records the entry whose write was refused and keeps going with the others" {
        $script:FailKey = 'HKLM\zSOFTWARE\Test\B'
        Invoke-WinEaseRegistryTable -Section sample -TableRoot $script:TblRoot
        $script:RegistryWriteFailures.Count | Should Be 1
        $script:RegistryWriteFailures[0] | Should Match 'Test\\B \[Second\]'
    }

    It "warns about the failures and stores them in the diagnostics" {
        $script:FailKey = 'HKLM\zSOFTWARE\Test\A'
        Invoke-WinEaseRegistryTable -Section sample -TableRoot $script:TblRoot
        $out = @(Assert-WinEaseRegistryWrites -Stage 'unit test' 3>&1)
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        ($warnings -join ' ') | Should Match '1 registry write\(s\) failed in unit test'
        @($script:DiagnosticData['RegistryWriteFailures']).Count | Should Be 1
    }

    It "throws with -Strict so a partly written image does not become an ISO" {
        $script:FailKey = 'HKLM\zSOFTWARE\Test\C'
        Invoke-WinEaseRegistryTable -Section sample -TableRoot $script:TblRoot
        { Assert-WinEaseRegistryWrites -Stage 'unit test' -Strict } | Should Throw 'registry write(s) failed'
    }

    It "does not count a stand-in that returns nothing as a failure" {
        function Invoke-WinEaseReg { param($Action, $Key, $Name, [switch]$DefaultValue, $Type, $Data) }
        Invoke-WinEaseRegistryTable -Section sample -TableRoot $script:TblRoot
        $script:RegistryWriteFailures.Count | Should Be 0
    }

    It "reads the exit status of the boot.wim writes in phase 14 and phase 10 checks the result" {
        $boot = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\14-bootwim.ps1'))
        [regex]::Matches($boot, '(?m)^\s*reg\.exe\s+add\b').Count | Should Be 0
        $boot | Should Match 'Assert-WinEaseRegistryWrites'
        ([System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\10-registry.ps1'))) | Should Match 'Assert-WinEaseRegistryWrites'
    }
}

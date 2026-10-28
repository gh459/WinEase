# BehaviourFixes.Tests.ps1 - process argument quoting, OnError=Stop propagation, option-gated boot.wim writes and
# honest wording for the physical debloat binary check (audit PR-C)
# Run with:  Invoke-Pester -Path .\tests\BehaviourFixes.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
#
# The argument tests start a real powershell.exe child; nothing else leaves the temp directory.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')
if (-not (Get-Command -Name ConvertTo-WinEaseProcessArgumentString -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

if (-not (Get-Command -Name Test-WinEaseStopException -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseExtensions.ps1")
}

Describe "Process arguments keep spaces (P2-09)" {
    BeforeAll {
        $script:ArgRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase args " + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($script:ArgRoot) | Out-Null
        $script:Echo = Join-Path $script:ArgRoot 'echo args.ps1'
        # Writes every argument it receives on its own line.
        [System.IO.File]::WriteAllText($script:Echo, 'param() $args | ForEach-Object { $_ }')
        $script:Out = Join-Path $script:ArgRoot 'out.txt'
    }
    AfterAll { Remove-Item -LiteralPath $script:ArgRoot -Recurse -Force -ErrorAction SilentlyContinue }

    function Invoke-ArgEcho {
        param([string[]]$Values)
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Echo) + $Values
        $list = ConvertTo-WinEaseProcessArgumentString -Arguments $all
        $p = Start-Process powershell.exe -ArgumentList $list -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $script:Out
        [void]$p
        return @(Get-Content -LiteralPath $script:Out)
    }

    It "the quoted string delivers each value as one argument" {
        $got = Invoke-ArgEcho -Values @('C:\a b\c', 'plain', 'say "hi"')
        $got.Count | Should Be 3
        $got[0] | Should Be 'C:\a b\c'
        $got[1] | Should Be 'plain'
        $got[2] | Should Be 'say "hi"'
    }
    It "a path ending in a backslash does not swallow the closing quote" {
        $got = Invoke-ArgEcho -Values @('C:\a b\', 'next')
        $got.Count | Should Be 2
        $got[0] | Should Be 'C:\a b\'
        $got[1] | Should Be 'next'
    }
    It "leaves simple tokens unquoted and keeps an empty argument" {
        ConvertTo-WinEaseProcessArgumentString -Arguments @('--dry-run', 'x') | Should Be '--dry-run x'
        ConvertTo-WinEaseProcessArgumentString -Arguments @('') | Should Be '""'
    }
    It "the physical debloat launch and both migration wizard launches use quoted argument lines" {
        $phys = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\09-physical-debloat.ps1') -Raw
        $phys | Should Match 'ConvertTo-WinEaseProcessArgumentString -Arguments \$rustArgs'
        foreach ($f in 'gui\WinEaseGui.ps1', 'gui\WinEaseWinUiHost.ps1') {
            (Get-Content -LiteralPath (Join-Path $script:RepoRoot $f) -Raw) | Should Match 'ArgumentList \$migratorArgLine'
        }
    }
}

Describe "OnError Stop reaches the build (P2-10)" {
    BeforeEach {
        $script:OrigScripts = $script:UserCustomScripts
        $script:StopRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_stop_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($script:StopRoot) | Out-Null
    }
    AfterEach {
        $script:UserCustomScripts = $script:OrigScripts
        Remove-Item -LiteralPath $script:StopRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "a stage that stops throws an exception marked as a requested stop" {
        $s = Join-Path $script:StopRoot '01-stop.ps1'
        "# @WinEase-Id: StopScript`n# @WinEase-Stage: PreBuild`n# @WinEase-OnError: Stop`nthrow 'boom'" | Set-Content $s -Encoding UTF8
        $script:UserCustomScripts = @(@{ Enabled = $true; Stage = 'PreBuild'; Path = $s })
        $caught = $null
        try { Invoke-WinEaseCustomScriptsStage -Stage PreBuild | Out-Null } catch { $caught = $_ }
        ($null -ne $caught) | Should Be $true
        (Test-WinEaseStopException $caught) | Should Be $true
        $caught.Exception.Message | Should Match 'boom'
    }
    It "an ordinary error is not mistaken for a requested stop" {
        $caught = $null
        try { throw 'plain failure' } catch { $caught = $_ }
        (Test-WinEaseStopException $caught) | Should Be $false
    }
    It "finds the marker on an inner exception" {
        $inner = New-Object System.Exception('inner')
        $inner.Data['WinEaseStop'] = $true
        (Test-WinEaseStopException (New-Object System.Exception('outer', $inner))) | Should Be $true
    }
    It "the phases and the builder re-throw a requested stop and no longer hide other failures" {
        foreach ($f in 'phases\11-unattend.ps1', 'WinEasebuilder.ps1') {
            (Get-Content -LiteralPath (Join-Path $script:RepoRoot $f) -Raw) | Should Match 'Test-WinEaseStopException'
        }
        foreach ($f in 'phases\05-appx.ps1', 'phases\06-fod.ps1', 'phases\10-registry.ps1') {
            $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot $f) -Raw
            $t | Should Match 'User extension actions \(\w+\) failed'
            $t | Should Not Match 'UserExtensionActions -PhaseType \w+ [^\r\n]*Write-Verbose'
        }
    }
}

Describe "PreventDeviceEncryption follows its option (P2-08)" {
    It "boot.wim and the resume path write it only when the option is on" {
        $boot = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\14-bootwim.ps1') -Raw
        $boot | Should Match "if \(Test-TweakEnabled 'PreventDeviceEncryption' \`$false\) \{\s+\`$bootWrites\.Add"
        $resume = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'lib\WinEaseResume.ps1') -Raw
        $resume | Should Match "if \(Test-TweakEnabled 'PreventDeviceEncryption' \`$false\) \{\s+reg\.exe add"
    }
}

Describe "Physical debloat binary wording (P2-04)" {
    It "says the binary was found, not verified" {
        $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'phases\09-physical-debloat.ps1') -Raw
        $t | Should Match 'Rust binary found'
        $t | Should Not Match 'Rust binary verified'
    }
}

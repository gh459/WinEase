# Integration.Scaffold.Tests.ps1 - F2 scaffold: plan, scrub, failure-injection logic and workflow shape
# Run with:  Invoke-Pester -Path .\tests\Integration.Scaffold.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# NOTHING here boots a VM or builds an ISO. Passing proves the scaffold's pure logic only; it does
# not verify the real build/boot path (see docs\INTEGRATION_TESTING.md).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in the Describe body and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

$script:ToolPath = Join-Path -Path $script:RepoRoot -ChildPath 'tools\Test-WinEaseIntegration.ps1'
$script:WorkflowPath = Join-Path -Path $script:RepoRoot -ChildPath '.github\workflows\integration-vm.yml'
$script:CiPath = Join-Path -Path $script:RepoRoot -ChildPath '.github\workflows\ci.yml'

# Load the functions only (the tool returns early when dot-sourced)
. $script:ToolPath

function New-ScratchDir {
    $d = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('WinEaseIntTest_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

Describe "Integration scaffold - script" {
    It "tools\Test-WinEaseIntegration.ps1 parses with zero parser errors" {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:ToolPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "declares the required parameters" {
        $cmd = Get-Command -Name $script:ToolPath
        foreach ($p in 'IsoPath', 'Profile', 'WorkDir', 'VmName', 'TimeoutMinutes', 'DryRunPlanOnly') {
            $cmd.Parameters.ContainsKey($p) | Should Be $true
        }
    }
    It "-DryRunPlanOnly returns the expected stages in order and is unverified" {
        $plan = & $script:ToolPath -DryRunPlanOnly 6>$null
        $plan.verified | Should Be $false
        (@($plan.stages | ForEach-Object { $_.Name }) -join ',') |
            Should Be 'preflight,build-iso,create-vm,wait-firstlogon,collect-logs,teardown,post-assert,scrub'
    }
    It "-DryRunPlanOnly touches neither disk nor Hyper-V" {
        $artifactDir = Join-Path ([System.IO.Path]::GetTempPath()) ('WinEaseNoCreate_' + [guid]::NewGuid().ToString('N'))
        & $script:ToolPath -DryRunPlanOnly -ArtifactDir $artifactDir -WorkDir $artifactDir 6>$null | Out-Null
        Test-Path -LiteralPath $artifactDir | Should Be $false
    }
    It "refuses a real run without -IsoPath" {
        { & $script:ToolPath -ArtifactDir (Join-Path ([System.IO.Path]::GetTempPath()) 'x_never_created') } | Should Throw
    }
    It "generates distinct, complex per-run passwords" {
        $a = New-WinEaseIntegrationPassword
        $b = New-WinEaseIntegrationPassword
        $a | Should Not Be $b
        $a.Length | Should BeGreaterThan 20
        $a | Should Match '[a-z]'
        $a | Should Match '[A-Z]'
        $a | Should Match '[0-9]'
    }
}

Describe "Integration scaffold - artifact scrub" {
    It "passes a clean directory" {
        $d = New-ScratchDir
        try {
            Set-Content -LiteralPath (Join-Path $d 'builder.log') -Value 'Build finished. nothing secret here'
            (Invoke-WinEaseArtifactScrub -Path $d -Secret @('Sup3rS3cretValue')).Passed | Should Be $true
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "detects the planted run password (UTF-8) and quarantines the file without echoing it" {
        $d = New-ScratchDir
        try {
            $pw = New-WinEaseIntegrationPassword
            $bad = Join-Path $d 'leak.log'
            Set-Content -LiteralPath $bad -Value "UserPassword=$pw" -Encoding UTF8
            $r = Invoke-WinEaseArtifactScrub -Path $d -Secret @($pw)
            $r.Passed | Should Be $false
            (Test-Path -LiteralPath $bad) | Should Be $false
            (($r.Findings | Out-String) -like "*$pw*") | Should Be $false
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "detects the planted run password in a UTF-16 file" {
        $d = New-ScratchDir
        try {
            Set-Content -LiteralPath (Join-Path $d 'transcript.txt') -Value 'password Sup3rS3cretValue' -Encoding Unicode
            @(Test-WinEaseArtifactSecrets -Path $d -Secret @('Sup3rS3cretValue')).Count | Should BeGreaterThan 0
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "detects known secret shapes and the builder default password" {
        $d = New-ScratchDir
        try {
            $ghp = 'ghp_' + ('a' * 36)
            Set-Content -LiteralPath (Join-Path $d 'a.txt') -Value "token $ghp"
            Set-Content -LiteralPath (Join-Path $d 'b.txt') -Value '-----BEGIN RSA PRIVATE KEY-----'
            Set-Content -LiteralPath (Join-Path $d 'c.txt') -Value 'AKIAABCDEFGHIJKLMNOP'
            Set-Content -LiteralPath (Join-Path $d 'd.txt') -Value 'UserPassword = WinEase123!'
            $rules = @(Test-WinEaseArtifactSecrets -Path $d | ForEach-Object { $_.Rule })
            $rules -contains 'github-token' | Should Be $true
            $rules -contains 'private-key-block' | Should Be $true
            $rules -contains 'aws-access-key-id' | Should Be $true
            $rules -contains 'builder-default-password' | Should Be $true
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "-ScrubOnly exits non-zero for a planted secret (separate process)" {
        $d = New-ScratchDir
        try {
            Set-Content -LiteralPath (Join-Path $d 'x.log') -Value ('ghp_' + ('b' * 36))
            $ps = (Get-Command powershell.exe).Source
            $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ('WinEaseScrubOut_' + [guid]::NewGuid().ToString('N') + '.txt')
            $p = Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($script:ToolPath)`"", '-ScrubOnly', '-ArtifactDir', "`"$d`"") `
                -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile
            $out = [System.IO.File]::ReadAllText($outFile)
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            $out | Should Match "Secret pattern 'github-token'"
            $p.ExitCode | Should Be 1
            (Test-Path -LiteralPath (Join-Path $d 'x.log')) | Should Be $false
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Integration scaffold - failure injection (mockable subset)" {
    It "low disk space is rejected, enough space is accepted" {
        (Test-WinEaseIntegrationDiskSpace -FreeBytes 10GB -RequiredBytes 80GB).Ok | Should Be $false
        (Test-WinEaseIntegrationDiskSpace -FreeBytes 120GB -RequiredBytes 80GB).Ok | Should Be $true
    }
    It "a stale DISM mount fails the preflight check" {
        $mounts = @([PSCustomObject]@{ Path = 'C:\x\mount'; ImagePath = 'C:\x\install.wim'; ImageIndex = 1; MountStatus = 'Invalid' })
        $s = Test-WinEaseIntegrationMountState -Mounts $mounts
        $s.Ok | Should Be $false
        $s.Mounts[0] | Should Match 'Invalid'
        (Test-WinEaseIntegrationMountState -Mounts @()).Ok | Should Be $true
    }
    It "a DISM unmount failure (mount left behind) fails the post-run assertion" {
        $mounts = @([PSCustomObject]@{ Path = 'C:\x\mount'; MountStatus = 'Needs Remount' })
        $r = Test-WinEaseIntegrationPostRun -Mounts $mounts -WorkDir (Join-Path ([System.IO.Path]::GetTempPath()) ('WinEaseNoSuch_' + [guid]::NewGuid().ToString('N')))
        $r.Ok | Should Be $false
        $r.Problems[0] | Should Match 'DISM mount'
    }
    It "a leftover work directory or VM fails the post-run assertion; a clean run passes" {
        $d = New-ScratchDir
        try {
            (Test-WinEaseIntegrationPostRun -Mounts @() -WorkDir $d).Ok | Should Be $false
            (Test-WinEaseIntegrationPostRun -Mounts @() -WorkDir (Join-Path $d 'gone') -ExistingVmNames @('WinEase-Integration') -VmName 'WinEase-Integration').Ok | Should Be $false
            (Test-WinEaseIntegrationPostRun -Mounts @() -WorkDir (Join-Path $d 'gone') -ExistingVmNames @('other') -VmName 'WinEase-Integration').Ok | Should Be $true
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "a locked file is detected and cleanup reports the failure instead of hiding it" {
        $d = New-ScratchDir
        $fs = $null
        try {
            $f = Join-Path $d 'locked.vhdx'
            Set-Content -LiteralPath $f -Value 'x'
            $fs = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            Test-WinEaseFileLocked -Path $f | Should Be $true
            Remove-WinEaseIntegrationPath -Path $d -Attempts 2 -DelaySeconds 0 | Should Be $false
            $fs.Dispose(); $fs = $null
            Test-WinEaseFileLocked -Path $f | Should Be $false
            Remove-WinEaseIntegrationPath -Path $d -Attempts 2 -DelaySeconds 0 | Should Be $true
        } finally {
            if ($fs) { $fs.Dispose() }
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # Not mockable cheaply (need real DISM / a real interrupted build): documented as manual scenarios M1-M4
    # in docs\INTEGRATION_TESTING.md.
}

Describe "Integration scaffold - workflow shape" {
    $yaml = [System.IO.File]::ReadAllText($script:WorkflowPath)
    $ci = [System.IO.File]::ReadAllText($script:CiPath)
    $onBlock = ($yaml -split '(?m)^permissions:')[0]

    It "triggers on workflow_dispatch and schedule only" {
        $onBlock | Should Match '(?m)^  workflow_dispatch:'
        $onBlock | Should Match '(?m)^  schedule:'
    }
    It "has no pull_request / push / workflow_call trigger (never required for PRs)" {
        $onBlock | Should Not Match 'pull_request'
        $onBlock | Should Not Match '(?m)^  push:'
        $onBlock | Should Not Match 'workflow_call'
    }
    It "has the dispatch inputs iso_path, edition_index, profile, windows_build" {
        foreach ($i in 'iso_path', 'edition_index', 'profile', 'windows_build') { $onBlock | Should Match "(?m)^      ${i}:" }
    }
    It "is gated by INTEGRATION_ENABLED for the schedule" {
        $yaml | Should Match "vars\.INTEGRATION_ENABLED == 'true'"
    }
    It "targets the self-hosted hyperv runner" {
        $yaml | Should Match 'runs-on: \[self-hosted, windows, hyperv\]'
    }
    It "has empty top-level permissions and contents: read on the job" {
        $yaml | Should Match '(?m)^permissions: \{\}\s*$'
        $yaml | Should Match '(?ms)^    permissions:\s*\r?\n      contents: read'
    }
    It "does not use any secret and does not persist credentials" {
        $yaml | Should Not Match 'secrets\.'
        $yaml | Should Match 'persist-credentials: false'
    }
    It "pins every action to a full SHA that ci.yml already uses" {
        $uses = @([regex]::Matches($yaml, '(?m)^\s*(?:-\s+)?uses:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
        $uses.Count | Should BeGreaterThan 1
        foreach ($u in $uses) {
            $u | Should Match '@[0-9a-f]{40}$'
            $ci.Contains($u) | Should Be $true
        }
    }
    It "passes inputs through env, not into the script text" {
        $runBlocks = [regex]::Matches($yaml, '(?ms)^\s+run: \|\r?\n(.*?)(?=^\s+- name:|\z)') | ForEach-Object { $_.Groups[1].Value }
        ($runBlocks -join "`n") | Should Not Match '\$\{\{'
    }
    It "scrubs before the upload and only uploads after a successful scrub" {
        $yaml.IndexOf('-ScrubOnly') | Should BeLessThan $yaml.IndexOf('upload-artifact')
        $yaml | Should Match "steps\.scrub\.outcome == 'success'"
    }
    It "leaves ci.yml independent of the integration workflow" {
        $ci | Should Not Match 'integration-vm'
        $ci | Should Not Match 'Test-WinEaseIntegration'
    }
}

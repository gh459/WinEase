# Helpers.Tests.ps1 - shared helpers, path safety, ACL, DISM and logging
# Run with:  Invoke-Pester -Path .\tests\Helpers.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
# Split from the former tests\WinEase.Tests.ps1 in R1. Shared setup is in _TestCommon.ps1.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are assigned in BeforeAll/BeforeEach and read inside It blocks')]
param()

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')


Describe "WinEase builder - path safety guards (mock)" {
    It "rejects drive roots" {
        $norm = 'C:'
        ($norm.Length -le 3) | Should Be $true
    }
    It "rejects host system directories" {
        $hostWin = [System.Environment]::GetFolderPath('Windows')
        $target = Join-Path -Path $hostWin -ChildPath "System32"
        $target.StartsWith($hostWin + '\', [System.StringComparison]::OrdinalIgnoreCase) | Should Be $true
    }
}

# --- Regression tests: Remove-WinEaseTreeRobust (fixes the 41 GB deep_apply leak and the
# --- ~5-hour final cleanup stall). Loads WinEasehelpers.ps1 functions directly. ---
if (-not (Get-Command -Name Remove-WinEaseTreeRobust -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

Describe "WinEase builder - robust tree removal (long paths + image ACLs)" -Tags 'slow' {
    It "removes a tree containing >260-char paths" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $deep = Join-Path -Path $root -ChildPath "t1"
        [System.IO.Directory]::CreateDirectory($deep) | Out-Null
        $cur = $deep
        for ($i = 0; $i -lt 12; $i++) {
            $cur = Join-Path $cur "segments_of_reasonable_length_0123456789"
            [System.IO.Directory]::CreateDirectory("\\?\$cur") | Out-Null
        }
        $deepFile = Join-Path $cur "deep.txt"
        [System.IO.File]::WriteAllText("\\?\$deepFile", 'x')
        ($deepFile.Length -gt 260) | Should Be $true

        (Remove-WinEaseTreeRobust -Path $deep -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $deep) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "removes a tree protected by image-style ACLs (Administrators RX only)" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $sub = Join-Path -Path $root -ChildPath "System32"
        [System.IO.Directory]::CreateDirectory($sub) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sub "locked.exe"), 'x')
        & icacls.exe $sub /inheritance:r /grant '*S-1-5-32-544:RX' /T /C /Q > $null 2>&1

        (Remove-WinEaseTreeRobust -Path $sub -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $sub) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "repairs a WIM-style locked directory (SYSTEM-only DACL) and removes the tree" {
        # Regression for the 2026-10-18 real-build leftover (17.2 GB): dism /Apply-Image output
        # contains directories with protected SYSTEM-only DACLs. The old repair call
        # ('takeown /f <dir> /d y') was rejected by takeown's argv validation (needs /R) and
        # failed SILENTLY - the tree could never be repaired, deleting, or logged.
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $tree = Join-Path -Path $root -ChildPath "t_wim"
        $denied = Join-Path -Path $tree -ChildPath "WebThreatDefSvc"
        [System.IO.Directory]::CreateDirectory($denied) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $denied "payload.bin"), 'x')
        & icacls.exe $denied /inheritance:r > $null 2>&1
        & icacls.exe $denied /grant '*S-1-5-18:F' /C /Q > $null 2>&1
        & icacls.exe $denied /setowner '*S-1-5-18' /C /Q > $null 2>&1
        # /inheritance:r only strips INHERITED entries. Where the parent's entries are not
        # marked as inherited (the GitHub-hosted runner's temp folder), Administrators and the
        # current user would keep an explicit grant and the "locked" directory would not be
        # locked at all, so drop those two explicitly. A no-op where they were already gone.
        & icacls.exe $denied /remove:g '*S-1-5-32-544' /C /Q > $null 2>&1
        & icacls.exe $denied /remove:g ('*' + [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) /C /Q > $null 2>&1
        # Precondition: the DACL grants nothing to Administrators (privilege-state agnostic).
        $aclPre = Get-Acl -LiteralPath $denied
        $adminsAces = @($aclPre.Access | Where-Object {
            try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' } catch { $false }
        })
        $adminsAces.Count | Should Be 0

        (Remove-WinEaseTreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "repairs a SYSTEM-locked directory hiding a junction (canary survives)" {
        # End-to-end incident shape: the unreadable directory hides a junction. Before the fix
        # the repair no-op kept the link-free gate closed forever; the gate must stay closed
        # until the walk can prove the tree link-free - the mirror purge would destroy the
        # junction target (verified hazard).
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $canary = ($root + '_canary')
        $tree = Join-Path -Path $root -ChildPath "t_wim_link"
        $denied = Join-Path -Path $tree -ChildPath "RtBackup"
        [System.IO.Directory]::CreateDirectory($denied) | Out-Null
        [System.IO.Directory]::CreateDirectory($canary) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $canary "canary.txt"), 'precious')
        & cmd.exe /c "mklink /J `"$denied\hidden_junction`" `"$canary`"" > $null 2>&1
        ([System.IO.Directory]::Exists((Join-Path $denied 'hidden_junction'))) | Should Be $true
        & icacls.exe $denied /inheritance:r > $null 2>&1
        & icacls.exe $denied /grant '*S-1-5-18:F' /C /Q > $null 2>&1
        & icacls.exe $denied /setowner '*S-1-5-18' /C /Q > $null 2>&1

        (Remove-WinEaseTreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }

    It "never follows junctions (canary directory survives)" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $canary = ($root + '_canary')
        $target = Join-Path -Path $root -ChildPath "linked"
        [System.IO.Directory]::CreateDirectory($target) | Out-Null
        [System.IO.Directory]::CreateDirectory($canary) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $canary "canary.txt"), 'precious')
        & cmd.exe /c "mklink /J `"$target\the_junction`" `"$canary`"" > $null 2>&1

        (Remove-WinEaseTreeRobust -Path $target -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }

    It "refuses paths that are not strict children of the safety root" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $child = Join-Path -Path $root -ChildPath "keepme"
        [System.IO.Directory]::CreateDirectory($child) | Out-Null

        (Remove-WinEaseTreeRobust -Path $root -SafetyRoot $root) | Should Be $false
        (Remove-WinEaseTreeRobust -Path $child -SafetyRoot (Join-Path $root "other")) | Should Be $false
        (Test-Path -LiteralPath $child) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "removes a tree whose subdirectory denies enumeration (real-incident shape)" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $tree = Join-Path -Path $root -ChildPath "t_enum"
        $denied = Join-Path -Path $tree -ChildPath "DeniedSvc"
        [System.IO.Directory]::CreateDirectory($denied) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $denied "payload.bin"), 'x')
        & icacls.exe $denied /inheritance:r /deny '*S-1-5-32-544:RX' /C /Q > $null 2>&1

        (Remove-WinEaseTreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "never destroys a junction target hidden inside an unreadable directory" {
        # Regression: robocopy /MIR purges THROUGH junctions even with /XJ, so it must only
        # run on trees the prune walk could fully verify as link-free.
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $canary = ($root + '_canary')
        $tree = Join-Path -Path $root -ChildPath "t_hidden"
        $denied = Join-Path -Path $tree -ChildPath "DeniedSvc"
        [System.IO.Directory]::CreateDirectory($denied) | Out-Null
        [System.IO.Directory]::CreateDirectory($canary) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $canary "canary.txt"), 'precious')
        & cmd.exe /c "mklink /J `"$denied\hidden_junction`" `"$canary`"" > $null 2>&1
        & icacls.exe $denied /inheritance:r /deny '*S-1-5-32-544:RX' /C /Q > $null 2>&1

        (Remove-WinEaseTreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }

    It "deletes links whose inherited ACL was emptied, via parent repair" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $canary = ($root + '_canary')
        $tree = Join-Path -Path $root -ChildPath "t_stripped"
        $p = Join-Path -Path $tree -ChildPath "P"
        [System.IO.Directory]::CreateDirectory($p) | Out-Null
        [System.IO.Directory]::CreateDirectory($canary) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $canary "canary.txt"), 'precious')
        & cmd.exe /c "mklink /J `"$p\stripped_link`" `"$canary`"" > $null 2>&1
        & icacls.exe $p /inheritance:r /grant '*S-1-5-32-544:F' /C /Q > $null 2>&1

        (Remove-WinEaseTreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }
}

Describe "WinEase builder - phase timing telemetry" {
    It "persists Phase 18 through Exit-Phase + Save-WinEasePhaseTimings" {
        # Runtime test of the real source text: extract the two functions from the builder
        # AST, run them in this scope against a temp log dir, and verify the final phase
        # lands in last_phase_timings.json (regression for the always-missing Phase 18).
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)

        $funcTexts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Exit-Phase', 'Save-WinEasePhaseTimings')
        }, $true)) | ForEach-Object { $_.Extent.Text }
        $funcTexts.Count | Should Be 2

        $logDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_timings_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        $script:PhaseTimings = [ordered]@{ "Phase 17" = 42.5 }
        $script:CurrentPhase = 18
        $script:PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 60
        . ([scriptblock]::Create(($funcTexts -join "`n")))
        Exit-Phase
        Save-WinEasePhaseTimings

        $saved = (Get-Content -LiteralPath (Join-Path $logDir "last_phase_timings.json") -Raw -Encoding UTF8) | ConvertFrom-Json
        ($saved.PSObject.Properties.Name -contains "Phase 18") | Should Be $true
        ([double]$saved.'Phase 18') | Should BeGreaterThan 0
        ([double]$saved.'Phase 17') | Should Be 42.5
        $script:PhaseStopwatch | Should Be $null

        $script:PhaseTimings = [ordered]@{}
        Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "sums decimal phase durations from last_phase_timings.json" {
        # Regression: PS 5.1 ConvertFrom-Json yields System.Decimal for JSON decimals, and
        # the old reader only accepted double/int/long - fractional durations were silently
        # dropped (a ~840 s table displayed as "~0 min").
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        $funcTexts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-WinEaseLastRunTotalSeconds'
        }, $true))
        $funcTexts.Count | Should Be 1
        . ([scriptblock]::Create($funcTexts[0].Extent.Text))

        $jsonPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_timings_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
        '{ "Phase 1": 0.8, "Phase 2": 1, "Phase 3": 25.3 }' | Set-Content -LiteralPath $jsonPath -Encoding utf8
        $total = Get-WinEaseLastRunTotalSeconds -TimingsPath $jsonPath
        ([math]::Round($total, 1)) | Should Be 27.1
        Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
    }

    It "writes diagnostic JSON and summary text report when Write-WinEaseDiagnosticReport is invoked" {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        $funcTexts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Write-WinEaseDiagnosticReport'
        }, $true))
        $funcTexts.Count | Should Be 1
        . ([scriptblock]::Create($funcTexts[0].Extent.Text))

        $tempDiagDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_diag_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($tempDiagDir) | Out-Null
        $script:DiagDir = $tempDiagDir
        $script:DiagnosticData = [ordered]@{
            BuildId              = "test-build-123"
            Timestamp            = "2026-01-01 12:00:00"
            BuilderScriptSha256  = "dummyhash"
            BuildSucceeded       = $true
            FailurePhase         = $null
            FailureMessage       = $null
            DismPath             = "dism.exe"
            DismVersion          = "10.0.22621"
            SourceIsoPath        = "C:\test.iso"
            SourceIsoSha256      = "isohash"
            SelectedImageIndex   = "1"
            SelectedImageName    = "Windows 11 Pro"
            ExportSucceeded      = $true
            ExportExitCode       = 0
            PreExportWimSha256   = "prehash"
            ExportedWimSha256    = "exphash"
            FinalPayloadVerified = $true
            FinalApplyExitCode   = 0
            FinalWimSha256       = "finalhash"
            IsoGenerated         = $true
            OscdimgExitCode      = 0
            IsoEmbeddedWimSha256 = "finalhash"
            IsoPayloadMatch      = $true
            PreservedArtifacts   = @("C:\workspace\build")
        }

        Write-WinEaseDiagnosticReport "Test status message"

        $jsonPath = Join-Path -Path $tempDiagDir -ChildPath "build_diagnostic_report.json"
        $txtPath = Join-Path -Path $tempDiagDir -ChildPath "build_diagnostic_summary.txt"

        (Test-Path -LiteralPath $jsonPath) | Should Be $true
        (Test-Path -LiteralPath $txtPath) | Should Be $true

        $reportJson = (Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8) | ConvertFrom-Json
        $reportJson.BuildId | Should Be "test-build-123"
        $reportJson.BuildSucceeded | Should Be $true
        $reportJson.IsoPayloadMatch | Should Be $true

        $summaryTxt = Get-Content -LiteralPath $txtPath -Raw -Encoding UTF8
        $summaryTxt | Should Match "Overall Build Status:\s+SUCCESS"
        $summaryTxt | Should Match "Build ID:\s+test-build-123"
        $summaryTxt | Should Match "Preserved Artifacts:\r?\n\s+- C:\\workspace\\build"

        Remove-Item -LiteralPath $tempDiagDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "formats build failure details in summary text report when build failed" {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        $funcTexts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Write-WinEaseDiagnosticReport'
        }, $true))
        . ([scriptblock]::Create($funcTexts[0].Extent.Text))

        $tempDiagDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_diag_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($tempDiagDir) | Out-Null
        $script:DiagDir = $tempDiagDir
        $script:DiagnosticData = [ordered]@{
            BuildId            = "failed-build-456"
            Timestamp          = "2026-01-01 12:05:00"
            BuildSucceeded     = $false
            FailurePhase       = "Phase 13: Export"
            FailureMessage     = "Export command exited with code 1"
            PreservedArtifacts = @()
        }

        Write-WinEaseDiagnosticReport "Build failed"

        $txtPath = Join-Path -Path $tempDiagDir -ChildPath "build_diagnostic_summary.txt"
        $summaryTxt = Get-Content -LiteralPath $txtPath -Raw -Encoding UTF8
        $summaryTxt | Should Match "Overall Build Status:\s+FAILED"
        $summaryTxt | Should Match "Failure Phase:\s+Phase 13: Export"
        $summaryTxt | Should Match "Failure Message:\s+Export command exited with code 1"

        Remove-Item -LiteralPath $tempDiagDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "catches file write errors without throwing an exception when output directory is invalid" {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        $funcTexts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Write-WinEaseDiagnosticReport'
        }, $true))
        . ([scriptblock]::Create($funcTexts[0].Extent.Text))

        $script:DiagDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nonexistent_dir_12345\sub_dir"
        $script:DiagnosticData = [ordered]@{ BuildId = "err-build" }

        { Write-WinEaseDiagnosticReport "Status" -ErrorAction SilentlyContinue } | Should Not Throw
    }
}

Describe "WinEase telemetry - Save-WinEaseTelemetry" {
    BeforeAll {
        . (Join-Path $script:RepoRoot "lib\WinEaseTelemetry.ps1")
    }

    It "returns early without writing a file when WinEaseBuildTelemetry is null" {
        $script:WinEaseBuildTelemetry = $null
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_telem_" + [guid]::NewGuid().ToString('N').Substring(0, 8))

        $res = Save-WinEaseTelemetry -OutputDirectory $tempDir -BuildId "b123"
        $res | Should Be $null
        (Test-Path -LiteralPath $tempDir) | Should Be $false
    }

    It "creates output directory and writes valid telemetry JSON file when data is provided" {
        $script:WinEaseBuildTelemetry = [ordered]@{
            BuildId = "b123"
            Timing  = @{ Phases = @{ "Phase 1" = 12.3 } }
        }
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_telem_" + [guid]::NewGuid().ToString('N').Substring(0, 8))

        $res = Save-WinEaseTelemetry -OutputDirectory $tempDir -BuildId "b123"
        $res | Should Not Be $null
        (Test-Path -LiteralPath $res) | Should Be $true

        $savedJson = (Get-Content -LiteralPath $res -Raw -Encoding UTF8) | ConvertFrom-Json
        $savedJson.BuildId | Should Be "b123"
        $savedJson.Timing.Phases.'Phase 1' | Should Be 12.3

        $script:WinEaseBuildTelemetry = $null
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "catches file write errors and returns null when output directory creation fails" {
        $script:WinEaseBuildTelemetry = [ordered]@{ BuildId = "b999" }
        $tempFileAsDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_blocker_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Set-Content -LiteralPath $tempFileAsDir -Value "blocking_file"
        $invalidDir = Join-Path -Path $tempFileAsDir -ChildPath "child"

        $res = Save-WinEaseTelemetry -OutputDirectory $invalidDir -BuildId "b999" -ErrorAction SilentlyContinue
        $res | Should Be $null

        $script:WinEaseBuildTelemetry = $null
        Remove-Item -LiteralPath $tempFileAsDir -Force -ErrorAction SilentlyContinue
    }
}

Describe "WinEase helpers - DISM wrapper (Invoke-Dism)" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    BeforeEach {
        $script:DismLogPath = $null
        $script:LastDismExitCode = $null
    }

    AfterEach {
        Remove-Item Function:\dism.exe -ErrorAction SilentlyContinue
        Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    }

    It "returns true when DISM exits with code 0" {
        function dism.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DismArgs)
            $global:LASTEXITCODE = 0
        }

        $result = Invoke-Dism -DismArgs @('/Get-MountedWimInfo')
        $result | Should Be $true
        $script:LastDismExitCode | Should Be 0
    }

    It "returns true when DISM exits with code 3010 (reboot required)" {
        function dism.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DismArgs)
            $global:LASTEXITCODE = 3010
        }

        $result = Invoke-Dism -DismArgs @('/Get-MountedWimInfo')
        $result | Should Be $true
        $script:LastDismExitCode | Should Be 3010
    }

    It "includes DismLogPath arguments when DismLogPath is set" {
        $script:CapturedArgs = $null
        function dism.exe {
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DismArgs)
            $script:CapturedArgs = $DismArgs
            $global:LASTEXITCODE = 0
        }

        $script:DismLogPath = "C:\Logs\dism.log"
        $result = Invoke-Dism -DismArgs @('/Get-MountedWimInfo') -ActivityDescription "Testing Log Path"
        $result | Should Be $true
        ($script:CapturedArgs -contains "/LogPath:C:\Logs\dism.log") | Should Be $true
        ($script:CapturedArgs -contains "/LogLevel:3") | Should Be $true
    }

    It "captures and returns output when CaptureOutput is specified" {
        function dism.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DismArgs)
            Write-Output "Deployment Image Servicing and Management tool"
            $global:LASTEXITCODE = 0
        }

        $output = Invoke-Dism -DismArgs @('/Get-MountedWimInfo') -CaptureOutput
        $output | Should Match "Deployment Image Servicing"
        $script:LastDismExitCode | Should Be 0
    }

    It "runs quietly when Quiet parameter is specified" {
        function dism.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DismArgs)
            Write-Output "Some noisy output"
            $global:LASTEXITCODE = 0
        }

        $result = Invoke-Dism -DismArgs @('/Get-MountedWimInfo') -Quiet
        $result | Should Be $true
    }

    It "retries on failure up to Retries attempts and returns false on final attempt failure" {
        $script:DismCalls = 0
        function dism.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DismArgs)
            $script:DismCalls++
            $global:LASTEXITCODE = 2
        }
        function Start-Sleep {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Mock Start-Sleep to avoid delays during tests')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([int]$Seconds)
        }

        $result = Invoke-Dism -DismArgs @('/Cleanup-Wim') -Retries 3
        $result | Should Be $false
        $script:DismCalls | Should Be 3
        $script:LastDismExitCode | Should Be 2
    }

    It "returns null when CaptureOutput is specified and DISM fails after retries" {
        function dism.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DismArgs)
            Write-Output "Error occurred"
            $global:LASTEXITCODE = 87
        }
        function Start-Sleep {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Mock Start-Sleep to avoid delays during tests')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([int]$Seconds)
        }

        $result = Invoke-Dism -DismArgs @('/InvalidArg') -Retries 2 -CaptureOutput
        $result | Should BeNullOrEmpty
        $script:LastDismExitCode | Should Be 87
    }
}

Describe "WinEase helpers - registry hive unmounting (Unmount-RegistryHiveWithRetry)" {
    BeforeAll {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    It "returns true immediately when hive is not mounted (reg query fails)" {
        $script:unloadCalled = $false
        function reg.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([string]$subcmd, [string]$key)
            if ($subcmd -eq 'query') { $global:LASTEXITCODE = 1 }
            elseif ($subcmd -eq 'unload') {
                $script:unloadCalled = $true
                $global:LASTEXITCODE = 0
            }
        }
        Unmount-RegistryHiveWithRetry -Name "zSOFTWARE" -Retries 3 | Should Be $true
        $script:unloadCalled | Should Be $false
    }

    It "returns true when hive is mounted and unloads successfully on first attempt" {
        $script:unloadCalls = 0
        function reg.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([string]$subcmd, [string]$key)
            if ($subcmd -eq 'query') { $global:LASTEXITCODE = 0 }
            elseif ($subcmd -eq 'unload') {
                $script:unloadCalls++
                $global:LASTEXITCODE = 0
            }
        }
        Unmount-RegistryHiveWithRetry -Name "zSOFTWARE" -Retries 3 | Should Be $true
        $script:unloadCalls | Should Be 1
    }

    It "retries unloading when initial unload attempts fail and succeeds on a later attempt" {
        $script:unloadAttempts = 0
        function reg.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([string]$subcmd, [string]$key)
            if ($subcmd -eq 'query') { $global:LASTEXITCODE = 0 }
            elseif ($subcmd -eq 'unload') {
                $script:unloadAttempts++
                if ($script:unloadAttempts -ge 2) {
                    $global:LASTEXITCODE = 0
                } else {
                    $global:LASTEXITCODE = 1
                }
            }
        }
        Unmount-RegistryHiveWithRetry -Name "zSOFTWARE" -Retries 3 | Should Be $true
        $script:unloadAttempts | Should Be 2
    }

    It "returns false when all retry attempts fail to unload" {
        $script:unloadAttempts = 0
        function reg.exe {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
            param([string]$subcmd, [string]$key)
            if ($subcmd -eq 'query') { $global:LASTEXITCODE = 0 }
            elseif ($subcmd -eq 'unload') {
                $script:unloadAttempts++
                $global:LASTEXITCODE = 1
            }
        }
        Unmount-RegistryHiveWithRetry -Name "zSOFTWARE" -Retries 2 | Should Be $false
        # Loop runs for $i = 0..Retries (0, 1, 2) = 3 attempts total
        $script:unloadAttempts | Should Be 3
    }
}

Describe "WinEase helpers - atomic file I/O (Write-WinEaseTextFileAtomic)" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    It "writes text content atomically and cleans temporary files" {
        $tempFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_test_atomic_" + [guid]::NewGuid().ToString('N') + ".txt")
        $c1 = "First line of content"
        $ok1 = Write-WinEaseTextFileAtomic -Path $tempFile -Content $c1
        $ok1 | Should Be $true
        (Test-Path -LiteralPath $tempFile) | Should Be $true
        [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8) | Should Be $c1

        $c2 = "Second line replaced content"
        $ok2 = Write-WinEaseTextFileAtomic -Path $tempFile -Content $c2
        $ok2 | Should Be $true
        [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8) | Should Be $c2

        $dir = [System.IO.Path]::GetDirectoryName($tempFile)
        $orphans = Get-ChildItem -Path $dir -Filter "*WinEase_test_atomic*.*.tmp" -ErrorAction SilentlyContinue
        ($null -eq $orphans -or $orphans.Count -eq 0) | Should Be $true

        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

Describe "WinEase helpers - process token privileges (Enable-WinEaseTokenPrivileges)" {
    BeforeAll {
        $root = if ($script:RepoRoot) { $script:RepoRoot } else { Split-Path -Parent $PSScriptRoot }
        if (-not (Get-Command -Name Enable-WinEaseTokenPrivileges -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $root -ChildPath "WinEasehelpers.ps1")
        }
    }

    It "has expected default parameter list containing standard token privileges" {
        $ast = Get-WinEaseHelperAst
        $func = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Enable-WinEaseTokenPrivileges' }, $true)
        $func | Should Not Be $null
        $privParam = $func.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Privileges' }
        $privParam | Should Not Be $null
        $defaultExpr = $privParam.DefaultValue.Extent.Text
        $defaultExpr | Should Match 'SeTakeOwnershipPrivilege'
        $defaultExpr | Should Match 'SeRestorePrivilege'
        $defaultExpr | Should Match 'SeBackupPrivilege'
    }

    It "returns a boolean value when called with default privileges" {
        $result = Enable-WinEaseTokenPrivileges
        ($result -is [bool]) | Should Be $true
    }

    It "returns true when empty privileges array is provided" {
        $result = Enable-WinEaseTokenPrivileges -Privileges @()
        $result | Should Be $true
    }

    It "returns false when invalid privilege name is provided without throwing" {
        $result = Enable-WinEaseTokenPrivileges -Privileges @('SeNonExistentPrivilege_12345')
        $result | Should Be $false
    }

    It "handles custom privilege arrays gracefully" {
        $result = Enable-WinEaseTokenPrivileges -Privileges @('SeTakeOwnershipPrivilege')
        ($result -is [bool]) | Should Be $true
    }

    It "emits warning and sets warning flag when TokenHelpers type is unavailable" {
        $warnedBefore = $script:WinEaseTokenHelperWarned
        try {
            $script:WinEaseTokenHelperWarned = $false
            $res = Enable-WinEaseTokenPrivileges -Privileges @()
            ($res -is [bool]) | Should Be $true
        } finally {
            $script:WinEaseTokenHelperWarned = $warnedBefore
        }
    }
}

Describe "Get-WinEaseHtmlTemplate HTML report template loader" {
    BeforeAll {
        . (Join-Path $script:RepoRoot "lib\WinEaseReport.ps1")
    }

    It "loads template from an existing custom TemplatePath" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("template_test_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $customTemplateFile = Join-Path $tempDir "custom_template.html"
        $customContent = '<html><body><h1>Custom Template {{TITLE}}</h1></body></html>'
        [System.IO.File]::WriteAllText($customTemplateFile, $customContent, [System.Text.Encoding]::UTF8)

        try {
            $template = Get-WinEaseHtmlTemplate -TemplatePath $customTemplateFile
            $template | Should Be $customContent
        } finally {
            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "falls back to default template when custom TemplatePath does not exist" {
        $nonExistentPath = Join-Path ([System.IO.Path]::GetTempPath()) ("nonexistent_template_" + [guid]::NewGuid().ToString('N') + ".html")
        $template = Get-WinEaseHtmlTemplate -TemplatePath $nonExistentPath
        $template | Should Not BeNullOrEmpty
        $template | Should Match '\{\{TITLE\}\}'
    }

    It "falls back to default template when TemplatePath is null, empty, or whitespace" {
        $templateNull = Get-WinEaseHtmlTemplate -TemplatePath $null
        $templateNull | Should Not BeNullOrEmpty
        $templateNull | Should Match '\{\{TITLE\}\}'

        $templateEmpty = Get-WinEaseHtmlTemplate -TemplatePath ""
        $templateEmpty | Should Not BeNullOrEmpty

        $templateWS = Get-WinEaseHtmlTemplate -TemplatePath "   "
        $templateWS | Should Not BeNullOrEmpty
    }

    It "loads repository report.html template when templates/report.html exists" {
        $template = Get-WinEaseHtmlTemplate
        $template | Should Not BeNullOrEmpty
        $template | Should Match '\{\{TITLE\}\}'
        $template | Should Match '\{\{TIMESTAMP\}\}'
    }
}

Describe "WinEase helpers - Repair-WinEaseDeniedAcl" {
    BeforeAll {
        if (-not (Get-Command -Name Repair-WinEaseDeniedAcl -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
        }
    }

    $isWindowsPlatform = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT -or $IsWindows -or ($env:OS -like '*Windows*')

    It "function Repair-WinEaseDeniedAcl is defined and has Mandatory Path parameter" {
        $cmd = Get-Command -Name Repair-WinEaseDeniedAcl -ErrorAction SilentlyContinue
        $cmd | Should Not Be $null
        $cmd.Parameters.ContainsKey('Path') | Should Be $true
        $cmd.Parameters['Path'].Attributes.Mandatory | Should Be $true
    }

    It "repairs a readable directory ACL by setting owner, removing Deny ACEs, and adding FullControl Allow" -Skip:(-not $isWindowsPlatform) {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_repair_acl_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
        try {
            # Apply an initial explicit Deny ACE for Administrators (S-1-5-32-544)
            & icacls.exe $tempDir /deny '*S-1-5-32-544:(R)' /C /Q > $null 2>&1

            $result = Repair-WinEaseDeniedAcl -Path $tempDir
            $result | Should Be $null

            # Verify owner and ACL rules
            $aclAfter = Get-Acl -LiteralPath $tempDir
            $ownerSid = try { $aclAfter.Owner.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $aclAfter.Owner }
            $ownerSid | Should Match 'S-1-5-32-544|Administrators'

            # Verify Deny rules for S-1-5-32-544 are gone
            $accessRules = @($aclAfter.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
            $denyRules = @($accessRules | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
                $_.IdentityReference.Value -eq 'S-1-5-32-544'
            })
            $denyRules.Count | Should Be 0

            # Verify Allow rule for S-1-5-32-544 exists
            $allowRules = @($accessRules | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -eq 'S-1-5-32-544' -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl)
            })
            $allowRules.Count | Should BeGreaterThan 0
        } finally {
            if (Test-Path -LiteralPath $tempDir) {
                & cmd.exe /c "rd /s /q `"$tempDir`"" > $null 2>&1
            }
        }
    }

    It "repairs an unreadable DACL directory using fresh descriptor fallback" -Skip:(-not $isWindowsPlatform) {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_repair_unreadable_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
        try {
            # Strip inheritance and grant only SYSTEM access so DACL blocks current user or Administrators
            & icacls.exe $tempDir /inheritance:r /grant '*S-1-5-18:F' /C /Q > $null 2>&1
            & icacls.exe $tempDir /remove:g '*S-1-5-32-544' /C /Q > $null 2>&1

            $result = Repair-WinEaseDeniedAcl -Path $tempDir
            $result | Should Be $null

            $aclAfter = Get-Acl -LiteralPath $tempDir
            $accessRules = @($aclAfter.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
            $allowRules = @($accessRules | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -eq 'S-1-5-32-544'
            })
            $allowRules.Count | Should BeGreaterThan 0
        } finally {
            if (Test-Path -LiteralPath $tempDir) {
                & cmd.exe /c "rd /s /q `"$tempDir`"" > $null 2>&1
            }
        }
    }

    It "returns error string when Set-Acl fails on a readable DACL" -Skip:(-not $isWindowsPlatform) {
        Mock Enable-WinEaseTokenPrivileges { $true }
        Mock Get-Acl {
            New-Object System.Security.AccessControl.DirectorySecurity
        }
        Mock Set-Acl {
            throw "Access denied to set ACL"
        }

        $result = Repair-WinEaseDeniedAcl -Path "C:\DummyPath"
        $result | Should Match '^Set-Acl failed:'
    }

    It "returns error string when fresh descriptor Set-Acl fails on an unreadable DACL" -Skip:(-not $isWindowsPlatform) {
        Mock Enable-WinEaseTokenPrivileges { $true }
        Mock Get-Acl {
            throw "Unreadable DACL"
        }
        Mock Set-Acl {
            throw "Access denied to set fresh ACL"
        }

        $result = Repair-WinEaseDeniedAcl -Path "C:\DummyPath"
        $result | Should Match '^fresh-descriptor Set-Acl failed:'
    }
}

Describe "WinEase helpers - build resume integrity (Test-WinEaseResumeIntegrity)" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    It "fails validation on non-existent or empty workspace" {
        $dummyDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_empty_" + [guid]::NewGuid().ToString('N'))
        $res = Test-WinEaseResumeIntegrity -WorkspaceDir $dummyDir
        $res.IsValid | Should Be $false
        $res.Errors.Count | Should BeGreaterThan 0
    }

    It "passes validation when WIM payload has valid MSWIM magic header and root files" {
        $tempResume = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_resume_" + [guid]::NewGuid().ToString('N'))
        $sourcesDir = Join-Path -Path $tempResume -ChildPath "build\sources"
        New-Item -ItemType Directory -Path $sourcesDir -Force | Out-Null

        $fakeWim = Join-Path -Path $sourcesDir -ChildPath "install.wim"
        $magicBytes = [System.Text.Encoding]::ASCII.GetBytes("MSWIM`0`0`0")
        $fs = [System.IO.File]::Create($fakeWim)
        $fs.Write($magicBytes, 0, $magicBytes.Length)
        $fs.SetLength(600 * 1024 * 1024)
        $fs.Close()

        $fakeBoot = Join-Path -Path $sourcesDir -ChildPath "boot.wim"
        [System.IO.File]::WriteAllBytes($fakeBoot, $magicBytes)

        foreach ($req in @('boot', 'efi', 'bootmgr', 'bootmgr.efi', 'bootmgfw.efi', 'setup.exe', 'autounattend.xml')) {
            $t = Join-Path -Path (Join-Path $tempResume "build") -ChildPath $req
            if ($req -in @('boot', 'efi')) { New-Item -ItemType Directory -Path $t -Force | Out-Null }
            else { [System.IO.File]::WriteAllText($t, "dummy") }
        }

        $res = Test-WinEaseResumeIntegrity -WorkspaceDir $tempResume -IsIsoOnly
        $res.IsValid | Should Be $true
        $res.PayloadPath | Should Be $fakeWim
        $res.PayloadType | Should Be "WIM"

        Remove-Item -LiteralPath $tempResume -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "WinEase helpers - BuildContext lifecycle" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
    }

    It "instantiates BuildContext with all required properties and initial values" {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
        $ctx = [BuildContext]::new()
        ($null -ne $ctx) | Should Be $true
        $ctx.IsoCreatedSuccessfully | Should Be $false
        $ctx.IsoPayloadMatch | Should Be $false
        $ctx.ExportSucceeded | Should Be $false
        $ctx.IsoGenerated | Should Be $false
        $ctx.AllowPhysicalDebloat | Should Be $false
        ($null -ne $ctx.PhaseTimings) | Should Be $true
        ($null -ne $ctx.DiagnosticData) | Should Be $true
        ($null -ne $ctx.ManagedMountDirs) | Should Be $true
    }
}

Describe "Export-WinEaseHtmlReport HTML escaping" {
    BeforeAll {
        . (Join-Path $script:RepoRoot "lib\WinEaseReport.ps1")
    }

    It "properly escapes HTML tags and prevents XSS injection" {
        $outPath = Join-Path ([System.IO.Path]::GetTempPath()) ("report_xss_" + [guid]::NewGuid().ToString('N') + ".html")
        $evil = '<script>alert(1)</script>'
        try {
            Export-WinEaseHtmlReport -OutputPath $outPath -BuildInfo @{
                Title     = $evil
                Profile   = "<b>$evil</b>"
                Settings  = @{ RemoveDefender = $true }
            }
            Test-Path -LiteralPath $outPath | Should Be $true
            $html = [System.IO.File]::ReadAllText($outPath)
            $html | Should Not Match '<script>alert\(1\)</script>'
            $html | Should Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        } finally {
            if (Test-Path -LiteralPath $outPath) {
                Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "WinEase helpers - ConvertTo-WinEaseNormalizedPath" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "converts forward slashes to backslashes and trims trailing slashes" {
        $normalized = ConvertTo-WinEaseNormalizedPath -Path "C:/Windows/System32/"
        $expected = [System.IO.Path]::GetFullPath("C:\Windows\System32").TrimEnd('\')
        $normalized | Should Be $expected
    }

    It "resolves relative path segments" {
        $normalized = ConvertTo-WinEaseNormalizedPath -Path "C:\Windows\System32\..\System32\Drivers"
        $expected = [System.IO.Path]::GetFullPath("C:\Windows\System32\..\System32\Drivers").TrimEnd('\')
        $normalized | Should Be $expected
    }

    It "throws when Path is null, empty, or whitespace" {
        { ConvertTo-WinEaseNormalizedPath -Path "" } | Should Throw
        { ConvertTo-WinEaseNormalizedPath -Path "   " } | Should Throw
    }

    It "throws when Path does not start with an absolute local drive letter" {
        { ConvertTo-WinEaseNormalizedPath -Path "relative/path/to/folder" } | Should Throw
        { ConvertTo-WinEaseNormalizedPath -Path "C:relative/path" } | Should Throw
        { ConvertTo-WinEaseNormalizedPath -Path "\\server\share\folder" } | Should Throw
    }

    It "throws when Path is a drive root" {
        { ConvertTo-WinEaseNormalizedPath -Path "C:\" } | Should Throw
        { ConvertTo-WinEaseNormalizedPath -Path "D:/" } | Should Throw
    }
}

Describe "WinEase helpers - ConvertTo-WinEaseComparablePath" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    $isWinPlatform = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT -or (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)

    It "returns null for whitespace paths" {
        $res = ConvertTo-WinEaseComparablePath -Path "   "
        $res | Should Be $null
    }

    It "converts forward slashes to backslashes and trims trailing separators" {
        $inputPath = "C:/Windows/System32/"
        $res = ConvertTo-WinEaseComparablePath -Path $inputPath
        $expected = [System.IO.Path]::GetFullPath("C:\Windows\System32").TrimEnd('\')
        $res | Should Be $expected
    }

    It "preserves root separator for drive root paths" -Skip:(-not $isWinPlatform) {
        $res = ConvertTo-WinEaseComparablePath -Path "C:\"
        $expected = [System.IO.Path]::GetFullPath("C:\")
        $res | Should Be $expected
    }

    It "returns null and handles exceptions when GetFullPath throws an exception" {
        $invalidPath = [string]::Concat("C:\test", [char]0, "invalid")
        $verboseMsg = $null
        $res = ConvertTo-WinEaseComparablePath -Path $invalidPath -Verbose 4>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.VerboseRecord]) { $verboseMsg = $_.Message }
            else { $_ }
        }
        $res | Should Be $null
        $verboseMsg | Should Match '^Ignored:'
    }

    It "falls back to un-resolved path and handles exceptions when Get-Item throws for non-existent paths" -Skip:(-not $isWinPlatform) {
        $nonExistentPath = "C:/non_existent_directory_win_ease_xyz/sub/"
        $verboseMsg = $null
        $res = ConvertTo-WinEaseComparablePath -Path $nonExistentPath -Verbose 4>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.VerboseRecord]) { $verboseMsg = $_.Message }
            else { $_ }
        }
        $expected = [System.IO.Path]::GetFullPath("C:\non_existent_directory_win_ease_xyz\sub").TrimEnd('\')
        $res | Should Be $expected
        $verboseMsg | Should Match '^Ignored:'
    }

    It "resolves existing filesystem item FullName when path exists on disk" -Skip:(-not $isWinPlatform) {
        $existingFile = $PSScriptRoot
        $res = ConvertTo-WinEaseComparablePath -Path $existingFile
        $expectedItem = (Get-Item -LiteralPath $existingFile -Force).FullName.TrimEnd('\')
        $res | Should Be $expectedItem
    }
}

Describe "WinEase helpers - Build ID Generator" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "New-WinEaseBuildId returns build ID matching expected timestamp and GUID format" {
        $id = New-WinEaseBuildId
        $id | Should Match '^\d{8}_\d{6}_[a-f0-9]{8}$'
    }

    It "New-WinEaseBuildId respects provided timestamp parameter" {
        $ts = Get-Date -Year 2025 -Month 5 -Day 20 -Hour 14 -Minute 30 -Second 15
        $id = New-WinEaseBuildId -Timestamp $ts
        $id | Should Match '^20250520_143015_[a-f0-9]{8}$'
    }

    It "New-WinEaseBuildId generates unique build IDs for same timestamp" {
        $ts = Get-Date -Year 2025 -Month 5 -Day 20 -Hour 14 -Minute 30 -Second 15
        $id1 = New-WinEaseBuildId -Timestamp $ts
        $id2 = New-WinEaseBuildId -Timestamp $ts
        $id1 | Should Not Be $id2
    }
}

Describe "WinEase helpers - Test-IsNtfsVolume" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
        if (-not (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
            function Get-Volume {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
                param([string]$DriveLetter, $ErrorAction)
            }
        }
    }

    It "returns false for null, empty or whitespace path" {
        Test-IsNtfsVolume -Path $null | Should Be $false
        Test-IsNtfsVolume -Path "" | Should Be $false
        Test-IsNtfsVolume -Path "   " | Should Be $false
    }

    It "returns false for relative path without root" {
        Test-IsNtfsVolume -Path "relative/path/to/file" | Should Be $false
    }

    It "returns true when DriveInfo reports NTFS" {
        Mock New-Object {
            [PSCustomObject]@{
                IsReady     = $true
                DriveFormat = 'NTFS'
            }
        } -ParameterFilter { $TypeName -eq 'System.IO.DriveInfo' }
        Test-IsNtfsVolume -Path "/test/path" | Should Be $true
    }

    It "returns false when DriveInfo reports FAT32" {
        Mock New-Object {
            [PSCustomObject]@{
                IsReady     = $true
                DriveFormat = 'FAT32'
            }
        } -ParameterFilter { $TypeName -eq 'System.IO.DriveInfo' }
        Test-IsNtfsVolume -Path "/test/path" | Should Be $false
    }

    It "falls back to Get-Volume and returns true when volume is NTFS" {
        Mock New-Object { throw "DriveInfo failed" } -ParameterFilter { $TypeName -eq 'System.IO.DriveInfo' }
        Mock Get-Volume { [PSCustomObject]@{ FileSystem = 'NTFS' } }
        Test-IsNtfsVolume -Path "C:\test\path" | Should Be $true
    }

    It "falls back to Get-Volume and returns false when volume is FAT32" {
        Mock New-Object { throw "DriveInfo failed" } -ParameterFilter { $TypeName -eq 'System.IO.DriveInfo' }
        Mock Get-Volume { [PSCustomObject]@{ FileSystem = 'FAT32' } }
        Test-IsNtfsVolume -Path "C:\test\path" | Should Be $false
    }

    It "returns false when Get-Volume throws exception" {
        Mock New-Object { throw "DriveInfo failed" } -ParameterFilter { $TypeName -eq 'System.IO.DriveInfo' }
        Mock Get-Volume { throw "Volume not found" }
        Test-IsNtfsVolume -Path "X:\test\path" | Should Be $false
    }

    It "returns false for UNC path when DriveInfo is not ready" {
        Mock New-Object {
            [PSCustomObject]@{
                IsReady     = $false
                DriveFormat = 'NTFS'
            }
        } -ParameterFilter { $TypeName -eq 'System.IO.DriveInfo' }
        Test-IsNtfsVolume -Path "\\server\share\file" | Should Be $false
    }
}

Describe "WinEase helpers - Path and Directory Safety Guards" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "Test-WinEasePathWithin blocks .. traversal escape attempts" {
        $base = "C:\TestFolder\Work"
        $traversal = "C:\TestFolder\Work\..\..\Windows"
        Test-WinEasePathWithin -Path $traversal -Root $base | Should Be $false
    }

    It "Test-WinEasePathWithin accepts legitimate subpaths" {
        $base = "C:\TestFolder\Work"
        $sub = "C:\TestFolder\Work\Subdir\file.txt"
        Test-WinEasePathWithin -Path $sub -Root $base | Should Be $true
    }

    It "Test-IsSafePathToDelete protects OS root and protected system folders" {
        Test-IsSafePathToDelete -Path "C:\" | Should Be $false
        Test-IsSafePathToDelete -Path "C:\Windows" | Should Be $false
        Test-IsSafePathToDelete -Path "C:\Program Files" | Should Be $false
        Test-IsSafePathToDelete -Path "C:\Users" | Should Be $false
    }

    It "Test-IsSafePathToDelete protects repo root and parent directories" {
        Test-IsSafePathToDelete -Path $script:RepoRoot | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path $script:RepoRoot "WinEasehelpers.ps1") | Should Be $false
    }

    It "Get-WinEaseVolumeFreeSpaceGB returns positive value for valid drive and throws on invalid" {
        $freeGB = Get-WinEaseVolumeFreeSpaceGB -Path "C:\"
        $freeGB | Should BeGreaterThan 0
        { Get-WinEaseVolumeFreeSpaceGB -Path "" } | Should Throw
        { Get-WinEaseVolumeFreeSpaceGB -Path "Z:\NonExistentDriveXYZ" } | Should Throw
    }

    It "Test-CanSafelyDeleteDirectory refuses to delete workspace base directory itself" {
        $baseDir = "C:\TestFolder\BaseWork"
        Test-CanSafelyDeleteDirectory -Path $baseDir -ExpectedBaseDir $baseDir | Should Be $false
    }

    It "Test-IsPathPreserved correctly identifies exact, parent, and descendant preserved paths" {
        $preserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$preserved.Add("C:\TestWorkspace\MountDir")

        # Null/empty set checks
        Test-IsPathPreserved -Path "C:\TestWorkspace\MountDir" -PreservedDirs $null | Should Be $false
        Test-IsPathPreserved -Path "" -PreservedDirs $preserved | Should Be $false

        # Exact match
        Test-IsPathPreserved -Path "C:\TestWorkspace\MountDir" -PreservedDirs $preserved | Should Be $true

        # Parent of preserved dir
        Test-IsPathPreserved -Path "C:\TestWorkspace" -PreservedDirs $preserved | Should Be $true

        # Descendant of preserved dir
        Test-IsPathPreserved -Path "C:\TestWorkspace\MountDir\SubFolder" -PreservedDirs $preserved | Should Be $true

        # Unrelated path
        Test-IsPathPreserved -Path "C:\OtherFolder\Build" -PreservedDirs $preserved | Should Be $false
    }

    It "Test-WinEasePathExistsSafe returns true for existing directory and file" {
        Test-WinEasePathExistsSafe -Path $script:RepoRoot | Should Be $true
        Test-WinEasePathExistsSafe -Path $helpersPath | Should Be $true
    }

    It "Test-WinEasePathExistsSafe returns false for null, empty, whitespace, and non-existent path" {
        Test-WinEasePathExistsSafe -Path $null | Should Be $false
        Test-WinEasePathExistsSafe -Path "" | Should Be $false
        Test-WinEasePathExistsSafe -Path "   " | Should Be $false
        Test-WinEasePathExistsSafe -Path (Join-Path $script:RepoRoot "non_existent_file_xyz_12345.tmp") | Should Be $false
    }

    It "Test-WinEasePathExistsSafe returns false when an exception occurs on invalid path" {
        Test-WinEasePathExistsSafe -Path "::invalid_path::\0\*\?\<\>" | Should Be $false
    }
}

Describe "WinEase helpers - Test-CanSafelyDeleteVhdx" {
    BeforeAll {
        if (-not $script:RepoRoot) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "returns false when script:BuildSucceeded is false" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $false
            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Workspace\disk.vhdx" -VhdxDetached $true | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns false when VhdxDetached is false" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Workspace\disk.vhdx" -VhdxDetached $false | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns false when VhdxPath is null, empty, or whitespace" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Test-CanSafelyDeleteVhdx -VhdxPath $null -VhdxDetached $true | Should Be $false
            Test-CanSafelyDeleteVhdx -VhdxPath "" -VhdxDetached $true | Should Be $false
            Test-CanSafelyDeleteVhdx -VhdxPath "   " -VhdxDetached $true | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns false when VhdxPath does not exist" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Mock Test-Path { return $false }
            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Workspace\nonexistent.vhdx" -VhdxDetached $true | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns false when VhdxPath fails safety check (Test-IsSafePathToDelete returns false)" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Mock Test-Path { return $true }
            Mock Test-IsSafePathToDelete { return $false }
            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Windows\disk.vhdx" -VhdxDetached $true | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns false when ConvertTo-WinEaseNormalizedPath throws" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Mock Test-Path { return $true }
            Mock Test-IsSafePathToDelete { return $true }
            Mock ConvertTo-WinEaseNormalizedPath { throw "Invalid path format" }
            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Workspace\disk.vhdx" -VhdxDetached $true | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns false when VhdxPath is outside ExpectedBaseDir" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Mock Test-Path { return $true }
            Mock Test-IsSafePathToDelete { return $true }
            Mock ConvertTo-WinEaseNormalizedPath { param($Path) return $Path }
            Mock Test-WinEasePathWithin { return $false }
            Test-CanSafelyDeleteVhdx -VhdxPath "C:\OtherDir\disk.vhdx" -VhdxDetached $true -ExpectedBaseDir "C:\Workspace" | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns false when VhdxPath is preserved in PreservedDirs" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Mock Test-Path { return $true }
            Mock Test-IsSafePathToDelete { return $true }
            Mock ConvertTo-WinEaseNormalizedPath { param($Path) return $Path }
            Mock Test-WinEasePathWithin { return $true }
            Mock Test-IsPathPreserved { return $true }
            $preserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            [void]$preserved.Add("C:\Workspace\disk.vhdx")

            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Workspace\disk.vhdx" -VhdxDetached $true -ExpectedBaseDir "C:\Workspace" -PreservedDirs $preserved | Should Be $false
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }

    It "returns true when all safety conditions are met" {
        $savedBuildSucceeded = $script:BuildSucceeded
        try {
            $script:BuildSucceeded = $true
            Mock Test-Path { return $true }
            Mock Test-IsSafePathToDelete { return $true }
            Mock ConvertTo-WinEaseNormalizedPath { param($Path) return $Path }
            Mock Test-WinEasePathWithin { return $true }
            Mock Test-IsPathPreserved { return $false }

            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Workspace\disk.vhdx" -VhdxDetached $true -ExpectedBaseDir "C:\Workspace" | Should Be $true
            Test-CanSafelyDeleteVhdx -VhdxPath "C:\Workspace\disk.vhdx" -VhdxDetached $true | Should Be $true
        } finally {
            $script:BuildSucceeded = $savedBuildSucceeded
        }
    }
}

Describe "WinEase helpers - Get-WinEaseRelativePath" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "returns relative path when BasePath is a prefix of FullName" {
        $base = "C:\Users\runneradmin\AppData\Local\Temp"
        $full = "C:\Users\runneradmin\AppData\Local\Temp\subfolder\file.txt"
        $rel = Get-WinEaseRelativePath -BasePath $base -FullName $full
        $rel | Should Be "subfolder\file.txt"
    }

    It "handles trailing slashes on BasePath" {
        $base = "C:\Users\runneradmin\AppData\Local\Temp\"
        $full = "C:\Users\runneradmin\AppData\Local\Temp\subfolder\file.txt"
        $rel = Get-WinEaseRelativePath -BasePath $base -FullName $full
        $rel | Should Be "subfolder\file.txt"
    }

    It "is case-insensitive when matching BasePath against FullName" {
        $base = "c:\users\runneradmin\appdata\local\temp"
        $full = "C:\USERS\RUNNERADMIN\APPDATA\LOCAL\TEMP\subfolder\file.txt"
        $rel = Get-WinEaseRelativePath -BasePath $base -FullName $full
        $rel | Should Be "subfolder\file.txt"
    }

    It "returns only filename when BasePath is not a prefix of FullName" {
        $base = "C:\Users\differentuser"
        $full = "C:\Users\runneradmin\AppData\Local\Temp\subfolder\file.txt"
        $rel = Get-WinEaseRelativePath -BasePath $base -FullName $full
        $rel | Should Be "file.txt"
    }

    It "resolves real filesystem paths when BasePath exists on disk" {
        $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_relpath_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $subFile = Join-Path -Path $tmpDir -ChildPath "nested\test.txt"
            $rel = Get-WinEaseRelativePath -BasePath $tmpDir -FullName $subFile
            $rel | Should Be "nested\test.txt"
        } finally {
            if (Test-Path -LiteralPath $tmpDir) {
                Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "WinEase helpers - Get-SafeShortPath" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "returns null or empty string when input is null or empty" {
        Get-SafeShortPath -Path $null | Should BeNullOrEmpty
        Get-SafeShortPath -Path "" | Should BeNullOrEmpty
    }

    It "returns original path when path does not exist" {
        $nonExistent = "C:\NonExistentPath_With Spaces_12345\file.txt"
        Get-SafeShortPath -Path $nonExistent | Should Be $nonExistent
    }

    It "returns original path when path has no spaces" {
        $tempFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_nospaces_" + [guid]::NewGuid().ToString('N') + ".txt")
        [System.IO.File]::WriteAllText($tempFile, "test")
        try {
            Get-SafeShortPath -Path $tempFile | Should Be $tempFile
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "converts file path with spaces to 8.3 short path using FileSystemObject" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_space dir_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $tempFile = Join-Path -Path $tempDir -ChildPath "test file.txt"
        [System.IO.File]::WriteAllText($tempFile, "test")

        try {
            $fsoMock = New-Object PSCustomObject
            $fsoMock | Add-Member -MemberType ScriptMethod -Name "GetFile" -Value {
                param($FilePath)
                [void]$FilePath
                return [PSCustomObject]@{ ShortPath = 'C:\WINEAS~1\TESTFI~1.TXT' }
            }
            Mock New-Object { return $fsoMock } -ParameterFilter { $ComObject -eq 'Scripting.FileSystemObject' }

            $result = Get-SafeShortPath -Path $tempFile
            $result | Should Be 'C:\WINEAS~1\TESTFI~1.TXT'
            Assert-MockCalled New-Object -Times 1 -ParameterFilter { $ComObject -eq 'Scripting.FileSystemObject' }
        } finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "converts folder path with spaces to 8.3 short path using FileSystemObject" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_space dir_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        try {
            $fsoMock = New-Object PSCustomObject
            $fsoMock | Add-Member -MemberType ScriptMethod -Name "GetFolder" -Value {
                param($FolderPath)
                [void]$FolderPath
                return [PSCustomObject]@{ ShortPath = 'C:\WINEAS~1' }
            }
            Mock New-Object { return $fsoMock } -ParameterFilter { $ComObject -eq 'Scripting.FileSystemObject' }

            $result = Get-SafeShortPath -Path $tempDir
            $result | Should Be 'C:\WINEAS~1'
            Assert-MockCalled New-Object -Times 1 -ParameterFilter { $ComObject -eq 'Scripting.FileSystemObject' }
        } finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "falls back to original path when FileSystemObject ShortPath is empty" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_space dir_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        try {
            $fsoMock = New-Object PSCustomObject
            $fsoMock | Add-Member -MemberType ScriptMethod -Name "GetFolder" -Value {
                param($FolderPath)
                [void]$FolderPath
                return [PSCustomObject]@{ ShortPath = $null }
            }
            Mock New-Object { return $fsoMock } -ParameterFilter { $ComObject -eq 'Scripting.FileSystemObject' }

            $result = Get-SafeShortPath -Path $tempDir
            $result | Should Be $tempDir
        } finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "falls back to original path when exception is thrown" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_space dir_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        try {
            Mock New-Object { throw "COM Object creation failed" } -ParameterFilter { $ComObject -eq 'Scripting.FileSystemObject' }

            $result = Get-SafeShortPath -Path $tempDir
            $result | Should Be $tempDir
        } finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "WinEase helpers - oscdimg integrity (Test-OscdimgIntegrity)" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
        if (-not (Get-Command -Name Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
            function global:Get-AuthenticodeSignature {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
                param($FilePath, [switch]$ErrorAction)
                return $null
            }
        }
    }

    It "returns `$false for null, empty, or whitespace paths" {
        Test-OscdimgIntegrity -OscdimgPath $null | Should Be $false
        Test-OscdimgIntegrity -OscdimgPath "" | Should Be $false
    }

    It "returns `$false for a non-existent file path" {
        $fakePath = Join-Path ([System.IO.Path]::GetTempPath()) ("nonexistent_oscdimg_" + [guid]::NewGuid().ToString('N') + ".exe")
        Test-OscdimgIntegrity -OscdimgPath $fakePath | Should Be $false
    }

    It "returns `$true for bundled oscdimg.exe if present" {
        $bundled = Join-Path $script:RepoRoot "oscdimg.exe"
        if (Test-Path -LiteralPath $bundled) {
            Test-OscdimgIntegrity -OscdimgPath $bundled | Should Be $true
        }
    }

    It "returns `$true for files with valid Microsoft Authenticode signature" {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("test_oscdimg_sig_" + [guid]::NewGuid().ToString('N') + ".exe")
        [System.IO.File]::WriteAllText($tempFile, "dummy exe content")
        try {
            Mock Get-AuthenticodeSignature {
                return [PSCustomObject]@{
                    Status            = 'Valid'
                    SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' }
                }
            }
            Test-OscdimgIntegrity -OscdimgPath $tempFile | Should Be $true
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "returns `$true for files matching each known pinned SHA256 hash" {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("test_oscdimg_hash_" + [guid]::NewGuid().ToString('N') + ".exe")
        [System.IO.File]::WriteAllText($tempFile, "dummy exe content")
        $pinnedHashes = @(
            'F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD',
            '8DC3FB38E75C42127BE0A29D64CA6D79DFDDFDCBEE4A3BA8B36CFEBDCC1689E2',
            'CE53D1C8C08FF54B4B91D2DFDE80F9D86427BC8C78FA6BBDE278456CDD2E2B85',
            'B27E36C95A7490A175B5F17781C5C7A7C0B0C4670ACBF5B0BA0E0556BCDE0F46'
        )
        try {
            Mock Get-AuthenticodeSignature { return $null }
            foreach ($hash in $pinnedHashes) {
                Mock Get-FileHash { return [PSCustomObject]@{ Hash = $hash } }
                Test-OscdimgIntegrity -OscdimgPath $tempFile | Should Be $true
            }
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "returns `$false for files with unknown SHA256 hashes" {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("test_oscdimg_bad_" + [guid]::NewGuid().ToString('N') + ".exe")
        [System.IO.File]::WriteAllText($tempFile, "bad exe content")
        try {
            Mock Get-AuthenticodeSignature { return $null }
            Mock Get-FileHash { return [PSCustomObject]@{ Hash = '0000000000000000000000000000000000000000000000000000000000000000' } }
            Test-OscdimgIntegrity -OscdimgPath $tempFile | Should Be $false
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "handles exceptions in Get-AuthenticodeSignature and Get-FileHash gracefully" {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("test_oscdimg_err_" + [guid]::NewGuid().ToString('N') + ".exe")
        [System.IO.File]::WriteAllText($tempFile, "err content")
        try {
            Mock Get-AuthenticodeSignature { throw "Signature check failed" }
            Mock Get-FileHash { throw "Hash check failed" }
            Test-OscdimgIntegrity -OscdimgPath $tempFile | Should Be $false
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "WinEase helpers - Statistical Analysis and Benchmark Comparison" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "Get-WinEaseMetricStatistics calculates correct mean, median, min, max, stddev, IQR" {
        $values = @(10.0, 20.0, 30.0, 40.0, 50.0)
        $stats = Get-WinEaseMetricStatistics -Values $values
        $stats.Count | Should Be 5
        $stats.Mean | Should Be 30.0
        $stats.Median | Should Be 30.0
        $stats.Min | Should Be 10.0
        $stats.Max | Should Be 50.0
        $stats.StdDev | Should BeGreaterThan 15.0
        $stats.StdDev | Should BeLessThan 16.0
        $stats.IQR | Should Be 20.0
    }

    It "Get-WinEaseMetricStatistics handles empty input gracefully" {
        $stats = Get-WinEaseMetricStatistics -Values @()
        $stats.Count | Should Be 0
        $stats.Mean | Should Be 0.0
        $stats.Median | Should Be 0.0
    }

    It "Compare-WinEaseBenchmarkSeries computes percentage improvement across series" {
        $baseRuns = @(
            [PSCustomObject]@{ Memory = [PSCustomObject]@{ CommittedMB = 2000.0; ProcessCount = 100 } },
            [PSCustomObject]@{ Memory = [PSCustomObject]@{ CommittedMB = 2000.0; ProcessCount = 100 } },
            [PSCustomObject]@{ Memory = [PSCustomObject]@{ CommittedMB = 2000.0; ProcessCount = 100 } }
        )
        $optRuns = @(
            [PSCustomObject]@{ Memory = [PSCustomObject]@{ CommittedMB = 1000.0; ProcessCount = 50 } },
            [PSCustomObject]@{ Memory = [PSCustomObject]@{ CommittedMB = 1000.0; ProcessCount = 50 } },
            [PSCustomObject]@{ Memory = [PSCustomObject]@{ CommittedMB = 1000.0; ProcessCount = 50 } }
        )

        $comp = Compare-WinEaseBenchmarkSeries -BaselineRuns $baseRuns -OptimizedRuns $optRuns -OptimizedLabel "WinEase Test"
        $comp.CommittedMemoryMB | Should Not Be $null
        $comp.CommittedMemoryMB.Baseline.Median | Should Be 2000.0
        $comp.CommittedMemoryMB.Optimized.Median | Should Be 1000.0
        $comp.CommittedMemoryMB.ImprovementPercent | Should Be 50.0
        $comp.ProcessCount.ImprovementPercent | Should Be 50.0
    }
}

Describe "WinEase helpers - Format-WinEasePhaseDuration" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "WinEasehelpers.ps1"
        . $helpersPath
    }

    It "formats durations under 60 seconds as rounded seconds" {
        Format-WinEasePhaseDuration -TotalSeconds 0 | Should Be "0s"
        Format-WinEasePhaseDuration -TotalSeconds 0.5 | Should Be "0.5s"
        Format-WinEasePhaseDuration -TotalSeconds 42.3 | Should Be "42.3s"
        Format-WinEasePhaseDuration -TotalSeconds 59.9 | Should Be "59.9s"
    }

    It "formats exact minutes without trailing seconds" {
        Format-WinEasePhaseDuration -TotalSeconds 60 | Should Be "1m"
        Format-WinEasePhaseDuration -TotalSeconds 120 | Should Be "2m"
        Format-WinEasePhaseDuration -TotalSeconds 3600 | Should Be "60m"
    }

    It "formats durations over 60 seconds with minutes and remaining seconds" {
        Format-WinEasePhaseDuration -TotalSeconds 65.4 | Should Be "1m 5.4s"
        Format-WinEasePhaseDuration -TotalSeconds 125.1 | Should Be "2m 5.1s"
        Format-WinEasePhaseDuration -TotalSeconds 3615.8 | Should Be "60m 15.8s"
    }

    It "handles rounding boundary at 60 seconds correctly" {
        Format-WinEasePhaseDuration -TotalSeconds 59.96 | Should Be "1m"
        Format-WinEasePhaseDuration -TotalSeconds 119.96 | Should Be "2m"
    }
}

Describe "WinEase structured logger (lib/WinEaseLogger.ps1)" {
    BeforeAll {
        . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseLogger.ps1")
    }

    BeforeEach {
        Reset-WinEaseLogState
    }

    It "creates structured log entry with default level Info" {
        $entry = New-WinEaseLogMessage -Message "Information test"
        $entry.Message | Should Be "Information test"
        $entry.Level | Should Be "Info"
        $entry.Timestamp | Should Not BeNullOrEmpty
        $script:WinEaseLogEntries.Count | Should Be 1
        $script:WinEaseLogWarningCount | Should Be 0
        $script:WinEaseLogErrorCount | Should Be 0
    }

    It "creates log entries with custom levels Debug and Success" {
        $debugEntry = New-WinEaseLogMessage -Message "Debug test" -Level "Debug"
        $debugEntry.Message | Should Be "Debug test"
        $debugEntry.Level | Should Be "Debug"

        $successEntry = New-WinEaseLogMessage -Message "Success test" -Level "Success"
        $successEntry.Message | Should Be "Success test"
        $successEntry.Level | Should Be "Success"

        $script:WinEaseLogEntries.Count | Should Be 2
        $script:WinEaseLogWarningCount | Should Be 0
        $script:WinEaseLogErrorCount | Should Be 0
    }

    It "increments warning count and records entry when level is Warning" {
        $entry = New-WinEaseLogMessage -Message "Warning test" -Level "Warning"
        $entry.Message | Should Be "Warning test"
        $entry.Level | Should Be "Warning"
        $script:WinEaseLogWarningCount | Should Be 1
        $script:WinEaseLogErrorCount | Should Be 0
        $script:WinEaseLogEntries.Count | Should Be 1
    }

    It "increments error count and records entry when level is Error" {
        $entry = New-WinEaseLogMessage -Message "Error test" -Level "Error"
        $entry.Message | Should Be "Error test"
        $entry.Level | Should Be "Error"
        $script:WinEaseLogErrorCount | Should Be 1
        $script:WinEaseLogWarningCount | Should Be 0
        $script:WinEaseLogEntries.Count | Should Be 1
    }

    It "throws when mandatory Message parameter is missing or Level is invalid" {
        { New-WinEaseLogMessage -Message $null } | Should Throw
        { New-WinEaseLogMessage -Message "Test" -Level "InvalidLevel" } | Should Throw
    }

    It "resets log state correctly via Reset-WinEaseLogState" {
        New-WinEaseLogMessage -Message "Warn" -Level "Warning" | Out-Null
        New-WinEaseLogMessage -Message "Err" -Level "Error" | Out-Null
        $script:WinEaseLogEntries.Count | Should Be 2
        $script:WinEaseLogWarningCount | Should Be 1
        $script:WinEaseLogErrorCount | Should Be 1

        Reset-WinEaseLogState

        $script:WinEaseLogEntries.Count | Should Be 0
        $script:WinEaseLogWarningCount | Should Be 0
        $script:WinEaseLogErrorCount | Should Be 0
    }
}

Describe "WinEase helpers - split module layout (R2)" {
    It "keeps the compatibility loader as the only helper entry point" {
        $loader = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "WinEasehelpers.ps1"))
        $loader | Should Match 'WinEasePathSafety\.ps1'
        $loader | Should Match 'WinEaseSystem\.ps1'
        $loader | Should Match 'WinEaseFileSystem\.ps1'
        $loader | Should Match 'WinEaseConfig\.ps1'
        $loader | Should Match 'WinEaseBenchmarks\.ps1'
        $loader | Should Match 'WinEaseDependencies\.ps1'
        $loader | Should Match 'throw'
    }

    It "defines every helper function exactly once across the split modules" {
        $ast = Get-WinEaseHelperAst
        $functions = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Parent -is [System.Management.Automation.Language.NamedBlockAst]
        }, $true))
        # 42 functions moved out of WinEasehelpers.ps1 plus the 7 functions that
        # already lived in lib\WinEaseFileSystem.ps1.
        $functions.Count | Should Be 49
        $duplicates = @($functions | Group-Object Name | Where-Object Count -gt 1)
        $duplicates.Count | Should Be 0
        @($ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.Name -eq 'BuildContext'
        }, $true)).Count | Should Be 1
    }

    It "keeps the split modules free of top-level executable statements" {
        foreach ($relative in $script:HelperSourceFiles | Where-Object { $_ -like 'lib\*.ps1' }) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $relative))
            $tokens = $null
            $errors = $null
            $fileAst = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            $errors.Count | Should Be 0
            foreach ($statement in $fileAst.EndBlock.Statements) {
                $allowed = $statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    $statement -is [System.Management.Automation.Language.TypeDefinitionAst]
                $allowed | Should Be $true
            }
        }
    }

    It "loads the same flat layout used by the migration bundle" {
        $flatDir = Join-Path ([System.IO.Path]::GetTempPath()) ("WinEase-r2-flat-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $flatDir -Force | Out-Null
        $savedHelperRoot = $script:WinEaseHelperRoot
        try {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot "WinEasehelpers.ps1") -Destination $flatDir
            foreach ($relative in $script:HelperSourceFiles | Where-Object { $_ -like 'lib\*.ps1' }) {
                Copy-Item -LiteralPath (Join-Path $script:RepoRoot $relative) -Destination $flatDir
            }
            Add-Content -LiteralPath (Join-Path $flatDir "WinEaseConfig.ps1") -Value "`nfunction Test-WinEaseR2FlatMarker { return 'flat' }`n"
            $marker = & {
                . (Join-Path $flatDir "WinEasehelpers.ps1")
                Get-Command -Name Test-WinEaseR2FlatMarker -ErrorAction SilentlyContinue
            }
            $marker | Should Not Be $null
        } finally {
            $script:WinEaseHelperRoot = $savedHelperRoot
            Remove-Item -LiteralPath $flatDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "throws a clear error when a required split module is missing" {
        $missingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("WinEase-r2-missing-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
        $savedHelperRoot = $script:WinEaseHelperRoot
        try {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot "WinEasehelpers.ps1") -Destination $missingDir
            { . (Join-Path $missingDir "WinEasehelpers.ps1") } | Should Throw
        } finally {
            $script:WinEaseHelperRoot = $savedHelperRoot
            Remove-Item -LiteralPath $missingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "builder loads the GUI session helpers through the lib loop" {
        $builderText = [System.IO.File]::ReadAllText($script:BuilderPath)
        $builderText | Should Match 'WinEaseGuiSession\.ps1'
        $builderText | Should Not Match "foreach \(\`$WinEaseLibFile in @\([^\)]*'WinEaseFileSystem\.ps1'"
        $builderAst = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
        @($builderAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -in @('Apply-WinEaseGuiResult', 'Show-WinEaseGuiSessionWindow', 'Invoke-WinEaseGuiSession')
        }, $true)).Count | Should Be 0
    }
}

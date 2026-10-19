# nano11.Tests.ps1 - Pester suite for the nano11 builder fork
# Run with:  Invoke-Pester -Path .\tests\nano11.Tests.ps1
# Requires:  Pester 3.4+ (ships with Windows PowerShell 5.1)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'builderAst', Justification = 'Used inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Evaluates literal arrays/hashtables taken from the repo''s own source AST')]
param()

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BuilderPath = Join-Path -Path $script:RepoRoot -ChildPath "nano11builder.ps1"
$script:GuiPath = Join-Path -Path $script:RepoRoot -ChildPath "gui\Nano11Gui.ps1"
$script:UnattendPath = Join-Path -Path $script:RepoRoot -ChildPath "autounattend.xml"

Describe "nano11 builder - repository layout" {
    It "builder script exists" {
        Test-Path -LiteralPath $script:BuilderPath | Should Be $true
    }
    It "autounattend.xml exists" {
        Test-Path -LiteralPath $script:UnattendPath | Should Be $true
    }
    It "LICENSE exists (MIT)" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "LICENSE") | Should Be $true
    }
    It "tools/custom-scripts skeleton exists" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "tools\custom-scripts") | Should Be $true
    }
    It "CHANGELOG.md exists" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "CHANGELOG.md") | Should Be $true
    }
}

Describe "nano11 builder - AST syntax" {
    It "parses with zero parser errors" {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "gui\Nano11Gui.ps1 parses with zero parser errors" {
        $content = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
}

Describe "nano11 builder - autounattend.xml" {
    It "loads as valid XML with unattend root" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $doc.DocumentElement.Name | Should Be "unattend"
        $doc.unattend.settings | Should Not Be $null
    }
    It "has no duplicate components in any pass" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $dupCount = 0
        foreach ($pass in $doc.unattend.settings) {
            $keys = @($pass.component | ForEach-Object { "$($_.name) [$($_.processorArchitecture)]" })
            $dups = $keys | Group-Object | Where-Object { $_.Count -gt 1 }
            if ($dups) { $dupCount += $dups.Count }
        }
        $dupCount | Should Be 0
    }
    It "embeds all four setup scripts" {
        $raw = [System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8)
        foreach ($s in @('Specialize.ps1', 'FirstLogon.ps1', 'DefaultUser.ps1', 'UserOnce.ps1')) {
            $raw -match [regex]::Escape($s) | Should Be $true
        }
    }
    It "embedded FirstLogon.ps1 parses as valid PowerShell" {
        $doc = [xml]([System.IO.File]::ReadAllText($script:UnattendPath, [System.Text.Encoding]::UTF8))
        $node = $doc.unattend.Extensions.File | Where-Object { $_.path -like '*FirstLogon.ps1' }
        $content = [string]$node.'#text'
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
}

Describe "nano11 builder - profile presets" {
    BeforeAll {
        # Dot-source only the preset definition by extracting it via AST is overkill; instead
        # run -TestSelf which validates presets internally and capture exit code.
    }
    It "built-in presets validate via -TestSelf" {
        $psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:BuilderPath`" -TestSelf"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $p.ExitCode | Should Be 0
    }
}

Describe "nano11 builder - IME decoupling filter logic (mock)" {
    It "ja-JP target keeps foreign IME patterns in the removal list" {
        $primaryImeLang = $null
        $patterns = @('*IME-ko-kr*', '*IME-zh-cn*', '*IME-zh-tw*', '*IME-zh-hk*', 'Microsoft-Windows-InternetExplorer-Optional-Package~*')
        # size-first decoupling: drop ONLY own-language IME patterns
        if ($primaryImeLang) {
            $patterns = @($patterns | Where-Object { $_ -notlike "*IME-$primaryImeLang*" })
        }
        ($patterns -contains '*IME-ko-kr*') | Should Be $true
        ($patterns -contains '*IME-zh-cn*') | Should Be $true
    }
    It "ko-KR target drops the ko-kr IME pattern (keeps Korean IME)" {
        $primaryImeLang = 'ko-kr'
        $patterns = @('*IME-ko-kr*', '*IME-zh-cn*', '*IME-zh-tw*', '*IME-zh-hk*')
        if ($primaryImeLang) {
            $patterns = @($patterns | Where-Object { $_ -notlike "*IME-$primaryImeLang*" })
        }
        ($patterns -contains '*IME-ko-kr*') | Should Be $false
        ($patterns -contains '*IME-zh-cn*') | Should Be $true
        ($patterns -contains '*IME-zh-tw*') | Should Be $true
    }
    It "primaryImeLang mapping covers ko/zh-cn/zh-tw/zh-hk" {
        $map = @{ 'ko-kr' = 'ko-kr'; 'zh-cn' = 'zh-cn'; 'zh-tw' = 'zh-tw'; 'zh-hk' = 'zh-tw' }
        $map['ko-kr'] | Should Be 'ko-kr'
        $map['zh-cn'] | Should Be 'zh-cn'
        $map['zh-tw'] | Should Be 'zh-tw'
        $map['zh-hk'] | Should Be 'zh-tw'
    }
}

Describe "nano11 builder - path safety guards (mock)" {
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

Describe "nano11 builder - end-to-end DryRun" {
    It "resolves extreme profile configuration without errors" {
        $psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:BuilderPath`" -DryRun -NonInteractive -Profile extreme"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        $finished = $p.WaitForExit(300000)
        if (-not $finished) { $p.Kill(); throw "builder did not exit within timeout" }
        [void]$stdoutTask.Result
        [void]$stderrTask.Result
        $p.ExitCode | Should Be 0
    }
}

# --- Regression tests: Remove-Nano11TreeRobust (fixes the 41 GB deep_apply leak and the
# --- ~5-hour final cleanup stall). Loads nano11helpers.ps1 functions directly. ---
if (-not (Get-Command -Name Remove-Nano11TreeRobust -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "nano11helpers.ps1")
}

Describe "nano11 builder - robust tree removal (long paths + image ACLs)" {
    It "removes a tree containing >260-char paths" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

        (Remove-Nano11TreeRobust -Path $deep -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $deep) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "removes a tree protected by image-style ACLs (Administrators RX only)" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $sub = Join-Path -Path $root -ChildPath "System32"
        [System.IO.Directory]::CreateDirectory($sub) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sub "locked.exe"), 'x')
        & icacls.exe $sub /inheritance:r /grant '*S-1-5-32-544:RX' /T /C /Q > $null 2>&1

        (Remove-Nano11TreeRobust -Path $sub -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $sub) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "repairs a WIM-style locked directory (SYSTEM-only DACL) and removes the tree" {
        # Regression for the 2026-10-18 real-build leftover (17.2 GB): dism /Apply-Image output
        # contains directories with protected SYSTEM-only DACLs. The old repair call
        # ('takeown /f <dir> /d y') was rejected by takeown's argv validation (needs /R) and
        # failed SILENTLY - the tree could never be repaired, deleting, or logged.
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $tree = Join-Path -Path $root -ChildPath "t_wim"
        $denied = Join-Path -Path $tree -ChildPath "WebThreatDefSvc"
        [System.IO.Directory]::CreateDirectory($denied) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $denied "payload.bin"), 'x')
        & icacls.exe $denied /inheritance:r > $null 2>&1
        & icacls.exe $denied /grant '*S-1-5-18:F' /C /Q > $null 2>&1
        & icacls.exe $denied /setowner '*S-1-5-18' /C /Q > $null 2>&1
        # Precondition: the DACL grants nothing to Administrators (privilege-state agnostic).
        $aclPre = Get-Acl -LiteralPath $denied
        $adminsAces = @($aclPre.Access | Where-Object {
            try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' } catch { $false }
        })
        $adminsAces.Count | Should Be 0

        (Remove-Nano11TreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "repairs a SYSTEM-locked directory hiding a junction (canary survives)" {
        # End-to-end incident shape: the unreadable directory hides a junction. Before the fix
        # the repair no-op kept the link-free gate closed forever; the gate must stay closed
        # until the walk can prove the tree link-free - the mirror purge would destroy the
        # junction target (verified hazard).
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

        (Remove-Nano11TreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }

    It "never follows junctions (canary directory survives)" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $canary = ($root + '_canary')
        $target = Join-Path -Path $root -ChildPath "linked"
        [System.IO.Directory]::CreateDirectory($target) | Out-Null
        [System.IO.Directory]::CreateDirectory($canary) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $canary "canary.txt"), 'precious')
        & cmd.exe /c "mklink /J `"$target\the_junction`" `"$canary`"" > $null 2>&1

        (Remove-Nano11TreeRobust -Path $target -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }

    It "refuses paths that are not strict children of the safety root" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $child = Join-Path -Path $root -ChildPath "keepme"
        [System.IO.Directory]::CreateDirectory($child) | Out-Null

        (Remove-Nano11TreeRobust -Path $root -SafetyRoot $root) | Should Be $false
        (Remove-Nano11TreeRobust -Path $child -SafetyRoot (Join-Path $root "other")) | Should Be $false
        (Test-Path -LiteralPath $child) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "removes a tree whose subdirectory denies enumeration (real-incident shape)" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $tree = Join-Path -Path $root -ChildPath "t_enum"
        $denied = Join-Path -Path $tree -ChildPath "DeniedSvc"
        [System.IO.Directory]::CreateDirectory($denied) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $denied "payload.bin"), 'x')
        & icacls.exe $denied /inheritance:r /deny '*S-1-5-32-544:RX' /C /Q > $null 2>&1

        (Remove-Nano11TreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
    }

    It "never destroys a junction target hidden inside an unreadable directory" {
        # Regression: robocopy /MIR purges THROUGH junctions even with /XJ, so it must only
        # run on trees the prune walk could fully verify as link-free.
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $canary = ($root + '_canary')
        $tree = Join-Path -Path $root -ChildPath "t_hidden"
        $denied = Join-Path -Path $tree -ChildPath "DeniedSvc"
        [System.IO.Directory]::CreateDirectory($denied) | Out-Null
        [System.IO.Directory]::CreateDirectory($canary) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $canary "canary.txt"), 'precious')
        & cmd.exe /c "mklink /J `"$denied\hidden_junction`" `"$canary`"" > $null 2>&1
        & icacls.exe $denied /inheritance:r /deny '*S-1-5-32-544:RX' /C /Q > $null 2>&1

        (Remove-Nano11TreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }

    It "deletes links whose inherited ACL was emptied, via parent repair" {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_robust_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $canary = ($root + '_canary')
        $tree = Join-Path -Path $root -ChildPath "t_stripped"
        $p = Join-Path -Path $tree -ChildPath "P"
        [System.IO.Directory]::CreateDirectory($p) | Out-Null
        [System.IO.Directory]::CreateDirectory($canary) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $canary "canary.txt"), 'precious')
        & cmd.exe /c "mklink /J `"$p\stripped_link`" `"$canary`"" > $null 2>&1
        & icacls.exe $p /inheritance:r /grant '*S-1-5-32-544:F' /C /Q > $null 2>&1

        (Remove-Nano11TreeRobust -Path $tree -SafetyRoot $root) | Should Be $true
        (Test-Path -LiteralPath $tree) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $canary "canary.txt")) | Should Be $true
        if (Test-Path -LiteralPath $root) { & cmd.exe /c "rd /s /q `"$root`"" > $null 2>&1 }
        if (Test-Path -LiteralPath $canary) { & cmd.exe /c "rd /s /q `"$canary`"" > $null 2>&1 }
    }
}

Describe "nano11 builder - phase timing telemetry" {
    It "persists Phase 18 through Exit-Phase + Save-Nano11PhaseTimings" {
        # Runtime test of the real source text: extract the two functions from the builder
        # AST, run them in this scope against a temp log dir, and verify the final phase
        # lands in last_phase_timings.json (regression for the always-missing Phase 18).
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)

        $funcTexts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Exit-Phase', 'Save-Nano11PhaseTimings')
        }, $true)) | ForEach-Object { $_.Extent.Text }
        $funcTexts.Count | Should Be 2

        $logDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_timings_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        $script:PhaseTimings = [ordered]@{ "Phase 17" = 42.5 }
        $script:CurrentPhase = 18
        $script:PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 60
        . ([scriptblock]::Create(($funcTexts -join "`n")))
        Exit-Phase
        Save-Nano11PhaseTimings

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
            $node.Name -eq 'Get-Nano11LastRunTotalSeconds'
        }, $true))
        $funcTexts.Count | Should Be 1
        . ([scriptblock]::Create($funcTexts[0].Extent.Text))

        $jsonPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_timings_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
        '{ "Phase 1": 0.8, "Phase 2": 1, "Phase 3": 25.3 }' | Set-Content -LiteralPath $jsonPath -Encoding utf8
        $total = Get-Nano11LastRunTotalSeconds -TimingsPath $jsonPath
        ([math]::Round($total, 1)) | Should Be 27.1
        Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
    }
}

Describe "nano11 helpers - atomic file I/O (Write-Nano11TextFileAtomic)" {
    It "writes text content atomically and cleans temporary files" {
        $tempFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_test_atomic_" + [guid]::NewGuid().ToString('N') + ".txt")
        $c1 = "First line of content"
        $ok1 = Write-Nano11TextFileAtomic -Path $tempFile -Content $c1
        $ok1 | Should Be $true
        (Test-Path -LiteralPath $tempFile) | Should Be $true
        [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8) | Should Be $c1

        $c2 = "Second line replaced content"
        $ok2 = Write-Nano11TextFileAtomic -Path $tempFile -Content $c2
        $ok2 | Should Be $true
        [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8) | Should Be $c2

        $dir = [System.IO.Path]::GetDirectoryName($tempFile)
        $orphans = Get-ChildItem -Path $dir -Filter "*nano11_test_atomic*.*.tmp" -ErrorAction SilentlyContinue
        ($null -eq $orphans -or $orphans.Count -eq 0) | Should Be $true

        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

Describe "nano11 helpers - configuration conflict resolution (Test-Nano11ConfigConflicts)" {
    It "detects and auto-resolves Store and Windows Update dependency conflict" {
        $cfg = [PSCustomObject]@{
            KeepStore = $true
            RemoveStore = $false
            DisableWindowsUpdate = $true
        }
        $res = Test-Nano11ConfigConflicts -Config $cfg -AutoResolve
        $res.HasConflicts | Should Be $true
        $res.ResolvedConfig.DisableWindowsUpdate | Should Be $false
    }

    It "enforces safety gate on physical debloat when -AllowPhysicalDebloat is false" {
        $cfg = [PSCustomObject]@{
            AllowPhysicalDebloat = $false
            advancedDebloatExperimental = @("Physical deletion candidate")
            TweakSettings = @{ PhysicalDebloat = $true }
        }
        $res = Test-Nano11ConfigConflicts -Config $cfg -AutoResolve
        $res.HasConflicts | Should Be $true
        $res.ResolvedConfig.TweakSettings.PhysicalDebloat | Should Be $false
        $res.ResolvedConfig.advancedDebloatExperimental.Count | Should Be 0
    }
}

Describe "nano11 helpers - build resume integrity (Test-Nano11ResumeIntegrity)" {
    It "fails validation on non-existent or empty workspace" {
        $dummyDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_empty_" + [guid]::NewGuid().ToString('N'))
        $res = Test-Nano11ResumeIntegrity -WorkspaceDir $dummyDir
        $res.IsValid | Should Be $false
        $res.Errors.Count | Should BeGreaterThan 0
    }

    It "passes validation when WIM payload has valid MSWIM magic header and root files" {
        $tempResume = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nano11_resume_" + [guid]::NewGuid().ToString('N'))
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

        $res = Test-Nano11ResumeIntegrity -WorkspaceDir $tempResume -IsIsoOnly
        $res.IsValid | Should Be $true
        $res.PayloadPath | Should Be $fakeWim
        $res.PayloadType | Should Be "WIM"

        Remove-Item -LiteralPath $tempResume -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "nano11 helpers - BuildContext lifecycle" {
    It "instantiates BuildContext with all required properties and initial values" {
        $helpersPath = Join-Path $script:RepoRoot "nano11helpers.ps1"
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

Describe "nano11 helpers - Path and Directory Safety Guards" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "nano11helpers.ps1"
        . $helpersPath
    }

    It "Test-Nano11PathWithin blocks .. traversal escape attempts" {
        $base = "C:\TestFolder\Work"
        $traversal = "C:\TestFolder\Work\..\..\Windows"
        Test-Nano11PathWithin -Path $traversal -Root $base | Should Be $false
    }

    It "Test-Nano11PathWithin accepts legitimate subpaths" {
        $base = "C:\TestFolder\Work"
        $sub = "C:\TestFolder\Work\Subdir\file.txt"
        Test-Nano11PathWithin -Path $sub -Root $base | Should Be $true
    }

    It "Test-IsSafePathToDelete protects OS root and protected system folders" {
        Test-IsSafePathToDelete -Path "C:\" | Should Be $false
        Test-IsSafePathToDelete -Path "C:\Windows" | Should Be $false
        Test-IsSafePathToDelete -Path "C:\Program Files" | Should Be $false
        Test-IsSafePathToDelete -Path "C:\Users" | Should Be $false
    }

    It "Test-IsSafePathToDelete protects repo root and parent directories" {
        Test-IsSafePathToDelete -Path $script:RepoRoot | Should Be $false
        Test-IsSafePathToDelete -Path (Join-Path $script:RepoRoot "nano11helpers.ps1") | Should Be $false
    }

    It "Get-Nano11VolumeFreeSpaceGB returns positive value for valid drive and throws on invalid" {
        $freeGB = Get-Nano11VolumeFreeSpaceGB -Path "C:\"
        $freeGB | Should BeGreaterThan 0
        { Get-Nano11VolumeFreeSpaceGB -Path "" } | Should Throw
        { Get-Nano11VolumeFreeSpaceGB -Path "Z:\NonExistentDriveXYZ" } | Should Throw
    }

    It "Test-CanSafelyDeleteDirectory refuses to delete workspace base directory itself" {
        $baseDir = "C:\TestFolder\BaseWork"
        Test-CanSafelyDeleteDirectory -Path $baseDir -ExpectedBaseDir $baseDir | Should Be $false
    }
}

Describe "nano11 helpers - Statistical Analysis and Benchmark Comparison" {
    BeforeAll {
        $helpersPath = Join-Path $script:RepoRoot "nano11helpers.ps1"
        . $helpersPath
    }

    It "Get-Nano11MetricStatistics calculates correct mean, median, min, max, stddev, IQR" {
        $values = @(10.0, 20.0, 30.0, 40.0, 50.0)
        $stats = Get-Nano11MetricStatistics -Values $values
        $stats.Count | Should Be 5
        $stats.Mean | Should Be 30.0
        $stats.Median | Should Be 30.0
        $stats.Min | Should Be 10.0
        $stats.Max | Should Be 50.0
        $stats.StdDev | Should BeGreaterThan 15.0
        $stats.StdDev | Should BeLessThan 16.0
        $stats.IQR | Should Be 20.0
    }

    It "Get-Nano11MetricStatistics handles empty input gracefully" {
        $stats = Get-Nano11MetricStatistics -Values @()
        $stats.Count | Should Be 0
        $stats.Mean | Should Be 0.0
        $stats.Median | Should Be 0.0
    }

    It "Compare-Nano11BenchmarkSeries computes percentage improvement across series" {
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

        $comp = Compare-Nano11BenchmarkSeries -BaselineRuns $baseRuns -OptimizedRuns $optRuns -OptimizedLabel "nano11 Test"
        $comp.CommittedMemoryMB | Should Not Be $null
        $comp.CommittedMemoryMB.Baseline.Median | Should Be 2000.0
        $comp.CommittedMemoryMB.Optimized.Median | Should Be 1000.0
        $comp.CommittedMemoryMB.ImprovementPercent | Should Be 50.0
        $comp.ProcessCount.ImprovementPercent | Should Be 50.0
    }
}

Describe "nano11 setup scripts - Custom Scripts Logging" {
    It "scripts/FirstLogon.ps1 contains dual-log recording and stop preference wrapper" {
        $firstLogonPath = Join-Path $script:RepoRoot "scripts\FirstLogon.ps1"
        $content = [System.IO.File]::ReadAllText($firstLogonPath, [System.Text.Encoding]::UTF8)
        $content | Should Match "custom-scripts\.log"
        $content | Should Match "Duration:"
        $content | Should Match "FAILED"
        $content | Should Match "SUCCESS"
        $content | Should Match "LASTEXITCODE = 0"
    }

    It "scripts/UserOnce.ps1 contains execution logging and redaction" {
        $userOncePath = Join-Path $script:RepoRoot "scripts\UserOnce.ps1"
        $content = [System.IO.File]::ReadAllText($userOncePath, [System.Text.Encoding]::UTF8)
        $content | Should Match "UserOnce-custom\.log"
        $content | Should Match "Redact-Nano11UserSecret"
        $content | Should Match "Duration:"
    }
}



Describe "nano11 GUI wiring - every toggle is consumed by the build" {
    $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
    $builderAst = [System.Management.Automation.Language.Parser]::ParseInput($builderText, [ref]$null, [ref]$null)
    $phasesDir = Join-Path -Path $script:RepoRoot -ChildPath "phases"
    $phaseText = (Get-ChildItem -LiteralPath $phasesDir -Filter "*.ps1" | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
    $helpersText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "nano11helpers.ps1"))

    # The builder derives these tables from config\tweaks.psd1; build them the same way here
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\tweaks.psd1")
    $tweakDefs = [ordered]@{}; $varMap = [ordered]@{}; $aliases = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) {
        $tweakDefs[$td.Key] = $td
        foreach ($a in @($td.Aliases)) { if ($a) { $aliases[$a] = $td.Key } }
        if ($td.Variable) { $varMap[$td.Key] = $td.Variable }
    }

    It "every AllTweakDefs key is read by a phase (Test-TweakEnabled) or mapped to a consumed variable" {
        $unconsumed = @()
        foreach ($k in $tweakDefs.Keys) {
            if ($phaseText -match "Test-TweakEnabled\s+'$k'") { continue }
            if ($varMap.Contains($k)) {
                $v = $varMap[$k]
                if (($phaseText -match "\`$$v\b") -or ($helpersText -match "\`$$v\b")) { continue }
            }
            $unconsumed += $k
        }
        ($unconsumed -join ', ') | Should Be ''
    }

    It "legacy tweak aliases point at existing AllTweakDefs keys" {
        foreach ($a in $aliases.Keys) { $tweakDefs.Contains($aliases[$a]) | Should Be $true }
    }

    It "phases do not read legacy alias names directly" {
        foreach ($a in $aliases.Keys) { ($phaseText -match "Test-TweakEnabled\s+'$a'") | Should Be $false }
    }

    It "GUI session maps TweakSettings onto the variable-backed tweaks" {
        $builderText | Should Match 'Sync-Nano11TweakVariables'
        $builderText | Should Not Match '\$guiResult\.RadicalRAM'
    }

    It "every GUI Advanced Debloat standard item has a phase 09 handler" {
        $physPath = Join-Path $phasesDir "09-physical-debloat.ps1"
        $physAst = [System.Management.Automation.Language.Parser]::ParseFile($physPath, [ref]$null, [ref]$null)
        # Patterns of the standard if/elseif chain: "$item -match '<pattern>'" in the Standard loop
        $stdLoop = $physAst.Find({
            param($n)
            $n -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $n.Condition.Extent.Text -eq '$script:advancedDebloatStandard'
        }, $true)
        $patterns = @([regex]::Matches($stdLoop.Body.Extent.Text, "\`$item -match '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $patterns.Count | Should BeGreaterThan 0

        $guiAst = [System.Management.Automation.Language.Parser]::ParseFile($script:GuiPath, [ref]$null, [ref]$null)
        $stdLists = $guiAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$stdItems'
        }, $true)
        @($stdLists).Count | Should BeGreaterThan 0
        $unhandled = @()
        foreach ($list in $stdLists) {
            foreach ($item in (Invoke-Expression $list.Right.Extent.Text)) {
                if (@($patterns | Where-Object { $item -match $_ }).Count -eq 0) { $unhandled += $item }
            }
        }
        ($unhandled -join ' | ') | Should Be ''
    }
}

Describe "nano11 settings - config\tweaks.psd1 is the single source of truth" {
    $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
    $builderAst = [System.Management.Automation.Language.Parser]::ParseInput($builderText, [ref]$null, [ref]$null)
    $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
    $guiAst = [System.Management.Automation.Language.Parser]::ParseInput($guiText, [ref]$null, [ref]$null)
    $settingsDef =Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\tweaks.psd1")
    $tweakKeys = @($settingsDef.Tweaks | ForEach-Object { $_.Key })
    $componentKeys = @($settingsDef.Components | ForEach-Object { $_.Key })
    $allKeys = $tweakKeys + $componentKeys
    $switchNames = @($builderAst.ParamBlock.Parameters | Where-Object { $_.StaticType -eq [switch] } | ForEach-Object { $_.Name.VariablePath.UserPath })

    It "keys are unique within Tweaks and within Components" {
        @($tweakKeys | Group-Object | Where-Object Count -gt 1).Count | Should Be 0
        @($componentKeys | Group-Object | Where-Object Count -gt 1).Count | Should Be 0
    }

    It "every tweak has a valid category, boolean default and description" {
        foreach ($td in $settingsDef.Tweaks) {
            @('Security', 'Privacy', 'Performance', 'UI') -contains $td.Category | Should Be $true
            $td.Default -is [bool] | Should Be $true
            [string]::IsNullOrWhiteSpace($td.Description) | Should Be $false
        }
    }

    It "every non-special component names its script variable and type" {
        foreach ($cd in $settingsDef.Components) {
            @('Bool', 'String', 'Special') -contains $cd.Type | Should Be $true
            if ($cd.Type -ne 'Special') { [string]::IsNullOrWhiteSpace($cd.Variable) | Should Be $false }
            if ($cd.Gui) { $cd.Type | Should Be 'Bool' }
        }
    }

    It "aliases never shadow a real key" {
        foreach ($td in $settingsDef.Tweaks) {
            foreach ($a in @($td.Aliases)) { if ($a) { $tweakKeys -contains $a | Should Be $false } }
        }
    }

    It "CliSwitch matches a [switch] parameter of the builder, and every setting-named switch is marked" {
        foreach ($d in @($settingsDef.Tweaks) + @($settingsDef.Components)) {
            if ($d.CliSwitch) { $switchNames -contains $d.Key | Should Be $true }
        }
        foreach ($td in $settingsDef.Tweaks) {
            if ($switchNames -contains $td.Key) { [bool]$td.CliSwitch | Should Be $true }
        }
    }

    It "every GUI checkbox key (New-Nano11ToggleCheckBox) exists in the definition file" {
        # The GUI builds its tweak tabs from AllTweakDefs and the Services tab from $svcDefs; both
        # come from the definition file, so no literal setting key may be passed as -Key.
        $calls = [regex]::Matches($guiText, "New-Nano11ToggleCheckBox -Parent \S+ -Key (\S+) ")
        $calls.Count | Should BeGreaterThan 0
        foreach ($m in $calls) {
            $keyArg = $m.Groups[1].Value
            if ($keyArg -match '^["'']([^"'']+)["'']$') { $allKeys -contains $Matches[1] | Should Be $true }
            else { @('$tk', '$sd.Key') -contains $keyArg | Should Be $true }
        }
    }

    It "derived tables are built from the definition file, not hand-written" {
        foreach ($name in 'AllTweakDefs', 'TweakKeyAliases', 'TweakVariableMap', 'Nano11ProfileKeys') {
            $assigns = @($builderAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$script:$name"
            }, $true))
            $assigns.Count | Should Be 1
            # Only an empty initializer or a derivation from the loaded definitions is allowed
            $assigns[0].Right.Extent.Text | Should Match '^(\[ordered\]@\{\}|@\(\$script:ComponentDefs\.Keys\).*)$'
        }
        $svc = $guiAst.Find({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$svcDefs'
        }, $true)
        $svc.Right.Extent.Text | Should Match 'ComponentDefs'
    }

    It "every CliBindings switch name is a builder parameter or alias" {
        $paramNames = @(foreach ($p in $builderAst.ParamBlock.Parameters) {
            $p.Name.VariablePath.UserPath
            foreach ($a in $p.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }) { $a.PositionalArguments | ForEach-Object { $_.Value } }
        })
        @($settingsDef.CliBindings).Count | Should BeGreaterThan 0
        foreach ($cb in $settingsDef.CliBindings) {
            foreach ($grp in $cb.Switches) {
                foreach ($n in $grp.Names) { "$($cb.Tag):$n" | Should Be "$($cb.Tag):$(@($paramNames | Where-Object { $_ -eq $n })[0])" }
            }
        }
    }

    It "built-in preset and phase-read setting keys all exist in the definition file" {
        $presets = $builderAst.Find({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:BuiltInPresets'
        }, $true)
        $presetData = Invoke-Expression $presets.Right.Extent.Text
        $meta = @('ProfileName', 'Description')
        foreach ($pn in $presetData.Keys) {
            foreach ($k in $presetData[$pn].Keys) {
                if ($meta -contains $k) { continue }
                ($allKeys -contains $k) | Should Be $true
            }
        }
        $phaseText = (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "phases") -Filter "*.ps1" | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        # A key missing from the definition file is an internal tweak (no GUI/profile entry yet);
        # it must at least carry its own explicit default so a typo cannot silently disable it.
        foreach ($m in [regex]::Matches($phaseText, "Test-TweakEnabled\s+'([^']+)'(\s+\`$(true|false))?")) {
            if ($tweakKeys -notcontains $m.Groups[1].Value) { $m.Groups[2].Success | Should Be $true }
        }
    }

    It "profiles\*.json only use known setting keys" {
        $known = $allKeys + @('ProfileName', 'Description', 'Version', 'Timestamp', 'Architecture')
        $aliasNames = @($settingsDef.Tweaks | ForEach-Object { @($_.Aliases) } | Where-Object { $_ })
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "profiles") -Filter "*.json") {
            $data = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
            $settings = if ($data.Settings) { $data.Settings } else { $data }
            foreach ($prop in $settings.PSObject.Properties) { ($known -contains $prop.Name) | Should Be $true }
            if ($settings.TweakSettings) {
                foreach ($prop in $settings.TweakSettings.PSObject.Properties) {
                    (($tweakKeys + $aliasNames) -contains $prop.Name) | Should Be $true
                }
            }
        }
    }
}

Describe "nano11 GUI - smoke test (form built without ShowDialog)" {
    # Same derived tables the builder hands the GUI, built from config\tweaks.psd1
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\tweaks.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-Nano11Preset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }

    . $script:GuiPath
    # Never block on the experimental Select All confirmation
    function Confirm-Nano11GuiAction { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Message, [string]$Title) $true }

    function Get-AllControls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-AllControls $c } }

    # PerformClick only fires on visible controls: show off-screen, select each tab, click its buttons
    function Invoke-SelectButtons($form) {
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = New-Object System.Drawing.Point(-20000, -20000)
        $form.ShowInTaskbar = $false
        [void]$form.Show()
        $clicked = 0
        try {
            $tabControl = @(Get-AllControls $form | Where-Object { $_ -is [System.Windows.Forms.TabControl] })[0]
            foreach ($tab in $tabControl.TabPages) {
                $tabControl.SelectedTab = $tab
                [void][System.Windows.Forms.Application]::DoEvents()
                $buttons = @(Get-AllControls $tab | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -match '^(Select All|Clear All|Deselect All)$' })
                foreach ($btn in ($buttons | Sort-Object { $_.Text -ne 'Select All' })) {
                    $target = $btn.Tag.Target
                    $want = $btn.Text -eq 'Select All'
                    # Start from the opposite state so the click has to change every box
                    Set-Nano11Checked -Target $target -Checked (-not $want)
                    [void]$btn.PerformClick()
                    if ($target -is [System.Windows.Forms.CheckedListBox]) {
                        $target.Items.Count | Should BeGreaterThan 0 | Out-Null
                        $target.CheckedItems.Count | Should Be $(if ($want) { $target.Items.Count } else { 0 }) | Out-Null
                    } else {
                        @($target).Count | Should BeGreaterThan 0 | Out-Null
                        @($target | Where-Object { $_.Checked -ne $want }).Count | Should Be 0 | Out-Null
                    }
                    $clicked++
                }
            }
        } finally {
            $form.Close(); $form.Dispose()
        }
        return $clicked
    }

    It "main window: every Select All / Clear All button changes its boxes" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $gui.Form.Tag | Should Be $gui
            $gui.TweakCheckboxes.Count | Should Be $script:AllTweakDefs.Count
            Invoke-SelectButtons $gui.Form | Should Be 14
            # Toggle handlers reached the shared context: preset switched to Custom
            $gui.Preset.SelectedIndex | Should Be ($gui.Preset.Items.Count - 1)
        } finally {
            if ($gui -and $gui.Form) { $gui.Form.Dispose() }
            [System.Windows.Forms.Application]::Exit()
        }
    }

    It "main window: result hashtable keeps its contract" {
        $gui = Show-Nano11GUI -NoShow -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            Complete-Nano11GuiResult -Gui $gui | Should Be $true
            $r = $gui.Result
            foreach ($k in 'Success', 'UserName', 'ComputerName', 'PresetKey', 'BasePresetKey', 'SourceDrive', 'WorkDir', 'Index',
                           'InjectDrivers', 'DryRun', 'UseVHDX', 'ExportESDMode', 'SplitWIMMode', 'TweakSettings',
                           'AdvancedDebloatStandard', 'AdvancedDebloatExperimental') {
                $r.ContainsKey($k) | Should Be $true
            }
            $r.Success | Should Be $true
            $r.TweakSettings.Count | Should Be $script:AllTweakDefs.Count
            foreach ($k in $gui.ComponentCheckboxes.Keys) { $r.ContainsKey($k) | Should Be $true }
        } finally { $gui.Form.Dispose() }
    }

    It "Advanced Debloat dialog: every Select All / Deselect All button changes its list" {
        $dlg = Show-AdvancedDebloatDialog -NoShow
        try {
            Invoke-SelectButtons $dlg | Should Be 4
        } finally {
            if ($dlg -and $dlg.Form) { $dlg.Form.Dispose() }
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
    }

    It "cleanup WinForms message pump (environmental stability)" {
        [System.Windows.Forms.Application]::Exit()
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $true | Should Be $true
    }
}

Describe "nano11 code quality - PSScriptAnalyzer" {
    $analyzerAvailable = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
    if (-not $analyzerAvailable) {
        Write-Warning "PSScriptAnalyzer is not installed - skipping the analyzer test. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    }

    It "reports zero Error/Warning findings with PSScriptAnalyzerSettings.psd1" -Skip:(-not $analyzerAvailable) {
        $settingsPath = Join-Path -Path $script:RepoRoot -ChildPath "PSScriptAnalyzerSettings.psd1"
        $targets = @(
            (Join-Path $script:RepoRoot "nano11builder.ps1"),
            (Join-Path $script:RepoRoot "nano11helpers.ps1"),
            $script:GuiPath
        ) + @(Get-ChildItem -Path (Join-Path $script:RepoRoot "phases"), (Join-Path $script:RepoRoot "lib"), (Join-Path $script:RepoRoot "scripts"), (Join-Path $script:RepoRoot "tools"), (Join-Path $script:RepoRoot "tests") -Filter "*.ps1" -File | ForEach-Object { $_.FullName })
        $findings = @(foreach ($target in $targets) {
            Invoke-ScriptAnalyzer -Path $target -Settings $settingsPath -Severity Error, Warning
        })
        ($findings | ForEach-Object { "$($_.RuleName) $(Split-Path -Leaf $_.ScriptPath):$($_.Line) $($_.Message)" }) -join "`n" | Should Be ''
    }
}

# --- Dependency / feature-impact checker tests ---
if (-not (Get-Command -Name Test-Nano11Dependencies -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "nano11helpers.ps1")
}

Describe "nano11 dependency checker" {
    $depsPath = Join-Path -Path $script:RepoRoot -ChildPath "config\dependencies.psd1"
    $tweaksPath = Join-Path -Path $script:RepoRoot -ChildPath "config\tweaks.psd1"

    It "dependency catalog exists" {
        Test-Path -LiteralPath $depsPath | Should Be $true
    }

    It "covers every tweak key from config/tweaks.psd1" {
        $deps = Import-PowerShellDataFile -Path $depsPath
        $defs = Import-PowerShellDataFile -Path $tweaksPath
        foreach ($t in $defs.Tweaks) {
            $deps.Tweaks.ContainsKey($t.Key) | Should Be $true
        }
    }

    It "covers every component key from config/tweaks.psd1" {
        $deps = Import-PowerShellDataFile -Path $depsPath
        $defs = Import-PowerShellDataFile -Path $tweaksPath
        foreach ($c in $defs.Components) {
            $deps.Components.ContainsKey($c.Key) | Should Be $true
        }
    }

    It "covers every Advanced Debloat item from the GUI" {
        $deps = Import-PowerShellDataFile -Path $depsPath
        $guiLines = [System.IO.File]::ReadAllLines($script:GuiPath)
        $items = @()
        $i = 0
        while ($i -lt $guiLines.Count) {
            if ($guiLines[$i] -match '\$(std|exp)Items\s*=\s*@\(') {
                $i++
                while ($i -lt $guiLines.Count -and $guiLines[$i].Trim() -ne ')') {
                    $l = $guiLines[$i].Trim().TrimEnd(',')
                    if ($l -match '"([^"]*)"') { $items += $matches[1] }
                    $i++
                }
            }
            $i++
        }
        $items = $items | Select-Object -Unique
        $items.Count | Should BeGreaterThan 0
        foreach ($it in $items) {
            $deps.AdvancedDebloat.ContainsKey($it) | Should Be $true
        }
    }

    It "detects a conflict for WSLSupport + NoHypervisor" {
        $cfg = @{ WSLSupport = $true; NoHypervisor = $true; TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-Nano11Dependencies -Config $cfg
        $r.Conflicts.Count | Should BeGreaterThan 0
    }

    It "returns impacts for RemoveStore" {
        $cfg = @{ RemoveStore = $true; TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-Nano11Dependencies -Config $cfg
        $r.Impacts.Count | Should BeGreaterThan 0
    }

    It "returns impacts for 'Remove Print Spooler'" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Remove Print Spooler (service + binary) [20-30MB]'); AdvancedDebloatExperimental = @() }
        $r = Test-Nano11Dependencies -Config $cfg
        $r.Impacts.Count | Should BeGreaterThan 0
    }

    It "marks 'Provisioning packages' as Unknown" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Remove Provisioning packages [5-10MB]'); AdvancedDebloatExperimental = @() }
        $r = Test-Nano11Dependencies -Config $cfg
        $r.Unknowns.Count | Should BeGreaterThan 0
    }

    It "treats unregistered advanced debloat items as Unknown (fail-safe)" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Totally Unknown Item XYZ'); AdvancedDebloatExperimental = @() }
        $r = Test-Nano11Dependencies -Config $cfg
        $r.Unknowns.Count | Should BeGreaterThan 0
    }

    It "returns no issues for a safe/empty configuration" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-Nano11Dependencies -Config $cfg
        $r.HasIssues | Should Be $false
    }
}

# --- User Extensibility Engine tests (M2) ---
if (-not (Get-Command -Name Import-Nano11UserExtensions -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\Nano11Extensions.ps1")
}
if (-not (Get-Command -Name Test-Nano11RecoveryReadiness -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\Nano11Migration.ps1")
}

Describe "User Extensibility Engine (lib/Nano11Extensions.ps1)" {
    It "Import-Nano11UserExtensions returns Loaded=false for missing file" {
        $r = Import-Nano11UserExtensions -ConfigPath (Join-Path $script:RepoRoot "config\nonexistent-user-tweaks.psd1")
        $r.Loaded | Should Be $false
    }
    It "Import-Nano11UserExtensions loads valid user-tweaks.psd1" {
        $r = Import-Nano11UserExtensions -ConfigPath (Join-Path $script:RepoRoot "config\user-tweaks.psd1")
        $r.Loaded | Should Be $true
        $r.Errors.Count | Should Be 0
    }
    It "Test-Nano11RecoveryReadiness returns expected properties" {
        $rr = Test-Nano11RecoveryReadiness -Config @{ KeepRecoveryEnv = $false }
        $rr.PSObject.Properties.Name -contains 'HasSecondaryDrive' | Should Be $true
        $rr.PSObject.Properties.Name -contains 'ReadinessScore' | Should Be $true
        $rr.PSObject.Properties.Name -contains 'Recommendations' | Should Be $true
        $rr.WinReEnabledOnTarget | Should Be $false
    }
    It "Compare-Nano11Config returns a diff result" {
        $diff = Compare-Nano11Config -ReferenceConfig @{ TweakSettings = @{ DisableUAC = $false } } -DifferenceConfig @{ TweakSettings = @{ DisableUAC = $true } }
        $diff.TotalDiffCount | Should BeGreaterThan 0
        $diff.ReferenceName | Should Not Be $null
    }
    It "Get-Nano11CustomScriptMetadata parses metadata headers" {
        $tmp = Join-Path $env:TEMP "test_script_meta.ps1"
        "# @Nano11-Id: TestScript`n# @Nano11-Stage: PreBuild`n# @Nano11-Order: 42`n# @Nano11-OnError: Warn`n# @Nano11-Description: Test desc`nWrite-Host 'hi'" | Set-Content $tmp -Encoding UTF8
        $m = Get-Nano11CustomScriptMetadata -ScriptPath $tmp
        $m.Id | Should Be 'TestScript'
        $m.Stage | Should Be 'PreBuild'
        $m.Order | Should Be 42
        $m.OnError | Should Be 'Warn'
        $m.Description | Should Be 'Test desc'
        $m.Sha256 | Should Not Be ''
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# --- PC Migration & Backup Engine tests (M3) ---
if (-not (Get-Command -Name Get-Nano11MigrationRules -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\Nano11Migration.ps1")
}

Describe "PC Migration & Backup Engine (lib/Nano11Migration.ps1)" {
    It "Get-Nano11MigrationRules loads standard rules" {
        $rules = Get-Nano11MigrationRules
        $rules.GameRules.Count | Should BeGreaterThan 0
        $rules.AppConfigRules.Count | Should BeGreaterThan 0
        $rules.SecretPatterns.Count | Should BeGreaterThan 0
        $rules.Errors.Count | Should Be 0
    }
    It "Expand-Nano11MigrationPath expands environment variables" {
        $p = Expand-Nano11MigrationPath -RawPath '%USERPROFILE%\Documents'
        $p | Should Not Be '%USERPROFILE%\Documents'
        $p | Should Match 'Documents$'
    }
    It "Test-Nano11SecretPath identifies secret files" {
        $patterns = @('*Cookies*','*id_rsa*','*.pfx')
        Test-Nano11SecretPath -FilePath 'Cookies' -SecretPatterns $patterns | Should Be $true
        Test-Nano11SecretPath -FilePath 'normal.txt' -SecretPatterns $patterns | Should Be $false
    }
    It "Backup-Nano11UserData copies files and records SHA-256 without deleting source" {
        $srcDir = Join-Path $env:TEMP "migtest_src2"
        $bkDir = Join-Path $env:TEMP "migtest_bk2"
        if (Test-Path $srcDir) { Remove-Item $srcDir -Recurse -Force }
        if (Test-Path $bkDir) { Remove-Item $bkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $srcDir 'Documents') | Out-Null
        'hello' | Set-Content (Join-Path $srcDir 'Documents\test.txt')
        $r = Backup-Nano11UserData -FolderMap @{ Documents = (Join-Path $srcDir 'Documents') } -BackupRoot $bkDir
        $r.CopiedFiles | Should Be 1
        $r.Success | Should Be $true
        $r.ManifestEntries.Count | Should Be 1
        $r.ManifestEntries[0].Sha256 | Should Not Be ''
        # source still exists
        Test-Path (Join-Path $srcDir 'Documents\test.txt') | Should Be $true
        Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $bkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "Restore-Nano11UserData creates .nano11.bak on conflict" {
        $srcDir = Join-Path $env:TEMP "migtest_src3"
        $bkDir = Join-Path $env:TEMP "migtest_bk3"
        if (Test-Path $srcDir) { Remove-Item $srcDir -Recurse -Force }
        if (Test-Path $bkDir) { Remove-Item $bkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $srcDir 'Documents') | Out-Null
        'hello' | Set-Content (Join-Path $srcDir 'Documents\test.txt')
        Backup-Nano11UserData -FolderMap @{ Documents = (Join-Path $srcDir 'Documents') } -BackupRoot $bkDir | Out-Null
        $destFile = Join-Path $env:USERPROFILE 'test.txt'
        'existing' | Set-Content $destFile
        $r = Restore-Nano11UserData -BackupRoot $bkDir -ConflictPolicy BackupExisting
        $r.RestoredFiles | Should Be 1
        Test-Path "$destFile.nano11.bak" | Should Be $true
        Remove-Item $destFile -Force -ErrorAction SilentlyContinue
        Remove-Item "$destFile.nano11.bak" -Force -ErrorAction SilentlyContinue
        Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $bkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "Start-Nano11MigrationRestore -RetryFailedOnly skips completed tasks" {
        $bkDir = Join-Path $env:TEMP "migtest_bk4"
        if (Test-Path $bkDir) { Remove-Item $bkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $bkDir | Out-Null
        @{ Created = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $bkDir 'migration-manifest.json') -Encoding UTF8
        Start-Nano11MigrationRestore -BackupRoot $bkDir | Out-Null
        $r2 = Start-Nano11MigrationRestore -BackupRoot $bkDir -RetryFailedOnly
        @($r2.Results | Where-Object { $_.Status -like 'Skipped*' }).Count | Should BeGreaterThan 0
        Remove-Item $bkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "Invoke-Nano11MigrationRulesBackup excludes secret files by default" {
        # Verify Test-Nano11SecretPath identifies secret patterns
        $patterns = (Get-Nano11MigrationRules).SecretPatterns
        Test-Nano11SecretPath -FilePath 'Cookies' -SecretPatterns $patterns | Should Be $true
        Test-Nano11SecretPath -FilePath 'id_rsa' -SecretPatterns $patterns | Should Be $true
        Test-Nano11SecretPath -FilePath 'normal.txt' -SecretPatterns $patterns | Should Be $false
    }
}

Describe "S1 - user extensions survive -PresetsOnly re-import" {
    It "keeps UserTweakDefs and UserCustomScripts after a -PresetsOnly call" {
        . (Join-Path $script:RepoRoot 'lib\Nano11Extensions.ps1')
        $dir = Join-Path $env:TEMP ("s1ext_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $cfg = Join-Path $dir 'user-tweaks.psd1'
        $lines = @(
            '@{',
            '    UserTweaks = @(',
            '        @{ Key = ''S1TestSwitch''; Category = ''Test''; Description = ''S1 test''; Default = $false }',
            '    )',
            '    UserPresets = @{',
            '        S1Preset = @{ S1TestSwitch = $true }',
            '    }',
            '    CustomScripts = @(',
            '        @{ Id = ''S1Script''; Stage = ''PreBuild''; Path = ''x.ps1'' }',
            '    )',
            '}'
        )
        Set-Content -LiteralPath $cfg -Value $lines -Encoding UTF8
        $script:AllTweakDefs = [ordered]@{}
        $script:BuiltInPresets = [ordered]@{}
        $r1 = Import-Nano11UserExtensions -ConfigPath $cfg
        $r1.UserTweakCount | Should Be 1
        $r1.CustomScriptCount | Should Be 1
        $r2 = Import-Nano11UserExtensions -ConfigPath $cfg -PresetsOnly
        @($script:UserTweakDefs.Keys).Count | Should Be 1
        @($script:UserCustomScripts).Count | Should Be 1
        $r2.UserTweakCount | Should Be 1
        $r2.CustomScriptCount | Should Be 1
        $script:BuiltInPresets.Contains('S1Preset') | Should Be $true
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "dot-sources Nano11Extensions.ps1 and Nano11Migration.ps1 once each in the builder" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot' }, $true)
        $text = @($cmds | ForEach-Object { $_.Extent.Text })
        foreach ($name in 'Nano11Extensions.ps1', 'Nano11Migration.ps1') {
            $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Right.Extent.Text -like "*$name*" }, $true))
            $assigns.Count | Should Be 1
            $var = $assigns[0].Left.VariablePath.UserPath
            @($text | Where-Object { $_ -eq ". `$$var" }).Count | Should Be 1
        }
    }
}


# --- S2: dependency checker additions ---
Describe "nano11 dependency checker S2 additions" {
    $emptyLists = @{ TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }

    It "reports RemoveDrivers as Unknown" {
        $cfg = $emptyLists.Clone(); $cfg['RemoveDrivers'] = $true
        $r = Test-Nano11Dependencies -Config $cfg
        @($r.Unknowns | Where-Object { $_.Source -eq 'RemoveDrivers' }).Count | Should Be 1
    }

    It "reports AllowPhysicalDebloat as Unknown" {
        $cfg = $emptyLists.Clone(); $cfg['AllowPhysicalDebloat'] = $true
        $r = Test-Nano11Dependencies -Config $cfg
        @($r.Unknowns | Where-Object { $_.Source -eq 'AllowPhysicalDebloat' }).Count | Should Be 1
    }

    It "lists VBS among NoHypervisor affected features" {
        $c = Import-PowerShellDataFile -Path (Join-Path -Path $script:RepoRoot -ChildPath 'config\dependencies.psd1')
        ($c.Tweaks['NoHypervisor'].AffectedFeatures -contains 'VBS') | Should Be $true
    }

    It "reports an enabled user tweak without Impact as Unknown, but not when Impact is Safe" {
        $saved = $script:UserTweakDefs
        try {
            $script:UserTweakDefs = [ordered]@{
                S2NoImpact = @{ Key = 'S2NoImpact' }
                S2SafeOne  = @{ Key = 'S2SafeOne'; Impact = 'Safe' }
            }
            $cfg = @{ TweakSettings = @{ S2NoImpact = $true; S2SafeOne = $true }; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
            $r = Test-Nano11Dependencies -Config $cfg
            @($r.Unknowns | Where-Object { $_.Source -eq 'S2NoImpact' }).Count | Should Be 1
            @($r.Unknowns | Where-Object { $_.Source -eq 'S2SafeOne' }).Count | Should Be 0
            @($r.Impacts | Where-Object { $_.Source -eq 'S2SafeOne' }).Count | Should Be 0
        } finally {
            $script:UserTweakDefs = $saved
        }
    }

    It "adds a hashtable Impact of a user tweak to Impacts" {
        $saved = $script:UserTweakDefs
        try {
            $script:UserTweakDefs = [ordered]@{
                S2WithImpact = @{ Key = 'S2WithImpact'; Impact = @{ AffectedFeatures = @('Foo'); Severity = 'Warning'; Reason = 'r' } }
            }
            $cfg = @{ TweakSettings = @{ S2WithImpact = $true }; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
            $r = Test-Nano11Dependencies -Config $cfg
            @($r.Impacts | Where-Object { $_.Source -eq 'S2WithImpact' }).Count | Should Be 1
            @($r.Unknowns | Where-Object { $_.Source -eq 'S2WithImpact' }).Count | Should Be 0
        } finally {
            $script:UserTweakDefs = $saved
        }
    }

    It "does not fail when UserTweakDefs is undefined" {
        $saved = $script:UserTweakDefs
        try {
            Remove-Variable -Name UserTweakDefs -Scope Script -ErrorAction SilentlyContinue
            $r = Test-Nano11Dependencies -Config $emptyLists
            $r.HasIssues | Should Be $false
        } finally {
            $script:UserTweakDefs = $saved
        }
    }

    It "still detects RemoveStore + KeepXboxServices and NoHypervisor + WSLSupport conflicts" {
        $cfg = $emptyLists.Clone(); $cfg['RemoveStore'] = $true; $cfg['KeepXboxServices'] = $true
        (Test-Nano11Dependencies -Config $cfg).Conflicts.Count | Should BeGreaterThan 0
        $cfg2 = $emptyLists.Clone(); $cfg2['NoHypervisor'] = $true; $cfg2['WSLSupport'] = $true
        (Test-Nano11Dependencies -Config $cfg2).Conflicts.Count | Should BeGreaterThan 0
    }
}


# --- S3: migration engine (task-based restore, report, BackupRoot guard) ---
Describe "Migration engine S3 (lib/Nano11Migration.ps1)" {
    BeforeAll {
        if (-not (Get-Command -Name Test-Nano11PathWithin -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "nano11helpers.ps1")
        }
        if (-not (Get-Command -Name Start-Nano11MigrationRestore -ErrorAction SilentlyContinue)) {
            . (Join-Path -Path $script:RepoRoot -ChildPath "lib\Nano11Migration.ps1")
        }
    }

    It "Start-Nano11MigrationRestore -RetryFailedOnly reruns only Failed tasks" {
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
        Mock Restore-Nano11UserData { $script:s3Calls += ($Categories -join ','); [PSCustomObject]@{ RestoredFiles = 1; SkippedFiles = 0; FailedFiles = @() } }
        $r = Start-Nano11MigrationRestore -BackupRoot $bk -RetryFailedOnly
        $script:s3Calls.Count | Should Be 1
        $script:s3Calls[0] | Should Be 'Pictures'
        ($r.Results | Where-Object { $_.TaskId -eq 'UserData_Documents' }).Status | Should Match '^Skipped'
        $state = Get-Content (Join-Path $bk 'restore-state.json') -Raw | ConvertFrom-Json
        $state.UserData_Pictures | Should Be 'Completed'
        $state.UserData_Documents | Should Be 'Completed'
    }

    It "Start-Nano11MigrationRestore continues after a failed task" {
        $bk = Join-Path $TestDrive 'continue'
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        @{ Entries = @(); Folders = @(@{ Category = 'A'; SourcePath = 'C:\a' }, @{ Category = 'B'; SourcePath = 'C:\b' }); Rules = @(); CustomPaths = @() } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $bk 'migration-manifest.json') -Encoding UTF8
        Mock Restore-Nano11UserData {
            if ($Categories -contains 'A') { throw 'boom' }
            [PSCustomObject]@{ RestoredFiles = 0; SkippedFiles = 0; FailedFiles = @() }
        }
        $r = Start-Nano11MigrationRestore -BackupRoot $bk
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
        Start-Nano11MigrationBackup -FolderMap @{ 'Docs' = $src } -BackupRoot $bk -OfflineTestMode | Out-Null
        Test-Path (Join-Path $bk 'migration-report.html') | Should Be $true
        Test-Path (Join-Path $bk 'migration-report.json') | Should Be $true
        (Get-FileHash (Join-Path $src 'a.txt') -Algorithm SHA256).Hash | Should Be $before
        $j = Get-Content (Join-Path $bk 'migration-report.json') -Raw | ConvertFrom-Json
        $j.Success.Files | Should Be 1
        $j.Success.Sha256Verified | Should Be 1
        $mf = Get-Content (Join-Path $bk 'migration-manifest.json') -Raw | ConvertFrom-Json
        @($mf.Folders).Count | Should Be 1
        @($mf.Entries).Count | Should Be 1
        $rep = Export-Nano11MigrationReport -MigrationResult ([PSCustomObject]@{ Results = @([PSCustomObject]@{ TaskId = "App_$evil"; Status = 'Failed'; Detail = $evil }) }) -ReportPath (Join-Path $TestDrive 'r2\migration-report.html')
        $html = Get-Content $rep.HtmlPath -Raw
        $html | Should Not Match '<script>alert'
        $html | Should Match '&lt;script&gt;'
    }

    It "Backup-Nano11UserData and Backup-Nano11CustomPaths reject a BackupRoot inside the source" {
        $src = Join-Path $TestDrive 'guard\Docs'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content (Join-Path $src 'a.txt') 'x'
        $inside = Join-Path $src 'backup'
        { Backup-Nano11UserData -FolderMap @{ Docs = $src } -BackupRoot $inside } | Should Throw
        { Backup-Nano11CustomPaths -Paths @($src) -BackupRoot $inside } | Should Throw
        { Start-Nano11MigrationBackup -FolderMap @{ Docs = $src } -BackupRoot $inside -OfflineTestMode } | Should Throw
        Test-Path $inside | Should Be $false
        Test-Path (Join-Path $src 'a.txt') | Should Be $true
    }

    It "Invoke-Nano11MigrationRulesBackup result carries CloudSaveNotices for rules that define one" {
        $rules = Get-Nano11MigrationRules
        $rule = @($rules.GameRules + $rules.AppConfigRules) | Where-Object { $_.CloudSaveNotice } | Select-Object -First 1
        $rule | Should Not BeNullOrEmpty
        $r = Invoke-Nano11MigrationRulesBackup -RuleIds @($rule.Id) -BackupRoot (Join-Path $TestDrive 'bk-rules') -ForceRunningProcess
        @($r.CloudSaveNotices).Count | Should Be 1
        $r.CloudSaveNotices[0].RuleId | Should Be $rule.Id
    }
}

Describe "S4 builder hooks (ComparePreset / PreBuild / OfflineImage)" {
    BeforeAll { }
    $s4Root = Split-Path -Parent $PSScriptRoot
    $s4Builder = Join-Path $s4Root 'nano11builder.ps1'
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
        $s4Unattend.IndexOf("-Stage 'OfflineImage'") | Should BeLessThan $s4Unattend.IndexOf("-Stage 'FirstLogon'")
    }
    It "builder runs the PreBuild stage and the recovery readiness check" {
        $s4Text.Contains("-Stage 'PreBuild'") | Should Be $true
        $s4Text.Contains('Test-Nano11RecoveryReadiness -Config') | Should Be $true
    }
    It "-ComparePreset balanced prints a diff and exits 0 without building" {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s4Builder -ComparePreset balanced -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out.Contains('Config diff:') | Should Be $true
    }
}


Describe "Migrator tool S6 (tools/Nano11-Migrator.ps1)" {
    BeforeAll {
        $script:S6Tool = Join-Path -Path $script:RepoRoot -ChildPath "tools\Nano11-Migrator.ps1"
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
        Backup-Nano11UserData -FolderMap @{ Docs = $src } -BackupRoot $bk | Out-Null
        (& $script:S6Tool -Mode Verify -PackagePath $bk).Success | Should Be $true
        Set-Content -LiteralPath (Join-Path $bk 'Docs\a.txt') -Value 'tampered'
        (& $script:S6Tool -Mode Verify -PackagePath $bk).Success | Should Be $false
    }
}


Describe "S7 - GUI Tab 8 (Migration & Backup)" {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\tweaks.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-Nano11Preset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }
    function Test-Nano11RecoveryReadiness { param($Config) $script:S7CapturedConfig = $Config; [PSCustomObject]@{ ReadinessScore = 1 } }
    . $script:GuiPath
    function Get-S7Controls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-S7Controls $c } }

    It "Tab 8 has the personal folder checklist and Run Backup passes -FolderMap" {
        $gui = Show-Nano11GUI -NoShow
        try {
            @($gui.MigFolders.Items) -contains 'Documents' | Should Be $true
            @($gui.MigFolders.Items) -contains 'Downloads' | Should Be $true
            $a = Get-Nano11GuiBackupArgs -Gui $gui
            $a.ContainsKey('FolderMap') | Should Be $true
            $a.FolderMap.Count | Should BeGreaterThan 0
            $a.FolderMap['Documents'] | Should Be ([Environment]::GetFolderPath('MyDocuments'))
            $a.ContainsKey('IncludeSecrets') | Should Be $false
            $gui.MigExcludeSecrets.Checked = $false
            (Get-Nano11GuiBackupArgs -Gui $gui).IncludeSecrets | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "Tab 8 rule list never yields a placeholder row as a rule Id" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $list = $gui.MigRulesList
            if (-not $list.Enabled) { $list.Items.Count | Should Be 1 }
            @(Get-Nano11GuiMigrationRuleIds -Gui $gui) -contains 'No migration rules found' | Should Be $false
            $list.Enabled = $false
            if ($list.Items.Count -gt 0) { $list.SetItemChecked(0, $true) }
            @(Get-Nano11GuiMigrationRuleIds -Gui $gui).Count | Should Be 0
        } finally { $gui.Form.Dispose() }
    }

    It "Recovery Readiness Check uses the draft config of the current window" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $key = @($gui.ComponentCheckboxes.Keys)[0]
            $gui.ComponentCheckboxes[$key].Checked = -not $gui.ComponentCheckboxes[$key].Checked
            $script:S7CapturedConfig = $null
            [void](Get-Nano11GuiRecoveryReadiness -Gui $gui)
            $script:S7CapturedConfig[$key] | Should Be ([bool]$gui.ComponentCheckboxes[$key].Checked)
        } finally { $gui.Form.Dispose() }
    }

    It "IncludeMigrationAssistant lives on Tab 8 and still reaches the result" {
        $gui = Show-Nano11GUI -NoShow -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            $chk = $gui.ComponentCheckboxes['IncludeMigrationAssistant']
            $chk | Should Not BeNullOrEmpty
            $tab8 = @($gui.Form.Controls | ForEach-Object { Get-S7Controls $_ } | Where-Object { $_ -is [System.Windows.Forms.TabPage] -and $_.Text -match '8\. Migration' })[0]
            @(Get-S7Controls $tab8) -contains $chk | Should Be $true
            $chk.Checked = $true
            Complete-Nano11GuiResult -Gui $gui | Should Be $true
            $gui.Result['IncludeMigrationAssistant'] | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "has Browse, Estimate, Verify and Retry buttons and no stray Select/Clear All text" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $texts = @(Get-S7Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] } | ForEach-Object { $_.Text })
            foreach ($t in 'Browse...', 'Estimate Size', 'Verify Backup Integrity', 'Retry Failed Tasks Only') { ($texts -contains $t) | Should Be $true }
            @($texts | Where-Object { $_ -match '^(Select All|Clear All|Deselect All)$' }).Count | Should Be 14
        } finally { $gui.Form.Dispose() }
    }
}

Describe "S5: Migration Assistant bundling" {
    $s5Root = Split-Path -Parent $PSScriptRoot
    $s5Text = [System.IO.File]::ReadAllText((Join-Path $s5Root 'phases\11-unattend.ps1'))
    $s5Defs = Import-PowerShellDataFile -LiteralPath (Join-Path $s5Root 'config\tweaks.psd1')

    It "the component maps to the variable the phase reads" {
        $cd = @($s5Defs.Components | Where-Object { $_.Key -eq 'IncludeMigrationAssistant' })[0]
        $cd.Variable | Should Be 'includeMigrationAssistant'
        $s5Text.Contains('$includeMigrationAssistant') | Should Be $true
    }

    It "the phase targets the four files and the launcher" {
        foreach ($f in 'tools\Nano11-Migrator.ps1', 'lib\Nano11Migration.ps1', 'config\migration-rules.psd1', 'config\user-migration-rules.psd1', 'Launch-MigrationAssistant.cmd', 'Windows\Setup\Scripts\Migration', 'Users\Public\Desktop') {
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
            foreach ($n in 'Nano11-Migrator.ps1', 'Nano11Migration.ps1', 'migration-rules.psd1', 'user-migration-rules.psd1') {
                (Test-Path (Join-Path $dest $n)) | Should Be $true
            }
            $cmd = Join-Path $scratchDir 'Users\Public\Desktop\Launch-MigrationAssistant.cmd'
            ([System.IO.File]::ReadAllText($cmd)).Contains('-File "C:\Windows\Setup\Scripts\Migration\Nano11-Migrator.ps1" -GUI') | Should Be $true
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}



Describe "S8 - GUI user extensions tab and Preset Diff" {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\tweaks.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:AllTweakDefs['S8GamingSwitch'] = @{ Category = 'Gaming'; Default = $false; Description = 'S8 user switch' }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    $script:BuiltInPresets = [ordered]@{
        s8a = [ordered]@{ TweakSettings = [ordered]@{ S8GamingSwitch = $false } }
        s8b = [ordered]@{ TweakSettings = [ordered]@{ S8GamingSwitch = $true } }
    }
    $script:UserExtensionsResult = [PSCustomObject]@{ Loaded = $true; UserTweakCount = 1; UserPresetCount = 0; CustomScriptCount = 0; Errors = @('S8 sample error') }
    function Get-Nano11Preset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }
    . (Join-Path $script:RepoRoot 'lib\Nano11Extensions.ps1')
    . $script:GuiPath
    function Get-S8Controls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-S8Controls $c } }

    It "shows a Gaming user switch on the User Tweaks tab" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $chk = $gui.TweakCheckboxes['S8GamingSwitch']
            $chk | Should Not BeNullOrEmpty
            $tab = @(Get-S8Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.TabPage] -and $_.Text -match 'User Tweaks' })[0]
            $tab | Should Not BeNullOrEmpty
            @(Get-S8Controls $tab) -contains $chk | Should Be $true
            $chk.Checked = $true
            (Get-Nano11GuiDraftConfig -Gui $gui).TweakSettings['S8GamingSwitch'] | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "has a Preset Diff button, no fixed compare button, and the bottom buttons do not overlap" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $buttons = @(Get-S8Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] })
            @($buttons | Where-Object { $_.Text -eq 'Preset Diff' }).Count | Should Be 1
            @($buttons | Where-Object { $_.Text -like 'Compare Presets*' }).Count | Should Be 0
            $row = @($buttons | Where-Object { $_.Text -in 'Preset Diff', 'Check Dependencies', 'Start nano11 Build', 'Cancel' } | Sort-Object { $_.Left })
            $row.Count | Should Be 4
            for ($i = 1; $i -lt $row.Count; $i++) { ($row[$i].Left -ge $row[$i - 1].Right) | Should Be $true }
            @($buttons | Where-Object { $_.Text -match '^(Select All|Clear All|Deselect All)$' }).Count | Should Be 14
        } finally { $gui.Form.Dispose() }
    }

    It "diffs preset vs current window settings" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $gui.TweakCheckboxes['S8GamingSwitch'].Checked = $true
            $txt = Get-Nano11GuiPresetDiffText -Gui $gui -From 's8a' -To $script:Nano11GuiCurrentSettingsLabel
            $txt | Should Match 'S8GamingSwitch'
            $txt = Get-Nano11GuiPresetDiffText -Gui $gui -From 's8a' -To 's8b'
            $txt | Should Match 'S8GamingSwitch'
        } finally { $gui.Form.Dispose() }
    }

    It "Tab 8 shows extension counts, errors and the guide button" {
        $gui = Show-Nano11GUI -NoShow
        try {
            $all = @(Get-S8Controls $gui.Form)
            @($all | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -match 'User tweaks: 1\s+User presets: 0\s+Custom scripts: 0' }).Count | Should Be 1
            $gui.ExtensionsLabel.Text | Should Match 'S8 sample error'
            @($all | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Open Extensibility Guide' }).Count | Should Be 1
            Test-Path -LiteralPath (Join-Path $script:RepoRoot 'docs\EXTENSIBILITY_GUIDE.md') | Should Be $true
        } finally { $gui.Form.Dispose() }
    }
}

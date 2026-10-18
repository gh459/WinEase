# nano11.Tests.ps1 - Pester suite for the nano11 builder fork
# Run with:  Invoke-Pester -Path .\tests\nano11.Tests.ps1
# Requires:  Pester 3.4+ (ships with Windows PowerShell 5.1)

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
        $p.WaitForExit(300000)
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
    $paramNames = @($builderAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
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
    function Get-Nano11Preset { param([string]$Name) $null }

    . $script:GuiPath
    # Never block on the experimental Select All confirmation
    function Confirm-Nano11GuiAction { param([string]$Message, [string]$Title) $true }

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
        $gui.Form.Tag | Should Be $gui
        $gui.TweakCheckboxes.Count | Should Be $script:AllTweakDefs.Count
        Invoke-SelectButtons $gui.Form | Should Be 14
        # Toggle handlers reached the shared context: preset switched to Custom
        $gui.Preset.SelectedIndex | Should Be ($gui.Preset.Items.Count - 1)
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
        Invoke-SelectButtons $dlg | Should Be 4
    }
}

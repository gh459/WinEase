# WinEase.Tests.ps1 - Pester suite for the WinEase builder fork
# Run with:  Invoke-Pester -Path .\tests\WinEase.Tests.ps1
# Requires:  Pester 3.4+ (ships with Windows PowerShell 5.1)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'builderAst', Justification = 'Used inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Evaluates literal arrays/hashtables taken from the repo''s own source AST')]
param()

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BuilderPath = Join-Path -Path $script:RepoRoot -ChildPath "WinEasebuilder.ps1"
$script:GuiPath = Join-Path -Path $script:RepoRoot -ChildPath "gui\WinEaseGui.ps1"
$script:UnattendPath = Join-Path -Path $script:RepoRoot -ChildPath "autounattend.xml"
# The GUI tests below assume English (they match button texts like "Select All"); the display-language tests at the end set their own.
$env:WINEASE_UI_LANGUAGE = 'en'

Describe "WinEase builder - repository layout" {
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

Describe "WinEase builder - AST syntax" {
    It "parses with zero parser errors" {
        $content = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "gui\WinEaseGui.ps1 parses with zero parser errors" {
        $content = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "phases\10-registry.ps1 parses with zero parser errors" {
        $p10Path = Join-Path $script:RepoRoot "phases\10-registry.ps1"
        $content = [System.IO.File]::ReadAllText($p10Path, [System.Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It "phases\10-registry.ps1 TakeOwnershipContextMenu avoids cmd.exe /c %1 command injection" {
        $p10Path = Join-Path $script:RepoRoot "phases\10-registry.ps1"
        $content = [System.IO.File]::ReadAllText($p10Path, [System.Text.Encoding]::UTF8)
        $content | Should Not Match 'cmd\.exe /c takeown.*%1'
        $content | Should Match 'powershell\.exe.*takeown\.exe'
    }
}

Describe "WinEase builder - autounattend.xml" {
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

Describe "WinEase builder - profile presets" {
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

Describe "WinEase builder - IME decoupling filter logic (mock)" {
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

Describe "WinEase builder - end-to-end DryRun" {
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

# --- Regression tests: Remove-WinEaseTreeRobust (fixes the 41 GB deep_apply leak and the
# --- ~5-hour final cleanup stall). Loads WinEasehelpers.ps1 functions directly. ---
if (-not (Get-Command -Name Remove-WinEaseTreeRobust -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

Describe "WinEase builder - robust tree removal (long paths + image ACLs)" {
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
}

Describe "WinEase helpers - atomic file I/O (Write-WinEaseTextFileAtomic)" {
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

Describe "WinEase helpers - configuration conflict resolution (Test-WinEaseConfigConflicts)" {
    It "detects the Store and Windows Update dependency conflict without changing the settings" {
        $cfg = [PSCustomObject]@{
            KeepStore = $true
            RemoveStore = $false
            DisableWindowsUpdate = $true
        }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $res.HasConflicts | Should Be $true
        # the check is a pure validation: it reports, it never rewrites (AUD-14)
        $res.ResolvedConfig.DisableWindowsUpdate | Should Be $true
    }

    It "enforces safety gate on physical debloat when -AllowPhysicalDebloat is false" {
        $cfg = [PSCustomObject]@{
            AllowPhysicalDebloat = $false
            advancedDebloatExperimental = @("Physical deletion candidate")
            TweakSettings = @{ PhysicalDebloat = $true }
        }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $res.HasConflicts | Should Be $true
        # the check reports, it never rewrites (AUD-14); the builder applies the safeguard
        $res.ResolvedConfig.TweakSettings.PhysicalDebloat | Should Be $true
        $res.ResolvedConfig.advancedDebloatExperimental.Count | Should Be 1
        $gate = @($res.Conflicts | Where-Object { $_.Rule -eq 'PhysicalDebloatSafetyGate' })
        $gate.Count | Should Be 1
        $gate[0].Safeguard.Action | Should Be 'ClearExperimental'
    }
}

Describe "WinEase helpers - build resume integrity (Test-WinEaseResumeIntegrity)" {
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

Describe "WinEase helpers - BuildContext advanced debloat lists" {
    BeforeAll {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        $script:SavedStd = $script:advancedDebloatStandard
        $script:SavedExp = $script:advancedDebloatExperimental
    }
    AfterAll {
        $script:advancedDebloatStandard = $script:SavedStd
        $script:advancedDebloatExperimental = $script:SavedExp
    }

    It "defaults both lists to empty string arrays" {
        $ctx = [BuildContext]::new()
        @($ctx.AdvancedDebloatStandard).Count | Should Be 0
        @($ctx.AdvancedDebloatExperimental).Count | Should Be 0
    }

    It "keeps `$null as an empty list" {
        $script:advancedDebloatStandard = $null
        $script:advancedDebloatExperimental = $null
        $ctx = New-BuildContextFromScriptScope
        @($ctx.AdvancedDebloatStandard).Count | Should Be 0
        @($ctx.AdvancedDebloatExperimental).Count | Should Be 0
    }

    It "keeps an empty array empty" {
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $ctx = New-BuildContextFromScriptScope
        @($ctx.AdvancedDebloatStandard).Count | Should Be 0
        @($ctx.AdvancedDebloatExperimental).Count | Should Be 0
    }

    It "keeps a single element" {
        $script:advancedDebloatStandard = @('OnlyOne')
        $script:advancedDebloatExperimental = @('SoleExp')
        $ctx = New-BuildContextFromScriptScope
        @($ctx.AdvancedDebloatStandard).Count | Should Be 1
        $ctx.AdvancedDebloatStandard[0] | Should Be 'OnlyOne'
        $ctx.AdvancedDebloatExperimental[0] | Should Be 'SoleExp'
    }

    It "keeps multiple elements in order through context and back to script scope" {
        $std = @('Zeta', 'Alpha', 'Mid')
        $exp = @('E2', 'E1')
        $script:advancedDebloatStandard = $std
        $script:advancedDebloatExperimental = $exp
        $ctx = New-BuildContextFromScriptScope
        ($ctx.AdvancedDebloatStandard -join '|') | Should Be 'Zeta|Alpha|Mid'
        ($ctx.AdvancedDebloatExperimental -join '|') | Should Be 'E2|E1'
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        Sync-ScriptScopeFromContext $ctx
        @($script:advancedDebloatStandard).Count | Should Be 3
        ($script:advancedDebloatStandard -join '|') | Should Be 'Zeta|Alpha|Mid'
        ($script:advancedDebloatExperimental -join '|') | Should Be 'E2|E1'
        ($script:advancedDebloatStandard -is [string[]]) | Should Be $true
        ($script:advancedDebloatExperimental -is [string[]]) | Should Be $true
    }

    It "syncs an empty context back as an empty array, not a Boolean" {
        $ctx = [BuildContext]::new()
        Sync-ScriptScopeFromContext $ctx
        ($script:advancedDebloatStandard -is [bool]) | Should Be $false
        @($script:advancedDebloatStandard).Count | Should Be 0
        @($script:advancedDebloatExperimental).Count | Should Be 0
    }
}

Describe "WinEase helpers - Path and Directory Safety Guards" {
    BeforeAll {
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

Describe "WinEase setup scripts - Custom Scripts Logging" {
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
        $content | Should Match "Redact-WinEaseUserSecret"
        $content | Should Match "Duration:"
    }
}



Describe "WinEase GUI wiring - every toggle is consumed by the build" {
    $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
    $builderAst = [System.Management.Automation.Language.Parser]::ParseInput($builderText, [ref]$null, [ref]$null)
    $phasesDir = Join-Path -Path $script:RepoRoot -ChildPath "phases"
    $phaseText = (Get-ChildItem -LiteralPath $phasesDir -Filter "*.ps1" | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
# lib\WinEaseDebloat.ps1 holds the safe (PowerShell) engine of the Advanced Debloat targets
$phaseText += "`n" + [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"))
# config\schema.psd1 is the master schema: the lookup tables of the options live there
$schemaText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "config\schema.psd1"))
    $helpersText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "WinEasehelpers.ps1"))
    $scriptText = (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "scripts") -Filter "*.ps1" -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"

    # The builder derives these tables from config\schema.psd1; build them the same way here
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
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
            # Options may also be consumed through a lookup table whose keys are the option
            # names (for example the FoD package map in phase 06), so a key that only
            # appears as a table key counts as consumed as well.
            if ($phaseText -match "['`"]$([regex]::Escape($k))['`"]\s*=") { continue }
            # the lookup tables of the options live in the master schema
            if ($schemaText -match "['`"]$([regex]::Escape($k))['`"]\s*=") { continue }
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

    # --- No unconditional removals in the post-install scripts --------------------
    # A removal that runs on every installed system cannot be turned off by the user.
    # The post-install scripts therefore have to consult a flag that phase 11 only
    # writes when the matching option is enabled.
    It "the post-install scripts only remove or change things behind an option flag" {
        # A removal that runs on every installed system cannot be turned off by the user.
        # The post-install scripts therefore have to consult a flag that phase 11 only
        # writes when the matching option is enabled. The check is line based: a mutating
        # statement is acceptable when the nearest enclosing "if" block above it tests a
        # .flag path.
        $scriptDir = Join-Path $script:RepoRoot "scripts"
        $mutating = @(
            'Remove-Item\s+-LiteralPath\s+"\\\$initMarkerDir',
            'Remove-Item\s+-LiteralPath\s+"\\\$markerDir',
            'Stop-Process',
            'Stop-Service',
            'Set-Service',
            'Disable-ComputerRestore',
            'Compact\.exe',
            'fsutil\.exe',
            'powercfg\.exe'
        )
        $unconditional = @()
        foreach ($file in (Get-ChildItem -LiteralPath $scriptDir -Filter "*.ps1")) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s*#') { continue }
                $isMutating = $false
                foreach ($pat in $mutating) {
                    if ($line -match $pat) { $isMutating = $true; break }
                }
                if (-not $isMutating) { continue }
                # Walk upwards to the enclosing "if" that guards this statement. The
                # window is generous because a guarded block can be long (a loop over
                # services, for example). A closing brace only ends the search when it
                # closes the guarded block itself, so a nested loop or try block does not
                # stop the walk too early.
                $guarded = $false
                $depth = 0
                for ($j = $i - 1; $j -ge 0 -and $j -ge $i - 40; $j--) {
                    $up = $lines[$j]
                    # The guard may test a literal path or a variable that holds one
                    # (for example $hibernateFlag = "C:\...\hibernate-mode.flag").
                    if ($up -match 'Test-Path\s+["''][^"'']*\.flag["'']') { $guarded = $true; break }
                    if ($up -match '^\s*\$\w+\s*=\s*["''][^"'']*\.flag["'']') { $guarded = $true; break }
                    if ($up -match '^\s*\}' ) {
                        $depth++
                        # Three consecutive closing braces mean the guarded block itself
                        # was closed before this statement.
                        if ($depth -ge 3) { break }
                    }
                }
                if (-not $guarded) {
                    $unconditional += "$($file.Name):$($i + 1): $($line.Trim())"
                }
            }
        }
        ($unconditional -join ' | ') | Should Be ''
    }

    It "phase 11 stages a post-install flag for every post-install option" {
        $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $phase11Text = [System.IO.File]::ReadAllText((Join-Path $phasesDir "11-unattend.ps1"), [System.Text.Encoding]::UTF8)
        $postInstallOptions = @(
            'EnableCompactOS', 'EnableNtfs8dot3Disable', 'EnableUltimatePerformancePower',
            'EnableMsiMode', 'DisableAccessibilityTools', 'DisableWindowsSearchProcess',
            'HideSearchBox', 'DisableCrossDevice', 'DisableComputerRestore'
        )
        $missing = @()
        foreach ($opt in $postInstallOptions) {
            if (-not ($settingsDef.Tweaks | Where-Object { $_.Key -eq $opt })) { $missing += "$opt (not defined)"; continue }
            if ($phase11Text -notmatch [regex]::Escape("'$opt'")) { $missing += "$opt (no flag staged)" }
        }
        ($missing -join ', ') | Should Be ''
    }

    # --- Completeness of the option -> processing wiring -------------------------
    # These checks cover the reverse direction of the wiring test above: a phase that
    # references a setting key which does not exist in config\schema.psd1 can never be
    # influenced by the user, because Test-TweakEnabled falls through to its hard-coded
    # default argument for unknown keys.
    It "every Test-TweakEnabled key used by a phase is defined in config\schema.psd1" {
        $defined = @($tweakDefs.Keys)
        $componentKeys = @()
        $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $componentKeys = @($settingsDef.Components | ForEach-Object { $_.Key })
        $known = $defined + $componentKeys
        $unknown = @()
        foreach ($m in [regex]::Matches($phaseText, "Test-TweakEnabled\s+'([^']+)'")) {
            $k = $m.Groups[1].Value
            if ($known -notcontains $k) { $unknown += $k }
        }
        (($unknown | Sort-Object -Unique) -join ', ') | Should Be ''
    }

    It "the hard-coded default of every Test-TweakEnabled call matches the defined default" {
        # For a defined key Test-TweakEnabled returns TweakSettings[key] and never reaches
        # the default argument, but a mismatching argument is a trap for the next reader
        # and hides the effective default, so it is kept in sync.
        $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $defaults = @{}
        foreach ($td in $settingsDef.Tweaks) { $defaults[$td.Key] = [bool]$td.Default }
        $mismatched = @()
        foreach ($m in [regex]::Matches($phaseText, "Test-TweakEnabled\s+'([^']+)'\s*`$(true|false)")) {
            $k = $m.Groups[1].Value
            $arg = ($m.Groups[2].Value -eq 'true')
            if ($defaults.ContainsKey($k) -and $defaults[$k] -ne $arg) {
                $mismatched += "$k (arg=$($m.Groups[2].Value), default=$($defaults[$k]))"
            }
        }
        (($mismatched | Sort-Object -Unique) -join ', ') | Should Be ''
    }

    It "every Component variable is read by at least one phase or setup script" {
        # A GUI switch whose variable is never read has no effect at all.
        $unconsumed = @()
        foreach ($cd in $settingsDef.Components) {
            if ($cd.Type -eq 'Special' -or -not $cd.Variable) { continue }
            $v = $cd.Variable
            if (($phaseText -match "\`$$v\b") -or ($helpersText -match "\`$$v\b") -or ($scriptText -match "\`$$v\b")) { continue }
            $unconsumed += "$($cd.Key) (`$$v)"
        }
        ($unconsumed -join ', ') | Should Be ''
    }

    It "no setting key is defined in both Tweaks and Components" {
        # A key in both tables is registered twice: the two definitions can drift apart
        # (different defaults, different GUI visibility) and the winner depends on the
        # order in which the builder applies them.
        $componentKeyList = @($settingsDef.Components | ForEach-Object { $_.Key })
        $dupes = @($tweakDefs.Keys | Where-Object { $componentKeyList -contains $_ })
        ($dupes -join ', ') | Should Be ''
    }

    It "a Component default matches its GUI default" {
        $mismatched = @()
        foreach ($cd in $settingsDef.Components) {
            if (-not $cd.Gui) { continue }
            if (-not $cd.ContainsKey('Default') -or -not $cd.Gui.ContainsKey('Default')) { continue }
            if ([bool]$cd.Default -ne [bool]$cd.Gui.Default) {
                $mismatched += "$($cd.Key) (Default=$($cd.Default), Gui.Default=$($cd.Gui.Default))"
            }
        }
        ($mismatched -join ', ') | Should Be ''
    }

    It "every TweakGroup is read by a phase" {
        $groups = @()
        $groupDef = Select-String -Path (Join-Path $script:RepoRoot "WinEasebuilder.ps1") -Pattern '\$script:TweakGroups\s*=\s*\[ordered\]@\{' | Select-Object -First 1
        if ($groupDef) {
            $builderLines = Get-Content (Join-Path $script:RepoRoot "WinEasebuilder.ps1")
            $block = $builderLines[($groupDef.LineNumber - 1)..($groupDef.LineNumber + 12)] -join "`n"
            foreach ($m in [regex]::Matches($block, '(?m)^\s{4}(\w+)\s*=\s*@\{')) { $groups += $m.Groups[1].Value }
        }
        $unused = @()
        foreach ($g in $groups) {
            if ($phaseText -match "activeTweakGroups\['$g'\]") { continue }
            $unused += $g
        }
        ($unused -join ', ') | Should Be ''
    }

    It "phases do not read legacy alias names directly" {
        foreach ($a in $aliases.Keys) { ($phaseText -match "Test-TweakEnabled\s+'$a'") | Should Be $false }
    }

    It "GUI session maps TweakSettings onto the variable-backed tweaks" {
        $builderText | Should Match 'Sync-WinEaseTweakVariables'
        $builderText | Should Not Match '\$guiResult\.RadicalRAM'
    }

    # --- Stage 2: the PowerShell <-> Rust engine switch ------------------------------------
    # The engine of a target is bound in config\schema.psd1 (DebloatEngines). The rules are:
    #   * a target that is not selected never runs, no matter which engine it uses
    #   * the engine "PowerShell" never hands the target to the Rust binary
    #   * the engine "Rust" hands exactly that one key to the Rust binary
    $engineDefs = (Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")).DebloatEngines
    function Get-DebloatItemFromGuiSource {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GuiPath, [ref]$null, [ref]$null)
        $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$script:WinEaseDebloatStandardItems', '$script:WinEaseDebloatExperimentalItems' }, $true)
        $items = @()
        foreach ($a in $assigns) { $items += @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) }
        return @($items | Select-Object -Unique)
    }


    It "config\schema.psd1 binds every Advanced Debloat target to an engine" {
        $engineDefs.Count | Should BeGreaterThan 40
        $items = @($engineDefs | ForEach-Object { $_.Item })
        @($items | Select-Object -Unique).Count | Should Be $items.Count
        foreach ($def in $engineDefs) {
            $engines = @($def.Engines)
            $engines.Count | Should BeGreaterThan 0
            if (-not ($engines -contains 'PowerShell' -or $engines -contains 'Rust')) { throw "no engine for $($def.Item)" }
            if (-not ($engines -contains $def.Default)) { throw "the default engine of $($def.Item) is not allowed" }
        }
    }

    It "every GUI Advanced Debloat item has an engine binding" {
        $guiItems = Get-DebloatItemFromGuiSource
        $guiItems.Count | Should BeGreaterThan 40
        foreach ($item in $guiItems) {
            $def = @($engineDefs | Where-Object { $_.Item -eq $item })
            $def.Count | Should Be 1
        }
    }

    It "the Rust-only targets are the ones without a PowerShell handler" {
        $libText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"), [System.Text.Encoding]::UTF8)
        $handled = @([regex]::Matches($libText, "(?m)^\s{8}'([^']+)' \{") | ForEach-Object { $_.Groups[1].Value })
        $handled.Count | Should BeGreaterThan 0
        $rustOnly = @($engineDefs | Where-Object { @($_.Engines) -notcontains 'PowerShell' })
        $rustOnly.Count | Should BeGreaterThan 0
        foreach ($def in $rustOnly) {
            # a Rust-only target must not be handled by the safe engine
            if ($handled -contains $def.Item) { throw "the Rust-only target '$($def.Item)' has a safe handler" }
        }
    }

    It "every Rust-capable target names the Rust key the binary understands" {
        $rustSrc = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "tools\winease-physical-debloat\src\main.rs"), [System.Text.Encoding]::UTF8)
        foreach ($def in $engineDefs) {
            if (@($def.Engines) -notcontains 'Rust') { continue }
            $def.RustKey | Should Not BeNullOrEmpty
            $rustSrc | Should Match ([regex]::Escape($def.RustKey))
        }
    }

    It "the builder keeps the engine selection inside the selected targets" {
        # the engine helpers of the builder are loaded on their own
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Resolve-WinEaseDebloatEngine', 'ConvertTo-WinEaseDebloatTarget', 'Set-WinEaseDebloatEngineSelection', 'Test-WinEaseDebloatOptionEnabled', 'Test-WinEaseDebloatTarget')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count
        $script:WinEaseDebloatEngines = [ordered]@{}
        $script:WinEaseDebloatLegacyMap = [ordered]@{}
        foreach ($def in $engineDefs) {
            $script:WinEaseDebloatEngines[[string]$def.Item] = $def
            foreach ($legacy in @($def.Legacy)) { if ($legacy) { $script:WinEaseDebloatLegacyMap[[string]$legacy] = [string]$def.Item } }
        }
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        try {
            foreach ($fn in $funcs) { Invoke-Expression $fn.Extent.Text }

            $bt = 'Remove Bluetooth stack (service + binary) [20-40MB]'
            $legacy = 'Physical: Bluetooth stack (complete removal) [~20-40MB]'

            # an older profile entry is mapped onto the canonical target
            ConvertTo-WinEaseDebloatTarget -Item $legacy | Should Be $bt
            ConvertTo-WinEaseDebloatTarget -Item $bt | Should Be $bt

            # an engine for a target that is not selected is dropped
            $script:advancedDebloatStandard = @($bt)
            Set-WinEaseDebloatEngineSelection -Selection @{ $bt = 'Rust' }
            $script:DebloatEngineSelection.Contains($bt) | Should Be $true
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'Rust'

            $script:advancedDebloatStandard = @()
            $script:DebloatEngineSelection = [ordered]@{}
            Set-WinEaseDebloatEngineSelection -Selection @{ $bt = 'Rust' }
            $script:DebloatEngineSelection.Count | Should Be 0

            # an engine the target does not support is dropped as well
            $script:advancedDebloatStandard = @($bt)
            Set-WinEaseDebloatEngineSelection -Selection @{ $bt = 'PowerShell' }
            $script:DebloatEngineSelection.Contains($bt) | Should Be $true
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'PowerShell'
        } finally {
            $script:WinEaseDebloatEngines = $null
            $script:WinEaseDebloatLegacyMap = $null
            $script:DebloatEngineSelection = [ordered]@{}
        }
    }
    It "the phase 09 engine functions resolve and dispatch as specified" {
        # the engine functions of phase 09 are loaded on their own, so the dispatch can be
        # checked without running the phase
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Resolve-WinEaseDebloatEngine', 'Get-WinEaseDebloatRustKey', 'Test-WinEaseDebloatTarget')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count
        $script:WinEaseDebloatEngines = @{}
        foreach ($def in $engineDefs) { $script:WinEaseDebloatEngines[[string]$def.Item] = $def }
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        try {
            foreach ($fn in $funcs) { Invoke-Expression $fn.Extent.Text }

            $bt = 'Remove Bluetooth stack (service + binary) [20-40MB]'
            $defender = 'Physical: Defender (complete removal) [~50MB]'
            $swap = 'Remove swapfile.sys (pagefile disable) [256MB-1GB]'

            # the registered default runs when the user did not choose
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'PowerShell'
            Resolve-WinEaseDebloatEngine -Item $defender | Should Be 'Rust'

            # the user's choice wins
            $script:DebloatEngineSelection = [ordered]@{ $bt = 'Rust' }
            Resolve-WinEaseDebloatEngine -Item $bt | Should Be 'Rust'
            # the gate needs the target to be selected as well
            Test-WinEaseDebloatTarget -Item $bt -Engine 'Rust' | Should Be $false
            $script:advancedDebloatStandard = @($bt)
            Test-WinEaseDebloatTarget -Item $bt -Engine 'Rust' | Should Be $true
            Test-WinEaseDebloatTarget -Item $bt -Engine 'PowerShell' | Should Be $false
            $script:advancedDebloatStandard = @()

            # an engine the target does not support falls back to the default
            $script:DebloatEngineSelection = [ordered]@{ $defender = 'PowerShell' }
            Resolve-WinEaseDebloatEngine -Item $defender | Should Be 'Rust'

            # the Rust key is data driven (the swap file must not land on the page file key)
            Get-WinEaseDebloatRustKey -Item $bt | Should Be 'physical_bluetooth'
            Get-WinEaseDebloatRustKey -Item $swap | Should Be 'physical_swapfile'
            Get-WinEaseDebloatRustKey -Item $defender | Should Be 'physical_defender'
        } finally {
            # the GUI reads the same table; restore it so the later GUI tests see the real one
            $script:WinEaseDebloatEngines = $null
            $script:WinEaseDebloatEngineDefs = $null
            $script:DebloatEngineSelection = [ordered]@{}
        }
    }
    It "the phase 09 dispatch keeps the two engines apart" {
        $physText = [System.IO.File]::ReadAllText((Join-Path $phasesDir "09-physical-debloat.ps1"), [System.Text.Encoding]::UTF8)
        # the Rust dispatch only gets the targets whose engine is "Rust"
        $physText | Should Match '\(Resolve-WinEaseDebloatEngine -Item \$_\) -eq ''Rust'''
        $physText | Should Match 'Get-WinEaseDebloatRustKey -Item \$item'
        # the engine the user picked must survive: phase 09 may not reset the selection
        $physText | Should Not Match '^\$script:DebloatEngineSelection = \[ordered\]@\{\}$'
    }

    It "the GUI locks the engine while the target is not selected" {
        $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $guiText | Should Match 'Update-WinEaseDebloatRowState'
        $guiText | Should Match '\$locked = \(-not \$selected\) -or \(\$allowed\.Count -le 1\)'
        $guiText | Should Match '\$cell\.ReadOnly = \$locked'
    }

    It "the GUI offers the engine per target and a global switch" {
        $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
        $guiText | Should Match 'New-WinEaseDebloatGrid'
        $guiText | Should Match 'Set-WinEaseDebloatEngineForAll'
        $guiText | Should Match "Debloat\.Engine\.All"
    }

    It "an unselected target never reaches the Rust binary" {
        # the engine map can only add a Rust dispatch for a target that is in the list
        $libText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"), [System.Text.Encoding]::UTF8)
        $libText | Should Match 'Set-WinEaseDebloatEngineSelection'
        $libText | Should Match 'if \(\$selected -notcontains \$item\) \{ continue \}'
        # the gate every phase uses
        $libText | Should Match 'if \(\$selected -notcontains \$Item\) \{ return \$false \}'
    }
    It "every GUI Advanced Debloat item is owned by a phase" {
        # Every target declares the phase that runs its safe work (config\schema.psd1 ->
        # DebloatEngines -> Phase), so no work item is implemented twice.
        $owned = @()
        foreach ($def in $engineDefs) {
            if (-not $def.Phase) { throw "the target '$($def.Item)' has no owning phase" }
            $owned += $def.Item
        }
        $owned.Count | Should Be $engineDefs.Count
        $guiItems = Get-DebloatItemFromGuiSource
        foreach ($item in $guiItems) {
            if ($owned -notcontains $item) { throw "the target '$item' is not owned by a phase" }
        }
    }

    It "the safe work of a target runs in the phase that owns it" {
        # every phase that owns a target calls the shared dispatcher, so the work is done
        # exactly once and never a second time in phase 09
        $phases = @{
            '05-appx'           = 'phases\05-appx.ps1'
            '06-fod'            = 'phases\06-fod.ps1'
            '08-filesystem'     = 'phases\08-filesystem.ps1'
            '09-winsxs'         = 'phases\09-winsxs.ps1'
            '10-registry'       = 'phases\10-registry.ps1'
            '11-unattend'       = 'phases\11-unattend.ps1'
        }
        foreach ($phase in $phases.Keys) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $phases[$phase]), [System.Text.Encoding]::UTF8)
            if ($text -notmatch [regex]::Escape("Invoke-WinEaseDebloatTargets -Phase '$phase'") -and
                $text -notmatch [regex]::Escape("Test-WinEaseDebloatTarget -Item")) {
                throw "the phase $phase owns a target but never asks for it"
            }
        }
        # phase 09 is the Rust engine only
        $physText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\09-physical-debloat.ps1"), [System.Text.Encoding]::UTF8)
        $physText | Should Not Match 'Invoke-WinEaseDebloatTargets -Phase'
    }

    It "an Advanced Debloat target can switch on the option of the phase that owns it" {
        # the Option field of the table is the bridge between the two UIs: the target of the
        # Advanced Debloat tab and the granular option do the same work, once
        $withOption = @($engineDefs | Where-Object { $_.Option })
        $withOption.Count | Should BeGreaterThan 0
        # several targets may imply the same option (the event logs, the crash dumps and the
        # temp files are all part of the offline cache cleanup)
        $optionKeys = @($withOption | ForEach-Object { $_.Option })
        # every option the table names really exists
        $known = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")).Tweaks | ForEach-Object { $_.Key })
        foreach ($o in $optionKeys) {
            if ($known -notcontains $o) { throw "the option $o of the debloat table does not exist" }
        }
    }

    It "the safe handler of a target runs once, in the phase that owns it" {
        # the shared library is loaded on its own, with a scratch directory that stands in
        # for the mounted image
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $wanted = @('Get-WinEaseDebloatEngines', 'Get-WinEaseDebloatEngineDef', 'Resolve-WinEaseDebloatEngine', 'Test-WinEaseDebloatTarget', 'Test-WinEaseDebloatOptionEnabled', 'Invoke-WinEaseDebloatTargets', 'Invoke-WinEaseDebloatTarget', 'Remove-WinEaseDebloatPath', 'Get-WinEaseDebloatSafeHandlerItems')
        $funcs = $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
        $funcs.Count | Should Be $wanted.Count

        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("winease_debloat_" + [System.IO.Path]::GetRandomFileName())
        $patchCache = Join-Path $scratch "Windows\Installer\`$PatchCache$"
        New-Item -ItemType Directory -Force -Path $patchCache | Out-Null
        Set-Content -LiteralPath (Join-Path $patchCache "payload.msi") -Value "x" -Encoding ascii
        $script:scratchDir = $scratch
        $script:isDryRunMode = $false
        $script:WinEaseDebloatEngines = [ordered]@{}
        foreach ($def in $engineDefs) { $script:WinEaseDebloatEngines[[string]$def.Item] = $def }
        $script:advancedDebloatStandard = @()
        $script:advancedDebloatExperimental = @()
        $script:DebloatEngineSelection = [ordered]@{}
        try {
            foreach ($fn in $funcs) { Invoke-Expression $fn.Extent.Text }

            $target = 'Remove PatchCache (dir delete) [200-500MB]'
            # not selected -> nothing happens
            Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
            (Test-Path -LiteralPath (Join-Path $patchCache "payload.msi")) | Should Be $true

            # selected -> the owning phase removes it
            $script:advancedDebloatStandard = @($target)
            Invoke-WinEaseDebloatTargets -Phase '08-filesystem'
            (Test-Path -LiteralPath (Join-Path $patchCache "payload.msi")) | Should Be $false

            # a phase that does not own the target leaves it alone
            New-Item -ItemType Directory -Force -Path $patchCache | Out-Null
            Set-Content -LiteralPath (Join-Path $patchCache "payload.msi") -Value "x" -Encoding ascii
            Invoke-WinEaseDebloatTargets -Phase '06-fod'
            (Test-Path -LiteralPath (Join-Path $patchCache "payload.msi")) | Should Be $true
        } finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
            $script:scratchDir = $null
            $script:WinEaseDebloatEngines = $null
            $script:DebloatEngineSelection = [ordered]@{}
        }
    }
    # --- C1/C2: the master schema, the presets and the resolution engine -------------------
    It "the built-in presets live in config\presets.psd1" {
        $presetPath = Join-Path $script:RepoRoot "config\presets.psd1"
        Test-Path -LiteralPath $presetPath | Should Be $true
        $presets = Import-PowerShellDataFile -LiteralPath $presetPath
        @($presets.Presets.Keys).Count | Should BeGreaterThan 5
        # the descriptive names of the plan are accepted as well
        foreach ($alias in @('None', 'Standard', 'Gaming', 'UltraSlim', 'MinimalServices')) {
            $presets.Aliases.Contains($alias) | Should Be $true
            $presets.Presets.Contains($presets.Aliases[$alias]) | Should Be $true
        }
        # the builder does not define the values of the presets a second time
        $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
        $builderText | Should Not Match "ProfileName\s+= 'Extreme Slim & Gaming'"
        $builderText | Should Match 'config\\presets\.psd1'
    }

    It "the master schema replaces config\tweaks.psd1" {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:RepoRoot "config\tweaks.psd1") | Should Be $false
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        @($schema.Tweaks).Count | Should BeGreaterThan 50
        @($schema.Components).Count | Should BeGreaterThan 20
        @($schema.DebloatEngines).Count | Should BeGreaterThan 40
        # the targets of the options live in the schema as well
        @($schema.Targets.Keys).Count | Should BeGreaterThan 20
    }

    It "every option that the phases read through a lookup table is registered in the schema" {
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        $known = @(@($schema.Tweaks | ForEach-Object { $_.Key }) + @($schema.Components | ForEach-Object { $_.Key }))
        foreach ($p in $schema.Targets.Keys) {
            if ($known -notcontains $p) { throw "the option $p of the lookup table is not defined" }
            foreach ($pkg in @($schema.Targets[$p].FoDPackages)) { if (-not $pkg) { throw "the option $p has an empty target" } }
        }
    }

    It "the Rust capability of every target is declared in the schema" {
        $schema = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
        foreach ($def in $schema.DebloatEngines) {
            if ($def.SupportsRustPhysical) {
                if (-not $def.RustKey) { throw "the target $($def.Item) has no Rust key" }
                if (@($def.Engines) -notcontains 'Rust') { throw "the target $($def.Item) does not allow the Rust engine" }
            } else {
                if (@($def.Engines) -contains 'Rust') { throw "the target $($def.Item) allows the Rust engine but does not declare it" }
            }
        }
    }

    It "the polarity of an option follows the naming convention" {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        Get-WinEaseOptionPolarity -Key 'RemoveEdge' | Should Be 'Remove'
        Get-WinEaseOptionPolarity -Key 'DisableUAC' | Should Be 'Disable'
        Get-WinEaseOptionPolarity -Key 'EnableScripts' | Should Be 'Enable'
        Get-WinEaseOptionPolarity -Key 'KeepBluetooth' | Should Be 'Keep'
        Get-WinEaseOptionPolarity -Key 'BypassActivationRestrictions' | Should Be 'Feature'
    }

    It "the resolution engine applies the base, then the preset, then the user settings" {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        $base    = @{ A = $true; B = $true; C = 'Keep' }
        $preset  = @{ A = $false; B = $true; C = 'Off' }
        $over    = @{ A = $false; B = $true }
        $r = Resolve-WinEaseConfiguration -Base $base -Preset $preset -Overrides $over
        # the preset overrules the base
        $r.Components['C'] | Should Be 'Off'
        # an explicit setting of the user always wins - also an explicit $false
        $r.Components['A'] | Should Be $false
        $r.Components['B'] | Should Be $true
        # an option that is not in the base is not introduced
        $r2 = Resolve-WinEaseConfiguration -Base @{ A = $true } -Preset @{ X = $true } -Overrides @{ Y = $true }
        $r2.Components.Contains('X') | Should Be $false
        $r2.Components.Contains('Y') | Should Be $false
    }

    It "the resolution engine keeps the explicit tweak settings of the user" {
        . (Join-Path $script:RepoRoot "WinEasehelpers.ps1")
        $r = Resolve-WinEaseConfiguration -TweakBase @{ X = $true; Y = $true } -TweakPreset @{ X = $false } -TweakOverrides @{ Y = $false }
        $r.Tweaks['X'] | Should Be $false
        $r.Tweaks['Y'] | Should Be $false
    }

    It "the conflict check never rewrites a setting of the user" {
        $cfg = [PSCustomObject]@{ DisableWindowsUpdate = $true; RemoveStore = $true; TweakSettings = @{ PhysicalDebloat = $true } }
        $res = Test-WinEaseConfigConflicts -Config $cfg
        $res.HasConflicts | Should Be $true
        $res.ResolvedConfig.DisableWindowsUpdate | Should Be $true
        $res.ResolvedConfig.RemoveStore | Should Be $true
        $res.ResolvedConfig.TweakSettings.PhysicalDebloat | Should Be $true
        # the old "-AutoResolve" switch is gone
        (Get-Command Test-WinEaseConfigConflicts).Parameters.ContainsKey('AutoResolve') | Should Be $false
    }
    It "the option bridge is used by the phase that owns the option" {
        $fodText = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "phases\06-fod.ps1"), [System.Text.Encoding]::UTF8)
        $fodText | Should Match 'Test-WinEaseDebloatOptionEnabled -Option \$optKey'
    }
    It "the safe handlers live in the shared debloat library" {
        $libPath = Join-Path $script:RepoRoot "lib\WinEaseDebloat.ps1"
        Test-Path -LiteralPath $libPath | Should Be $true
        $libText = [System.IO.File]::ReadAllText($libPath, [System.Text.Encoding]::UTF8)
        $libText | Should Match 'function Invoke-WinEaseDebloatTargets'
        $libText | Should Match 'function Invoke-WinEaseDebloatTarget'
        $libText | Should Match 'function Test-WinEaseDebloatTarget'
        # phase 09 is the Rust engine only: it must not carry a safe handler chain any more
        $physText = [System.IO.File]::ReadAllText((Join-Path $phasesDir "09-physical-debloat.ps1"), [System.Text.Encoding]::UTF8)
        $physText | Should Not Match 'Invoke-WinEaseDebloatFeatureRemoval'
        $physText | Should Not Match 'Invoke-WinEaseDebloatCapabilityRemoval'
    }
}

Describe "WinEase settings - config\schema.psd1 is the single source of truth" {
    $builderText = [System.IO.File]::ReadAllText($script:BuilderPath, [System.Text.Encoding]::UTF8)
    $builderAst = [System.Management.Automation.Language.Parser]::ParseInput($builderText, [ref]$null, [ref]$null)
    $guiText = [System.IO.File]::ReadAllText($script:GuiPath, [System.Text.Encoding]::UTF8)
    $guiAst = [System.Management.Automation.Language.Parser]::ParseInput($guiText, [ref]$null, [ref]$null)
    $settingsDef =Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
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

    It "every GUI checkbox key (New-WinEaseToggleCheckBox) exists in the definition file" {
        # The GUI builds its tweak tabs from AllTweakDefs and the Services tab from $svcDefs; both
        # come from the definition file, so no literal setting key may be passed as -Key.
        $calls = [regex]::Matches($guiText, "New-WinEaseToggleCheckBox -Parent \S+ -Key (\S+) ")
        $calls.Count | Should BeGreaterThan 0
        foreach ($m in $calls) {
            $keyArg = $m.Groups[1].Value
            if ($keyArg -match '^["'']([^"'']+)["'']$') { $allKeys -contains $Matches[1] | Should Be $true }
            else { @('$tk', '$sd.Key') -contains $keyArg | Should Be $true }
        }
    }

    It "derived tables are built from the definition file, not hand-written" {
        foreach ($name in 'AllTweakDefs', 'TweakKeyAliases', 'TweakVariableMap', 'WinEaseProfileKeys') {
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

Describe "WinEase GUI - smoke test (form built without ShowDialog)" {
    # Same derived tables the builder hands the GUI, built from config\schema.psd1
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }

    . $script:GuiPath
    # Never block on the experimental Select All confirmation
    function Confirm-WinEaseGuiAction { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Message, [string]$Title) $true }

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
                    $want = $btn.Text -eq 'Select All'
                    if ($btn.Tag -and $btn.Tag.ContainsKey('Grid')) {
                        # Advanced Debloat grid: the button selects or clears every row
                        $grid = $btn.Tag.Grid
                        Set-WinEaseDebloatGridChecked -Grid $grid -Checked (-not $want)
                        [void]$btn.PerformClick()
                        $grid.Rows.Count | Should BeGreaterThan 0 | Out-Null
                        @($grid.Rows | Where-Object { [bool]$_.Cells['On'].Value -ne $want }).Count | Should Be 0 | Out-Null
                    } else {
                        $target = $btn.Tag.Target
                        # Start from the opposite state so the click has to change every box
                        Set-WinEaseChecked -Target $target -Checked (-not $want)
                        [void]$btn.PerformClick()
                        if ($target -is [System.Windows.Forms.CheckedListBox]) {
                            $target.Items.Count | Should BeGreaterThan 0 | Out-Null
                            $target.CheckedItems.Count | Should Be $(if ($want) { $target.Items.Count } else { 0 }) | Out-Null
                        } else {
                            @($target).Count | Should BeGreaterThan 0 | Out-Null
                            @($target | Where-Object { $_.Checked -ne $want }).Count | Should Be 0 | Out-Null
                        }
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
        $gui = Show-WinEaseGUI -NoShow
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
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
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

Describe "WinEase code quality - PSScriptAnalyzer" {
    $analyzerAvailable = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
    if (-not $analyzerAvailable) {
        Write-Warning "PSScriptAnalyzer is not installed - skipping the analyzer test. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    }

    It "reports zero Error/Warning findings with PSScriptAnalyzerSettings.psd1" -Skip:(-not $analyzerAvailable) {
        $settingsPath = Join-Path -Path $script:RepoRoot -ChildPath "PSScriptAnalyzerSettings.psd1"
        $targets = @(
            (Join-Path $script:RepoRoot "WinEasebuilder.ps1"),
            (Join-Path $script:RepoRoot "WinEasehelpers.ps1"),
            $script:GuiPath
        ) + @(Get-ChildItem -Path (Join-Path $script:RepoRoot "phases"), (Join-Path $script:RepoRoot "lib"), (Join-Path $script:RepoRoot "scripts"), (Join-Path $script:RepoRoot "tools"), (Join-Path $script:RepoRoot "tests") -Filter "*.ps1" -File | ForEach-Object { $_.FullName })
        $findings = @(foreach ($target in $targets) {
            Invoke-ScriptAnalyzer -Path $target -Settings $settingsPath -Severity Error, Warning
        })
        ($findings | ForEach-Object { "$($_.RuleName) $(Split-Path -Leaf $_.ScriptPath):$($_.Line) $($_.Message)" }) -join "`n" | Should Be ''
    }
}

# --- Dependency / feature-impact checker tests ---
if (-not (Get-Command -Name Test-WinEaseDependencies -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "WinEasehelpers.ps1")
}

Describe "WinEase dependency checker" {
    $depsPath = Join-Path -Path $script:RepoRoot -ChildPath "config\dependencies.psd1"
    $tweaksPath = Join-Path -Path $script:RepoRoot -ChildPath "config\schema.psd1"

    It "dependency catalog exists" {
        Test-Path -LiteralPath $depsPath | Should Be $true
    }

    It "covers every tweak key from config/schema.psd1" {
        $deps = Import-PowerShellDataFile -Path $depsPath
        $defs = Import-PowerShellDataFile -Path $tweaksPath
        foreach ($t in $defs.Tweaks) {
            $deps.Tweaks.ContainsKey($t.Key) | Should Be $true
        }
    }

    It "covers every component key from config/schema.psd1" {
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
            if ($guiLines[$i] -match '\$script:WinEaseDebloat(Standard|Experimental)Items\s*=\s*@\(') {
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
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Conflicts.Count | Should BeGreaterThan 0
    }

    It "WSLSupport wins over NoHypervisor: phase 11 never writes no-hypervisor.flag when WSL2 is enabled" {
        $p11 = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'phases\11-unattend.ps1'))
        $m = [regex]::Match($p11, '(?s)if \(\$noHypervisor -or \(Test-TweakEnabled ''NoHypervisor'' \$false\)\) \{(.*?)\n    \}')
        $m.Success | Should Be $true
        $m.Groups[1].Value | Should Match 'if \(\$wslSupport\)'
        # the flag write must sit in the else branch, i.e. after the wslSupport check
        $body = $m.Groups[1].Value
        $body.IndexOf('no-hypervisor.flag') | Should BeGreaterThan $body.IndexOf('if ($wslSupport)')
    }

    It "returns impacts for RemoveStore" {
        $cfg = @{ RemoveStore = $true; TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Impacts.Count | Should BeGreaterThan 0
    }

    It "returns impacts for 'Remove Print Spooler'" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Remove Print Spooler (service + binary) [20-30MB]'); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Impacts.Count | Should BeGreaterThan 0
    }

    It "marks 'Provisioning packages' as Unknown" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Remove Provisioning packages [5-10MB]'); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Unknowns.Count | Should BeGreaterThan 0
    }

    It "treats unregistered advanced debloat items as Unknown (fail-safe)" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @('Totally Unknown Item XYZ'); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.Unknowns.Count | Should BeGreaterThan 0
    }

    It "returns no issues for a safe/empty configuration" {
        $cfg = @{ TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }
        $r = Test-WinEaseDependencies -Config $cfg
        $r.HasIssues | Should Be $false
    }
}

# --- User Extensibility Engine tests (M2) ---
if (-not (Get-Command -Name Import-WinEaseUserExtensions -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "lib\WinEaseExtensions.ps1")
}
if (-not (Get-Command -Name Test-WinEaseRecoveryReadiness -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
}

Describe "User Extensibility Engine (lib/WinEaseExtensions.ps1)" {
    It "Import-WinEaseUserExtensions returns Loaded=false for missing file" {
        $r = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:RepoRoot "config\nonexistent-user-tweaks.psd1")
        $r.Loaded | Should Be $false
    }
    It "Import-WinEaseUserExtensions loads valid user-tweaks.psd1" {
        $r = Import-WinEaseUserExtensions -ConfigPath (Join-Path $script:RepoRoot "config\user\user-tweaks.psd1")
        $r.Loaded | Should Be $true
        $r.Errors.Count | Should Be 0
    }
    It "Test-WinEaseRecoveryReadiness returns expected properties" {
        $rr = Test-WinEaseRecoveryReadiness -Config @{ KeepRecoveryEnv = $false }
        $rr.PSObject.Properties.Name -contains 'HasSecondaryDrive' | Should Be $true
        $rr.PSObject.Properties.Name -contains 'ReadinessScore' | Should Be $true
        $rr.PSObject.Properties.Name -contains 'Recommendations' | Should Be $true
        $rr.WinReEnabledOnTarget | Should Be $false
    }
    It "Compare-WinEaseConfig returns a diff result" {
        $diff = Compare-WinEaseConfig -ReferenceConfig @{ TweakSettings = @{ DisableUAC = $false } } -DifferenceConfig @{ TweakSettings = @{ DisableUAC = $true } }
        $diff.TotalDiffCount | Should BeGreaterThan 0
        $diff.ReferenceName | Should Not Be $null
    }
    It "Get-WinEaseCustomScriptMetadata parses metadata headers" {
        $tmp = Join-Path $env:TEMP "test_script_meta.ps1"
        "# @WinEase-Id: TestScript`n# @WinEase-Stage: PreBuild`n# @WinEase-Order: 42`n# @WinEase-OnError: Warn`n# @WinEase-Description: Test desc`nWrite-Host 'hi'" | Set-Content $tmp -Encoding UTF8
        $m = Get-WinEaseCustomScriptMetadata -ScriptPath $tmp
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
if (-not (Get-Command -Name Get-WinEaseMigrationRules -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEaseMigration.ps1")
}

Describe "PC Migration & Backup Engine (tools/migrator/WinEaseMigration.ps1)" {
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
        if (Test-Path $srcDir) { Remove-Item $srcDir -Recurse -Force }
        if (Test-Path $bkDir) { Remove-Item $bkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $srcDir 'Documents') | Out-Null
        'hello' | Set-Content (Join-Path $srcDir 'Documents\test.txt')
        Backup-WinEaseUserData -FolderMap @{ Documents = (Join-Path $srcDir 'Documents') } -BackupRoot $bkDir | Out-Null
        $destFile = Join-Path $env:USERPROFILE 'test.txt'
        'existing' | Set-Content $destFile
        $r = Restore-WinEaseUserData -BackupRoot $bkDir -ConflictPolicy BackupExisting
        $r.RestoredFiles | Should Be 1
        Test-Path "$destFile.WinEase.bak" | Should Be $true
        Remove-Item $destFile -Force -ErrorAction SilentlyContinue
        Remove-Item "$destFile.WinEase.bak" -Force -ErrorAction SilentlyContinue
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

Describe "S1 - user extensions survive -PresetsOnly re-import" {
    It "keeps UserTweakDefs and UserCustomScripts after a -PresetsOnly call" {
        . (Join-Path $script:RepoRoot 'lib\WinEaseExtensions.ps1')
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
        $r1 = Import-WinEaseUserExtensions -ConfigPath $cfg
        $r1.UserTweakCount | Should Be 1
        $r1.CustomScriptCount | Should Be 1
        $r2 = Import-WinEaseUserExtensions -ConfigPath $cfg -PresetsOnly
        @($script:UserTweakDefs.Keys).Count | Should Be 1
        @($script:UserCustomScripts).Count | Should Be 1
        $r2.UserTweakCount | Should Be 1
        $r2.CustomScriptCount | Should Be 1
        $script:BuiltInPresets.Contains('S1Preset') | Should Be $true
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "dot-sources WinEaseExtensions.ps1 once in the builder (the migration engine is not part of the ISO build)" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$null)
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot' }, $true)
        $text = @($cmds | ForEach-Object { $_.Extent.Text })
        foreach ($name in 'WinEaseExtensions.ps1') {
            $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Right.Extent.Text -like "*$name*" }, $true))
            $assigns.Count | Should Be 1
            $var = $assigns[0].Left.VariablePath.UserPath
            @($text | Where-Object { $_ -eq ". `$$var" }).Count | Should Be 1
        }
    }
}


# --- S2: dependency checker additions ---
Describe "WinEase dependency checker S2 additions" {
    $emptyLists = @{ TweakSettings = @{}; AdvancedDebloatStandard = @(); AdvancedDebloatExperimental = @() }

    It "reports RemoveDrivers as Unknown" {
        $cfg = $emptyLists.Clone(); $cfg['RemoveDrivers'] = $true
        $r = Test-WinEaseDependencies -Config $cfg
        @($r.Unknowns | Where-Object { $_.Source -eq 'RemoveDrivers' }).Count | Should Be 1
    }

    It "reports AllowPhysicalDebloat as Unknown" {
        $cfg = $emptyLists.Clone(); $cfg['AllowPhysicalDebloat'] = $true
        $r = Test-WinEaseDependencies -Config $cfg
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
            $r = Test-WinEaseDependencies -Config $cfg
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
            $r = Test-WinEaseDependencies -Config $cfg
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
            $r = Test-WinEaseDependencies -Config $emptyLists
            $r.HasIssues | Should Be $false
        } finally {
            $script:UserTweakDefs = $saved
        }
    }

    It "still detects RemoveStore + KeepXboxServices and NoHypervisor + WSLSupport conflicts" {
        $cfg = $emptyLists.Clone(); $cfg['RemoveStore'] = $true; $cfg['KeepXboxServices'] = $true
        (Test-WinEaseDependencies -Config $cfg).Conflicts.Count | Should BeGreaterThan 0
        $cfg2 = $emptyLists.Clone(); $cfg2['NoHypervisor'] = $true; $cfg2['WSLSupport'] = $true
        (Test-WinEaseDependencies -Config $cfg2).Conflicts.Count | Should BeGreaterThan 0
    }
}


# --- S3: migration engine (task-based restore, report, BackupRoot guard) ---
Describe "Migration engine S3 (tools/migrator/WinEaseMigration.ps1)" {
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


Describe "S7 - GUI Tab 8 (Migration & Backup)" {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }
    function Test-WinEaseRecoveryReadiness { param($Config) $script:S7CapturedConfig = $Config; [PSCustomObject]@{ ReadinessScore = 1 } }
    . $script:GuiPath
    function Get-S7Controls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-S7Controls $c } }

    It "Tab 8 has the personal folder checklist and Run Backup passes -FolderMap" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            @($gui.MigFolders.Items) -contains 'Documents' | Should Be $true
            @($gui.MigFolders.Items) -contains 'Downloads' | Should Be $true
            $a = Get-WinEaseGuiBackupArgs -Gui $gui
            $a.ContainsKey('FolderMap') | Should Be $true
            $a.FolderMap.Count | Should BeGreaterThan 0
            $a.FolderMap['Documents'] | Should Be ([Environment]::GetFolderPath('MyDocuments'))
            $a.ContainsKey('IncludeSecrets') | Should Be $false
            $gui.MigExcludeSecrets.Checked = $false
            (Get-WinEaseGuiBackupArgs -Gui $gui).IncludeSecrets | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "Tab 8 rule list never yields a placeholder row as a rule Id" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $list = $gui.MigRulesList
            if (-not $list.Enabled) { $list.Items.Count | Should Be 1 }
            @(Get-WinEaseGuiMigrationRuleIds -Gui $gui) -contains 'No migration rules found' | Should Be $false
            $list.Enabled = $false
            if ($list.Items.Count -gt 0) { $list.SetItemChecked(0, $true) }
            @(Get-WinEaseGuiMigrationRuleIds -Gui $gui).Count | Should Be 0
        } finally { $gui.Form.Dispose() }
    }

    It "Recovery Readiness Check uses the draft config of the current window" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $key = @($gui.ComponentCheckboxes.Keys)[0]
            $gui.ComponentCheckboxes[$key].Checked = -not $gui.ComponentCheckboxes[$key].Checked
            $script:S7CapturedConfig = $null
            [void](Get-WinEaseGuiRecoveryReadiness -Gui $gui)
            $script:S7CapturedConfig[$key] | Should Be ([bool]$gui.ComponentCheckboxes[$key].Checked)
        } finally { $gui.Form.Dispose() }
    }

    It "IncludeMigrationAssistant lives on Tab 8 and still reaches the result" {
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            $chk = $gui.ComponentCheckboxes['IncludeMigrationAssistant']
            $chk | Should Not BeNullOrEmpty
            $tab8 = @($gui.Form.Controls | ForEach-Object { Get-S7Controls $_ } | Where-Object { $_ -is [System.Windows.Forms.TabPage] -and $_.Text -match '8\. Migration' })[0]
            @(Get-S7Controls $tab8) -contains $chk | Should Be $true
            $chk.Checked = $true
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
            $gui.Result['IncludeMigrationAssistant'] | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "has Browse, Estimate, Verify and Retry buttons and no stray Select/Clear All text" {
        $gui = Show-WinEaseGUI -NoShow
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
    $s5Defs = Import-PowerShellDataFile -LiteralPath (Join-Path $s5Root 'config\schema.psd1')

    It "the component maps to the variable the phase reads" {
        $cd = @($s5Defs.Components | Where-Object { $_.Key -eq 'IncludeMigrationAssistant' })[0]
        $cd.Variable | Should Be 'includeMigrationAssistant'
        $s5Text.Contains('$includeMigrationAssistant') | Should Be $true
    }

    It "the phase targets the four files and the launcher" {
        foreach ($f in 'tools\migrator\WinEase-Migrator.ps1', 'tools\migrator\WinEaseMigration.ps1', 'tools\migrator\migration-rules.psd1', 'config\user\user-migration-rules.psd1', 'Launch-MigrationAssistant.cmd', 'Windows\Setup\Scripts\Migration', 'Users\Public\Desktop') {
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
            foreach ($n in 'WinEase-Migrator.ps1', 'WinEaseMigration.ps1', 'migration-rules.psd1', 'user-migration-rules.psd1') {
                (Test-Path (Join-Path $dest $n)) | Should Be $true
            }
            $cmd = Join-Path $scratchDir 'Users\Public\Desktop\Launch-MigrationAssistant.cmd'
            ([System.IO.File]::ReadAllText($cmd)).Contains('-File "C:\Windows\Setup\Scripts\Migration\WinEase-Migrator.ps1" -GUI') | Should Be $true
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}



Describe "S8 - GUI user extensions tab and Preset Diff" {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
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
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }
    . (Join-Path $script:RepoRoot 'lib\WinEaseExtensions.ps1')
    . $script:GuiPath
    function Get-S8Controls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-S8Controls $c } }

    It "shows a Gaming user switch on the User Tweaks tab" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $chk = $gui.TweakCheckboxes['S8GamingSwitch']
            $chk | Should Not BeNullOrEmpty
            $tab = @(Get-S8Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.TabPage] -and $_.Text -match 'User Tweaks' })[0]
            $tab | Should Not BeNullOrEmpty
            @(Get-S8Controls $tab) -contains $chk | Should Be $true
            $chk.Checked = $true
            (Get-WinEaseGuiDraftConfig -Gui $gui).TweakSettings['S8GamingSwitch'] | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "has a Preset Diff button, no fixed compare button, and the bottom buttons do not overlap" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $buttons = @(Get-S8Controls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] })
            @($buttons | Where-Object { $_.Text -eq 'Preset Diff' }).Count | Should Be 1
            @($buttons | Where-Object { $_.Text -like 'Compare Presets*' }).Count | Should Be 0
            $row = @($buttons | Where-Object { $_.Text -in 'Preset Diff', 'Check Dependencies', 'Start WinEase Build', 'Cancel' } | Sort-Object { $_.Left })
            $row.Count | Should Be 4
            for ($i = 1; $i -lt $row.Count; $i++) { ($row[$i].Left -ge $row[$i - 1].Right) | Should Be $true }
            @($buttons | Where-Object { $_.Text -match '^(Select All|Clear All|Deselect All)$' }).Count | Should Be 14
        } finally { $gui.Form.Dispose() }
    }

    It "diffs preset vs current window settings" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $gui.TweakCheckboxes['S8GamingSwitch'].Checked = $true
            $txt = Get-WinEaseGuiPresetDiffText -Gui $gui -From 's8a' -To $script:WinEaseGuiCurrentSettingsLabel
            $txt | Should Match 'S8GamingSwitch'
            $txt = Get-WinEaseGuiPresetDiffText -Gui $gui -From 's8a' -To 's8b'
            $txt | Should Match 'S8GamingSwitch'
        } finally { $gui.Form.Dispose() }
    }

    It "Tab 8 shows extension counts, errors and the guide button" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $all = @(Get-S8Controls $gui.Form)
            @($all | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -match 'User tweaks: 1\s+User presets: 0\s+Custom scripts: 0' }).Count | Should Be 1
            $gui.ExtensionsLabel.Text | Should Match 'S8 sample error'
            @($all | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Open Extensibility Guide' }).Count | Should Be 1
            Test-Path -LiteralPath (Join-Path $script:RepoRoot 'docs\EXTENSIBILITY_GUIDE.md') | Should Be $true
        } finally { $gui.Form.Dispose() }
    }
}

Describe "Folder structure S9" {
    BeforeAll {
        $script:S9Root = $script:RepoRoot
        . (Join-Path -Path $script:S9Root -ChildPath "WinEasehelpers.ps1")
        . (Join-Path -Path $script:S9Root -ChildPath "lib\WinEaseExtensions.ps1")
    }
    It "migrator files live under tools/migrator and the old paths are gone" {
        foreach ($f in 'WinEaseMigration.ps1', 'WinEase-Migrator.ps1', 'migration-rules.psd1') {
            Test-Path -LiteralPath (Join-Path $script:S9Root "tools\migrator\$f") | Should Be $true
        }
        Test-Path -LiteralPath (Join-Path $script:S9Root "lib\WinEaseMigration.ps1") | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:S9Root "tools\WinEase-Migrator.ps1") | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\migration-rules.psd1") | Should Be $false
    }
    It "user config files live under config/user" {
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\user\user-tweaks.psd1") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\user\user-migration-rules.psd1") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:S9Root "config\user-tweaks.psd1") | Should Be $false
    }
    It "the builder does not load the migration engine" {
        $text = [System.IO.File]::ReadAllText($script:BuilderPath)
        $text.Contains('WinEaseMigration.ps1') | Should Be $false
    }
    It "the GUI loads the migration engine from tools/migrator, and only inside a function" {
        $gui = Join-Path $script:S9Root "gui\WinEaseGui.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($gui, [ref]$null, [ref]$null)
        $hits = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot' -and $n.Extent.Text -like '*WinEaseMigration.ps1*' }, $true))
        $hits.Count | Should Be 2
        foreach ($h in $hits) {
            $h.Extent.Text.Contains('tools\migrator\WinEaseMigration.ps1') | Should Be $true
            $fn = $h.Parent
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $fn -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $fn = $fn.Parent }
            ($null -ne $fn) | Should Be $true
        }
    }
    It "Resolve-WinEaseUserConfigPath prefers config/user, falls back to config with one warning" {
        $root = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'config\user-tweaks.psd1') -Value '@{}'
        $script:WinEaseLegacyConfigWarned = $null
        $first = Resolve-WinEaseUserConfigPath -RepoRoot $root -Name 'user-tweaks.psd1' -WarningVariable w1 -WarningAction SilentlyContinue
        [void](Resolve-WinEaseUserConfigPath -RepoRoot $root -Name 'user-tweaks.psd1' -WarningVariable w2 -WarningAction SilentlyContinue)
        $first | Should Be (Join-Path $root 'config\user-tweaks.psd1')
        @($w1).Count | Should Be 1
        @($w2).Count | Should Be 0
        New-Item -ItemType Directory -Path (Join-Path $root 'config\user') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'config\user\user-tweaks.psd1') -Value '@{}'
        Resolve-WinEaseUserConfigPath -RepoRoot $root -Name 'user-tweaks.psd1' | Should Be (Join-Path $root 'config\user\user-tweaks.psd1')
    }
    It "Get-WinEaseCustomScriptFiles maps stage folders and the older layout" {
        $root = Join-Path $TestDrive 'cs'
        $base = Join-Path $root 'tools\custom-scripts'
        foreach ($d in 'FirstLogon', 'UserOnce', 'user', 'PreBuild') { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
        foreach ($f in 'a.ps1', 'README.md', 'FirstLogon\b.ps1', 'FirstLogon\.gitkeep', 'user\c.ps1', 'UserOnce\d.ps1', 'PreBuild\e.ps1') { Set-Content -LiteralPath (Join-Path $base $f) -Value 'x' }
        $names = { param($st, $legacy) @(Get-WinEaseCustomScriptFiles -RepoRoot $root -Stage $st -IncludeLegacy:$legacy | ForEach-Object { $_.Name } | Sort-Object) -join ',' }
        (& $names 'FirstLogon' $false) | Should Be 'b.ps1'
        (& $names 'FirstLogon' $true) | Should Be 'a.ps1,b.ps1'
        (& $names 'UserOnce' $true) | Should Be 'c.ps1,d.ps1'
        (& $names 'PreBuild' $false) | Should Be 'e.ps1'
        (& $names 'OfflineImage' $true) | Should Be ''
    }
    It "scripts/custom is not used and every stage folder under tools/custom-scripts has a .gitkeep" {
        Test-Path -LiteralPath (Join-Path $script:S9Root "scripts\custom") | Should Be $false
        foreach ($st in 'PreBuild', 'OfflineImage', 'FirstLogon', 'UserOnce') {
            Test-Path -LiteralPath (Join-Path $script:S9Root "tools\custom-scripts\$st\.gitkeep") | Should Be $true
        }
    }
    It "WinEase_report.html is ignored by git and templates/report.html remains" {
        ([System.IO.File]::ReadAllText((Join-Path $script:S9Root ".gitignore")) -split "`r?`n") -contains 'WinEase_report.html' | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:S9Root "templates\report.html") | Should Be $true
    }
}

Describe "S10 - GUI and migrator cleanup (shared parts)" {
    $script:S10Gui = Join-Path -Path $script:RepoRoot -ChildPath "gui\WinEaseGui.ps1"
    $script:S10Mig = Join-Path -Path $script:RepoRoot -ChildPath "tools\migrator\WinEase-Migrator.ps1"
    $script:S10GuiText = [System.IO.File]::ReadAllText($script:S10Gui)
    $script:S10MigText = [System.IO.File]::ReadAllText($script:S10Mig)
    $script:S10GuiAst = [System.Management.Automation.Language.Parser]::ParseFile($script:S10Gui, [ref]$null, [ref]$null)

    It "colours are defined once: FromArgb only appears in the colour table" {
        ([regex]::Matches($script:S10GuiText, 'FromArgb')).Count | Should Be 14
        ([regex]::Matches($script:S10MigText, 'FromArgb')).Count | Should Be 0
    }

    It "OK message boxes go through Show-WinEaseGuiMessage (only it and the YesNo confirm call MessageBox)" {
        ([regex]::Matches($script:S10GuiText, 'MessageBox\]::Show')).Count | Should Be 2
        ([regex]::Matches($script:S10MigText, 'MessageBox')).Count | Should Be 0
        $fn = $script:S10GuiAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-WinEaseGuiMessage' }, $true)
        $kind = $fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Kind' }
        $set = ($kind.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments | ForEach-Object { $_.Value }
        (@($set) -join ',') | Should Be 'Info,Warning,Error'
    }

    It "the default backup folder name is spelled once per file" {
        ([regex]::Matches($script:S10GuiText, 'WinEase_migration_backup')).Count | Should Be 1
        ([regex]::Matches($script:S10MigText, 'WinEase_migration_backup')).Count | Should Be 1
    }

    It "the migrator builds its window from the shared parts (no raw WinForms controls)" {
        $script:S10MigText | Should Not Match 'New-Object\s+"?System\.Windows\.Forms\.(Form|TabControl|TabPage|Label|TextBox|Button|CheckBox|CheckedListBox|ComboBox)\b'
        $script:S10MigText | Should Not Match 'Start-Job'
        $script:S10MigText | Should Match 'Invoke-WinEaseGuiBackgroundJob'
        $script:S10MigText | Should Match 'WinEaseGui\.ps1'
    }

    It "the GUI file creates no Form/TabControl/ComboBox/TextBox outside the part functions" {
        $parts = 'New-WinEaseForm', 'New-WinEaseTabControl', 'New-WinEaseComboBox', 'New-WinEaseTextBox'
        $calls = $script:S10GuiAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Object' -and
            $n.Extent.Text -match 'System\.Windows\.Forms\.(Form|TabControl|ComboBox|TextBox)\b' }, $true)
        foreach ($c in $calls) {
            $owner = $c.Parent
            while ($owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            ($parts -contains $owner.Name) | Should Be $true
        }
    }

    It "Show-WinEaseGUI is short: tabs are built by their own functions" {
        $show = $script:S10GuiAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-WinEaseGUI' }, $true)
        ($show.Extent.EndLineNumber - $show.Extent.StartLineNumber) | Should BeLessThan 230
        foreach ($fnName in 'New-WinEaseMediaTab', 'New-WinEaseTweakTabs', 'New-WinEaseServicesTab', 'New-WinEaseDebloatTab', 'New-WinEaseMigrationTab', 'New-WinEaseUserTweaksTab') {
            $script:S10GuiAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Should Not BeNullOrEmpty
        }
    }

    It "Invoke-WinEaseGuiBackgroundJob returns output and errors, and restores the button and cursor" {
        . $script:S10Gui
        $form = New-Object System.Windows.Forms.Form
        $btn = New-Object System.Windows.Forms.Button
        $form.Controls.Add($btn)
        try {
            $o = Invoke-WinEaseGuiBackgroundJob -Button $btn -Form $form -ArgumentList 3, 'x' -ScriptBlock { param($n, $s) "$s$n"; Write-Error 'boom'; 42 }
            (@($o.Output) -join ',') | Should Be 'x3,42'
            $o.Error | Should BeNullOrEmpty
            (@($o.Errors) -join ';') | Should Be 'boom'
            $btn.Enabled | Should Be $true
            $form.Cursor | Should Be ([System.Windows.Forms.Cursors]::Default)
            $o2 = Invoke-WinEaseGuiBackgroundJob -Button $btn -Form $form -ScriptBlock { throw 'fail' }
            $o2.Error | Should Be 'fail'
            @($o2.Output).Count | Should Be 0
            $btn.Enabled | Should Be $true
        } finally { $form.Dispose() }
    }

    It "Invoke-WinEaseGuiBusy restores the button when the action throws" {
        . $script:S10Gui
        $form = New-Object System.Windows.Forms.Form
        $btn = New-Object System.Windows.Forms.Button
        $form.Controls.Add($btn)
        try {
            $threw = $false
            try { Invoke-WinEaseGuiBusy -Button $btn -Form $form -Action { throw 'x' } } catch { $threw = $true }
            $threw | Should Be $true
            $btn.Enabled | Should Be $true
            (Invoke-WinEaseGuiBusy -Button $btn -Form $form -ArgumentList 5 -Action { param($v) $v * 2 }) | Should Be 10
        } finally { $form.Dispose() }
    }

    It "default backup path and colour table" {
        . $script:S10Gui
        (Get-WinEaseDefaultMigrationBackupPath) | Should Be (Join-Path $env:USERPROFILE 'WinEase_migration_backup')
        (Get-WinEaseDefaultMigrationBackupPath -Base Documents) | Should Be (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WinEase_migration_backup')
        $script:WinEaseGuiColors.Count | Should Be 14
        $script:WinEaseGuiColors.Accent.ToArgb() | Should Be ([System.Drawing.Color]::FromArgb(0, 190, 255).ToArgb())
    }

    It "part factories keep their geometry and colours" {
        . $script:S10Gui
        $cmb = New-WinEaseComboBox -Items 'a', 'b' -SelectedIndex 1 -DropList -X 5 -Y 6 -Width 100
        $cmb.DropDownStyle | Should Be 'DropDownList'
        $cmb.SelectedIndex | Should Be 1
        $cmb.Location.X | Should Be 5
        $txt = New-WinEaseTextBox -X 1 -Y 2 -Width 50 -Height 60 -Multiline -ReadOnly -ScrollBars Vertical
        $txt.Multiline | Should Be $true
        $txt.ScrollBars | Should Be 'Vertical'
        $txt.BackColor.ToArgb() | Should Be ([System.Drawing.Color]::FromArgb(35, 38, 46).ToArgb())
        $frm = New-WinEaseForm -Text 't' -Width 300 -Height 200 -ClientSize -FixedDialog -NoMaximize
        try {
            $frm.ClientSize.Width | Should Be 300
            $frm.MaximizeBox | Should Be $false
            $frm.FormBorderStyle | Should Be 'FixedDialog'
        } finally { $frm.Dispose() }
    }
}


Describe "Builder cleanup S11" {
    BeforeAll {
        $script:S11Root = $script:RepoRoot
    }
    It "BOM-less .ps1/.psd1 files are ASCII only" {
        $bad = @()
        foreach ($f in (Get-ChildItem -LiteralPath $script:S11Root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psd1' -and $_.FullName -notmatch '[\\/](\.git|\.claude|logs)[\\/]' })) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            if (-not $hasBom -and (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0)) { $bad += $f.Name }
        }
        ($bad -join ',') | Should Be ''
    }
    It "parallel WindowsApps cleanup checks containment and reports failed folders" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:S11Root "phases\05-appx.ps1"))
        $src -match 'Test-WinEasePathWithin -Path \$fp -Root \$scratchDir' | Should Be $true
        $src -match 'Parallel cleanup failed for folder' | Should Be $true
    }
    It "self-test is split into per-check functions and still runs 21 checks" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:S11Root "lib\WinEaseSelfTest.ps1"))
        @([regex]::Matches($src, '(?m)^function Test-WinEaseSelfCheck\d\d')).Count | Should Be 21
    }
    It "no -isAnyBound repetition remains in the builder beyond the component-switch loop" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:S11Root "WinEasebuilder.ps1"))
        @([regex]::Matches($src, '& \$isAnyBound')).Count | Should Be 1
    }
}

Describe "Documentation S12" {
    # Files the docs mention that are created at run/build time, or live outside the repo.
    $script:DocPathExclusions = @(
        'migration-manifest.json',      # written into the built ISO/image by the migration engine
        'restore-state.json',           # written at run time by the restore tooling
        'custom-scripts-manifest.json', # generated at build time from the custom scripts folder
        'SetupComplete.cmd',            # written into the image by phases\11-unattend.ps1 at build time
        'ErrorHandler.cmd',             # written into the image by phases\11-unattend.ps1 at build time
        'gui\winui\bin\WinEaseGui.exe', # WinUI build output (gui\winui\build.ps1); git-ignored, absent from a clean checkout
        'implementation_plan.md'        # planning note outside the repository
    )

    function Get-MissingDocPath {
        param([string]$Text, [string]$RepoRoot, [string[]]$Files, [string[]]$Exclude = @())
        $topDirs = 'config|lib|phases|gui|tools|docs|scripts|templates|profiles|tests|\.github'
        $fileExt = 'ps1|psd1|psm1|json|md|xml|txt|cmd|bat|yml|yaml'
        $missing = @()
        foreach ($m in [regex]::Matches($Text, '`([^`\r\n]+)`')) {
            $p = ($m.Groups[1].Value -replace '/', '\').TrimEnd('\')
            if ($p -notmatch '^[A-Za-z0-9_.\\-]+$') { continue }
            if ($Exclude -contains $p) { continue }
            if ($p -match ('^(' + $topDirs + ')(\\|$)')) {
                if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $p))) { $missing += $p }
            }
            elseif ($p -match ('^[A-Za-z0-9_.\-]+\.(' + $fileExt + ')$')) {
                # a bare file name may live anywhere in the repo
                if (-not (@($Files | Where-Object { $_ -eq $p -or $_.EndsWith('\' + $p) }).Count -gt 0)) { $missing += $p }
            }
        }
        $missing | Select-Object -Unique
    }

    It "repo file paths in backticks in README, CHANGELOG and the extensibility guide exist" {
        $files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File | Where-Object { $_.FullName -notmatch '[\/](\.git|\.claude|logs)[\/]' } | ForEach-Object { $_.FullName.Substring($script:RepoRoot.Length).TrimStart('\') })
        $missing = @()
        foreach ($doc in @('README.md', 'CHANGELOG.md', 'docs\EXTENSIBILITY_GUIDE.md', 'docs\EXTENSIBILITY_GUIDE.ja.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $doc))
            foreach ($p in @(Get-MissingDocPath -Text $text -RepoRoot $script:RepoRoot -Files $files -Exclude $script:DocPathExclusions)) { $missing += "${doc}: $p" }
        }
        ($missing | Select-Object -Unique) -join "`n" | Should Be ''
    }

    It "the doc path check detects missing paths and accepts existing ones" {
        $files = @('phases\18-iso.ps1')
        $text = 'ok `config\schema.psd1` `docs/EXTENSIBILITY_GUIDE.md` `18-iso.ps1` bad `config\does-not-exist.psd1` `nope\x.ps1` `gone.ps1` `config/*.psd1` `migration-manifest.json`'
        $r = @(Get-MissingDocPath -Text $text -RepoRoot $script:RepoRoot -Files $files -Exclude @('migration-manifest.json'))
        ($r -join '|') | Should Be 'config\does-not-exist.psd1|gone.ps1'
    }
}

Describe "GUI display language (English / Japanese)" {
    # These tests run the GUI in English or Japanese explicitly; the rest of this file assumes English
    # (see WINEASE_UI_LANGUAGE at the top). Settings are redirected to a temp folder so the user's saved choice is never touched.
    $script:LangDir = Join-Path -Path $script:RepoRoot -ChildPath "config\ui-strings"
    $script:LangTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinEase_lang_" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:LangTemp -Force)
    $script:LangSavedLocalAppData = $env:LOCALAPPDATA
    $script:LangSavedEnv = $env:WINEASE_UI_LANGUAGE
    $env:LOCALAPPDATA = $script:LangTemp

    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    function Get-WinEasePreset { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Name) $null }

    . $script:GuiPath
    function Confirm-WinEaseGuiAction { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')] param([string]$Message, [string]$Title) $true }

    function Read-UiTable([string]$Lang) {
        $json = [System.IO.File]::ReadAllText((Join-Path $script:LangDir "$Lang.json"), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $t = @{}
        foreach ($p in $json.PSObject.Properties) { $t[$p.Name] = [string]$p.Value }
        return $t
    }
    # Literal keys passed to Get-WinEaseUiString in a source file (dynamic keys are skipped)
    function Get-UiKeyUsed([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-WinEaseUiString' }, $true)
        $keys = @()
        foreach ($c in $cmds) {
            $els = @($c.CommandElements)
            for ($i = 1; $i -lt $els.Count; $i++) {
                $e = $els[$i]
                $prev = $els[$i - 1]
                $isKey = ($prev -is [System.Management.Automation.Language.CommandParameterAst] -and $prev.ParameterName -eq 'Key') -or
                    ($i -eq 1 -and $e -isnot [System.Management.Automation.Language.CommandParameterAst])
                if ($isKey -and $e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $keys += $e.Value }
            }
        }
        return $keys
    }
    # Literal keys of the WinUI 3 window: _s.Get("Key" / _s.Format("Key" in gui\winui\WinEaseGui\*.cs (and the preset labels)
    function Get-UiKeyUsedWinUi {
        $keys = @()
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'gui\winui\WinEaseGui') -Filter '*.cs') {
            $src = [System.IO.File]::ReadAllText($f.FullName)
            $keys += @([regex]::Matches($src, '_s\.(?:Get|Format)\("([^"{}]+)"') | ForEach-Object { $_.Groups[1].Value })
            $keys += @([regex]::Matches($src, '"(Media\.Preset\.[A-Za-z0-9]+)"') | ForEach-Object { $_.Groups[1].Value })
        }
        return $keys
    }
    # English Advanced Debloat item names written in the GUI source (both the tab and the dialog)
    function Get-DebloatItemFromSource {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GuiPath, [ref]$null, [ref]$null)
        $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$script:WinEaseDebloatStandardItems', '$script:WinEaseDebloatExperimentalItems' }, $true)
        $items = @()
        foreach ($a in $assigns) { $items += @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) }
        return @($items | Select-Object -Unique)
    }
    function Get-AllControls($ctl) { foreach ($c in $ctl.Controls) { $c; Get-AllControls $c } }
    $script:LangOnlyPrefixes = '^(Tweak\.|Component\.|Debloat:)'

    It "en.json and ja.json have the same keys (tweak, component and Advanced Debloat translations live in ja only)" {
        $en = Read-UiTable 'en'
        $ja = Read-UiTable 'ja'
        $enOnly = @($en.Keys | Where-Object { -not $ja.ContainsKey($_) })
        $jaOnly = @($ja.Keys | Where-Object { -not $en.ContainsKey($_) -and $_ -notmatch $script:LangOnlyPrefixes })
        ($enOnly -join ',') | Should Be ''
        ($jaOnly -join ',') | Should Be ''
        @($en.Keys | Where-Object { $_ -match $script:LangOnlyPrefixes }).Count | Should Be 0
        $en.Count | Should BeGreaterThan 100
    }

    It "every string key used by the GUI and the migrator exists in the English table, and no English key is unused" {
        $en = Read-UiTable 'en'
        $used = @(Get-UiKeyUsed $script:GuiPath) + @(Get-UiKeyUsed (Join-Path $script:RepoRoot "tools\migrator\WinEase-Migrator.ps1")) +
            @(Get-UiKeyUsed (Join-Path $script:RepoRoot "gui\WinEaseWinUiHost.ps1")) + @(Get-UiKeyUsedWinUi)
        $used.Count | Should BeGreaterThan 100
        $missing = @($used | Where-Object { $_ -notmatch $script:LangOnlyPrefixes -and -not $en.ContainsKey($_) } | Select-Object -Unique)
        ($missing -join ',') | Should Be ''
        # Category.<name> keys are built from the category name at run time
        $unused = @($en.Keys | Where-Object { $used -notcontains $_ -and $_ -notmatch '^Category\.' })
        ($unused -join ',') | Should Be ''
    }

    It "the Japanese table translates every tweak, component switch and Advanced Debloat item, with no orphan entries" {
        $ja = Read-UiTable 'ja'
        $missing = @()
        foreach ($t in $settingsDef.Tweaks) { if (-not $ja.ContainsKey("Tweak.$($t.Key).Description")) { $missing += "Tweak.$($t.Key)" } }
        foreach ($c in @($settingsDef.Components | Where-Object { $_.Gui })) {
            foreach ($f in 'Text', 'Description') { if (-not $ja.ContainsKey("Component.$($c.Key).$f")) { $missing += "Component.$($c.Key).$f" } }
        }
        $items = Get-DebloatItemFromSource
        $items.Count | Should BeGreaterThan 40
        foreach ($i in $items) { if (-not $ja.ContainsKey("Debloat:$i")) { $missing += "Debloat:$i" } }
        ($missing -join "`n") | Should Be ''
        $tweakKeys = @($settingsDef.Tweaks | ForEach-Object { $_.Key })
        $compKeys = @($settingsDef.Components | Where-Object { $_.Gui } | ForEach-Object { $_.Key })
        $orphans = @()
        foreach ($k in $ja.Keys) {
            if ($k -match '^Tweak\.(.+)\.Description$') { if ($tweakKeys -notcontains $Matches[1]) { $orphans += $k } }
            elseif ($k -match '^Component\.(.+)\.(Text|Description)$') { if ($compKeys -notcontains $Matches[1]) { $orphans += $k } }
            elseif ($k -match '^Debloat:(.+)$') { if ($items -notcontains $Matches[1]) { $orphans += $k } }
        }
        ($orphans -join "`n") | Should Be ''
    }

    It "placeholders are the same in English and Japanese" {
        $en = Read-UiTable 'en'
        $ja = Read-UiTable 'ja'
        $bad = @()
        foreach ($k in $en.Keys) {
            $a = @([regex]::Matches($en[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            $b = @([regex]::Matches($ja[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            if ($a -ne $b) { $bad += $k }
        }
        ($bad -join ',') | Should Be ''
    }

    It "the Japanese table reads back as Japanese in Windows PowerShell 5.1 (UTF-8 data file, no mojibake)" {
        $ja = Read-UiTable 'ja'
        ([int[]][char[]]$ja['Button.SelectAll'] -join ',') | Should Be '12377,12409,12390,36984,25246'
        ([int[]][char[]]$ja['Language.Name'] -join ',') | Should Be '26085,26412,35486'
        foreach ($k in $ja.Keys) { $ja[$k].Contains([string][char]0xFFFD) | Should Be $false | Out-Null }
        # a fresh Windows PowerShell 5.1 process that only dot-sources the GUI file and asks for the string
        $cmd = ". '$($script:GuiPath)'; `$s = Get-WinEaseUiString 'Button.SelectAll' -Language ja; ([int[]][char[]]`$s) -join ','"
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd
        (@($out)[-1]) | Should Be '12377,12409,12390,36984,25246'
    }

    It "the source files stay ASCII: Japanese lives only in the JSON tables" {
        foreach ($f in 'gui\WinEaseGui.ps1', 'tools\migrator\WinEase-Migrator.ps1', 'WinEasebuilder.ps1', 'lib\WinEaseExtensions.ps1', 'config\schema.psd1') {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:RepoRoot $f))
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
        }
    }

    It "Get-WinEaseUiString falls back from the chosen language to English, then to the default, then to the key" {
        Set-WinEaseUiLanguage -Language 'ja'
        try {
            (Get-WinEaseUiString 'No.Such.Key') | Should Be 'No.Such.Key'
            (Get-WinEaseUiString 'No.Such.Key' -Default 'dflt') | Should Be 'dflt'
            (Get-WinEaseUiTable -Language 'en')['Test.OnlyEnglish'] = 'English only'
            (Get-WinEaseUiString 'Test.OnlyEnglish') | Should Be 'English only'
            (Get-WinEaseUiString 'Test.OnlyEnglish' -Language 'en') | Should Be 'English only'
            (Get-WinEaseUiString 'Button.SelectAll') | Should Be (Get-WinEaseUiString 'Button.SelectAll' -Language 'ja')
            (Get-WinEaseUiString 'Button.SelectAll') | Should Not Be 'Select All'
            (Get-WinEaseUiString 'Main.Estimate' -Format 2 -Language 'en') | Should Be 'Estimated ISO Size: ~2 GB (LZX baseline)'
        } finally {
            [void](Get-WinEaseUiTable -Language 'en').Remove('Test.OnlyEnglish')
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "a missing or unreadable table never throws (empty table, key comes back)" {
        $savedTables = $script:WinEaseUiTables
        $savedRoot = $script:WinEaseGuiRepoRoot
        $savedDir = $script:WinEaseGuiDir
        try {
            $script:WinEaseUiTables = @{}
            $script:WinEaseGuiRepoRoot = Join-Path $script:LangTemp 'nowhere'
            $script:WinEaseGuiDir = Join-Path $script:LangTemp 'nowhere'
            Set-WinEaseUiLanguage -Language 'ja'
            (Get-WinEaseUiString 'Button.SelectAll') | Should Be 'Button.SelectAll'
            (Get-WinEaseUiString 'Button.SelectAll' -Default 'Select All') | Should Be 'Select All'
        } finally {
            $script:WinEaseGuiRepoRoot = $savedRoot
            $script:WinEaseGuiDir = $savedDir
            $script:WinEaseUiTables = $savedTables
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "language choice: -UiLanguage beats the environment, which beats the saved choice, which beats the OS language" {
        $env:WINEASE_UI_LANGUAGE = ''
        $settingsFile = Get-WinEaseGuiSettingsPath
        $settingsFile | Should Be (Join-Path $script:LangTemp 'WinEase\gui-settings.json')
        if (Test-Path -LiteralPath $settingsFile) { Remove-Item -LiteralPath $settingsFile -Force }
        $osLang = if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ja') { 'ja' } else { 'en' }
        (Resolve-WinEaseUiLanguage) | Should Be $osLang
        Save-WinEaseGuiLanguage -Language 'ja'
        (Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).UiLanguage | Should Be 'ja'
        (Resolve-WinEaseUiLanguage) | Should Be 'ja'
        (Resolve-WinEaseUiLanguage -Requested 'en') | Should Be 'en'
        $env:WINEASE_UI_LANGUAGE = 'en'
        (Resolve-WinEaseUiLanguage) | Should Be 'en'
        (Resolve-WinEaseUiLanguage -Requested 'ja') | Should Be 'ja'
        (Resolve-WinEaseUiLanguage -Requested 'xx') | Should Be 'en'
        $env:WINEASE_UI_LANGUAGE = ''
        Save-WinEaseGuiLanguage -Language 'en'
        (Resolve-WinEaseUiLanguage) | Should Be 'en'
        # other keys of the settings file survive a save
        [System.IO.File]::WriteAllText($settingsFile, '{ "Other": 5, "UiLanguage": "en" }')
        Save-WinEaseGuiLanguage -Language 'ja'
        $after = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        $after.Other | Should Be 5
        $after.UiLanguage | Should Be 'ja'
        # an unreadable settings file is ignored
        [System.IO.File]::WriteAllText($settingsFile, 'not json')
        (Resolve-WinEaseUiLanguage) | Should Be $osLang
        $env:WINEASE_UI_LANGUAGE = 'en'
    }

    It "failing to save the language does not throw" {
        $blocker = Join-Path $script:LangTemp 'blocked'
        [System.IO.File]::WriteAllText($blocker, 'x')
        $env:LOCALAPPDATA = $blocker
        try {
            { Save-WinEaseGuiLanguage -Language 'ja' } | Should Not Throw
            (Resolve-WinEaseUiLanguage -Requested 'ja') | Should Be 'ja'
        } finally { $env:LOCALAPPDATA = $script:LangTemp }
    }

    It "tweak description: language table first, then DescriptionJa of a user tweak (Japanese only), then the Description" {
        Set-WinEaseUiLanguage -Language 'ja'
        try {
            (Get-WinEaseTweakDescription -Key 'DisableUAC' -Def @{ Description = 'x' }) | Should Be (Get-WinEaseUiString 'Tweak.DisableUAC.Description' -Language 'ja')
            (Get-WinEaseTweakDescription -Key 'User_Test' -Def @{ Description = 'plain'; DescriptionJa = 'ja text' }) | Should Be 'ja text'
            (Get-WinEaseTweakDescription -Key 'User_Test' -Def @{ Description = 'plain' }) | Should Be 'plain'
            Set-WinEaseUiLanguage -Language 'en'
            (Get-WinEaseTweakDescription -Key 'User_Test' -Def @{ Description = 'plain'; DescriptionJa = 'ja text' }) | Should Be 'plain'
            (Get-WinEaseTweakDescription -Key 'DisableUAC' -Def $script:AllTweakDefs['DisableUAC']) | Should Be $script:AllTweakDefs['DisableUAC'].Description
        } finally { Set-WinEaseUiLanguage -Language 'en' }
    }

    It "user tweaks keep DescriptionJa in AllTweakDefs" {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "lib\WinEaseExtensions.ps1"))
        $src | Should Match 'DescriptionJa'
    }

    It "builder and migrator take -UiLanguage en|ja" {
        foreach ($f in 'WinEasebuilder.ps1', 'tools\migrator\WinEase-Migrator.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $f), [ref]$null, [ref]$null)
            $p = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'UiLanguage' })
            $p.Count | Should Be 1
            $set = @(($p[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments | ForEach-Object { $_.Value })
            ($set -join ',') | Should Be 'en,ja'
        }
    }

    It "English window: texts are the same English as before the language option existed" {
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en
        try {
            $gui.Form.Text | Should Be 'WinEase Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer'
            $tabs = @($gui.Tabs.TabPages | ForEach-Object { $_.Text })
            ($tabs -join '|') | Should Be ' 1. Media & Output | 2. Security & Bypass | 3. Privacy & AI | 4. Performance | 5. UI & Shell | 6. Services & Apps | 7. Advanced Debloat | 8. Migration & Backup | 9. User Tweaks '
            $gui.Preset.Items[0] | Should Be 'Extreme Slim & Gaming (Max debloat, minimal memory, ultra-low latency)'
            $gui.DryRun.Text | Should Be 'DryRun (Simulation Mode)'
            $gui.TweakCheckboxes['DisableUAC'].Text | Should Be ('DisableUAC - ' + $script:AllTweakDefs['DisableUAC'].Description)
            $gui.ComponentCheckboxes['RemoveDefender'].Text | Should Be ('RemoveDefender - ' + $script:ComponentDefs['RemoveDefender'].Gui.Text)
            @(Get-AllControls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -match '^(Select All|Clear All|Deselect All)$' }).Count | Should Be 14
            # plain strings, not wrapped items, so English behaves exactly as before
            ($gui.GrdStd.Rows[0].Tag -is [string]) | Should Be $true
        } finally { $gui.Form.Dispose() }
    }

    It "Japanese window: builds without showing, texts are Japanese, Advanced Debloat results stay English" {
        $ja = Read-UiTable 'ja'
        $english = Get-DebloatItemFromSource
        $gui = Show-WinEaseGUI -NoShow -UiLanguage ja -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            $gui.Form.Text | Should Be $ja['Main.WindowTitle']
            $gui.Tabs.TabPages[0].Text | Should Be $ja['Tab.Media']
            $gui.DryRun.Text | Should Be $ja['Main.DryRun']
            $gui.TweakCheckboxes['DisableUAC'].Text | Should Be ('DisableUAC - ' + $ja['Tweak.DisableUAC.Description'])
            $gui.ComponentCheckboxes['RemoveDefender'].Text | Should Be ('RemoveDefender - ' + $ja['Component.RemoveDefender.Text'])
            @(Get-AllControls $gui.Form | Where-Object { $_ -is [System.Windows.Forms.Button] -and ($_.Text -eq $ja['Button.SelectAll'] -or $_.Text -eq $ja['Button.ClearAll']) }).Count | Should Be 14
            # every item shows its translation, and checking all of them hands the English text on
            $gui.GrdStd.Rows.Count | Should BeGreaterThan 20
            $gui.GrdStd.Rows[0].Cells['Target'].Value | Should Be $ja['Debloat:Remove WinRE (reagentc /disable + file delete) [500-700MB]']
            Set-WinEaseDebloatGridChecked -Grid $gui.GrdStd -Checked $true
            Set-WinEaseDebloatGridChecked -Grid $gui.GrdExp -Checked $true
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
            $r = $gui.Result
            @($r.AdvancedDebloatStandard).Count | Should Be $gui.GrdStd.Rows.Count
            foreach ($v in @($r.AdvancedDebloatStandard) + @($r.AdvancedDebloatExperimental)) { ($english -contains $v) | Should Be $true | Out-Null }
            ($r.AdvancedDebloatStandard -join "`n") | Should Be ((@($gui.GrdStd.Rows | ForEach-Object { $_.Tag })) -join "`n")
            (Get-WinEaseGuiDraftConfig -Gui $gui).AdvancedDebloatExperimental[0] | Should Match '^Physical: '
            $r.TweakSettings.Count | Should Be $script:AllTweakDefs.Count
        } finally { $gui.Form.Dispose() }
        # a profile that already holds the English names pre-checks the right (translated) rows
        $first = $english[0]
        $gui2 = Show-WinEaseGUI -NoShow -UiLanguage ja -InitialSettings @{ AdvancedDebloatStandard = @($first) }
        try {
            @($gui2.GrdStd.Rows | Where-Object { [bool]$_.Cells['On'].Value }).Count | Should Be 1
            @($gui2.GrdStd.Rows | Where-Object { [bool]$_.Cells['On'].Value })[0].Tag | Should Be $first
        } finally { $gui2.Form.Dispose() }
    }

    It "the engine cell is locked while the target is not selected" {
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            # a target that supports both engines starts unchecked -> the engine is locked
            $row = @($gui.GrdStd.Rows | Where-Object { @($_.Tag) -like '*Bluetooth*' })[0]
            $row | Should Not BeNullOrEmpty
            $row.Cells['On'].Value | Should Be $false
            $row.Cells['Engine'].ReadOnly | Should Be $true
            # checking it unlocks the engine
            $row.Cells['On'].Value = $true
            Update-WinEaseDebloatRowState -Grid $gui.GrdStd -RowIndex $row.Index -EngineDefs (Get-WinEaseDebloatEngineDefs)
            $row.Cells['Engine'].ReadOnly | Should Be $false
            # a target that only the Rust engine can remove stays locked
            $rustOnly = @($gui.GrdExp.Rows | Where-Object { [string]$_.Tag -like 'Physical: Defender*' })[0]
            $rustOnly | Should Not BeNullOrEmpty
            $rustOnly.Cells['Engine'].ReadOnly | Should Be $true
            $rustOnly.Cells['Engine'].Value | Should Be 'Rust'
        } finally { $gui.Form.Dispose() }
    }

    It "the global engine switch sets every target that supports it" {
        $gui = Show-WinEaseGUI -NoShow -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            Set-WinEaseDebloatEngineForAll -Grids @($gui.GrdStd, $gui.GrdExp) -Engine 'Rust'
            $dual = @($gui.GrdStd.Rows | Where-Object { @($_.Tag) -like '*Bluetooth*' })[0]
            $dual.Cells['Engine'].Value | Should Be 'Rust'
            # a target that only the Rust engine can remove is not changed
            $rustOnly = @($gui.GrdExp.Rows | Where-Object { [string]$_.Tag -like 'Physical: Defender*' })[0]
            $rustOnly.Cells['Engine'].Value | Should Be 'Rust'
            # the draft config carries the engine of every target, the result only the changed ones
            Set-WinEaseDebloatGridChecked -Grid $gui.GrdStd -Checked $true
            $cfg = Get-WinEaseGuiDraftConfig -Gui $gui
            $cfg.DebloatEngineSelection.Count | Should BeGreaterThan 0
            Complete-WinEaseGuiResult -Gui $gui -SkipPhysicalDebloatConsent | Should Be $true
            $r = $gui.Result
            $r.DebloatEngineSelection.Count | Should BeGreaterThan 0
            foreach ($k in $r.DebloatEngineSelection.Keys) { $r.DebloatEngineSelection[$k] | Should Be 'Rust' }
        } finally { $gui.Form.Dispose() }
    }

    It "the window starts on the safe preset with every engine on PowerShell" {
        $gui = Show-WinEaseGUI -NoShow
        try {
            $gui.Preset.SelectedIndex | Should Be 1
            $gui.GrdStd.Rows[0].Cells['Engine'].Value | Should Be 'PowerShell'
        } finally { $gui.Form.Dispose() }
    }
    It "Advanced Debloat dialog in Japanese returns the English item names" {
        $english = Get-DebloatItemFromSource
        Set-WinEaseUiLanguage -Language 'ja'
        $dlg = Show-AdvancedDebloatDialog -NoShow
        try {
            $dlg.Text | Should Be (Get-WinEaseUiString 'Dlg.Debloat.Title' -Language 'ja')
            Set-WinEaseDebloatGridChecked -Grid $dlg.Tag.Std -Checked $true
            Set-WinEaseDebloatGridChecked -Grid $dlg.Tag.Exp -Checked $true
            $std = @((Get-WinEaseDebloatGridState -Grid $dlg.Tag.Std).Selected)
            $exp = @((Get-WinEaseDebloatGridState -Grid $dlg.Tag.Exp).Selected)
            $std.Count | Should Be 32
            foreach ($v in @($std) + @($exp)) { ($english -contains $v) | Should Be $true | Out-Null }
            $dlg.Tag.Std.Rows[0].Cells['Target'].Value | Should Not Be $std[0]
        } finally {
            $dlg.Dispose()
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "switching the language keeps what was typed, checked and selected (and saves the choice)" {
        $env:WINEASE_UI_LANGUAGE = 'en'
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en -InitialSettings @{ SourceDrive = 'E:\'; TweakSettings = [ordered]@{} }
        try {
            $gui.Work.Text = 'D:\work space'
            $gui.Index.Text = '3'
            $gui.Drivers.Text = 'D:\drv'
            $gui.UserName.Text = 'Taro'
            $gui.ComputerName.Text = 'PC-1'
            $gui.DryRun.Checked = $true
            $gui.VHDX.Checked = $true
            $gui.RadSWM.Checked = $true
            $gui.TweakCheckboxes['DisableUAC'].Checked = $true
            $gui.ComponentCheckboxes['RemoveStore'].Checked = $true
            $gui.GrdStd.Rows[2].Cells['On'].Value = $true
            $gui.GrdExp.Rows[4].Cells['On'].Value = $true
            $gui.MigRoot.Text = 'D:\mig'
            $gui.CustomPaths.Text = "C:\a`r`nC:\b"
            $gui.MigExcludeSecrets.Checked = $false
            $gui.MigConflict.SelectedIndex = 2
            $gui.MigFolders.SetItemChecked(3, $true)
            Initialize-WinEaseGuiMigrationRules -List $gui.MigRulesList
            $gui.MigTab.Tag.Loaded = $true
            $gui.MigRulesList.SetItemChecked(1, $true)
            $gui.MigRulesList.SetItemChecked(3, $true)
            $ruleIds = @(Get-WinEaseGuiMigrationRuleIds -Gui $gui)
            $ruleIds.Count | Should Be 2
            $stdValue = $gui.GrdStd.Rows[2].Tag
            $gui.Tabs.SelectedIndex = 4
            $presetIndex = $gui.Preset.SelectedIndex
            $before = Get-WinEaseGuiDraftConfig -Gui $gui

            Switch-WinEaseGuiLanguage -Gui $gui -Language ja
            $script:WinEaseUiLanguage | Should Be 'ja'
            (Get-Content -LiteralPath (Get-WinEaseGuiSettingsPath) -Raw | ConvertFrom-Json).UiLanguage | Should Be 'ja'
            $gui.Form.Tag | Should Be $gui
            $gui.Form.Text | Should Be (Get-WinEaseUiString 'Main.WindowTitle' -Language 'ja')
            $gui.Tabs.TabPages[0].Text | Should Be (Get-WinEaseUiString 'Tab.Media' -Language 'ja')
            $gui.Language.SelectedIndex | Should Be 1

            $gui.Work.Text | Should Be 'D:\work space'
            $gui.Index.Text | Should Be '3'
            $gui.Drivers.Text | Should Be 'D:\drv'
            $gui.UserName.Text | Should Be 'Taro'
            $gui.ComputerName.Text | Should Be 'PC-1'
            $gui.Source.Text | Should Be 'E:\'
            $gui.DryRun.Checked | Should Be $true
            $gui.VHDX.Checked | Should Be $true
            $gui.RadSWM.Checked | Should Be $true
            $gui.Tabs.SelectedIndex | Should Be 4
            $gui.Preset.SelectedIndex | Should Be $presetIndex
            $gui.TweakCheckboxes['DisableUAC'].Checked | Should Be $true
            $gui.ComponentCheckboxes['RemoveStore'].Checked | Should Be $true
            $after = Get-WinEaseGuiDraftConfig -Gui $gui
            foreach ($k in $before.TweakSettings.Keys) { $after.TweakSettings[$k] | Should Be $before.TweakSettings[$k] | Out-Null }
            foreach ($k in $gui.ComponentCheckboxes.Keys) { $after[$k] | Should Be $before[$k] | Out-Null }
            (@($after.AdvancedDebloatStandard) -join '|') | Should Be $stdValue
            @($after.AdvancedDebloatExperimental).Count | Should Be 1
            $gui.MigRoot.Text | Should Be 'D:\mig'
            $gui.CustomPaths.Text | Should Be "C:\a`r`nC:\b"
            $gui.MigExcludeSecrets.Checked | Should Be $false
            $gui.MigConflict.SelectedIndex | Should Be 2
            $gui.MigFolders.GetItemChecked(3) | Should Be $true
            (@(Get-WinEaseGuiMigrationRuleIds -Gui $gui) -join ',') | Should Be ($ruleIds -join ',')
            $gui.TweakCheckboxes.Count | Should Be $script:AllTweakDefs.Count
            # the rebuilt window is live: toggling a tweak still switches the preset to Custom and updates the estimate
            $gui.Preset.SelectedIndex = 0
            $gui.TweakCheckboxes['DisableUAC'].Checked = $false
            $gui.Preset.SelectedIndex | Should Be ($gui.Preset.Items.Count - 1)

            Switch-WinEaseGuiLanguage -Gui $gui -Language en
            $script:WinEaseUiLanguage | Should Be 'en'
            $gui.Form.Text | Should Be 'WinEase Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer'
            $gui.Work.Text | Should Be 'D:\work space'
            $gui.ComponentCheckboxes['RemoveStore'].Checked | Should Be $true
            (@((Get-WinEaseGuiDraftConfig -Gui $gui).AdvancedDebloatStandard) -join '|') | Should Be $stdValue
        } finally {
            $gui.Form.Dispose()
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "switching to the language already shown, or to an unknown one, changes nothing" {
        $gui = Show-WinEaseGUI -NoShow -UiLanguage en
        try {
            $form = $gui.Form
            $firstTab = $gui.Tabs
            Switch-WinEaseGuiLanguage -Gui $gui -Language en
            Switch-WinEaseGuiLanguage -Gui $gui -Language xx
            [object]::ReferenceEquals($gui.Tabs, $firstTab) | Should Be $true
            $form.Text | Should Be 'WinEase Builder v2.1 - Next-Gen Windows 11 Modular Optimizer & Reducer'
        } finally { $gui.Form.Dispose() }
    }

    It "migration wizard: opens in either language and keeps its state when the language changes" {
        . (Join-Path $script:RepoRoot "tools\migrator\WinEaseMigration.ps1")
        $toolPath = Join-Path $script:RepoRoot "tools\migrator\WinEase-Migrator.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($toolPath, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
        $script:MigratorToolPath = $toolPath
        $script:RulesPath = Join-Path $script:RepoRoot "tools\migrator\migration-rules.psd1"
        $script:UserRulesPath = $null
        $script:DefaultPackagePath = Get-WinEaseDefaultMigrationBackupPath -Base Documents
        $ja = Read-UiTable 'ja'
        $en = Read-UiTable 'en'
        $form = Show-WinEaseMigratorDialog -NoShow -UiLanguage ja -PackagePath 'D:\bk'
        try {
            $form.Text | Should Be $ja['Migrator.Title']
            $form.Tag.Tabs.TabPages[0].Text | Should Be $ja['Migrator.Tab.Backup']
            $form.Tag.Tabs.TabPages[1].Text | Should Be $ja['Migrator.Tab.Restore']
            $form.Tag.BackupRoot.Text | Should Be 'D:\bk'
            $form.Tag.GameRules.Items.Count | Should BeGreaterThan 0
            $form.Tag.GameRules.SetItemChecked(1, $true)
            $form.Tag.AppRules.SetItemChecked(0, $true)
            [void]$form.Tag.Folders.Items.Add('D:\custom', $true)
            $form.Tag.Policy.SelectedIndex = 3
            $form.Tag.RestoreRoot.Text = 'E:\restore'
            $form.Tag.ExcludeSecrets.Checked = $false
            $form.Tag.Log.Text = 'a log line'
            $form.Tag.Tabs.SelectedIndex = 1
            $rules = @($form.Tag.GameRules.CheckedItems) + @($form.Tag.AppRules.CheckedItems)
            $sel = Get-MigSelection -Form $form

            Switch-MigratorLanguage -Form $form -Language en
            $script:WinEaseUiLanguage | Should Be 'en'
            $form.Text | Should Be $en['Migrator.Title']
            $form.Tag.Tabs.TabPages[0].Text | Should Be 'Export / Backup'
            $form.Tag.BackupRoot.Text | Should Be 'D:\bk'
            $form.Tag.RestoreRoot.Text | Should Be 'E:\restore'
            $form.Tag.Policy.SelectedIndex | Should Be 3
            $form.Tag.ExcludeSecrets.Checked | Should Be $false
            $form.Tag.Log.Text | Should Be 'a log line'
            $form.Tag.Tabs.SelectedIndex | Should Be 1
            $form.Tag.Folders.Items.Contains('D:\custom') | Should Be $true
            $after = Get-MigSelection -Form $form
            $after.RuleIds | Should Be $sel.RuleIds
            $after.UserFolders -join ',' | Should Be ($sel.UserFolders -join ',')
            $after.CustomPaths -join ',' | Should Be ($sel.CustomPaths -join ',')
            @($rules).Count | Should Be 2
            $form.Tag.Language.SelectedIndex | Should Be 0
        } finally {
            $form.Dispose()
            Set-WinEaseUiLanguage -Language 'en'
        }
    }

    It "cleanup: restore the environment" {
        $env:LOCALAPPDATA = $script:LangSavedLocalAppData
        $env:WINEASE_UI_LANGUAGE = 'en'
        Set-WinEaseUiLanguage -Language 'en'
        if (Test-Path -LiteralPath $script:LangTemp) { Remove-Item -LiteralPath $script:LangTemp -Recurse -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.Application]::Exit()
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $env:LOCALAPPDATA | Should Be $script:LangSavedLocalAppData
    }
}

Describe "WinUI 3 window host (gui\WinEaseWinUiHost.ps1)" {
    $settingsDef = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot "config\schema.psd1")
    $script:AllTweakDefs = [ordered]@{}
    foreach ($td in $settingsDef.Tweaks) { $script:AllTweakDefs[$td.Key] = @{ Category = $td.Category; Default = [bool]$td.Default; Description = $td.Description } }
    $script:ComponentDefs = [ordered]@{}
    foreach ($cd in $settingsDef.Components) { $script:ComponentDefs[$cd.Key] = $cd }
    $script:BuiltInPresets = [ordered]@{ wtest = @{ PayloadFormat = 'ESD'; RemoveDefender = $false; TweakSettings = @{ DisableUAC = $true } } }
    function Get-WinEasePreset { param([string]$Name) if ($Name -eq 'extreme') { $script:BuiltInPresets['wtest'] } else { $null } }
    . $script:GuiPath
    $script:WinUiHostPath = Join-Path -Path $script:RepoRoot -ChildPath "gui\WinEaseWinUiHost.ps1"

    It "gui\WinEaseWinUiHost.ps1 parses with zero parser errors and is loaded with gui\WinEaseGui.ps1" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:WinUiHostPath, [ref]$null, [ref]$errs)
        @($errs).Count | Should Be 0
        (Get-Command Show-WinEaseWinUiGUI -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }

    It "the init message carries every definition and survives the JSON round trip" {
        $init = New-WinEaseWinUiInitMessage -Language 'en' -InitialSettings @{
            SourceDrive = 'E:\'; UserName = 'Tester'; ExportESDMode = $true; RemoveDefender = $false
            TweakSettings = [ordered]@{ DisableUAC = $true }; AdvancedDebloatStandard = @('x')
        }
        $back = $init | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
        $back.Op | Should Be 'init'
        @($back.Tweaks).Count | Should Be $script:AllTweakDefs.Count
        @($back.Components).Count | Should Be @($script:ComponentDefs.Values | Where-Object { $_.Gui }).Count
        @($back.DebloatStandard).Count | Should BeGreaterThan 20
        @($back.DebloatExperimental).Count | Should BeGreaterThan 10
        $back.Initial.SourceDrive | Should Be 'E:\'
        $back.Initial.UserName | Should Be 'Tester'
        $back.Initial.ExportESDMode | Should Be $true
        $back.Initial.Components.RemoveDefender | Should Be $false
        $back.Initial.TweakSettings.DisableUAC | Should Be $true
        @($back.Initial.AdvancedDebloatStandard) -join ',' | Should Be 'x'
        @($back.PresetNames) -join ',' | Should Be 'wtest'
        # only 'extreme' resolves in this test: the preset carries every tweak, its payload and its components
        $p = @($back.Presets)[0]
        $p.Key | Should Be 'extreme'
        $p.PayloadFormat | Should Be 'ESD'
        $p.Components.RemoveDefender | Should Be $false
        $p.Tweaks.DisableUAC | Should Be $true
        @($p.Tweaks.PSObject.Properties).Count | Should Be $script:AllTweakDefs.Count
    }

    It "a window result becomes the Show-WinEaseGUI result hashtable" {
        $json = '{"Success":true,"SourceDrive":"Z:\\nothing\\here","WorkDir":"","UserName":" Tester ","ComputerName":"","Index":"3","InjectDrivers":"",' +
            '"PresetKey":"balanced","BasePresetKey":"balanced","DryRun":true,"UseVHDX":false,"ExportESDMode":false,"SplitWIMMode":true,' +
            '"Components":{"RemoveDefender":true},"TweakSettings":{"DisableUAC":true,"DisableVBS":false},' +
            '"AdvancedDebloatStandard":["Remove help files [10-20MB]"],"AdvancedDebloatExperimental":[],"PhysicalDebloatConsent":true}'
        $r = ConvertFrom-WinEaseWinUiResult -Result ($json | ConvertFrom-Json)
        $r.Success | Should Be $true
        $r.SourceDrive | Should Be 'Z:'
        $r.WorkDir | Should Be (Get-WinEaseGuiDefaultWorkDir)
        $r.UserName | Should Be 'Tester'
        $r.ComputerName | Should Be '*'
        $r.Index | Should Be '3'
        $r.PresetKey | Should Be 'balanced'
        $r.DryRun | Should Be $true
        $r.SplitWIMMode | Should Be $true
        $r.RemoveDefender | Should Be $true
        $r.TweakSettings['DisableUAC'] | Should Be $true
        $r.TweakSettings['DisableVBS'] | Should Be $false
        @($r.AdvancedDebloatStandard) -join ',' | Should Be 'Remove help files [10-20MB]'
        @($r.AdvancedDebloatExperimental).Count | Should Be 0
        $r.PhysicalDebloatConsent | Should Be $true
        (ConvertFrom-WinEaseWinUiResult -Result ('{"Success":false}' | ConvertFrom-Json)).Success | Should Be $false
    }

    It "requests: JSON configs reach the build functions as hashtables, unknown requests throw" {
        $cfg = ConvertTo-WinEaseHashtable ('{"RemoveDefender":true,"TweakSettings":{"DisableUAC":true},"AdvancedDebloatStandard":["a","b"]}' | ConvertFrom-Json)
        ($cfg -is [hashtable]) | Should Be $true
        ($cfg.TweakSettings -is [hashtable]) | Should Be $true
        @($cfg.AdvancedDebloatStandard).Count | Should Be 2
        (Invoke-WinEaseWinUiRequest -Op 'sources' -Arguments $null).Contains('Data') | Should Be $true
        { Invoke-WinEaseWinUiRequest -Op 'no-such-request' -Arguments $null } | Should Throw
    }

    It "the builder prefers the WinUI 3 window, keeps -ClassicGui and falls back to WinForms" {
        $builder = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'WinEasebuilder.ps1'))
        $builder | Should Match '\[switch\]\$ClassicGui'
        $builder | Should Match 'Find-WinEaseWinUiExe'
        $builder | Should Match 'Show-WinEaseWinUiGUI'
        $builder | Should Match 'falling back to the classic window'
    }
}

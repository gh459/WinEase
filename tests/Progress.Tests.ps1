. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

# D1: builder -> window progress protocol (docs\PROGRESS_PROTOCOL.md)
Describe "D1 - progress protocol (state, failure, verification)" {
    BeforeAll {
        . $script:GuiSessionPath
        . (Join-Path -Path $script:RepoRoot -ChildPath 'gui\WinEaseWinUiHost.ps1')
    }
    BeforeEach {
        $script:Sw = New-Object System.IO.StringWriter
        $script:WinEaseGuiProgressChannel = @{ Writer = $script:Sw }
    }
    AfterEach { $script:WinEaseGuiProgressChannel = $null }

    function Get-SentEvents { @($script:Sw.ToString() -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }

    It "emits one valid JSON line for every state, and rejects an unknown state" {
        foreach ($st in 'Preparing', 'Running', 'Verifying', 'Succeeded', 'NotVerified', 'Failed', 'Cancelling', 'Cancelled') {
            Send-WinEaseGuiState -State $st
        }
        $ev = Get-SentEvents
        $ev.Count | Should Be 8
        foreach ($e in $ev) { $e.op | Should Be 'progress'; $e.event | Should Be 'state' }
        (($ev | ForEach-Object { $_.State }) -join ',') | Should Be 'Preparing,Running,Verifying,Succeeded,NotVerified,Failed,Cancelling,Cancelled'
        { New-WinEaseProgressStateData -State 'Bogus' } | Should Throw
    }

    It "failure event carries phase, message key, summary and paths, and no secret" {
        $secret = 'Pl4ntedS3cret-xyz'
        $err = $null
        try { throw "Could not set UserPassword=$secret for account; token: abc123tokenvalue" } catch { $err = $_ }
        $data = New-WinEaseFailureData -ErrorRecord $err -FailedPhase 'Phase 15: Verify' -FailedPhaseNumber 15 `
            -LogPath 'C:\l\a.log' -ReportPath 'C:\l\r.txt' -OutputPath 'C:\o\WinEase.iso' -DiagnosticsPath 'C:\d' -DocsPath 'C:\docs\KNOWN_ISSUES.md' -Secrets @($secret)
        Send-WinEaseGuiProgress -Event failure -Data $data
        $raw = $script:Sw.ToString()
        $raw.Contains($secret) | Should Be $false
        $raw.Contains('abc123tokenvalue') | Should Be $false
        $e = Get-SentEvents | Select-Object -First 1
        $e.event | Should Be 'failure'
        $e.State | Should Be 'Failed'
        $e.FailedPhase | Should Be 'Phase 15: Verify'
        $e.MessageKey | Should Be 'Progress.Failure.Verification'
        $e.LogPath | Should Be 'C:\l\a.log'
        $e.ReportPath | Should Be 'C:\l\r.txt'
        $e.OutputPath | Should Be 'C:\o\WinEase.iso'
        $e.Summary | Should Match 'RuntimeException'
    }

    It "masks the configured account password even without an explicit secret list" {
        $script:UserPassword = 'Cfg-P4ss-w0rd!'
        try {
            (Hide-WinEaseSecretText -Text 'dism failed near Cfg-P4ss-w0rd! in file').Contains('Cfg-P4ss-w0rd!') | Should Be $false
        } finally { $script:UserPassword = $null }
    }

    It "masks every known secret, including two of the same length" {
        $t = Hide-WinEaseSecretText -Text 'first=alpha1 second=bravo2' -Secrets @('alpha1', 'bravo2')
        $t.Contains('alpha1') | Should Be $false
        $t.Contains('bravo2') | Should Be $false
    }

    It "masks unattend password elements, command line parameters and bearer tokens" {
        $t = Hide-WinEaseSecretText -Text '<Password><Value>hunter2x</Value><PlainText>true</PlainText></Password> -UserPassword zzTop99 UserPassword=NoHyphen99 AdministratorPassword: Adm1nPw Authorization: Bearer abcDEF123.xyz'
        $t.Contains('hunter2x') | Should Be $false
        $t.Contains('zzTop99') | Should Be $false
        $t.Contains('NoHyphen99') | Should Be $false
        $t.Contains('Adm1nPw') | Should Be $false
        $t.Contains('abcDEF123') | Should Be $false
        $t.Contains('UserPassword=') | Should Be $true
    }

    It "log lines are masked, single line and bounded" {
        Send-WinEaseGuiLogLine -Text ("password=Sup3rS3cret`nline2 " + ('x' * 1000))
        $e = Get-SentEvents | Select-Object -First 1
        $e.event | Should Be 'log'
        $e.Text.Contains('Sup3rS3cret') | Should Be $false
        ($e.Text -match "[\r\n]") | Should Be $false
        $e.Text.Length | Should BeLessThan 600
    }

    It "unknown or not-run verification is never Succeeded" {
        Get-WinEaseVerificationState -PayloadVerified $null -IsoVerified $null | Should Be 'NotVerified'
        Get-WinEaseVerificationState -PayloadVerified $true -IsoVerified $false | Should Be 'NotVerified'
        Get-WinEaseVerificationState -PayloadVerified $false -IsoVerified $true | Should Be 'NotVerified'
        Get-WinEaseVerificationState -PayloadVerified 'true' -IsoVerified 'true' | Should Be 'NotVerified'
        Get-WinEaseVerificationState -PayloadVerified $true -IsoVerified $true | Should Be 'Verified'
        $d = New-WinEaseDoneData -BuildSucceeded $true -PayloadVerified $true -IsoVerified $null
        $d.Verification | Should Be 'NotVerified'
        $d.State | Should Be 'NotVerified'
        (New-WinEaseDoneData -BuildSucceeded $true).State | Should Not Be 'Succeeded'
        (New-WinEaseDoneData -BuildSucceeded $true -PayloadVerified $true -IsoVerified $true).State | Should Be 'Succeeded'
        (New-WinEaseDoneData -BuildSucceeded $false -PayloadVerified $true -IsoVerified $true).State | Should Be 'Failed'
    }

    It "done event carries the verification result and keeps the old Success and Message fields" {
        $data = New-WinEaseDoneData -BuildSucceeded $true -PayloadVerified $true -IsoVerified $true -OutputPath 'C:\o\WinEase.iso'
        $script:WinEaseGuiProgressChannel = @{ Writer = $script:Sw; Proc = $null }
        Close-WinEaseGuiProgress -Success $true -Message 'WinEase.iso is ready.' -Extra $data
        $e = Get-SentEvents | Select-Object -First 1
        $e.event | Should Be 'done'
        $e.Success | Should Be $true
        $e.Message | Should Be 'WinEase.iso is ready.'
        $e.Verification | Should Be 'Verified'
        $e.State | Should Be 'Succeeded'
    }

    It "old-style events (phase, log, done without new fields) still parse" {
        Send-WinEaseGuiProgress -Event phase -Data @{ Phase = 2; Total = 18; Name = 'Mount' }
        Send-WinEaseGuiProgress -Event log -Data @{ Text = 'a' }
        Send-WinEaseGuiProgress -Event done -Data @{ Success = $true; Message = 'x' }
        $ev = Get-SentEvents
        $ev.Count | Should Be 3
        $ev[2].Success | Should Be $true
        $ev[2].PSObject.Properties['Verification'] | Should BeNullOrEmpty
    }

    It "failure message keys map to the expected ui-strings keys" {
        Get-WinEaseFailureMessageKey -PhaseNumber 0 | Should Be 'Progress.Failure.Generic'
        Get-WinEaseFailureMessageKey -PhaseNumber 2 | Should Be 'Progress.Failure.Source'
        Get-WinEaseFailureMessageKey -PhaseNumber 15 | Should Be 'Progress.Failure.Verification'
        Get-WinEaseFailureMessageKey -PhaseNumber 18 | Should Be 'Progress.Failure.Iso'
        Get-WinEaseFailureMessageKey -PhaseNumber 9 | Should Be 'Progress.Failure.Generic'
    }
}

Describe "D1 - window and builder wiring (static checks)" {
    $script:CsPath = Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'
    $script:Cs = [System.IO.File]::ReadAllText($script:CsPath)
    $script:Builder = [System.IO.File]::ReadAllText($script:BuilderPath)

    It "the window handles every event type" {
        foreach ($ev in 'state', 'phase', 'log', 'failure', 'done') {
            $script:Cs | Should Match ('case "' + $ev + '":')
        }
    }
    It "every new Progress string key exists in en and ja and is used by the window" {
        $en = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\ui-strings\en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $ja = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\ui-strings\ja.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $keys = @([regex]::Matches($script:Cs, '_s\.(?:Get|Format)\("(Progress\.[A-Za-z.]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $keys.Count | Should BeGreaterThan 40
        $missing = @($keys | Where-Object { -not $en.PSObject.Properties[$_] -or -not $ja.PSObject.Properties[$_] })
        ($missing -join ',') | Should Be ''
        foreach ($k in 'Progress.Failure.Generic', 'Progress.Failure.Source', 'Progress.Failure.Verification', 'Progress.Failure.Iso',
                       'Progress.Button.OpenLog', 'Progress.Button.OpenReport', 'Progress.Button.OpenOutput') {
            $keys -contains $k | Should Be $true
        }
    }
    It "message keys sent by the builder are keys of the window" {
        $lib = [System.IO.File]::ReadAllText($script:GuiSessionPath)
        foreach ($m in [regex]::Matches($lib, "'(Progress\.Failure\.[A-Za-z]+)'")) {
            $script:Cs.Contains('"' + $m.Groups[1].Value + '"') | Should Be $true
        }
    }
    It "every progress control has an automation name and the open buttons use the shell without a command line" {
        $script:Cs | Should Match 'AutomationProperties\.SetHelpText\(b, '
        $script:Cs | Should Match 'AutomationProperties\.SetName\(b, '
        $script:Cs | Should Match 'AutomationProperties\.SetName\(closeButton'
        $script:Cs | Should Match 'AutomationProperties\.SetName\(logView'
        $script:Cs | Should Match 'AutomationProperties\.SetName\(bar, '
        $script:Cs | Should Match 'UseShellExecute = true'
        $script:Cs | Should Not Match 'Arguments\s*='
    }
    It "the output folder is known before the ISO exists, so an early failure can still open it" {
        $script:Builder | Should Match '(?s)BuildOutputIsoPath = if \(\$OutputIsoName\)'
        $script:Cs | Should Match 'System\.IO\.Path\.GetDirectoryName\(path\)'
        $script:Cs | Should Match 'System\.IO\.Directory\.Exists\(folder\)'
    }
    It "the log pane is bounded" {
        $script:Cs | Should Match 'MaxLogLines'
        $script:Cs | Should Match 'RemoveAt\(0\)'
    }
    It "a builder that ends without done is shown as a failure, not as success" {
        $script:Cs | Should Match '(?s)if \(!finished\).*?failed = true'
        $script:Cs | Should Match 'Progress\.Ended'
    }
    It "the phase loop records the failure (masked) and rethrows" {
        $script:Builder | Should Match '(?s)catch \{[^}]*Register-WinEaseBuildFailure -ErrorRecord \$_\s+throw'
        $script:Builder | Should Match 'build_errors\.log'
        $script:Builder | Should Match 'Hide-WinEaseSecretText'
        $script:Builder | Should Match 'New-WinEaseDoneData[^\r\n]*-PayloadVerified \$script:FinalPayloadVerified -IsoVerified \$script:IsoPayloadVerified'
    }
}

# D2: safe cancellation (docs\PROGRESS_PROTOCOL.md, docs\KNOWN_ISSUES.md "Cancelling and interrupted builds")
Describe "D2 - cancel request, phase boundary and result" {
    BeforeAll {
        . $script:GuiSessionPath
        . (Join-Path -Path $script:RepoRoot -ChildPath 'gui\WinEaseWinUiHost.ps1')
        $script:D2Dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wineased2_" + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:D2Dir -Force)
    }
    AfterAll { if ($script:D2Dir -and (Test-Path -LiteralPath $script:D2Dir)) { Remove-Item -LiteralPath $script:D2Dir -Recurse -Force -ErrorAction SilentlyContinue } }
    BeforeEach {
        $script:Sw = New-Object System.IO.StringWriter
        $script:WinEaseGuiProgressChannel = @{ Writer = $script:Sw }
        $script:WinEaseCancelRequestPath = $null
    }
    AfterEach { $script:WinEaseGuiProgressChannel = $null; $script:WinEaseCancelRequestPath = $null }

    function Get-D2Events { @($script:Sw.ToString() -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }

    It "the cancel check is true only when a request exists" {
        Test-WinEaseCancelRequested | Should Be $false                      # no channel registered
        $dir = Join-Path $script:D2Dir 'check'
        [void](New-Item -ItemType Directory -Path $dir -Force)
        $script:WinEaseCancelRequestPath = Get-WinEaseCancelRequestPath -DiagnosticsDir $dir
        Test-WinEaseCancelRequested | Should Be $false                      # registered, nothing requested
        New-Item -ItemType Directory -Path $script:WinEaseCancelRequestPath -Force | Out-Null
        Test-WinEaseCancelRequested | Should Be $false                      # a folder of that name is not a request
        Remove-Item -LiteralPath $script:WinEaseCancelRequestPath -Force
        Set-Content -LiteralPath $script:WinEaseCancelRequestPath -Value 'x'
        Test-WinEaseCancelRequested | Should Be $true
    }

    It "registering the channel sends one valid hello event that advertises cancel; without a window nothing is sent or armed" {
        $dir = Join-Path $script:D2Dir 'hello'
        Register-WinEaseCancelChannel -DiagnosticsDir $dir
        $ev = @(Get-D2Events)
        $ev.Count | Should Be 1
        $ev[0].op | Should Be 'progress'
        $ev[0].event | Should Be 'hello'
        $ev[0].Capabilities.Cancel | Should Be $true
        $ev[0].CancelRequestPath | Should Be (Join-Path $dir 'cancel.request')

        $script:WinEaseGuiProgressChannel = $null
        $script:WinEaseCancelRequestPath = $null
        Register-WinEaseCancelChannel -DiagnosticsDir $dir
        $script:WinEaseCancelRequestPath | Should BeNullOrEmpty
        (New-WinEaseHelloData).Capabilities.Cancel | Should Be $false
    }

    It "cancel states and done event are valid JSON; Cancelled is never a success" {
        Send-WinEaseGuiState -State 'Cancelling'
        Send-WinEaseGuiState -State 'Cancelled'
        $ok = New-WinEaseDoneData -BuildSucceeded $false -Cancelled $true -CleanupProblems @()
        $ok.State | Should Be 'Cancelled'
        $ok.CleanupOk | Should Be $true
        $ok.Cancelled | Should Be $true
        Close-WinEaseGuiProgress -Success $false -Message 'x' -Extra $ok
        $ev = @(Get-D2Events)
        (($ev | Where-Object { $_.event -eq 'state' } | ForEach-Object { $_.State }) -join ',') | Should Be 'Cancelling,Cancelled'
        $done = $ev | Where-Object { $_.event -eq 'done' } | Select-Object -First 1
        $done.Success | Should Be $false
        $done.State | Should Be 'Cancelled'
        $done.CleanupOk | Should Be $true
    }

    It "a failed cleanup is Failed, not Cancelled, and carries the details without secrets" {
        Get-WinEaseFinalProgressState -BuildSucceeded $false -Cancelled $true -CleanupProblems @() | Should Be 'Cancelled'
        Get-WinEaseFinalProgressState -BuildSucceeded $false -Cancelled $true -CleanupProblems @('DISM mount still present: C:\m') | Should Be 'Failed'
        $problems = Get-WinEaseCancelCleanupProblems -LoadedHives @('zSOFTWARE') -LingeringMounts @('C:\w\mount token=abc123secret') -VhdxStillAttached $true -IsoStillMounted $true
        $problems.Count | Should Be 4
        (Get-WinEaseCancelCleanupProblems).Count | Should Be 0
        $bad = New-WinEaseDoneData -BuildSucceeded $false -Cancelled $true -CleanupProblems $problems
        $bad.State | Should Be 'Failed'
        $bad.CleanupOk | Should Be $false
        $bad.MessageKey | Should Be 'Progress.Cancel.CleanupFailed'
        $bad.Summary | Should Match 'zSOFTWARE'
        ($bad | ConvertTo-Json -Depth 4 -Compress).Contains('abc123secret') | Should Be $false
    }

    It "the real phase loop stops at the boundary after a request, starts no further phase, and cleanup runs exactly once" {
        # The loop is taken from the builder source itself, so this tests the shipped code with mocked phases
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$tokens, [ref]$errs)
        $loop = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'buildPhase' }, $true)
        $loop | Should Not BeNullOrEmpty
        $loopBlock = [scriptblock]::Create($loop.Extent.Text)

        $dir = Join-Path $script:D2Dir 'loop'
        [void](New-Item -ItemType Directory -Path $dir -Force)
        $reqFile = Get-WinEaseCancelRequestPath -DiagnosticsDir $dir
        $script:WinEaseCancelRequestPath = $reqFile
        $global:D2Ran = @(); $global:D2Entered = @(); $global:D2Registered = 0; $global:D2Cleanup = 0
        Set-Content -LiteralPath (Join-Path $dir '01-a.ps1') -Value '$global:D2Ran += 1'
        Set-Content -LiteralPath (Join-Path $dir '02-b.ps1') -Value ('$global:D2Ran += 2; Set-Content -LiteralPath "' + $reqFile + '" -Value x')
        Set-Content -LiteralPath (Join-Path $dir '03-c.ps1') -Value '$global:D2Ran += 3'
        $buildPhases = @(
            @{ Number = 1; Name = 'A'; File = '01-a.ps1' }
            @{ Number = 2; Name = 'B'; File = '02-b.ps1' }
            @{ Number = 3; Name = 'C'; File = '03-c.ps1' }
        )
        $phasesDir = $dir
        function Enter-Phase { param($n, $name) $global:D2Entered += $n }
        function Register-WinEaseBuildFailure { param($ErrorRecord) $global:D2Registered++ }

        $cancelled = $false
        try {
            try { . $loopBlock }
            catch { if (Test-WinEaseCancelException -ErrorRecord $_) { $cancelled = $true } else { throw } }
        } finally { $global:D2Cleanup++ }

        $cancelled | Should Be $true
        ($global:D2Ran -join ',') | Should Be '1,2'            # phase 2 ran to its end, phase 3 never started
        ($global:D2Entered -join ',') | Should Be '1,2'
        $global:D2Registered | Should Be 0                      # a cancel is not a failure
        $global:D2Cleanup | Should Be 1

        # No request: every phase runs
        Remove-Item -LiteralPath $reqFile -Force
        Set-Content -LiteralPath (Join-Path $dir '02-b.ps1') -Value '$global:D2Ran += 2'
        $global:D2Ran = @()
        . $loopBlock
        ($global:D2Ran -join ',') | Should Be '1,2,3'
    }

    It "another OperationCanceledException from a phase is an ordinary failure, not a cancel" {
        $plain = New-Object System.OperationCanceledException('phase cancelled itself')
        Test-WinEaseCancelException -ErrorRecord $plain | Should Be $false
        Test-WinEaseCancelException -ErrorRecord (New-WinEaseCancelException) | Should Be $true
    }
}

Describe "D2 - window and builder wiring (static checks)" {
    BeforeAll {
        $script:Cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'))
        $script:Builder = [System.IO.File]::ReadAllText($script:BuilderPath)
    }
    It "the window handles the hello event and enables Cancel only when the builder advertises it" {
        $script:Cs | Should Match 'case "hello":'
        $script:Cs | Should Match 'm\["Capabilities"\] is JsonObject caps && InitData\.Bool\(caps\["Cancel"\]\)'
        $script:Cs | Should Match 'var cancelBuildButton = new Button \{[^}]*IsEnabled = false'
        $script:Cs | Should Match 'cancelBuildButton\.IsEnabled = _cancelSupported && !_cancelRequested && !finished'
        $script:Cs | Should Match 'Progress\.Cancel\.Unsupported'
        $script:Cs | Should Match 'ToolTipService\.SetToolTip\(cancelBuildButton'
    }
    It "clicking Cancel only waits: Cancelled is shown only from the builder's state/done event" {
        $script:Cs | Should Match 'Progress\.Cancel\.Waiting'
        $script:Cs | Should Match 'bool cancelledDone = finished && state == "Cancelled"'
        # the request path never sets the state to Cancelled/Cancelling itself
        $script:Cs | Should Not Match 'state = "Cancell'
    }
    It "closing the window during a build asks: Cancel build / Keep running in console / Stay" {
        $script:Cs | Should Match '(?s)if \(!_progressActive \|\| _buildFinished \|\| _allowClose\) return;\s+args\.Cancel = true;'
        foreach ($k in 'Progress.Close.CancelBuild', 'Progress.Close.KeepRunning', 'Progress.Close.Stay') { $script:Cs.Contains('"' + $k + '"') | Should Be $true }
        $script:Cs | Should Match 'DefaultButton = ContentDialogButton\.Close'
    }
    It "every cancel and close string exists in en and ja" {
        $en = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\ui-strings\en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $ja = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\ui-strings\ja.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $keys = @([regex]::Matches($script:Cs, '"(Progress\.(?:Cancel|Close)\.[A-Za-z.]+|Progress\.Button\.Cancel|Progress\.Help\.Cancel)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $keys.Count | Should BeGreaterThan 10
        foreach ($k in $keys) {
            $en.PSObject.Properties[$k] | Should Not BeNullOrEmpty
            $ja.PSObject.Properties[$k] | Should Not BeNullOrEmpty
            [string]$ja.$k | Should Not Be ([string]$en.$k)
        }
    }
    It "the builder checks for a cancel only between phases, reuses the finally cleanup and exits with a distinct code" {
        $script:Builder | Should Match '(?s)foreach \(\$buildPhase in \$buildPhases\) \{.{0,400}?if \(Test-WinEaseCancelRequested\) \{ throw \(New-WinEaseCancelException\) \}\s+\$phaseFile'
        $script:Builder | Should Match 'Register-WinEaseCancelChannel -DiagnosticsDir \$script:DiagDir'
        $script:Builder | Should Match 'exit \$script:WinEaseCancelExitCode'
        # the cancel branch of the catch block does not delete anything itself
        $m = [regex]::Match($script:Builder, '(?s)if \(Test-WinEaseCancelException -ErrorRecord \$_\) \{(.*?)\r?\n  \} else \{')
        $m.Success | Should Be $true
        $m.Groups[1].Value | Should Not Match 'Remove-Item|Remove-WinEaseTreeRobust|Delete\('
        # the done event carries the cancel result
        $script:Builder | Should Match '-Cancelled \(\[bool\]\$script:BuildCancelled\) -CleanupProblems'
    }
}

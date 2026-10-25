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

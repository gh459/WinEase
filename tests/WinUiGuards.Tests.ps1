# WinUiGuards.Tests.ps1 - WinUI window: double start, failed result send, progress listener, error replies (audit PR-G)
# Run with:  Invoke-Pester -Path .\tests\WinUiGuards.Tests.ps1
# Requires:  Pester 3.4 on Windows PowerShell 5.1
#
# Source checks only: the window needs the Windows App SDK to build, which CI does in its own job.

. (Join-Path -Path $PSScriptRoot -ChildPath '_TestCommon.ps1')

Describe "WinUI main window guards" {
    BeforeAll {
        $script:Cs = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'gui\winui\WinEaseGui\MainWindow.xaml.cs'), [System.Text.Encoding]::UTF8)
    }
    It "Start is guarded against a second click while the confirmations run" {
        $script:Cs | Should Match 'if \(_busy \|\| _starting \|\| _resultSent\) return;'
        $script:Cs | Should Match '(?s)_starting = true;\s+try\s+\{\s+await StartBuildFlowAsync\(\);.*?finally\s+\{\s+_starting = false;'
    }
    It "a failed result send gives the window back and tells the user" {
        $script:Cs | Should Match '(?s)await _bridge\.SendResultAsync\(_s\.Language, result\);\s+\}\s+catch \(Exception ex\)\s+\{.*?_resultSent = false;'
    }
    It "the progress listener survives a bad event and a broken pipe" {
        $script:Cs | Should Match 'void Safe\(\)'
        $script:Cs | Should Match '(?s)await _bridge\.ListenProgressAsync.*?catch \(Exception ex\)\s+\{[^}]*AddLogLine\(ex\.Message\)'
    }
    It "the done event no longer stores its message text as the diagnostics path" {
        $script:Cs | Should Not Match 'diagPath = InitData\.Str\(m\["Message"\]\)'
    }
    It "custom scripts and migration rules show an error reply instead of an empty list" {
        $script:Cs | Should Match 'requestedStage != _csStage'
        $script:Cs | Should Match '(?s)RequestAsync\("migrationRules".*?InitData\.Bool\(r\["ok"\]\)'
    }
    It "the preset diff dialog catches a failed request" {
        $script:Cs | Should Match '(?s)RequestAsync\("presetDiff".*?catch \(Exception ex\)'
    }
    It "accessibility settings retrieval handles exceptions with debug logging" {
        $script:Cs | Should Match '(?s)highContrast = new Windows\.UI\.ViewManagement\.AccessibilitySettings\(\)\.HighContrast;.*?catch \(Exception ex\)'
    }
}

# WinEaseGuiSession.ps1 - GUI session bridge shared by the builder, WinForms and WinUI.
# Dot-sourced by WinEasebuilder.ps1 before the -GUI trigger (function definitions only).

function Get-WinEaseGuiInitialSettings {
    $initialSettings = @{
        SourceDrive                  = $script:SourceDrive
        WorkDir                      = $script:WorkDir
        Index                        = $script:Index
        InjectDrivers                = $script:InjectDrivers
        UserName                     = $script:UserName
        UserPassword                 = $script:UserPassword
        ComputerName                 = $script:ComputerName
        PresetKey                    = $script:selectedProfile
        UseVHDX                      = $script:useVHDX
        ExportESDMode                = $script:exportESDMode
        SplitWIMMode                 = $script:splitWIMMode
        TweakSettings                = $script:TweakSettings
        AdvancedDebloatStandard      = $script:advancedDebloatStandard
        AdvancedDebloatExperimental  = $script:advancedDebloatExperimental
        DebloatEngineSelection       = $script:DebloatEngineSelection
    }
    # Services & Apps tab checkboxes
    foreach ($cd in $script:ComponentDefs.Values) {
        if ($cd.Gui) { $initialSettings[$cd.Key] = Get-WinEaseComponentValue -Def $cd }
    }
    return $initialSettings
}

function Show-WinEaseGuiSessionWindow {
    param(
        $InitialSettings
    )
    $guiLanguageArgs = @{}
    if ($UiLanguage) { $guiLanguageArgs["UiLanguage"] = $UiLanguage }
    # WinUI 3 window when gui\winui is built (and -ClassicGui is not set), else the WinForms window
    $guiResult = $null
    $winUiExe = if ($ClassicGui) { $null } else { Find-WinEaseWinUiExe }
    if ($winUiExe) {
        try {
            $guiResult = Show-WinEaseWinUiGUI -InitialSettings $InitialSettings -ExePath $winUiExe @guiLanguageArgs
        } catch {
            Write-Warning "WinUI 3 window failed ($($_.Exception.Message)); falling back to the classic window."
            $winUiExe = $null
        }
    }
    if (-not $winUiExe) { $guiResult = Show-WinEaseGUI -InitialSettings $InitialSettings @guiLanguageArgs }
    return $guiResult
}

function Confirm-WinEasePhysicalDebloatConsent {
    param(
        $GuiResult
    )
    # Explicit Physical Debloat Consent Gate
    # The GUI windows (WinUI 3 and the classic WinForms window) both ask for this consent
    # themselves, next to the selection, and report it back as PhysicalDebloatConsent. When
    # the consent was already granted there is nothing left to confirm here. This fallback
    # dialog only appears for a non-GUI run that set the advanced debloat lists directly
    # (e.g. a profile), where no GUI was involved.
    $advStdCount = @($script:advancedDebloatStandard).Count
    $advExpCount = @($script:advancedDebloatExperimental).Count
    $hasConsent = if ($GuiResult) { [bool]$GuiResult.PhysicalDebloatConsent } else { $false }
    if ((-not $script:allowPhysicalDebloat) -and (($advStdCount + $advExpCount) -gt 0) -and (-not $hasConsent)) {
        $consentMsg = "Advanced Debloat options selected: Standard=$advStdCount / Experimental=$advExpCount.`n`n" +
            "These operations physically delete files and directories from the offline image.`n" +
            "Experimental items permanently break Windows Update and sfc verification.`n`n" +
            "Enable physical debloat for this build?"
        $consent = [System.Windows.Forms.MessageBox]::Show(
            $consentMsg,
            "WinEase - Confirm Physical Debloat",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($consent -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:allowPhysicalDebloat = $true
            Write-Host "Physical debloat explicitly confirmed for this session." -ForegroundColor Yellow
        } else {
            $script:advancedDebloatStandard     = @()
            $script:advancedDebloatExperimental = @()
            Write-Warning "Physical debloat was not confirmed; Advanced Debloat selections were cleared for this build."
        }
    }
}

function Apply-WinEaseGuiResult {
    [CmdletBinding()]
    param(
        $GuiResult
    )
    # The GUI is not the trust boundary: the same input check the windows run (lib\WinEaseInputValidation.ps1) runs here
    # before any builder variable changes. UserName / ComputerName go into autounattend.xml verbatim.
    if (-not (Get-Command -Name Test-WinEaseGuiResultInputs -ErrorAction SilentlyContinue)) { throw 'Test-WinEaseGuiResultInputs is not loaded (lib\WinEaseInputValidation.ps1).' }
    $inputIssues = @(Test-WinEaseGuiResultInputs -Result $GuiResult -OutputDir $script:scriptDir -SkipWriteProbe:([bool]$GuiResult.DryRun))
    if (Test-WinEaseInputHasError -Issues $inputIssues) {
        Write-Warning (Get-WinEaseInputText 'Val.Refused' -Format (Format-WinEaseInputIssues -Issues @($inputIssues | Where-Object { $_.Severity -eq 'Error' })))
        return $false
    }
    # The plan the window showed in its final confirmation (null when the window did not create one); the builder logs it
    # and compares it with the resolved settings (Compare-WinEaseBuildPlanToSettings)
    $script:GuiBuildPlan = $GuiResult.BuildPlan
    # The WinUI 3 window asks for the physical debloat consent itself
    if ($GuiResult.PhysicalDebloatConsent) { $script:allowPhysicalDebloat = $true }

    if ($GuiResult.BasePresetKey) {
        $null = Apply-ProfileSettings -ProfileName $GuiResult.BasePresetKey
    }

    if ($GuiResult.SourceDrive) { $script:SourceDrive = $GuiResult.SourceDrive }
    if ($GuiResult.WorkDir)     { $script:WorkDir = $GuiResult.WorkDir }
    if ($GuiResult.UserName)     { $script:UserName = $GuiResult.UserName }
    if ($null -ne $GuiResult.UserPassword) { $script:UserPassword = $GuiResult.UserPassword }
    if ($GuiResult.ComputerName) { $script:ComputerName = $GuiResult.ComputerName }
    foreach ($cd in $script:ComponentDefs.Values) {
        if ($cd.Gui) { Set-Variable -Name $cd.Variable -Scope Script -Value ([bool]$GuiResult.($cd.Key)) }
    }
    $script:useVHDX                      = [bool]$GuiResult.UseVHDX
    $script:exportESDMode                = [bool]$GuiResult.ExportESDMode
    $script:splitWIMMode                 = [bool]$GuiResult.SplitWIMMode

    if ($GuiResult.TweakSettings) {
        foreach ($tk in $GuiResult.TweakSettings.Keys) {
            $script:TweakSettings[$tk] = [bool]$GuiResult.TweakSettings[$tk]
        }
    }
    # RadicalRAM, BypassActivationRestrictions, NoHypervisor, ... are tab toggles that phases read as variables
    Sync-WinEaseTweakVariables

    if ($GuiResult.AdvancedDebloatStandard)     { $script:advancedDebloatStandard     = @($GuiResult.AdvancedDebloatStandard) }     else { $script:advancedDebloatStandard     = @() }
    if ($GuiResult.AdvancedDebloatExperimental) { $script:advancedDebloatExperimental = @($GuiResult.AdvancedDebloatExperimental) } else { $script:advancedDebloatExperimental = @() }

    # Engine selection (PowerShell <-> Rust) per target. Entries for targets that are not
    # selected, or that the target does not support, are dropped.
    $script:DebloatEngineSelection = [ordered]@{}
    if ($GuiResult.DebloatEngineSelection) {
        $engineMap = @{}
        if ($GuiResult.DebloatEngineSelection -is [System.Collections.IDictionary]) {
            foreach ($k in $GuiResult.DebloatEngineSelection.Keys) { $engineMap[[string]$k] = [string]$GuiResult.DebloatEngineSelection[$k] }
        } else {
            foreach ($p in $GuiResult.DebloatEngineSelection.PSObject.Properties) { $engineMap[[string]$p.Name] = [string]$p.Value }
        }
        Set-WinEaseDebloatEngineSelection -Selection $engineMap
    }
    $rustCount = @($script:advancedDebloatStandard + $script:advancedDebloatExperimental |
        Where-Object { (Resolve-WinEaseDebloatEngine -Item ([string]$_)) -eq 'Rust' }).Count
    if ($rustCount -gt 0) {
        Write-Host "Debloat engine: $rustCount target(s) run on the Rust engine (forced physical deletion)." -ForegroundColor Yellow
    }

    Confirm-WinEasePhysicalDebloatConsent -GuiResult $GuiResult

    if ($GuiResult.Index)         { $script:Index = $GuiResult.Index }
    if ($GuiResult.InjectDrivers) { $script:InjectDrivers = $GuiResult.InjectDrivers }
    if ($GuiResult.DryRun) {
        $script:DryRun = $true
        $script:isDryRunMode = $true
    }
    # PresetKey 'custom' = the window was edited after the preset was chosen (Get-WinEaseGuiPresetState); the base preset stays in BasePresetKey
    $script:selectedProfile = if ("$($GuiResult.PresetKey)" -ieq 'custom') { if ($GuiResult.BasePresetKey) { "custom (based on $($GuiResult.BasePresetKey))" } else { "GUI Selection" } } elseif ($GuiResult.PresetKey) { $GuiResult.PresetKey } elseif ($GuiResult.BasePresetKey) { "custom (based on $($GuiResult.BasePresetKey))" } else { "GUI Selection" }
    Write-Host "Applied GUI Configuration successfully ($($script:selectedProfile))." -ForegroundColor Green
    return $true
}

function Invoke-WinEaseGuiSession {
    $initialSettings = Get-WinEaseGuiInitialSettings
    $guiResult = Show-WinEaseGuiSessionWindow -InitialSettings $initialSettings
    if (-not ($guiResult -and $guiResult.Success)) {
        # A result the PowerShell side refused (ConvertFrom-WinEaseWinUiResult) says why
        if ($guiResult -and $guiResult.Reason) { Write-Warning (Get-WinEaseInputText 'Val.Refused' -Format $guiResult.Reason) }
        return $false
    }

    return [bool](Apply-WinEaseGuiResult -GuiResult $guiResult)
}

# ==============================================================================
# Build progress protocol (builder -> window). Documented in docs/PROGRESS_PROTOCOL.md.
# Pure functions: they build the event data; gui\WinEaseWinUiHost.ps1 (Send-WinEaseGuiProgress)
# writes the JSON line. Every event is { op = 'progress'; event = <name>; ... }.
# ==============================================================================

# 'Cancelling' is reserved for the cancel feature (D2); 'NotVerified' is the final state of a build that
# produced output but whose final verification did not complete (never shown as success).
$script:WinEaseProgressStates = @('Preparing', 'Running', 'Verifying', 'Succeeded', 'NotVerified', 'Failed', 'Cancelling', 'Cancelled')

# Masks secrets in text that is sent to the window or written to a log: the known secret values (the
# configured account password is always included), unattend password elements, key=value / -Param value
# forms for password, token, secret and API key, and Bearer tokens.
function Hide-WinEaseSecretText {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string[]]$Secrets = @()
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $mask = '********'
    $known = @($Secrets)
    if ($script:UserPassword) { $known += [string]$script:UserPassword }
    $out = $Text
    # Longest first, so a secret that contains another one is masked completely. Do not use
    # Sort-Object -Unique here: it de-duplicates by the sort property (Length), which would drop
    # a different secret of the same length. Replacing the same value twice is harmless.
    foreach ($s in @($known | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Property Length -Descending)) {
        $out = $out.Replace($s, $mask)
    }
    $out = [regex]::Replace($out, '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+', "`${1}$mask")
    $out = [regex]::Replace($out, '(?is)(<(?:Administrator)?Password\b[^>]*>\s*<Value>)[^<]*(</Value>)', "`${1}$mask`${2}")
    $out = [regex]::Replace($out, '(?i)(-(?:UserPassword|Password|Token|ApiKey|Secret)(?:\s+|:))("[^"]*"|''[^'']*''|\S+)', "`${1}$mask")
    $out = [regex]::Replace($out, '(?i)((?<![A-Za-z0-9])(?:user_?password|administrator_?password|password|passwd|pwd|token|secret|api[_-]?key|authorization)\b["'']?\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s,;]+)', "`${1}$mask")
    return $out
}

# One short line without secrets for an exception: "TypeName: first line of the message".
function Get-WinEaseExceptionSummary {
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [string[]]$Secrets = @(),
        [int]$MaxLength = 300
    )
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $typeName = if ($ex) { $ex.GetType().Name } else { 'Error' }
    $msg = if ($ex -and $ex.Message) { [string]$ex.Message } else { "$ErrorRecord" }
    $first = (($msg -split "[\r\n]+") | Where-Object { $_.Trim() } | Select-Object -First 1)
    $text = Hide-WinEaseSecretText -Text "${typeName}: $first" -Secrets $Secrets
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + '...' }
    return $text
}

# 'Verified' only when both the deep apply of install.wim (phase 15) and the ISO payload hash check
# (phase 18) really passed. Anything else - false, null, not run - is 'NotVerified'.
function Get-WinEaseVerificationState {
    param($PayloadVerified = $null, $IsoVerified = $null)
    if (($PayloadVerified -is [bool]) -and $PayloadVerified -and ($IsoVerified -is [bool]) -and $IsoVerified) { return 'Verified' }
    return 'NotVerified'
}

# A finished build is 'Succeeded' only when it is verified; otherwise it is 'NotVerified' (or 'Failed').
function Get-WinEaseFinalProgressState {
    param([bool]$BuildSucceeded, [string]$Verification = 'NotVerified', [bool]$Cancelled = $false)
    if ($Cancelled) { return 'Cancelled' }
    if (-not $BuildSucceeded) { return 'Failed' }
    if ($Verification -eq 'Verified') { return 'Succeeded' }
    return 'NotVerified'
}

# Short message key (a ui-strings key) for the failed phase; the window shows the translated text.
function Get-WinEaseFailureMessageKey {
    param([double]$PhaseNumber = 0)
    if ($PhaseNumber -ge 1 -and $PhaseNumber -le 3) { return 'Progress.Failure.Source' }
    if ($PhaseNumber -eq 15) { return 'Progress.Failure.Verification' }
    if ($PhaseNumber -ge 16 -and $PhaseNumber -le 18) { return 'Progress.Failure.Iso' }
    return 'Progress.Failure.Generic'
}

function New-WinEaseProgressStateData {
    param([Parameter(Mandatory)][string]$State)
    if ($script:WinEaseProgressStates -notcontains $State) { throw "Unknown progress state '$State'" }
    return @{ State = $State }
}

# Data of the 'failure' event. Nothing here carries a secret: the summary is masked, the paths are paths.
function New-WinEaseFailureData {
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [string]$FailedPhase = '',
        [double]$FailedPhaseNumber = 0,
        [string]$LogPath = '',
        [string]$ReportPath = '',
        [string]$OutputPath = '',
        [string]$DiagnosticsPath = '',
        [string]$DocsPath = '',
        [string[]]$Secrets = @()
    )
    return @{
        State             = 'Failed'
        FailedPhase       = $FailedPhase
        FailedPhaseNumber = $FailedPhaseNumber
        MessageKey        = (Get-WinEaseFailureMessageKey -PhaseNumber $FailedPhaseNumber)
        Summary           = (Get-WinEaseExceptionSummary -ErrorRecord $ErrorRecord -Secrets $Secrets)
        LogPath           = $LogPath
        ReportPath        = $ReportPath
        OutputPath        = $OutputPath
        DiagnosticsPath   = $DiagnosticsPath
        DocsPath          = $DocsPath
    }
}

# Extra data of the final 'done' event. Success keeps its old meaning (the builder finished without an
# error); State and Verification are what a window must show.
function New-WinEaseDoneData {
    param(
        [bool]$BuildSucceeded,
        $PayloadVerified = $null,
        $IsoVerified = $null,
        [hashtable]$Failure = $null,
        [string]$LogPath = '',
        [string]$ReportPath = '',
        [string]$OutputPath = '',
        [string]$DiagnosticsPath = '',
        [string]$DocsPath = ''
    )
    $verification = Get-WinEaseVerificationState -PayloadVerified $PayloadVerified -IsoVerified $IsoVerified
    $data = @{
        State           = (Get-WinEaseFinalProgressState -BuildSucceeded $BuildSucceeded -Verification $verification)
        Verification    = $verification
        LogPath         = $LogPath
        ReportPath      = $ReportPath
        OutputPath      = $OutputPath
        DiagnosticsPath = $DiagnosticsPath
        DocsPath        = $DocsPath
    }
    if ($Failure) {
        foreach ($k in 'FailedPhase', 'FailedPhaseNumber', 'MessageKey', 'Summary') { if ($Failure.ContainsKey($k)) { $data[$k] = $Failure[$k] } }
    }
    return $data
}

# Convenience senders: no-ops when no window is open (Send-WinEaseGuiProgress is defined by the WinUI host).
function Send-WinEaseGuiState {
    param([Parameter(Mandatory)][string]$State)
    if (-not (Get-Command -Name Send-WinEaseGuiProgress -ErrorAction SilentlyContinue)) { return }
    Send-WinEaseGuiProgress -Event state -Data (New-WinEaseProgressStateData -State $State)
}

# A log line for the window: one line, secrets masked, bounded length.
function Send-WinEaseGuiLogLine {
    param([AllowEmptyString()][string]$Text)
    if (-not (Get-Command -Name Send-WinEaseGuiProgress -ErrorAction SilentlyContinue)) { return }
    $line = (Hide-WinEaseSecretText -Text $Text) -replace '[\r\n]+', ' '
    if ($line.Length -gt 500) { $line = $line.Substring(0, 500) + '...' }
    Send-WinEaseGuiProgress -Event log -Data @{ Text = $line }
}

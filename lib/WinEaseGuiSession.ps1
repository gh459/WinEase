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
    param(
        $GuiResult
    )
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
}

function Invoke-WinEaseGuiSession {
    $initialSettings = Get-WinEaseGuiInitialSettings
    $guiResult = Show-WinEaseGuiSessionWindow -InitialSettings $initialSettings
    if (-not ($guiResult -and $guiResult.Success)) { return $false }

    Apply-WinEaseGuiResult -GuiResult $guiResult
    return $true
}

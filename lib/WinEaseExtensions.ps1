# WinEaseExtensions.ps1 - User extensibility engine for WinEase
# Dot-sourced by WinEasebuilder.ps1. Provides user tweaks, presets, custom scripts,
# config diffing and recovery readiness diagnostics.

# 1. Import-WinEaseUserExtensions
function Import-WinEaseUserExtensions {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$PresetsOnly
    )
    # Reset only what this call repopulates; a -PresetsOnly re-read must keep the tweaks
    # and scripts loaded by the earlier full call.
    if (-not $PresetsOnly) {
        $script:UserTweakDefs = [ordered]@{}
        $script:UserCustomScripts = @()
    }
    $script:UserPresets = [ordered]@{}
    $errors = @()

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $scriptDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
        $ConfigPath = Resolve-WinEaseUserConfigPath -RepoRoot $scriptDir -Name 'user-tweaks.psd1'
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return [PSCustomObject]@{ Loaded = $false; UserTweakCount = 0; UserPresetCount = 0; CustomScriptCount = 0; Errors = $errors }
    }

    $data = $null
    try {
        $data = Import-PowerShellDataFile -LiteralPath $ConfigPath
    } catch {
        $msg = "Failed to load '$ConfigPath': $($_.Exception.Message)"
        $errors += $msg
        Write-Warning "[UserExtensions] $msg"
        return [PSCustomObject]@{ Loaded = $false; UserTweakCount = 0; UserPresetCount = 0; CustomScriptCount = 0; Errors = $errors }
    }

    # UserTweaks
    if (-not $PresetsOnly -and $data.UserTweaks) {
        foreach ($ut in $data.UserTweaks) {
            if (-not $ut.Key -or -not $ut.Category -or -not $ut.Description) {
                $errors += "UserTweak missing required keys (Key, Category, Description): $($ut.Key)"
                Write-Warning "[UserExtensions] UserTweak missing required keys: $($ut.Key)"
                continue
            }
            if ($script:AllTweakDefs -and $script:AllTweakDefs.Contains($ut.Key)) {
                $errors += "UserTweak key '$($ut.Key)' conflicts with an existing tweak key; skipped."
                Write-Warning "[UserExtensions] UserTweak key '$($ut.Key)' conflicts with existing key; skipped."
                continue
            }
            $script:UserTweakDefs[$ut.Key] = $ut
            if ($script:AllTweakDefs) {
                $script:AllTweakDefs[$ut.Key] = @{ Category = $ut.Category; Default = [bool]$ut.Default; Description = $ut.Description; IsUserTweak = $true }
                # Optional Japanese text for the GUI (display only)
                if ($ut.DescriptionJa) { $script:AllTweakDefs[$ut.Key].DescriptionJa = [string]$ut.DescriptionJa }
            }
        }
    }

    # UserPresets
    if ($data.UserPresets) {
        foreach ($presetKey in $data.UserPresets.Keys) {
            $ov = $data.UserPresets[$presetKey]
            $merged = @{}
            if ($ov.BasePreset -and $script:BuiltInPresets -and $script:BuiltInPresets.Contains($ov.BasePreset)) {
                $base = $script:BuiltInPresets[$ov.BasePreset]
                if ($base -is [System.Collections.IDictionary]) {
                    foreach ($k in $base.Keys) { $merged[$k] = $base[$k] }
                } elseif ($base.PSObject) {
                    foreach ($p in $base.PSObject.Properties) { $merged[$p.Name] = $p.Value }
                }
            }
            if ($ov -is [System.Collections.IDictionary]) {
                foreach ($k in $ov.Keys) { if ($k -ne 'BasePreset') { $merged[$k] = $ov[$k] } }
            } elseif ($ov.PSObject) {
                foreach ($p in $ov.PSObject.Properties) { if ($p.Name -ne 'BasePreset') { $merged[$p.Name] = $p.Value } }
            }
            if ($script:BuiltInPresets) { $script:BuiltInPresets[$presetKey] = $merged }
            else { if (-not $script:UserPresets) { $script:UserPresets = [ordered]@{} }; $script:UserPresets[$presetKey] = $merged }
        }
    }

    # CustomScripts
    if (-not $PresetsOnly) {
    $validStages = @('PreBuild','OfflineImage','FirstLogon','UserOnce')
    $validOnErrors = @('Stop','Warn','Ignore')
    if ($data.CustomScripts) {
        foreach ($cs in $data.CustomScripts) {
            if (-not $cs.Stage -or $validStages -notcontains $cs.Stage) {
                $errors += "CustomScript '$($cs.Id)' has invalid Stage '$($cs.Stage)'."
                Write-Warning "[UserExtensions] CustomScript '$($cs.Id)' invalid Stage '$($cs.Stage)'."
                continue
            }
            if ($cs.OnError -and $validOnErrors -notcontains $cs.OnError) {
                $errors += "CustomScript '$($cs.Id)' has invalid OnError '$($cs.OnError)'."
                Write-Warning "[UserExtensions] CustomScript '$($cs.Id)' invalid OnError '$($cs.OnError)'."
                continue
            }
            $script:UserCustomScripts += $cs
        }
    }
    }

    return [PSCustomObject]@{
        Loaded            = $true
        UserTweakCount    = @($script:UserTweakDefs.Keys).Count
        UserPresetCount   = if ($data.UserPresets) { $data.UserPresets.Count } else { 0 }
        CustomScriptCount = @($script:UserCustomScripts).Count
        Errors            = $errors
    }
}

# 2. Invoke-WinEaseUserExtensionActions
function Invoke-WinEaseUserExtensionActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Appx','FOD','Registry','SetupScripts')]
        [string]$PhaseType,
        [hashtable]$TweakSettings = $null,
        [string]$ScratchDir = '',
        [hashtable]$Context = $null,
        [switch]$DryRun
    )
    if ($Context) { Write-Verbose "Context keys: $(@($Context.Keys) -join ', ')" }
    if ($null -eq $TweakSettings) { $TweakSettings = $script:TweakSettings }
    if ($null -eq $TweakSettings) { $TweakSettings = @{} }
    Write-Verbose "ScratchDir: $ScratchDir"
    $applied = 0
    $failed = 0
    $results = @()
    if (-not $script:UserTweakDefs) { $script:UserTweakDefs = [ordered]@{} }

    foreach ($ut in $script:UserTweakDefs.Values) {
        if (-not $TweakSettings.Contains($ut.Key)) { continue }
        if (-not [bool]$TweakSettings[$ut.Key]) { continue }
        if (-not $ut.Actions) { continue }
        foreach ($act in $ut.Actions) {
            $actType = $act.Type
            $shouldRun = $false
            if ($PhaseType -eq 'Appx' -and $actType -eq 'AppxRemove') { $shouldRun = $true }
            if ($PhaseType -eq 'FOD' -and ($actType -eq 'FeatureDisable' -or $actType -eq 'CapabilityRemove')) { $shouldRun = $true }
            if ($PhaseType -eq 'Registry' -and ($actType -eq 'Registry' -or $actType -eq 'Service')) { $shouldRun = $true }
            if (-not $shouldRun) { continue }
            $r = @{ Tweak = $ut.Key; Type = $actType; Status = 'Applied'; Error = '' }
            if ($DryRun) {
                $r.Status = 'DryRun'
                $results += $r
                $applied++
                continue
            }
            try {
                if ($PhaseType -eq 'Appx') {
                    Write-Verbose "UserExtension AppxRemove: $($act.Name)"
                } elseif ($PhaseType -eq 'FOD') {
                    Write-Verbose "UserExtension FOD: $($act.Name)"
                } elseif ($PhaseType -eq 'Registry') {
                    if ($actType -eq 'Registry') {
                        $hivePath = "HKLM:\$($act.Hive)\$($act.Path)"
                        if (-not (Test-Path -LiteralPath $hivePath)) { New-Item -Path $hivePath -Force | Out-Null }
                        $kind = if ($act.Kind) { $act.Kind } else { 'String' }
                        Set-ItemProperty -LiteralPath $hivePath -Name $act.Name -Value $act.Value -Type $kind -Force -ErrorAction Stop
                    } elseif ($actType -eq 'Service') {
                        $svcPath = "HKLM:\zSYSTEM\ControlSet001\Services\$($act.Name)"
                        if (Test-Path -LiteralPath $svcPath) {
                            $startVal = switch ($act.Value) { 'Disabled' { 4 } 'Manual' { 3 } 'Automatic' { 2 } default { 4 } }
                            Set-ItemProperty -LiteralPath $svcPath -Name 'Start' -Value $startVal -Type DWord -Force -ErrorAction Stop
                        }
                    }
                }
                $applied++
            } catch {
                $failed++
                $r.Status = 'Failed'
                $r.Error = $_.Exception.Message
                Write-Warning "User extension action '$actType' failed for tweak '$($ut.Key)': $($_.Exception.Message)"
            }
            $results += $r
        }
    }
    return [PSCustomObject]@{ AppliedCount = $applied; FailedCount = $failed; Results = $results }
}

# 3. Get-WinEaseCustomScriptMetadata
function Get-WinEaseCustomScriptMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )
    $meta = [PSCustomObject]@{
        Id          = ''
        Path        = $ScriptPath
        Stage       = ''
        Order       = 100
        Condition   = ''
        OnError     = 'Warn'
        Description = ''
        Sha256      = ''
    }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return $meta }
    try {
        $meta.Sha256 = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    try {
        $lines = [System.IO.File]::ReadAllLines($ScriptPath) | Select-Object -First 30
        foreach ($ln in $lines) {
            if ($ln -match '^\s*#\s*@WinEase-Stage:\s*(.+)$') { $meta.Stage = $matches[1].Trim() }
            elseif ($ln -match '^\s*#\s*@WinEase-Order:\s*(\d+)') { $meta.Order = [int]$matches[1] }
            elseif ($ln -match '^\s*#\s*@WinEase-Condition:\s*(.+)$') { $meta.Condition = $matches[1].Trim() }
            elseif ($ln -match '^\s*#\s*@WinEase-OnError:\s*(Stop|Warn|Ignore)') { $meta.OnError = $matches[1] }
            elseif ($ln -match '^\s*#\s*@WinEase-Description:\s*(.+)$') { $meta.Description = $matches[1].Trim() }
            elseif ($ln -match '^\s*#\s*@WinEase-Id:\s*(.+)$') { $meta.Id = $matches[1].Trim() }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    if (-not $meta.Id) { $meta.Id = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath) }
    return $meta
}

# Custom script locator shared by the stage runner and the ISO bundler. Layout: tools\custom-scripts\<Stage>\
# (PreBuild / OfflineImage / FirstLogon / UserOnce). With -IncludeLegacy, files directly in tools\custom-scripts
# count as FirstLogon and tools\custom-scripts\user as UserOnce (the older layout).
function Get-WinEaseCustomScriptFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][ValidateSet('PreBuild','OfflineImage','FirstLogon','UserOnce')][string]$Stage,
        [switch]$IncludeLegacy
    )
    $base = Join-Path -Path $RepoRoot -ChildPath 'tools\custom-scripts'
    $dirs = @(Join-Path -Path $base -ChildPath $Stage)
    if ($IncludeLegacy) {
        if ($Stage -eq 'FirstLogon') { $dirs += $base }
        elseif ($Stage -eq 'UserOnce') { $dirs += (Join-Path -Path $base -ChildPath 'user') }
    }
    $found = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $found += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'README.md' -and $_.Name -ne '.gitkeep' })
    }
    return $found
}
# 4. Invoke-WinEaseCustomScriptsStage
function Invoke-WinEaseCustomScriptsStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PreBuild','OfflineImage','FirstLogon','UserOnce')]
        [string]$Stage,
        [hashtable]$Context = @{},
        [switch]$DryRun
    )
    $executed = @()
    $skipped = @()
    $failed = @()
    $candidates = @()

    if ($script:UserCustomScripts) {
        foreach ($cs in $script:UserCustomScripts) {
            if ($cs.Enabled -ne $true) { continue }
            if ($cs.Stage -ne $Stage) { continue }
            $candidates += $cs
        }
    }

    # Auto-detect scripts in tools/custom-scripts/<Stage>/
    $scriptDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
    foreach ($f in @(Get-WinEaseCustomScriptFiles -RepoRoot $scriptDir -Stage $Stage | Where-Object { $_.Extension -eq '.ps1' })) {
        $meta = Get-WinEaseCustomScriptMetadata -ScriptPath $f.FullName
        if (-not $meta.Stage) { $meta.Stage = $Stage }
        if ($meta.Stage -eq $Stage) { $candidates += $meta }
    }
    # Sort by Order then filename
    $sorted = $candidates | Sort-Object -Property @{ Expression = { if ($_.Order) { [int]$_.Order } else { 100 } } }, @{ Expression = { [string]$_.Path } }

    foreach ($cand in $sorted) {
        $meta = if ($cand -is [PSCustomObject] -and $cand.Sha256) { $cand } else { Get-WinEaseCustomScriptMetadata -ScriptPath $cand.Path }
        $cond = $meta.Condition
        if ([string]::IsNullOrWhiteSpace($cond)) { $cond = $cand.Condition }
        $run = $true
        if (-not [string]::IsNullOrWhiteSpace($cond)) {
            $condVal = $null
            if ($script:TweakSettings -and $script:TweakSettings.Contains($cond)) { $condVal = $script:TweakSettings[$cond] }
            elseif ($Context.Config -and $Context.Config.ContainsKey($cond)) { $condVal = $Context.Config[$cond] }
            if ($condVal -ne $true) { $run = $false }
        }
        if (-not $run) {
            $skipped += $meta
            continue
        }

        $onError = if ($meta.OnError) { $meta.OnError } elseif ($cand.OnError) { $cand.OnError } else { 'Warn' }
        Write-Host "[CUSTOM SCRIPT] Executing '$($meta.Id)' (Stage: $Stage, SHA256: $($meta.Sha256), OnError: $onError)" -ForegroundColor Cyan

        if ($Stage -eq 'PreBuild' -or $Stage -eq 'OfflineImage') {
            if ($DryRun) {
                $executed += $meta
                continue
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                & $meta.Path -WinEaseContext $Context
                $sw.Stop()
                Write-Host "  [OK] Completed in $([math]::Round($sw.Elapsed.TotalSeconds,2))s" -ForegroundColor Green
                $executed += $meta
            } catch {
                $sw.Stop()
                $failed += $meta
                if ($onError -eq 'Stop') { throw }
                elseif ($onError -eq 'Warn') { Write-Warning "Custom script '$($meta.Id)' failed: $($_.Exception.Message)" }
                else { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
        } else {
            # FirstLogon / UserOnce: copy to offline image
            $scratchDir = if ($Context.ScratchDir) { $Context.ScratchDir } else { $script:BaseWorkDir }
            if ($scratchDir) {
                $targetDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts\Custom\$Stage"
                if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
                Copy-Item -LiteralPath $meta.Path -Destination (Join-Path -Path $targetDir -ChildPath ([System.IO.Path]::GetFileName($meta.Path))) -Force
            }
            $executed += $meta
        }
    }

    return [PSCustomObject]@{ Stage = $Stage; Executed = $executed; Skipped = $skipped; Failed = $failed }
}

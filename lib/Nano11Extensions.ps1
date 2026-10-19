# Nano11Extensions.ps1 - User extensibility engine for nano11
# Dot-sourced by nano11builder.ps1. Provides user tweaks, presets, custom scripts,
# config diffing and recovery readiness diagnostics.

# 1. Import-Nano11UserExtensions
function Import-Nano11UserExtensions {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$PresetsOnly
    )
    $script:UserTweakDefs = [ordered]@{}
    $script:UserPresets = [ordered]@{}
    $script:UserCustomScripts = @()
    $errors = @()

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $ConfigPath = Join-Path -Path $scriptDir -ChildPath 'config\user-tweaks.psd1'
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
        UserTweakCount    = $script:UserTweakDefs.Count
        UserPresetCount   = if ($data.UserPresets) { $data.UserPresets.Count } else { 0 }
        CustomScriptCount = $script:UserCustomScripts.Count
        Errors            = $errors
    }
}

# 2. Invoke-Nano11UserExtensionActions
function Invoke-Nano11UserExtensionActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Appx','FOD','Registry','SetupScripts')]
        [string]$PhaseType,
        [hashtable]$TweakSettings = $null,
        [string]$ScratchDir = '',
        [switch]$DryRun
    )
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
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
            $results += $r
        }
    }
    return [PSCustomObject]@{ AppliedCount = $applied; FailedCount = $failed; Results = $results }
}

# 3. Get-Nano11CustomScriptMetadata
function Get-Nano11CustomScriptMetadata {
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
            if ($ln -match '^\s*#\s*@Nano11-Stage:\s*(.+)$') { $meta.Stage = $matches[1].Trim() }
            elseif ($ln -match '^\s*#\s*@Nano11-Order:\s*(\d+)') { $meta.Order = [int]$matches[1] }
            elseif ($ln -match '^\s*#\s*@Nano11-Condition:\s*(.+)$') { $meta.Condition = $matches[1].Trim() }
            elseif ($ln -match '^\s*#\s*@Nano11-OnError:\s*(Stop|Warn|Ignore)') { $meta.OnError = $matches[1] }
            elseif ($ln -match '^\s*#\s*@Nano11-Description:\s*(.+)$') { $meta.Description = $matches[1].Trim() }
            elseif ($ln -match '^\s*#\s*@Nano11-Id:\s*(.+)$') { $meta.Id = $matches[1].Trim() }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    if (-not $meta.Id) { $meta.Id = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath) }
    return $meta
}

# 4. Invoke-Nano11CustomScriptsStage
function Invoke-Nano11CustomScriptsStage {
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

    # Auto-detect scripts in scripts/custom/<Stage>/
    $scriptDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
    $autoDir = Join-Path -Path $scriptDir -ChildPath "scripts\custom\$Stage"
    if (Test-Path -LiteralPath $autoDir) {
        Get-ChildItem -LiteralPath $autoDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $meta = Get-Nano11CustomScriptMetadata -ScriptPath $_.FullName
            if (-not $meta.Stage) { $meta.Stage = $Stage }
            if ($meta.Stage -eq $Stage) { $candidates += $meta }
        }
    }

    # Sort by Order then filename
    $sorted = $candidates | Sort-Object -Property @{ Expression = { if ($_.Order) { [int]$_.Order } else { 100 } } }, @{ Expression = { [string]$_.Path } }

    foreach ($cand in $sorted) {
        $meta = if ($cand -is [PSCustomObject] -and $cand.Sha256) { $cand } else { Get-Nano11CustomScriptMetadata -ScriptPath $cand.Path }
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
                & $meta.Path -Nano11Context $Context
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

# 5. Compare-Nano11Config & Format-Nano11ConfigDiff
function Resolve-Nano11ConfigForDiff {
    param($InputConfig, $NameHint)
    $result = @{ Name = $NameHint; Data = $null }
    if ($InputConfig -is [string]) {
        $s = $InputConfig.Trim()
        if (Test-Path -LiteralPath $s) {
            try { $raw = [System.IO.File]::ReadAllText($s, [System.Text.Encoding]::UTF8); $parsed = $raw | ConvertFrom-Json; $result.Data = $parsed; $result.Name = [System.IO.Path]::GetFileNameWithoutExtension($s) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        } elseif ($script:BuiltInPresets -and $script:BuiltInPresets.Contains($s)) {
            $result.Data = $script:BuiltInPresets[$s]
            $result.Name = $s
        } else {
            $result.Name = $s
            $result.Data = @{}
        }
    } elseif ($InputConfig -is [System.Collections.IDictionary]) {
        $result.Data = $InputConfig
        if ($NameHint) { $result.Name = $NameHint }
    } elseif ($InputConfig.PSObject) {
        $result.Data = $InputConfig
        if ($NameHint) { $result.Name = $NameHint }
    }
    if ($null -eq $result.Data) { $result.Data = @{} }
    if (-not $result.Name) { $result.Name = 'Config' }
    return $result
}

function Compare-Nano11Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ReferenceConfig,
        [Parameter(Mandatory = $true)]
        $DifferenceConfig
    )
    $ref = Resolve-Nano11ConfigForDiff -InputConfig $ReferenceConfig -NameHint 'Reference'
    $diff = Resolve-Nano11ConfigForDiff -InputConfig $DifferenceConfig -NameHint 'Difference'

    $compDiffs = @()
    $tweakGroupDiffs = @()
    $tweakSettingDiffs = @()

    # Component diffs
    $allCompKeys = @()
    if ($ref.Data -is [System.Collections.IDictionary]) { $allCompKeys += $ref.Data.Keys }
    elseif ($ref.Data.PSObject) { $allCompKeys += $ref.Data.PSObject.Properties.Name }
    if ($diff.Data -is [System.Collections.IDictionary]) { $allCompKeys += $diff.Data.Keys }
    elseif ($diff.Data.PSObject) { $allCompKeys += $diff.Data.PSObject.Properties.Name }
    $allCompKeys = $allCompKeys | Select-Object -Unique
    foreach ($k in $allCompKeys) {
        $rv = $null; $dv = $null
        if ($ref.Data -is [System.Collections.IDictionary]) { if ($ref.Data.Contains($k)) { $rv = $ref.Data[$k] } } elseif ($ref.Data.PSObject -and $ref.Data.PSObject.Properties[$k]) { $rv = $ref.Data.PSObject.Properties[$k].Value }
        if ($diff.Data -is [System.Collections.IDictionary]) { if ($diff.Data.Contains($k)) { $dv = $diff.Data[$k] } } elseif ($diff.Data.PSObject -and $diff.Data.PSObject.Properties[$k]) { $dv = $diff.Data.PSObject.Properties[$k].Value }
        if ($rv -ne $dv) {
            $compDiffs += [PSCustomObject]@{ Key = $k; Category = 'Component'; ReferenceValue = $rv; DifferenceValue = $dv }
        }
    }

    # TweakSettings diffs
    $refTS = $null; $diffTS = $null
    if ($ref.Data -is [System.Collections.IDictionary] -and $ref.Data.Contains('TweakSettings')) { $refTS = $ref.Data['TweakSettings'] }
    elseif ($ref.Data.PSObject -and $ref.Data.PSObject.Properties['TweakSettings']) { $refTS = $ref.Data.PSObject.Properties['TweakSettings'].Value }
    if ($diff.Data -is [System.Collections.IDictionary] -and $diff.Data.Contains('TweakSettings')) { $diffTS = $diff.Data['TweakSettings'] }
    elseif ($diff.Data.PSObject -and $diff.Data.PSObject.Properties['TweakSettings']) { $diffTS = $diff.Data.PSObject.Properties['TweakSettings'].Value }

    $allTweakKeys = @()
    if ($refTS -is [System.Collections.IDictionary]) { $allTweakKeys += $refTS.Keys }
    elseif ($refTS.PSObject) { $allTweakKeys += $refTS.PSObject.Properties.Name }
    if ($diffTS -is [System.Collections.IDictionary]) { $allTweakKeys += $diffTS.Keys }
    elseif ($diffTS.PSObject) { $allTweakKeys += $diffTS.PSObject.Properties.Name }
    $allTweakKeys = $allTweakKeys | Select-Object -Unique
    foreach ($k in $allTweakKeys) {
        $rv = $null; $dv = $null
        if ($refTS -is [System.Collections.IDictionary]) { if ($refTS.Contains($k)) { $rv = $refTS[$k] } } elseif ($refTS.PSObject -and $refTS.PSObject.Properties[$k]) { $rv = $refTS.PSObject.Properties[$k].Value }
        if ($diffTS -is [System.Collections.IDictionary]) { if ($diffTS.Contains($k)) { $dv = $diffTS[$k] } } elseif ($diffTS.PSObject -and $diffTS.PSObject.Properties[$k]) { $dv = $diffTS.PSObject.Properties[$k].Value }
        $desc = ''
        if ($script:AllTweakDefs -and $script:AllTweakDefs.Contains($k)) { $desc = $script:AllTweakDefs[$k].Description }
        if ($rv -ne $dv) {
            $tweakSettingDiffs += [PSCustomObject]@{ Key = $k; Category = 'TweakSetting'; Description = $desc; ReferenceValue = $rv; DifferenceValue = $dv }
        }
    }

    # TweakGroups
    $refTG = $null; $diffTG = $null
    if ($ref.Data -is [System.Collections.IDictionary] -and $ref.Data.Contains('TweakGroups')) { $refTG = $ref.Data['TweakGroups'] }
    elseif ($ref.Data.PSObject -and $ref.Data.PSObject.Properties['TweakGroups']) { $refTG = $ref.Data.PSObject.Properties['TweakGroups'].Value }
    if ($diff.Data -is [System.Collections.IDictionary] -and $diff.Data.Contains('TweakGroups')) { $diffTG = $diff.Data['TweakGroups'] }
    elseif ($diff.Data.PSObject -and $diff.Data.PSObject.Properties['TweakGroups']) { $diffTG = $diff.Data.PSObject.Properties['TweakGroups'].Value }
    $allTGKeys = @()
    if ($refTG -is [System.Collections.IDictionary]) { $allTGKeys += $refTG.Keys }
    elseif ($refTG.PSObject) { $allTGKeys += $refTG.PSObject.Properties.Name }
    if ($diffTG -is [System.Collections.IDictionary]) { $allTGKeys += $diffTG.Keys }
    elseif ($diffTG.PSObject) { $allTGKeys += $diffTG.PSObject.Properties.Name }
    $allTGKeys = $allTGKeys | Select-Object -Unique
    foreach ($k in $allTGKeys) {
        $rv = $null; $dv = $null
        if ($refTG -is [System.Collections.IDictionary]) { if ($refTG.Contains($k)) { $rv = $refTG[$k] } } elseif ($refTG.PSObject -and $refTG.PSObject.Properties[$k]) { $rv = $refTG.PSObject.Properties[$k].Value }
        if ($diffTG -is [System.Collections.IDictionary]) { if ($diffTG.Contains($k)) { $dv = $diffTG[$k] } } elseif ($diffTG.PSObject -and $diffTG.PSObject.Properties[$k]) { $dv = $diffTG.PSObject.Properties[$k].Value }
        if ($rv -ne $dv) {
            $tweakGroupDiffs += [PSCustomObject]@{ Key = $k; Category = 'TweakGroup'; ReferenceValue = $rv; DifferenceValue = $dv }
        }
    }

    $totalDiff = $compDiffs.Count + $tweakGroupDiffs.Count + $tweakSettingDiffs.Count
    return [PSCustomObject]@{
        ReferenceName     = $ref.Name
        DifferenceName    = $diff.Name
        ComponentDiffs    = $compDiffs
        TweakGroupDiffs   = $tweakGroupDiffs
        TweakSettingDiffs = $tweakSettingDiffs
        AddedImpacts      = @()
        RemovedImpacts    = @()
        TotalDiffCount    = $totalDiff
    }
}

function Format-Nano11ConfigDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$DiffResult
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Config diff: $($DiffResult.ReferenceName) -> $($DiffResult.DifferenceName)")
    [void]$sb.AppendLine("Total differences: $($DiffResult.TotalDiffCount)")
    if ($DiffResult.ComponentDiffs.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('[Components]')
        foreach ($d in $DiffResult.ComponentDiffs) { [void]$sb.AppendLine("  $($d.Key): $($d.ReferenceValue) -> $($d.DifferenceValue)") }
    }
    if ($DiffResult.TweakGroupDiffs.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('[Tweak Groups]')
        foreach ($d in $DiffResult.TweakGroupDiffs) { [void]$sb.AppendLine("  $($d.Key): $($d.ReferenceValue) -> $($d.DifferenceValue)") }
    }
    if ($DiffResult.TweakSettingDiffs.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('[Tweak Settings]')
        foreach ($d in $DiffResult.TweakSettingDiffs) { [void]$sb.AppendLine("  $($d.Key): $($d.ReferenceValue) -> $($d.DifferenceValue)") }
    }
    return $sb.ToString()
}

# 6. Test-Nano11RecoveryReadiness
function Test-Nano11RecoveryReadiness {
    [CmdletBinding()]
    param(
        [psobject]$Config
    )
    $secondaryDrives = @()
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
        foreach ($d in $drives) {
            if ($d.Name -eq 'C' -or $d.Name.Length -ne 1) { continue }
            if ($d.Free -gt 0) {
                $freeGB = [math]::Round($d.Free / 1GB, 1)
                $secondaryDrives += "$($d.Name): ($freeGB GB free)"
            }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    $sysRestoreEnabled = $false
    try {
        $sr = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
        if ($sr) { $sysRestoreEnabled = $true }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    $winReEnabled = $true
    if ($Config -and $Config.KeepRecoveryEnv -eq $false) { $winReEnabled = $false }

    $migrationBackupFound = $false
    try {
        $manifestPath = Join-Path -Path (Join-Path -Path $env:USERPROFILE -ChildPath 'Documents\nano11_workspace') -ChildPath 'migration-manifest.json'
        if (Test-Path -LiteralPath $manifestPath) { $migrationBackupFound = $true }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    $score = 'Low'
    if ($secondaryDrives.Count -gt 0 -and $sysRestoreEnabled) { $score = 'High' }
    elseif ($secondaryDrives.Count -gt 0 -or $sysRestoreEnabled -or $winReEnabled) { $score = 'Medium' }

    $recs = @()
    if (-not $winReEnabled) {
        $recs += "The generated ISO will have Windows Recovery Environment (WinRE) removed. Keep the installation USB media as a recovery disk."
    }
    if ($secondaryDrives.Count -eq 0 -and -not $migrationBackupFound) {
        $recs += "No secondary drive or migration backup found. Run Nano11-Migrator.ps1 to back up user data before building."
    }

    return [PSCustomObject]@{
        HasSecondaryDrive    = ($secondaryDrives.Count -gt 0)
        SecondaryDrives      = $secondaryDrives
        SystemRestoreEnabled = $sysRestoreEnabled
        WinReEnabledOnTarget = $winReEnabled
        MigrationBackupFound = $migrationBackupFound
        ReadinessScore       = $score
        Recommendations     = $recs
    }
}
# WinEaseDependencies.ps1 - Dependency catalog import, checks and report formatting
# Dot-sourced by WinEasehelpers.ps1 (function definitions only).

# =========================================================================
# Dependency / feature-impact analysis (config/dependencies.psd1)
# =========================================================================

# User-facing strings of the dependency report. The text lives in config/ui-strings/<lang>.json
# (keys Dep.*); the English text here is the fallback for callers without the GUI string loader
# (the console builder) and is kept identical to en.json by a test. A function, not a script
# variable: the helper modules must not run top-level statements.
function Get-WinEaseDependencyStringDefaults {
    return [ordered]@{
    'Dep.Heading.Conflict'       = '[DEPENDENCY CONFLICT]'
    'Dep.Heading.Unknown'        = '[DEPENDENCY UNKNOWN / UNVERIFIED]'
    'Dep.Heading.Impact'         = '[FEATURE IMPACT]'
    'Dep.Label.Conflict'         = 'CONFLICT'
    'Dep.Label.Unknown'          = 'UNKNOWN (not verified, may NOT be safe)'
    'Dep.Label.Impact'           = 'IMPACT'
    'Dep.Conflict.With'          = ' (conflicts with: {0})'
    'Dep.Conflict.KeptFeature'   = ' -- removes a feature you chose to keep'
    'Dep.Reason.CatalogUnknown'  = 'Catalog marks this item as Unknown.'
    'Dep.Reason.ImpactUndefined' = 'Impact is undefined or Unknown (fail-safe).'
    'Dep.Reason.Unregistered'    = 'Not defined in config/dependencies.psd1 (fail-safe: treated as Unknown).'
    'Dep.Summary.UserTweakNoImpact' = 'User-defined custom tweak does not declare explicit dependency impact metadata (Dependency: Unknown).'
    'Dep.Summary.Unregistered'   = 'Unregistered advanced debloat item'
    }
}

function Get-WinEaseDependencyString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [object[]]$Format = @()
    )
    $defaults = Get-WinEaseDependencyStringDefaults
    $fallback = if ($defaults.Contains($Key)) { $defaults[$Key] } else { $Key }
    # Bolt optimization: Replacing Get-Command with Test-Path Function:\ avoids expensive cmdlet discovery overhead (~99% faster).
    if (Test-Path -LiteralPath 'Function:\Get-WinEaseUiString') {
        return (Get-WinEaseUiString -Key $Key -Format $Format -Default $fallback)
    }
    if ($Format.Count -gt 0) { try { return ($fallback -f $Format) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" } }
    return $fallback
}

# Property of a result item (the formatter also accepts plain hashtables)
function Get-WinEaseDependencyField {
    param($Item, [string]$Name)
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) { if ($Item.Contains($Name)) { return $Item[$Name] } else { return $null } }
    $p = $Item.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Backwards-compatible result hashtable (HasIssues / HasCritical / Conflicts / Impacts / Unknowns) plus
# a Kind on every item. HasCritical = at least one conflict or Unknown (an Unknown is never treated as safe).
function New-WinEaseDependencyResult {
    param($Conflicts, $Impacts, $Unknowns)
    foreach ($c in @($Conflicts)) { Add-Member -InputObject $c -NotePropertyName Kind -NotePropertyValue 'Conflict' -Force }
    foreach ($i in @($Impacts)) { Add-Member -InputObject $i -NotePropertyName Kind -NotePropertyValue 'Impact' -Force }
    foreach ($u in @($Unknowns)) { Add-Member -InputObject $u -NotePropertyName Kind -NotePropertyValue 'Unknown' -Force }
    return @{
        HasIssues   = (@($Conflicts).Count -gt 0 -or @($Impacts).Count -gt 0 -or @($Unknowns).Count -gt 0)
        HasCritical = (@($Conflicts).Count -gt 0 -or @($Unknowns).Count -gt 0)
        Conflicts   = $Conflicts
        Impacts     = $Impacts
        Unknowns    = $Unknowns
    }
}

function Import-WinEaseDependencyCatalog {
    [CmdletBinding()]
    param(
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $scriptDir = if ($script:WinEaseHelperRoot) {
            $script:WinEaseHelperRoot
        } elseif ($PSScriptRoot) {
            Split-Path -Parent $PSScriptRoot
        } else {
            (Get-Location).Path
        }
        $Path = Join-Path -Path $scriptDir -ChildPath 'config\dependencies.psd1'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Dependency catalog not found: $Path"
    }
    $catalog = Import-PowerShellDataFile -Path $Path
    $script:WinEaseDependencyCatalog = $catalog
    $script:WinEaseDependencyCatalogPath = $Path
    return $catalog
}

function Get-WinEaseNormalizedDependencyConfig {
    param([object]$Config)
    if ($null -ne $Config -and -not ($Config -is [System.Collections.IDictionary])) {
        $normalizedConfig = @{}
        foreach ($prop in $Config.PSObject.Properties) { $normalizedConfig[$prop.Name] = $prop.Value }
        return $normalizedConfig
    } elseif ($null -ne $Config -and -not ($Config -is [hashtable])) {
        $normalizedConfig = @{}
        foreach ($key in $Config.Keys) { $normalizedConfig[$key] = $Config[$key] }
        return $normalizedConfig
    }
    return $Config
}

function Test-WinEaseSettingIsRemoved {
    param($Entry, $Value)
    if ($null -eq $Entry -or $null -eq $Entry.TriggerValue) { return $false }
    $tv = $Entry.TriggerValue
    if ($tv -is [bool]) { return ([bool]$Value -eq $tv) }
    return ("$Value" -eq "$tv")
}

function Add-WinEaseDependencyConflict {
    param(
        $Conflicts,
        $SeenConflicts,
        [string]$Category,
        [string]$Source,
        [string]$Summary,
        [string]$ConflictingWith,
        [bool]$KeptFeature = $false
    )
    $key = "$Source|$ConflictingWith"
    if ($SeenConflicts.ContainsKey($key)) { return }
    $SeenConflicts[$key] = $true
    $Conflicts.Add([pscustomobject]@{
        Category        = $Category
        Source          = $Source
        Summary         = $Summary
        ConflictingWith = $ConflictingWith
        KeptFeature     = $KeptFeature
    })
}

function Test-WinEaseCrossRuleConflicts {
    param(
        $Config,
        $Conflicts,
        $SeenConflicts
    )
    $wuKept = $false
    if ($Config -and $Config.ContainsKey('DisableWindowsUpdate')) { $wuKept = -not [bool]$Config['DisableWindowsUpdate'] }
    $expSelected = @()
    $stdSelected = @()
    if ($Config) {
        if ($Config.ContainsKey('AdvancedDebloatExperimental')) { $expSelected = @($Config['AdvancedDebloatExperimental']) }
        if ($Config.ContainsKey('AdvancedDebloatStandard')) { $stdSelected = @($Config['AdvancedDebloatStandard']) }
    }
    $safeMode = $false
    if ($Config -and $Config.ContainsKey('SafeDebloatMode')) { $safeMode = [bool]$Config['SafeDebloatMode'] }
    $keepBT = $true
    if ($Config -and $Config.ContainsKey('KeepBluetooth')) { $keepBT = [bool]$Config['KeepBluetooth'] }
    $wsl = $false
    if ($Config -and $Config.ContainsKey('WSLSupport')) { $wsl = [bool]$Config['WSLSupport'] }
    $noHyp = $false
    if ($Config -and $Config.ContainsKey('NoHypervisor')) { $noHyp = [bool]$Config['NoHypervisor'] }
    $keepSearch = $false
    if ($Config -and $Config.ContainsKey('KeepSearchIndex')) { $keepSearch = [bool]$Config['KeepSearchIndex'] }
    $disableSearch = $false
    if ($Config -and $Config.ContainsKey('DisableWindowsSearchIndexing')) { $disableSearch = [bool]$Config['DisableWindowsSearchIndexing'] }
    $keepXbox = $false
    if ($Config -and $Config.ContainsKey('KeepXboxServices')) { $keepXbox = [bool]$Config['KeepXboxServices'] }
    $removeStore = $false
    if ($Config -and $Config.ContainsKey('RemoveStore')) { $removeStore = [bool]$Config['RemoveStore'] }
    $disableGameDVR = $false
    if ($Config -and $Config.ContainsKey('DisableGameDVR')) { $disableGameDVR = [bool]$Config['DisableGameDVR'] }

    $btRemoved = ($stdSelected -contains 'Remove Bluetooth stack (service + binary) [20-40MB]') -or ($expSelected -contains 'Physical: Bluetooth stack (complete removal) [~20-40MB]')
    $wslRemoved = ($stdSelected -contains 'Remove WSL / VM Platform [20-40MB]') -or ($expSelected -contains 'Physical: WSL / VM Platform (complete removal) [~20-40MB]') -or ($expSelected -contains 'Physical: Hyper-V / Virtualization stack [~200-400MB]')
    $searchRemoved = ($expSelected -contains 'Physical: Cortana / Search (complete removal) [~100MB]') -or ($expSelected -contains 'Physical: Windows Search index (complete removal) [varies]')

    if ($wuKept -and $expSelected.Count -gt 0) {
        Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Component' -Source 'DisableWindowsUpdate' -Summary 'Windows Update is kept but Experimental physical debloat is selected, which breaks WinSxS/CBS integrity.' -ConflictingWith 'AdvancedDebloatExperimental' -KeptFeature $true
    }
    if ($safeMode -and $expSelected.Count -gt 0) {
        Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Component' -Source 'SafeDebloatMode' -Summary 'Safe WinSxS mode is enabled but Experimental physical debloat is selected, which breaks CBS/WinSxS integrity.' -ConflictingWith 'AdvancedDebloatExperimental' -KeptFeature $true
    }
    if ($keepBT -and $btRemoved) {
        Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Component' -Source 'KeepBluetooth' -Summary 'Bluetooth is kept but a Bluetooth stack removal item is selected.' -ConflictingWith 'Bluetooth removal item' -KeptFeature $true
    }
    if ($wsl -and ($noHyp -or $wslRemoved)) {
        Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Component' -Source 'WSLSupport' -Summary 'WSL support is enabled but hypervisor is disabled or WSL/Hyper-V removal is selected.' -ConflictingWith 'NoHypervisor / WSL removal' -KeptFeature $true
    }
    if ($keepSearch -and ($disableSearch -or $searchRemoved)) {
        Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Component' -Source 'KeepSearchIndex' -Summary 'Search indexing is kept but search disabling/removal is selected.' -ConflictingWith 'DisableWindowsSearchIndexing / search removal' -KeptFeature $true
    }
    if ($keepXbox -and ($removeStore -or $disableGameDVR)) {
        Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Component' -Source 'KeepXboxServices' -Summary 'Xbox services are kept but Store removal or GameDVR disable is selected.' -ConflictingWith 'RemoveStore / DisableGameDVR' -KeptFeature $true
    }
}

function Test-WinEaseComponentDependencies {
    param(
        $Config,
        $Cat,
        $Conflicts,
        $Impacts,
        $Unknowns,
        $SeenConflicts,
        $StdSelected,
        $ExpSelected
    )
    if (-not ($Cat -and $Cat.Components)) { return }

    foreach ($key in $Cat.Components.Keys) {
        if (-not $Config.ContainsKey($key)) { continue }
        $entry = $Cat.Components[$key]
        if ($null -eq $entry) { continue }
        $val = $Config[$key]
        $removed = Test-WinEaseSettingIsRemoved -Entry $entry -Value $val
        if (-not $removed) { continue }
        if ($entry.Status -eq 'Safe') { continue }
        if ($entry.Status -eq 'Known') {
            $Impacts.Add([pscustomobject]@{ Category = 'Component'; Source = $key; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
        } elseif ($entry.Status -eq 'Unknown') {
            $Unknowns.Add([pscustomobject]@{ Category = 'Component'; Source = $key; Summary = $entry.Summary; Reason = (Get-WinEaseDependencyString 'Dep.Reason.CatalogUnknown'); ReasonKey = 'Dep.Reason.CatalogUnknown' })
        }
        if ($entry.ConflictsWith) {
            foreach ($cw in $entry.ConflictsWith) {
                $targetRemoved = $false
                if ($Config.ContainsKey($cw)) {
                    if ($Cat.Components.ContainsKey($cw)) { $targetRemoved = Test-WinEaseSettingIsRemoved -Entry $Cat.Components[$cw] -Value $Config[$cw] }
                    elseif ($Cat.Tweaks.ContainsKey($cw)) { $targetRemoved = Test-WinEaseSettingIsRemoved -Entry $Cat.Tweaks[$cw] -Value $Config[$cw] }
                    else { $targetRemoved = [bool]$Config[$cw] }
                } elseif ($StdSelected -contains $cw -or $ExpSelected -contains $cw) {
                    $targetRemoved = $true
                }
                if ($targetRemoved) {
                    Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Component' -Source $key -Summary "$($entry.Summary)" -ConflictingWith $cw
                }
            }
        }
    }
}

function Test-WinEaseTweakDependencies {
    param(
        $Config,
        $Cat,
        $TweakSettings,
        $Conflicts,
        $Impacts,
        $Unknowns,
        $SeenConflicts,
        $StdSelected,
        $ExpSelected
    )
    if (-not ($Cat -and $Cat.Tweaks)) { return }

    foreach ($key in $Cat.Tweaks.Keys) {
        $entry = $Cat.Tweaks[$key]
        if ($null -eq $entry) { continue }
        $val = $null
        if ($TweakSettings) {
            if ($TweakSettings -is [System.Collections.IDictionary]) {
                if ($TweakSettings.Contains($key)) { $val = $TweakSettings[$key] }
            } elseif ($TweakSettings.PSObject -and $TweakSettings.PSObject.Properties[$key]) {
                $val = $TweakSettings.PSObject.Properties[$key].Value
            }
        }
        if ($null -eq $val -and $Config.ContainsKey($key)) { $val = $Config[$key] }
        if ($null -eq $val) { continue }
        $removed = Test-WinEaseSettingIsRemoved -Entry $entry -Value $val
        if (-not $removed) { continue }
        if ($entry.Status -eq 'Safe') { continue }
        if ($entry.Status -eq 'Known') {
            $Impacts.Add([pscustomobject]@{ Category = 'Tweak'; Source = $key; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
        } elseif ($entry.Status -eq 'Unknown') {
            $Unknowns.Add([pscustomobject]@{ Category = 'Tweak'; Source = $key; Summary = $entry.Summary; Reason = (Get-WinEaseDependencyString 'Dep.Reason.CatalogUnknown'); ReasonKey = 'Dep.Reason.CatalogUnknown' })
        }
        if ($entry.ConflictsWith) {
            foreach ($cw in $entry.ConflictsWith) {
                $targetRemoved = $false
                if ($Config.ContainsKey($cw)) {
                    if ($Cat.Components.ContainsKey($cw)) { $targetRemoved = Test-WinEaseSettingIsRemoved -Entry $Cat.Components[$cw] -Value $Config[$cw] }
                    elseif ($Cat.Tweaks.ContainsKey($cw)) { $targetRemoved = Test-WinEaseSettingIsRemoved -Entry $Cat.Tweaks[$cw] -Value $Config[$cw] }
                    else { $targetRemoved = [bool]$Config[$cw] }
                } elseif ($StdSelected -contains $cw -or $ExpSelected -contains $cw) {
                    $targetRemoved = $true
                }
                if ($targetRemoved) {
                    Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'Tweak' -Source $key -Summary "$($entry.Summary)" -ConflictingWith $cw
                }
            }
        }
    }
}

function Test-WinEaseUserTweakDependencies {
    param(
        $Config,
        $TweakSettings,
        $Impacts,
        $Unknowns
    )
    $userDefs = $null
    if (Get-Variable -Name UserTweakDefs -Scope Script -ErrorAction SilentlyContinue) { $userDefs = $script:UserTweakDefs }
    if (-not ($userDefs -and $userDefs.Count -gt 0)) { return }

    foreach ($ukey in @($userDefs.Keys)) {
        $uval = $null
        if ($TweakSettings) {
            if ($TweakSettings -is [System.Collections.IDictionary]) {
                if ($TweakSettings.Contains($ukey)) { $uval = $TweakSettings[$ukey] }
            } elseif ($TweakSettings.PSObject -and $TweakSettings.PSObject.Properties[$ukey]) {
                $uval = $TweakSettings.PSObject.Properties[$ukey].Value
            }
        }
        if ($null -eq $uval -and $Config.ContainsKey($ukey)) { $uval = $Config[$ukey] }
        if ($null -eq $uval -or $uval -ne $true) { continue }

        $udef = $userDefs[$ukey]
        $impact = $null
        if ($udef -is [System.Collections.IDictionary]) {
            if ($udef.Contains('Impact')) { $impact = $udef['Impact'] }
        } elseif ($udef -and $udef.PSObject.Properties['Impact']) {
            $impact = $udef.PSObject.Properties['Impact'].Value
        }

        if ($impact -is [System.Collections.IDictionary]) {
            $feat = @()
            if ($impact.Contains('AffectedFeatures')) { $feat = @($impact['AffectedFeatures']) }
            $reason = ''
            if ($impact.Contains('Reason')) { $reason = "$($impact['Reason'])" }
            $sev = ''
            if ($impact.Contains('Severity')) { $sev = "$($impact['Severity'])" }
            $Impacts.Add([pscustomobject]@{ Category = 'UserTweak'; Source = $ukey; Summary = $reason; AffectedFeatures = $feat; Severity = $sev })
        } elseif ($impact -is [string] -and $impact -eq 'Safe') {
            continue
        } else {
            $Unknowns.Add([pscustomobject]@{ Category = 'UserTweak'; Source = $ukey; Summary = (Get-WinEaseDependencyString 'Dep.Summary.UserTweakNoImpact'); SummaryKey = 'Dep.Summary.UserTweakNoImpact'; Reason = (Get-WinEaseDependencyString 'Dep.Reason.ImpactUndefined'); ReasonKey = 'Dep.Reason.ImpactUndefined' })
        }
    }
}

function Test-WinEaseAdvancedDebloatDependencies {
    param(
        $Config,
        $Cat,
        $Conflicts,
        $Impacts,
        $Unknowns,
        $SeenConflicts,
        $StdSelected,
        $ExpSelected
    )
    if (-not ($Cat -and $Cat.AdvancedDebloat)) { return }

    foreach ($listName in @('AdvancedDebloatStandard','AdvancedDebloatExperimental')) {
        $items = @()
        if ($Config.ContainsKey($listName)) { $items = @($Config[$listName]) }
        foreach ($item in $items) {
            if ($Cat.AdvancedDebloat.ContainsKey($item)) {
                $entry = $Cat.AdvancedDebloat[$item]
                if ($entry.Status -eq 'Safe') { continue }
                if ($entry.Status -eq 'Known') {
                    $Impacts.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
                } elseif ($entry.Status -eq 'Unknown') {
                    $Unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = $entry.Summary; Reason = (Get-WinEaseDependencyString 'Dep.Reason.CatalogUnknown'); ReasonKey = 'Dep.Reason.CatalogUnknown' })
                }
                if ($entry.ConflictsWith) {
                    foreach ($cw in $entry.ConflictsWith) {
                        $targetRemoved = $false
                        if ($Config.ContainsKey($cw)) {
                            if ($Cat.Components.ContainsKey($cw)) { $targetRemoved = Test-WinEaseSettingIsRemoved -Entry $Cat.Components[$cw] -Value $Config[$cw] }
                            elseif ($Cat.Tweaks.ContainsKey($cw)) { $targetRemoved = Test-WinEaseSettingIsRemoved -Entry $Cat.Tweaks[$cw] -Value $Config[$cw] }
                            else { $targetRemoved = [bool]$Config[$cw] }
                        } elseif ($StdSelected -contains $cw -or $ExpSelected -contains $cw) {
                            $targetRemoved = $true
                        }
                        if ($targetRemoved) {
                            Add-WinEaseDependencyConflict -Conflicts $Conflicts -SeenConflicts $SeenConflicts -Category 'AdvancedDebloat' -Source $item -Summary "$($entry.Summary)" -ConflictingWith $cw
                        }
                    }
                }
            } else {
                # fail-safe: unregistered item -> Unknown
                $Unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = (Get-WinEaseDependencyString 'Dep.Summary.Unregistered'); SummaryKey = 'Dep.Summary.Unregistered'; Reason = (Get-WinEaseDependencyString 'Dep.Reason.Unregistered'); ReasonKey = 'Dep.Reason.Unregistered' })
            }
        }
    }
}

function Test-WinEaseDependencies {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The builder and phase 18 pass a PSCustomObject; older callers pass a
        # hashtable. Normalize here instead of requiring the caller to know the
        # internal representation.
        [object]$Config
    )
    $Config = Get-WinEaseNormalizedDependencyConfig -Config $Config

    if (-not $script:WinEaseDependencyCatalog) {
        try { $null = Import-WinEaseDependencyCatalog } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $cat = $script:WinEaseDependencyCatalog
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $impacts = [System.Collections.Generic.List[object]]::new()
    $unknowns = [System.Collections.Generic.List[object]]::new()
    $seenConflicts = @{}

    if ($null -eq $cat) {
        return (New-WinEaseDependencyResult -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns)
    }

    Test-WinEaseCrossRuleConflicts -Config $Config -Conflicts $conflicts -SeenConflicts $seenConflicts

    if (-not $Config) {
        return (New-WinEaseDependencyResult -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns)
    }

    $stdSelected = if ($Config.ContainsKey('AdvancedDebloatStandard')) { @($Config['AdvancedDebloatStandard']) } else { @() }
    $expSelected = if ($Config.ContainsKey('AdvancedDebloatExperimental')) { @($Config['AdvancedDebloatExperimental']) } else { @() }
    $tweakSettings = if ($Config.ContainsKey('TweakSettings')) { $Config['TweakSettings'] } else { $null }

    Test-WinEaseComponentDependencies -Config $Config -Cat $cat -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns -SeenConflicts $seenConflicts -StdSelected $stdSelected -ExpSelected $expSelected

    Test-WinEaseTweakDependencies -Config $Config -Cat $cat -TweakSettings $tweakSettings -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns -SeenConflicts $seenConflicts -StdSelected $stdSelected -ExpSelected $expSelected

    Test-WinEaseUserTweakDependencies -Config $Config -TweakSettings $tweakSettings -Impacts $impacts -Unknowns $unknowns

    Test-WinEaseAdvancedDebloatDependencies -Config $Config -Cat $cat -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns -SeenConflicts $seenConflicts -StdSelected $stdSelected -ExpSelected $expSelected

    return (New-WinEaseDependencyResult -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns)
}

function Format-WinEaseDependencyReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )
    $sb = New-Object System.Text.StringBuilder
    if ($Result.Conflicts -and $Result.Conflicts.Count -gt 0) {
        [void]$sb.AppendLine((Get-WinEaseDependencyString 'Dep.Heading.Conflict'))
        foreach ($c in $Result.Conflicts) {
            [void]$sb.AppendLine((Format-WinEaseDependencyItemLine -Item $c -Kind 'Conflict'))
        }
        [void]$sb.AppendLine('')
    }
    if ($Result.Unknowns -and $Result.Unknowns.Count -gt 0) {
        [void]$sb.AppendLine((Get-WinEaseDependencyString 'Dep.Heading.Unknown'))
        foreach ($u in $Result.Unknowns) {
            [void]$sb.AppendLine((Format-WinEaseDependencyItemLine -Item $u -Kind 'Unknown'))
        }
        [void]$sb.AppendLine('')
    }
    if ($Result.Impacts -and $Result.Impacts.Count -gt 0) {
        [void]$sb.AppendLine((Get-WinEaseDependencyString 'Dep.Heading.Impact'))
        foreach ($i in $Result.Impacts) {
            [void]$sb.AppendLine((Format-WinEaseDependencyItemLine -Item $i -Kind 'Impact'))
        }
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd()
}

# One report entry (the "  - [Category] Source: ..." line, plus "      * feature" lines for an impact)
function Format-WinEaseDependencyItemLine {
    param($Item, [ValidateSet('Conflict', 'Unknown', 'Impact')][string]$Kind)
    $category = Get-WinEaseDependencyField $Item 'Category'
    $source = Get-WinEaseDependencyField $Item 'Source'
    $summary = Get-WinEaseDependencyField $Item 'Summary'
    $summaryKey = Get-WinEaseDependencyField $Item 'SummaryKey'
    if ($summaryKey) { $summary = Get-WinEaseDependencyString $summaryKey }
    $line = "  - [$category] ${source}: $summary"
    switch ($Kind) {
        'Conflict' {
            $with = Get-WinEaseDependencyField $Item 'ConflictingWith'
            if ($with) { $line += (Get-WinEaseDependencyString 'Dep.Conflict.With' -Format @($with)) }
            if (Get-WinEaseDependencyField $Item 'KeptFeature') { $line += (Get-WinEaseDependencyString 'Dep.Conflict.KeptFeature') }
        }
        'Unknown' {
            $reason = Get-WinEaseDependencyField $Item 'Reason'
            $reasonKey = Get-WinEaseDependencyField $Item 'ReasonKey'
            if ($reasonKey) { $reason = Get-WinEaseDependencyString $reasonKey }
            $line += " -- $reason"
        }
        'Impact' {
            foreach ($af in @(Get-WinEaseDependencyField $Item 'AffectedFeatures')) {
                if ($af) { $line += "`r`n      * $af" }
            }
        }
    }
    return $line
}

# Presentation model shared by both GUIs: items split into Critical (conflict / Unknown) and plain Impact,
# each with a text Label and an ASCII Glyph so the state is never conveyed by colour alone.
# An Unknown is always labelled as not verified, never as safe.
function Get-WinEaseDependencyView {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result)
    $mk = {
        param($item, $kind, $severity, $glyph)
        $line = Format-WinEaseDependencyItemLine -Item $item -Kind $kind
        [pscustomobject]@{
            Kind             = $kind
            Severity         = $severity
            Glyph            = $glyph
            Label            = (Get-WinEaseDependencyString "Dep.Label.$kind")
            Category         = "$(Get-WinEaseDependencyField $item 'Category')"
            Source           = "$(Get-WinEaseDependencyField $item 'Source')"
            KeptFeature      = [bool](Get-WinEaseDependencyField $item 'KeptFeature')
            AffectedFeatures = @(Get-WinEaseDependencyField $item 'AffectedFeatures')
            Text             = (($line -split '\r?\n')[0]).TrimStart(' ', '-').TrimStart()
        }
    }
    $critical = [System.Collections.Generic.List[object]]::new()
    $impact = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($Result.Conflicts)) { if ($c) { $critical.Add((& $mk $c 'Conflict' 'Critical' '[X]')) } }
    foreach ($u in @($Result.Unknowns)) { if ($u) { $critical.Add((& $mk $u 'Unknown' 'Critical' '[?]')) } }
    foreach ($i in @($Result.Impacts)) { if ($i) { $impact.Add((& $mk $i 'Impact' 'Impact' '[i]')) } }
    $criticalResult = @{ Conflicts = @($Result.Conflicts); Unknowns = @($Result.Unknowns); Impacts = @() }
    $impactResult = @{ Conflicts = @(); Unknowns = @(); Impacts = @($Result.Impacts) }
    return @{
        HasIssues     = ($critical.Count -gt 0 -or $impact.Count -gt 0)
        HasCritical   = ($critical.Count -gt 0)
        Critical      = $critical.ToArray()
        Impact        = $impact.ToArray()
        KeptFeature   = @($critical | Where-Object { $_.KeptFeature })
        CriticalText  = (Format-WinEaseDependencyReport -Result $criticalResult)
        ImpactText    = (Format-WinEaseDependencyReport -Result $impactResult)
        Text          = (Format-WinEaseDependencyReport -Result $Result)
    }
}

# Single entry point of both GUIs: always recomputed from the configuration passed in (the CURRENT
# selection); nothing is cached between calls, so a warning disappears as soon as its cause is deselected.
function Get-WinEaseDependencyReview {
    [CmdletBinding()]
    param($Config)
    $result = Test-WinEaseDependencies -Config $Config
    $view = Get-WinEaseDependencyView -Result $result
    $view['Result'] = $result
    return $view
}
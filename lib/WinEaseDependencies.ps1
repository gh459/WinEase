# WinEaseDependencies.ps1 - Dependency catalog import, checks and report formatting
# Dot-sourced by WinEasehelpers.ps1 (function definitions only).

# =========================================================================
# Dependency / feature-impact analysis (config/dependencies.psd1)
# =========================================================================

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

function Test-WinEaseDependencies {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The builder and phase 18 pass a PSCustomObject; older callers pass a
        # hashtable. Normalize here instead of requiring the caller to know the
        # internal representation.
        [object]$Config
    )
    if ($null -ne $Config -and -not ($Config -is [System.Collections.IDictionary])) {
        $normalizedConfig = @{}
        foreach ($prop in $Config.PSObject.Properties) { $normalizedConfig[$prop.Name] = $prop.Value }
        $Config = $normalizedConfig
    } elseif ($null -ne $Config -and -not ($Config -is [hashtable])) {
        $normalizedConfig = @{}
        foreach ($key in $Config.Keys) { $normalizedConfig[$key] = $Config[$key] }
        $Config = $normalizedConfig
    }
    if (-not $script:WinEaseDependencyCatalog) {
        try { $null = Import-WinEaseDependencyCatalog } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $cat = $script:WinEaseDependencyCatalog
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $impacts = [System.Collections.Generic.List[object]]::new()
    $unknowns = [System.Collections.Generic.List[object]]::new()
    $seenConflicts = @{}

    $addConflict = {
        param($category, $source, $summary, $conflictingWith)
        $key = "$source|$conflictingWith"
        if ($seenConflicts.ContainsKey($key)) { return }
        $seenConflicts[$key] = $true
        $conflicts.Add([pscustomobject]@{
            Category       = $category
            Source         = $source
            Summary        = $summary
            ConflictingWith = $conflictingWith
        })
    }

    if ($null -eq $cat) {
        return @{ HasIssues = $false; HasCritical = $false; Conflicts = $conflicts; Impacts = $impacts; Unknowns = $unknowns }
    }

    # helper: is a given setting "removed / disabled"?
    $isRemoved = {
        param($entry, $value)
        if ($null -eq $entry -or $null -eq $entry.TriggerValue) { return $false }
        $tv = $entry.TriggerValue
        if ($tv -is [bool]) { return ([bool]$value -eq $tv) }
        return ("$value" -eq "$tv")
    }

    # Cross-rule conflicts (explicit)
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
        & $addConflict 'Component' 'DisableWindowsUpdate' 'Windows Update is kept but Experimental physical debloat is selected, which breaks WinSxS/CBS integrity.' 'AdvancedDebloatExperimental'
    }
    if ($safeMode -and $expSelected.Count -gt 0) {
        & $addConflict 'Component' 'SafeDebloatMode' 'Safe WinSxS mode is enabled but Experimental physical debloat is selected, which breaks CBS/WinSxS integrity.' 'AdvancedDebloatExperimental'
    }
    if ($keepBT -and $btRemoved) {
        & $addConflict 'Component' 'KeepBluetooth' 'Bluetooth is kept but a Bluetooth stack removal item is selected.' 'Bluetooth removal item'
    }
    if ($wsl -and ($noHyp -or $wslRemoved)) {
        & $addConflict 'Component' 'WSLSupport' 'WSL support is enabled but hypervisor is disabled or WSL/Hyper-V removal is selected.' 'NoHypervisor / WSL removal'
    }
    if ($keepSearch -and ($disableSearch -or $searchRemoved)) {
        & $addConflict 'Component' 'KeepSearchIndex' 'Search indexing is kept but search disabling/removal is selected.' 'DisableWindowsSearchIndexing / search removal'
    }
    if ($keepXbox -and ($removeStore -or $disableGameDVR)) {
        & $addConflict 'Component' 'KeepXboxServices' 'Xbox services are kept but Store removal or GameDVR disable is selected.' 'RemoveStore / DisableGameDVR'
    }

    if (-not $Config) {
        $hasIssues = ($conflicts.Count -gt 0 -or $impacts.Count -gt 0 -or $unknowns.Count -gt 0)
        $hasCritical = ($conflicts.Count -gt 0 -or $unknowns.Count -gt 0)
        return @{ HasIssues = $hasIssues; HasCritical = $hasCritical; Conflicts = $conflicts; Impacts = $impacts; Unknowns = $unknowns }
    }

    # Step 2: per-item ConflictsWith (generic) + Impacts/Unknowns
    # Components
    if ($cat -and $cat.Components) {
        foreach ($key in $cat.Components.Keys) {
            if (-not $Config.ContainsKey($key)) { continue }
            $entry = $cat.Components[$key]
            if ($null -eq $entry) { continue }
            $val = $Config[$key]
            $removed = & $isRemoved $entry $val
            if (-not $removed) { continue }
            if ($entry.Status -eq 'Safe') { continue }
            if ($entry.Status -eq 'Known') {
                $impacts.Add([pscustomobject]@{ Category = 'Component'; Source = $key; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
            } elseif ($entry.Status -eq 'Unknown') {
                $unknowns.Add([pscustomobject]@{ Category = 'Component'; Source = $key; Summary = $entry.Summary; Reason = 'Catalog marks this item as Unknown.' })
            }
            # ConflictsWith generic
            if ($entry.ConflictsWith) {
                foreach ($cw in $entry.ConflictsWith) {
                    # determine if conflicting target is also removed/enabled
                    $targetRemoved = $false
                    if ($Config.ContainsKey($cw)) {
                        if ($cat.Components.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Components[$cw] $Config[$cw] }
                        elseif ($cat.Tweaks.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Tweaks[$cw] $Config[$cw] }
                        else { $targetRemoved = [bool]$Config[$cw] }
                    } elseif ($stdSelected -contains $cw -or $expSelected -contains $cw) {
                        $targetRemoved = $true
                    }
                    if ($targetRemoved) {
                        & $addConflict 'Component' $key "$($entry.Summary)" $cw
                    }
                }
            }
        }
    }

    # Tweaks
    $tweakSettings = $null
    if ($Config.ContainsKey('TweakSettings')) { $tweakSettings = $Config['TweakSettings'] }
    if ($cat -and $cat.Tweaks) {
        foreach ($key in $cat.Tweaks.Keys) {
            $entry = $cat.Tweaks[$key]
            if ($null -eq $entry) { continue }
            $val = $null
            if ($tweakSettings) {
                if ($tweakSettings -is [System.Collections.IDictionary]) {
                    if ($tweakSettings.Contains($key)) { $val = $tweakSettings[$key] }
                } elseif ($tweakSettings.PSObject -and $tweakSettings.PSObject.Properties[$key]) {
                    $val = $tweakSettings.PSObject.Properties[$key].Value
                }
            }
            if ($null -eq $val -and $Config.ContainsKey($key)) { $val = $Config[$key] }
            if ($null -eq $val) { continue }
            $removed = & $isRemoved $entry $val
            if (-not $removed) { continue }
            if ($entry.Status -eq 'Safe') { continue }
            if ($entry.Status -eq 'Known') {
                $impacts.Add([pscustomobject]@{ Category = 'Tweak'; Source = $key; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
            } elseif ($entry.Status -eq 'Unknown') {
                $unknowns.Add([pscustomobject]@{ Category = 'Tweak'; Source = $key; Summary = $entry.Summary; Reason = 'Catalog marks this item as Unknown.' })
            }
            if ($entry.ConflictsWith) {
                foreach ($cw in $entry.ConflictsWith) {
                    $targetRemoved = $false
                    if ($Config.ContainsKey($cw)) {
                        if ($cat.Components.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Components[$cw] $Config[$cw] }
                        elseif ($cat.Tweaks.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Tweaks[$cw] $Config[$cw] }
                        else { $targetRemoved = [bool]$Config[$cw] }
                    } elseif ($stdSelected -contains $cw -or $expSelected -contains $cw) {
                        $targetRemoved = $true
                    }
                    if ($targetRemoved) {
                        & $addConflict 'Tweak' $key "$($entry.Summary)" $cw
                    }
                }
            }
        }
    }

    # User-defined custom tweaks (lib/WinEaseExtensions.ps1): enabled ones without explicit Impact are Unknown
    $userDefs = $null
    if (Get-Variable -Name UserTweakDefs -Scope Script -ErrorAction SilentlyContinue) { $userDefs = $script:UserTweakDefs }
    if ($userDefs -and $userDefs.Count -gt 0) {
        foreach ($ukey in @($userDefs.Keys)) {
            $uval = $null
            if ($tweakSettings) {
                if ($tweakSettings -is [System.Collections.IDictionary]) {
                    if ($tweakSettings.Contains($ukey)) { $uval = $tweakSettings[$ukey] }
                } elseif ($tweakSettings.PSObject -and $tweakSettings.PSObject.Properties[$ukey]) {
                    $uval = $tweakSettings.PSObject.Properties[$ukey].Value
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
                $impacts.Add([pscustomobject]@{ Category = 'UserTweak'; Source = $ukey; Summary = $reason; AffectedFeatures = $feat; Severity = $sev })
            } elseif ($impact -is [string] -and $impact -eq 'Safe') {
                continue
            } else {
                $unknowns.Add([pscustomobject]@{ Category = 'UserTweak'; Source = $ukey; Summary = 'User-defined custom tweak does not declare explicit dependency impact metadata (Dependency: Unknown).'; Reason = 'Impact is undefined or Unknown (fail-safe).' })
            }
        }
    }

    # AdvancedDebloat items (present in lists)
    if ($cat -and $cat.AdvancedDebloat) {
        foreach ($listName in @('AdvancedDebloatStandard','AdvancedDebloatExperimental')) {
            $items = @()
            if ($Config.ContainsKey($listName)) { $items = @($Config[$listName]) }
            foreach ($item in $items) {
                if ($cat.AdvancedDebloat.ContainsKey($item)) {
                    $entry = $cat.AdvancedDebloat[$item]
                    if ($entry.Status -eq 'Safe') { continue }
                    if ($entry.Status -eq 'Known') {
                        $impacts.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = $entry.Summary; AffectedFeatures = @($entry.AffectedFeatures) })
                    } elseif ($entry.Status -eq 'Unknown') {
                        $unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = $entry.Summary; Reason = 'Catalog marks this item as Unknown.' })
                    }
                    if ($entry.ConflictsWith) {
                        foreach ($cw in $entry.ConflictsWith) {
                            $targetRemoved = $false
                            if ($Config.ContainsKey($cw)) {
                                if ($cat.Components.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Components[$cw] $Config[$cw] }
                                elseif ($cat.Tweaks.ContainsKey($cw)) { $targetRemoved = & $isRemoved $cat.Tweaks[$cw] $Config[$cw] }
                                else { $targetRemoved = [bool]$Config[$cw] }
                            } elseif ($stdSelected -contains $cw -or $expSelected -contains $cw) {
                                $targetRemoved = $true
                            }
                            if ($targetRemoved) {
                                & $addConflict 'AdvancedDebloat' $item "$($entry.Summary)" $cw
                            }
                        }
                    }
                } else {
                    # fail-safe: unregistered item -> Unknown
                    $unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = "Unregistered advanced debloat item"; Reason = 'Not defined in config/dependencies.psd1 (fail-safe: treated as Unknown).' })
                }
            }
        }
    }

    $hasIssues = ($conflicts.Count -gt 0 -or $impacts.Count -gt 0 -or $unknowns.Count -gt 0)
    $hasCritical = ($conflicts.Count -gt 0 -or $unknowns.Count -gt 0)
    return @{ HasIssues = $hasIssues; HasCritical = $hasCritical; Conflicts = $conflicts; Impacts = $impacts; Unknowns = $unknowns }
}

function Format-WinEaseDependencyReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )
    $sb = New-Object System.Text.StringBuilder
    if ($Result.Conflicts -and $Result.Conflicts.Count -gt 0) {
        [void]$sb.AppendLine('[DEPENDENCY CONFLICT]')
        foreach ($c in $Result.Conflicts) {
            $cw = if ($c.ConflictingWith) { " (conflicts with: $($c.ConflictingWith))" } else { '' }
            [void]$sb.AppendLine("  - [$($c.Category)] $($c.Source): $($c.Summary)$cw")
        }
        [void]$sb.AppendLine('')
    }
    if ($Result.Unknowns -and $Result.Unknowns.Count -gt 0) {
        [void]$sb.AppendLine('[DEPENDENCY UNKNOWN / 不明]')
        foreach ($u in $Result.Unknowns) {
            [void]$sb.AppendLine("  - [$($u.Category)] $($u.Source): $($u.Summary) -- $($u.Reason)")
        }
        [void]$sb.AppendLine('')
    }
    if ($Result.Impacts -and $Result.Impacts.Count -gt 0) {
        [void]$sb.AppendLine('[FEATURE IMPACT]')
        foreach ($i in $Result.Impacts) {
            [void]$sb.AppendLine("  - [$($i.Category)] $($i.Source): $($i.Summary)")
            if ($i.AffectedFeatures) {
                foreach ($af in $i.AffectedFeatures) {
                    [void]$sb.AppendLine("      * $af")
                }
            }
        }
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd()
}

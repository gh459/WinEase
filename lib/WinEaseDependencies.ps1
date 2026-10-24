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
    if (Get-Command -Name Get-WinEaseUiString -ErrorAction SilentlyContinue) {
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
        param($category, $source, $summary, $conflictingWith, $keptFeature = $false)
        $key = "$source|$conflictingWith"
        if ($seenConflicts.ContainsKey($key)) { return }
        $seenConflicts[$key] = $true
        $conflicts.Add([pscustomobject]@{
            Category       = $category
            Source         = $source
            Summary        = $summary
            ConflictingWith = $conflictingWith
            KeptFeature    = [bool]$keptFeature
        })
    }

    if ($null -eq $cat) {
        return (New-WinEaseDependencyResult -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns)
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
        & $addConflict 'Component' 'DisableWindowsUpdate' 'Windows Update is kept but Experimental physical debloat is selected, which breaks WinSxS/CBS integrity.' 'AdvancedDebloatExperimental' $true
    }
    if ($safeMode -and $expSelected.Count -gt 0) {
        & $addConflict 'Component' 'SafeDebloatMode' 'Safe WinSxS mode is enabled but Experimental physical debloat is selected, which breaks CBS/WinSxS integrity.' 'AdvancedDebloatExperimental' $true
    }
    if ($keepBT -and $btRemoved) {
        & $addConflict 'Component' 'KeepBluetooth' 'Bluetooth is kept but a Bluetooth stack removal item is selected.' 'Bluetooth removal item' $true
    }
    if ($wsl -and ($noHyp -or $wslRemoved)) {
        & $addConflict 'Component' 'WSLSupport' 'WSL support is enabled but hypervisor is disabled or WSL/Hyper-V removal is selected.' 'NoHypervisor / WSL removal' $true
    }
    if ($keepSearch -and ($disableSearch -or $searchRemoved)) {
        & $addConflict 'Component' 'KeepSearchIndex' 'Search indexing is kept but search disabling/removal is selected.' 'DisableWindowsSearchIndexing / search removal' $true
    }
    if ($keepXbox -and ($removeStore -or $disableGameDVR)) {
        & $addConflict 'Component' 'KeepXboxServices' 'Xbox services are kept but Store removal or GameDVR disable is selected.' 'RemoveStore / DisableGameDVR' $true
    }

    if (-not $Config) {
        return (New-WinEaseDependencyResult -Conflicts $conflicts -Impacts $impacts -Unknowns $unknowns)
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
                $unknowns.Add([pscustomobject]@{ Category = 'Component'; Source = $key; Summary = $entry.Summary; Reason = (Get-WinEaseDependencyString 'Dep.Reason.CatalogUnknown'); ReasonKey = 'Dep.Reason.CatalogUnknown' })
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
                $unknowns.Add([pscustomobject]@{ Category = 'Tweak'; Source = $key; Summary = $entry.Summary; Reason = (Get-WinEaseDependencyString 'Dep.Reason.CatalogUnknown'); ReasonKey = 'Dep.Reason.CatalogUnknown' })
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
                $unknowns.Add([pscustomobject]@{ Category = 'UserTweak'; Source = $ukey; Summary = (Get-WinEaseDependencyString 'Dep.Summary.UserTweakNoImpact'); SummaryKey = 'Dep.Summary.UserTweakNoImpact'; Reason = (Get-WinEaseDependencyString 'Dep.Reason.ImpactUndefined'); ReasonKey = 'Dep.Reason.ImpactUndefined' })
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
                        $unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = $entry.Summary; Reason = (Get-WinEaseDependencyString 'Dep.Reason.CatalogUnknown'); ReasonKey = 'Dep.Reason.CatalogUnknown' })
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
                    $unknowns.Add([pscustomobject]@{ Category = 'AdvancedDebloat'; Source = $item; Summary = (Get-WinEaseDependencyString 'Dep.Summary.Unregistered'); SummaryKey = 'Dep.Summary.Unregistered'; Reason = (Get-WinEaseDependencyString 'Dep.Reason.Unregistered'); ReasonKey = 'Dep.Reason.Unregistered' })
                }
            }
        }
    }

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
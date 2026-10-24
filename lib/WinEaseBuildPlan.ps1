# WinEaseBuildPlan.ps1 - the pre-build change preview ("build plan") shared by both GUI windows and the builder.
# Function definitions only. See docs\BUILD_PREVIEW.md.
#
# Get-WinEaseBuildPlan   GUI result -> plan (pure: no UI, no state, recomputed on every call, nothing cached)
# Get-WinEaseBuildPlanView  plan -> localized sections / plain text both windows render
# Compare-WinEaseBuildPlanToSettings  plan vs the settings the builder resolved (mismatch detection)
# Write-WinEaseBuildPlanSummary  plan -> logs\*.plan.json / *.plan.txt
#
# The rules come from config\schema.psd1 (via Get-WinEaseGuiPresetValues / Get-WinEaseGuiPresetState in
# WinEaseGuiCore.ps1), config\dependencies.psd1 (via Get-WinEaseDependencyReview) and nothing else.
# A value whose impact or origin cannot be resolved goes to "Unverified", never to "Unchanged".

# Free space the builder recommends on the work volume (Invoke-WinEaseHostHealthCheck warns below this)
function Get-WinEaseRecommendedFreeGB { return 40 }

# Output image size estimate in MB (the figure both windows show as "Estimated size"); -Components is
# a hashtable of component key -> bool, -PayloadFormat is WIM / ESD / SWM.
function Get-WinEaseBuildSizeEstimateMB {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Components', Justification = 'Read inside script blocks the analyzer does not follow')]
    param($Components, [string]$PayloadFormat = 'WIM')
    $on = { param($k) ($null -ne $Components) -and (Get-WinEaseBuildPlanValue $Components $k) -eq $true }
    $has = { param($k) ($null -ne $Components) -and ($null -ne (Get-WinEaseBuildPlanValue $Components $k)) }
    $mb = 5500.0
    if (& $on 'KeepExtraFonts') { $mb += 150 }
    if (& $on 'KeepAsianIME') { $mb += 400 }
    if ((& $has 'RemoveDefender') -and -not (& $on 'RemoveDefender')) { $mb += 200 }
    if ((& $has 'RemoveStore') -and -not (& $on 'RemoveStore')) { $mb += 120 }
    if ((& $has 'DisableWindowsUpdate') -and -not (& $on 'DisableWindowsUpdate')) { $mb += 50 }
    if (& $on 'KeepBasicApps') { $mb += 30 }
    if (& $on 'KeepSearchIndex') { $mb += 20 }
    if (& $on 'KeepXboxServices') { $mb += 40 }
    if (& $on 'RemoveDrivers') { $mb -= 80 }
    if (& $on 'UltraSlimMode') { $mb -= 200 }
    if ("$PayloadFormat".ToUpper() -eq 'ESD') { $mb = [math]::Round($mb * 0.82) }
    return $mb
}

# Value of a key in a hashtable or an object (ConvertFrom-Json); $null when absent. Self-contained so the
# builder can compare a plan without the GUI core loaded.
function Get-WinEaseBuildPlanValue {
    param($Object, [string]$Key)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Key)) { return $Object[$Key] } else { return $null } }
    $p = $Object.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    return $null
}

# Free bytes of the volume holding -Path; $null when it cannot be determined (UNC path, unknown drive, error)
function Get-WinEaseVolumeFreeBytes {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if (-not $root -or $root.StartsWith('\\')) { return $null }
        $drive = New-Object System.IO.DriveInfo($root)
        if (-not $drive.IsReady) { return $null }
        return [int64]$drive.AvailableFreeSpace
    } catch { return $null }
}

# Dependency catalog entry (Components / Tweaks / AdvancedDebloat) of a setting, or $null
function Get-WinEaseBuildPlanCatalogEntry {
    param([string]$Source)
    $cat = $script:WinEaseDependencyCatalog
    if (-not $cat -and (Get-Command -Name Import-WinEaseDependencyCatalog -ErrorAction SilentlyContinue)) {
        try { $cat = Import-WinEaseDependencyCatalog } catch { $cat = $null }
    }
    if (-not $cat) { return $null }
    foreach ($section in @('Components', 'Tweaks', 'AdvancedDebloat')) {
        $s = $cat[$section]
        if ($s -and $s.ContainsKey($Source)) { return $s[$Source] }
    }
    return $null
}

function ConvertTo-WinEaseBuildPlanBool {
    param($Value)
    if ($Value -is [string]) { return ($Value -match '^(1|true|yes|on)$') }
    return [bool]$Value
}

# -Result  the GUI result (flat: component keys at the top level, as Show-WinEaseGUI returns it; a nested
#          'Components' object is accepted too).
# -FreeSpaceProvider  scriptblock { param($Path) } returning free bytes or $null (default: Get-WinEaseVolumeFreeBytes)
# -OutputDir / -OutputIsoName / -EditionName  what the builder will use / what is known about the image
function Get-WinEaseBuildPlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Result', Justification = 'Read inside script blocks the analyzer does not follow')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Result,
        [scriptblock]$FreeSpaceProvider = { param($Path) Get-WinEaseVolumeFreeBytes -Path $Path },
        [string]$OutputDir,
        [string]$OutputIsoName,
        [string]$EditionName,
        $DependencyReview
    )
    foreach ($need in 'Get-WinEaseGuiPresetValues', 'Get-WinEaseGuiPresetState', 'Get-WinEaseDependencyReview') {
        if (-not (Get-Command -Name $need -ErrorAction SilentlyContinue)) { throw "Get-WinEaseBuildPlan needs $need (WinEaseGuiCore.ps1 / WinEaseDependencies.ps1)." }
    }
    $g = { param($k) Get-WinEaseBuildPlanValue $Result $k }

    # Flat view of the settings (what the builder applies): components, tweaks, payload, debloat
    $components = [ordered]@{}
    $nested = & $g 'Components'
    if ($nested) {
        $nkeys = if ($nested -is [System.Collections.IDictionary]) { @($nested.Keys) } else { @($nested.PSObject.Properties.Name) }
        foreach ($k in $nkeys) { $v = Get-WinEaseBuildPlanValue $nested $k; if ($v -is [bool]) { $components["$k"] = $v } }
    }
    foreach ($cd in $script:ComponentDefs.Values) {
        if ($cd.Gui) { $v = & $g $cd.Key; if ($null -ne $v) { $components[$cd.Key] = [bool]$v } }
    }
    $tweaks = [ordered]@{}
    $rawTweaks = & $g 'TweakSettings'
    if ($rawTweaks) {
        $tkeys = if ($rawTweaks -is [System.Collections.IDictionary]) { @($rawTweaks.Keys) } else { @($rawTweaks.PSObject.Properties.Name) }
        foreach ($k in $tkeys) { $tweaks["$k"] = [bool](Get-WinEaseBuildPlanValue $rawTweaks $k) }
    }
    $payload = if (ConvertTo-WinEaseBuildPlanBool (& $g 'ExportESDMode')) { 'ESD' } elseif (ConvertTo-WinEaseBuildPlanBool (& $g 'SplitWIMMode')) { 'SWM' } else { 'WIM' }
    $dryRun = ConvertTo-WinEaseBuildPlanBool (& $g 'DryRun')
    $consent = ConvertTo-WinEaseBuildPlanBool (& $g 'PhysicalDebloatConsent')
    $useVhdx = ConvertTo-WinEaseBuildPlanBool (& $g 'UseVHDX')
    $stdSel = @(@(& $g 'AdvancedDebloatStandard') | Where-Object { $_ } | ForEach-Object { "$_" })
    $expSel = @(@(& $g 'AdvancedDebloatExperimental') | Where-Object { $_ } | ForEach-Object { "$_" })
    $engines = & $g 'DebloatEngineSelection'

    $changed = [System.Collections.Generic.List[object]]::new()
    $unchanged = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $unverified = [System.Collections.Generic.List[object]]::new()
    $criticals = [System.Collections.Generic.List[object]]::new()

    # --- preset and the Changed / Unchanged split (the rule is Get-WinEaseGuiPresetState) ---
    $baseKey = "$(& $g 'BasePresetKey')".Trim().ToLower()
    $presetKey = "$(& $g 'PresetKey')"
    $current = @{ Components = $components; TweakSettings = $tweaks; PayloadFormat = $payload; AdvancedDebloatStandard = $stdSel; AdvancedDebloatExperimental = $expSel }
    if ($engines) { $current['DebloatEngineSelection'] = $engines }
    $baseValues = if ($baseKey) { Get-WinEaseGuiPresetValues -Name $baseKey } else { $null }
    $presetState = 'Custom'
    $diffCount = 0
    if ($baseValues) {
        $st = Get-WinEaseGuiPresetState -BasePresetKey $baseKey -Current $current -BaseValues $baseValues
        $presetState = "$($st.State)"
        $diffCount = @($st.Differences).Count
        foreach ($d in @($st.Differences)) {
            $changed.Add([ordered]@{ Key = "$($d.Key)"; Kind = "$($d.Kind)"; Preset = "$($d.Preset)"; Current = "$($d.Current)" })
        }
        $diffKeys = @($st.DifferingKeys)
        foreach ($k in $baseValues.Components.Keys) { if ($components.Contains($k) -and ($diffKeys -notcontains $k)) { $unchanged.Add("$k") } }
        foreach ($k in $baseValues.Tweaks.Keys) { if ($tweaks.Contains($k) -and ($diffKeys -notcontains $k)) { $unchanged.Add("$k") } }
        if ($diffKeys -notcontains 'PayloadFormat') { $unchanged.Add('PayloadFormat') }
        foreach ($k in $components.Keys) {
            if (-not $baseValues.Components.Contains($k)) { $skipped.Add([ordered]@{ Key = "$k"; ReasonKey = 'Plan.Skipped.NotInPreset'; Value = "$($components[$k])" }) }
        }
    } else {
        $unverified.Add([ordered]@{ Key = 'Preset'; ReasonKey = 'Plan.Unverified.NoPreset'; Value = $(if ($baseKey) { $baseKey } else { '' }) })
    }

    # --- settings the schema does not know ---
    foreach ($k in $tweaks.Keys) {
        if (-not $script:AllTweakDefs.Contains($k)) { $unverified.Add([ordered]@{ Key = "$k"; ReasonKey = 'Plan.Unverified.UnknownTweak'; Value = "$($tweaks[$k])" }) }
    }
    $known = @($script:WinEaseDebloatStandardItems) + @($script:WinEaseDebloatExperimentalItems)
    foreach ($i in @($stdSel + $expSel | Select-Object -Unique)) {
        if ($known -notcontains $i) { $unverified.Add([ordered]@{ Key = "$i"; ReasonKey = 'Plan.Unverified.UnknownDebloat'; Value = '' }) }
    }

    # --- Advanced Debloat without consent is dropped by the build ---
    $debloatCount = $stdSel.Count + $expSel.Count
    $effStd = $stdSel; $effExp = $expSel
    if ($debloatCount -gt 0 -and -not $consent) {
        foreach ($i in @($stdSel + $expSel)) { $skipped.Add([ordered]@{ Key = "$i"; ReasonKey = 'Plan.Skipped.NoConsent'; Value = '' }) }
        $effStd = @(); $effExp = @()
    } elseif ($debloatCount -gt 0) {
        $criticals.Add([ordered]@{ Code = 'PhysicalDebloat'; TextKey = 'Plan.Critical.PhysicalDebloat'; Args = @($stdSel.Count, $expSel.Count) })
    }

    # --- dependency review (B2) of what will really run ---
    $cfg = @{ TweakSettings = $tweaks; AdvancedDebloatStandard = $effStd; AdvancedDebloatExperimental = $effExp }
    foreach ($k in $components.Keys) { $cfg[$k] = $components[$k] }
    $review = if ($DependencyReview) { $DependencyReview } else { Get-WinEaseDependencyReview -Config $cfg }
    $dangerous = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($review.Critical) + @($review.Impact)) {
        if (-not $row) { continue }
        $entry = Get-WinEaseBuildPlanCatalogEntry -Source "$($row.Source)"
        $rev = 'Undocumented'; $recovery = ''
        if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('Reversible') -and $null -ne $entry['Reversible']) {
            $rev = if ([bool]$entry['Reversible']) { 'Reversible' } else { 'Irreversible' }
            if ($entry.Contains('Recovery')) { $recovery = "$($entry['Recovery'])" }
        }
        $dangerous.Add([ordered]@{
            Key = "$($row.Source)"; Kind = "$($row.Kind)"; Severity = "$($row.Severity)"; Label = "$($row.Label)"
            Impact = "$($row.Text)"; AffectedFeatures = @($row.AffectedFeatures | Where-Object { $_ } | ForEach-Object { "$_" })
            Reversibility = $rev; Recovery = $recovery
        })
        if ("$($row.Kind)" -eq 'Unknown') {
            $unverified.Add([ordered]@{ Key = "$($row.Source)"; ReasonKey = 'Plan.Unverified.DependencyUnknown'; Value = "$($row.Text)" })
        }
    }
    if ($review.HasCritical) { $criticals.Add([ordered]@{ Code = 'DependencyCritical'; TextKey = 'Plan.Critical.Dependency'; Args = @(@($review.Critical).Count) }) }
    if (@($dangerous | Where-Object { $_.Reversibility -eq 'Irreversible' }).Count -gt 0) {
        $criticals.Add([ordered]@{ Code = 'Irreversible'; TextKey = 'Plan.Critical.Irreversible'; Args = @((@($dangerous | Where-Object { $_.Reversibility -eq 'Irreversible' }) | ForEach-Object { $_.Key }) -join ', ') })
    }

    # --- paths, output, disk ---
    $source = "$(& $g 'SourceDrive')".Trim()
    $workDir = "$(& $g 'WorkDir')".Trim()
    $workIsDefault = $false
    if (-not $workDir) { $workDir = if (Get-Command -Name Get-WinEaseGuiDefaultWorkDir -ErrorAction SilentlyContinue) { Get-WinEaseGuiDefaultWorkDir } else { '' }; $workIsDefault = $true }
    if (-not $OutputDir) { $OutputDir = if ($script:WinEaseGuiRepoRoot) { $script:WinEaseGuiRepoRoot } else { (Get-Location).Path } }
    $slug = if ($presetKey) { ($presetKey -replace '[^\w\-]', '_').Trim('_') } else { 'custom' }
    $outputName = if ($OutputIsoName) { $(if ($OutputIsoName.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) { $OutputIsoName } else { "$OutputIsoName.iso" }) } else { "WinEase_${slug}_<timestamp>.iso" }
    $estimateGB = [math]::Round((Get-WinEaseBuildSizeEstimateMB -Components $components -PayloadFormat $payload) / 1024, 2)
    $needs = @(
        [ordered]@{ Role = 'Work'; Path = $workDir; RequiredGB = [double](Get-WinEaseRecommendedFreeGB) }
        [ordered]@{ Role = 'Output'; Path = $OutputDir; RequiredGB = $estimateGB }
    )
    # Needs on the same volume add up
    $disk = [System.Collections.Generic.List[object]]::new()
    $byVolume = [ordered]@{}
    foreach ($n in $needs) {
        $vol = ''
        try { $vol = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($n.Path)).ToUpper() } catch { $vol = '' }
        if (-not $byVolume.Contains($vol)) { $byVolume[$vol] = [ordered]@{ Volume = $vol; Paths = @(); Roles = @(); RequiredGB = 0.0 } }
        $byVolume[$vol].Paths += $n.Path; $byVolume[$vol].Roles += $n.Role; $byVolume[$vol].RequiredGB += $n.RequiredGB
    }
    foreach ($v in $byVolume.Values) {
        $free = $null
        try { $free = & $FreeSpaceProvider $v.Paths[0] } catch { $free = $null }
        $freeGB = if ($null -ne $free) { [math]::Round([double]$free / 1GB, 1) } else { $null }
        $status = if ($null -eq $freeGB) { 'Unknown' } elseif ($freeGB -lt $v.RequiredGB) { 'Insufficient' } else { 'Ok' }
        $disk.Add([ordered]@{ Volume = $v.Volume; Roles = @($v.Roles); Paths = @($v.Paths); RequiredGB = [math]::Round($v.RequiredGB, 1); FreeGB = $freeGB; Status = $status })
        if ($status -eq 'Unknown') { $unverified.Add([ordered]@{ Key = "Disk $($v.Volume)"; ReasonKey = 'Plan.Unverified.DiskUnknown'; Value = '' }) }
        elseif ($status -eq 'Insufficient') { $criticals.Add([ordered]@{ Code = 'DiskInsufficient'; TextKey = 'Plan.Critical.Disk'; Args = @($v.Volume, $freeGB, [math]::Round($v.RequiredGB, 1)) }) }
    }

    # Something that is not verified is never reported as unchanged / OK
    $unverifiedKeys = @($unverified | ForEach-Object { $_.Key })
    $unchangedKept = @($unchanged | Where-Object { $unverifiedKeys -notcontains $_ })

    return [ordered]@{
        IsDryRun          = $dryRun
        Mode              = $(if ($dryRun) { 'DryRun' } else { 'RealBuild' })
        Source            = $source
        Index             = "$(& $g 'Index')".Trim()
        EditionName       = $EditionName
        WorkDir           = $workDir
        WorkDirIsDefault  = $workIsDefault
        OutputDir         = $OutputDir
        OutputName        = $outputName
        PayloadFormat     = $payload
        UseVHDX           = $useVhdx
        PresetKey         = $presetKey
        BasePresetKey     = $baseKey
        PresetState       = $presetState
        DifferenceCount   = $diffCount
        Changed           = @($changed)
        Unchanged         = $unchangedKept
        Skipped           = @($skipped)
        Unverified        = @($unverified)
        Dangerous         = @($dangerous)
        Dependency        = [ordered]@{ HasIssues = [bool]$review.HasIssues; HasCritical = [bool]$review.HasCritical; CriticalCount = @($review.Critical).Count; ImpactCount = @($review.Impact).Count }
        Disk              = @($disk)
        EstimatedSizeGB   = $estimateGB
        Criticals         = @($criticals)
        HasCritical       = ($criticals.Count -gt 0)
        # A dry run changes nothing, so it never needs the acknowledgement; a real build does when anything is critical
        RequiresAck       = ((-not $dryRun) -and $criticals.Count -gt 0)
        # What the builder must end up with (Compare-WinEaseBuildPlanToSettings); a declined consent already dropped the debloat lists
        Effective         = [ordered]@{
            Components = $components; TweakSettings = $tweaks; PayloadFormat = $payload; UseVHDX = $useVhdx; DryRun = $dryRun
            AllowPhysicalDebloat = ($consent -and $debloatCount -gt 0)
            AdvancedDebloatStandard = @($effStd); AdvancedDebloatExperimental = @($effExp)
        }
    }
}

# Localized view of a plan: Sections (Heading / Severity / Lines) for the WinUI dialog, Text for WinForms.
function Get-WinEaseBuildPlanView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Plan', Justification = 'Read inside script blocks the analyzer does not follow')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)
    $s = { param($key, $fmt) if ($null -ne $fmt) { Get-WinEaseUiString $key -Format @($fmt) } else { Get-WinEaseUiString $key } }
    $p = { param($k) Get-WinEaseBuildPlanValue $Plan $k }
    $sections = [System.Collections.Generic.List[object]]::new()
    $add = { param($heading, $severity, $lines) $sections.Add([ordered]@{ Heading = $heading; Severity = $severity; Lines = @($lines | Where-Object { $null -ne $_ } | ForEach-Object { "$_" }) }) }
    $unknown = & $s 'Plan.Value.Unknown'
    $orUnknown = { param($v) if ([string]::IsNullOrWhiteSpace("$v")) { $unknown } else { "$v" } }

    $isDry = [bool](& $p 'IsDryRun')
    $modeText = if ($isDry) { & $s 'Plan.Mode.Dry' } else { & $s 'Plan.Mode.Real' }
    $presetLine = switch ("$(& $p 'PresetState')") {
        'Preset' { & $s 'Plan.Preset.Unmodified' (& $p 'BasePresetKey') }
        'Modified' { & $s 'Plan.Preset.Modified' @((& $p 'BasePresetKey'), (& $p 'DifferenceCount')) }
        default { & $s 'Plan.Preset.Custom' }
    }
    $payloadNote = if ([bool](& $p 'UseVHDX')) { (& $s 'Plan.Line.Payload' ((& $p 'PayloadFormat'))) + ' + ' + (& $s 'Plan.Value.Vhdx') } else { & $s 'Plan.Line.Payload' ((& $p 'PayloadFormat')) }
    $edition = & $orUnknown (& $p 'EditionName')
    $idx = if ((& $p 'Index')) { "$(& $p 'Index')" } else { & $s 'Plan.Value.DefaultIndex' }
    $workText = "$(& $p 'WorkDir')"
    if ([bool](& $p 'WorkDirIsDefault')) { $workText += ' ' + (& $s 'Plan.Value.DefaultFolder') }
    & $add (& $s 'Plan.Section.Overview') 'Info' @(
        (& $s 'Plan.Line.Source' (& $orUnknown (& $p 'Source'))),
        (& $s 'Plan.Line.Edition' @($idx, $edition)),
        (& $s 'Plan.Line.WorkDir' $workText),
        (& $s 'Plan.Line.Output' @((& $p 'OutputDir'), (& $p 'OutputName'))),
        $payloadNote,
        $presetLine
    )

    $changedLines = @(foreach ($c in @(& $p 'Changed')) { & $s 'Plan.Line.Changed' @((Get-WinEaseBuildPlanValue $c 'Key'), (Get-WinEaseBuildPlanValue $c 'Preset'), (Get-WinEaseBuildPlanValue $c 'Current')) })
    if ($changedLines.Count -eq 0) { $changedLines = @(& $s 'Plan.Line.None') }
    & $add (& $s 'Plan.Section.Changed' @(@(& $p 'Changed').Count)) 'Info' $changedLines

    $unch = @(& $p 'Unchanged')
    & $add (& $s 'Plan.Section.Unchanged' @($unch.Count)) 'Info' @($(if ($unch.Count -gt 0) { $unch -join ', ' } else { & $s 'Plan.Line.None' }))

    $skipLines = @(foreach ($k in @(& $p 'Skipped')) { & $s 'Plan.Line.Reason' @((Get-WinEaseBuildPlanValue $k 'Key'), (& $s (Get-WinEaseBuildPlanValue $k 'ReasonKey'))) })
    if ($skipLines.Count -eq 0) { $skipLines = @(& $s 'Plan.Line.None') }
    & $add (& $s 'Plan.Section.Skipped' @(@(& $p 'Skipped').Count)) 'Info' $skipLines

    $unvLines = @(foreach ($k in @(& $p 'Unverified')) {
        $val = "$(Get-WinEaseBuildPlanValue $k 'Value')"
        $reason = & $s (Get-WinEaseBuildPlanValue $k 'ReasonKey')
        if ($val -and (Get-WinEaseBuildPlanValue $k 'ReasonKey') -eq 'Plan.Unverified.DependencyUnknown') { $reason += " $val" }
        & $s 'Plan.Line.Reason' @((Get-WinEaseBuildPlanValue $k 'Key'), $reason)
    })
    if ($unvLines.Count -eq 0) { $unvLines = @(& $s 'Plan.Line.None') }
    & $add (& $s 'Plan.Section.Unverified' @(@(& $p 'Unverified').Count)) $(if (@(& $p 'Unverified').Count -gt 0) { 'Warning' } else { 'Info' }) $unvLines

    $dangerLines = [System.Collections.Generic.List[string]]::new()
    foreach ($d in @(& $p 'Dangerous')) {
        $dangerLines.Add((& $s 'Plan.Line.Danger' @((Get-WinEaseBuildPlanValue $d 'Label'), (Get-WinEaseBuildPlanValue $d 'Key'), (Get-WinEaseBuildPlanValue $d 'Impact'))))
        foreach ($af in @(Get-WinEaseBuildPlanValue $d 'AffectedFeatures')) { $dangerLines.Add("      * $af") }
        $rev = switch ("$(Get-WinEaseBuildPlanValue $d 'Reversibility')") { 'Reversible' { & $s 'Plan.Rev.Reversible' } 'Irreversible' { & $s 'Plan.Rev.Irreversible' } default { & $s 'Plan.Rev.Undocumented' } }
        $rec = "$(Get-WinEaseBuildPlanValue $d 'Recovery')"
        $dangerLines.Add('      ' + (& $s 'Plan.Line.Reversibility' $rev) + $(if ($rec) { " - $rec" } else { '' }))
    }
    if ($dangerLines.Count -eq 0) { $dangerLines.Add((& $s 'Plan.Line.None')) }
    & $add (& $s 'Plan.Section.Dangerous' @(@(& $p 'Dangerous').Count)) $(if (@(& $p 'Dangerous').Count -gt 0) { 'Warning' } else { 'Info' }) $dangerLines

    $diskLines = @(foreach ($d in @(& $p 'Disk')) {
        $free = Get-WinEaseBuildPlanValue $d 'FreeGB'
        $freeText = if ($null -eq $free) { $unknown } else { "$free GB" }
        $status = switch ("$(Get-WinEaseBuildPlanValue $d 'Status')") { 'Ok' { & $s 'Plan.Disk.Ok' } 'Insufficient' { & $s 'Plan.Disk.Insufficient' } default { & $s 'Plan.Disk.Unknown' } }
        & $s 'Plan.Line.Disk' @((Get-WinEaseBuildPlanValue $d 'Volume'), (@(Get-WinEaseBuildPlanValue $d 'Roles') -join '+'), (Get-WinEaseBuildPlanValue $d 'RequiredGB'), $freeText, $status)
    })
    $diskSev = if (@(@(& $p 'Disk') | Where-Object { (Get-WinEaseBuildPlanValue $_ 'Status') -eq 'Insufficient' }).Count -gt 0) { 'Critical' } elseif (@(@(& $p 'Disk') | Where-Object { (Get-WinEaseBuildPlanValue $_ 'Status') -eq 'Unknown' }).Count -gt 0) { 'Warning' } else { 'Info' }
    & $add (& $s 'Plan.Section.Disk') $diskSev $diskLines

    $critLines = @(foreach ($c in @(& $p 'Criticals')) { & $s (Get-WinEaseBuildPlanValue $c 'TextKey') @(Get-WinEaseBuildPlanValue $c 'Args') })
    if ($critLines.Count -gt 0) { & $add (& $s 'Plan.Section.Critical') 'Critical' $critLines }

    $needAck = [bool](& $p 'RequiresAck')
    $ackText = if ($needAck) { & $s 'Plan.Ack.Checkbox' } else { '' }
    $textParts = [System.Collections.Generic.List[string]]::new()
    $textParts.Add($modeText); $textParts.Add('')
    foreach ($sec in $sections) { $textParts.Add("== $($sec.Heading) =="); foreach ($l in $sec.Lines) { $textParts.Add($l) }; $textParts.Add('') }
    return [ordered]@{
        Title = (& $s 'Plan.Title'); ModeText = $modeText; IsDryRun = $isDry
        ConfirmText = $(if ($isDry) { & $s 'Plan.Confirm.Dry' } else { & $s 'Plan.Confirm.Real' })
        RequiresAck = $needAck; AckText = $ackText; HasCritical = [bool](& $p 'HasCritical')
        Sections = @($sections); Text = ($textParts -join "`r`n").TrimEnd()
    }
}

# Plan vs the settings the builder resolved. -Resolved: hashtable / object with the component keys, TweakSettings,
# PayloadFormat, AdvancedDebloatStandard / Experimental, UseVHDX, DryRun, AllowPhysicalDebloat (only keys present in
# BOTH sides are compared). A mismatch of a build option, a debloat list or a setting the dependency catalog marks
# Known/Unknown is Critical.
function Compare-WinEaseBuildPlanToSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan, [Parameter(Mandatory = $true)]$Resolved)
    $eff = Get-WinEaseBuildPlanValue $Plan 'Effective'
    $mismatches = [System.Collections.Generic.List[object]]::new()
    $add = { param($k, $pv, $rv, $crit) $mismatches.Add([pscustomobject]@{ Key = $k; Plan = $pv; Resolved = $rv; Critical = [bool]$crit }) }
    $isCritical = { param($k) $e = Get-WinEaseBuildPlanCatalogEntry -Source $k; ($e -is [System.Collections.IDictionary]) -and ("$($e['Status'])" -in @('Known', 'Unknown')) }
    $keys = { param($o) if ($null -eq $o) { @() } elseif ($o -is [System.Collections.IDictionary]) { @($o.Keys) } else { @($o.PSObject.Properties.Name) } }

    foreach ($k in (& $keys (Get-WinEaseBuildPlanValue $eff 'Components'))) {
        $rv = Get-WinEaseBuildPlanValue $Resolved $k
        if ($null -eq $rv) { continue }
        $pv = [bool](Get-WinEaseBuildPlanValue (Get-WinEaseBuildPlanValue $eff 'Components') $k)
        if ($pv -ne [bool]$rv) { & $add $k $pv ([bool]$rv) (& $isCritical $k) }
    }
    $rt = Get-WinEaseBuildPlanValue $Resolved 'TweakSettings'
    if ($null -ne $rt) {
        foreach ($k in (& $keys (Get-WinEaseBuildPlanValue $eff 'TweakSettings'))) {
            $rv = Get-WinEaseBuildPlanValue $rt $k
            if ($null -eq $rv) { continue }
            $pv = [bool](Get-WinEaseBuildPlanValue (Get-WinEaseBuildPlanValue $eff 'TweakSettings') $k)
            if ($pv -ne [bool]$rv) { & $add "Tweak:$k" $pv ([bool]$rv) (& $isCritical $k) }
        }
    }
    # AllowPhysicalDebloat only matters when the plan runs Advanced Debloat items (an unrelated -AllowPhysicalDebloat flag deletes nothing)
    $planHasDebloat = (@(Get-WinEaseBuildPlanValue $eff 'AdvancedDebloatStandard').Count + @(Get-WinEaseBuildPlanValue $eff 'AdvancedDebloatExperimental').Count) -gt 0
    foreach ($k in 'PayloadFormat', 'UseVHDX', 'DryRun', 'AllowPhysicalDebloat') {
        if ($k -eq 'AllowPhysicalDebloat' -and -not $planHasDebloat) { continue }
        $rv = Get-WinEaseBuildPlanValue $Resolved $k
        $pv = Get-WinEaseBuildPlanValue $eff $k
        if ($null -eq $rv -or $null -eq $pv) { continue }
        $same = if ($pv -is [bool]) { [bool]$pv -eq [bool]$rv } else { "$pv" -eq "$rv" }
        if (-not $same) { & $add $k $pv $rv $true }
    }
    foreach ($k in 'AdvancedDebloatStandard', 'AdvancedDebloatExperimental') {
        $rv = Get-WinEaseBuildPlanValue $Resolved $k
        if ($null -eq $rv) { continue }
        $pv = @(@(Get-WinEaseBuildPlanValue $eff $k) | Where-Object { $_ } | ForEach-Object { "$_" } | Sort-Object)
        $rvs = @(@($rv) | Where-Object { $_ } | ForEach-Object { "$_" } | Sort-Object)
        if (($pv -join "`n") -ne ($rvs -join "`n")) { & $add $k ($pv -join '; ') ($rvs -join '; ') $true }
    }
    return [pscustomobject]@{
        Match       = ($mismatches.Count -eq 0)
        HasCritical = (@($mismatches | Where-Object { $_.Critical }).Count -gt 0)
        Mismatches  = @($mismatches)
    }
}

# Writes <Dir>\<BaseName>.plan.json and .plan.txt (the plan the builder received); returns the two paths
function Write-WinEaseBuildPlanSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan, [Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][string]$BaseName)
    if (-not (Test-Path -LiteralPath $Directory)) { [void](New-Item -ItemType Directory -Force -Path $Directory) }
    $jsonPath = Join-Path -Path $Directory -ChildPath "$BaseName.plan.json"
    $textPath = Join-Path -Path $Directory -ChildPath "$BaseName.plan.txt"
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($jsonPath, ($Plan | ConvertTo-Json -Depth 8), $utf8)
    [System.IO.File]::WriteAllText($textPath, (Get-WinEaseBuildPlanView -Plan $Plan).Text, $utf8)
    return @($jsonPath, $textPath)
}

# Builder entry point, called once at the end of configuration resolution: writes the plan it received to the log
# directory, compares it with the resolved settings and reports every mismatch (Write-Warning). A mismatch of a
# critical setting is an error: the build would differ from what the user confirmed, so it throws.
# Returns the comparison result ($null when no plan was received).
function Invoke-WinEaseBuildPlanCheck {
    [CmdletBinding()]
    param($Plan, $Resolved, [string]$LogDirectory, [string]$BaseName)
    if (-not $Plan) {
        Write-Host '  - Build plan:              (none received; not started from the GUI confirmation)' -ForegroundColor DarkGray
        return $null
    }
    if ($LogDirectory -and $BaseName) {
        try {
            $paths = Write-WinEaseBuildPlanSummary -Plan $Plan -Directory $LogDirectory -BaseName $BaseName
            Write-Host "  - Build plan:              $($paths[1])" -ForegroundColor DarkCyan
        } catch { Write-Warning "Build plan summary could not be written: $($_.Exception.Message)" }
    }
    $cmp = Compare-WinEaseBuildPlanToSettings -Plan $Plan -Resolved $Resolved
    foreach ($m in @($cmp.Mismatches)) {
        $msg = "Build plan mismatch: '$($m.Key)' was confirmed as '$($m.Plan)' but resolved to '$($m.Resolved)'$(if ($m.Critical) { ' (CRITICAL)' })."
        Write-Warning $msg
    }
    if ($cmp.HasCritical) {
        $keys = (@($cmp.Mismatches | Where-Object { $_.Critical } | ForEach-Object { $_.Key }) -join ', ')
        throw "The resolved settings differ from the confirmed build plan in critical setting(s): $keys. Aborting; nothing was built."
    }
    if ($cmp.Match) { Write-Host '  - Build plan check:        resolved settings match the confirmed plan' -ForegroundColor DarkCyan }
    return $cmp
}

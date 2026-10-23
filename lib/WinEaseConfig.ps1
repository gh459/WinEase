# WinEaseConfig.ps1 - Configuration resolution, conflict checks, resume integrity and diff helpers
# Dot-sourced by WinEasehelpers.ps1 (function definitions only).
# Helper function: Detect and resolve configuration conflicts across debloat selections and tweaks

function Get-WinEaseOptionPolarity {
    <#
    .SYNOPSIS
        The polarity of an option, derived from its key.
    .DESCRIPTION
        The convention of the whole configuration (config\schema.psd1):
          Remove*  the option removes something        OFF = keep it
          Disable* the option switches something off    OFF = leave it on
          Enable*  the option switches something on     OFF = leave it off
          Keep*    the option keeps something           ON  = keep it
        Every other key is a plain feature switch: ON = the feature is active.

        The "keep" options are the inverted ones: they are on by default and the user
        switches them off to get the removal.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Key)
    if ($Key -match '^Remove') { return 'Remove' }
    if ($Key -match '^Disable') { return 'Disable' }
    if ($Key -match '^Enable') { return 'Enable' }
    if ($Key -match '^Keep') { return 'Keep' }
    return 'Feature'
}

function Resolve-WinEaseConfiguration {
    <#
    .SYNOPSIS
        Resolves the effective configuration of a build.
    .DESCRIPTION
        The order of the three layers is fixed:
          1. the base defaults (config\schema.psd1 / config\schema.psd1)
          2. the preset (config\presets.psd1)
          3. the individual settings of the user (profile, GUI, command line)

        An individual setting always wins: an option the user set explicitly to $false
        stays false, even when the preset switches it on. A "keep" request is never
        overruled by a preset, and a preset never overrules the command line.
    .PARAMETER Base
        The defaults of the components.
    .PARAMETER Preset
        The values of the preset.
    .PARAMETER Overrides
        The explicit settings of the user. They win over the preset.
    .PARAMETER TweakBase
        The defaults of the individual tweaks.
    .PARAMETER TweakPreset
        The values of the preset for the individual tweaks.
    .PARAMETER TweakOverrides
        The explicit settings of the user for the individual tweaks.
    .OUTPUTS
        A PSCustomObject with the resolved Components and Tweaks.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [hashtable]$Base = @{},
        [hashtable]$Preset = @{},
        [hashtable]$Overrides = @{},
        [hashtable]$TweakBase = @{},
        [hashtable]$TweakPreset = @{},
        [hashtable]$TweakOverrides = @{}
    )
    $components = [ordered]@{}
    foreach ($k in $Base.Keys) { $components[$k] = $Base[$k] }
    foreach ($k in $Preset.Keys) { if ($components.Contains($k)) { $components[$k] = $Preset[$k] } }
    foreach ($k in $Overrides.Keys) { if ($components.Contains($k)) { $components[$k] = $Overrides[$k] } }

    $tweaks = [ordered]@{}
    foreach ($k in $TweakBase.Keys) { $tweaks[$k] = $TweakBase[$k] }
    foreach ($k in $TweakPreset.Keys) { if ($tweaks.Contains($k)) { $tweaks[$k] = $TweakPreset[$k] } }
    foreach ($k in $TweakOverrides.Keys) { if ($tweaks.Contains($k)) { $tweaks[$k] = $TweakOverrides[$k] } }

    return [PSCustomObject]@{
        Components = $components
        Tweaks     = $tweaks
    }
}

function Test-WinEaseConfigConflicts {
    <#
    .SYNOPSIS
        Checks a configuration for contradictions. It never changes the settings.
    .DESCRIPTION
        The check is a pure validation: it reports what contradicts and what the
        resolution would be, but it never writes a value back (AUD-14). A setting of the
        user is never overruled silently.

        A conflict can carry a safeguard: a resolution that protects the build and must
        not be left to the user (a "keep" request that contradicts a selected debloat
        target, or the physical debloat without its explicit consent). The builder
        applies those safeguards and reports them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Config
    )
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Helper to get property value whether hashtable or psobject
    $getVal = {
        param($key)
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains($key)) { return $Config[$key] }
        } elseif ($Config.PSObject.Properties[$key]) {
            return $Config.PSObject.Properties[$key].Value
        }
        return $null
    }

    $rawStd = & $getVal 'advancedDebloatStandard'
    $rawExp = & $getVal 'advancedDebloatExperimental'
    $stdItems = [System.Collections.Generic.List[string]]::new()
    if ($rawStd) { foreach ($item in $rawStd) { $stdItems.Add("$item") } }
    $expItems = [System.Collections.Generic.List[string]]::new()
    if ($rawExp) { foreach ($item in $rawExp) { $expItems.Add("$item") } }

    $tweakSettings = & $getVal 'TweakSettings'
    $getTweak = {
        param($tkey)
        if ($tweakSettings -is [System.Collections.IDictionary]) {
            if ($tweakSettings.Contains($tkey)) { return [bool]$tweakSettings[$tkey] }
        } elseif ($tweakSettings -and $tweakSettings.PSObject.Properties[$tkey]) {
            return [bool]$tweakSettings.PSObject.Properties[$tkey].Value
        }
        return $false
    }

    # 1. Edge conflict
    if (& $getVal 'KeepEdge') {
        $expEdge = $expItems | Where-Object { $_ -match 'Edge' }
        if ($expEdge) {
            $msg = "KeepEdge is true, but advancedDebloatExperimental contains '$($expEdge -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "KeepEdge"; Type = "Browser"; Details = $msg; Resolution = "Removed Edge items from experimental debloat"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($expEdge) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    # 2. Defender conflict
    # The Defender targets are looked up in BOTH debloat lists. The Advanced Debloat tab
    # has a standard and an experimental list, and a target that ends up in the standard
    # list (an older profile put the "Physical: ..." entries there) disables the Defender
    # services in phase 10 exactly like the one in the experimental list. Scanning only
    # the experimental list left that path open, so the Defender was disabled and its
    # payload was deleted while the "RemoveDefender" setting was off.
    if ((& $getVal 'KeepDefender') -or (-not (& $getVal 'RemoveDefender'))) {
        $defenderItems = @(@($stdItems) + @($expItems))
        $expDef = @($defenderItems | Where-Object { $_ -match 'Defender|Firewall' } | Select-Object -Unique)
        if ($expDef.Count -gt 0) {
            $msg = "Defender is kept, but the debloat lists contain '$($expDef -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "Defender"; Type = "Security"; Details = $msg; Resolution = "Removed Defender items from the debloat lists"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($expDef) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    # 3. Recovery / WinRE conflict
    if (& $getVal 'KeepRecoveryEnv') {
        $stdWinre = $stdItems | Where-Object { $_ -match 'WinRE' }
        if ($stdWinre) {
            $msg = "KeepRecoveryEnv is true, but advancedDebloatStandard contains '$($stdWinre -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "WinRE"; Type = "Recovery"; Details = $msg; Resolution = "Removed WinRE removal from debloat"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($stdWinre) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    # 4. Search index conflict
    if (& $getVal 'KeepSearchIndex') {
        $expSearch = $expItems | Where-Object { $_ -match 'Search index' }
        if ($expSearch) {
            $msg = "KeepSearchIndex is true, but advancedDebloatExperimental contains '$($expSearch -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "SearchIndex"; Type = "System"; Details = $msg; Resolution = "Removed Search index removal from debloat"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($expSearch) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    # 5. Xbox conflict
    if (& $getVal 'KeepXboxServices') {
        $stdXbox = $stdItems | Where-Object { $_ -match 'Xbox' }
        if ($stdXbox) {
            $msg = "KeepXboxServices is true, but debloat contains '$($stdXbox -join ', ')lib'."
            $conf = [PSCustomObject]@{ Rule = "XboxServices"; Type = "Gaming"; Details = $msg; Resolution = "Removed Xbox debloat items"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($stdXbox) + @($expItems | Where-Object { $_ -match 'Xbox' }) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    # 6. Bluetooth conflict
    if (& $getVal 'KeepBT') {
        $stdBT = $stdItems | Where-Object { $_ -match 'Bluetooth' }
        $expBT = $expItems | Where-Object { $_ -match 'Bluetooth' }
        if ($stdBT -or $expBT) {
            $msg = "KeepBT is true, but debloat contains Bluetooth items."
            $conf = [PSCustomObject]@{ Rule = "Bluetooth"; Type = "Hardware"; Details = $msg; Resolution = "Removed Bluetooth debloat items"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($stdBT) + @($expBT) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    # 7. Microsoft Store vs Windows Update dependency
    $removeStoreVal = [bool](& $getVal 'RemoveStore')
    $keepStoreVal = [bool](& $getVal 'KeepStore')
    $storeRetained = (-not $removeStoreVal) -or $keepStoreVal
    $disableWUVal = [bool](& $getVal 'DisableWindowsUpdate')

    if ($storeRetained -and $disableWUVal) {
        $msg = "Microsoft Store is kept, but DisableWindowsUpdate is true. Store downloads/updates require Windows Update."
        $conf = [PSCustomObject]@{ Rule = "StoreWindowsUpdateDependency"; Type = "Dependency"; Details = $msg; Resolution = "Set DisableWindowsUpdate = $false to ensure Store functionality"; Safeguard = $null }
        $conflicts.Add($conf)
        $warnings.Add("Conflict: $msg")
    }

    # 8. Store retention conflict (KeepStore vs RemoveStore)
    if ($keepStoreVal -and $removeStoreVal) {
        $msg = "KeepStore is true, but RemoveStore is also set to true."
        $conf = [PSCustomObject]@{ Rule = "KeepStoreVsRemoveStore"; Type = "Logic"; Details = $msg; Resolution = "Set RemoveStore = $false (KeepStore takes precedence)"; Safeguard = $null }
        $conflicts.Add($conf)
        $warnings.Add("Conflict: $msg")
    }

    # 9. Physical Debloat Safety Gate (-AllowPhysicalDebloat guard)
    $allowPhys = [bool](& $getVal 'AllowPhysicalDebloat')
    $physTweak = & $getTweak 'PhysicalDebloat'
    $hasPhysExp = ($expItems.Count -gt 0)
    if ((-not $allowPhys) -and ($physTweak -or $hasPhysExp)) {
        $msg = "Destructive physical debloat is requested, but -AllowPhysicalDebloat safety guard is not enabled."
        $conf = [PSCustomObject]@{ Rule = "PhysicalDebloatSafetyGate"; Type = "Safety"; Details = $msg; Resolution = "Disabled PhysicalDebloat tweak and cleared experimental deletions"; Safeguard = [PSCustomObject]@{ Action = "ClearExperimental" } }
        $conflicts.Add($conf)
        $warnings.Add("Conflict: $msg")
    }

    # 10. Asian IME Preservation
    if (& $getVal 'KeepAsianIME') {
        $imeItems = $stdItems | Where-Object { $_ -match 'IME' }
        if ($imeItems) {
            $msg = "KeepAsianIME is true, but debloat contains IME removal items."
            $conf = [PSCustomObject]@{ Rule = "KeepAsianIME"; Type = "Localization"; Details = $msg; Resolution = "Removed IME removal items"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($imeItems) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    # 11. Extra Fonts Preservation
    if (& $getVal 'KeepExtraFonts') {
        $fontItems = $stdItems | Where-Object { $_ -match 'font' }
        if ($fontItems) {
            $msg = "KeepExtraFonts is true, but debloat contains font removal items."
            $conf = [PSCustomObject]@{ Rule = "KeepExtraFonts"; Type = "Localization"; Details = $msg; Resolution = "Removed font removal items"; Safeguard = [PSCustomObject]@{ Action = "RemoveItems"; Items = @($fontItems) } }
            $conflicts.Add($conf)
            $warnings.Add("Conflict: $msg")
        }
    }

    return [PSCustomObject]@{
        HasConflicts   = ($conflicts.Count -gt 0)
        Conflicts      = [object[]]$conflicts
        Warnings       = [string[]]$warnings
        ResolvedConfig = $Config
        Safeguards     = @($conflicts | Where-Object { $_.Safeguard } | ForEach-Object { $_.Safeguard })
    }
}
# Helper function: Validate image and workspace integrity before resuming

function Test-WinEaseResumeIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceDir,
        [int]$TargetPhase = 0,
        [switch]$IsIsoOnly
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $payloadPath = $null
    $payloadType = $null
    $bootWimPath = $null

    if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
        $errors.Add("Workspace directory '$WorkspaceDir' does not exist.")
        return [PSCustomObject]@{ IsValid = $false; Errors = [string[]]$errors; Warnings = [string[]]$warnings; BuildDir = $null; PayloadPath = $null; PayloadType = $null; BootWimPath = $null }
    }

    $buildDir = Join-Path -Path $WorkspaceDir -ChildPath "build"
    if (-not (Test-Path -LiteralPath $buildDir)) {
        $errors.Add("Workspace build directory '$buildDir' does not exist.")
        return [PSCustomObject]@{ IsValid = $false; Errors = [string[]]$errors; Warnings = [string[]]$warnings; BuildDir = $null; PayloadPath = $null; PayloadType = $null; BootWimPath = $null }
    }

    $sourcesDir = Join-Path -Path $buildDir -ChildPath "sources"
    if (-not (Test-Path -LiteralPath $sourcesDir)) {
        $errors.Add("Build sources directory '$sourcesDir' does not exist.")
    } else {
        foreach ($cand in @('install.wim', 'install.esd')) {
            $p = Join-Path -Path $sourcesDir -ChildPath $cand
            if (Test-Path -LiteralPath $p) {
                $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
                if ($item.Length -gt 500MB) {
                    $payloadPath = $p
                    $payloadType = [System.IO.Path]::GetExtension($cand).TrimStart('.').ToUpperInvariant()
                    # Validate WIM header magic bytes MSWIM\0\0
                    try {
                        $fs = [System.IO.File]::OpenRead($p)
                        $hdr = New-Object byte[] 8
                        $null = $fs.Read($hdr, 0, 8)
                        $fs.Close()
                        $sig = [System.Text.Encoding]::ASCII.GetString($hdr, 0, 5)
                        if ($sig -ne 'MSWIM') {
                            $errors.Add("File '$p' does not have valid MSWIM header signature (got '$sig').")
                        }
                    } catch {
                        $errors.Add("Could not read WIM header of '$p': $_")
                    }
                    break
                }
            }
        }
        if (-not $payloadPath) {
            $errors.Add("No valid install.wim or install.esd (>500MB) found in '$sourcesDir'.")
        }
        $bootWimPath = Join-Path -Path $sourcesDir -ChildPath "boot.wim"
        if (-not (Test-Path -LiteralPath $bootWimPath)) {
            $errors.Add("boot.wim is missing in '$sourcesDir'.")
        }
    }

    # ISO root items validation for resume ISO mode
    if ($IsIsoOnly -or $TargetPhase -ge 13) {
        $requiredRootItems = @('boot', 'efi', 'bootmgr', 'bootmgr.efi', 'bootmgfw.efi', 'setup.exe', 'autounattend.xml')
        foreach ($item in $requiredRootItems) {
            $itemPath = Join-Path -Path $buildDir -ChildPath $item
            if (-not (Test-Path -LiteralPath $itemPath)) {
                $errors.Add("Required ISO root component '$item' is missing in '$buildDir'.")
            }
        }
    }

    return [PSCustomObject]@{
        IsValid     = ($errors.Count -eq 0)
        Errors      = [string[]]$errors
        Warnings    = [string[]]$warnings
        BuildDir    = $buildDir
        PayloadPath = $payloadPath
        PayloadType = $payloadType
        BootWimPath = $bootWimPath
    }
}

# Path of a user-editable config file. The new home is config\user\<Name>; a file left in the old config\<Name>
# is still used when the new one is absent, with a one-time warning per file.
function Resolve-WinEaseUserConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $newPath = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'config\user') -ChildPath $Name
    if (Test-Path -LiteralPath $newPath) { return $newPath }
    $oldPath = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'config') -ChildPath $Name
    if (Test-Path -LiteralPath $oldPath) {
        if ($null -eq $script:WinEaseLegacyConfigWarned) { $script:WinEaseLegacyConfigWarned = @{} }
        if (-not $script:WinEaseLegacyConfigWarned.ContainsKey($Name)) {
            $script:WinEaseLegacyConfigWarned[$Name] = $true
            Write-Warning "Using '$oldPath' from the old location. Move it to '$newPath'."
        }
        return $oldPath
    }
    return $newPath
}

# 5. Compare-WinEaseConfig & Format-WinEaseConfigDiff
function Resolve-WinEaseConfigForDiff {
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

function Compare-WinEaseConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ReferenceConfig,
        [Parameter(Mandatory = $true)]
        $DifferenceConfig
    )
    $ref = Resolve-WinEaseConfigForDiff -InputConfig $ReferenceConfig -NameHint 'Reference'
    $diff = Resolve-WinEaseConfigForDiff -InputConfig $DifferenceConfig -NameHint 'Difference'

    $compDiffs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tweakGroupDiffs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tweakSettingDiffs = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Component diffs
    $allCompKeysList = [System.Collections.Generic.List[object]]::new()
    if ($ref.Data -is [System.Collections.IDictionary]) { $allCompKeysList.AddRange([object[]]@($ref.Data.Keys)) }
    elseif ($ref.Data.PSObject) { $allCompKeysList.AddRange([object[]]@($ref.Data.PSObject.Properties.Name)) }
    if ($diff.Data -is [System.Collections.IDictionary]) { $allCompKeysList.AddRange([object[]]@($diff.Data.Keys)) }
    elseif ($diff.Data.PSObject) { $allCompKeysList.AddRange([object[]]@($diff.Data.PSObject.Properties.Name)) }
    $allCompKeys = $allCompKeysList | Select-Object -Unique
    foreach ($k in $allCompKeys) {
        $rv = $null; $dv = $null
        if ($ref.Data -is [System.Collections.IDictionary]) { if ($ref.Data.Contains($k)) { $rv = $ref.Data[$k] } } elseif ($ref.Data.PSObject -and $ref.Data.PSObject.Properties[$k]) { $rv = $ref.Data.PSObject.Properties[$k].Value }
        if ($diff.Data -is [System.Collections.IDictionary]) { if ($diff.Data.Contains($k)) { $dv = $diff.Data[$k] } } elseif ($diff.Data.PSObject -and $diff.Data.PSObject.Properties[$k]) { $dv = $diff.Data.PSObject.Properties[$k].Value }
        if ($rv -ne $dv) {
            $compDiffs.Add([PSCustomObject]@{ Key = $k; Category = 'Component'; ReferenceValue = $rv; DifferenceValue = $dv })
        }
    }

    # TweakSettings diffs
    $refTS = $null; $diffTS = $null
    if ($ref.Data -is [System.Collections.IDictionary] -and $ref.Data.Contains('TweakSettings')) { $refTS = $ref.Data['TweakSettings'] }
    elseif ($ref.Data.PSObject -and $ref.Data.PSObject.Properties['TweakSettings']) { $refTS = $ref.Data.PSObject.Properties['TweakSettings'].Value }
    if ($diff.Data -is [System.Collections.IDictionary] -and $diff.Data.Contains('TweakSettings')) { $diffTS = $diff.Data['TweakSettings'] }
    elseif ($diff.Data.PSObject -and $diff.Data.PSObject.Properties['TweakSettings']) { $diffTS = $diff.Data.PSObject.Properties['TweakSettings'].Value }

    $allTweakKeysList = [System.Collections.Generic.List[object]]::new()
    if ($refTS -is [System.Collections.IDictionary]) { $allTweakKeysList.AddRange([object[]]@($refTS.Keys)) }
    elseif ($refTS.PSObject) { $allTweakKeysList.AddRange([object[]]@($refTS.PSObject.Properties.Name)) }
    if ($diffTS -is [System.Collections.IDictionary]) { $allTweakKeysList.AddRange([object[]]@($diffTS.Keys)) }
    elseif ($diffTS.PSObject) { $allTweakKeysList.AddRange([object[]]@($diffTS.PSObject.Properties.Name)) }
    $allTweakKeys = $allTweakKeysList | Select-Object -Unique
    foreach ($k in $allTweakKeys) {
        $rv = $null; $dv = $null
        if ($refTS -is [System.Collections.IDictionary]) { if ($refTS.Contains($k)) { $rv = $refTS[$k] } } elseif ($refTS -and $refTS.PSObject -and $refTS.PSObject.Properties[$k]) { $rv = $refTS.PSObject.Properties[$k].Value }
        if ($diffTS -is [System.Collections.IDictionary]) { if ($diffTS.Contains($k)) { $dv = $diffTS[$k] } } elseif ($diffTS -and $diffTS.PSObject -and $diffTS.PSObject.Properties[$k]) { $dv = $diffTS.PSObject.Properties[$k].Value }
        $desc = ''
        if ($script:AllTweakDefs -and $script:AllTweakDefs.Contains($k)) { $desc = $script:AllTweakDefs[$k].Description }
        if ($rv -ne $dv) {
            $tweakSettingDiffs.Add([PSCustomObject]@{ Key = $k; Category = 'TweakSetting'; Description = $desc; ReferenceValue = $rv; DifferenceValue = $dv })
        }
    }

    # TweakGroups
    $refTG = $null; $diffTG = $null
    if ($ref.Data -is [System.Collections.IDictionary] -and $ref.Data.Contains('TweakGroups')) { $refTG = $ref.Data['TweakGroups'] }
    elseif ($ref.Data.PSObject -and $ref.Data.PSObject.Properties['TweakGroups']) { $refTG = $ref.Data.PSObject.Properties['TweakGroups'].Value }
    if ($diff.Data -is [System.Collections.IDictionary] -and $diff.Data.Contains('TweakGroups')) { $diffTG = $diff.Data['TweakGroups'] }
    elseif ($diff.Data.PSObject -and $diff.Data.PSObject.Properties['TweakGroups']) { $diffTG = $diff.Data.PSObject.Properties['TweakGroups'].Value }
    $allTGKeysList = [System.Collections.Generic.List[object]]::new()
    if ($refTG -is [System.Collections.IDictionary]) { $allTGKeysList.AddRange([object[]]@($refTG.Keys)) }
    elseif ($refTG.PSObject) { $allTGKeysList.AddRange([object[]]@($refTG.PSObject.Properties.Name)) }
    if ($diffTG -is [System.Collections.IDictionary]) { $allTGKeysList.AddRange([object[]]@($diffTG.Keys)) }
    elseif ($diffTG.PSObject) { $allTGKeysList.AddRange([object[]]@($diffTG.PSObject.Properties.Name)) }
    $allTGKeys = $allTGKeysList | Select-Object -Unique
    foreach ($k in $allTGKeys) {
        $rv = $null; $dv = $null
        if ($refTG -is [System.Collections.IDictionary]) { if ($refTG.Contains($k)) { $rv = $refTG[$k] } } elseif ($refTG -and $refTG.PSObject -and $refTG.PSObject.Properties[$k]) { $rv = $refTG.PSObject.Properties[$k].Value }
        if ($diffTG -is [System.Collections.IDictionary]) { if ($diffTG.Contains($k)) { $dv = $diffTG[$k] } } elseif ($diffTG -and $diffTG.PSObject -and $diffTG.PSObject.Properties[$k]) { $dv = $diffTG.PSObject.Properties[$k].Value }
        if ($rv -ne $dv) {
            $tweakGroupDiffs.Add([PSCustomObject]@{ Key = $k; Category = 'TweakGroup'; ReferenceValue = $rv; DifferenceValue = $dv })
        }
    }

    $totalDiff = $compDiffs.Count + $tweakGroupDiffs.Count + $tweakSettingDiffs.Count
    return [PSCustomObject]@{
        ReferenceName     = $ref.Name
        DifferenceName    = $diff.Name
        ComponentDiffs    = @($compDiffs)
        TweakGroupDiffs   = @($tweakGroupDiffs)
        TweakSettingDiffs = @($tweakSettingDiffs)
        AddedImpacts      = @()
        RemovedImpacts    = @()
        TotalDiffCount    = $totalDiff
    }
}

function Format-WinEaseConfigDiff {
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

# 6. Test-WinEaseRecoveryReadiness
function Test-WinEaseRecoveryReadiness {
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
        # The build GUI writes its backup to %USERPROFILE%\WinEase_migration_backup.
        # Documents was the old default. C:\WinEaseBackup only exists after an image
        # with the bundled backup was installed, but checking it keeps the readiness
        # report correct when the helper runs from such an installation.
        $backupCandidates = @(
            $(if ($env:USERPROFILE) { Join-Path -Path $env:USERPROFILE -ChildPath (Join-Path -Path 'WinEase_migration_backup' -ChildPath 'migration-manifest.json') }),
            $(if ([Environment]::GetFolderPath('MyDocuments')) { Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath (Join-Path -Path 'WinEase_migration_backup' -ChildPath 'migration-manifest.json') }),
            'C:\WinEaseBackup\migration-manifest.json'
        )
        foreach ($manifestPath in $backupCandidates) {
            if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) { $migrationBackupFound = $true; break }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    $score = 'Low'
    if ($secondaryDrives.Count -gt 0 -and $sysRestoreEnabled) { $score = 'High' }
    elseif ($secondaryDrives.Count -gt 0 -or $sysRestoreEnabled -or $winReEnabled) { $score = 'Medium' }

    $recs = @()
    if (-not $winReEnabled) {
        $recs += "The generated ISO will have Windows Recovery Environment (WinRE) removed. Keep the installation USB media as a recovery disk."
    }
    if ($secondaryDrives.Count -eq 0 -and -not $migrationBackupFound) {
        $recs += "No secondary drive or migration backup found. Run WinEase-Migrator.ps1 to back up user data before building."
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

# ---------------------------------------------------------------------------
# FeatureManagement override IDs
#
# Windows stores the on/off state of some shell features as an obfuscated
# 32-bit ID under two locations of the SYSTEM hive:
#   HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\<id>
#       EnabledState = 1 (disabled) / 2 (enabled)
#       EnabledStateOptions, Variant, VariantPayload, VariantPayloadKind = 0
#   HKLM\SYSTEM\ControlSet001\Policies\Microsoft\FeatureManagement\Overrides\<id>
#       0 (disabled) / 1 (enabled)
#
# The obfuscation is a fixed XOR (seed 0x447F3700) followed by a bit-slice
# transform. The same algorithm is used by the ReviOS playbook and by the
# Revision Tool (meetrevision/revision-tool), so the IDs computed here match
# the values those tools write.
# ---------------------------------------------------------------------------
function ConvertTo-WinEaseFeatureIdOverride {
    param(
        [Parameter(Mandatory=$true)]
        [int64]$FeatureId
    )
    # The mask is built from the type itself: PowerShell 5.1 parses 0xFFFFFFFF as
    # a signed Int32 (-1).
    [int64]$uint32Max = [int64][uint32]::MaxValue
    [int64]$seed = 0x447F3700
    if ($FeatureId -lt 0 -or $FeatureId -gt $uint32Max) {
        throw "Feature ID must be a 32-bit unsigned integer: $FeatureId"
    }
    [int64]$w = (($FeatureId -bxor $seed) -band $uint32Max)
    [int64]$b0 = $w -band 0xFF
    [int64]$b1 = ($w -shr 8) -band 0xFF
    [int64]$b2 = ($w -shr 16) -band 0xFF
    [int64]$b3 = ($w -shr 24) -band 0xFF
    [int64]$r = (((((($b0 -band 0x7F) -shl 25) -bor ($b0 -shr 7))) -bor ($b1 -shl 17)) -bor ($b2 -shl 9)) -bor ($b3 -shl 1)
    return [uint32]($r -band $uint32Max)
}

function ConvertFrom-WinEaseFeatureIdOverride {
    param(
        [Parameter(Mandatory=$true)]
        [int64]$OverrideId
    )
    [int64]$uint32Max = [int64][uint32]::MaxValue
    [int64]$seed = 0x447F3700
    if ($OverrideId -lt 0 -or $OverrideId -gt $uint32Max) {
        throw "Override ID must be a 32-bit unsigned integer: $OverrideId"
    }
    [int64]$v = $OverrideId -band $uint32Max
    [int64]$b0 = (($v -shr 25) -band 0x7F) -bor (($v -band 1) -shl 7)
    [int64]$b1 = ($v -shr 17) -band 0xFF
    [int64]$b2 = ($v -shr 9) -band 0xFF
    [int64]$b3 = ($v -shr 1) -band 0xFF
    [int64]$w = ($b0 -bor ($b1 -shl 8) -bor ($b2 -shl 16) -bor ($b3 -shl 24))
    return [int64](($w -bxor $seed) -band $uint32Max)
}

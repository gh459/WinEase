# Advanced Debloat: the execution engine (PowerShell / Rust) and the per-target handlers.
#
# The target list, the engine binding and the owning phase live in config\schema.psd1
# (DebloatEngines), so the GUI, the profile format and the phases read one table.
#
# Invariants (enforced here and in phases\09-physical-debloat.ps1, not only in the UI):
#   * a target that is not selected never runs, whatever engine it carries
#   * the engine "PowerShell" never hands the target to the Rust binary
#   * the engine "Rust" hands exactly that one key to the Rust binary
#   * a target whose "keep" option is on is never removed, not even when the target
#     itself was selected
#
# The safe (PowerShell) work is executed by the phase that owns the target, so one work
# item has exactly one implementation. Phase 09 only dispatches to the Rust binary.

# --- the engine table ---------------------------------------------------------------
function Get-WinEaseDebloatEngines {
    # The engine definitions, keyed by the exact list entry text.
    if ((Get-Variable -Name 'WinEaseDebloatEngines' -Scope Script -ErrorAction SilentlyContinue) -and $script:WinEaseDebloatEngines) {
        return $script:WinEaseDebloatEngines
    }
    return $null
}

function Get-WinEaseDebloatEngineDef {
    # The engine definition of one target, or $null when the target is not registered.
    param([string]$Item)
    $map = Get-WinEaseDebloatEngines
    if (-not $map -or [string]::IsNullOrWhiteSpace($Item)) { return $null }
    if ($map.Contains($Item)) { return $map[$Item] }
    return $null
}

function Resolve-WinEaseDebloatEngine {
    # The engine that removes the given target.
    #
    # The user's choice ($script:DebloatEngineSelection) wins, but only when the target
    # really supports that engine - an unknown or disallowed engine falls back to the
    # registered default. This keeps a hand-edited profile from selecting an engine that
    # does not exist for the target.
    param([string]$Item)
    $def = Get-WinEaseDebloatEngineDef -Item $Item
    $allowed = @()
    $fallback = 'PowerShell'
    if ($def) {
        $allowed = @($def.Engines)
        if ($def.Default) { $fallback = [string]$def.Default }
    } else {
        # Unregistered target: fall back to the historical split (Standard -> PowerShell,
        # Experimental -> Rust) so an unknown entry never reaches the wrong engine.
        if (@($script:advancedDebloatExperimental) -contains $Item) { $fallback = 'Rust' }
    }
    if ($script:DebloatEngineSelection -and $script:DebloatEngineSelection.Contains($Item)) {
        $chosen = [string]$script:DebloatEngineSelection[$Item]
        if ($allowed -contains $chosen) { return $chosen }
        Write-Host "    [WARN] Engine '$chosen' is not available for '$Item' - using '$fallback' instead." -ForegroundColor Yellow
    }
    if ($allowed -contains $fallback) { return $fallback }
    if ($allowed.Count -gt 0) { return [string]$allowed[0] }
    return $fallback
}

function Test-WinEaseDebloatTarget {
    # True when the target is selected and runs on the given engine.
    #
    # This is the single gate every phase uses: a target that is not in the selection
    # never runs, and a target that runs on the Rust engine is not touched by the safe
    # engine either - the two engines are mutually exclusive for one target.
    param(
        [Parameter(Mandatory = $true)][string]$Item,
        [ValidateSet('PowerShell', 'Rust')][string]$Engine = 'PowerShell'
    )
    $selected = @($script:advancedDebloatStandard) + @($script:advancedDebloatExperimental)
    if ($selected -notcontains $Item) { return $false }
    return ((Resolve-WinEaseDebloatEngine -Item $Item) -eq $Engine)
}

function Test-WinEaseDebloatOptionEnabled {
    # True when the granular option is on, or when a selected Advanced Debloat target
    # implies it (the Option field of the table). This is how a target of the Advanced
    # Debloat tab reaches the phase that owns the option: the work is done once, by the
    # phase that owns it.
    param([Parameter(Mandatory = $true)][string]$Option)
    $defs = Get-WinEaseDebloatEngines
    if (-not $defs) { return $false }
    foreach ($k in $defs.Keys) {
        $def = $defs[$k]
        if ([string]$def.Option -ne $Option) { continue }
        if (Test-WinEaseDebloatTarget -Item $k -Engine 'PowerShell') { return $true }
    }
    return $false
}

function ConvertTo-WinEaseDebloatTarget {
    # Maps a list entry onto the registered target. Older profiles still contain the
    # "Physical: <target>" entries that were merged into the standard list; they are
    # mapped onto the canonical target and run on the Rust engine.
    param([string]$Item)
    if ([string]::IsNullOrWhiteSpace($Item)) { return $null }
    if ($script:WinEaseDebloatEngines -and $script:WinEaseDebloatEngines.Contains($Item)) { return $Item }
    if ($script:WinEaseDebloatLegacyMap -and $script:WinEaseDebloatLegacyMap.Contains($Item)) { return $script:WinEaseDebloatLegacyMap[$Item] }
    return $Item
}

function Set-WinEaseDebloatEngineSelection {
    # Applies an engine map (from a profile or from the GUI) and drops every entry that
    # does not belong to a selected target or that the target does not support.
    param([hashtable]$Selection)
    $script:DebloatEngineSelection = [ordered]@{}
    if (-not $Selection) { return }
    $selected = @($script:advancedDebloatStandard) + @($script:advancedDebloatExperimental)
    foreach ($k in $Selection.Keys) {
        $item = ConvertTo-WinEaseDebloatTarget -Item ([string]$k)
        if (-not $item) { continue }
        if ($selected -notcontains $item) { continue }
        if (-not $script:WinEaseDebloatEngines -or -not $script:WinEaseDebloatEngines.Contains($item)) { continue }
        $allowed = @($script:WinEaseDebloatEngines[$item].Engines)
        $engine = [string]$Selection[$k]
        if ($allowed -notcontains $engine) { continue }
        $script:DebloatEngineSelection[$item] = $engine
    }
}

function Get-WinEaseDebloatRustKey {
    # The key the Rust binary understands for the given target.
    # The mapping is data driven (config\schema.psd1 -> DebloatEngines -> RustKey); the
    # regex list is only the fallback for entries that are not registered yet.
    param([string]$Item)
    $def = Get-WinEaseDebloatEngineDef -Item $Item
    if ($def -and $def.RustKey) { return [string]$def.RustKey }
    if ($Item -match 'Edge') { return 'physical_edge' }
    elseif ($Item -match 'Defender') { return 'physical_defender' }
    elseif ($Item -match 'Cortana') { return 'physical_cortana' }
    elseif ($Item -match 'OneDrive') { return 'physical_onedrive' }
    elseif ($Item -match 'Telemetry') { return 'physical_telemetry' }
    elseif ($Item -match 'Hyper-V') { return 'physical_hyperv' }
    elseif ($Item -match 'IIS') { return 'physical_iis' }
    elseif ($Item -match 'Firewall') { return 'physical_firewall' }
    elseif ($Item -match 'Bluetooth') { return 'physical_bluetooth' }
    elseif ($Item -match 'Spooler') { return 'physical_spooler' }
    elseif ($Item -match 'Touch/Pen') { return 'physical_touch_pen' }
    elseif ($Item -match 'Accessibility') { return 'physical_accessibility' }
    elseif ($Item -match 'Media Player') { return 'physical_media_player' }
    elseif ($Item -match 'Remote Desktop') { return 'physical_rdp' }
    elseif ($Item -match 'BitLocker') { return 'physical_bitlocker' }
    elseif ($Item -match 'Sandbox') { return 'physical_sandbox' }
    elseif ($Item -match 'WSL') { return 'physical_wsl' }
    elseif ($Item -match 'Help') { return 'physical_help' }
    elseif ($Item -match 'Crash dumps') { return 'physical_crash_dumps' }
    elseif ($Item -match 'Provisioning') { return 'physical_provisioning' }
    elseif ($Item -match 'Delivery Optimization') { return 'physical_delivery_optimization' }
    elseif ($Item -match 'Search index') { return 'physical_search_index' }
    elseif ($Item -match 'Windows.old') { return 'physical_windows_old' }
    elseif ($Item -match 'Temp files') { return 'physical_temp_files' }
    elseif ($Item -match 'PatchCache') { return 'physical_patchcache' }
    elseif ($Item -match 'pagefile') { return 'physical_pagefile' }
    elseif ($Item -match 'hiberfil') { return 'physical_hiberfil' }
    elseif ($Item -match 'swapfile') { return 'physical_swapfile' }
    elseif ($Item -match 'Memory.dmp') { return 'physical_memory_dmp' }
    elseif ($Item -match 'Minidump') { return 'physical_minidump' }
    elseif ($Item -match 'event logs') { return 'physical_event_logs' }
    elseif ($Item -match 'non-essential fonts') { return 'physical_fonts' }
    elseif ($Item -match 'non-Japanese IME') { return 'physical_ime' }
    $fallback = $Item -replace '\s*\[.*?\]\s*', '' -replace '\s+', '_' -replace '[^a-zA-Z0-9_]', '' -replace '_+', '_' -replace '^_|_$', ''
    return 'physical_' + $fallback.ToLower()
}

# --- the AppX removal list (phase 05 and the "Remove Provisioned AppX" target) --------
# The list of the AppX packages the build removes lives in config\schema.psd1
# (AppxRemoval). Every entry names the setting that controls it, so a package is only
# removed when the user asked for it.

function Get-WinEaseAppxRemovalDefinitions {
    # The AppX removal definitions (config\schema.psd1 -> AppxRemoval).
    if ((Get-Variable -Name 'WinEaseSettingsDef' -Scope Script -ErrorAction SilentlyContinue) -and $script:WinEaseSettingsDef.AppxRemoval) {
        return @($script:WinEaseSettingsDef.AppxRemoval)
    }
    return @()
}

function Get-WinEaseAppxRemovalPatterns {
    # The AppX wildcard patterns that apply to the current settings.
    #
    # Every definition names the setting that controls it:
    #   Option = ''      the pattern belongs to the default removal list and is
    #                    controlled by RemoveAppxBloatware as a whole
    #   Option = '<key>' the pattern is applied when that setting is on
    #   Invert = $true   the setting is a "Keep..." option: the pattern is applied when
    #                    that setting is off
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [hashtable]$Settings = @{},
        [object[]]$Definitions
    )
    if (-not $Definitions -or @($Definitions).Count -eq 0) { $Definitions = Get-WinEaseAppxRemovalDefinitions }
    if (@($Definitions).Count -eq 0) { return @() }
    if (-not $Settings.ContainsKey('RemoveAppxBloatware') -or -not [bool]$Settings['RemoveAppxBloatware']) { return @() }
    $patterns = @()
    foreach ($d in $Definitions) {
        if (-not $d -or -not $d.Pattern) { continue }
        $option = [string]$d.Option
        if ([string]::IsNullOrWhiteSpace($option)) { $patterns += [string]$d.Pattern; continue }
        if (-not $Settings.ContainsKey($option)) { continue }
        $on = [bool]$Settings[$option]
        if ([bool]$d.Invert) { $on = -not $on }
        if ($on) { $patterns += [string]$d.Pattern }
    }
    return @($patterns | Select-Object -Unique)
}

function Get-WinEaseAppxPatternRegex {
    # The regex of a list of AppX wildcard patterns ('*' matches any text).
    [CmdletBinding()]
    [OutputType([regex])]
    param(
        [string[]]$Patterns = @()
    )
    if (@($Patterns).Count -eq 0) { return $null }
    $escaped = @($Patterns | Sort-Object -Unique | ForEach-Object { [regex]::Escape($_) -replace '\\\*', '.*' })
    return [regex]::new(('^(' + ($escaped -join '|') + ')$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-WinEaseAppxPackageRemovable {
    # The single decision for an AppX package: the same rule for the installed and for
    # the provisioned packages. A package that matches the protection whitelist is
    # never removed, whatever the removal list says.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Name,
        [string]$DisplayName,
        [regex]$RemovalRegex,
        [regex]$ProtectedRegex
    )
    if (-not $RemovalRegex) { return $false }
    if ($ProtectedRegex) {
        if (($Name -and $ProtectedRegex.IsMatch($Name)) -or ($DisplayName -and $ProtectedRegex.IsMatch($DisplayName))) { return $false }
    }
    return [bool](($Name -and $RemovalRegex.IsMatch($Name)) -or ($DisplayName -and $RemovalRegex.IsMatch($DisplayName)))
}

# --- the safe (PowerShell) handlers ---------------------------------------------------
function Invoke-WinEaseDebloatFeatureRemoval {
    # Disable/remove optional features of the mounted image (DISM).
    param([string[]]$FeatureNames = @())
    foreach ($fn in $FeatureNames) {
        if ($isDryRunMode) { Write-Host "    [DRY] Would remove feature: $fn" -ForegroundColor Yellow; continue }
        try {
            & dism.exe /English "/image:$scratchDir" /Disable-Feature "/FeatureName:$fn" /NoRestart 2>&1 | Out-Null
            Write-Host "    [OK] Disabled feature: $fn" -ForegroundColor Green
        } catch { Write-Host "    [WARN] Could not remove feature $fn : $_" -ForegroundColor Yellow }
    }
}

function Invoke-WinEaseDebloatCapabilityRemoval {
    # Remove installed capabilities of the mounted image (DISM).
    param([string[]]$NamePatterns = @())
    $caps = & dism.exe /English "/image:$scratchDir" /Get-Capabilities 2>&1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -and $_ -notmatch '^$' }
    $matched = @()
    foreach ($cap in $caps) {
        foreach ($pat in $NamePatterns) {
            if ($cap -like $pat) { $matched += $cap; break }
        }
    }
    if ($matched.Count -eq 0) {
        Write-Host "    [INFO] No installed capability matches: $($NamePatterns -join ', ')" -ForegroundColor Gray
        return
    }
    foreach ($cap in $matched) {
        if ($isDryRunMode) { Write-Host "    [DRY] Would remove capability: $cap" -ForegroundColor Yellow; continue }
        & dism.exe /English "/image:$scratchDir" /Remove-Capability "/CapabilityName:$cap" /NoRestart > $null 2>&1
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) { Write-Host "    [OK] Removed capability: $cap" -ForegroundColor Green }
        else { Write-Host "    [WARN] Could not remove capability $cap (DISM exit $LASTEXITCODE)" -ForegroundColor Yellow }
    }
}

function Remove-WinEaseDebloatPath {
    # Deletes a path inside the mounted image and reports what happened.
    param([string]$Path, [string]$Label, [switch]$ContentsOnly)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ($isDryRunMode) { Write-Host "    [DRY] Would delete: $Path" -ForegroundColor Yellow; return $true }
    if ($ContentsOnly) {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    [OK] Deleted $Label" -ForegroundColor Green
    return $true
}

function Invoke-WinEaseDebloatTarget {
    # The safe handler of one Advanced Debloat target. Only the targets whose work is not
    # implemented by another phase are handled here; the other targets are executed by
    # their owning phase (the trigger is the option or the target selection).
    param([Parameter(Mandatory = $true)][string]$Item)
    switch -Exact ($Item) {
        'Remove PatchCache (dir delete) [200-500MB]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "Windows\Installer\`$PatchCache$") -Label '$PatchCache$')
        }
        'Remove Delivery Optimization cache (dir delete) [100-500MB]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "Windows\SoftwareDistribution\DeliveryOptimization") -Label 'DeliveryOptimization cache')
        }
        'Remove Windows Store cache [varies]' {
            # The Store cache lives under each user profile and only exists after the first
            # sign-in, so there is nothing in the offline image to remove.
            Write-Host "    [INFO] Store cache is per-user; nothing exists in the offline image to remove" -ForegroundColor Gray
        }
        'Remove Provisioning packages [5-10MB]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "Windows\Provisioning") -Label 'Provisioning dir')
        }
        'Physical: Windows.old (complete removal) [varies]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "Windows.old") -Label 'Windows.old')
        }
        'Physical: OneDrive (complete removal) [~50MB]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "Windows\System32\OneDriveSetup.exe") -Label 'OneDriveSetup.exe')
        }
        'Physical: Cortana / Search (complete removal) [~100MB]' {
            foreach ($dir in @('Windows\SystemApps\Microsoft.Windows.Search_cw5n1h2txyewy', 'Windows\SystemApps\Microsoft.Cortana_cw5n1h2txyewy')) {
                [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath $dir) -Label $dir)
            }
        }
        'Remove non-Japanese language packs (DISM) [200-500MB]' {
            # The language of the image is always kept. A language whose option is off is
            # protected as well (RemoveLanguage<xx> = off means the pack stays).
            $protected = @('ja-JP', 'en-US')
            $imageLang = "$script:detectedImageLanguage"
            if ($imageLang) { $protected += $imageLang }
            try {
                $langPacks = & dism.exe /image:$scratchDir /Get-Packages /Format:Table 2>&1 | Select-String -Pattern 'LanguagePack'
                foreach ($lp in $langPacks) {
                    $pkgName = ($lp -split '\s+')[0]
                    if (-not $pkgName) { continue }
                    $pkgLang = $null
                    if ($pkgName -like '*ja-JP*') { $pkgLang = 'ja-JP' }
                    elseif ($pkgName -like '*ko-KR*') { $pkgLang = 'ko-KR' }
                    elseif ($pkgName -like '*zh-CN*') { $pkgLang = 'zh-CN' }
                    elseif ($pkgName -like '*zh-TW*') { $pkgLang = 'zh-TW' }
                    if (-not $pkgLang) { continue }
                    if ($protected -contains $pkgLang) { continue }
                    $allow = $true
                    switch ($pkgLang) {
                        'ja-JP' { $allow = (Test-TweakEnabled 'RemoveLanguageJaJP' $true) }
                        'ko-KR' { $allow = (Test-TweakEnabled 'RemoveLanguageKoKR' $true) }
                        'zh-CN' { $allow = (Test-TweakEnabled 'RemoveLanguageZhCN' $true) }
                        'zh-TW' { $allow = (Test-TweakEnabled 'RemoveLanguageZhTW' $true) }
                    }
                    if (-not $allow) {
                        Write-Host "    [SKIP] $pkgLang language pack: protected by its option" -ForegroundColor Gray
                        continue
                    }
                    if ($isDryRunMode) { Write-Host "    [DRY] Would remove: $pkgName" -ForegroundColor Yellow; continue }
                    & dism.exe /image:$scratchDir /Remove-Package /PackageName:$pkgName /NoRestart 2>&1 | Out-Null
                    Write-Host "    [OK] Removed: $pkgName" -ForegroundColor Green
                }
            } catch { Write-Host "    [WARN] Language pack removal failed: $_" -ForegroundColor Yellow }
        }
        'Remove Windows Sandbox [10-20MB]' {
            Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('Containers-DisposableClientVM')
        }
        'Remove WSL / VM Platform [20-40MB]' {
            if ($wslSupport) { Write-Host "    [SKIP] WSL support is enabled for this build; WSL / VM Platform kept" -ForegroundColor Yellow }
            else { Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') }
        }
        'Remove .NET Framework 3.5 [100MB]' {
            Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('NetFx3')
        }
        'Remove Windows Identity Foundation [10MB]' {
            Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('Windows-Identity-Foundation')
        }
        'Physical: Hyper-V / Virtualization stack [~200-400MB]' {
            Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('Microsoft-Hyper-V-All')
        }
        'Physical: IIS (Web server) [~50-100MB]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "Windows\System32\inetsrv") -Label 'inetsrv dir')
        }
        'Remove Windows Media Player (component) [50-100MB]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "Program Files\Windows Media Player") -Label 'Windows Media Player dir')
            try { & dism.exe /image:$scratchDir /Disable-Feature /FeatureName:WindowsMediaPlayer /NoRestart 2>&1 | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
        'Remove Windows PowerShell ISE [5MB]' {
            Invoke-WinEaseDebloatCapabilityRemoval -NamePatterns @('Microsoft.Windows.PowerShell.ISE~*')
        }
        'Remove Steps Recorder [2MB]' {
            Invoke-WinEaseDebloatCapabilityRemoval -NamePatterns @('App.StepsRecorder~*')
        }
        'Remove SNMP service [2MB]' {
            Invoke-WinEaseDebloatCapabilityRemoval -NamePatterns @('SNMP.Client~*', 'WMI-SNMP-Provider.Client~*')
        }
        'Remove Fax service [5MB]' {
            Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('FaxServicesClientPackage')
            Invoke-WinEaseDebloatCapabilityRemoval -NamePatterns @('Print.Fax.Scan~*')
        }
        'Remove XPS Viewer [5MB]' {
            Invoke-WinEaseDebloatCapabilityRemoval -NamePatterns @('XPS.Viewer~*')
            Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('Printing-XPSServices-Features')
        }
        'Remove Telnet/TFTP client [1MB]' {
            Invoke-WinEaseDebloatFeatureRemoval -FeatureNames @('TelnetClient', 'TFTP')
        }
        'Physical: Telemetry/DiagTrack (complete removal) [~30MB]' {
            [void](Remove-WinEaseDebloatPath -Path (Join-Path -Path $scratchDir -ChildPath "ProgramData\Microsoft\Diagnosis") -Label 'Diagnosis (telemetry) dir')
        }
        'Remove Provisioned AppX (list-based) [100-300MB]' {
            # Second pass over the Phase 05 pattern list (same protection whitelist) for the
            # packages that survived it. The decision is the shared one, so the installed
            # and the provisioned packages are treated exactly the same.
            if ($appxRegex -and $protectedAppxRegex) {
                $leftoverAppx = @(Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue | Where-Object {
                    Test-WinEaseAppxPackageRemovable -Name $_.PackageName -DisplayName $_.DisplayName -RemovalRegex $appxRegex -ProtectedRegex $protectedAppxRegex
                })
                if ($leftoverAppx.Count -eq 0) { Write-Host "    [OK] No listed provisioned AppX packages remain" -ForegroundColor Green }
                foreach ($pkg in $leftoverAppx) {
                    if ($isDryRunMode) { Write-Host "    [DRY] Would remove provisioned AppX: $($pkg.DisplayName)" -ForegroundColor Yellow; continue }
                    & dism.exe /English "/image:$scratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$($pkg.PackageName)" > $null 2>&1
                    if ($LASTEXITCODE -eq 0) { Write-Host "    [OK] Removed provisioned AppX: $($pkg.DisplayName)" -ForegroundColor Green }
                    else { Write-Host "    [WARN] Could not remove provisioned AppX: $($pkg.DisplayName)" -ForegroundColor Yellow }
                }
            } else {
                Write-Host "    [WARN] Phase 05 AppX pattern list unavailable; provisioned AppX pass skipped" -ForegroundColor Yellow
            }
        }
        default {
            Write-Host "    [SKIP] No safe handler in this phase: $Item" -ForegroundColor DarkGray
        }
    }
}

function Get-WinEaseDebloatSafeHandlerItems {
    # The targets the safe engine handles here. Every other target is executed by the phase
    # that owns it, either by its own option or by the target selection.
    return @(
        'Remove PatchCache (dir delete) [200-500MB]'
        'Remove Delivery Optimization cache (dir delete) [100-500MB]'
        'Remove Windows Store cache [varies]'
        'Remove Provisioning packages [5-10MB]'
        'Physical: Windows.old (complete removal) [varies]'
        'Physical: OneDrive (complete removal) [~50MB]'
        'Physical: Cortana / Search (complete removal) [~100MB]'
        'Physical: Telemetry/DiagTrack (complete removal) [~30MB]'
        'Remove non-Japanese language packs (DISM) [200-500MB]'
        'Remove Windows Sandbox [10-20MB]'
        'Remove WSL / VM Platform [20-40MB]'
        'Remove .NET Framework 3.5 [100MB]'
        'Remove Windows Identity Foundation [10MB]'
        'Physical: Hyper-V / Virtualization stack [~200-400MB]'
        'Physical: IIS (Web server) [~50-100MB]'
        'Remove Windows Media Player (component) [50-100MB]'
        'Remove Windows PowerShell ISE [5MB]'
        'Remove Steps Recorder [2MB]'
        'Remove SNMP service [2MB]'
        'Remove Fax service [5MB]'
        'Remove XPS Viewer [5MB]'
        'Remove Telnet/TFTP client [1MB]'
        'Remove Provisioned AppX (list-based) [100-300MB]'
    )
}

function Invoke-WinEaseDebloatTargets {
    # Runs the safe (PowerShell) engine for every selected target of one phase.
    #
    # The owning phase is declared per target in config\schema.psd1 (DebloatEngines ->
    # Phase), so the work of a target is executed exactly once, by the phase that owns it.
    param([Parameter(Mandatory = $true)][string]$Phase)
    $defs = Get-WinEaseDebloatEngines
    if (-not $defs) { return }
    $handlerItems = Get-WinEaseDebloatSafeHandlerItems
    $items = @($script:advancedDebloatStandard) + @($script:advancedDebloatExperimental)
    foreach ($item in @($items | Select-Object -Unique)) {
        $def = Get-WinEaseDebloatEngineDef -Item $item
        if (-not $def) { continue }
        if ([string]$def.Phase -ne $Phase) { continue }
        if (-not (Test-WinEaseDebloatTarget -Item $item -Engine 'PowerShell')) { continue }
        if ($handlerItems -notcontains $item) { continue }
        Write-Host "  [Debloat] Processing: $item" -ForegroundColor Gray
        Invoke-WinEaseDebloatTarget -Item $item
    }
}

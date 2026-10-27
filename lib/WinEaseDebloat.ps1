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

function Test-WinEaseDebloatTargetSelected {
    # True when the target is selected, no matter which engine removes it.
    #
    # The work that belongs to the target itself and not to one engine is done for both:
    # the services of the Spooler, the Bluetooth stack, the Remote Desktop host and the
    # BitLocker stack have to be disabled in any case, otherwise the image keeps a
    # service whose binary the Rust engine has just deleted.
    param([Parameter(Mandatory = $true)][string]$Item)
    $selected = @($script:advancedDebloatStandard) + @($script:advancedDebloatExperimental)
    return ($selected -contains $Item)
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
    elseif ($Item -match 'Memory.dmp') { return 'physical_memory_dmp' }
    elseif ($Item -match 'Minidump') { return 'physical_minidump' }
    elseif ($Item -match 'event logs') { return 'physical_event_logs' }
    elseif ($Item -match 'non-essential fonts') { return 'physical_fonts' }
    elseif ($Item -match 'non-Japanese IME') { return 'physical_ime' }
    # The packages the safe engine removes with DISM and the Rust engine with the forced
    # physical deletion of their payload.
    elseif ($Item -match '\.NET Framework 3\.5') { return 'physical_dotnet35' }
    elseif ($Item -match 'PowerShell ISE') { return 'physical_powershell_ise' }
    elseif ($Item -match 'Steps Recorder') { return 'physical_steps_recorder' }
    elseif ($Item -match 'Telnet') { return 'physical_telnet_tftp' }
    elseif ($Item -match 'SNMP') { return 'physical_snmp_client' }
    elseif ($Item -match 'Identity Foundation') { return 'physical_identity_foundation' }
    elseif ($Item -match 'Fax service') { return 'physical_fax' }
    elseif ($Item -match 'XPS Viewer') { return 'physical_xps_viewer' }
    # The paging files are not part of the mounted image: the safe engine disables them
    # after the setup, so they have no Rust key and no Rust target.
    elseif ($Item -match 'pagefile|hiberfil|swapfile') { return '' }
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
    #   Option = '<key>' a non-inverted pattern is independent of RemoveAppxBloatware:
    #                    it is applied when that setting is on. This is what makes the
    #                    Camera / Photos / Screen Sketch / Store / Defender options work
    #                    even when the general bloatware pass is off.
    #   Invert = $true   the setting is a "Keep..." option: the pattern is applied when
    #                    that setting is off. Keep options only belong to the default
    #                    removal list, so they need RemoveAppxBloatware to be on.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [hashtable]$Settings = @{},
        [object[]]$Definitions
    )
    if (-not $Definitions -or @($Definitions).Count -eq 0) { $Definitions = Get-WinEaseAppxRemovalDefinitions }
    if (@($Definitions).Count -eq 0) { return @() }
    $removeDefault = $Settings.ContainsKey('RemoveAppxBloatware') -and [bool]$Settings['RemoveAppxBloatware']
    $patterns = @()
    foreach ($d in $Definitions) {
        if (-not $d -or -not $d.Pattern) { continue }
        $option = [string]$d.Option
        if ([string]::IsNullOrWhiteSpace($option)) {
            if ($removeDefault) { $patterns += [string]$d.Pattern }
            continue
        }
        if ([bool]$d.Invert -and -not $removeDefault) { continue }
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
function Remove-WinEaseDebloatLanguagePacks {
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

function Remove-WinEaseDebloatProvisionedAppx {
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

function Test-WinEaseSystem32BinaryPath {
    # True when the payload path points at a binary of the system directory.
    #
    # The safe engine must not delete those (Directive 2.1 of phase 08): the file is
    # hardlinked into the component store (WinSxS), and deleting one of the two links
    # desyncs the hardlink set of the image. The export then fails with 0x80070570
    # (Data Error) and the installer ends in a reboot loop. A shared library makes it
    # worse: wmisnmp.dll and snmpapi.dll belong to WMI, mpssvc.dll to the firewall.
    # The service of the target is disabled in phase 10 instead, which is what the
    # removal of a service is about.
    param([Parameter(Mandatory = $true)][string]$Path)
    $norm = (([string]$Path) -replace '/', '\').TrimStart('\')
    return [bool]($norm -match '^(?i)Windows\\(System32|SysWOW64|SysNative)\\')
}

function Remove-WinEaseDebloatPayload {
    # Deletes the payload of a target (config\schema.psd1 -> DebloatEngines -> Payload).
    #
    # This is the safe counterpart of the Rust engine: the same files are removed, but
    # with the normal permissions. A protected folder is taken over first, a file is
    # deleted directly. A path that does not exist in the image is skipped, so a payload
    # that belongs to another Windows build never breaks the build.
    param(
        [Parameter(Mandatory = $true)][string]$Item,
        [string[]]$Paths = @()
    )
    if (-not $Paths -or $Paths.Count -eq 0) {
        $def = Get-WinEaseDebloatEngineDef -Item $Item
        if ($def -and $def.Payload) { $Paths = @($def.Payload) }
    }
    if (-not $Paths -or $Paths.Count -eq 0) {
        Write-Host "    [SKIP] No payload is declared for: $Item" -ForegroundColor DarkGray
        return
    }
    foreach ($rel in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$rel)) { continue }
        $full = Join-Path -Path $scratchDir -ChildPath ([string]$rel)
        # a wildcard path is expanded first (the payload of some targets is a family of
        # folders, e.g. the Edge packages of the WindowsApps folder)
        $targets = @()
        if ([string]$rel -match '[\*\?]') {
            $targets = @(Get-ChildItem -Path $full -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            if ($targets.Count -eq 0) {
                Write-Host "    [SKIP] No match for: $rel" -ForegroundColor DarkGray
                continue
            }
        } else {
            $targets = @($full)
        }
        foreach ($target in $targets) {
            if (-not (Test-Path -LiteralPath $target)) { continue }
            $entry = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            $isDirectory = ($entry -is [System.IO.DirectoryInfo])
            if ($isDryRunMode) {
                Write-Host "    [DRY] Would delete: $target" -ForegroundColor Yellow
                continue
            }
            if ($isDirectory) {
                # a protected folder is taken over first, the rest is removed normally
                if (Get-Command -Name 'Remove-ProtectedDirectory' -ErrorAction SilentlyContinue) {
                    try {
                        Remove-ProtectedDirectory -Path $target -ScratchPath $scratchDir
                    } catch {
                        Write-Host "    [WARN] Could not remove $target : $_" -ForegroundColor Yellow
                        continue
                    }
                } else {
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                # Directive 2.1: a binary of the system directory is never deleted by the
                # safe engine. The path is checked relative to the mount, so the check
                # works for the wildcard payloads as well.
                $relTarget = [string]$rel
                $scratchNorm = (([string]$scratchDir) -replace '/', '\').TrimEnd('\')
                $targetNorm = (([string]$target) -replace '/', '\')
                if ($scratchNorm -and $targetNorm.StartsWith($scratchNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relTarget = $targetNorm.Substring($scratchNorm.Length).TrimStart('\')
                }
                if (Test-WinEaseSystem32BinaryPath -Path $relTarget) {
                    Write-Host "    [SKIP] System32 binary, not deleted by the safe engine: $target" -ForegroundColor Yellow
                    continue
                }
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $target) {
                Write-Host "    [WARN] Could not delete: $target" -ForegroundColor Yellow
            } else {
                Write-Host "    [OK] Deleted $target" -ForegroundColor Green
            }
        }
    }
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
            Remove-WinEaseDebloatLanguagePacks
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
            Remove-WinEaseDebloatProvisionedAppx
        }
        # The targets below are the ones the Rust engine removes with the forced physical
        # deletion. The safe engine removes the same payload (config\schema.psd1 ->
        # DebloatEngines -> Payload), so the user can pick the engine of the target.
        'Physical: Edge / WebView2 (complete removal) [~200MB]' {
            Remove-WinEaseDebloatPayload -Item 'Physical: Edge / WebView2 (complete removal) [~200MB]'
        }
        'Physical: Defender (complete removal) [~50MB]' {
            Remove-WinEaseDebloatPayload -Item 'Physical: Defender (complete removal) [~50MB]'
        }
        'Physical: Windows Firewall (complete removal) [~20-40MB]' {
            Remove-WinEaseDebloatPayload -Item 'Physical: Windows Firewall (complete removal) [~20-40MB]'
        }
        'Physical: Windows Search index (complete removal) [varies]' {
            Remove-WinEaseDebloatPayload -Item 'Physical: Windows Search index (complete removal) [varies]'
        }
        'Physical: Memory.dmp (complete removal) [varies]' {
            Remove-WinEaseDebloatPayload -Item 'Physical: Memory.dmp (complete removal) [varies]'
        }
        'Physical: Minidump (complete removal) [varies]' {
            Remove-WinEaseDebloatPayload -Item 'Physical: Minidump (complete removal) [varies]'
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
        # The targets the Rust engine removes with the forced physical deletion: the safe
        # engine deletes the same payload.
        'Physical: Edge / WebView2 (complete removal) [~200MB]'
        'Physical: Defender (complete removal) [~50MB]'
        'Physical: Windows Firewall (complete removal) [~20-40MB]'
        'Physical: Windows Search index (complete removal) [varies]'
        'Physical: Memory.dmp (complete removal) [varies]'
        'Physical: Minidump (complete removal) [varies]'
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

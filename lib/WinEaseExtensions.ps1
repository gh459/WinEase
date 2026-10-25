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

    # Per-file user presets live in a folder next to the user config: config\user\presets\<key>.psd1
    # (one preset per file, written by the GUI "Save as preset"). A legacy user-tweaks.psd1 left in
    # config\ still resolves to the new presets folder.
    $presetsDir = $null
    $configDir = Split-Path -Parent $ConfigPath
    if ($configDir) {
        if ((Split-Path -Leaf $configDir) -ieq 'user') { $presetsDir = Join-Path -Path $configDir -ChildPath 'presets' }
        else { $presetsDir = Join-Path -Path (Split-Path -Parent $configDir) -ChildPath 'config\user\presets' }
    }

    $data = $null
    $loadedMain = $false
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $ConfigPath
            $loadedMain = $true
        } catch {
            $msg = "Failed to load '$ConfigPath': $($_.Exception.Message)"
            $errors += $msg
            Write-Warning "[UserExtensions] $msg"
        }
    }

    # UserTweaks
    if (-not $PresetsOnly -and $data -and $data.UserTweaks) {
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
    if ($data -and $data.UserPresets) {
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

    # Per-file user presets. The file name (without extension) is the preset key, the content is
    # the same override hashtable a UserPresets entry holds. The rules the GUI save enforces also
    # apply to hand-made files: no built-in preset name (the order of config\presets.psd1, which
    # both windows also hard-code) and not the reserved 'custom' - such a file is skipped with a
    # warning instead of overriding a built-in preset. Keys of presets loaded earlier (a save
    # reloads before this runs again) are user presets and are simply loaded again.
    $folderPresetCount = 0
    $knownBuiltInKeys = @('none', 'extreme', 'balanced', 'fat32', 'handheld', 'vm', 'audio')
    if ($presetsDir -and (Test-Path -LiteralPath $presetsDir)) {
        foreach ($presetFile in @(Get-ChildItem -LiteralPath $presetsDir -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $presetKey = ([System.IO.Path]::GetFileNameWithoutExtension($presetFile.Name)).Trim().ToLower()
            if (-not $presetKey) { continue }
            if ($presetKey -eq 'custom' -or $knownBuiltInKeys -contains $presetKey) {
                $msg = "User preset file '$($presetFile.Name)' uses a reserved or built-in preset name; skipped."
                $errors += $msg
                Write-Warning "[UserExtensions] $msg"
                continue
            }
            try {
                $presetData = Import-PowerShellDataFile -LiteralPath $presetFile.FullName
            } catch {
                $msg = "Failed to load user preset '$($presetFile.FullName)': $($_.Exception.Message)"
                $errors += $msg
                Write-Warning "[UserExtensions] $msg"
                continue
            }
            if ($presetData -isnot [System.Collections.IDictionary]) {
                $msg = "User preset '$($presetFile.FullName)' does not contain a hashtable; skipped."
                $errors += $msg
                Write-Warning "[UserExtensions] $msg"
                continue
            }
            $merged = @{}
            if ($presetData.BasePreset -and $script:BuiltInPresets -and $script:BuiltInPresets.Contains($presetData.BasePreset)) {
                $base = $script:BuiltInPresets[$presetData.BasePreset]
                if ($base -is [System.Collections.IDictionary]) {
                    foreach ($k in $base.Keys) { $merged[$k] = $base[$k] }
                } elseif ($base.PSObject) {
                    foreach ($p in $base.PSObject.Properties) { $merged[$p.Name] = $p.Value }
                }
            }
            foreach ($k in $presetData.Keys) { if ($k -ne 'BasePreset') { $merged[$k] = $presetData[$k] } }
            if ($script:BuiltInPresets) { $script:BuiltInPresets[$presetKey] = $merged }
            else { if (-not $script:UserPresets) { $script:UserPresets = [ordered]@{} }; $script:UserPresets[$presetKey] = $merged }
            $folderPresetCount++
            $loadedAny = $true
        }
    }

    # CustomScripts
    if (-not $PresetsOnly) {
    $validStages = @('PreBuild','OfflineImage','FirstLogon','UserOnce')
    $validOnErrors = @('Stop','Warn','Ignore')
    if ($data -and $data.CustomScripts) {
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
        Loaded                = ($loadedMain -or $loadedAny)
        UserTweakCount        = @($script:UserTweakDefs.Keys).Count
        UserPresetCount       = (($data.UserPresets | Measure-Object).Count + $folderPresetCount)
        UserPresetFolderCount = $folderPresetCount
        CustomScriptCount     = @($script:UserCustomScripts).Count
        Errors                = $errors
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
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
            $results += $r
        }
    }
    return [PSCustomObject]@{ AppliedCount = $applied; FailedCount = $failed; Results = $results }
}

# 3. Get-WinEaseCustomScriptMetadata
# The metadata header uses the comment syntax of the file type: '#' for .ps1, 'REM' for
# .bat/.cmd and ';' for .reg. Without this a batch or registry file could never carry a
# description, an order or a condition.
function Get-WinEaseCustomScriptCommentPrefix {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)
    $ext = ''
    try { $ext = [System.IO.Path]::GetExtension([string]$Path).ToLowerInvariant() } catch { $ext = '' }
    switch ($ext) {
        '.bat' { return 'REM' }
        '.cmd' { return 'REM' }
        '.reg' { return ';' }
        default { return '#' }
    }
}

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
        Comment     = (Get-WinEaseCustomScriptCommentPrefix -Path $ScriptPath)
    }
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return $meta }
    try {
        $meta.Sha256 = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    try {
        $lines = [System.IO.File]::ReadAllLines($ScriptPath) | Select-Object -First 30
        foreach ($ln in $lines) {
            if ($ln -match '^\s*(?:#|REM|;)\s*@WinEase-Stage:\s*(.+)$') { $meta.Stage = $matches[1].Trim() }
            elseif ($ln -match '^\s*(?:#|REM|;)\s*@WinEase-Order:\s*(\d+)') { $meta.Order = [int]$matches[1] }
            elseif ($ln -match '^\s*(?:#|REM|;)\s*@WinEase-Condition:\s*(.+)$') { $meta.Condition = $matches[1].Trim() }
            elseif ($ln -match '^\s*(?:#|REM|;)\s*@WinEase-OnError:\s*(Stop|Warn|Ignore)') { $meta.OnError = $matches[1] }
            elseif ($ln -match '^\s*(?:#|REM|;)\s*@WinEase-Description:\s*(.+)$') { $meta.Description = $matches[1].Trim() }
            elseif ($ln -match '^\s*(?:#|REM|;)\s*@WinEase-Id:\s*(.+)$') { $meta.Id = $matches[1].Trim() }
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

# The four stages of the custom script pipeline: where the scripts live in the repository, where
# they end up in the image and with which rights they run.
function Get-WinEaseCustomScriptStageMap {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(
        [PSCustomObject]@{ Stage = 'PreBuild';    RepoFolder = 'tools\custom-scripts\PreBuild';    ImageFolder = '';                                   RunsAs = 'BuildHost';     LegacyFolder = '' }
        [PSCustomObject]@{ Stage = 'OfflineImage'; RepoFolder = 'tools\custom-scripts\OfflineImage'; ImageFolder = '';                                   RunsAs = 'BuildHost';     LegacyFolder = '' }
        [PSCustomObject]@{ Stage = 'FirstLogon';  RepoFolder = 'tools\custom-scripts\FirstLogon';  ImageFolder = 'Windows\Setup\Scripts\Custom';     RunsAs = 'Administrator'; LegacyFolder = 'tools\custom-scripts' }
        [PSCustomObject]@{ Stage = 'UserOnce';    RepoFolder = 'tools\custom-scripts\UserOnce';    ImageFolder = 'Windows\Setup\Scripts\UserCustom'; RunsAs = 'StandardUser'; LegacyFolder = 'tools\custom-scripts\user' }
    )
}

# The file types the first logon and the user context execute.
function Get-WinEaseCustomScriptExtensions {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('.ps1', '.bat', '.cmd', '.reg')
}

# The folder of the image a stage script is executed from. The scripts are copied flat: the first
# logon and the user context read the folder with a non-recursive Get-ChildItem -File, so a script
# in a sub folder would never run.
function Get-WinEaseCustomScriptImageDir {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('PreBuild','OfflineImage','FirstLogon','UserOnce')][string]$Stage,
        [Parameter(Mandatory = $true)][string]$ScratchDir
    )
    $sub = if ($Stage -eq 'UserOnce') { 'Windows\Setup\Scripts\UserCustom' } else { 'Windows\Setup\Scripts\Custom' }
    return (Join-Path -Path $ScratchDir -ChildPath $sub)
}

# The key of a script in the build-time integrity manifest: the plain file name for the elevated
# first logon, "user/<name>" for the standard user context (that is how both pipelines look it up).
function Get-WinEaseCustomScriptManifestKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    if ($Stage -eq 'UserOnce') { return "user/$FileName" }
    return $FileName
}

# Registers a copied script in the build-time integrity manifest. The first logon refuses every
# file that is not listed there, so a script that is copied into the image has to be registered.
function Add-WinEaseCustomScriptManifestEntry {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$ScratchDir,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$FilePath
    )
    $manifestPath = Join-Path -Path $ScratchDir -ChildPath 'Windows\Setup\Scripts\custom-scripts-manifest.json'
    $manifest = [ordered]@{}
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $manifest[$p.Name] = [string]$p.Value }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $hash = ''
    try { $hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace($hash)) { return $false }
    $manifest[(Get-WinEaseCustomScriptManifestKey -Stage $Stage -FileName $FileName)] = $hash
    try {
        $json = $manifest | ConvertTo-Json -Depth 2
        if (Get-Command -Name 'Write-WinEaseTextFileAtomic' -ErrorAction SilentlyContinue) {
            Write-WinEaseTextFileAtomic -Path $manifestPath -Content $json | Out-Null
        } else {
            [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {
        Write-Verbose "Ignored: $($_.Exception.Message)"
        return $false
    }
    return $true
}

# Resolves a script path that may be relative to the repository (the user extension file stores
# paths like 'tools\custom-scripts\PreBuild\01-check.ps1').
function Resolve-WinEaseCustomScriptPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Context = @{}
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    $root = ''
    if ($Context -and $Context.ContainsKey('ScriptRoot') -and $Context['ScriptRoot']) { $root = [string]$Context['ScriptRoot'] }
    elseif ($Context -and $Context.ContainsKey('RepoRoot') -and $Context['RepoRoot']) { $root = [string]$Context['RepoRoot'] }
    if (-not $root) { $root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path } }
    return (Join-Path -Path $root -ChildPath $p)
}

# True when the file carries an @WinEase-Order header.
function Test-WinEaseCustomScriptHasHeaderOrder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        foreach ($ln in @([System.IO.File]::ReadAllLines($Path) | Select-Object -First 30)) {
            if ($ln -match '^\s*(?:#|REM|;)\s*@WinEase-Order:\s*\d+') { return $true }
        }
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return $false
}

# The order of a script: the @WinEase-Order header wins, otherwise the numeric prefix of the file
# name decides (that is the order the first logon uses: it sorts the files by name).
function Get-WinEaseCustomScriptEffectiveOrder {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$HeaderOrder = 100,
        [bool]$HasHeaderOrder = $false
    )
    if ($HasHeaderOrder) { return $HeaderOrder }
    $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$Path)
    if ($name -match '^(\d+)') { return [int]$matches[1] }
    return 100
}

# The scripts of one stage (or of all stages) with their metadata: what the GUI shows.
function Get-WinEaseCustomScriptInventory {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$Stage = ''
    )
    $map = @(Get-WinEaseCustomScriptStageMap)
    if ($Stage) { $map = @($map | Where-Object { $_.Stage -eq $Stage }) }
    $items = @()
    foreach ($stageInfo in $map) {
        $files = @(Get-WinEaseCustomScriptFiles -RepoRoot $RepoRoot -Stage $stageInfo.Stage)
        if ($stageInfo.LegacyFolder) {
            $legacyDir = Join-Path -Path $RepoRoot -ChildPath $stageInfo.LegacyFolder
            if (Test-Path -LiteralPath $legacyDir) {
                $files += @(Get-ChildItem -LiteralPath $legacyDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'README.md' -and $_.Name -ne '.gitkeep' })
            }
        }
        foreach ($f in $files) {
            $meta = Get-WinEaseCustomScriptMetadata -ScriptPath $f.FullName
            $hasOrder = Test-WinEaseCustomScriptHasHeaderOrder -Path $f.FullName
            $inStage = ($f.DirectoryName -eq (Join-Path -Path $RepoRoot -ChildPath $stageInfo.RepoFolder))
            $items += [PSCustomObject]@{
                Stage          = $stageInfo.Stage
                Name           = $f.Name
                FullPath       = $f.FullName
                Extension      = $f.Extension.ToLowerInvariant()
                Size           = $f.Length
                Sha256         = $meta.Sha256
                Id             = $meta.Id
                Order          = $meta.Order
                HasHeaderOrder = $hasOrder
                EffectiveOrder = (Get-WinEaseCustomScriptEffectiveOrder -Path $f.FullName -HeaderOrder $meta.Order -HasHeaderOrder $hasOrder)
                Condition      = $meta.Condition
                OnError        = $meta.OnError
                Description    = $meta.Description
                Comment        = $meta.Comment
                RunsAs         = $stageInfo.RunsAs
                ImageFolder    = $stageInfo.ImageFolder
                Location       = if ($inStage) { 'Stage' } else { 'Legacy' }
            }
        }
    }
    return @($items | Sort-Object Stage, EffectiveOrder, Name)
}

# Copies a script into a stage folder. The file name gets a numeric prefix so that the order of
# the scripts is visible and stable (the first logon runs them sorted by name).
function Add-WinEaseCustomScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][ValidateSet('PreBuild','OfflineImage','FirstLogon','UserOnce')][string]$Stage,
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [switch]$Overwrite
    )
    $added = @()
    $skipped = @()
    $errors = @()
    $validExts = @(Get-WinEaseCustomScriptExtensions)
    $stageInfo = @(Get-WinEaseCustomScriptStageMap | Where-Object { $_.Stage -eq $Stage })[0]
    if (-not $stageInfo) { throw "Unknown stage '$Stage'." }
    $targetDir = Join-Path -Path $RepoRoot -ChildPath $stageInfo.RepoFolder
    foreach ($p in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $src = $p.Trim()
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $errors += "File not found: '$src'"
            continue
        }
        $ext = [System.IO.Path]::GetExtension($src).ToLowerInvariant()
        if ($validExts -notcontains $ext) {
            $errors += "Unsupported file type '$ext' (allowed: $($validExts -join ', ')): '$src'"
            continue
        }
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($src)
        $rest = [System.IO.Path]::GetFileName($src)
        if ($leaf -match '^(\d+)[-_]?(.*)$') {
            $prefix = [int]$matches[1]
            $tail = $matches[2] + [System.IO.Path]::GetExtension($src)
        } else {
            $prefix = 0
            $tail = $rest
        }
        if ($prefix -le 0) {
            # next free index (two digits, like 01- / 02-)
            $used = @(Get-ChildItem -LiteralPath $targetDir -File -ErrorAction SilentlyContinue |
                ForEach-Object { if ([System.IO.Path]::GetFileNameWithoutExtension($_.Name) -match '^(\d+)') { [int]$matches[1] } })
            $prefix = 1
            while ($used -contains $prefix) { $prefix++ }
            $tail = $rest
        }
        $targetName = ('{0:D2}-{1}' -f $prefix, $tail)
        $target = Join-Path -Path $targetDir -ChildPath $targetName
        if (Test-Path -LiteralPath $target) {
            if (-not $Overwrite) {
                $errors += "A script with the name '$targetName' already exists in $stageInfo.RepoFolder."
                continue
            }
            Remove-Item -LiteralPath $target -Force
        }
        try {
            Copy-Item -LiteralPath $src -Destination $target -Force
            $added += [PSCustomObject]@{ Name = $targetName; Path = $target; Stage = $Stage }
        } catch {
            $errors += "Could not copy '$src': $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ Stage = $Stage; Added = $added; Skipped = $skipped; Errors = $errors }
}

# Deletes a script from a stage folder. The README and the .gitkeep of the stage folders stay.
function Remove-WinEaseCustomScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'No script was given.' }
    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path -Path $RepoRoot -ChildPath $full }
    $full = [System.IO.Path]::GetFullPath($full)
    $base = [System.IO.Path]::GetFullPath((Join-Path -Path $RepoRoot -ChildPath 'tools\custom-scripts'))
    if (-not ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Only scripts inside '$base' can be removed."
    }
    $leaf = [System.IO.Path]::GetFileName($full)
    if ($leaf -eq 'README.md' -or $leaf -eq '.gitkeep') { throw "'$leaf' is part of the repository and cannot be removed." }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Script not found: '$full'." }
    Remove-Item -LiteralPath $full -Force
    return [PSCustomObject]@{ Stage = $Stage; Removed = $leaf; Path = $full }
}

# The encoding of a script file: the BOM decides, without a BOM the system default (ANSI) is used
# because Windows PowerShell 5.1 reads such a script that way.
function Get-WinEaseCustomScriptEncoding {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return @{ Encoding = (New-Object System.Text.UTF8Encoding($true)); HasBom = $true }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return @{ Encoding = (New-Object System.Text.UnicodeEncoding($false, $true)); HasBom = $true }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return @{ Encoding = (New-Object System.Text.UnicodeEncoding($true, $true)); HasBom = $true }
    }
    return @{ Encoding = [System.Text.Encoding]::Default; HasBom = $false }
}

# Writes the metadata header of a script. The keys are written in the comment syntax of the file
# type ('#' for .ps1, 'REM' for .bat/.cmd, ';' for .reg).
function Set-WinEaseCustomScriptMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Order = -1,
        [string]$Condition,
        [string]$OnError,
        [string]$Description,
        [string]$Id
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Script not found: '$Path'." }
    $info = Get-WinEaseCustomScriptEncoding -Path $Path
    $text = [System.IO.File]::ReadAllText($Path, $info.Encoding)
    $lineEnding = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in ($text -split "`r`n|`n")) { $lines.Add($ln) }
    $prefix = Get-WinEaseCustomScriptCommentPrefix -Path $Path
    $keys = [ordered]@{}
    if ($Order -ge 0) { $keys['Order'] = "$Order" }
    if ($PSBoundParameters.ContainsKey('Condition')) { $keys['Condition'] = $Condition }
    if ($PSBoundParameters.ContainsKey('OnError') -and $OnError) { $keys['OnError'] = $OnError }
    if ($PSBoundParameters.ContainsKey('Description')) { $keys['Description'] = $Description }
    if ($PSBoundParameters.ContainsKey('Id') -and $Id) { $keys['Id'] = $Id }
    # replace the existing header lines, add the missing ones after the last header line
    $lastHeader = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(?:#|REM|;)\s*@WinEase-(Id|Stage|Order|Condition|OnError|Description)\s*:') { $lastHeader = $i }
    }
    foreach ($key in $keys.Keys) {
        $pattern = '^\s*(?:#|REM|;)\s*@WinEase-' + $key + '\s*:.*$'
        $found = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) { $found = $i; break }
        }
        # not $newLine: PowerShell does not distinguish case, it would overwrite the line ending
        $metaLine = "$prefix @WinEase-$key`: $($keys[$key])"
        if ($found -ge 0) {
            $lines[$found] = $metaLine
        } elseif ($lastHeader -ge 0) {
            $lines.Insert($lastHeader + 1, $metaLine)
            $lastHeader++
        } else {
            $lines.Insert(0, $metaLine)
            $lastHeader = 0
        }
    }
    $out = ($lines -join $lineEnding)
    [System.IO.File]::WriteAllText($Path, $out, $info.Encoding)
    return (Get-WinEaseCustomScriptMetadata -ScriptPath $Path)
}

# Changes the numeric prefix of a script file name: that is the order the first logon uses.
function Move-WinEaseCustomScriptOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$NewOrder
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Script not found: '$Path'." }
    if ($NewOrder -lt 0) { throw 'The new order must not be negative.' }
    $dir = Split-Path -Parent $Path
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    if ($leaf -match '^\d+[-_]?(.*)$') { $tail = $matches[1] } else { $tail = $leaf }
    $newName = ('{0:D2}-{1}{2}' -f $NewOrder, $tail, $ext)
    $target = Join-Path -Path $dir -ChildPath $newName
    if ($target -eq $Path) { return [PSCustomObject]@{ Path = $Path; Name = $newName; Changed = $false } }
    if (Test-Path -LiteralPath $target) { throw "A script named '$newName' already exists." }
    Rename-Item -LiteralPath $Path -NewName $newName -Force
    return [PSCustomObject]@{ Path = $target; Name = $newName; Changed = $true }
}

# What ends up in the image: the scripts of the post install stages with their target and hash.
function Get-WinEaseCustomScriptPreview {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    $items = @()
    foreach ($stageInfo in @(Get-WinEaseCustomScriptStageMap)) {
        if (-not $stageInfo.ImageFolder) { continue }
        foreach ($entry in @(Get-WinEaseCustomScriptInventory -RepoRoot $RepoRoot -Stage $stageInfo.Stage)) {
            $items += [PSCustomObject]@{
                Stage     = $stageInfo.Stage
                Name      = $entry.Name
                ImagePath = (Join-Path -Path $stageInfo.ImageFolder -ChildPath $entry.Name)
                RunsAs    = $stageInfo.RunsAs
                Sha256    = $entry.Sha256
                Location  = $entry.Location
            }
        }
    }
    return @($items)
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
            # The path may be relative to the repository (config\user\user-tweaks.psd1)
            $csPath = Resolve-WinEaseCustomScriptPath -Path ([string]$cs.Path) -Context $Context
            if ([string]::IsNullOrWhiteSpace($csPath)) { continue }
            $candidates += [PSCustomObject]@{
                Id          = [string]$cs.Id
                Path        = $csPath
                Stage       = [string]$cs.Stage
                Order       = [int]$cs.Order
                Condition   = [string]$cs.Condition
                OnError     = [string]$cs.OnError
                Description = [string]$cs.Description
                Sha256      = ''
            }
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
            # FirstLogon / UserOnce: copy into the offline image.
            # Two destinations, because two different runners pick the scripts up:
            #   1. Windows\Setup\Scripts\Custom\<Stage>  - the .ps1 files are registered as
            #      FirstLogonCommands in autounattend.xml (phase 11 reads that folder).
            #   2. Windows\Setup\Scripts\Custom (FirstLogon) or ...\UserCustom (UserOnce) - the
            #      flat folder the custom script pipeline executes (it reads the folder with a
            #      non-recursive Get-ChildItem -File, so a script in a sub folder would never run).
            # The flat copy is what makes .bat/.cmd/.reg and the UserOnce stage work at all.
            $scratchDir = if ($Context.ScratchDir) { $Context.ScratchDir } else { $script:BaseWorkDir }
            if ($scratchDir) {
                $fileName = [System.IO.Path]::GetFileName($meta.Path)
                # 1. the stage folder: the .ps1 files of the FirstLogon stage are registered as
                #    FirstLogonCommands in autounattend.xml (phase 11 reads that folder)
                if ($Stage -eq 'FirstLogon') {
                    $stageDir = Join-Path -Path $scratchDir -ChildPath "Windows\Setup\Scripts\Custom\$Stage"
                    if (-not (Test-Path -LiteralPath $stageDir)) { New-Item -ItemType Directory -Force -Path $stageDir | Out-Null }
                    Copy-Item -LiteralPath $meta.Path -Destination (Join-Path -Path $stageDir -ChildPath $fileName) -Force
                }
                # 2. the flat folder the custom script pipeline executes: it reads the folder with a
                #    non-recursive Get-ChildItem -File, so a script in a sub folder would never run
                $targetDir = Get-WinEaseCustomScriptImageDir -Stage $Stage -ScratchDir $scratchDir
                if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
                $targetFile = Join-Path -Path $targetDir -ChildPath $fileName
                Copy-Item -LiteralPath $meta.Path -Destination $targetFile -Force
                # The pipeline refuses every file that is not listed in the build-time integrity
                # manifest, so the copied script is registered there with its hash.
                if (-not (Add-WinEaseCustomScriptManifestEntry -ScratchDir $scratchDir -Stage $Stage -FileName $fileName -FilePath $targetFile)) {
                    Write-Warning "Custom script '$fileName' was copied but could not be registered in the integrity manifest."
                }
            }
            $executed += $meta
        }
    }

    return [PSCustomObject]@{ Stage = $Stage; Executed = $executed; Skipped = $skipped; Failed = $failed }
}

# Stage 2 (build phase): Deploy the extension host script to the custom-scripts directory
# of the built ISO. This ensures the extension script runs during FirstLogon.
function Install-WinEaseExtensionHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CustomScriptsDir
    )

    if (-not (Test-Path -LiteralPath $CustomScriptsDir)) {
        New-Item -ItemType Directory -Path $CustomScriptsDir -Force | Out-Null
    }

    $hostContent = @"
# WinEase Extension Host Script
param(
    [string]`$Stage = 'FirstLogon'
)
Write-Verbose "Executing extension host for stage `$Stage"
"@

    $targetFile = Join-Path -Path $CustomScriptsDir -ChildPath "WinEaseExtensionHost.ps1"
    Set-Content -LiteralPath $targetFile -Value $hostContent -Encoding UTF8
    return $targetFile
}

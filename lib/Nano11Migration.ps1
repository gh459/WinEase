# Nano11Migration.ps1 - PC migration / backup / restore engine for nano11
# Dot-sourced by tools/Nano11-Migrator.ps1 (and the GUI migration tab) and by the test suite.
# nano11builder.ps1 does NOT load this file. Depends on Test-Nano11PathWithin from
# nano11helpers.ps1, so the caller must dot-source nano11helpers.ps1 first.

# 1. Expand-Nano11MigrationPath
function Expand-Nano11MigrationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawPath
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($RawPath)
    try { $expanded = [System.IO.Path]::GetFullPath($expanded) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return $expanded
}

# 2. Get-Nano11MigrationRules
function Get-Nano11MigrationRules {
    [CmdletBinding()]
    param(
        [string]$BuiltInPath,
        [string]$UserPath
    )
    $scriptDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
    if ([string]::IsNullOrWhiteSpace($BuiltInPath)) { $BuiltInPath = Join-Path -Path $scriptDir -ChildPath 'config\migration-rules.psd1' }
    if ([string]::IsNullOrWhiteSpace($UserPath)) { $UserPath = Join-Path -Path $scriptDir -ChildPath 'config\user-migration-rules.psd1' }

    $gameRules = @()
    $appRules = @()
    $customPathRules = @()
    $secretPatterns = @()
    $errors = @()

    if (Test-Path -LiteralPath $BuiltInPath) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $BuiltInPath
            if ($data.DefaultSecretExcludePatterns) { $secretPatterns += $data.DefaultSecretExcludePatterns }
            if ($data.GameRules) { $gameRules += $data.GameRules }
            if ($data.AppConfigRules) { $appRules += $data.AppConfigRules }
            if ($data.CustomPathRules) { $customPathRules += $data.CustomPathRules }
        } catch {
            $errors += "Failed to load '$BuiltInPath': $($_.Exception.Message)"
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $UserPath) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $UserPath
            if ($data.DefaultSecretExcludePatterns) { $secretPatterns += $data.DefaultSecretExcludePatterns }
            if ($data.GameRules) {
                foreach ($r in $data.GameRules) {
                    if ($gameRules.Id -contains $r.Id) { $errors += "Duplicate rule Id '$($r.Id)' in user rules; skipped." ; continue }
                    $gameRules += $r
                }
            }
            if ($data.AppConfigRules) {
                foreach ($r in $data.AppConfigRules) {
                    if ($appRules.Id -contains $r.Id) { $errors += "Duplicate rule Id '$($r.Id)' in user rules; skipped." ; continue }
                    $appRules += $r
                }
            }
            if ($data.CustomPathRules) {
                foreach ($r in $data.CustomPathRules) {
                    if ($customPathRules.Id -contains $r.Id) { $errors += "Duplicate rule Id '$($r.Id)' in user rules; skipped." ; continue }
                    $customPathRules += $r
                }
            }
        } catch {
            $errors += "Failed to load '$UserPath': $($_.Exception.Message)"
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    $secretPatterns = $secretPatterns | Select-Object -Unique
    return [PSCustomObject]@{ GameRules = $gameRules; AppConfigRules = $appRules; CustomPathRules = $customPathRules; SecretPatterns = $secretPatterns; Errors = $errors }
}

# 3. Test-Nano11SecretPath
function Test-Nano11SecretPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$SecretPatterns = @()
    )
    $name = [System.IO.Path]::GetFileName($FilePath)
    foreach ($pat in $SecretPatterns) {
        if ($name -like $pat) { return $true }
        if ($FilePath -like $pat) { return $true }
    }
    return $false
}

# 4. Export-Nano11AppInventory
function Export-Nano11AppInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [switch]$OfflineTestMode,
        [object[]]$MockRegistryEntries
    )
    $apps = @()
    $entries = @()
    if ($MockRegistryEntries) {
        $entries = $MockRegistryEntries
    } elseif (-not $OfflineTestMode) {
        $regPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($rp in $regPaths) {
            try {
                $items = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
                foreach ($it in $items) {
                    if (-not $it.DisplayName) { continue }
                    if ($it.SystemComponent -eq 1) { continue }
                    $entries += $it
                }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
    }

    $wingetAvailable = $false
    $wingetLookup = @{}
    if (-not $OfflineTestMode) {
        try {
            $null = Get-Command winget -ErrorAction Stop
            $wingetAvailable = $true
            # Run winget list ONCE and build a lookup table (avoids per-app shell-outs that freeze the UI)
            try {
                $wl = & winget list --accept-source-agreements 2>$null
                if ($wl) {
                    foreach ($line in $wl) {
                        # winget list output: Name  Id  Version  Source
                        if ($line -match '^(.+?)\s{2,}(\S+)\s+\S+(\s+\S+)?$') {
                            $wName = $matches[1].Trim().ToLower()
                            $wId = $matches[2].Trim()
                            if ($wName -and $wId -and -not $wingetLookup.ContainsKey($wName)) {
                                $wingetLookup[$wName] = $wId
                            }
                        }
                    }
                }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    foreach ($e in $entries) {
        $name = $e.DisplayName
        if (-not $name) { continue }
        $source = 'StandaloneInstaller'
        $pkgId = $null
        $auto = $false
        if ($wingetAvailable) {
            # Match against the pre-built lookup table (fast, no per-app shell-out)
            try {
                $key = $name.Trim().ToLower()
                if ($wingetLookup.ContainsKey($key)) {
                    $pkgId = $wingetLookup[$key]
                    $source = 'Winget'
                    $auto = $true
                } else {
                    # fuzzy: find a lookup key that contains the app name or vice versa
                    foreach ($wk in $wingetLookup.Keys) {
                        if ($wk -eq $key -or $wk.Contains($key) -or $key.Contains($wk)) {
                            $pkgId = $wingetLookup[$wk]
                            $source = 'Winget'
                            $auto = $true
                            break
                        }
                    }
                }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
        $manualHint = if ($auto) { $null } else { "Standalone installer by $($e.Publisher). Download installer from official vendor site." }
        $reinstallCmd = if ($auto -and $pkgId) { "winget install --id `"$pkgId`" --exact --accept-source-agreements --accept-package-agreements" } else { $null }
        $apps += [PSCustomObject]@{
            Name              = $name
            Version           = if ($e.DisplayVersion) { $e.DisplayVersion } else { '' }
            Publisher         = if ($e.Publisher) { $e.Publisher } else { '' }
            Source            = $source
            PackageIdentifier = $pkgId
            AutoReinstallable = $auto
            ReinstallCommand  = $reinstallCmd
            ManualHint        = $manualHint
        }
    }

    # Appx (Store) apps
    if (-not $OfflineTestMode) {
        try {
            $appx = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.SignatureKind -eq 'Store' -and $_.IsFramework -eq $false }
            foreach ($a in $appx) {
                $apps += [PSCustomObject]@{
                    Name              = $a.Name
                    Version           = $a.Version
                    Publisher         = $a.Publisher
                    Source            = 'MicrosoftStore'
                    PackageIdentifier = $a.PackageFamilyName
                    AutoReinstallable = $false
                    ReinstallCommand  = $null
                    ManualHint        = "Microsoft Store app. Reinstall from Microsoft Store."
                }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    $autoCount = @($apps | Where-Object { $_.AutoReinstallable }).Count
    $manualCount = $apps.Count - $autoCount

    $result = [PSCustomObject]@{
        TotalApps            = $apps.Count
        AutoInstallable      = $autoCount
        ManualInstallRequired = $manualCount
        Apps                 = $apps
        OutputPath           = $OutputPath
    }

    if ($OutputPath) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $json = $result | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.Encoding]::UTF8)
    }
    return $result
}

# 5. Restore-Nano11Apps
function Restore-Nano11Apps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InventoryPath,
        [string[]]$SelectedAppNames,
        [switch]$DryRun
    )
    $installed = @()
    $failed = @()
    $manual = @()
    if (-not (Test-Path -LiteralPath $InventoryPath)) { return [PSCustomObject]@{ Installed = $installed; Failed = $failed; ManualGuidance = $manual } }
    try {
        $data = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)"; return [PSCustomObject]@{ Installed = $installed; Failed = $failed; ManualGuidance = $manual } }
    $apps = $data.Apps
    if ($SelectedAppNames) { $apps = $apps | Where-Object { $SelectedAppNames -contains $_.Name } }
    foreach ($a in $apps) {
        if ($a.AutoReinstallable -and $a.ReinstallCommand) {
            if ($DryRun) { $installed += $a; continue }
            try {
                & winget install --id $a.PackageIdentifier -e --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                $installed += $a
            } catch {
                $failed += [PSCustomObject]@{ App = $a.Name; Error = $_.Exception.Message }
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        } else {
            $manual += [PSCustomObject]@{ Name = $a.Name; Hint = $a.ManualHint }
        }
    }
    return [PSCustomObject]@{ Installed = $installed; Failed = $failed; ManualGuidance = $manual }
}

# 6. Get-Nano11MigrationSizeEstimate
function Get-Nano11MigrationSizeEstimate {
    [CmdletBinding()]
    param(
        [string[]]$UserFolderPaths = @(),
        [string[]]$SelectedRuleIds = @(),
        [string]$DestinationPath = ''
    )
    $totalFiles = 0
    $totalBytes = [int64]0
    $runningProcs = @()
    Write-Verbose "SelectedRuleIds: $($SelectedRuleIds -join ', ')"
    foreach ($fp in $UserFolderPaths) {
        $p = Expand-Nano11MigrationPath -RawPath $fp
        if (Test-Path -LiteralPath $p) {
            try {
                $items = Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue
                $totalFiles += $items.Count
                foreach ($it in $items) { $totalBytes += $it.Length }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
    }
    $destDrive = ''
    $destFree = [int64]0
    if ($DestinationPath) {
        try {
            $root = [System.IO.Path]::GetPathRoot($DestinationPath)
            if ($root) {
                $di = New-Object System.IO.DriveInfo($root)
                if ($di.IsReady) { $destDrive = $di.Name; $destFree = $di.AvailableFreeSpace }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $hasEnough = $destFree -gt ($totalBytes * 1.1)
    return [PSCustomObject]@{
        TotalFiles           = $totalFiles
        TotalBytes           = $totalBytes
        TotalMB              = [math]::Round($totalBytes / 1MB, 2)
        DestinationDrive     = $destDrive
        DestinationFreeBytes = $destFree
        DestinationFreeMB    = [math]::Round($destFree / 1MB, 2)
        HasEnoughSpace       = $hasEnough
        RunningProcesses     = $runningProcs
    }
}

# Assert-Nano11BackupRootOutsideSources: refuse a BackupRoot that lives inside a source folder
# (the copy would pick up its own output and never finish). Runs before any copy starts.
function Assert-Nano11BackupRootOutsideSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [string[]]$SourcePaths = @()
    )
    foreach ($sp in @($SourcePaths)) {
        if ([string]::IsNullOrWhiteSpace($sp)) { continue }
        if (Test-Nano11PathWithin -Path $BackupRoot -Root $sp) {
            throw "BackupRoot '$BackupRoot' is inside the source folder '$sp'. Choose a backup location outside the folders being backed up."
        }
    }
}

# 7. Backup-Nano11UserData
function Backup-Nano11UserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FolderMap,
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [ValidateSet('Skip','OverwriteIfNewer','Overwrite')]
        [string]$OverwritePolicy = 'OverwriteIfNewer',
        [switch]$VerifySha256,
        [switch]$DryRun
    )
    # Safety: backup root must not be inside a source folder or the build dir
    $nano11Dir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
    try {
        $fullBackup = [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
        if ($fullBackup.StartsWith($nano11Dir, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "BackupRoot must not be inside the nano11 directory."
        }
    } catch { throw }
    Assert-Nano11BackupRootOutsideSources -BackupRoot $BackupRoot -SourcePaths @($FolderMap.Values)

    $copied = 0
    $skipped = 0
    $failed = @()
    $totalBytes = [int64]0
    $manifest = @()

    if (-not $PSBoundParameters.ContainsKey('VerifySha256')) { $VerifySha256 = $true }
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }
    }

    foreach ($cat in $FolderMap.Keys) {
        $srcPath = $FolderMap[$cat]
        if (-not (Test-Path -LiteralPath $srcPath)) { continue }
        try {
            $items = Get-ChildItem -LiteralPath $srcPath -Recurse -File -ErrorAction SilentlyContinue
        } catch { $items = @() }
        foreach ($it in $items) {
            $rel = $it.FullName.Substring($srcPath.Length).TrimStart('\')
            $destPath = Join-Path -Path (Join-Path -Path $BackupRoot -ChildPath $cat) -ChildPath $rel
            $destDir = Split-Path -Parent $destPath
            if ($DryRun) { $copied++; $totalBytes += $it.Length; continue }
            try {
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                $doCopy = $true
                if (Test-Path -LiteralPath $destPath) {
                    if ($OverwritePolicy -eq 'Skip') { $doCopy = $false }
                    elseif ($OverwritePolicy -eq 'OverwriteIfNewer') {
                        $destItem = Get-Item -LiteralPath $destPath
                        if ($destItem.LastWriteTimeUtc -ge $it.LastWriteTimeUtc) { $doCopy = $false }
                    }
                }
                if (-not $doCopy) { $skipped++; continue }
                Copy-Item -LiteralPath $it.FullName -Destination $destPath -Force
                $copied++
                $totalBytes += $it.Length
                $hash = ''
                if ($VerifySha256) { try { $hash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256).Hash } catch { Write-Verbose "Ignored: $($_.Exception.Message)" } }
                $manifest += [PSCustomObject]@{ RelativePath = $rel; Category = $cat; SizeBytes = $it.Length; Sha256 = $hash; LastWriteTimeUtc = $it.LastWriteTimeUtc.ToString('o') }
            } catch {
                $failed += [PSCustomObject]@{ Path = $it.FullName; Error = $_.Exception.Message }
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        }
    }

    # Write manifest
    if (-not $DryRun -and $BackupRoot) {
        try {
            $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
            $manifestObj = [PSCustomObject]@{ Entries = $manifest; Created = (Get-Date).ToString('o') }
            $manifestObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    return [PSCustomObject]@{ Success = ($failed.Count -eq 0); CopiedFiles = $copied; SkippedFiles = $skipped; FailedFiles = $failed; TotalBytes = $totalBytes; ManifestEntries = $manifest }
}

# Restore-Nano11UserData
function Restore-Nano11UserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting',
        [switch]$VerifyHashBeforeRestore,
        [switch]$DryRun,
        [string[]]$Categories
    )
    if (-not $PSBoundParameters.ContainsKey('VerifyHashBeforeRestore')) { $VerifyHashBeforeRestore = $true }
    $restored = 0
    $skipped = 0
    $failed = @()
    $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    $entries = @()
    if (Test-Path -LiteralPath $manifestPath) {
        try { $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json; $entries = $m.Entries } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    # Custom paths have their own restore (Restore-Nano11CustomPaths); an optional category filter narrows the rest
    $entries = @($entries | Where-Object { $_.Category -ne 'CustomPath' })
    if ($Categories) { $entries = @($entries | Where-Object { $Categories -contains $_.Category }) }
    foreach ($entry in $entries) {
        $srcPath = Join-Path -Path $BackupRoot -ChildPath $entry.RelativePath
        if ($entry.Category) { $srcPath = Join-Path -Path (Join-Path -Path $BackupRoot -ChildPath $entry.Category) -ChildPath $entry.RelativePath }
        # Actually backup stores under BackupRoot\<Category>\<rel>; handle both
        if (-not (Test-Path -LiteralPath $srcPath)) {
            # try BackupRoot\<rel>
            $srcPath2 = Join-Path -Path $BackupRoot -ChildPath $entry.RelativePath
            if (Test-Path -LiteralPath $srcPath2) { $srcPath = $srcPath2 }
        }
        if (-not (Test-Path -LiteralPath $srcPath)) { $failed += [PSCustomObject]@{ Path = $entry.RelativePath; Error = 'Backup file missing' }; continue }
        # verify hash
        if ($VerifyHashBeforeRestore -and $entry.Sha256) {
            try {
                $h = (Get-FileHash -LiteralPath $srcPath -Algorithm SHA256).Hash
                if ($h -ne $entry.Sha256) { $failed += [PSCustomObject]@{ Path = $entry.RelativePath; Error = 'Hash mismatch (corrupt)' }; continue }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
        $destPath = $entry.RelativePath
        # dest is relative to user profile home? We'll restore under USERPROFILE
        $destPath = Join-Path -Path $env:USERPROFILE -ChildPath $entry.RelativePath
        # but category-based: if RelativePath doesn't include category, prepend? Keep as-is per manifest
        if ($DryRun) { $restored++; continue }
        try {
            $destDir = Split-Path -Parent $destPath
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            if (Test-Path -LiteralPath $destPath) {
                if ($ConflictPolicy -eq 'Skip') { $skipped++; continue }
                elseif ($ConflictPolicy -eq 'BackupExisting') {
                    Copy-Item -LiteralPath $destPath -Destination "$destPath.nano11.bak" -Force
                } elseif ($ConflictPolicy -eq 'OverwriteIfNewer') {
                    $destItem = Get-Item -LiteralPath $destPath
                    $srcItem = Get-Item -LiteralPath $srcPath
                    if ($destItem.LastWriteTimeUtc -ge $srcItem.LastWriteTimeUtc) { $skipped++; continue }
                }
            }
            Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
            $restored++
        } catch {
            $failed += [PSCustomObject]@{ Path = $entry.RelativePath; Error = $_.Exception.Message }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
}

# 8. Invoke-Nano11MigrationRulesBackup
function Invoke-Nano11MigrationRulesBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RuleIds,
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [switch]$IncludeSecrets,
        [switch]$ForceRunningProcess,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting'
    )
    $rules = Get-Nano11MigrationRules
    $allRules = $rules.GameRules + $rules.AppConfigRules + $rules.CustomPathRules
    $secretPatterns = $rules.SecretPatterns
    Write-Verbose "ConflictPolicy: $ConflictPolicy"
    $copied = 0
    $skipped = 0
    $secretExcluded = 0
    $failed = @()
    $skipReasons = @()
    $backedUp = @()
    $notices = @()
    if (-not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }
    foreach ($rid in $RuleIds) {
        $rule = $allRules | Where-Object { $_.Id -eq $rid } | Select-Object -First 1
        if (-not $rule) { $failed += [PSCustomObject]@{ Rule = $rid; Error = 'Rule not found' }; continue }
        # process running check
        if (-not $ForceRunningProcess -and $rule.ProcessNames) {
            $running = @()
            foreach ($pn in $rule.ProcessNames) {
                if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $running += $pn }
            }
            if ($running.Count -gt 0) {
                Write-Warning "Rule '$rid' skipped: process(es) running: $($running -join ', ')"
                $skipped++
                $skipReasons += [PSCustomObject]@{ Item = $rid; Reason = "Application running ($($running -join ', ')); close it and retry" }
                continue
            }
        }
        $backedUp += [PSCustomObject]@{ Id = $rid; Name = $rule.Name }
        if ($rule.CloudSaveNotice) { $notices += [PSCustomObject]@{ RuleId = $rid; Name = $rule.Name; Notice = [string]$rule.CloudSaveNotice } }
        $ruleBackupDir = Join-Path -Path $BackupRoot -ChildPath "rules\$rid"
        if (-not (Test-Path -LiteralPath $ruleBackupDir)) { New-Item -ItemType Directory -Force -Path $ruleBackupDir | Out-Null }
        # SourcePaths (files/dirs)
        if ($rule.SourcePaths) {
            foreach ($sp in $rule.SourcePaths) {
                $src = Expand-Nano11MigrationPath -RawPath $sp
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $item = Get-Item -LiteralPath $src
                if ($item.PSIsContainer) {
                    Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                        $rel = $_.FullName.Substring($src.Length).TrimStart('\')
                        if (-not $IncludeSecrets -and $rule.ExcludeSecrets -and (Test-Nano11SecretPath -FilePath $_.Name -SecretPatterns $secretPatterns)) {
                            Write-Verbose "Excluded secret: $($_.FullName)"
                            $skipped++
                            $secretExcluded++
                            return
                        }
                        $exclude = $false
                        foreach ($pat in @($rule.ExcludePatterns)) { if ($_.Name -like $pat) { $exclude = $true; break } }
                        if ($exclude) { $skipped++; return }
                        $dest = Join-Path -Path $ruleBackupDir -ChildPath $rel
                        $destDir = Split-Path -Parent $dest
                        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
                        $copied++
                    }
                } else {
                    if (-not $IncludeSecrets -and $rule.ExcludeSecrets -and (Test-Nano11SecretPath -FilePath $item.Name -SecretPatterns $secretPatterns)) {
                        Write-Verbose "Excluded secret: $($item.FullName)"; $skipped++; $secretExcluded++; continue
                    }
                    $exclude = $false
                    foreach ($pat in @($rule.ExcludePatterns)) { if ($item.Name -like $pat) { $exclude = $true; break } }
                    if ($exclude) { $skipped++; continue }
                    Copy-Item -LiteralPath $src -Destination (Join-Path -Path $ruleBackupDir -ChildPath $item.Name) -Force
                    $copied++
                }
            }
        }
        # RegistryPaths
        if ($rule.RegistryPaths) {
            foreach ($rp in $rule.RegistryPaths) {
                try {
                    $regFile = Join-Path -Path $ruleBackupDir -ChildPath 'registry.reg'
                    & reg.exe export $rp $regFile /y 2>&1 | Out-Null
                } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
        }
    }
    if ($secretExcluded -gt 0) { $skipReasons += [PSCustomObject]@{ Item = "$secretExcluded file(s)"; Reason = 'Secret/credential files excluded by default (use -IncludeSecrets to back them up)' } }
    return [PSCustomObject]@{ CopiedFiles = $copied; SkippedFiles = $skipped; FailedFiles = $failed; SecretExcludedFiles = $secretExcluded; SkipReasons = $skipReasons; BackedUpRules = $backedUp; CloudSaveNotices = $notices }
}

function Invoke-Nano11MigrationRulesRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RuleIds,
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [switch]$IncludeSecrets,
        [switch]$ForceRunningProcess,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting'
    )
    $rules = Get-Nano11MigrationRules
    $allRules = $rules.GameRules + $rules.AppConfigRules + $rules.CustomPathRules
    Write-Verbose "IncludeSecrets=$IncludeSecrets ForceRunningProcess=$ForceRunningProcess ConflictPolicy=$ConflictPolicy"
    $restored = 0
    $skipped = 0
    $failed = @()
    foreach ($rid in $RuleIds) {
        $rule = $allRules | Where-Object { $_.Id -eq $rid } | Select-Object -First 1
        if (-not $rule) { $failed += [PSCustomObject]@{ Rule = $rid; Error = 'Rule not found' }; continue }
        $ruleBackupDir = Join-Path -Path $BackupRoot -ChildPath "rules\$rid"
        if (-not (Test-Path -LiteralPath $ruleBackupDir)) { $failed += [PSCustomObject]@{ Rule = $rid; Error = 'Backup not found' }; continue }
        # Registry restore
        if ($rule.RegistryPaths) {
            $regFile = Join-Path -Path $ruleBackupDir -ChildPath 'registry.reg'
            if (Test-Path -LiteralPath $regFile) {
                try { & reg.exe import $regFile 2>&1 | Out-Null; $restored++ } catch { $failed += [PSCustomObject]@{ Rule = $rid; Error = $_.Exception.Message } }
            }
        }
        # File restore
        Get-ChildItem -LiteralPath $ruleBackupDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'registry.reg' } | ForEach-Object {
            $rel = $_.FullName.Substring($ruleBackupDir.Length).TrimStart('\')
            # reconstruct source path from rule SourcePaths (use first existing parent)
            $src = $null
            foreach ($sp in @($rule.SourcePaths)) {
                $expanded = Expand-Nano11MigrationPath -RawPath $sp
                if ($expanded) { $src = $expanded; break }
            }
            if (-not $src) { return }
            # rel is relative to the rule's source root; restore under the source root's parent
            $destPath = $null
            if ($rule.SourcePaths -and $rule.SourcePaths.Count -gt 0) {
                $firstSrc = Expand-Nano11MigrationPath -RawPath $rule.SourcePaths[0]
                # if source is a file, dest is that file's dir + rel
                if (Test-Path -LiteralPath $firstSrc -PathType Leaf) {
                    $destPath = Join-Path -Path (Split-Path -Parent $firstSrc) -ChildPath $rel
                } else {
                    $destPath = Join-Path -Path $firstSrc -ChildPath $rel
                }
            }
            if (-not $destPath) { return }
            try {
                $destDir = Split-Path -Parent $destPath
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                if (Test-Path -LiteralPath $destPath) {
                    if ($ConflictPolicy -eq 'Skip') { $skipped++; return }
                    elseif ($ConflictPolicy -eq 'BackupExisting') {
                        Copy-Item -LiteralPath $destPath -Destination "$destPath.nano11.bak" -Force
                    } elseif ($ConflictPolicy -eq 'OverwriteIfNewer') {
                        $destItem = Get-Item -LiteralPath $destPath
                        if ($destItem.LastWriteTimeUtc -ge $_.LastWriteTimeUtc) { $skipped++; return }
                    }
                }
                Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
                $restored++
            } catch {
                $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = $_.Exception.Message }
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        }
    }
    return [PSCustomObject]@{ RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
}

# 9. Start-Nano11MigrationBackup & Start-Nano11MigrationRestore
function Start-Nano11MigrationBackup {
    [CmdletBinding()]
    param(
        [hashtable]$FolderMap = @{},
        [string]$BackupRoot = '',
        [string[]]$RuleIds = @(),
        [string[]]$CustomPaths = @(),
        [switch]$IncludeSecrets,
        [switch]$DryRun,
        [switch]$OfflineTestMode
    )
    if (-not $BackupRoot) { $BackupRoot = Join-Path -Path $env:USERPROFILE -ChildPath 'Documents\nano11_migration_backup' }
    # Refuse an unsafe BackupRoot before anything is written (inventory included)
    $customExpanded = @($CustomPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Expand-Nano11MigrationPath -RawPath $_.Trim() })
    Assert-Nano11BackupRootOutsideSources -BackupRoot $BackupRoot -SourcePaths (@($FolderMap.Values) + $customExpanded)
    if (-not $DryRun -and -not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }
    # App inventory
    $invPath = Join-Path -Path $BackupRoot -ChildPath 'apps-inventory.json'
    $inv = Export-Nano11AppInventory -OutputPath $invPath -OfflineTestMode:$OfflineTestMode
    # User data backup
    $ud = Backup-Nano11UserData -FolderMap $FolderMap -BackupRoot $BackupRoot -DryRun:$DryRun
    # Custom paths backup
    $cp = $null
    if ($CustomPaths -and $CustomPaths.Count -gt 0) {
        $cp = Backup-Nano11CustomPaths -Paths $CustomPaths -BackupRoot $BackupRoot -DryRun:$DryRun
    }
    # Rules backup
    $rb = $null
    if ($RuleIds -and $RuleIds.Count -gt 0 -and -not $DryRun) {
        $rb = Invoke-Nano11MigrationRulesBackup -RuleIds $RuleIds -BackupRoot $BackupRoot -IncludeSecrets:$IncludeSecrets
    }
    # Manifest: Entries stay readable by Restore-Nano11UserData / Restore-Nano11CustomPaths;
    # Folders / Rules / CustomPaths tell Start-Nano11MigrationRestore which tasks exist.
    $entries = @($ud.ManifestEntries)
    if ($cp) { $entries += @($cp.ManifestEntries) }
    $folderList = @()
    foreach ($k in $FolderMap.Keys) {
        $folderList += [PSCustomObject]@{ Category = [string]$k; SourcePath = [string]$FolderMap[$k] }
    }
    $ruleList = @()
    if ($rb) { $ruleList = @($rb.BackedUpRules) }
    $manifest = [PSCustomObject]@{
        Created      = (Get-Date).ToString('o')
        BackupRoot   = $BackupRoot
        AppInventory = $inv.OutputPath
        Entries      = $entries
        Folders      = $folderList
        Rules        = $ruleList
        CustomPaths  = @($customExpanded)
        UserData     = $ud
        RulesResult  = $rb
        CustomResult = $cp
        DryRun       = [bool]$DryRun
    }
    if (-not $DryRun) {
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $BackupRoot 'migration-manifest.json') -Encoding UTF8
        try {
            $rep = Export-Nano11MigrationReport -MigrationResult $manifest -ReportPath (Join-Path $BackupRoot 'migration-report.html')
            $manifest | Add-Member -NotePropertyName Report -NotePropertyValue $rep -Force
        } catch { Write-Warning "Migration report could not be written: $($_.Exception.Message)" }
    }
    return $manifest
}

function Start-Nano11MigrationRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [switch]$RetryFailedOnly,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting',
        [switch]$DryRun
    )
    $statePath = Join-Path -Path $BackupRoot -ChildPath 'restore-state.json'
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $statePath) {
        try { $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $raw.PSObject.Properties) { $state[$p.Name] = [string]$p.Value } } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    # Build the task list from what the backup recorded
    $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    $m = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try { $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $tasks = @()
    $invPath = Join-Path -Path $BackupRoot -ChildPath 'apps-inventory.json'
    if ($m -and $m.AppInventory -and (Test-Path -LiteralPath ([string]$m.AppInventory))) { $invPath = [string]$m.AppInventory }
    if (Test-Path -LiteralPath $invPath) {
        try {
            $inv = Get-Content -LiteralPath $invPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($a in @($inv.Apps)) {
                if ($a -and $a.Name) { $tasks += [PSCustomObject]@{ TaskId = "App_$($a.Name)"; Kind = 'App'; Target = [string]$a.Name } }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    if ($m) {
        foreach ($f in @($m.Folders)) {
            if ($f -and $f.Category) { $tasks += [PSCustomObject]@{ TaskId = "UserData_$($f.Category)"; Kind = 'UserData'; Target = [string]$f.Category } }
        }
        foreach ($r in @($m.Rules)) {
            if ($r -and $r.Id) { $tasks += [PSCustomObject]@{ TaskId = "Rule_$($r.Id)"; Kind = 'Rule'; Target = [string]$r.Id } }
        }
        foreach ($c in @($m.CustomPaths)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$c)) { $tasks += [PSCustomObject]@{ TaskId = "Custom_$c"; Kind = 'Custom'; Target = [string]$c } }
        }
    }
    if ($tasks.Count -eq 0) {
        # Older / minimal backups: restore whatever the manifest lists in one task
        $tasks += [PSCustomObject]@{ TaskId = 'UserData'; Kind = 'UserData'; Target = '' }
    }

    # Record every task as Pending up front so an interrupted run shows what is left
    if (-not $DryRun) {
        foreach ($t in $tasks) { if (-not $state.Contains($t.TaskId)) { $state[$t.TaskId] = 'Pending' } }
        try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    $results = @()
    foreach ($t in $tasks) {
        $id = $t.TaskId
        $prev = if ($state.Contains($id)) { [string]$state[$id] } else { 'Pending' }
        if ($RetryFailedOnly -and $prev -ne 'Failed' -and $prev -ne 'Pending') {
            $label = if ($prev -eq 'Completed') { 'Skipped (already completed)' } else { "Skipped (previous status: $prev)" }
            $results += [PSCustomObject]@{ TaskId = $id; Status = $label; Detail = $null }
            continue
        }
        $status = 'Completed'
        $detail = $null
        try {
            switch ($t.Kind) {
                'App' {
                    $detail = Restore-Nano11Apps -InventoryPath $invPath -SelectedAppNames @($t.Target) -DryRun:$DryRun
                    if (@($detail.Failed).Count -gt 0) { $status = 'Failed' }
                    elseif (@($detail.ManualGuidance).Count -gt 0) { $status = 'Skipped' }
                }
                'Rule' {
                    if ($DryRun) { $status = 'Skipped'; $detail = 'DryRun: rule restore not simulated' }
                    else {
                        $detail = Invoke-Nano11MigrationRulesRestore -RuleIds @($t.Target) -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy
                        if (@($detail.FailedFiles).Count -gt 0) { $status = 'Failed' }
                    }
                }
                'Custom' {
                    $detail = Restore-Nano11CustomPaths -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -SourcePath $t.Target -DryRun:$DryRun
                    if (@($detail.FailedFiles).Count -gt 0) { $status = 'Failed' }
                }
                default {
                    if ($t.Target) {
                        $detail = Restore-Nano11UserData -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -Categories @($t.Target) -DryRun:$DryRun
                    } else {
                        $detail = Restore-Nano11UserData -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -DryRun:$DryRun
                    }
                    if (@($detail.FailedFiles).Count -gt 0) { $status = 'Failed' }
                }
            }
        } catch {
            $status = 'Failed'
            $detail = $_.Exception.Message
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
        $results += [PSCustomObject]@{ TaskId = $id; Status = $status; Detail = $detail }
        if (-not $DryRun) {
            $state[$id] = $status
            # persist after every task so an interrupted run can be resumed
            try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
    }
    return [PSCustomObject]@{ Results = @($results); State = $state }
}

# Backup-Nano11CustomPaths: back up arbitrary files/folders preserving directory structure
function Backup-Nano11CustomPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [switch]$DryRun
    )
    $expandedSources = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Expand-Nano11MigrationPath -RawPath $_.Trim() })
    Assert-Nano11BackupRootOutsideSources -BackupRoot $BackupRoot -SourcePaths $expandedSources
    $copied = 0
    $skipped = 0
    $failed = @()
    $totalBytes = [int64]0
    $manifest = @()
    $customRoot = Join-Path -Path $BackupRoot -ChildPath 'Custom'
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $customRoot)) { New-Item -ItemType Directory -Force -Path $customRoot | Out-Null }
    }

    foreach ($rawPath in $Paths) {
        $p = $rawPath.Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $expanded = Expand-Nano11MigrationPath -RawPath $p
        if (-not (Test-Path -LiteralPath $expanded)) {
            $failed += [PSCustomObject]@{ Path = $p; Error = 'Path not found' }
            Write-Verbose "Path not found: $expanded"
            continue
        }
        $item = Get-Item -LiteralPath $expanded
        if ($item.PSIsContainer) {
            # Back up entire folder preserving structure
            try {
                $files = Get-ChildItem -LiteralPath $expanded -Recurse -File -ErrorAction SilentlyContinue
            } catch { $files = @() }
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($expanded.Length).TrimStart('\')
                $destPath = Join-Path -Path (Join-Path -Path $customRoot -ChildPath $item.Name) -ChildPath $rel
                if ($DryRun) { $copied++; $totalBytes += $f.Length; continue }
                try {
                    $destDir = Split-Path -Parent $destPath
                    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                    Copy-Item -LiteralPath $f.FullName -Destination $destPath -Force
                    $copied++
                    $totalBytes += $f.Length
                    $hash = ''
                    try { $hash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256).Hash } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
                    $manifest += [PSCustomObject]@{ RelativePath = (Join-Path $item.Name $rel); Category = 'CustomPath'; SizeBytes = $f.Length; Sha256 = $hash; LastWriteTimeUtc = $f.LastWriteTimeUtc.ToString('o'); SourcePath = $expanded }
                } catch {
                    $failed += [PSCustomObject]@{ Path = $f.FullName; Error = $_.Exception.Message }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                }
            }
        } else {
            # Back up single file
            $destPath = Join-Path -Path $customRoot -ChildPath $item.Name
            if ($DryRun) { $copied++; $totalBytes += $item.Length; continue }
            try {
                Copy-Item -LiteralPath $expanded -Destination $destPath -Force
                $copied++
                $totalBytes += $item.Length
                $hash = ''
                try { $hash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256).Hash } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
                $manifest += [PSCustomObject]@{ RelativePath = $item.Name; Category = 'CustomPath'; SizeBytes = $item.Length; Sha256 = $hash; LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o'); SourcePath = $expanded }
            } catch {
                $failed += [PSCustomObject]@{ Path = $expanded; Error = $_.Exception.Message }
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        }
    }

    # Append to existing manifest if present
    if (-not $DryRun -and $BackupRoot) {
        try {
            $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
            $existing = @()
            if (Test-Path -LiteralPath $manifestPath) {
                try { $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($m.Entries) { $existing = @($m.Entries) } } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            }
            $allEntries = $existing + $manifest
            $manifestObj = [PSCustomObject]@{ Entries = $allEntries; Created = (Get-Date).ToString('o') }
            $manifestObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    return [PSCustomObject]@{ Success = ($failed.Count -eq 0); CopiedFiles = $copied; SkippedFiles = $skipped; FailedFiles = $failed; TotalBytes = $totalBytes; ManifestEntries = $manifest }
}

# Restore-Nano11CustomPaths: restore arbitrary files/folders from backup
function Restore-Nano11CustomPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting',
        [switch]$VerifyHashBeforeRestore,
        [switch]$DryRun,
        [string]$SourcePath
    )
    if (-not $PSBoundParameters.ContainsKey('VerifyHashBeforeRestore')) { $VerifyHashBeforeRestore = $true }
    $restored = 0
    $skipped = 0
    $failed = @()
    $customRoot = Join-Path -Path $BackupRoot -ChildPath 'Custom'
    if (-not (Test-Path -LiteralPath $customRoot)) { return [PSCustomObject]@{ RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed } }

    # Read manifest for source paths
    $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    $entries = @()
    if (Test-Path -LiteralPath $manifestPath) {
        try { $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($m.Entries) { $entries = @($m.Entries | Where-Object { $_.Category -eq 'CustomPath' }) } } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    # Optional filter: only entries that came from this original path (the root folder/file or something below it)
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $entries = @($entries | Where-Object { $_.SourcePath -and $_.SourcePath -ieq $SourcePath })
    }

    foreach ($entry in $entries) {
        $srcPath = Join-Path -Path $customRoot -ChildPath $entry.RelativePath
        if (-not (Test-Path -LiteralPath $srcPath)) { $failed += [PSCustomObject]@{ Path = $entry.RelativePath; Error = 'Backup file missing' }; continue }
        if ($VerifyHashBeforeRestore -and $entry.Sha256) {
            try {
                $h = (Get-FileHash -LiteralPath $srcPath -Algorithm SHA256).Hash
                if ($h -ne $entry.Sha256) { $failed += [PSCustomObject]@{ Path = $entry.RelativePath; Error = 'Hash mismatch (corrupt)' }; continue }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
        $destPath = $entry.SourcePath
        if ([string]::IsNullOrWhiteSpace($destPath)) { $destPath = Join-Path -Path $env:USERPROFILE -ChildPath $entry.RelativePath }
        if ($DryRun) { $restored++; continue }
        try {
            $destDir = Split-Path -Parent $destPath
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            if (Test-Path -LiteralPath $destPath) {
                if ($ConflictPolicy -eq 'Skip') { $skipped++; continue }
                elseif ($ConflictPolicy -eq 'BackupExisting') {
                    Copy-Item -LiteralPath $destPath -Destination "$destPath.nano11.bak" -Force
                } elseif ($ConflictPolicy -eq 'OverwriteIfNewer') {
                    $destItem = Get-Item -LiteralPath $destPath
                    $srcItem = Get-Item -LiteralPath $srcPath
                    if ($destItem.LastWriteTimeUtc -ge $srcItem.LastWriteTimeUtc) { $skipped++; continue }
                }
            }
            Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
            $restored++
        } catch {
            $failed += [PSCustomObject]@{ Path = $entry.RelativePath; Error = $_.Exception.Message }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
}
# 10. Export-Nano11MigrationReport
function Export-Nano11MigrationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$MigrationResult,
        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Migration Report</title></head><body>')
    [void]$sb.AppendLine('<h1>Nano11 Migration Report</h1>')
    [void]$sb.AppendLine("<p>Generated: $(Get-Date)</p>")
    if ($MigrationResult.Results) {
        [void]$sb.AppendLine('<ul>')
        foreach ($r in $MigrationResult.Results) {
            [void]$sb.AppendLine("<li>$($r.TaskId): $($r.Status)</li>")
        }
        [void]$sb.AppendLine('</ul>')
    }
    [void]$sb.AppendLine('</body></html>')
    $parent = Split-Path -Parent $ReportPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($ReportPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# Compare-Nano11Config & Format-Nano11ConfigDiff
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

# Test-Nano11RecoveryReadiness
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
        SecondaryDrives     = $secondaryDrives
        SystemRestoreEnabled = $sysRestoreEnabled
        WinReEnabledOnTarget = $winReEnabled
        MigrationBackupFound = $migrationBackupFound
        ReadinessScore       = $score
        Recommendations     = $recs
    }
}
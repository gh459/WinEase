# WinEaseMigration.ps1 - PC migration / backup / restore engine for WinEase
# Dot-sourced by tools/migrator/WinEase-Migrator.ps1 (and the GUI migration tab) and by the test suite.
# WinEasebuilder.ps1 does NOT load this file. Depends on Test-WinEasePathWithin from
# WinEasehelpers.ps1, so the caller must dot-source WinEasehelpers.ps1 first.

# The profile folders of Windows. A file of one of them is restored into that folder
# (the backup stores it as <BackupRoot>\<Category>\<relative path>), so
# Documents\report.txt does not end up next to the profile root.
$script:WinEaseStandardProfileFolders = @(
    'Desktop', 'Documents', 'Downloads', 'Favorites', 'Links', 'Music', 'Pictures', 'Saved Games',
    'Searches', 'Contacts', 'Videos', '3D Objects', 'OneDrive'
)

# 3.1 Expand-WinEaseMigrationPath
function Expand-WinEaseMigrationPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawPath
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($RawPath)
    try { $expanded = [System.IO.Path]::GetFullPath($expanded) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    return $expanded
}

# A short, stable prefix of a path. It keeps two files with the same name apart in the
# backup, so one of them cannot overwrite the other.
function Get-WinEasePathHash8 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')).Substring(0, 8).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# 2. Get-WinEaseMigrationRules
function Get-WinEaseMigrationRules {
    [CmdletBinding()]
    param(
        [string]$BuiltInPath,
        [string]$UserPath
    )
    # Repo layout: tools\migrator\ (this file + migration-rules.psd1) and <root>\config\user\user-migration-rules.psd1.
    # ISO bundle: everything sits in this one folder.
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    if ([string]::IsNullOrWhiteSpace($BuiltInPath)) { $BuiltInPath = Join-Path -Path $scriptDir -ChildPath 'migration-rules.psd1' }
    if ([string]::IsNullOrWhiteSpace($UserPath)) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
        $helpersPath = if ($repoRoot) { Join-Path -Path $repoRoot -ChildPath 'WinEasehelpers.ps1' } else { $null }
        if (-not (Get-Command -Name Resolve-WinEaseUserConfigPath -ErrorAction SilentlyContinue) -and $helpersPath -and (Test-Path -LiteralPath $helpersPath)) { . $helpersPath }
        if ((Get-Command -Name Resolve-WinEaseUserConfigPath -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config'))) {
            $UserPath = Resolve-WinEaseUserConfigPath -RepoRoot $repoRoot -Name 'user-migration-rules.psd1'
        } else {
            $UserPath = Join-Path -Path $scriptDir -ChildPath 'user-migration-rules.psd1'
        }
    }

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

# 3. Test-WinEaseSecretPath
function Test-WinEaseSecretPath {
    [CmdletBinding()]
    [OutputType([bool])]
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

# 4. Export-WinEaseAppInventory
function Export-WinEaseAppInventory {
    [CmdletBinding()]
    param(
        # An empty path means "do not write the inventory" (a dry run must not create
        # a directory or a file on disk).
        [string]$OutputPath = '',
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

# 5. Restore-WinEaseApps
function Restore-WinEaseApps {
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
    } catch {
        # An inventory that cannot be read is a failed restore: the apps are unknown,
        # so nothing is installed and the task must not claim success.
        $failed += [PSCustomObject]@{ App = [string]$InventoryPath; Error = "The app inventory could not be read: $($_.Exception.Message)" }
        Write-Verbose "Ignored: $($_.Exception.Message)"
        return [PSCustomObject]@{ Installed = $installed; Failed = $failed; ManualGuidance = $manual }
    }
    $apps = $data.Apps
    if ($SelectedAppNames) { $apps = $apps | Where-Object { $SelectedAppNames -contains $_.Name } }
    foreach ($a in $apps) {
        if ($a.AutoReinstallable -and $a.ReinstallCommand) {
            if ($DryRun) { $installed += $a; continue }
            try {
                & winget install --id $a.PackageIdentifier -e --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                # winget reports a failure through its exit code, not through an
                # exception, so the code is checked before the app counts as installed
                $wingetExit = $LASTEXITCODE
                if ($null -eq $wingetExit) { $wingetExit = 0 }
                if ($wingetExit -eq 0) {
                    $installed += $a
                } else {
                    # The report and the log read the name of the app, so the entry keeps
                    # the field names they use.
                    $failed += [PSCustomObject]@{ Id = [string]$a.PackageIdentifier; Name = [string]$a.Name; App = [string]$a.Name; Error = "winget exited with code $wingetExit" }
                }
            } catch {
                $failed += [PSCustomObject]@{ Id = [string]$a.PackageIdentifier; Name = [string]$a.Name; App = [string]$a.Name; Error = $_.Exception.Message }
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        } else {
            $manual += [PSCustomObject]@{ Name = $a.Name; Hint = $a.ManualHint }
        }
    }
    return [PSCustomObject]@{ Installed = $installed; Failed = $failed; ManualGuidance = $manual }
}

# 6. Get-WinEaseMigrationSizeEstimate
function Get-WinEaseMigrationSizeEstimate {
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
        $p = Expand-WinEaseMigrationPath -RawPath $fp
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

# Assert-WinEaseBackupRootOutsideSources: refuse a BackupRoot that lives inside a source folder
# (the copy would pick up its own output and never finish). Runs before any copy starts.
function Assert-WinEaseBackupRootOutsideSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [string[]]$SourcePaths = @()
    )
    foreach ($sp in @($SourcePaths)) {
        if ([string]::IsNullOrWhiteSpace($sp)) { continue }
        if (Test-WinEasePathWithin -Path $BackupRoot -Root $sp) {
            throw "BackupRoot '$BackupRoot' is inside the source folder '$sp'. Choose a backup location outside the folders being backed up."
        }
    }
}

# 7. Backup-WinEaseUserData
function Backup-WinEaseUserData {
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
    $WinEaseDir = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
    try {
        $fullBackup = [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
        if ($fullBackup.StartsWith($WinEaseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "BackupRoot must not be inside the WinEase directory."
        }
    } catch { throw }
    Assert-WinEaseBackupRootOutsideSources -BackupRoot $BackupRoot -SourcePaths @($FolderMap.Values)

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
        # The category is a single directory name below the backup root. A category that
        # carries a traversal must not be able to write outside the backup directory.
        $catCheck = Resolve-WinEaseSafeRelativePath -RelativePath ([string]$cat) -Root $BackupRoot -Label 'category'
        if (-not $catCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = [string]$cat; Error = "Refused: $($catCheck.Reason)" }
            Write-Verbose "Ignored: $($catCheck.Reason)"
            continue
        }
        $catRoot = $catCheck.Path
        try {
            $items = @(Get-ChildItem -LiteralPath $srcPath -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable enumErrors)
            # A folder that cannot be read completely is reported: a silent partial
            # backup looks like a complete one.
            foreach ($enumErr in @($enumErrors)) {
                $failed += [PSCustomObject]@{ Path = $srcPath; Error = "The folder could not be read completely: $($enumErr.Exception.Message)" }
            }
        } catch { $items = @() }
        foreach ($it in $items) {
            $rel = Get-WinEaseRelativePath -BasePath $srcPath -FullName $it.FullName
            $destCheck = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $catRoot -Label 'backup path'
            if (-not $destCheck.IsSafe) {
                $failed += [PSCustomObject]@{ Path = $it.FullName; Error = "Refused: $($destCheck.Reason)" }
                Write-Verbose "Ignored: $($destCheck.Reason)"
                continue
            }
            $destPath = $destCheck.Path
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
                # The hash is part of the manifest: a file whose hash cannot be computed
                # is a failed file, not a backed up file with an empty hash.
                $hash = ''
                if ($VerifySha256) {
                    try {
                        $hash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256 -ErrorAction Stop).Hash
                        if ([string]::IsNullOrWhiteSpace($hash)) { throw 'the hash is empty' }
                    } catch {
                        $failed += [PSCustomObject]@{ Path = $it.FullName; Error = "The SHA256 could not be computed: $($_.Exception.Message)" }
                        Write-Verbose "Ignored: $($_.Exception.Message)"
                        continue
                    }
                }
                $manifest += [PSCustomObject]@{ RelativePath = $rel; Category = $cat; SizeBytes = $it.Length; Sha256 = $hash; LastWriteTimeUtc = $it.LastWriteTimeUtc.ToString('o'); SourcePath = $srcPath }
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
        } catch {
            # A manifest that cannot be written makes the backup unusable: the restore
            # would not know what to restore.
            $failed += [PSCustomObject]@{ Path = (Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'); Error = "The manifest could not be written: $($_.Exception.Message)" }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{ Success = ($failed.Count -eq 0); CopiedFiles = $copied; SkippedFiles = $skipped; FailedFiles = $failed; TotalBytes = $totalBytes; ManifestEntries = $manifest }
}

# Restore-WinEaseUserData
function Restore-WinEaseUserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting',
        [switch]$VerifyHashBeforeRestore,
        [switch]$DryRun,
        [string[]]$Categories,
        [hashtable]$FolderMap
    )
    if (-not $PSBoundParameters.ContainsKey('VerifyHashBeforeRestore')) { $VerifyHashBeforeRestore = $true }
    $restored = 0
    $skipped = 0
    $failed = @()
    $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    $entries = @()
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $entries = $m.Entries
        } catch {
            # A manifest that cannot be read is a failed restore: without it nothing is
            # known about the files, and a silent "nothing to do" looks like a success.
            $failed += [PSCustomObject]@{ Path = $manifestPath; Error = "The manifest could not be read: $($_.Exception.Message)" }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    } else {
        # Without the manifest there is nothing that could be restored: the backup is
        # incomplete, so the restore fails instead of reporting success.
        $failed += [PSCustomObject]@{ Path = $manifestPath; Error = 'Manifest file missing' }
    }
    # Custom paths have their own restore (Restore-WinEaseCustomPaths); an optional category filter narrows the rest.
    # A manifest without entries must not produce an empty entry: an empty relative path
    # would resolve to the backup root itself and copy the whole backup into the profile.
    $entries = @($entries | Where-Object { $_ -and $_.Category -ne 'CustomPath' })
    if ($Categories) { $entries = @($entries | Where-Object { $Categories -contains $_.Category }) }
    foreach ($entry in $entries) {
        $rel = [string]$entry.RelativePath
        $cat = [string]$entry.Category
        # The category is a single directory name below the backup root and the relative
        # path is relative to it. Both come from the manifest, which is not trusted: a
        # traversal in either of them must not reach outside the backup directory.
        $catCheck = Resolve-WinEaseSafeRelativePath -RelativePath $cat -Root $BackupRoot -Label 'category'
        if (-not $catCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $cat; Error = "Refused: $($catCheck.Reason)" }
            Write-Verbose "Ignored: $($catCheck.Reason)"
            continue
        }
        $srcCheck = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $catCheck.Path -Label 'backup path'
        if (-not $srcCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($srcCheck.Reason)" }
            Write-Verbose "Ignored: $($srcCheck.Reason)"
            continue
        }
        $srcPath = $srcCheck.Path
        # Actually backup stores under BackupRoot\<Category>\<rel>; handle both
        if (-not (Test-Path -LiteralPath $srcPath)) {
            # try BackupRoot\<rel>
            $fallback = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $BackupRoot -Label 'backup path'
            if ($fallback.IsSafe -and (Test-Path -LiteralPath $fallback.Path)) { $srcPath = $fallback.Path }
        }
        if (-not (Test-Path -LiteralPath $srcPath)) { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Backup file missing' }; continue }
        # verify hash: without a hash in the manifest the file cannot be verified, so
        # the restore is refused instead of trusting an unverifiable file.
        if ($VerifyHashBeforeRestore) {
            $expectedHash = [string]$entry.Sha256
            if ([string]::IsNullOrWhiteSpace($expectedHash)) {
                $failed += [PSCustomObject]@{ Path = $rel; Error = 'Hash missing in manifest' }
                continue
            }
            try {
                $h = (Get-FileHash -LiteralPath $srcPath -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($h -ne $expectedHash) { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Hash mismatch (corrupt)' }; continue }
            } catch {
                $failed += [PSCustomObject]@{ Path = $rel; Error = "The hash could not be verified: $($_.Exception.Message)" }
                Write-Verbose "Ignored: $($_.Exception.Message)"
                continue
            }
        }
        # The restore target is relative to the user profile home. The relative path is
        # validated again for that root: it must not leave the profile.
        # The category is the name of the profile folder the file belongs to (the
        # backup stores it as BackupRoot\<Category>\<rel>), so the file has to be
        # restored into that folder and not next to it.
        $profileRoot = $env:USERPROFILE
        $destRel = $rel
        $catFolder = $null
        if ($FolderMap -and $FolderMap.Contains($cat)) {
            # The map of the backup names the profile folder the category stands for
            $mapped = [string]$FolderMap[$cat]
            if (-not [string]::IsNullOrWhiteSpace($mapped)) {
                $mappedName = [System.IO.Path]::GetFileName($mapped.TrimEnd('\'))
                if ($mappedName) { $catFolder = $mappedName }
            }
        } elseif ($entry.PSObject.Properties['SourcePath'] -and $entry.SourcePath) {
            # The backup recorded the folder the file came from. When it is the profile
            # folder of the category, the file goes back into it.
            $sourceFull = ConvertTo-WinEaseComparablePath -Path ([string]$entry.SourcePath)
            $profileFull = ConvertTo-WinEaseComparablePath -Path $profileRoot
            if ($sourceFull -and $profileFull) {
                $expectedSource = Join-Path -Path $profileFull -ChildPath $cat
                if ($sourceFull -ieq $expectedSource) { $catFolder = $cat }
            }
        }
        if ($catFolder) { $destRel = Join-Path -Path $catFolder -ChildPath $rel }
        $destCheck = Resolve-WinEaseSafeRelativePath -RelativePath $destRel -Root $profileRoot -Label 'restore path'
        if (-not $destCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($destCheck.Reason)" }
            Write-Verbose "Ignored: $($destCheck.Reason)"
            continue
        }
        $destPath = $destCheck.Path
        if ($DryRun) { $restored++; continue }
        try {
            $destDir = Split-Path -Parent $destPath
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            if (Test-Path -LiteralPath $destPath) {
                if ($ConflictPolicy -eq 'Skip') { $skipped++; continue }
                elseif ($ConflictPolicy -eq 'BackupExisting') {
                    Copy-Item -LiteralPath $destPath -Destination "$destPath.WinEase.bak" -Force
                } elseif ($ConflictPolicy -eq 'OverwriteIfNewer') {
                    $destItem = Get-Item -LiteralPath $destPath
                    $srcItem = Get-Item -LiteralPath $srcPath
                    if ($destItem.LastWriteTimeUtc -ge $srcItem.LastWriteTimeUtc) { $skipped++; continue }
                }
            }
            Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
            $restored++
        } catch {
            $failed += [PSCustomObject]@{ Path = $rel; Error = $_.Exception.Message }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ Success = ($failed.Count -eq 0); RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
}

# 8. Invoke-WinEaseMigrationRulesBackup
function Invoke-WinEaseMigrationRulesBackup {
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
    $rules = Get-WinEaseMigrationRules
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
        # A rule that is backed up again must not keep the files that were deleted in
        # the meantime, so the folder of the rule is cleared first.
        if (Test-Path -LiteralPath $ruleBackupDir) {
            try { Remove-Item -LiteralPath $ruleBackupDir -Recurse -Force -ErrorAction Stop } catch { $failed += [PSCustomObject]@{ Rule = $rid; Error = "The old backup of the rule could not be removed: $($_.Exception.Message)" } }
        }
        if (-not (Test-Path -LiteralPath $ruleBackupDir)) { New-Item -ItemType Directory -Force -Path $ruleBackupDir | Out-Null }
        # The manifest of the rule maps every backed up file to the source it came
        # from, so a rule with several source paths is restored to the right one.
        $ruleManifest = @()
        # SourcePaths (files/dirs)
        if ($rule.SourcePaths) {
            $sourceIndex = 0
            foreach ($sp in $rule.SourcePaths) {
                $src = Expand-WinEaseMigrationPath -RawPath $sp
                if (-not (Test-Path -LiteralPath $src)) { $sourceIndex++; continue }
                $item = Get-Item -LiteralPath $src
                # The first source keeps the plain layout, the other ones are stored
                # in their own folder, so two sources cannot overwrite each other.
                $sourceFolder = if ($sourceIndex -eq 0) { '' } else { "_src_$sourceIndex" }
                if ($item.PSIsContainer) {
                    try {
                        $files = @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable enumErrors)
                        foreach ($enumErr in @($enumErrors)) {
                            $failed += [PSCustomObject]@{ Rule = $rid; Error = "The source folder could not be read completely: $($enumErr.Exception.Message)" }
                        }
                    } catch { $files = @() }
                    foreach ($f in $files) {
                        $rel = Get-WinEaseRelativePath -BasePath $src -FullName $f.FullName
                        if (-not $IncludeSecrets -and $rule.ExcludeSecrets -and (Test-WinEaseSecretPath -FilePath $f.Name -SecretPatterns $secretPatterns)) {
                            Write-Verbose "Excluded secret: $($f.FullName)"
                            $skipped++
                            $secretExcluded++
                            continue
                        }
                        $exclude = $false
                        foreach ($pat in @($rule.ExcludePatterns)) { if ($f.Name -like $pat) { $exclude = $true; break } }
                        if ($exclude) { $skipped++; continue }
                        # the first source keeps the plain layout, the other ones are
                        # stored in their own folder
                        $relInBackup = if ($sourceFolder) { Join-Path $sourceFolder $rel } else { $rel }
                        $dest = Join-Path -Path $ruleBackupDir -ChildPath $relInBackup
                        $destDir = Split-Path -Parent $dest
                        try {
                            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
                            $copied++
                            $ruleManifest += [PSCustomObject]@{ RelativePath = $relInBackup; SourceIndex = $sourceIndex; IsFile = $true; SourcePath = $f.FullName }
                        } catch {
                            $failed += [PSCustomObject]@{ Rule = $rid; Path = $f.FullName; Error = $_.Exception.Message }
                            Write-Verbose "Ignored: $($_.Exception.Message)"
                        }
                    }
                } else {
                    if (-not $IncludeSecrets -and $rule.ExcludeSecrets -and (Test-WinEaseSecretPath -FilePath $item.Name -SecretPatterns $secretPatterns)) {
                        Write-Verbose "Excluded secret: $($item.FullName)"; $skipped++; $secretExcluded++; $sourceIndex++; continue
                    }
                    $exclude = $false
                    foreach ($pat in @($rule.ExcludePatterns)) { if ($item.Name -like $pat) { $exclude = $true; break } }
                    if ($exclude) { $skipped++; $sourceIndex++; continue }
                    $rel = $item.Name
                    $relInBackup = if ($sourceFolder) { Join-Path $sourceFolder $rel } else { $rel }
                    $dest = Join-Path -Path $ruleBackupDir -ChildPath $relInBackup
                    $destDir = Split-Path -Parent $dest
                    try {
                        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                        Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
                        $copied++
                        $ruleManifest += [PSCustomObject]@{ RelativePath = $relInBackup; SourceIndex = $sourceIndex; IsFile = $true; SourcePath = $src }
                    } catch {
                        $failed += [PSCustomObject]@{ Rule = $rid; Path = $src; Error = $_.Exception.Message }
                        Write-Verbose "Ignored: $($_.Exception.Message)"
                    }
                }
                $sourceIndex++
            }
        }
        # The manifest of the rule is written next to its files
        if ($ruleManifest.Count -gt 0) {
            try {
                $ruleManifestPath = Join-Path -Path $ruleBackupDir -ChildPath 'rule-manifest.json'
                $ruleManifestObj = [PSCustomObject]@{ RuleId = $rid; Entries = $ruleManifest; Created = (Get-Date).ToString('o') }
                $ruleManifestObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ruleManifestPath -Encoding UTF8
            } catch {
                $failed += [PSCustomObject]@{ Rule = $rid; Error = "The rule manifest could not be written: $($_.Exception.Message)" }
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        }
        # RegistryPaths: every key gets its own file, the first one also keeps the
        # historical name registry.reg
        if ($rule.RegistryPaths) {
            $regIndex = 0
            foreach ($rp in $rule.RegistryPaths) {
                try {
                    $regName = if ($regIndex -eq 0) { 'registry.reg' } else { "registry_$regIndex.reg" }
                    $regFile = Join-Path -Path $ruleBackupDir -ChildPath $regName
                    & reg.exe export $rp $regFile /y 2>&1 | Out-Null
                    $regExit = $LASTEXITCODE
                    if ($null -eq $regExit) { $regExit = 0 }
                    if ($regExit -ne 0) {
                        $failed += [PSCustomObject]@{ Rule = $rid; Path = $rp; Error = "reg.exe export exited with code $regExit" }
                    }
                } catch {
                    $failed += [PSCustomObject]@{ Rule = $rid; Path = $rp; Error = $_.Exception.Message }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                }
                $regIndex++
            }
        }
    }
    if ($secretExcluded -gt 0) { $skipReasons += [PSCustomObject]@{ Item = "$secretExcluded file(s)"; Reason = 'Secret/credential files excluded by default (use -IncludeSecrets to back them up)' } }
    return [PSCustomObject]@{ CopiedFiles = $copied; SkippedFiles = $skipped; FailedFiles = $failed; SecretExcludedFiles = $secretExcluded; SkipReasons = $skipReasons; BackedUpRules = $backedUp; CloudSaveNotices = $notices }
}

function Invoke-WinEaseMigrationRulesRestore {
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
    $rules = Get-WinEaseMigrationRules
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
        # Registry restore: every exported key is imported from its own file
        if ($rule.RegistryPaths) {
            $regIndex = 0
            foreach ($rp in $rule.RegistryPaths) {
                $regName = if ($regIndex -eq 0) { 'registry.reg' } else { "registry_$regIndex.reg" }
                $regFile = Join-Path -Path $ruleBackupDir -ChildPath $regName
                if (Test-Path -LiteralPath $regFile) {
                    try {
                        & reg.exe import $regFile 2>&1 | Out-Null
                        $regExit = $LASTEXITCODE
                        if ($null -eq $regExit) { $regExit = 0 }
                        if ($regExit -eq 0) {
                            $restored++
                        } else {
                            $failed += [PSCustomObject]@{ Rule = $rid; Path = $regName; Error = "reg.exe import exited with code $regExit" }
                        }
                    } catch {
                        $failed += [PSCustomObject]@{ Rule = $rid; Path = $regName; Error = $_.Exception.Message }
                    }
                }
                $regIndex++
            }
        }
        # The manifest of the rule maps every file to the source it came from. Without
        # it (a legacy backup) the files are restored to the first source of the rule.
        $ruleManifestPath = Join-Path -Path $ruleBackupDir -ChildPath 'rule-manifest.json'
        $ruleEntries = @()
        if (Test-Path -LiteralPath $ruleManifestPath) {
            try {
                $ruleManifest = Get-Content -LiteralPath $ruleManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($ruleManifest.Entries) { $ruleEntries = @($ruleManifest.Entries) }
            } catch {
                $failed += [PSCustomObject]@{ Rule = $rid; Error = "The rule manifest could not be read: $($_.Exception.Message)" }
                Write-Verbose "Ignored: $($_.Exception.Message)"
            }
        }
        # File restore
        Get-ChildItem -LiteralPath $ruleBackupDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'registry.reg' -and $_.Name -notlike 'registry_*.reg' -and $_.Name -ne 'rule-manifest.json' } |
            ForEach-Object {
                $rel = Get-WinEaseRelativePath -BasePath $ruleBackupDir -FullName $_.FullName
                # The destination comes from the manifest of the rule, so a rule with
                # several source paths is restored to the one the file came from.
                $manifestEntry = @($ruleEntries | Where-Object { $_.RelativePath -eq $rel } | Select-Object -First 1)
                $sourceIndex = 0
                $sourcePath = $null
                if ($manifestEntry.Count -gt 0) {
                    $sourceIndex = [int]$manifestEntry[0].SourceIndex
                    if ($manifestEntry[0].PSObject.Properties['SourcePath'] -and $manifestEntry[0].SourcePath) { $sourcePath = [string]$manifestEntry[0].SourcePath }
                }
                $destPath = $null
                if ($sourcePath) {
                    # The file goes back to the place it came from
                    $destPath = $sourcePath
                } elseif ($rule.SourcePaths -and $rule.SourcePaths.Count -gt 0) {
                    $sp = $rule.SourcePaths[[Math]::Min($sourceIndex, $rule.SourcePaths.Count - 1)]
                    $firstSrc = Expand-WinEaseMigrationPath -RawPath $sp
                    if ($firstSrc) {
                        if (Test-Path -LiteralPath $firstSrc -PathType Leaf) {
                            $destPath = Join-Path -Path (Split-Path -Parent $firstSrc) -ChildPath (Split-Path -Leaf $rel)
                        } else {
                            $destPath = Join-Path -Path $firstSrc -ChildPath $rel
                        }
                    }
                }
                if (-not $destPath) { return }
                # The destination has to stay inside the source of the rule, and it must
                # not traverse a symbolic link or a junction on the way.
                if ($rule.SourcePaths -and $rule.SourcePaths.Count -gt 0) {
                    $ruleRoot = Expand-WinEaseMigrationPath -RawPath $rule.SourcePaths[0]
                    $destCheck = Resolve-WinEaseSafeRelativePath -RelativePath (Get-WinEaseRelativePath -BasePath $ruleRoot -FullName $destPath) -Root $ruleRoot -Label 'rule restore path'
                    if (-not $destCheck.IsSafe) {
                        $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = "Refused: $($destCheck.Reason)" }
                        Write-Verbose "Ignored: $($destCheck.Reason)"
                        return
                    }
                    if (Test-WinEasePathHasReparsePoint -Path $destPath -Root $ruleRoot) {
                        $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = "Refused: the destination traverses a symbolic link or junction" }
                        Write-Verbose "Ignored: the destination traverses a symbolic link or junction"
                        return
                    }
                }
                try {
                    $destDir = Split-Path -Parent $destPath
                    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                    if (Test-Path -LiteralPath $destPath) {
                        if ($ConflictPolicy -eq 'Skip') { $skipped++; return }
                        elseif ($ConflictPolicy -eq 'BackupExisting') {
                            Copy-Item -LiteralPath $destPath -Destination "$destPath.WinEase.bak" -Force
                        } elseif ($ConflictPolicy -eq 'OverwriteIfNewer') {
                            $destItem = Get-Item -LiteralPath $destPath
                            $srcItem = Get-Item -LiteralPath $_.FullName
                            if ($destItem.LastWriteTimeUtc -ge $srcItem.LastWriteTimeUtc) { $skipped++; return }
                        }
                    }
                    Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force -ErrorAction Stop
                    $restored++
                } catch {
                    $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = $_.Exception.Message }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                }
            }
    }
    return [PSCustomObject]@{ Success = ($failed.Count -eq 0); RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
}

# 9. Start-WinEaseMigrationBackup & Start-WinEaseMigrationRestore
function Start-WinEaseMigrationBackup {
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
    if (-not $BackupRoot) { $BackupRoot = Join-Path -Path $env:USERPROFILE -ChildPath 'Documents\WinEase_migration_backup' }
    # Refuse an unsafe BackupRoot before anything is written (inventory included)
    $customExpanded = @($CustomPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Expand-WinEaseMigrationPath -RawPath $_.Trim() })
    Assert-WinEaseBackupRootOutsideSources -BackupRoot $BackupRoot -SourcePaths (@($FolderMap.Values) + $customExpanded)
    if (-not $DryRun -and -not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null }
    # App inventory. A dry run must not write anything, so the inventory file is only
    # written when the backup really runs.
    $invPath = Join-Path -Path $BackupRoot -ChildPath 'apps-inventory.json'
    if ($DryRun) {
        $inv = Export-WinEaseAppInventory -OutputPath '' -OfflineTestMode:$OfflineTestMode
    } else {
        $inv = Export-WinEaseAppInventory -OutputPath $invPath -OfflineTestMode:$OfflineTestMode
    }
    # User data backup
    $ud = Backup-WinEaseUserData -FolderMap $FolderMap -BackupRoot $BackupRoot -DryRun:$DryRun
    # Custom paths backup
    $cp = $null
    if ($CustomPaths -and $CustomPaths.Count -gt 0) {
        $cp = Backup-WinEaseCustomPaths -Paths $CustomPaths -BackupRoot $BackupRoot -DryRun:$DryRun
    }
    # Rules backup
    $rb = $null
    if ($RuleIds -and $RuleIds.Count -gt 0 -and -not $DryRun) {
        $rb = Invoke-WinEaseMigrationRulesBackup -RuleIds $RuleIds -BackupRoot $BackupRoot -IncludeSecrets:$IncludeSecrets
    }
    # Manifest: Entries stay readable by Restore-WinEaseUserData / Restore-WinEaseCustomPaths;
    # Folders / Rules / CustomPaths tell Start-WinEaseMigrationRestore which tasks exist.
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
            $rep = Export-WinEaseMigrationReport -MigrationResult $manifest -ReportPath (Join-Path $BackupRoot 'migration-report.html')
            $manifest | Add-Member -NotePropertyName Report -NotePropertyValue $rep -Force
        } catch { Write-Warning "Migration report could not be written: $($_.Exception.Message)" }
    }
    return $manifest
}

function Start-WinEaseMigrationRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [switch]$RetryFailedOnly,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting',
        [switch]$DryRun,
        [string[]]$AllowedCustomPaths = @()
    )
    $statePath = Join-Path -Path $BackupRoot -ChildPath 'restore-state.json'
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $statePath) {
        try { $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $raw.PSObject.Properties) { $state[$p.Name] = [string]$p.Value } } catch { Write-Warning "The restore state could not be read: $($_.Exception.Message)" }
    }

    # Build the task list from what the backup recorded
    $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    $m = $null
    $manifestError = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            # A manifest that cannot be read is a failed restore: the folders, the rules
            # and the custom paths of the backup are unknown, so they would be skipped
            # without a word.
            $manifestError = "The migration manifest could not be read: $($_.Exception.Message)"
            Write-Warning $manifestError
        }
    } else {
        $manifestError = 'The migration manifest is missing'
        Write-Warning $manifestError
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
        } catch {
            # An inventory that cannot be read is a failed task: the apps are unknown.
            $manifestError = "The app inventory could not be read: $($_.Exception.Message)"
            Write-Warning $manifestError
        }
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
        # Nothing to restore: a backup without a manifest, without an app inventory and
        # without rules is not a backup. A dummy task would report a success that never
        # restored anything.
        $reason = if ($manifestError) { $manifestError } else { 'The backup folder holds nothing that can be restored: no manifest, no app inventory and no rules.' }
        Write-Warning $reason
        return [PSCustomObject]@{
            Results = @([PSCustomObject]@{ TaskId = 'None'; Status = 'Failed'; Detail = $reason })
            State = $state
        }
    }
    if ($manifestError) {
        # The manifest could not be read: the folders, the rules and the custom paths of
        # the backup are unknown, so the restore is reported as failed.
        $tasks += [PSCustomObject]@{ TaskId = 'Manifest'; Kind = 'Failed'; Target = '' }
    }

    # Record every task as Pending up front so an interrupted run shows what is left
    if (-not $DryRun) {
        foreach ($t in $tasks) { if (-not $state.Contains($t.TaskId)) { $state[$t.TaskId] = 'Pending' } }
        try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { Write-Warning "The restore state could not be written: $($_.Exception.Message)" }
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
                'Failed' {
                    # A part of the backup could not be read, so it is not restored
                    $status = 'Failed'
                    $detail = $manifestError
                }
                'App' {
                    $detail = Restore-WinEaseApps -InventoryPath $invPath -SelectedAppNames @($t.Target) -DryRun:$DryRun
                    if (@($detail.Failed).Count -gt 0) { $status = 'Failed' }
                    elseif (@($detail.ManualGuidance).Count -gt 0) { $status = 'Skipped' }
                }
                'Rule' {
                    if ($DryRun) { $status = 'Skipped'; $detail = 'DryRun: rule restore not simulated' }
                    else {
                        $detail = Invoke-WinEaseMigrationRulesRestore -RuleIds @($t.Target) -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy
                        if (@($detail.FailedFiles).Count -gt 0) { $status = 'Failed' }
                    }
                }
                'Custom' {
                    # The custom paths are only restored to the locations the caller
                    # allowed for this restore. Without an allow list nothing is written:
                    # the manifest alone never decides where a file goes.
                    if (@($AllowedCustomPaths).Count -eq 0) {
                        $status = 'Skipped'
                        $detail = 'No restore target was allowed for the custom paths (pass the paths to restore to).'
                    } else {
                        $detail = Restore-WinEaseCustomPaths -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -SourcePath $t.Target -AllowedSourcePaths $AllowedCustomPaths -DryRun:$DryRun
                        if (@($detail.FailedFiles).Count -gt 0) { $status = 'Failed' }
                    }
                }
                default {
                    if ($t.Target) {
                        $detail = Restore-WinEaseUserData -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -Categories @($t.Target) -DryRun:$DryRun
                    } else {
                        $detail = Restore-WinEaseUserData -BackupRoot $BackupRoot -ConflictPolicy $ConflictPolicy -DryRun:$DryRun
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
            try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { Write-Warning "The restore state could not be written: $($_.Exception.Message)" }
        }
    }
    return [PSCustomObject]@{ Results = @($results); State = $state }
}

# Backup-WinEaseCustomPaths: back up arbitrary files/folders preserving directory structure
function Backup-WinEaseCustomPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [switch]$DryRun
    )
    $expandedSources = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Expand-WinEaseMigrationPath -RawPath $_.Trim() })
    Assert-WinEaseBackupRootOutsideSources -BackupRoot $BackupRoot -SourcePaths $expandedSources
    $copied = 0
    $skipped = 0
    $failed = @()
    $totalBytes = [int64]0
    $manifest = @()
    $customRoot = Join-Path -Path $BackupRoot -ChildPath 'Custom'
    # The names that are already used in the backup folder: two files with the same name
    # from different folders would overwrite each other.
    $usedNames = @{}
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $customRoot)) { New-Item -ItemType Directory -Force -Path $customRoot | Out-Null }
    }

    foreach ($rawPath in $Paths) {
        $p = $rawPath.Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $expanded = Expand-WinEaseMigrationPath -RawPath $p
        if (-not (Test-Path -LiteralPath $expanded)) {
            $failed += [PSCustomObject]@{ Path = $p; Error = 'Path not found' }
            Write-Verbose "Path not found: $expanded"
            continue
        }
        $item = Get-Item -LiteralPath $expanded
        if ($item.PSIsContainer) {
            # Back up entire folder preserving structure
            try {
                $files = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable enumErrors)
                foreach ($enumErr in @($enumErrors)) {
                    $failed += [PSCustomObject]@{ Path = $expanded; Error = "The folder could not be read completely: $($enumErr.Exception.Message)" }
                }
            } catch { $files = @() }
            $usedNames[$item.Name.ToLowerInvariant()] = $true
            foreach ($f in $files) {
                $rel = Get-WinEaseRelativePath -BasePath $expanded -FullName $f.FullName
                $destPath = Join-Path -Path (Join-Path -Path $customRoot -ChildPath $item.Name) -ChildPath $rel
                if ($DryRun) { $copied++; $totalBytes += $f.Length; continue }
                try {
                    $destDir = Split-Path -Parent $destPath
                    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                    Copy-Item -LiteralPath $f.FullName -Destination $destPath -Force
                    $copied++
                    $totalBytes += $f.Length
                    # A file whose hash cannot be computed is a failed file, not a backed
                    # up file with an empty hash.
                    $hash = ''
                    try {
                        $hash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256 -ErrorAction Stop).Hash
                        if ([string]::IsNullOrWhiteSpace($hash)) { throw 'the hash is empty' }
                    } catch {
                        $failed += [PSCustomObject]@{ Path = $f.FullName; Error = "The SHA256 could not be computed: $($_.Exception.Message)" }
                        Write-Verbose "Ignored: $($_.Exception.Message)"
                        continue
                    }
                    # The source path of the entry is the file itself, so the restore puts
                    # it back into the folder it came from (and not next to it).
                    $manifest += [PSCustomObject]@{ RelativePath = (Join-Path $item.Name $rel); Category = 'CustomPath'; SizeBytes = $f.Length; Sha256 = $hash; LastWriteTimeUtc = $f.LastWriteTimeUtc.ToString('o'); SourcePath = $f.FullName }
                } catch {
                    $failed += [PSCustomObject]@{ Path = $f.FullName; Error = $_.Exception.Message }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                }
            }
        } else {
            # Back up single file. A file whose name is already used in the backup
            # folder gets a short prefix of the hash of its path, so the two files stay
            # apart.
            $storageName = $item.Name
            if ($usedNames.ContainsKey($storageName.ToLowerInvariant())) {
                $storageName = (Get-WinEasePathHash8 -Path $expanded) + '_' + $item.Name
            }
            $usedNames[$storageName.ToLowerInvariant()] = $true
            $destPath = Join-Path -Path $customRoot -ChildPath $storageName
            if ($DryRun) { $copied++; $totalBytes += $item.Length; continue }
            try {
                Copy-Item -LiteralPath $expanded -Destination $destPath -Force
                $copied++
                $totalBytes += $item.Length
                $hash = ''
                try {
                    $hash = (Get-FileHash -LiteralPath $destPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ([string]::IsNullOrWhiteSpace($hash)) { throw 'the hash is empty' }
                } catch {
                    $failed += [PSCustomObject]@{ Path = $expanded; Error = "The SHA256 could not be computed: $($_.Exception.Message)" }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                    continue
                }
                $manifest += [PSCustomObject]@{ RelativePath = $storageName; Category = 'CustomPath'; SizeBytes = $item.Length; Sha256 = $hash; LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o'); SourcePath = $expanded }
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
            $existingReadable = $true
            if (Test-Path -LiteralPath $manifestPath) {
                try {
                    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($m.Entries) { $existing = @($m.Entries) }
                } catch {
                    # A manifest that cannot be read is not overwritten: the entries it
                    # holds would be lost for good.
                    $existingReadable = $false
                    $failed += [PSCustomObject]@{ Path = $manifestPath; Error = "The manifest could not be read, so it was not overwritten: $($_.Exception.Message)" }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                }
            }
            if ($existingReadable) {
                $allEntries = $existing + $manifest
                $manifestObj = [PSCustomObject]@{ Entries = $allEntries; Created = (Get-Date).ToString('o') }
                $manifestObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            }
        } catch {
            # A manifest that cannot be written makes the backup unusable
            $failed += [PSCustomObject]@{ Path = (Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'); Error = "The manifest could not be written: $($_.Exception.Message)" }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{ Success = ($failed.Count -eq 0); CopiedFiles = $copied; SkippedFiles = $skipped; FailedFiles = $failed; TotalBytes = $totalBytes; ManifestEntries = $manifest }
}

# Restore-WinEaseCustomPaths: restore arbitrary files/folders from backup
#
# The restore target is NOT taken from the manifest alone: the manifest is untrusted
# input, so the caller has to name the locations this restore is allowed to write to
# (-AllowedSourcePaths). Without an allow list the restore either uses the explicit
# -DefaultRestoreRoot or refuses to write at all.
function Restore-WinEaseCustomPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting',
        [switch]$VerifyHashBeforeRestore,
        [switch]$DryRun,
        [string]$SourcePath,
        [string[]]$AllowedSourcePaths = @(),
        [string]$DefaultRestoreRoot = ''
    )
    if (-not $PSBoundParameters.ContainsKey('VerifyHashBeforeRestore')) { $VerifyHashBeforeRestore = $true }
    $restored = 0
    $skipped = 0
    $failed = @()
    $customRoot = Join-Path -Path $BackupRoot -ChildPath 'Custom'

    # Read manifest for source paths. The manifest is read before the check for the
    # custom folder, so a manifest that cannot be read is reported in any case.
    $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    $entries = @()
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $entries = @($m.Entries | Where-Object { $_.Category -eq 'CustomPath' })
        } catch {
            # A manifest that cannot be read is a failed restore: the entries of the
            # custom paths are unknown, so nothing is restored.
            $failed += [PSCustomObject]@{ Path = $manifestPath; Error = "The manifest could not be read: $($_.Exception.Message)" }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    } else {
        $failed += [PSCustomObject]@{ Path = $manifestPath; Error = 'Manifest file missing' }
    }
    if (-not (Test-Path -LiteralPath $customRoot)) {
        return [PSCustomObject]@{ Success = ($failed.Count -eq 0); RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
    }
    # Optional filter: only entries that came from this original path (the root folder/file or something below it)
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $entries = @($entries | Where-Object { $_.SourcePath -and $_.SourcePath -ieq $SourcePath })
    }

    foreach ($entry in $entries) {
        $rel = [string]$entry.RelativePath
        # The backup copy must stay inside the backup directory.
        $srcCheck = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $customRoot -Label 'backup path'
        if (-not $srcCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($srcCheck.Reason)" }
            Write-Verbose "Ignored: $($srcCheck.Reason)"
            continue
        }
        $srcPath = $srcCheck.Path
        if (-not (Test-Path -LiteralPath $srcPath)) { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Backup file missing' }; continue }
        # verify hash: without a hash in the manifest the file cannot be verified, so
        # the restore is refused instead of trusting an unverifiable file.
        if ($VerifyHashBeforeRestore) {
            $expectedHash = [string]$entry.Sha256
            if ([string]::IsNullOrWhiteSpace($expectedHash)) {
                $failed += [PSCustomObject]@{ Path = $rel; Error = 'Hash missing in manifest' }
                continue
            }
            try {
                $h = (Get-FileHash -LiteralPath $srcPath -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($h -ne $expectedHash) { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Hash mismatch (corrupt)' }; continue }
            } catch {
                $failed += [PSCustomObject]@{ Path = $rel; Error = "The hash could not be verified: $($_.Exception.Message)" }
                Write-Verbose "Ignored: $($_.Exception.Message)"
                continue
            }
        }
        # Restore target: the location the file came from is only a proposal. It is used
        # when the caller allowed that location for this restore.
        $destPath = $null
        if (@($AllowedSourcePaths).Count -gt 0) {
            $candidate = [string]$entry.SourcePath
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                $failed += [PSCustomObject]@{ Path = $rel; Error = 'Refused: the manifest entry has no source path' }
                Write-Verbose "Ignored: the manifest entry has no source path"
                continue
            }
            $target = Resolve-WinEaseRestoreTarget -Path $candidate -AllowedRoots $AllowedSourcePaths
            if (-not $target.IsSafe) {
                $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($target.Reason)" }
                Write-Verbose "Ignored: $($target.Reason)"
                continue
            }
            $destPath = $target.Path
        } elseif (-not [string]::IsNullOrWhiteSpace($DefaultRestoreRoot)) {
            $target = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $DefaultRestoreRoot -Label 'restore path'
            if (-not $target.IsSafe) {
                $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($target.Reason)" }
                Write-Verbose "Ignored: $($target.Reason)"
                continue
            }
            $destPath = $target.Path
        } else {
            $failed += [PSCustomObject]@{ Path = $rel; Error = 'Refused: no restore target was allowed for this restore' }
            Write-Verbose "Ignored: no restore target was allowed for this restore"
            continue
        }
        if ($DryRun) { $restored++; continue }
        try {
            # A backed up folder is restored into the folder itself (the file name of the
            # backup copy differs from the name of the destination), a backed up file is
            # restored onto the file.
            $destIsFolder = ($rel -match '[\\/]') -and (-not (Test-Path -LiteralPath $destPath -PathType Leaf))
            $destDir = if ($destIsFolder) { $destPath } else { Split-Path -Parent $destPath }
            if (-not [string]::IsNullOrWhiteSpace($destDir) -and -not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            }
            if (-not $destIsFolder -and (Test-Path -LiteralPath $destPath)) {
                if ($ConflictPolicy -eq 'Skip') { $skipped++; continue }
                elseif ($ConflictPolicy -eq 'BackupExisting') {
                    Copy-Item -LiteralPath $destPath -Destination "$destPath.WinEase.bak" -Force
                } elseif ($ConflictPolicy -eq 'OverwriteIfNewer') {
                    $destItem = Get-Item -LiteralPath $destPath
                    $srcItem = Get-Item -LiteralPath $srcPath
                    if ($destItem.LastWriteTimeUtc -ge $srcItem.LastWriteTimeUtc) { $skipped++; continue }
                }
            }
            Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
            $restored++
        } catch {
            $failed += [PSCustomObject]@{ Path = $rel; Error = $_.Exception.Message }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ Success = ($failed.Count -eq 0); RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
}
# 10. Export-WinEaseMigrationReport
function ConvertTo-WinEaseHtmlText {
    param($Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Format-WinEaseByteSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-WinEaseMigrationReportData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$MigrationResult
    )
    $succeeded = @()    # Area, Item, Detail
    $skippedItems = @() # Item, Reason
    $failedItems = @()  # Item, Reason
    $manual = @()       # Item, Note
    $files = 0
    $bytes = [int64]0
    $hashOk = 0
    $hashMissing = 0

    # --- file-copy results (user data and custom paths share the same shape) ---
    foreach ($pair in @(@('User data', 'UserData'), @('Custom paths', 'CustomResult'))) {
        $r = $MigrationResult.PSObject.Properties[$pair[1]]
        if (-not $r -or -not $r.Value) { continue }
        $r = $r.Value
        $files += [int]$r.CopiedFiles
        $bytes += [int64]$r.TotalBytes
        foreach ($e in @($r.ManifestEntries)) {
            if ($e.Sha256) { $hashOk++ } else { $hashMissing++ }
        }
        $succeeded += [PSCustomObject]@{ Area = $pair[0]; Item = "$($r.CopiedFiles) file(s)"; Detail = (Format-WinEaseByteSize -Bytes ([int64]$r.TotalBytes)) }
        if ([int]$r.SkippedFiles -gt 0) {
            $skippedItems += [PSCustomObject]@{ Item = "$($pair[0]): $($r.SkippedFiles) file(s)"; Reason = 'Already present in the backup and protected by the overwrite policy (unchanged or not newer)' }
        }
        foreach ($f in @($r.FailedFiles)) {
            $failedItems += [PSCustomObject]@{ Item = [string]$f.Path; Reason = [string]$f.Error }
        }
    }

    # --- rule results ---
    $rr = $MigrationResult.PSObject.Properties['RulesResult']
    if ($rr -and $rr.Value) {
        $rv = $rr.Value
        $files += [int]$rv.CopiedFiles
        $succeeded += [PSCustomObject]@{ Area = 'App/game rules'; Item = "$($rv.CopiedFiles) file(s) from $(@($rv.BackedUpRules).Count) rule(s)"; Detail = '' }
        foreach ($s in @($rv.SkipReasons)) { $skippedItems += [PSCustomObject]@{ Item = [string]$s.Item; Reason = [string]$s.Reason } }
        foreach ($f in @($rv.FailedFiles)) {
            $name = if ($f.Rule) { [string]$f.Rule } else { [string]$f.Path }
            $failedItems += [PSCustomObject]@{ Item = $name; Reason = [string]$f.Error }
        }
        foreach ($n in @($rv.CloudSaveNotices)) {
            $manual += [PSCustomObject]@{ Item = [string]$n.Name; Note = "Cloud save: $($n.Notice)" }
        }
    }

    # --- restore task results ---
    $tasks = @()
    $tr = $MigrationResult.PSObject.Properties['Results']
    if ($tr -and $tr.Value) {
        foreach ($t in @($tr.Value)) {
            $tasks += [PSCustomObject]@{ TaskId = [string]$t.TaskId; Status = [string]$t.Status }
            $st = [string]$t.Status
            if ($st -eq 'Completed') {
                $succeeded += [PSCustomObject]@{ Area = 'Restore'; Item = [string]$t.TaskId; Detail = '' }
            } elseif ($st -eq 'Failed') {
                $reason = if ($t.Detail -is [string]) { [string]$t.Detail } elseif ($t.Detail -and $t.Detail.FailedFiles) { (@($t.Detail.FailedFiles | ForEach-Object { "$($_.Path) $($_.Error)".Trim() }) -join '; ') } elseif ($t.Detail -and $t.Detail.Failed) { (@($t.Detail.Failed | ForEach-Object { "$($_.App): $($_.Error)" }) -join '; ') } else { 'Task failed' }
                $failedItems += [PSCustomObject]@{ Item = [string]$t.TaskId; Reason = $reason }
            } else {
                $skippedItems += [PSCustomObject]@{ Item = [string]$t.TaskId; Reason = $st }
                if ($t.Detail -and $t.Detail.ManualGuidance) {
                    foreach ($g in @($t.Detail.ManualGuidance)) { $manual += [PSCustomObject]@{ Item = [string]$g.Name; Note = [string]$g.Hint } }
                }
            }
        }
    }

    # --- apps that cannot be reinstalled automatically ---
    $invPath = $null
    $ip = $MigrationResult.PSObject.Properties['AppInventory']
    if ($ip -and $ip.Value) { $invPath = [string]$ip.Value }
    if ($invPath -and (Test-Path -LiteralPath $invPath)) {
        try {
            $inv = Get-Content -LiteralPath $invPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($a in @($inv.Apps)) {
                if ($a -and -not $a.AutoReinstallable) {
                    $hint = if ($a.ManualHint) { [string]$a.ManualHint } else { 'Reinstall manually.' }
                    $manual += [PSCustomObject]@{ Item = [string]$a.Name; Note = $hint }
                }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $manual += [PSCustomObject]@{ Item = 'Accounts and sign-ins'; Note = 'Sign in again to your Microsoft account, browsers, Steam/Epic/other launchers and any cloud-sync clients. Saved passwords and tokens are not migrated.' }

    return [ordered]@{
        Generated = (Get-Date).ToString('o')
        Summary   = [ordered]@{ Succeeded = $succeeded.Count; Skipped = $skippedItems.Count; Failed = $failedItems.Count; ManualActions = $manual.Count }
        Success   = [ordered]@{ Files = $files; TotalBytes = $bytes; TotalSize = (Format-WinEaseByteSize -Bytes $bytes); Sha256Verified = $hashOk; Sha256Missing = $hashMissing; Items = @($succeeded) }
        Skipped   = @($skippedItems)
        Failed    = @($failedItems)
        Manual    = @($manual)
        Tasks     = @($tasks)
    }
}

function ConvertTo-WinEaseMigrationHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$ReportData
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>WinEase Migration Report</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine(':root { --bg-main: #0b0f19; --bg-card: #151d2f; --border-card: #22304d; --accent: #00d2ff; --text-primary: #f1f5f9; --text-secondary: #94a3b8; --badge-pass: #10b981; --badge-warn: #f59e0b; --badge-fail: #ef4444; }')
    [void]$sb.AppendLine('* { box-sizing: border-box; margin: 0; padding: 0; }')
    [void]$sb.AppendLine('body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; background: var(--bg-main); color: var(--text-primary); line-height: 1.6; padding: 30px 20px; }')
    [void]$sb.AppendLine('.wrap { max-width: 1000px; margin: 0 auto; }')
    [void]$sb.AppendLine('h1 { font-size: 24px; color: #fff; margin-bottom: 4px; } .sub { color: var(--text-secondary); font-size: 13px; margin-bottom: 24px; }')
    [void]$sb.AppendLine('.section-card { background: var(--bg-card); border: 1px solid var(--border-card); border-radius: 10px; padding: 22px 24px; margin-bottom: 24px; }')
    [void]$sb.AppendLine('.section-card h2 { font-size: 18px; margin-bottom: 14px; color: var(--accent); border-bottom: 1px solid var(--border-card); padding-bottom: 8px; }')
    [void]$sb.AppendLine('table { width: 100%; border-collapse: collapse; font-size: 14px; } th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border-card); vertical-align: top; } th { color: var(--text-secondary); }')
    [void]$sb.AppendLine('.ok { color: var(--badge-pass); } .warn { color: var(--badge-warn); } .fail { color: var(--badge-fail); } .muted { color: var(--text-secondary); }')
    [void]$sb.AppendLine('code { font-family: Consolas, monospace; background: rgba(255,255,255,0.05); padding: 2px 6px; border-radius: 4px; color: #38bdf8; }')
    [void]$sb.AppendLine('</style></head><body><div class="wrap">')
    [void]$sb.AppendLine('<h1>WinEase Migration Report</h1>')
    [void]$sb.AppendLine("<div class=`"sub`">Generated: $(ConvertTo-WinEaseHtmlText $ReportData.Generated)</div>")

    [void]$sb.AppendLine('<div class="section-card"><h2>Succeeded</h2>')
    [void]$sb.AppendLine("<p><span class=`"ok`">$(ConvertTo-WinEaseHtmlText $ReportData.Success.Files) file(s)</span>, $(ConvertTo-WinEaseHtmlText $ReportData.Success.TotalSize) total. SHA-256 recorded for <span class=`"ok`">$($ReportData.Success.Sha256Verified)</span> file(s); not recorded for <span class=`"warn`">$($ReportData.Success.Sha256Missing)</span>.</p>")
    $succeeded = @($ReportData.Success.Items)
    if ($succeeded.Count -gt 0) {
        [void]$sb.AppendLine('<table><tr><th>Area</th><th>Item</th><th>Detail</th></tr>')
        foreach ($i in $succeeded) { [void]$sb.AppendLine("<tr><td>$(ConvertTo-WinEaseHtmlText $i.Area)</td><td>$(ConvertTo-WinEaseHtmlText $i.Item)</td><td>$(ConvertTo-WinEaseHtmlText $i.Detail)</td></tr>") }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</div>')

    $skippedItems = @($ReportData.Skipped)
    [void]$sb.AppendLine('<div class="section-card"><h2>Skipped</h2>')
    if ($skippedItems.Count -eq 0) { [void]$sb.AppendLine('<p class="muted">Nothing was skipped.</p>') }
    else {
        [void]$sb.AppendLine('<table><tr><th>Item</th><th>Reason</th></tr>')
        foreach ($i in $skippedItems) { [void]$sb.AppendLine("<tr><td>$(ConvertTo-WinEaseHtmlText $i.Item)</td><td class=`"warn`">$(ConvertTo-WinEaseHtmlText $i.Reason)</td></tr>") }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</div>')

    $failedItems = @($ReportData.Failed)
    [void]$sb.AppendLine('<div class="section-card"><h2>Failed</h2>')
    if ($failedItems.Count -eq 0) { [void]$sb.AppendLine('<p class="ok">No failures.</p>') }
    else {
        [void]$sb.AppendLine('<table><tr><th>Item</th><th>Reason</th></tr>')
        foreach ($i in $failedItems) { [void]$sb.AppendLine("<tr><td>$(ConvertTo-WinEaseHtmlText $i.Item)</td><td class=`"fail`">$(ConvertTo-WinEaseHtmlText $i.Reason)</td></tr>") }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</div>')

    $manual = @($ReportData.Manual)
    [void]$sb.AppendLine('<div class="section-card"><h2>Manual actions required</h2>')
    [void]$sb.AppendLine('<table><tr><th>Item</th><th>What to do</th></tr>')
    foreach ($i in $manual) { [void]$sb.AppendLine("<tr><td>$(ConvertTo-WinEaseHtmlText $i.Item)</td><td>$(ConvertTo-WinEaseHtmlText $i.Note)</td></tr>") }
    [void]$sb.AppendLine('</table></div>')
    [void]$sb.AppendLine('</div></body></html>')

    return $sb.ToString()
}

# Export-WinEaseMigrationReport: writes <ReportPath> (dark HTML) and a .json with the same base name.
# MigrationResult may be the object returned by Start-WinEaseMigrationBackup (UserData / CustomResult /
# RulesResult / AppInventory) and/or by Start-WinEaseMigrationRestore (Results). Every part is optional.
function Export-WinEaseMigrationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$MigrationResult,
        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )
    $data = Get-WinEaseMigrationReportData -MigrationResult $MigrationResult

    # --- JSON ---
    $parent = Split-Path -Parent $ReportPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $jsonPath = [System.IO.Path]::ChangeExtension($ReportPath, '.json')
    [System.IO.File]::WriteAllText($jsonPath, ($data | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $true))

    # --- HTML (dark theme, palette matches lib/WinEaseReport.ps1). Every dynamic value is HTML-encoded. ---
    $html = ConvertTo-WinEaseMigrationHtml -ReportData $data
    [System.IO.File]::WriteAllText($ReportPath, $html, (New-Object System.Text.UTF8Encoding $true))

    return [PSCustomObject]@{ HtmlPath = $ReportPath; JsonPath = $jsonPath; Data = [PSCustomObject]$data }
}

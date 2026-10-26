# WinEaseMigration.ps1 - PC migration / backup / restore engine for WinEase
# Dot-sourced by tools/migrator/WinEase-Migrator.ps1 (and the GUI migration tab) and by the test suite.
# WinEasebuilder.ps1 does NOT load this file. Depends on Test-WinEasePathWithin from
# WinEasehelpers.ps1, so the caller must dot-source WinEasehelpers.ps1 first.

# 1. Expand-WinEaseMigrationPath
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

# Get-WinEaseMigrationBaseCandidates: the spellings a base folder can appear as in the
# FullName of the files enumerated from it (as given, resolved by Get-Item, resolved by
# Resolve-Path). Computed once per source folder; the per-file relative path is then a
# pure string comparison (Get-WinEaseRelativePath would repeat the Get-Item/Resolve-Path
# round trips for every file).
function Get-WinEaseMigrationBaseCandidates {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($BasePath)
    try { $candidates.Add((Get-Item -LiteralPath $BasePath -Force -ErrorAction Stop).FullName) } catch { Write-Verbose "Get-WinEaseMigrationBaseCandidates: Get-Item failed: $($_.Exception.Message)" }
    try { $candidates.Add((Resolve-Path -LiteralPath $BasePath -ErrorAction Stop).ProviderPath) } catch { Write-Verbose "Get-WinEaseMigrationBaseCandidates: Resolve-Path failed: $($_.Exception.Message)" }
    return $candidates
}

# Get-WinEaseMigrationRelativePath: path of an enumerated item relative to the folder it
# was enumerated from, using pre-computed base candidates (see above). Falls back to the
# file name when no candidate is a prefix, exactly like Get-WinEaseRelativePath.
function Get-WinEaseMigrationRelativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$BaseCandidates,
        [Parameter(Mandatory = $true)]
        [string]$FullName
    )
    foreach ($candidate in $BaseCandidates) {
        $base = $candidate.TrimEnd('\', '/')
        if ($base -and $FullName.StartsWith($base + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $FullName.Substring($base.Length + 1)
        }
    }
    return [System.IO.Path]::GetFileName($FullName)
}

# Copy-WinEaseMigrationFileWithHash: copies one file and computes its SHA-256 while the
# bytes stream through, so the backup reads every file once instead of once for the copy
# and once more for Get-FileHash. The destination keeps the source's LastWriteTimeUtc
# (the OverwriteIfNewer policy compares on it). Opens the source with FileShare.ReadWrite
# so files a running application keeps open can still be read, like Get-FileHash does.
# Throws on failure; returns the uppercase hex hash of the copied bytes.
# The read buffer and the hash algorithm are reused across calls ($script: scope is
# per-runspace, so parallel jobs and GUI threads never share one).
function Copy-WinEaseMigrationFileWithHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestPath,
        [DateTime]$SourceTimestamp,
        [int]$BufferBytes = 1MB
    )
    if (-not $script:WinEaseMigrationCopyBuffer -or $script:WinEaseMigrationCopyBuffer.Length -ne $BufferBytes) {
        $script:WinEaseMigrationCopyBuffer = New-Object byte[] $BufferBytes
    }
    $buffer = $script:WinEaseMigrationCopyBuffer
    # A fresh algorithm per file: reusing one instance across TransformFinalBlock cycles
    # crashed with an access violation in the CNG implementation (PS 5.1).
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $source = [System.IO.File]::Open($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $destination = New-Object System.IO.FileStream($DestPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try {
                while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $destination.Write($buffer, 0, $read)
                    $null = $sha.TransformBlock($buffer, 0, $read, $null, 0)
                }
                $null = $sha.TransformFinalBlock($buffer, 0, 0)
                return [System.BitConverter]::ToString($sha.Hash).Replace('-', '')
            } finally { $destination.Dispose() }
        } finally { $source.Dispose() }
    } finally {
        $sha.Dispose()
        if ($PSBoundParameters.ContainsKey('SourceTimestamp') -and (Test-WinEasePathExistsSafe -Path $DestPath)) {
            try { [System.IO.File]::SetLastWriteTimeUtc($DestPath, $SourceTimestamp) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
    }
}

# Copy-WinEaseMigrationRestoreFile: restores one backed up file with the conflict policy
# applied. A file with an expected hash is copied to a temporary neighbour while it is
# hashed (one read instead of Get-FileHash + Copy-Item), and only moved into place when
# the hash matches, so a corrupt backup never replaces a good file.
# Returns 'Restored', 'Skipped' or 'HashMismatch'; throws on I/O failure.
function Copy-WinEaseMigrationRestoreFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestPath,
        [ValidateSet('Skip','BackupExisting','OverwriteIfNewer','Overwrite')]
        [string]$ConflictPolicy = 'BackupExisting',
        [string]$ExpectedSha256
    )
    $sourceTime = [System.IO.File]::GetLastWriteTimeUtc($SourcePath)
    $exists = [System.IO.File]::Exists($DestPath)
    if ($exists) {
        if ($ConflictPolicy -eq 'Skip') { return 'Skipped' }
        if ($ConflictPolicy -eq 'OverwriteIfNewer' -and [System.IO.File]::GetLastWriteTimeUtc($DestPath) -ge $sourceTime) { return 'Skipped' }
    }
    if ($ExpectedSha256) {
        $tempPath = "$DestPath.WinEase.tmp"
        try {
            $hash = Copy-WinEaseMigrationFileWithHash -SourcePath $SourcePath -DestPath $tempPath -SourceTimestamp $sourceTime
            if ($hash -ne $ExpectedSha256) { return 'HashMismatch' }
            if ($exists) {
                if ($ConflictPolicy -eq 'BackupExisting') { [System.IO.File]::Copy($DestPath, "$DestPath.WinEase.bak", $true) }
                [System.IO.File]::Delete($DestPath)
            }
            [System.IO.File]::Move($tempPath, $DestPath)
        } finally {
            if ([System.IO.File]::Exists($tempPath)) { try { [System.IO.File]::Delete($tempPath) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" } }
        }
        return 'Restored'
    }
    if ($exists -and $ConflictPolicy -eq 'BackupExisting') { [System.IO.File]::Copy($DestPath, "$DestPath.WinEase.bak", $true) }
    [System.IO.File]::Copy($SourcePath, $DestPath, $true)
    return 'Restored'
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
                if (Test-Path -LiteralPath $p -PathType Leaf) {
                    $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
                    if ($item) {
                        $totalFiles++
                        $totalBytes += $item.Length
                    }
                } else {
                    if ('System.IO.EnumerationOptions' -as [type]) {
                        $di = New-Object System.IO.DirectoryInfo($p)
                        $enumOptions = New-Object System.IO.EnumerationOptions
                        $enumOptions.RecurseSubdirectories = $true
                        $enumOptions.IgnoreInaccessible = $true
                        $files = $di.EnumerateFiles('*', $enumOptions)
                        foreach ($fi in $files) {
                            $totalFiles++
                            $totalBytes += $fi.Length
                        }
                    } else {
                        $items = Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue
                        $totalFiles += $items.Count
                        foreach ($it in $items) { $totalBytes += $it.Length }
                    }
                }
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

    # Per-run caches: validated destination directories and the reparse-point lookups of
    # Resolve-WinEaseSafeRelativePath. Validation results repeat for every file that
    # shares a directory, so memoizing them removes the per-file filesystem round trips
    # that dominated the backup time.
    $pathCache = @{}
    $createdDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($cat in $FolderMap.Keys) {
        $srcPath = $FolderMap[$cat]
        if (-not (Test-Path -LiteralPath $srcPath)) { continue }
        # The category is a single directory name below the backup root. A category that
        # carries a traversal must not be able to write outside the backup directory.
        $catCheck = Resolve-WinEaseSafeRelativePath -RelativePath ([string]$cat) -Root $BackupRoot -Label 'category' -LookupCache $pathCache
        if (-not $catCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = [string]$cat; Error = "Refused: $($catCheck.Reason)" }
            Write-Verbose "Ignored: $($catCheck.Reason)"
            continue
        }
        $catRoot = $catCheck.Path
        $baseCandidates = Get-WinEaseMigrationBaseCandidates -BasePath $srcPath
        $enumOptions = $null
        if ('System.IO.EnumerationOptions' -as [type]) {
            $enumOptions = New-Object System.IO.EnumerationOptions
            $enumOptions.RecurseSubdirectories = $true
            $enumOptions.IgnoreInaccessible = $true
            # Same visibility as Get-ChildItem without -Force (hidden/system stay out) and
            # no walking into junctions/symlinks: a reparse subtree would be copied twice
            # (link target + real tree) or loop forever.
            $enumOptions.AttributesToSkip = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::ReparsePoint
        }
        $items = @()
        try {
            if ($enumOptions) {
                $di = New-Object System.IO.DirectoryInfo($srcPath)
                $items = $di.EnumerateFiles('*', $enumOptions)
            } else {
                $items = Get-ChildItem -LiteralPath $srcPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
            }
        } catch { $items = @() }
        foreach ($it in $items) {
            if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
            $rel = Get-WinEaseMigrationRelativePath -BaseCandidates $baseCandidates -FullName $it.FullName
            $destCheck = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $catRoot -Label 'backup path' -LookupCache $pathCache
            if (-not $destCheck.IsSafe) {
                $failed += [PSCustomObject]@{ Path = $it.FullName; Error = "Refused: $($destCheck.Reason)" }
                Write-Verbose "Ignored: $($destCheck.Reason)"
                continue
            }
            $destPath = $destCheck.Path
            $destDir = Split-Path -Parent $destPath
            if ($DryRun) { $copied++; $totalBytes += $it.Length; continue }
            try {
                if (-not $createdDirs.Contains($destDir)) {
                    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                    [void]$createdDirs.Add($destDir)
                }
                $doCopy = $true
                if (Test-Path -LiteralPath $destPath) {
                    if ($OverwritePolicy -eq 'Skip') { $doCopy = $false }
                    elseif ($OverwritePolicy -eq 'OverwriteIfNewer') {
                        $destItem = Get-Item -LiteralPath $destPath
                        if ($destItem.LastWriteTimeUtc -ge $it.LastWriteTimeUtc) { $doCopy = $false }
                    }
                }
                if (-not $doCopy) {
                    # The copy already in the backup still has to be restored: keep it in the manifest
                    $skipped++
                    $manifest += [PSCustomObject]@{ RelativePath = $rel; Category = $cat; SizeBytes = $it.Length; Sha256 = ''; LastWriteTimeUtc = $it.LastWriteTimeUtc.ToString('o') }
                    continue
                }
                $hash = ''
                if ($VerifySha256) {
                    # Copy and hash in one pass: the file is read once, not twice.
                    $hash = Copy-WinEaseMigrationFileWithHash -SourcePath $it.FullName -DestPath $destPath -SourceTimestamp $it.LastWriteTimeUtc
                } else {
                    Copy-Item -LiteralPath $it.FullName -Destination $destPath -Force
                }
                $copied++
                $totalBytes += $it.Length
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

# Get-WinEaseMigrationManifestEntries: the file entries recorded in migration-manifest.json
# (empty when the manifest is missing or unreadable - callers report that themselves).
function Get-WinEaseMigrationManifestEntries {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot
    )
    $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @() }
    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($m.Entries | Where-Object { $_ })
    } catch {
        Write-Verbose "Ignored: $($_.Exception.Message)"
        return @()
    }
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
    # Custom paths have their own restore (Restore-WinEaseCustomPaths); an optional category filter narrows the rest.
    # A manifest without entries must not produce an empty entry: an empty relative path
    # would resolve to the backup root itself and copy the whole backup into the profile.
    $entries = @($entries | Where-Object { $_ -and $_.Category -ne 'CustomPath' })
    if ($Categories) { $entries = @($entries | Where-Object { $Categories -contains $_.Category }) }
    # Roots and reparse-free directories repeat across files: validated once, then cached.
    $lookupCache = @{}
    $createdDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $rel = [string]$entry.RelativePath
        $cat = [string]$entry.Category
        # The category is a single directory name below the backup root and the relative
        # path is relative to it. Both come from the manifest, which is not trusted: a
        # traversal in either of them must not reach outside the backup directory.
        $catCheck = Resolve-WinEaseSafeRelativePath -RelativePath $cat -Root $BackupRoot -Label 'category' -LookupCache $lookupCache
        if (-not $catCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $cat; Error = "Refused: $($catCheck.Reason)" }
            Write-Verbose "Ignored: $($catCheck.Reason)"
            continue
        }
        $srcCheck = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $catCheck.Path -Label 'backup path' -LookupCache $lookupCache
        if (-not $srcCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($srcCheck.Reason)" }
            Write-Verbose "Ignored: $($srcCheck.Reason)"
            continue
        }
        $srcPath = $srcCheck.Path
        # Actually backup stores under BackupRoot\<Category>\<rel>; handle both
        if (-not (Test-Path -LiteralPath $srcPath)) {
            # try BackupRoot\<rel>
            $fallback = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $BackupRoot -Label 'backup path' -LookupCache $lookupCache
            if ($fallback.IsSafe -and (Test-Path -LiteralPath $fallback.Path)) { $srcPath = $fallback.Path }
        }
        if (-not (Test-Path -LiteralPath $srcPath)) { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Backup file missing' }; continue }
        # The restore target is the same kind of folder in the new profile: the category
        # (Documents, Desktop, Pictures, ...) followed by the relative path inside it.
        # Without the category every personal folder would be flattened into the profile
        # root (Documents\a.txt and Downloads\a.txt would collide). The manifest is not
        # trusted: the combined path is validated against the profile.
        $destRel = if ([string]::IsNullOrWhiteSpace($cat)) { $rel } else { "$cat\$rel" }
        $destCheck = Resolve-WinEaseSafeRelativePath -RelativePath $destRel -Root $env:USERPROFILE -Label 'restore path' -LookupCache $lookupCache
        if (-not $destCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($destCheck.Reason)" }
            Write-Verbose "Ignored: $($destCheck.Reason)"
            continue
        }
        $destPath = $destCheck.Path
        if ($DryRun) { $restored++; continue }
        try {
            $destDir = [System.IO.Path]::GetDirectoryName($destPath)
            if ($destDir -and $createdDirs.Add($destDir)) { [System.IO.Directory]::CreateDirectory($destDir) | Out-Null }
            $expectedHash = if ($VerifyHashBeforeRestore -and $entry.Sha256) { [string]$entry.Sha256 } else { '' }
            switch (Copy-WinEaseMigrationRestoreFile -SourcePath $srcPath -DestPath $destPath -ConflictPolicy $ConflictPolicy -ExpectedSha256 $expectedHash) {
                'Restored' { $restored++ }
                'Skipped' { $skipped++ }
                'HashMismatch' { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Hash mismatch (corrupt)' } }
            }
        } catch {
            $failed += [PSCustomObject]@{ Path = $rel; Error = $_.Exception.Message }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
}

# Invoke-WinEaseRegExe: runs reg.exe and reports success without letting its stderr
# output throw: under $ErrorActionPreference = 'Stop' the 2>&1 redirection turns every
# stderr line (including "The operation completed successfully.") into a terminating
# error. Returns $true on exit code 0; throws when -KeyForError names the key.
function Invoke-WinEaseRegExe {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [string]$KeyForError = ''
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & reg.exe @ArgumentList 2>&1
        $exit = $LASTEXITCODE
        $stderrText = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$($_.Exception.Message)" }) -join ' ').Trim()
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($exit -ne 0) {
        if ($KeyForError) { throw "reg.exe $($ArgumentList[0]) failed for '$KeyForError' (exit $exit): $stderrText" }
        Write-Verbose "reg.exe $($ArgumentList[0]) failed (exit $exit): $stderrText"
        return $false
    }
    return $true
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
        [string]$ConflictPolicy = 'BackupExisting',
        # Optional preloaded rules (Get-WinEaseMigrationRules result); loaded on demand when omitted
        [psobject]$Rules
    )
    if (-not $Rules) { $Rules = Get-WinEaseMigrationRules }
    $allRules = @($Rules.GameRules) + @($Rules.AppConfigRules) + @($Rules.CustomPathRules)
    $secretPatterns = $Rules.SecretPatterns
    Write-Verbose "ConflictPolicy: $ConflictPolicy"
    $copied = 0
    $skipped = 0
    $registryExported = 0
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
        $ruleBackupDir = Join-Path -Path $BackupRoot -ChildPath "rules\$rid"
        if (-not (Test-Path -LiteralPath $ruleBackupDir)) { New-Item -ItemType Directory -Force -Path $ruleBackupDir | Out-Null }
        $ruleBackupDirNative = $ruleBackupDir
        try { $ruleBackupDirNative = (Get-Item -LiteralPath $ruleBackupDir -ErrorAction Stop).FullName } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        $ruleCopied = 0
        $ruleRegistry = 0
        # RelativePath -> the rule's own SourcePaths pattern it was copied from, so the
        # restore can reconstruct every file's original location even when the rule lists
        # several sources (the flat file layout under rules\<Id> alone cannot).
        $ruleEntries = @()
        $existingSources = @()
        $missingSources = @()
        # SourcePaths (files/dirs)
        if ($rule.SourcePaths) {
            foreach ($sp in $rule.SourcePaths) {
                $src = Expand-WinEaseMigrationPath -RawPath $sp
                if (-not (Test-Path -LiteralPath $src)) { $missingSources += [string]$sp; continue }
                $existingSources += [string]$sp
                $item = Get-Item -LiteralPath $src
                $srcCandidates = Get-WinEaseMigrationBaseCandidates -BasePath $src
                if ($item.PSIsContainer) {
                    $enumOptions = $null
                    if ('System.IO.EnumerationOptions' -as [type]) {
                        $enumOptions = New-Object System.IO.EnumerationOptions
                        $enumOptions.RecurseSubdirectories = $true
                        $enumOptions.IgnoreInaccessible = $true
                        $enumOptions.AttributesToSkip = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::ReparsePoint
                    }
                    try {
                        if ($enumOptions) {
                            $di = New-Object System.IO.DirectoryInfo($src)
                            $files = $di.EnumerateFiles('*', $enumOptions)
                        } else {
                            $files = Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
                        }
                    } catch { $files = @() }
                    foreach ($f in $files) {
                        if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
                        $rel = Get-WinEaseMigrationRelativePath -BaseCandidates $srcCandidates -FullName $f.FullName
                        if (-not $IncludeSecrets -and $rule.ExcludeSecrets -and (Test-WinEaseSecretPath -FilePath $f.Name -SecretPatterns $secretPatterns)) {
                            Write-Verbose "Excluded secret: $($f.FullName)"
                            $skipped++
                            $secretExcluded++
                            continue
                        }
                        $exclude = $false
                        foreach ($pat in @($rule.ExcludePatterns)) { if ($f.Name -like $pat) { $exclude = $true; break } }
                        if ($exclude) { $skipped++; continue }
                        $dest = Join-Path -Path $ruleBackupDir -ChildPath $rel
                        $destDir = Split-Path -Parent $dest
                        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                        $ruleEntries += [PSCustomObject]@{ RelativePath = $rel; SourcePath = [string]$sp }
                        $ruleCopied++
                    }
                } else {
                    if (-not $IncludeSecrets -and $rule.ExcludeSecrets -and (Test-WinEaseSecretPath -FilePath $item.Name -SecretPatterns $secretPatterns)) {
                        Write-Verbose "Excluded secret: $($item.FullName)"; $skipped++; $secretExcluded++; continue
                    }
                    $exclude = $false
                    foreach ($pat in @($rule.ExcludePatterns)) { if ($item.Name -like $pat) { $exclude = $true; break } }
                    if ($exclude) { $skipped++; continue }
                    Copy-Item -LiteralPath $src -Destination (Join-Path -Path $ruleBackupDir -ChildPath $item.Name) -Force
                    $ruleEntries += [PSCustomObject]@{ RelativePath = [string]$item.Name; SourcePath = [string]$sp; IsFileSource = $true }
                    $ruleCopied++
                }
            }
        }
        # RegistryPaths
        # reg.exe does not understand the PowerShell PSDrive spelling (HKCU:\...): the
        # colon makes it abort with "invalid key name". Export with the plain root name
        # (HKCU\...) and check the exit code so a failed export is reported instead of
        # silently producing a rule with no backup.
        if ($rule.RegistryPaths) {
            foreach ($rp in $rule.RegistryPaths) {
                $regKey = ([string]$rp).Trim() -replace ':', ''
                if ($regKey -match '^(?i)HKCU\\') { $regKey = 'HKEY_CURRENT_USER\' + $regKey.Substring(5) }
                elseif ($regKey -match '^(?i)HKLM\\') { $regKey = 'HKEY_LOCAL_MACHINE\' + $regKey.Substring(5) }
                $regName = ($regKey -replace '[\\/:*?"<>|\s]', '_')
                if (-not $regName) { $regName = 'registry' }
                $regFile = Join-Path -Path $ruleBackupDirNative -ChildPath ($regName + '.reg')
                try {
                    $exportOk = Invoke-WinEaseRegExe -ArgumentList @('export', $regKey, $regFile, '/y')
                    if (-not $exportOk -or -not (Test-Path -LiteralPath $regFile)) {
                        $failed += [PSCustomObject]@{ Rule = $rid; Path = [string]$rp; Error = "Registry export failed for '$regKey' (reg.exe exit code $($LASTEXITCODE))" }
                    } else {
                        $ruleEntries += [PSCustomObject]@{ RelativePath = ($regName + '.reg'); SourcePath = '' }
                        $ruleRegistry++
                    }
                } catch {
                    $failed += [PSCustomObject]@{ Rule = $rid; Path = [string]$rp; Error = "Registry export failed for '$regKey': $($_.Exception.Message)" }
                }
            }
        }
        $copied += $ruleCopied
        $registryExported += $ruleRegistry
        if ($ruleCopied -gt 0 -or $ruleRegistry -gt 0) {
            $backedUp += [PSCustomObject]@{ Id = $rid; Name = $rule.Name; FileCount = $ruleCopied; RegistryCount = $ruleRegistry }
            # The rule manifest tells the restore where every file came from (SourcePath
            # keeps the raw pattern so the new machine re-expands it with its own profile).
            try {
                $ruleManifest = [PSCustomObject]@{
                    Id            = $rid
                    Created       = (Get-Date).ToString('o')
                    SourcePaths   = @($existingSources)
                    RegistryKeys  = @(@($rule.RegistryPaths) | Where-Object { $_ } | ForEach-Object {
                        $k = ([string]$_).Trim() -replace ':', ''
                        if ($k -match '^(?i)HKCU\\') { $k = 'HKEY_CURRENT_USER\' + $k.Substring(5) }
                        elseif ($k -match '^(?i)HKLM\\') { $k = 'HKEY_LOCAL_MACHINE\' + $k.Substring(5) }
                        $k
                    })
                    Entries       = @($ruleEntries)
                }
                $ruleManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path -Path $ruleBackupDir -ChildPath 'rule-manifest.json') -Encoding UTF8
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        } else {
            # Nothing was copied: report why instead of listing the rule as backed up.
            if ($missingSources.Count -gt 0 -and $existingSources.Count -eq 0) {
                $skipReasons += [PSCustomObject]@{ Item = $rid; Reason = "Source not found: $($missingSources -join ', ')" }
            } elseif ($ruleCopied -eq 0 -and $ruleRegistry -eq 0) {
                $skipReasons += [PSCustomObject]@{ Item = $rid; Reason = 'No files matched the rule (all excluded or the sources are empty)' }
            }
        }
        if ($rule.CloudSaveNotice) { $notices += [PSCustomObject]@{ RuleId = $rid; Name = $rule.Name; Notice = [string]$rule.CloudSaveNotice } }
    }
    if ($secretExcluded -gt 0) { $skipReasons += [PSCustomObject]@{ Item = "$secretExcluded file(s)"; Reason = 'Secret/credential files excluded by default (use -IncludeSecrets to back them up)' } }
    return [PSCustomObject]@{ CopiedFiles = $copied; RegistryExports = $registryExported; SkippedFiles = $skipped; FailedFiles = $failed; SecretExcludedFiles = $secretExcluded; SkipReasons = $skipReasons; BackedUpRules = $backedUp; CloudSaveNotices = $notices; RuleErrors = @($Rules.Errors) }
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
        [string]$ConflictPolicy = 'BackupExisting',
        # Optional preloaded rules (Get-WinEaseMigrationRules result); loaded on demand when omitted
        [psobject]$Rules
    )
    if (-not $Rules) { $Rules = Get-WinEaseMigrationRules }
    $allRules = @($Rules.GameRules) + @($Rules.AppConfigRules) + @($Rules.CustomPathRules)
    Write-Verbose "IncludeSecrets=$IncludeSecrets ForceRunningProcess=$ForceRunningProcess ConflictPolicy=$ConflictPolicy"
    $restored = 0
    $skipped = 0
    $failed = @()
    foreach ($rid in $RuleIds) {
        $rule = $allRules | Where-Object { $_.Id -eq $rid } | Select-Object -First 1
        $ruleBackupDir = Join-Path -Path $BackupRoot -ChildPath "rules\$rid"
        if (-not (Test-Path -LiteralPath $ruleBackupDir)) { $failed += [PSCustomObject]@{ Rule = $rid; Error = 'Backup not found' }; continue }
        if (-not $rule) { $failed += [PSCustomObject]@{ Rule = $rid; Error = 'Rule not found (remove or rename the rule, then restore its files manually)' }; continue }
        # process running check: restoring under a running application produces files it
        # will never read back (settings are written on exit), so the rule is skipped.
        if (-not $ForceRunningProcess -and $rule.ProcessNames) {
            $running = @()
            foreach ($pn in $rule.ProcessNames) {
                if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $running += $pn }
            }
            if ($running.Count -gt 0) {
                Write-Warning "Rule '$rid' skipped: process(es) running: $($running -join ', ')"
                $skipped++
                $failed += [PSCustomObject]@{ Rule = $rid; Error = "Application running ($($running -join ', ')); close it and retry" }
                continue
            }
        }
        # The rule manifest records where every backed-up file came from (see the backup).
        # SourcePath is the raw pattern, so it is expanded with THIS machine's environment.
        $ruleManifestPath = Join-Path -Path $ruleBackupDir -ChildPath 'rule-manifest.json'
        $manifestEntries = @()
        if (Test-Path -LiteralPath $ruleManifestPath) {
            try { $rm = Get-Content -LiteralPath $ruleManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json; $manifestEntries = @($rm.Entries) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
        # Allowed restore targets: the locations the rule itself declares, expanded on
        # this machine. A manifest entry may only restore inside one of them.
        $allowedRoots = @(@($rule.SourcePaths) | ForEach-Object { Expand-WinEaseMigrationPath -RawPath ([string]$_) } | Where-Object { $_ })

        # Registry restore: every *.reg file the backup wrote (one per key)
        $regFiles = @(Get-ChildItem -LiteralPath $ruleBackupDir -Filter '*.reg' -File -ErrorAction SilentlyContinue)
        foreach ($reg in $regFiles) {
            $regPathNative = $reg.FullName
            try { $regPathNative = (Get-Item -LiteralPath $reg.FullName -ErrorAction Stop).FullName } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
            if (Invoke-WinEaseRegExe -ArgumentList @('import', $regPathNative)) { $restored++ }
            else { $failed += [PSCustomObject]@{ Rule = $rid; Path = $reg.Name; Error = "Registry import failed (reg.exe exit code $($LASTEXITCODE))" } }
        }

        if ($manifestEntries.Count -gt 0) {
            $createdDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $manifestEntries) {
                $rel = [string]$entry.RelativePath
                if (-not $rel -or $rel -eq 'rule-manifest.json' -or $rel -like '*.reg') { continue }
                $srcPath = Join-Path -Path $ruleBackupDir -ChildPath $rel
                if (-not (Test-Path -LiteralPath $srcPath)) { $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = 'Backup file missing' }; continue }
                $destPath = $null
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.SourcePath) -and $allowedRoots.Count -gt 0) {
                    # The source pattern is re-expanded here; the target must stay inside
                    # the rule's declared locations (the manifest is not trusted).
                    $srcExpanded = Expand-WinEaseMigrationPath -RawPath ([string]$entry.SourcePath)
                    # A rule source can be a single file: the backup copy IS that file, so
                    # the restore target is the source itself, not a child of it.
                    $targetCandidate = $null
                    if ($entry.IsFileSource) {
                        $targetCandidate = $srcExpanded
                    } else {
                        $srcItem = Get-Item -LiteralPath $srcExpanded -Force -ErrorAction SilentlyContinue
                        if ($srcItem -and -not $srcItem.PSIsContainer) { $targetCandidate = $srcExpanded }
                        else { $targetCandidate = Join-Path -Path $srcExpanded -ChildPath $rel }
                    }
                    $target = Resolve-WinEaseRestoreTarget -Path $targetCandidate -AllowedRoots $allowedRoots
                    if ($target.IsSafe) { $destPath = $target.Path }
                    else { $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = "Refused: $($target.Reason)" }; continue }
                } else {
                    $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = 'Refused: the rule manifest has no source path or the rule declares no sources' }
                    continue
                }
                try {
                    $destDir = [System.IO.Path]::GetDirectoryName($destPath)
                    if ($destDir -and $createdDirs.Add($destDir)) { [System.IO.Directory]::CreateDirectory($destDir) | Out-Null }
                    if ((Copy-WinEaseMigrationRestoreFile -SourcePath $srcPath -DestPath $destPath -ConflictPolicy $ConflictPolicy) -eq 'Skipped') { $skipped++ } else { $restored++ }
                } catch {
                    $failed += [PSCustomObject]@{ Rule = $rid; Path = $rel; Error = $_.Exception.Message }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                }
            }
        } else {
            # Backup without a rule manifest (older WinEase version): keep the previous
            # heuristic - files go below the first existing source path of the rule.
            Get-ChildItem -LiteralPath $ruleBackupDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'rule-manifest.json' -and $_.Extension -ne '.reg' } | ForEach-Object {
                $rel = Get-WinEaseRelativePath -BasePath $ruleBackupDir -FullName $_.FullName
                # reconstruct source path from rule SourcePaths (use first existing parent)
                $src = $null
                foreach ($sp in @($rule.SourcePaths)) {
                    $expanded = Expand-WinEaseMigrationPath -RawPath ([string]$sp)
                    if ($expanded -and (Test-Path -LiteralPath $expanded)) { $src = $expanded; break }
                }
                if (-not $src) { return }
                # rel is relative to the rule's source root; restore under the source root's parent
                $destPath = $null
                if ($rule.SourcePaths -and $rule.SourcePaths.Count -gt 0) {
                    $firstSrc = Expand-WinEaseMigrationPath -RawPath ([string]$rule.SourcePaths[0])
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
                            Copy-Item -LiteralPath $destPath -Destination "$destPath.WinEase.bak" -Force
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
    }
    return [PSCustomObject]@{ RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
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
    # A previous backup into the same root: read it before Backup-WinEaseUserData rewrites
    # the manifest, so the categories / rules / custom paths this run does not touch keep
    # being restored (their files are still in the root).
    $previous = $null
    $previousPath = Join-Path -Path $BackupRoot -ChildPath 'migration-manifest.json'
    if (-not $DryRun -and (Test-Path -LiteralPath $previousPath)) {
        try { $previous = Get-Content -LiteralPath $previousPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    # App inventory
    $invPath = Join-Path -Path $BackupRoot -ChildPath 'apps-inventory.json'
    $inv = Export-WinEaseAppInventory -OutputPath $invPath -OfflineTestMode:$OfflineTestMode
    # User data backup
    $ud = Backup-WinEaseUserData -FolderMap $FolderMap -BackupRoot $BackupRoot -DryRun:$DryRun
    # Custom paths backup
    $cp = $null
    if ($CustomPaths -and $CustomPaths.Count -gt 0) {
        $cp = Backup-WinEaseCustomPaths -Paths $CustomPaths -BackupRoot $BackupRoot -DryRun:$DryRun
    }
    # Rules backup. The rules are loaded once here: the load errors (a broken
    # user-migration-rules.psd1, duplicates) belong in the manifest and the report even
    # when no rule was selected.
    $rulesData = Get-WinEaseMigrationRules
    $ruleErrors = @($rulesData.Errors)
    $rb = $null
    if ($RuleIds -and $RuleIds.Count -gt 0 -and -not $DryRun) {
        $rb = Invoke-WinEaseMigrationRulesBackup -RuleIds $RuleIds -BackupRoot $BackupRoot -IncludeSecrets:$IncludeSecrets -Rules $rulesData
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
    $customList = @($customExpanded)
    if ($previous) {
        # What this run backed up replaces the previous record of the same item; the rest is kept
        $newCategories = @($FolderMap.Keys | ForEach-Object { [string]$_ })
        $newRuleIds = @($ruleList | ForEach-Object { [string]$_.Id })
        # A file skipped as unchanged keeps the hash the previous backup recorded for it
        $previousHash = @{}
        foreach ($pe in @($previous.Entries)) { if ($pe -and $pe.Sha256) { $previousHash["$($pe.Category)|$($pe.RelativePath)"] = [string]$pe.Sha256 } }
        foreach ($e in $entries) {
            $key = "$($e.Category)|$($e.RelativePath)"
            if (-not $e.Sha256 -and $previousHash.ContainsKey($key)) { $e.Sha256 = $previousHash[$key] }
        }
        $keptEntries = @($previous.Entries | Where-Object {
                $_ -and $(if ([string]$_.Category -eq 'CustomPath') { $customList -notcontains [string]$_.SourcePath } else { $newCategories -notcontains [string]$_.Category })
            })
        $entries = $keptEntries + $entries
        $folderList = @($previous.Folders | Where-Object { $_ -and $_.Category -and $newCategories -notcontains [string]$_.Category }) + $folderList
        $ruleList = @($previous.Rules | Where-Object { $_ -and $_.Id -and $newRuleIds -notcontains [string]$_.Id }) + $ruleList
        $customList = @($previous.CustomPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $customList -notcontains [string]$_ }) + $customList
    }
    $manifest = [PSCustomObject]@{
        Created      = (Get-Date).ToString('o')
        BackupRoot   = $BackupRoot
        AppInventory = $inv.OutputPath
        Entries      = $entries
        Folders      = $folderList
        Rules        = $ruleList
        RuleErrors   = $ruleErrors
        CustomPaths  = @($customList)
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
            try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
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
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $customRoot)) { New-Item -ItemType Directory -Force -Path $customRoot | Out-Null }
    }
    $pathCache = @{}
    $createdDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $enumOptions = $null
    if ('System.IO.EnumerationOptions' -as [type]) {
        $enumOptions = New-Object System.IO.EnumerationOptions
        $enumOptions.RecurseSubdirectories = $true
        $enumOptions.IgnoreInaccessible = $true
        $enumOptions.AttributesToSkip = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::ReparsePoint
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
        $srcCandidates = Get-WinEaseMigrationBaseCandidates -BasePath $expanded
        if ($item.PSIsContainer) {
            # Back up entire folder preserving structure
            try {
                if ($enumOptions) {
                    $di = New-Object System.IO.DirectoryInfo($expanded)
                    $files = $di.EnumerateFiles('*', $enumOptions)
                } else {
                    $files = Get-ChildItem -LiteralPath $expanded -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
                }
            } catch { $files = @() }
            foreach ($f in $files) {
                if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
                $rel = Get-WinEaseMigrationRelativePath -BaseCandidates $srcCandidates -FullName $f.FullName
                $destRel = Join-Path $item.Name $rel
                $destCheck = Resolve-WinEaseSafeRelativePath -RelativePath $destRel -Root $customRoot -Label 'backup path' -LookupCache $pathCache
                if (-not $destCheck.IsSafe) {
                    $failed += [PSCustomObject]@{ Path = $f.FullName; Error = "Refused: $($destCheck.Reason)" }
                    Write-Verbose "Ignored: $($destCheck.Reason)"
                    continue
                }
                $destPath = $destCheck.Path
                if ($DryRun) { $copied++; $totalBytes += $f.Length; continue }
                try {
                    $destDir = Split-Path -Parent $destPath
                    if (-not $createdDirs.Contains($destDir)) {
                        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                        [void]$createdDirs.Add($destDir)
                    }
                    $hash = Copy-WinEaseMigrationFileWithHash -SourcePath $f.FullName -DestPath $destPath -SourceTimestamp $f.LastWriteTimeUtc
                    $copied++
                    $totalBytes += $f.Length
                    $manifest += [PSCustomObject]@{ RelativePath = $destRel; Category = 'CustomPath'; SizeBytes = $f.Length; Sha256 = $hash; LastWriteTimeUtc = $f.LastWriteTimeUtc.ToString('o'); SourcePath = $expanded }
                } catch {
                    $failed += [PSCustomObject]@{ Path = $f.FullName; Error = $_.Exception.Message }
                    Write-Verbose "Ignored: $($_.Exception.Message)"
                }
            }
        } else {
            # Back up single file
            $destCheck = Resolve-WinEaseSafeRelativePath -RelativePath ([string]$item.Name) -Root $customRoot -Label 'backup path' -LookupCache $pathCache
            if (-not $destCheck.IsSafe) {
                $failed += [PSCustomObject]@{ Path = $expanded; Error = "Refused: $($destCheck.Reason)" }
                Write-Verbose "Ignored: $($destCheck.Reason)"
                continue
            }
            $destPath = $destCheck.Path
            if ($DryRun) { $copied++; $totalBytes += $item.Length; continue }
            try {
                $hash = Copy-WinEaseMigrationFileWithHash -SourcePath $expanded -DestPath $destPath -SourceTimestamp $item.LastWriteTimeUtc
                $copied++
                $totalBytes += $item.Length
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

    $lookupCache = @{}
    $createdDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $rel = [string]$entry.RelativePath
        # The backup copy must stay inside the backup directory.
        $srcCheck = Resolve-WinEaseSafeRelativePath -RelativePath $rel -Root $customRoot -Label 'backup path' -LookupCache $lookupCache
        if (-not $srcCheck.IsSafe) {
            $failed += [PSCustomObject]@{ Path = $rel; Error = "Refused: $($srcCheck.Reason)" }
            Write-Verbose "Ignored: $($srcCheck.Reason)"
            continue
        }
        $srcPath = $srcCheck.Path
        if (-not (Test-Path -LiteralPath $srcPath)) { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Backup file missing' }; continue }
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
            $destIsFolder = ($rel -match '[\\/]') -and (-not [System.IO.File]::Exists($destPath))
            $destDir = if ($destIsFolder) { $destPath } else { [System.IO.Path]::GetDirectoryName($destPath) }
            if (-not [string]::IsNullOrWhiteSpace($destDir) -and $createdDirs.Add($destDir)) {
                [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
            }
            # Into a folder the file keeps its backup name (as Copy-Item onto a folder did).
            $finalDest = if ($destIsFolder) { Join-Path -Path $destPath -ChildPath ([System.IO.Path]::GetFileName($srcPath)) } else { $destPath }
            $expectedHash = if ($VerifyHashBeforeRestore -and $entry.Sha256) { [string]$entry.Sha256 } else { '' }
            switch (Copy-WinEaseMigrationRestoreFile -SourcePath $srcPath -DestPath $finalDest -ConflictPolicy $(if ($destIsFolder) { 'Overwrite' } else { $ConflictPolicy }) -ExpectedSha256 $expectedHash) {
                'Restored' { $restored++ }
                'Skipped' { $skipped++ }
                'HashMismatch' { $failed += [PSCustomObject]@{ Path = $rel; Error = 'Hash mismatch (corrupt)' } }
            }
        } catch {
            $failed += [PSCustomObject]@{ Path = $rel; Error = $_.Exception.Message }
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ RestoredFiles = $restored; SkippedFiles = $skipped; FailedFiles = $failed }
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
    $succeeded = [System.Collections.Generic.List[PSCustomObject]]::new()    # Area, Item, Detail
    $skippedItems = [System.Collections.Generic.List[PSCustomObject]]::new() # Item, Reason
    $failedItems = [System.Collections.Generic.List[PSCustomObject]]::new()  # Item, Reason
    $manual = [System.Collections.Generic.List[PSCustomObject]]::new()       # Item, Note
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
        $succeeded.Add([PSCustomObject]@{ Area = $pair[0]; Item = "$($r.CopiedFiles) file(s)"; Detail = (Format-WinEaseByteSize -Bytes ([int64]$r.TotalBytes)) })
        if ([int]$r.SkippedFiles -gt 0) {
            $skippedItems.Add([PSCustomObject]@{ Item = "$($pair[0]): $($r.SkippedFiles) file(s)"; Reason = 'Already present in the backup and protected by the overwrite policy (unchanged or not newer)' })
        }
        foreach ($f in @($r.FailedFiles)) {
            $failedItems.Add([PSCustomObject]@{ Item = [string]$f.Path; Reason = [string]$f.Error })
        }
    }

    # --- rule results ---
    $rr = $MigrationResult.PSObject.Properties['RulesResult']
    if ($rr -and $rr.Value) {
        $rv = $rr.Value
        $files += [int]$rv.CopiedFiles
        $succeeded.Add([PSCustomObject]@{ Area = 'App/game rules'; Item = "$($rv.CopiedFiles) file(s) from $(@($rv.BackedUpRules).Count) rule(s)"; Detail = '' })
        foreach ($s in @($rv.SkipReasons)) { $skippedItems.Add([PSCustomObject]@{ Item = [string]$s.Item; Reason = [string]$s.Reason }) }
        foreach ($f in @($rv.FailedFiles)) {
            $name = if ($f.Rule) { [string]$f.Rule } else { [string]$f.Path }
            $failedItems.Add([PSCustomObject]@{ Item = $name; Reason = [string]$f.Error })
        }
        foreach ($n in @($rv.CloudSaveNotices)) {
            $manual.Add([PSCustomObject]@{ Item = [string]$n.Name; Note = "Cloud save: $($n.Notice)" })
        }
    }

    # --- migration rules that could not be loaded (broken user rules file, duplicates) ---
    $reProps = $MigrationResult.PSObject.Properties['RuleErrors']
    if ($reProps -and $reProps.Value) {
        foreach ($e in @($reProps.Value)) {
            $failedItems.Add([PSCustomObject]@{ Item = 'Migration rules'; Reason = [string]$e })
        }
    }

    # --- restore task results ---
    $tasks = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tr = $MigrationResult.PSObject.Properties['Results']
    if ($tr -and $tr.Value) {
        foreach ($t in @($tr.Value)) {
            $tasks.Add([PSCustomObject]@{ TaskId = [string]$t.TaskId; Status = [string]$t.Status })
            $st = [string]$t.Status
            if ($st -eq 'Completed') {
                $succeeded.Add([PSCustomObject]@{ Area = 'Restore'; Item = [string]$t.TaskId; Detail = '' })
            } elseif ($st -eq 'Failed') {
                $reason = if ($t.Detail -is [string]) { [string]$t.Detail } elseif ($t.Detail -and $t.Detail.FailedFiles) { (@($t.Detail.FailedFiles | ForEach-Object { "$($_.Path) $($_.Error)".Trim() }) -join '; ') } elseif ($t.Detail -and $t.Detail.Failed) { (@($t.Detail.Failed | ForEach-Object { "$($_.App): $($_.Error)" }) -join '; ') } else { 'Task failed' }
                $failedItems.Add([PSCustomObject]@{ Item = [string]$t.TaskId; Reason = $reason })
            } else {
                $skippedItems.Add([PSCustomObject]@{ Item = [string]$t.TaskId; Reason = $st })
                if ($t.Detail -and $t.Detail.ManualGuidance) {
                    foreach ($g in @($t.Detail.ManualGuidance)) { $manual.Add([PSCustomObject]@{ Item = [string]$g.Name; Note = [string]$g.Hint }) }
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
                    $manual.Add([PSCustomObject]@{ Item = [string]$a.Name; Note = $hint })
                }
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
    $manual.Add([PSCustomObject]@{ Item = 'Accounts and sign-ins'; Note = 'Sign in again to your Microsoft account, browsers, Steam/Epic/other launchers and any cloud-sync clients. Saved passwords and tokens are not migrated.' })

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
    [void]$sb.AppendLine("<p><span class=`"ok`">$(ConvertTo-WinEaseHtmlText $ReportData.Success.Files) file(s)</span>, $(ConvertTo-WinEaseHtmlText $ReportData.Success.TotalSize) total. SHA-256 recorded for <span class=`"ok`">$(ConvertTo-WinEaseHtmlText $ReportData.Success.Sha256Verified)</span> file(s); not recorded for <span class=`"warn`">$(ConvertTo-WinEaseHtmlText $ReportData.Success.Sha256Missing)</span>.</p>")
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

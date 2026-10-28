# WinEasePathSafety.ps1 - Path normalization, containment and destructive-operation safety checks
# Dot-sourced by WinEasehelpers.ps1 (function definitions only).

function ConvertTo-WinEaseNormalizedPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be null or empty."
    }
    $cleanPath = $Path.Replace('/', '\')
    if ($cleanPath -notmatch '^[A-Za-z]:\\') {
        throw "Path must be an absolute local drive path starting with a drive letter: '$Path'"
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($cleanPath).TrimEnd('\')
    } catch {
        throw "Failed to get full path for '$Path': $_"
    }
    if ($fullPath -match '^[A-Za-z]:$') {
        throw "Drive root path is not allowed as a managed path: '$Path'"
    }
    return $fullPath
}

# Helper function: True if Path equals Root or is a descendant of it.
# Compares on a '\' boundary after canonicalizing both paths via GetFullPath.
function Test-WinEasePathWithin {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }
    try {
        $cleanP = $Path.Replace('/', '\')
        $cleanR = $Root.Replace('/', '\')
        $p = [System.IO.Path]::GetFullPath($cleanP).TrimEnd('\', '/')
        $r = [System.IO.Path]::GetFullPath($cleanR).TrimEnd('\', '/')
    } catch {
        return $false
    }
    if ($p -ieq $r) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# Helper function: path of an enumerated item relative to the folder it was enumerated from.
# Get-ChildItem reports long names even when the folder was given in 8.3 form (for example
# C:\Users\RUNNER~1\... for C:\Users\runneradmin\...), so slicing FullName by the length of the
# caller's string cut the wrong number of characters ("nts\test.txt" instead of "test.txt").
# The base is tried as given, then resolved by the file system provider; if neither is a prefix
# of the item the file name alone is returned instead of a garbled path.
function Get-WinEaseRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$FullName
    )
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($BasePath)
    try { $candidates.Add((Get-Item -LiteralPath $BasePath -Force -ErrorAction Stop).FullName) } catch { Write-Verbose "Get-WinEaseRelativePath: Get-Item failed: $($_.Exception.Message)" }
    try { $candidates.Add((Resolve-Path -LiteralPath $BasePath -ErrorAction Stop).ProviderPath) } catch { Write-Verbose "Get-WinEaseRelativePath: Resolve-Path failed: $($_.Exception.Message)" }
    foreach ($candidate in $candidates) {
        $base = $candidate.TrimEnd('\', '/')
# --- Restore path validation (shared by the PC migration engine) -------------------
# The restore side of the migration feature reads a manifest that can come from an
# untrusted source (a backup package, a shared drive, a cloud folder). Every path in
# that manifest is therefore treated as untrusted input: it is normalized and checked
# against the allowed root before a single byte is written.

        if ($base -and $FullName.StartsWith($base + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $FullName.Substring($base.Length + 1)
        }
    }
    return [System.IO.Path]::GetFileName($FullName)
}

# Normalizes a path for containment comparisons:
#   - '/' becomes '\'
#   - the path is made absolute ('..' segments are resolved by GetFullPath)
#   - the 8.3 short form is resolved to the long form when the path exists, so a
#     containment check cannot be bypassed by writing the short name
#   - trailing separators are removed
# Returns $null when the path cannot be normalized.
function ConvertTo-WinEaseComparablePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $clean = $Path.Replace('/', '\')
    try {
        $full = [System.IO.Path]::GetFullPath($clean)
    } catch {
        Write-Verbose "Ignored: $($_.Exception.Message)"
        return $null
    }
    if ([string]::IsNullOrEmpty($full)) { return $null }
    $resolved = $full
    # Only an existing path can resolve to a different spelling (8.3 short form, case).
    # Probing with File/Directory.Exists instead of letting Get-Item throw keeps the
    # common not-found case exception-free: the migration backup calls this helper for
    # every file, and most destinations do not exist yet.
    if (Test-WinEasePathExistsSafe -Path $full) {
        try {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item -and -not [string]::IsNullOrEmpty($item.FullName)) { $resolved = $item.FullName }
        } catch {
            Write-Verbose "Ignored: $($_.Exception.Message)"
        }
    }
    $trimmed = $resolved.TrimEnd('\')
    if ([string]::IsNullOrEmpty($trimmed)) { return $resolved }
    # A drive root keeps its separator: "C:" would be resolved against the current
    # directory of the drive instead of the root itself.
    if ($trimmed -match '^[A-Za-z]:$') { return $resolved }
    return $trimmed
}

# True when the path is an absolute local path: a drive letter with a root ("C:\x")
# or a UNC share ("\\server\share\x"). A drive-relative ("C:x") or root-relative
# ("\x") path is not absolute and is refused.
function Test-WinEaseAbsoluteLocalPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $clean = $Path.Replace('/', '\')
    if ($clean -match '^[A-Za-z]:\\') { return $true }
    if ($clean -match '^\\\\[^\\]+\\[^\\]+') { return $true }
    return $false
}

# Resolves the REAL file-system path of an absolute path. Every existing element between the
# drive root and the path is inspected while walking downward: 8.3 short names are expanded to
# the long form and reparse-point targets (junctions, symlinks) are substituted. Segments below
# the first non-existing element are appended lexically ('..' segments are already collapsed by
# GetFullPath). Returns $null when the path is not an absolute local path, cannot be normalized,
# or a reparse point's target cannot be read - callers that decide on this must treat $null as
# "cannot prove safe" and fail closed.
# Kept as a single function so tests can mock it: 8.3 names cannot be created on the CI runner,
# so short-name spellings are simulated through the mock (real 8.3 behaviour is unverified).
function ConvertTo-WinEaseRealPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $clean = $Path.Replace('/', '\')
    if (-not (Test-WinEaseAbsoluteLocalPath -Path $clean)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($clean)
    } catch {
        Write-Verbose "ConvertTo-WinEaseRealPath: GetFullPath failed: $($_.Exception.Message)"
        return $null
    }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { return $null }
    $current = $root.TrimEnd('\')
    $rest = $full.Substring($root.Length).TrimStart('\')
    $segments = @(); if ($rest) { $segments = @($rest -split '\\') }
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $candidate = $current + '\' + $segments[$i]
        $item = $null
        try { $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop } catch { Write-Verbose "ConvertTo-WinEaseRealPath: '$candidate' not inspectable: $($_.Exception.Message)" }
        if (-not $item) {
            # Element does not exist (or cannot be inspected): everything below is lexical.
            $remaining = for ($j = $i; $j -lt $segments.Count; $j++) { $segments[$j] }
            $current = $current + '\' + ($remaining -join '\')
            break
        }
        if (-not [string]::IsNullOrEmpty($item.FullName)) { $current = $item.FullName.TrimEnd('\') }
        else { $current = $candidate }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $target = $null
            try { $target = @($item.Target) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1 } catch { Write-Verbose "ConvertTo-WinEaseRealPath: Target of '$candidate' unreadable: $($_.Exception.Message)" }
            if ([string]::IsNullOrWhiteSpace($target)) {
                Write-Verbose "ConvertTo-WinEaseRealPath: cannot resolve the target of reparse point '$candidate'."
                return $null
            }
            $target = $target.Replace('/', '\')
            if (-not ([System.IO.Path]::IsPathRooted($target))) {
                # Relative link target: resolve against the link's parent.
                try { $target = [System.IO.Path]::GetFullPath($current + '\' + $target) } catch { return $null }
            }
            try { $target = [System.IO.Path]::GetFullPath($target) } catch { return $null }
            $current = $target.TrimEnd('\')
        }
    }
    return $current
}

# True when one of the existing elements between Root and Path is a symbolic link, a
# junction or another reparse point. A write through such a link can land outside of
# the allowed root, so the restore refuses the path instead of following it.
function Test-WinEasePathHasReparsePoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Root
    )
    $p = ConvertTo-WinEaseComparablePath -Path $Path
    if (-not $p) { return $true }
    $r = $null
    if (-not [string]::IsNullOrWhiteSpace($Root)) { $r = ConvertTo-WinEaseComparablePath -Path $Root }
    if ($r -and -not (Test-WinEasePathWithin -Path $p -Root $r)) { return $true }
    $current = $p
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $true }
        }
        if ($r -and $current -ieq $r) { break }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -ieq $current) { break }
        $current = $parent
    }
    return $false
}

# Validates a relative path that came from a manifest and returns the absolute path it
# maps to inside the allowed root.
#
# Refused: an empty path, an absolute / drive-relative / UNC / root-relative path, a
# path with a '..' segment, a path with a wildcard or an invalid character, a path that
# leaves the root after normalization, and a path that traverses a symbolic link or a
# junction.
#
# -LookupCache (optional): a hashtable shared across calls by hot loops (the migration
# backup validates every file). Memoizes the resolved allowed root and the directories
# already proven reparse-free, keyed 'root|<root>' / 'dir|<parent>'. Omitting it keeps
# the exact one-shot behaviour. Callers must not reuse a cache across different roots
# that could be swapped for links mid-run; a per-operation cache is expected.
#
# Returns @{ IsSafe = $bool; Path = <string>; Reason = <string> }
function Resolve-WinEaseSafeRelativePath {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RelativePath,
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [string]$Label = 'path',
        [hashtable]$LookupCache
    )
    $result = [PSCustomObject]@{ IsSafe = $false; Path = $null; Reason = '' }
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        $result.Reason = "the $Label is empty"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $result.Reason = 'the allowed root is empty'
        return $result
    }
    $clean = $RelativePath.Replace('/', '\')
    if ([System.IO.Path]::IsPathRooted($clean)) {
        $result.Reason = "the $Label is not relative: '$RelativePath'"
        return $result
    }
    if ($clean -match '[<>:"|?*]' -or $clean -match '[\x00-\x1f]') {
        $result.Reason = "the $Label contains an invalid character: '$RelativePath'"
        return $result
    }
    $segments = @(foreach ($seg in ($clean -split '\\')) { if ($seg -ne '' -and $seg -ne '.') { $seg } })
    if ($segments.Count -eq 0) {
        $result.Reason = "the $Label does not name a file: '$RelativePath'"
        return $result
    }
    foreach ($seg in $segments) {
        if ($seg -eq '..') {
            $result.Reason = "the $Label leaves the allowed root ('..'): '$RelativePath'"
            return $result
        }
    }
    $rootFull = $null
    $rootKey = 'root|' + $Root
    if ($null -ne $LookupCache -and $LookupCache.ContainsKey($rootKey)) { $rootFull = $LookupCache[$rootKey] }
    if (-not $rootFull) {
        $rootFull = ConvertTo-WinEaseComparablePath -Path $Root
        if ($null -ne $LookupCache -and $rootFull) { $LookupCache[$rootKey] = $rootFull }
    }
    if (-not $rootFull) {
        $result.Reason = "the allowed root cannot be resolved: '$Root'"
        return $result
    }
    $joined = Join-Path -Path $rootFull -ChildPath ($segments -join '\')
    $full = ConvertTo-WinEaseComparablePath -Path $joined
    if (-not $full) {
        $result.Reason = "the $Label cannot be resolved: '$RelativePath'"
        return $result
    }
    if (-not (Test-WinEasePathWithin -Path $full -Root $rootFull)) {
        $result.Reason = "the $Label leaves the allowed root '$Root': '$RelativePath'"
        return $result
    }
    $traversesReparse = $null
    if ($null -ne $LookupCache) {
        # Directories repeat across files: a parent once proven reparse-free up to the
        # root lets the check shrink to the file itself (a file can still be a link).
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if ([string]::IsNullOrEmpty($parent)) { $parent = $rootFull }
        $dirKey = 'dir|' + $parent.ToLowerInvariant()
        $parentSafe = $false
        if ($LookupCache.ContainsKey($dirKey)) { $parentSafe = [bool]$LookupCache[$dirKey] }
        else {
            $parentSafe = -not (Test-WinEasePathHasReparsePoint -Path $parent -Root $rootFull)
            $LookupCache[$dirKey] = $parentSafe
        }
        if (-not $parentSafe) {
            $traversesReparse = $true
        } elseif (Test-WinEasePathExistsSafe -Path $full) {
            # The target exists: it must not be a link itself.
            try {
                $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
                if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $traversesReparse = $true }
            } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        }
    } else {
        $traversesReparse = Test-WinEasePathHasReparsePoint -Path $full -Root $rootFull
    }
    if ($traversesReparse) {
        $result.Reason = "the $Label traverses a symbolic link or junction: '$RelativePath'"
        return $result
    }
    $result.IsSafe = $true
    $result.Path = $full
    return $result
}

# Validates an absolute restore destination against the roots the caller allows.
#
# Refused: a relative or drive-relative path, a path with a wildcard or an invalid
# character, a path outside every allowed root, and a path that traverses a symbolic
# link or a junction.
#
# Returns @{ IsSafe = $bool; Path = <string>; Reason = <string> }
function Resolve-WinEaseRestoreTarget {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$AllowedRoots
    )
    $result = [PSCustomObject]@{ IsSafe = $false; Path = $null; Reason = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.Reason = 'the restore target is empty'
        return $result
    }
    $clean = $Path.Replace('/', '\')
    if (-not (Test-WinEaseAbsoluteLocalPath -Path $clean)) {
        $result.Reason = "the restore target is not an absolute path: '$Path'"
        return $result
    }
    $pathRoot = [System.IO.Path]::GetPathRoot($clean)
    $rest = if ($pathRoot -and $clean.Length -gt $pathRoot.Length) { $clean.Substring($pathRoot.Length) } else { '' }
    if ($rest -match '[<>:"|?*]' -or $rest -match '[\x00-\x1f]') {
        $result.Reason = "the restore target contains an invalid character: '$Path'"
        return $result
    }
    $full = ConvertTo-WinEaseComparablePath -Path $clean
    if (-not $full) {
        $result.Reason = "the restore target cannot be resolved: '$Path'"
        return $result
    }
    $roots = @($AllowedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($roots.Count -eq 0) {
        $result.Reason = 'no restore target was allowed for this restore'
        return $result
    }
    $matchedRoot = $null
    foreach ($r in $roots) {
        $rootFull = ConvertTo-WinEaseComparablePath -Path $r
        if (-not $rootFull) { continue }
        if (Test-WinEasePathWithin -Path $full -Root $rootFull) { $matchedRoot = $rootFull; break }
    }
    if (-not $matchedRoot) {
        $result.Reason = "the restore target '$Path' is outside the allowed locations ($($roots -join ', '))"
        return $result
    }
    if (Test-WinEasePathHasReparsePoint -Path $full -Root $matchedRoot) {
        $result.Reason = "the restore target traverses a symbolic link or junction: '$Path'"
        return $result
    }
    $result.IsSafe = $true
    $result.Path = $full
    return $result
}

function Test-IsNtfsVolume {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root -and $Path -match '^[a-zA-Z]:') { $root = $Path.Substring(0, 2) + '\' }
        if (-not $root) { return $false }
        try {
            $drive = New-Object System.IO.DriveInfo($root)
            if ($drive.IsReady) {
                return ($drive.DriveFormat -ieq 'NTFS')
            }
        } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        if ($root -match '^[a-zA-Z]:') {
            $letter = $root.Substring(0, 1)
            $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
            return ($vol.FileSystem -ieq 'NTFS')
        }
        return $false
    } catch {
        return $false
    }
}

# Private helper for Test-IsSafePathToDelete: purely lexical judgement over an already
# normalized path (no reparse-point resolution). True when the path is a drive root, a UNC
# share root, part of the user profile, a protected OS directory, or the repository script
# directory (or an ancestor/descendant of any of these).
function Test-WinEaseProtectedLexicalPath {
    param([string]$Path)
    $full = $Path
    # 1. Drive roots (C:, D:\, etc.)
    if ([string]::IsNullOrWhiteSpace($full) -or $full.Length -le 3 -or $full -match '^[A-Za-z]:$') { return $true }

    # 2. Reject UNC roots (\\server\share)
    if ($full -match '^\\\\[^\\]+\\[^\\]+$') { return $true }

    # 3. User profile and users root
    $systemProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ($systemProfile) {
        $normUser = [System.IO.Path]::GetFullPath($systemProfile).TrimEnd('\', '/')
        if ($full -ieq $normUser -or $normUser.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    if ($env:SystemDrive) {
        $hostUsers = [System.IO.Path]::GetFullPath("$($env:SystemDrive)\Users").TrimEnd('\', '/')
        if ($full -ieq $hostUsers -or $hostUsers.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    # 4. Critical OS and program files directories
    $protectedRoots = @(
        [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows),
        [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFiles),
        [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonProgramFiles),
        [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonApplicationData)
    )
    if (${env:ProgramFiles(x86)}) {
        $protectedRoots += ${env:ProgramFiles(x86)}
    }
    foreach ($pr in $protectedRoots) {
        if ([string]::IsNullOrWhiteSpace($pr)) { continue }
        $normPr = [System.IO.Path]::GetFullPath($pr).TrimEnd('\', '/')
        if ($full -ieq $normPr -or $full.StartsWith($normPr + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $normPr.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    # 5. Repository script directory itself, any subfolder inside it, or any ancestor of it
    $refScriptDir = if ($scriptDir) { $scriptDir } elseif ($script:WinEaseHelperRoot) {
        $script:WinEaseHelperRoot
    } elseif ($PSScriptRoot) {
        Split-Path -Parent $PSScriptRoot
    } else {
        $null
    }
    if ($refScriptDir) {
        $normScript = [System.IO.Path]::GetFullPath($refScriptDir).TrimEnd('\', '/')
        if ($full -ieq $normScript -or $full.StartsWith($normScript + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $normScript.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-IsSafePathToDelete {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # "C:" and "C:foo" are drive-relative: GetFullPath would resolve them against the current
    # directory of that drive, so what gets judged is not what the caller named. Refuse them.
    if (-not (Test-WinEaseAbsoluteLocalPath -Path $Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        if (Test-WinEaseProtectedLexicalPath -Path $full) { return $false }

        # The lexical judgement cannot see through junctions or symlinks: "<tmp>\junc\System32"
        # with junc -> %windir% is lexically safe but really inside the protected Windows
        # directory. Resolve the real path (existing ancestors are 8.3-expanded and reparse
        # targets substituted) and apply the same judgement to it - refuse when EITHER the
        # lexical or the real path names something protected. A real path that cannot be
        # determined is refused (fail closed). Non-existing tail segments keep the lexical
        # judgement, so plain "would-be" directories behave as before.
        $real = ConvertTo-WinEaseRealPath -Path $full
        if ([string]::IsNullOrWhiteSpace($real)) { return $false }
        $realNorm = $real.TrimEnd('\', '/')
        if (-not $realNorm.Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (Test-WinEaseProtectedLexicalPath -Path $realNorm) { return $false }
        }

        return $true
    } catch {
        return $false
    }
}

function Test-IsPathPreserved {
    param(
        [string]$Path,
        [System.Collections.Generic.HashSet[string]]$PreservedDirs
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not $PreservedDirs -or $PreservedDirs.Count -eq 0) {
        return $false
    }

    $normPath = try { ConvertTo-WinEaseNormalizedPath -Path $Path } catch { $Path.TrimEnd('\', '/') }
    # Pre-compute trailing slash path for case-insensitive parent boundary comparisons
    $normPathWithSlash = $normPath + '\'

    foreach ($pDir in $PreservedDirs) {
        if ([string]::IsNullOrWhiteSpace($pDir)) { continue }

        # Canonicalize pDir with ConvertTo-WinEaseNormalizedPath to ensure consistent drive path normalization
        $normPDir = try { ConvertTo-WinEaseNormalizedPath -Path $pDir } catch { $pDir.TrimEnd('\', '/') }

        # Case-insensitive exact match
        if ($normPath -ieq $normPDir) {
            Write-Warning "Directory '$normPath' is in PreservedMountDirs. Deletion prohibited."
            return $true
        }

        # Case-insensitive parent check: is $normPath a parent of preserved directory $normPDir?
        if ($normPDir.StartsWith($normPathWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Directory '$normPath' is a parent of preserved directory '$normPDir'. Deletion prohibited."
            return $true
        }

        # Case-insensitive descendant check: is $normPath a descendant of preserved directory $normPDir?
        $normPDirWithSlash = $normPDir + '\'
        if ($normPath.StartsWith($normPDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Directory '$normPath' is a descendant of preserved directory '$normPDir'. Deletion prohibited."
            return $true
        }
    }

    return $false
}

function Test-CanSafelyDeleteDirectory {
    param(
        [string]$Path,
        [string]$ExpectedBaseDir,
        [System.Collections.Generic.HashSet[string]]$PreservedDirs
    )
    if (-not $script:BuildSucceeded) { return $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-IsSafePathToDelete -Path $Path)) { return $false }

    $normPath = try { ConvertTo-WinEaseNormalizedPath -Path $Path } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-WinEaseNormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        # Prohibit deleting the workspace root itself
        if ($normPath -ieq $normBase) {
            Write-Warning "Directory '$normPath' is the workspace root itself. Deletion prohibited."
            return $false
        }
        if (-not (Test-WinEasePathWithin -Path $normPath -Root $normBase)) {
            Write-Warning "Directory '$normPath' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if (Test-IsPathPreserved -Path $normPath -PreservedDirs $PreservedDirs) {
        return $false
    }

    try {
        $activeMounts = @(Get-WinEaseMountedImages)
        $lingering = $activeMounts | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-WinEaseNormalizedPath -Path $_.Path } catch { $null } } else { $null }
            $p -and (($p -ieq $normPath) -or $p.StartsWith($normPath + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $normPath.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase))
        }
        if ($lingering) {
            Write-Warning "Active DISM mount detected on or under '$normPath'. Deletion prohibited."
            return $false
        }
    } catch {
        Write-Warning "Could not confirm DISM mount status on '$normPath': $_. Deletion prohibited."
        return $false
    }

    foreach ($hive in @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM')) {
        try {
            $hiveKey = "HKLM:\$hive"
            if (Test-Path -LiteralPath $hiveKey -ErrorAction Stop) {
                Write-Warning "Offline registry hive '$hive' still loaded. Deletion prohibited."
                return $false
            }
        } catch {
            Write-Warning "Could not confirm offline registry hive '$hive' status: $_. Deletion prohibited."
            return $false
        }
    }

    return $true
}

function Test-CanSafelyDeleteVhdx {
    param(
        [string]$VhdxPath,
        [bool]$VhdxDetached,
        [string]$ExpectedBaseDir,
        [System.Collections.Generic.HashSet[string]]$PreservedDirs
    )
    if (-not $script:BuildSucceeded) { return $false }
    if (-not $VhdxDetached) { return $false }
    if ([string]::IsNullOrWhiteSpace($VhdxPath) -or -not (Test-Path -LiteralPath $VhdxPath)) { return $false }
    if (-not (Test-IsSafePathToDelete -Path $VhdxPath)) { return $false }

    $normVhdx = try { ConvertTo-WinEaseNormalizedPath -Path $VhdxPath } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-WinEaseNormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        if (-not (Test-WinEasePathWithin -Path $normVhdx -Root $normBase)) {
            Write-Warning "VHDX '$normVhdx' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if (Test-IsPathPreserved -Path $normVhdx -PreservedDirs $PreservedDirs) {
        return $false
    }

    return $true
}

# Safe existence probe: Test-Path throws on some access-denied paths (verified),
# while Directory/File.Exists never throw.
function Test-WinEasePathExistsSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return ([System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path)) } catch { return $false }
}

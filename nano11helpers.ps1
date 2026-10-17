# nano11helpers.ps1 - Pure utility helpers extracted from nano11builder.ps1 (F8)
# Dot-sourced by nano11builder.ps1. Functions use $script: scope of the caller.
# Keep this file next to nano11builder.ps1.

function ConvertTo-Nano11NormalizedPath {
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
# Compares on a '\' boundary so that 'C:\work2' is NOT treated as inside 'C:\work'.
function Test-Nano11PathWithin {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }
    $p = $Path.Replace('/', '\').TrimEnd('\')
    $r = $Root.Replace('/', '\').TrimEnd('\')
    if ($p -ieq $r) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}


function Test-IsNtfsVolume {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root) { return $false }
        try {
            $drive = New-Object System.IO.DriveInfo($root)
            if ($drive.IsReady) {
                return ($drive.DriveFormat -ieq 'NTFS')
            }
        } catch {}
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


function Test-IsSafePathToDelete {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        if ($full.Length -le 3) { return $false }
        $systemProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ($full -ieq $systemProfile.TrimEnd('\', '/')) { return $false }
        $windowsDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows)
        if (Test-Nano11PathWithin -Path $full -Root $windowsDir) { return $false }
        if ($scriptDir -and ($full -ieq [System.IO.Path]::GetFullPath($scriptDir).TrimEnd('\', '/'))) { return $false }
        return $true
    } catch {
        return $false
    }
}

function New-Nano11BuildId {
    param([datetime]$Timestamp = (Get-Date))
    $timePart = $Timestamp.ToString('yyyyMMdd_HHmmss')
    $guidPart = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    return "${timePart}_${guidPart}"
}


# ==============================================================================
# Helper function: Standardized DISM wrapper with retries and exit code diagnostics
function Invoke-Dism {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$DismArgs,
        [int]$Retries = 1,
        [string]$ActivityDescription = "",
        [switch]$CaptureOutput,
        [switch]$Quiet
    )
    if ($ActivityDescription) {
        Write-Host "  -> DISM: $ActivityDescription..." -ForegroundColor Cyan
    }
    $fullArgs = @('/English')
    if ($script:DismLogPath) {
        $fullArgs += @("/LogPath:$script:DismLogPath", "/LogLevel:3")
    }
    $fullArgs += $DismArgs

    for ($i = 1; $i -le $Retries; $i++) {
        if ($CaptureOutput) {
            $output = & dism.exe @fullArgs 2>&1
            if ($LASTEXITCODE -eq 0) {
                return $output
            }
        } else {
            if ($Quiet) {
                & dism.exe @fullArgs > $null 2>&1
            } else {
                & dism.exe @fullArgs
            }
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        }
        if ($i -lt $Retries) {
            Write-Host "DISM command failed (Exit code: $LASTEXITCODE). Retrying ($i/$Retries)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }
    if ($CaptureOutput) { return $null }
    return $false
}


# ==============================================================================
# Helper function: Safely unmount offline registry hive with retry and garbage collection
function Unmount-RegistryHiveWithRetry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [int]$Retries = 5
    )
    for ($i = 0; $i -le $Retries; $i++) {
        & reg.exe query "HKLM\$Name" > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $true
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 300
        & reg.exe unload "HKLM\$Name" > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    return $false
}

# 4. Language-independent Administrators group via Well-Known SID (S-1-5-32-544)
$adminGroupSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

# Helper function: Query registered mounted images from DISM
# Helper function: Query registered mounted images from DISM (Distinguishes 0-mount success from query failure)

# ==============================================================================
# ==============================================================================
function Get-Nano11VolumeFreeSpaceGB {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
        $driveLetter = (Split-Path -Path $resolved -Qualifier).TrimEnd(':')
        $drive = [System.IO.DriveInfo]::new($driveLetter)
        return [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
    } catch {
        throw "Failed to query volume free space for '$Path': $_"
    }
}


# ==============================================================================
function Test-CanSafelyDeleteDirectory {
    param(
        [string]$Path,
        [string]$ExpectedBaseDir,
        [System.Collections.Generic.HashSet[string]]$PreservedDirs
    )
    if (-not $script:BuildSucceeded) { return $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-IsSafePathToDelete -Path $Path)) { return $false }

    $normPath = try { ConvertTo-Nano11NormalizedPath -Path $Path } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-Nano11NormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        if (-not (Test-Nano11PathWithin -Path $normPath -Root $normBase)) {
            Write-Warning "Directory '$normPath' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if ($PreservedDirs) {
        foreach ($pDir in $PreservedDirs) {
            if ([string]::IsNullOrWhiteSpace($pDir)) { continue }
            $normPDir = try { ConvertTo-Nano11NormalizedPath -Path $pDir } catch { $pDir.TrimEnd('\', '/') }
            if ($normPath -ieq $normPDir) {
                Write-Warning "Directory '$normPath' is in PreservedMountDirs. Deletion prohibited."
                return $false
            }
            if ($normPDir.StartsWith($normPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "Directory '$normPath' is a parent of preserved directory '$normPDir'. Deletion prohibited."
                return $false
            }
        }
    }

    try {
        $activeMounts = @(Get-Nano11MountedImages)
        $lingering = $activeMounts | Where-Object {
            $p = if ($_.Path) { try { ConvertTo-Nano11NormalizedPath -Path $_.Path } catch { $null } } else { $null }
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


# ==============================================================================
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

    $normVhdx = try { ConvertTo-Nano11NormalizedPath -Path $VhdxPath } catch { return $false }
    if ($ExpectedBaseDir) {
        $normBase = try { ConvertTo-Nano11NormalizedPath -Path $ExpectedBaseDir } catch { return $false }
        if (-not (Test-Nano11PathWithin -Path $normVhdx -Root $normBase)) {
            Write-Warning "VHDX '$normVhdx' is outside workspace '$normBase'. Deletion prohibited."
            return $false
        }
    }

    if ($PreservedDirs) {
        foreach ($pDir in $PreservedDirs) {
            if ([string]::IsNullOrWhiteSpace($pDir)) { continue }
            $normP = try { ConvertTo-Nano11NormalizedPath -Path $pDir } catch { $pDir.TrimEnd('\', '/') }
            if ($normVhdx -ieq $normP -or $normVhdx.StartsWith($normP + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "VHDX '$normVhdx' is in or under PreservedMountDirs '$normP'. Deletion prohibited."
                return $false
            }
        }
    }

    return $true
}


# ==============================================================================
# Helper function: Verify oscdimg.exe Authenticode signature or pinned SHA256 hashes
function Test-OscdimgIntegrity {
    param([string]$OscdimgPath)
    if (-not $OscdimgPath -or -not (Test-Path -LiteralPath $OscdimgPath)) { return $false }
    
    # 1. Check Authenticode Signature (Official Microsoft Windows ADK binary)
    try {
        $sig = Get-AuthenticodeSignature -FilePath $OscdimgPath -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid' -and ($sig.SignerCertificate.Subject -match 'Microsoft')) {
            return $true
        }
    } catch {}

    # 2. Known Official & Pinned SHA256 Hashes
    $knownHashes = @(
        'F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD', # Bundled repo version (2.56)
        '8DC3FB38E75C42127BE0A29D64CA6D79DFDDFDCBEE4A3BA8B36CFEBDCC1689E2', # Windows 11 ADK x64
        'CE53D1C8C08FF54B4B91D2DFDE80F9D86427BC8C78FA6BBDE278456CDD2E2B85', # Windows 11 ADK x86
        'B27E36C95A7490A175B5F17781C5C7A7C0B0C4670ACBF5B0BA0E0556BCDE0F46'  # Windows 11 ADK ARM64
    )
    try {
        $fileHash = (Get-FileHash -LiteralPath $OscdimgPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($fileHash -and ($knownHashes -contains $fileHash.ToUpperInvariant())) {
            return $true
        }
    } catch {}

    return $false
}


# ==============================================================================
# Helper function: Convert file/folder path to 8.3 short path if containing spaces, preventing parser issues with oscdimg -bootdata
function Get-SafeShortPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    if ($Path -notmatch '\s') { return $Path }
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $short = $fso.GetFile($Path).ShortPath
            if ($short) { return $short }
        } elseif (Test-Path -LiteralPath $Path -PathType Container) {
            $short = $fso.GetFolder($Path).ShortPath
            if ($short) { return $short }
        }
    } catch {}
    return $Path
}

# ---------------------------------------------------------------------------------------------
# WIM stream integrity helpers (Phase 15 self-healing)
# DISM /Apply-Image /Verify fails with 577 (0x80070241 ERROR_INVALID_IMAGE_HASH) or 0x80070570 when a
# decompressed file does not match the SHA-1 recorded in the WIM. Two very different causes produce the
# same error code:
#   1. Persistent corruption: a stream was damaged while /Unmount-Image /commit hashed/compressed it.
#      The bad stream is then copied verbatim by /Export-Image (which still reports success).
#   2. Transient corruption: the WIM is intact, but data was damaged in RAM while DISM decompressed it
#      (unstable memory/CPU). The failing file changes on every run.
# The helpers below extract the failing files directly via wimgapi.dll, classify them, and repair
# persistent corruption from a known-good reference image (source media / untouched editions).
# ---------------------------------------------------------------------------------------------


# WinEaseWim.ps1 - Native WIM export, fingerprinting and repair helpers
# Dot-sourced into the script scope of WinEasebuilder.ps1 (function definitions only).

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

function Initialize-WinEaseWimNative {
    if ('WinEaseWimNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinEaseWimNative {
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr WIMCreateFile(string path, uint access, uint disposition, uint flags, uint compression, out uint creationResult);
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool WIMSetTemporaryPath(IntPtr hWim, string path);
    [DllImport("wimgapi.dll", SetLastError = true)]
    public static extern uint WIMGetImageCount(IntPtr hWim);
    [DllImport("wimgapi.dll", SetLastError = true)]
    public static extern IntPtr WIMLoadImage(IntPtr hWim, uint index);
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool WIMExtractImagePath(IntPtr hImage, string imagePath, string destinationPath, uint flags);
    [DllImport("wimgapi.dll", SetLastError = true)]
    public static extern bool WIMCloseHandle(IntPtr hObject);
}
'@
}

# Extracts a single file from a WIM/ESD image without mounting it. Returns $true on success.
function Export-WinEaseWimFile {
    param(
        [Parameter(Mandatory=$true)][string]$WimPath,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][string]$TempPath
    )
    Initialize-WinEaseWimNative
    if (-not (Test-Path -LiteralPath $TempPath)) { New-Item -ItemType Directory -Path $TempPath -Force | Out-Null }
    $destDir = Split-Path -Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    $created = [uint32]0
    # GENERIC_READ (0x80000000), OPEN_EXISTING (3)
    $hWim = [WinEaseWimNative]::WIMCreateFile($WimPath, [uint32]2147483648, 3, 0, 0, [ref]$created)
    if ($hWim -eq [IntPtr]::Zero) { return $false }
    try {
        [void][WinEaseWimNative]::WIMSetTemporaryPath($hWim, $TempPath)
        $hImg = [WinEaseWimNative]::WIMLoadImage($hWim, [uint32]$Index)
        if ($hImg -eq [IntPtr]::Zero) { return $false }
        try {
            $imgPath = '\' + $ImagePath.TrimStart('\')
            return [bool][WinEaseWimNative]::WIMExtractImagePath($hImg, $imgPath, $Destination, 0)
        } finally {
            [void][WinEaseWimNative]::WIMCloseHandle($hImg)
        }
    } finally {
        [void][WinEaseWimNative]::WIMCloseHandle($hWim)
    }
}

function Get-WinEaseWimImageCount {
    param([Parameter(Mandatory=$true)][string]$WimPath)
    Initialize-WinEaseWimNative
    $created = [uint32]0
    $hWim = [WinEaseWimNative]::WIMCreateFile($WimPath, [uint32]2147483648, 3, 0, 0, [ref]$created)
    if ($hWim -eq [IntPtr]::Zero) { return 0 }
    try { return [int][WinEaseWimNative]::WIMGetImageCount($hWim) } finally { [void][WinEaseWimNative]::WIMCloseHandle($hWim) }
}

# Extracts a file twice and returns its SHA-1 / signature state. Two differing reads of the same
# stream mean the host itself is corrupting data in memory.
function Get-WinEaseWimFileFingerprint {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SHA1 only fingerprints files to detect corruption; not a security control')]
    param(
        [Parameter(Mandatory=$true)][string]$WimPath,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][string]$WorkDir,
        [switch]$KeepFile
    )
    $leaf = Split-Path -Path $ImagePath -Leaf
    $runDir = Join-Path -Path $WorkDir -ChildPath ([System.IO.Path]::GetRandomFileName())
    $tmpDir = Join-Path -Path $runDir -ChildPath 'wimtmp'
    $hashes = @()
    $keptFile = $null
    try {
        for ($n = 1; $n -le 2; $n++) {
            $outFile = Join-Path -Path (Join-Path -Path $runDir -ChildPath "read$n") -ChildPath $leaf
            if (-not (Export-WinEaseWimFile -WimPath $WimPath -Index $Index -ImagePath $ImagePath -Destination $outFile -TempPath $tmpDir)) {
                return $null
            }
            $hashes += (Get-FileHash -LiteralPath $outFile -Algorithm SHA1).Hash
            if ($n -eq 1) { $keptFile = $outFile }
        }
        $sigStatus = 'Unknown'
        try { $sigStatus = [string](Get-AuthenticodeSignature -LiteralPath $keptFile -ErrorAction Stop).Status } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
        return [PSCustomObject]@{
            Sha1          = $hashes[0]
            StableRead    = ($hashes[0] -eq $hashes[1])
            Signature     = $sigStatus
            File          = if ($KeepFile) { $keptFile } else { $null }
            RunDir        = $runDir
        }
    } finally {
        if (-not $KeepFile) {
            & cmd.exe /c "rd /s /q `"$runDir`"" > $null 2>&1
        }
    }
}

# Parses a DISM log for files that failed hash/signature verification and returns image-relative paths.
function Get-WinEaseDeepApplyFailedFiles {
    param(
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][string]$ApplyDir
    )
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    $applyRoot = [System.IO.Path]::GetFullPath($ApplyDir).TrimEnd('\')
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($LogPath)) {
        if ($line -match 'DISM WIM Provider:\s*PID=\d+\s+(?<p>.+?)\s+\(HRESULT=0x(?:80070241|80070570|8007000D|80070017)\)') {
            $full = $matches['p'].Trim()
            if ($full.StartsWith($applyRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $full.Substring($applyRoot.Length).TrimStart('\').TrimStart('/')
                if ($rel -and -not $found.Contains($rel)) { $found.Add($rel) }
            }
        }
    }
    return @($found)
}

# Finds a verified known-good copy of a file in reference images (never the corrupted build image).
function Find-WinEaseReferenceWimFile {
    param(
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][object[]]$References,
        [Parameter(Mandatory=$true)][string]$WorkDir
    )
    foreach ($ref in $References) {
        if (-not $ref.Path -or -not (Test-Path -LiteralPath $ref.Path)) { continue }
        $indices = [System.Collections.Generic.List[int]]::new()
        if ($ref.PreferredIndex) { $indices.Add([int]$ref.PreferredIndex) }
        $count = Get-WinEaseWimImageCount -WimPath $ref.Path
        for ($i = 1; $i -le $count; $i++) {
            if (-not $indices.Contains($i) -and -not ($ref.ExcludeIndex -and $i -eq [int]$ref.ExcludeIndex)) { $indices.Add($i) }
        }
        foreach ($i in $indices) {
            $fp = Get-WinEaseWimFileFingerprint -WimPath $ref.Path -Index $i -ImagePath $ImagePath -WorkDir $WorkDir -KeepFile
            if (-not $fp) { continue }
            if ($fp.StableRead -and $fp.Signature -ne 'HashMismatch') {
                $fp | Add-Member -NotePropertyName Source -NotePropertyValue "$($ref.Path) [Index $i]"
                return $fp
            }
            & cmd.exe /c "rd /s /q `"$($fp.RunDir)`"" > $null 2>&1
        }
    }
    return $null
}

# Overwrites corrupted files inside index 1 of a WIM with verified copies, commits, and re-exports so the
# corrupted stream is dropped. Files are overwritten in place with robocopy /B (backup semantics), which
# preserves WinSxS hard links, ownership and ACLs.
function Repair-WinEaseWimFiles {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SHA1 only fingerprints files to detect corruption; not a security control')]
    param(
        [Parameter(Mandatory=$true)][string]$WimPath,
        [Parameter(Mandatory=$true)][object[]]$Repairs,
        [Parameter(Mandatory=$true)][string]$WorkDir,
        [string]$CompressMode = '/Compress:max',
        [string]$LogPath
    )
    $mount = Invoke-WinEaseImageMount -ImageFile $WimPath -ImageIndex 1 -Retries 3
    $mountDir = $mount.MountDir
    $script:DismMountDir = $mountDir
    $script:MountOpened = $true
    $committed = $false
    try {
        foreach ($r in $Repairs) {
            $target = Join-Path -Path $mountDir -ChildPath $r.ImagePath.TrimStart('\')
            if (-not (Test-Path -LiteralPath $target)) {
                throw "Repair target not found in mounted image: $($r.ImagePath)"
            }
            $srcDir = Split-Path -Path $r.GoodFile -Parent
            $leaf = Split-Path -Path $target -Leaf
            & robocopy.exe $srcDir (Split-Path -Path $target -Parent) $leaf /B /COPY:D /IS /IT /R:2 /W:1 /NP /NJH /NJS /NFL /NDL > $null 2>&1
            if ($LASTEXITCODE -ge 8) {
                throw "robocopy /B failed to overwrite '$($r.ImagePath)' (Exit code: $LASTEXITCODE)."
            }
            $newHash = (Get-FileHash -LiteralPath $target -Algorithm SHA1).Hash
            if ($newHash -ne $r.GoodSha1) {
                throw "Repaired file hash mismatch for '$($r.ImagePath)' (expected $($r.GoodSha1), got $newHash)."
            }
            Write-Host "    [REPAIRED] $($r.ImagePath) <= $($r.Source)" -ForegroundColor Green
        }

        $safeLoc = if ($scriptDir) { $scriptDir } elseif ($PSScriptRoot) { (Split-Path -Parent $PSScriptRoot) } else { [System.IO.Path]::GetTempPath() }
        Set-Location -LiteralPath $safeLoc
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        for ($retry = 1; $retry -le 3; $retry++) {
            & dism.exe /English /Unmount-Image "/MountDir:$mountDir" /commit
            if ($LASTEXITCODE -eq 0) { $committed = $true; break }
            Start-Sleep -Seconds (2 * $retry)
        }
        if (-not $committed) { throw "Failed to commit repaired image (Exit code: $LASTEXITCODE)." }
    } catch {
        if (-not $committed) {
            & dism.exe /English /Unmount-Image "/MountDir:$mountDir" /discard > $null 2>&1
        }
        throw
    } finally {
        $script:MountOpened = $false
        try { Clear-DismMountConflicts -TargetMountDir $mountDir -TargetWimFile $WimPath } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }

    # Re-export so the superseded (corrupted) stream is removed and a fresh integrity table is written.
    $repairExport = Join-Path -Path $WorkDir -ChildPath "install_repaired_$([System.IO.Path]::GetRandomFileName()).wim"
    $repairScratch = Join-Path -Path $WorkDir -ChildPath "repair_export_scratch"
    New-Item -ItemType Directory -Path $repairScratch -Force | Out-Null
    $exportArgs = @('/English', '/Export-Image', "/SourceImageFile:$WimPath", '/SourceIndex:1', "/DestinationImageFile:$repairExport", $CompressMode, "/ScratchDir:$repairScratch", '/CheckIntegrity')
    if ($LogPath) { $exportArgs += "/LogPath:$LogPath" }
    & dism.exe @exportArgs
    $exportExit = $LASTEXITCODE
    & cmd.exe /c "rd /s /q `"$repairScratch`"" > $null 2>&1
    if ($exportExit -ne 0 -or -not (Test-Path -LiteralPath $repairExport)) {
        Remove-Item -LiteralPath $repairExport -Force -ErrorAction SilentlyContinue
        throw "Re-export of repaired install.wim failed (Exit code: $exportExit)."
    }
    Remove-Item -LiteralPath $WimPath -Force -ErrorAction Stop
    Move-Item -LiteralPath $repairExport -Destination $WimPath -Force -ErrorAction Stop
}

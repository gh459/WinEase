#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the full release package WinEase-<tag>-win-<arch>.zip (shared by CI and local use).
.DESCRIPTION
    The package is the source tree of a commit (git archive, the same bytes as the source release ZIP) plus the
    binaries built by tools\build-binaries.ps1 for one architecture:

        WinEase.exe                       the launcher
        gui\winui\bin\**                  the WinUI 3 window (self-contained)
        plugins\builtin\*.dll             the official built-in plugins
        plugins\builtin\builtin.lock.psd1 their SHA256 allow list

    Nothing else is added. .github\scripts\verify-release-zip.py checks the result (--binaries): the source part
    must equal the commit and the added files must match the hash list of the CI build output.
    Run tools\build-binaries.ps1 first (or point -BinariesRoot at a downloaded CI artifact of that architecture).
.PARAMETER Tag
    Release tag (or any label) used in the file name, e.g. v2.1.0.
.PARAMETER Architecture
    x64 or arm64. Only names the package and must match the architecture the binaries were built for.
.PARAMETER Commit
    The commit to package (default: HEAD).
.PARAMETER BinariesRoot
    Folder that holds the build output with the layout above (default: the repository root, where build-binaries.ps1 writes it).
.PARAMETER OutputDir
    Where the ZIP and its .sha256 file are written (default: dist in the repository root).
.PARAMETER Prefix
    Top-level folder inside the ZIP (default: WinEase, as in the source ZIP).
.EXAMPLE
    .\tools\build-binaries.ps1 -Architecture x64
    .\tools\package-release.ps1 -Tag v2.1.0 -Architecture x64
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z._-]*$')]
    [string]$Tag,
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,
    [string]$Commit = 'HEAD',
    [string]$BinariesRoot,
    [string]$OutputDir,
    [string]$Prefix = 'WinEase'
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BinariesRoot) { $BinariesRoot = $repoRoot }
if (-not $OutputDir) { $OutputDir = Join-Path -Path $repoRoot -ChildPath 'dist' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git was not found.' }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$BinariesRoot = (Resolve-Path -LiteralPath $BinariesRoot).Path
$files = New-Object System.Collections.Generic.List[object]
function Add-BinaryFile {
    param([string]$FullName)
    $rel = $FullName.Substring($BinariesRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    $files.Add([PSCustomObject]@{ Path = $rel; FullName = $FullName })
}

# the allowed paths (keep in sync with ALLOWED_BINARY_PATTERNS in .github\scripts\verify-release-zip.py)
$launcher = Join-Path -Path $BinariesRoot -ChildPath 'WinEase.exe'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "WinEase.exe not found in $BinariesRoot. Run tools\build-binaries.ps1 first." }
Add-BinaryFile -FullName $launcher

$winuiDir = Join-Path -Path (Join-Path -Path $BinariesRoot -ChildPath 'gui') -ChildPath 'winui\bin'
if (-not (Test-Path -LiteralPath (Join-Path -Path $winuiDir -ChildPath 'WinEaseGui.exe') -PathType Leaf)) {
    throw "gui\winui\bin\WinEaseGui.exe not found in $BinariesRoot. Run tools\build-binaries.ps1 first."
}
foreach ($f in (Get-ChildItem -LiteralPath $winuiDir -Recurse -File | Sort-Object -Property FullName)) { Add-BinaryFile -FullName $f.FullName }

$builtinDir = Join-Path -Path (Join-Path -Path $BinariesRoot -ChildPath 'plugins') -ChildPath 'builtin'
$lock = Join-Path -Path $builtinDir -ChildPath 'builtin.lock.psd1'
if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { throw "plugins\builtin\builtin.lock.psd1 not found in $BinariesRoot. Run tools\build-binaries.ps1 first." }
$pluginDlls = @(Get-ChildItem -LiteralPath $builtinDir -File -Filter '*.dll' | Sort-Object -Property Name)
if ($pluginDlls.Count -eq 0) { throw "No plugin DLL in $builtinDir." }
foreach ($f in $pluginDlls) { Add-BinaryFile -FullName $f.FullName }
Add-BinaryFile -FullName $lock

# the source part: git archive of the commit (the same call as the source release ZIP)
$full = (& git -C $repoRoot rev-parse --verify "$Commit^{commit}")
if ($LASTEXITCODE -ne 0) { throw "Commit not found: $Commit" }
$full = "$full".Trim()
$committed = [DateTimeOffset]::Parse(("$(& git -C $repoRoot show -s --format=%cI $full)").Trim())

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$finalZipPath = Join-Path -Path $OutputDir -ChildPath "WinEase-$Tag-win-$Architecture.zip"
# Built under a temporary name and renamed once complete, so a failed run never leaves a half-written .zip
# that looks like a release asset (and an existing good package survives a failed rebuild).
$zipPath = "$finalZipPath.partial"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
& git -C $repoRoot -c core.autocrlf=false archive --format=zip "--prefix=$Prefix/" -o $zipPath $full
if ($LASTEXITCODE -ne 0) { throw "git archive failed with exit code $LASTEXITCODE" }

$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $existing = New-Object System.Collections.Generic.HashSet[string]
    foreach ($e in $archive.Entries) { [void]$existing.Add($e.FullName) }
    foreach ($f in $files) {
        $name = "$Prefix/$($f.Path)"
        if ($existing.Contains($name)) { throw "$($f.Path) is already part of commit $full; binaries must not be committed." }
        $entry = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $committed
        $in = [System.IO.File]::OpenRead($f.FullName)
        try {
            $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
    }
} finally { $archive.Dispose() }
Move-Item -LiteralPath $zipPath -Destination $finalZipPath -Force
$zipPath = $finalZipPath

# <zip>.sha256 in the format of sha256sum (two spaces, LF) so that `sha256sum -c` and Get-FileHash agree
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$shaPath = "$zipPath.sha256"
[System.IO.File]::WriteAllText($shaPath, "$hash  $(Split-Path -Leaf $zipPath)`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Package: $zipPath" -ForegroundColor Green
Write-Host "  commit $full, $($files.Count) binary file(s) added, SHA-256 $hash"
$zipPath

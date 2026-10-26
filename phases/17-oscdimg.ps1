# Phase 17: 17-oscdimg
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


# 17. Locate or download oscdimg.exe (checks local dirs, PATH, ADK, and multi-mirror fallback)
$oscdimgCandidates = @(
    (Join-Path -Path $scriptDir -ChildPath "oscdimg.exe"),
    (Join-Path -Path (Get-Location).Path -ChildPath "oscdimg.exe"),
    (Join-Path -Path "$env:USERPROFILE\Downloads\WinEase-main" -ChildPath "oscdimg.exe"),
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\arm64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\arm64\Oscdimg\oscdimg.exe"
)

# Also check if oscdimg is available in PATH
$pathOscd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
if ($pathOscd -and $pathOscd.Source) {
    $oscdimgCandidates += $pathOscd.Source
}

$oscdimgExe = $null
foreach ($candidate in $oscdimgCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        if (Test-OscdimgIntegrity -OscdimgPath $candidate) {
            $oscdimgExe = $candidate
            Write-Host "Found verified local oscdimg.exe: $oscdimgExe" -ForegroundColor Green
            break
        } else {
            Write-Warning "Candidate oscdimg binary at '$candidate' failed Authenticode and hash verification! Skipping."
        }
    }
}

if (-not $oscdimgExe) {
    $targetOscdPath = Join-Path -Path $scriptDir -ChildPath "oscdimg.exe"
    Write-Host "Downloading oscdimg.exe..." -ForegroundColor Cyan

    $mirrors = @(
        "https://raw.githubusercontent.com/gh459/WinEase/main/oscdimg.exe",
        "https://github.com/gh459/WinEase/raw/main/oscdimg.exe",
        "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    if ([Enum]::IsDefined([Net.SecurityProtocolType], 'Tls13')) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]'Tls13'
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

    foreach ($url in $mirrors) {
        try {
            Write-Host "  - Attempting download from: $url" -ForegroundColor Gray
            Invoke-WebRequest -Uri $url -OutFile $targetOscdPath -UseBasicParsing -TimeoutSec 15
            if ((Test-Path -LiteralPath $targetOscdPath) -and (Test-OscdimgIntegrity -OscdimgPath $targetOscdPath)) {
                $oscdimgExe = $targetOscdPath
                Write-Host "  - oscdimg.exe downloaded and integrity verified successfully!" -ForegroundColor Green
                break
            } else {
                if (Test-Path -LiteralPath $targetOscdPath) { Remove-Item -LiteralPath $targetOscdPath -Force -ErrorAction SilentlyContinue }
            }
        } catch {
            Write-Host "  - Mirror failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # NOTE: The former public-DNS fallback (resolving raw.githubusercontent.com
    # via 8.8.8.8 and downloading from the raw IP with a Host header) was
    # removed: unauthenticated DNS answers decided the download endpoint and
    # the IP-literal HTTPS request could not validate the certificate against
    # the hostname. If every mirror above fails, the build stops below; local
    # candidates and mirror downloads remain gated by Test-OscdimgIntegrity.
}

if (-not $oscdimgExe) {
    $script:DiagnosticData.FailurePhase = "Phase 17: Locate or Verify oscdimg.exe"
    $script:DiagnosticData.FailureMessage = "Failed to locate or download an Authenticode-verified oscdimg.exe."
    Write-WinEaseDiagnosticReport "Missing oscdimg"
    throw "Phase 17: No Authenticode-verified oscdimg.exe available. Cannot proceed with bootable ISO generation."
}

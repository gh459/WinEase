# Phase 17: 17-oscdimg
# Extracted from nano11builder.ps1
# Dot-sourced by the main orchestrator


# 17. Locate or download oscdimg.exe (checks local dirs, PATH, ADK, and multi-mirror fallback)
$oscdimgCandidates = @(
    (Join-Path -Path $scriptDir -ChildPath "oscdimg.exe"),
    (Join-Path -Path (Get-Location).Path -ChildPath "oscdimg.exe"),
    (Join-Path -Path "$env:USERPROFILE\Downloads\nano11-main" -ChildPath "oscdimg.exe"),
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
        "https://raw.githubusercontent.com/gh459/nano11/main/oscdimg.exe",
        "https://github.com/gh459/nano11/raw/main/oscdimg.exe",
        "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
    )
    
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    if ([Enum]::IsDefined([Net.SecurityProtocolType], 'Tls13')) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]'Tls13'
    }
} catch {}
    
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

    # If still not found (e.g. system DNS failed to resolve hostnames), try public DNS resolution fallback
    if (-not $oscdimgExe) {
        try {
            Write-Host "  - Attempting public DNS fallback resolution (8.8.8.8)..." -ForegroundColor Gray
            $dnsEntry = Resolve-DnsName -Name "raw.githubusercontent.com" -Server 8.8.8.8 -ErrorAction SilentlyContinue | Where-Object { $_.IP4Address } | Select-Object -First 1
            if ($dnsEntry -and $dnsEntry.IP4Address) {
                $tempOscdPath = Join-Path -Path $env:TEMP -ChildPath "oscdimg_dns_temp_$([System.IO.Path]::GetRandomFileName()).exe"
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("Host", "raw.githubusercontent.com")
                $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                $wc.DownloadFile("https://$($dnsEntry.IP4Address)/gh459/nano11/main/oscdimg.exe", $tempOscdPath)
                if ((Test-Path -LiteralPath $tempOscdPath) -and (Test-OscdimgIntegrity -OscdimgPath $tempOscdPath)) {
                    Move-Item -LiteralPath $tempOscdPath -Destination $targetOscdPath -Force
                    $oscdimgExe = $targetOscdPath
                    Write-Host "  - oscdimg.exe downloaded and verified successfully via public DNS fallback!" -ForegroundColor Green
                } else {
                    if (Test-Path -LiteralPath $tempOscdPath) { Remove-Item -LiteralPath $tempOscdPath -Force -ErrorAction SilentlyContinue }
                }
            }
        } catch {
            Write-Host "  - Public DNS fallback download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

if (-not $oscdimgExe) {
    $script:DiagnosticData.FailurePhase = "Phase 17: Locate or Verify oscdimg.exe"
    $script:DiagnosticData.FailureMessage = "Failed to locate or download an Authenticode-verified oscdimg.exe."
    Write-Nano11DiagnosticReport "Missing oscdimg"
    throw "Phase 17: No Authenticode-verified oscdimg.exe available. Cannot proceed with bootable ISO generation."
}

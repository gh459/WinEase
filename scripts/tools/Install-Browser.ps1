[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    if ([Enum]::IsDefined([Net.SecurityProtocolType], 'Tls13')) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]'Tls13'
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
$ErrorActionPreference = 'Stop'

# Verify a downloaded installer before it is executed (S-M3): the Authenticode
# signature must be Valid and the signer subject must contain one of the
# expected publisher fragments for that browser. On any failure the file is
# deleted and $false is returned, so the caller can abort the installation.
function Test-WinEaseBrowserInstallerSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ExpectedSubjectParts,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($null -eq $sig -or $sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        $statusText = if ($null -eq $sig) { 'NoSignature' } else { [string]$sig.Status }
        Write-Host "Signature verification failed for $DisplayName (Status: $statusText). Deleting the downloaded file and aborting." -ForegroundColor Red
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $false
    }
    $subject = ''
    if ($null -ne $sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
    $matched = $false
    foreach ($part in $ExpectedSubjectParts) {
        if ($subject -like "*$part*") { $matched = $true; break }
    }
    if (-not $matched) {
        Write-Host "Unexpected signer for $DisplayName (Signer: $subject). Deleting the downloaded file and aborting." -ForegroundColor Red
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Host "Signature verified for $DisplayName (Signer: $subject)" -ForegroundColor Gray
    return $true
}

Clear-Host
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               WinEase Browser Installer" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Edge was removed for minimal footprint. Select a browser" -ForegroundColor Gray
Write-Host "to download and install directly from its official CDN:" -ForegroundColor Gray
Write-Host ""
Write-Host "  [1] Google Chrome         (Official Silent Installer)" -ForegroundColor Green
Write-Host "  [2] Mozilla Firefox        (Official Silent Installer - Japanese)" -ForegroundColor Yellow
Write-Host "  [3] Brave Browser          (Official Standalone Installer)" -ForegroundColor Magenta
Write-Host "  [4] Floorp Browser         (Japanese High-Privacy Gecko)" -ForegroundColor Cyan
Write-Host "  [5] Microsoft Edge         (Official Standalone Installer)" -ForegroundColor Blue
Write-Host "  [0] Exit" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Cyan

$choice = Read-Host "Select option [1-5, 0]"
if (-not $choice -or $choice.Trim() -eq '0') { exit }

$tempDir = Join-Path -Path $env:TEMP -ChildPath "WinEase_browser_$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    switch ($choice.Trim()) {
        '1' {
            Write-Host "`nDownloading Google Chrome..." -ForegroundColor Green
            $installer = Join-Path -Path $tempDir -ChildPath "ChromeSetup.exe"
            Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/latest/chrome_installer.exe" -OutFile $installer -UseBasicParsing
            if (-not (Test-WinEaseBrowserInstallerSignature -Path $installer -ExpectedSubjectParts @('Google') -DisplayName "Google Chrome")) { throw "Signature verification failed for Google Chrome; installation aborted." }
            Write-Host "Installing Google Chrome silently..." -ForegroundColor Green
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Google Chrome installation completed!" -ForegroundColor Green
        }
        '2' {
            Write-Host "`nDownloading Mozilla Firefox..." -ForegroundColor Yellow
            $installer = Join-Path -Path $tempDir -ChildPath "FirefoxSetup.exe"
            Invoke-WebRequest -Uri "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=ja" -OutFile $installer -UseBasicParsing
            if (-not (Test-WinEaseBrowserInstallerSignature -Path $installer -ExpectedSubjectParts @('Mozilla') -DisplayName "Mozilla Firefox")) { throw "Signature verification failed for Mozilla Firefox; installation aborted." }
            Write-Host "Installing Mozilla Firefox silently..." -ForegroundColor Yellow
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait
            Write-Host "Mozilla Firefox installation completed!" -ForegroundColor Green
        }
        '3' {
            Write-Host "`nDownloading Brave Browser..." -ForegroundColor Magenta
            $installer = Join-Path -Path $tempDir -ChildPath "BraveSetup.exe"
            Invoke-WebRequest -Uri "https://laptop-updates.brave.com/latest/winx64" -OutFile $installer -UseBasicParsing
            if (-not (Test-WinEaseBrowserInstallerSignature -Path $installer -ExpectedSubjectParts @('Brave') -DisplayName "Brave Browser")) { throw "Signature verification failed for Brave Browser; installation aborted." }
            Write-Host "Installing Brave Browser silently..." -ForegroundColor Magenta
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Brave Browser installation completed!" -ForegroundColor Green
        }
        '4' {
            Write-Host "`nDownloading Floorp Browser..." -ForegroundColor Cyan
            $installer = Join-Path -Path $tempDir -ChildPath "FloorpSetup.exe"
            Invoke-WebRequest -Uri "https://github.com/Floorp-Projects/Floorp/releases/latest/download/floorp-windows-x86_64-setup.exe" -OutFile $installer -UseBasicParsing
            if (-not (Test-WinEaseBrowserInstallerSignature -Path $installer -ExpectedSubjectParts @('Mozilla', 'Ablaze', 'Floorp') -DisplayName "Floorp Browser")) { throw "Signature verification failed for Floorp Browser; installation aborted." }
            Write-Host "Installing Floorp Browser silently..." -ForegroundColor Cyan
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait
            Write-Host "Floorp Browser installation completed!" -ForegroundColor Green
        }
        '5' {
            Write-Host "`nDownloading Microsoft Edge..." -ForegroundColor Blue
            $installer = Join-Path -Path $tempDir -ChildPath "MicrosoftEdgeSetup.exe"
            Invoke-WebRequest -Uri "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/latest/MicrosoftEdgeSetup.exe" -OutFile $installer -UseBasicParsing
            if (-not (Test-WinEaseBrowserInstallerSignature -Path $installer -ExpectedSubjectParts @('Microsoft') -DisplayName "Microsoft Edge")) { throw "Signature verification failed for Microsoft Edge; installation aborted." }
            Write-Host "Installing Microsoft Edge silently..." -ForegroundColor Blue
            Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
            Write-Host "Microsoft Edge installation completed!" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "Download/installation error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2
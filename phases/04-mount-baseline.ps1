# Phase 4: 04-mount-baseline
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'sourceWimSize', Justification = 'Read by later phases or New-BuildContextFromScriptScope in the shared builder scope')]
param()


Write-Host "Mounting Windows image (Index: $index)..." -ForegroundColor Green
Write-Host "  -> DISM is unpacking system files (takes approx. 1-2 min on SSD)..." -ForegroundColor Cyan
Write-Host "  -> [Notice] DISM normally pauses at 90%-94% for 1-2 minutes while committing 100,000+ NTFS ACLs, hardlinks, and metadata." -ForegroundColor Yellow
Write-Host "     This is expected Windows DISM behavior. Please DO NOT close this window - it will proceed automatically." -ForegroundColor Yellow
Set-ItemOwnershipAndAccess -Path $destWim
try { Set-ItemProperty -LiteralPath $destWim -Name IsReadOnly -Value $false -ErrorAction Stop } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

$mountResult = Invoke-WinEaseImageMount -ImageFile $destWim -ImageIndex $index -Retries 3
$scratchDir = $mountResult.MountDir
$script:DismMountDir = $scratchDir
$script:MountOpened = $true

$sourceWimSize = if (Test-Path -LiteralPath $destWim) { (Get-Item -LiteralPath $destWim).Length } else { 0 }

# Capture pre-debloat package and WinSxS baseline metrics for before/after comparison
Write-Host "Capturing pre-debloat image baseline metrics..." -ForegroundColor Cyan
$pkgBeforePath = Join-Path -Path $logDir -ChildPath "packages-before.txt"
$featBeforePath = Join-Path -Path $logDir -ChildPath "features-before.txt"
$winsxsBeforePath = Join-Path -Path $logDir -ChildPath "winsxs-before.txt"

Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Packages", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $pkgBeforePath -Encoding utf8
Invoke-Dism -DismArgs @("/image:$scratchDir", "/Get-Features", "/Format:Table") -CaptureOutput | Set-Content -LiteralPath $featBeforePath -Encoding utf8
if ($safeDebloatMode) {
    Write-Host "SafeDebloatMode enabled: Skipping /AnalyzeComponentStore baseline scan to prevent cache thrashing and preserve stream stability." -ForegroundColor Cyan
    $script:WinsxsBeforeRaw = @("Actual Size of Component Store : 0 MB", "(AnalyzeComponentStore skipped in SafeDebloatMode)")
    $script:WinsxsBeforeRaw | Set-Content -LiteralPath $winsxsBeforePath -Encoding utf8
} else {
    $script:WinsxsBeforeRaw = Invoke-Dism -DismArgs @("/image:$scratchDir", "/Cleanup-Image", "/AnalyzeComponentStore") -CaptureOutput
    $script:WinsxsBeforeRaw | Set-Content -LiteralPath $winsxsBeforePath -Encoding utf8
}

if ($CheckHealth) {
    Write-Host "Verifying image component store health (-CheckHealth)..." -ForegroundColor Cyan
    & dism.exe /English /Image:"$scratchDir" /Cleanup-Image /CheckHealth
}

# Directive 2.1: Physical ownership acquisition and deletion of System32 binaries removed to prevent WIM hardlink corruption.
# Neutralization is handled safely via IFEO debugger hijacking in Phase 10.

# Detect UI Language and Architecture
$imageIntl = & dism.exe /English /Get-Intl "/Image:$scratchDir"
$languageCode = "en-US"
$imageIntlText = ($imageIntl -join "`n")
if ($imageIntlText -match 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2})') {
    $languageCode = $Matches[1]
    Write-Host "Detected default system UI language code: $languageCode" -ForegroundColor Green
} else {
    Write-Host "Default system UI language code could not be detected, falling back to en-US." -ForegroundColor Yellow
}
# The language of the image is protected: the language pack removal (the Advanced Debloat
# item "Remove non-Japanese language packs") never touches it.
$script:detectedImageLanguage = $languageCode

# Size-first Asian IME decoupling target (README "Keep Asian IMEs" behavior):
# Retain only the IME package family matching the target UI language (ko-kr / zh-cn / zh-tw).
# For any other target language (e.g. ja-JP, en-US) foreign Asian IME packages are treated as removable.
$script:primaryImeLang = $null
$detectedLanguageLower = "$languageCode".ToLowerInvariant()
if ($detectedLanguageLower -match '^(ko|kor)(-.*)?$') {
    $script:primaryImeLang = 'ko-kr'
} elseif ($detectedLanguageLower -match '^(zh-cn|zh-sg)(-.*)?$') {
    $script:primaryImeLang = 'zh-cn'
} elseif ($detectedLanguageLower -match '^(zh-tw|zh-hk|zh-mo)(-.*)?$') {
    $script:primaryImeLang = 'zh-tw'
} elseif ($detectedLanguageLower -like 'zh-*') {
    $script:primaryImeLang = 'zh-cn'
}

$imageInfo = & dism.exe /English /Get-WimInfo "/WimFile:$destWim" "/Index:$index"
$architecture = "amd64"
$lines = $imageInfo -split '\r?\n'
foreach ($line in $lines) {
    if ($line -like '*Architecture*') {
        $rawArch = ($line -split ':\s*')[1].Trim().ToLower()
        if ($rawArch -in @('x64', 'amd64')) {
            $architecture = 'amd64'
        } elseif ($rawArch -in @('arm64', 'aarch64')) {
            $architecture = 'arm64'
        } elseif ($rawArch -in @('x86')) {
            $architecture = 'x86'
        }
        Write-Host "Detected Architecture: $architecture" -ForegroundColor Green
        break
    }
}

# Record the now-known image index, edition and architecture in diagnostics and the config snapshot
if ($script:DiagnosticData) {
    $script:DiagnosticData.SelectedImageIndex = $index
    $script:DiagnosticData.SelectedImageName  = $targetEditionName
}
if ($configSnapshotPath -and (Test-Path -LiteralPath $configSnapshotPath)) {
    try {
        $resolvedConfig.Architecture = $architecture
        $resolvedConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configSnapshotPath -Encoding UTF8 -Force
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# Pre-enable WSL2 and Virtual Machine Platform if requested (Resolves Issue #5)
if ($wslSupport) {
    Write-Host "Enabling WSL2 and VirtualMachinePlatform before WinSxS slimming..." -ForegroundColor Green
    & dism.exe /English "/image:$scratchDir" /Enable-Feature /FeatureName:VirtualMachinePlatform /All > $null 2>&1
    & dism.exe /English "/image:$scratchDir" /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /All > $null 2>&1
    Write-Host "  - WSL2 and VirtualMachinePlatform enabled." -ForegroundColor Green
}

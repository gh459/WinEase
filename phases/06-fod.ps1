# Phase 6: 06-fod
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


# 6. Removing system packages (FoD / Optional features)
Write-Host "Removing unnecessary system packages..." -ForegroundColor Cyan

if ($removeLegacyFOD) {
    Write-Host "Removing legacy system capabilities & features (-RemoveLegacyFOD)..." -ForegroundColor Cyan
    $legacyCaps = @(
        'VBSCRIPT~~~~0.0.1.0',
        'Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0',
        'Media.WindowsMediaPlayer~~~~0.0.1.0'
    )
    foreach ($cap in $legacyCaps) {
        & dism.exe /English "/image:$scratchDir" /Remove-Capability "/CapabilityName:$cap" > $null 2>&1
    }
    & dism.exe /English "/image:$scratchDir" /Disable-Feature /Remove /FeatureName:SMB1Protocol > $null 2>&1
    Write-Host "  - Legacy capabilities (VBScript, ISE, WMP, SMB1) removed." -ForegroundColor Green
}
$packagePatterns = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~",
    "Microsoft-Windows-MediaPlayer-Package~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-StepsRecorder-Package~",
    "Microsoft-Windows-MSPaint-FoD-Package~",
    "Microsoft-Windows-SnippingTool-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~",
    "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
    "OpenSSH-Client-Package~",
    "Microsoft-Windows-Search-Engine-Client-Package~",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~",
    "Microsoft-Windows-Hello-Face-Package~",
    "Microsoft-Windows-Hello-BioEnrollment-Package~",
    "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
    "Microsoft-Windows-TPM-WMI-Provider-Package~",
    "Microsoft-Windows-Narrator-App-Package~",
    "Microsoft-Windows-Magnifier-App-Package~",
    "Microsoft-Windows-Printing-PMCPPC-FoD-Package~",
    "Microsoft-Windows-WebcamExperience-Package~",
    "Microsoft-Media-MPEG2-Decoder-Package~",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~",

    # Foreign language font packages (preserves Latin, system, and Japanese Jpan fonts)
    "Microsoft-Windows-LanguageFeatures-Fonts-Hans-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Hant-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Kore-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Thai-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Deva-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Syrc-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Cher-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Ethi-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Beng-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Gujr-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Guru-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Knda-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Mlym-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Orya-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Taml-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Telu-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Hebr-Package~",
    "Microsoft-Windows-LanguageFeatures-Fonts-Arab-Package~",

    # Additional obsolete/unneeded optional FOD packages
    "Microsoft-Windows-WMIC-FoD-Package~",
    "Microsoft-Windows-Printing-WFS-FoD-Package~",
    "Microsoft-Windows-WirelessDisplay-FOD-Package~",
    "Microsoft-Windows-SNMP-Client-Package~",
    "Telnet-Client-Package~",
    "SimpleTCP-Client-Package~",
    "Microsoft-Windows-RDC-Package~",
    "Microsoft-Windows-Fax-Client-Package~",
    "Microsoft-Windows-Recall-FoD-Package~",
    "Microsoft-Windows-User-Experience-Virtualization-Package~",
    "Microsoft-Windows-Device-Management-Enterprise-Package~",
    "Microsoft-Windows-Notepad-FoD-Package~",
    "Microsoft-Windows-Paint-FoD-Package~",
    "Microsoft-Windows-MathRecognizer-Package~",

    # Decoupled Asian/Foreign Language Cleanup:
    # Always remove foreign Asian IMEs and heavy foreign Speech, Text-to-Speech, OCR, and Handwriting packages.
    # These packages take gigabytes of space and are completely unused in Japanese (ja-JP) or English (en-US) installations.
    "*IME-ko-kr*",
    "*IME-zh-cn*",
    "*IME-zh-tw*",
    "*IME-zh-hk*",
    "Microsoft-Windows-LanguageFeatures-Speech-zh-*",
    "Microsoft-Windows-LanguageFeatures-Speech-ko-*",
    "Microsoft-Windows-LanguageFeatures-Speech-de-*",
    "Microsoft-Windows-LanguageFeatures-Speech-fr-*",
    "Microsoft-Windows-LanguageFeatures-Speech-es-*",
    "Microsoft-Windows-LanguageFeatures-Speech-it-*",
    "Microsoft-Windows-LanguageFeatures-Speech-pt-*",
    "Microsoft-Windows-LanguageFeatures-Speech-ru-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-zh-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-ko-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-de-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-fr-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-es-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-it-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-pt-*",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-ru-*",
    "Microsoft-Windows-LanguageFeatures-Handwriting-zh-*",
    "Microsoft-Windows-LanguageFeatures-Handwriting-ko-*",
    "Microsoft-Windows-LanguageFeatures-OCR-zh-*",
    "Microsoft-Windows-LanguageFeatures-OCR-ko-*"
)

if (-not $keepAsianIME) {
    $packagePatterns += @(
        "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~",
        "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~",
        "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~",
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~",
        "*IME-ja-jp*"
    )
}

if ($removeDefender) {
    # NOTE: "Windows-Defender-Client-Package~" (the pattern that was used here before) does
    # not exist in the official Windows 11 install.wim: the Defender servicing payload is
    # part of the base OS (a Servicing Stack package) and is therefore never listed by
    # "dism /Get-Packages", so the pattern matched nothing and the removal was a no-op.
    # The pattern is kept for images that actually ship the FoD client package, and the
    # real payload (windows-defender-service) is neutralized in Phase 08 by removing the
    # CBS re-staging maps plus the ProgramData/Program Files payload.
    $packagePatterns += "Windows-Defender-Client-Package~"
    $packagePatterns += "Microsoft-Windows-Windows-Defender-Client-Package~"
}

# UltraSlim size-first trim (additional ④ size levers):
# Remove the target language's Speech (voice typing), TextToSpeech (narrator voice data),
# and OCR feature packages. Handwriting and the IME packages stay for input integrity.
# Applied only for CJK targets (ja/ko/zh): heavyweight ML voice & character data live only there.
if ($ultraSlimMode -and ("$languageCode" -match '^(ja|ko|zh)[-a-zA-Z]*$')) {
    Write-Host "  [UltraSlim] Trimming Speech/TextToSpeech/OCR language feature packages for '$languageCode'..." -ForegroundColor Cyan
    $packagePatterns += @(
        "Microsoft-Windows-LanguageFeatures-Speech-$languageCode*",
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode*",
        "Microsoft-Windows-LanguageFeatures-OCR-$languageCode*"
    )
}

# Apply preservation filters to $packagePatterns before scanning
if ($keepExtraFonts) {
    $packagePatterns = @($packagePatterns | Where-Object { $_ -notlike "Microsoft-Windows-LanguageFeatures-Fonts-*" })
}
if ($keepAsianIME) {
    # Decoupled Asian IME trimming (size-first, README "Keep Asian IMEs" behavior):
    # The pattern list always carries foreign IME removal patterns (ko-kr / zh-cn / zh-tw / zh-hk).
    # Drop ONLY patterns that would remove the target UI language's own IME packages;
    # foreign IME families stay in the removal list so they are stripped from the image.
    # e.g. ja-JP target -> IME-ko-kr / IME-zh-cn / IME-zh-tw / IME-zh-hk keep matching and are
    #      removed by DISM, while IME-ja-jp is protected (no pattern remains for it plus a
    #      per-package guard below).
    if ($script:primaryImeLang) {
        $packagePatterns = @($packagePatterns | Where-Object { $_ -notlike "*IME-$script:primaryImeLang*" })
    }
}

$allPackagesOutput = & dism.exe /English "/image:$scratchDir" /Get-Packages /Format:Table
$allPackages = ($allPackagesOutput -split '\r?\n') | Select-Object -Skip 1

$packagesToRemove = [System.Collections.Generic.List[string]]::new()
foreach ($packagePattern in $packagePatterns) {
    $pattern = if ($packagePattern.EndsWith("*")) { $packagePattern } else { "$packagePattern*" }
    $matched = $allPackages | Where-Object { $_ -like $pattern }
    foreach ($pkg in $matched) {
        $packageIdentity = ($pkg -split '\s+')[0]
        if ($packageIdentity -and (-not $packagesToRemove.Contains($packageIdentity))) {
            # Defensive guard: Strictly protect fonts and the target-language Asian IME if preservation flags are set
            if ($keepExtraFonts -and ($packageIdentity -like "*LanguageFeatures-Fonts-*")) {
                continue
            }
            $ownLanguageIme = ($script:primaryImeLang -and $packageIdentity -like "*IME-$script:primaryImeLang*")
            $ownLanguageFont = $false
            if ($script:primaryImeLang) {
                $ownLanguageFontPackage = @{ 'ko-kr' = 'Fonts-Kore'; 'zh-cn' = 'Fonts-Hans'; 'zh-tw' = 'Fonts-Hant' }[$script:primaryImeLang]
                if ($ownLanguageFontPackage) {
                    $ownLanguageFont = ($packageIdentity -like "*LanguageFeatures-$ownLanguageFontPackage*")
                }
            }
            if ($keepAsianIME -and ($ownLanguageIme -or $packageIdentity -like "*Fonts-Jpan*")) {
                continue
            }
            if ($ownLanguageFont) {
                continue
            }
            $packagesToRemove.Add($packageIdentity)
        }
    }
}

foreach ($packageIdentity in $packagesToRemove) {
    Write-Host "  - Removing package: $packageIdentity"
    & dism.exe /English "/image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" > $null 2>&1
}

# M2: User extension actions (FOD)
if (Get-Command -Name Invoke-WinEaseUserExtensionActions -ErrorAction SilentlyContinue) {
    try { Invoke-WinEaseUserExtensionActions -PhaseType FOD -ScratchDir $scratchDir -DryRun:$DryRun | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

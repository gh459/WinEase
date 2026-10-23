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
# FoD / optional-feature package patterns, each bound to an individual option.
# The polarity is uniform: the option is ON -> the package is removed, OFF -> the package
# is kept. Before this mapping every pattern below was removed on every build, so a user
# could not keep any of these features.
$packagePatterns = @()

# Map: option key -> package patterns. The map lives in config\schema.psd1 (Targets), so
# the schema is the single source of truth for what an option removes.
$packageOptionMap = [ordered]@{}
foreach ($targetKey in @($script:WinEaseSettingsDef.Targets.Keys)) {
    $packageOptionMap[$targetKey] = @($script:WinEaseSettingsDef.Targets[$targetKey].FoDPackages)
}

foreach ($optKey in $packageOptionMap.Keys) {
    # The option itself, or an Advanced Debloat target that implies it (the Option field of
    # config\schema.psd1 -> DebloatEngines). The target selection is the second way to ask
    # for the same work, not a second implementation of it.
    $optionOn = (Test-TweakEnabled $optKey $false)
    if (-not $optionOn -and (Get-Command -Name Test-WinEaseDebloatOptionEnabled -ErrorAction SilentlyContinue)) {
        $optionOn = Test-WinEaseDebloatOptionEnabled -Option $optKey
    }
    if ($optionOn) {
        $packagePatterns += $packageOptionMap[$optKey]
    }
}

# Foreign language font packages (preserves Latin, system, and Japanese Jpan fonts).
# These are bound to the font options: keepExtraFonts keeps the extra international fonts,
# keepAsianIME keeps the Asian IME related packages.
if (-not $keepExtraFonts) {
    $packagePatterns += @(
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
    "Microsoft-Windows-LanguageFeatures-Fonts-Arab-Package~"
    )
}

# Foreign Speech / Text-to-Speech / Handwriting / OCR packages for non-target languages.
# These are bound to the Asian-IME option: with keepAsianIME the foreign language IME and
# language-feature packages are kept, otherwise they are removed.
if (-not $keepAsianIME) {
    $packagePatterns += @(
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
}

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

# Plugin contributions (IFodRemovalContributor). Packages join the pattern list, so the
# preservation filters below apply to them; capabilities and features are removed after the
# package pass (see the end of this phase).
$pluginFodRemovals = @()
if (Get-Command -Name Get-WinEasePluginContributions -ErrorAction SilentlyContinue) {
    $pluginFodRemovals = @(Get-WinEasePluginContributions -Kind Fod)
    foreach ($pluginFod in @($pluginFodRemovals | Where-Object { $_.Kind -eq 'Package' })) {
        Write-Host "  [Plugin $($pluginFod.PluginId)] package removal pattern: $($pluginFod.Name)" -ForegroundColor DarkCyan
        $packagePatterns += $pluginFod.Name
    }
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
if ($packagePatterns.Count -gt 0) {
    $regexParts = foreach ($packagePattern in $packagePatterns) {
        $pattern = if ($packagePattern.EndsWith("*")) { $packagePattern } else { "$packagePattern*" }
        "^" + [regex]::Escape($pattern).Replace("\*", ".*").Replace("\?", ".")
    }
    $combinedRegex = [regex]::new(($regexParts -join "|"), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($pkg in $allPackages) {
        if ($combinedRegex.IsMatch($pkg)) {
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
}

foreach ($packageIdentity in $packagesToRemove) {
    Write-Host "  - Removing package: $packageIdentity"
    & dism.exe /English "/image:$scratchDir" /Remove-Package "/PackageName:$packageIdentity" > $null 2>&1
}

# The Advanced Debloat targets this phase owns (config\schema.psd1 -> DebloatEngines):
# the optional features and the installed capabilities that the FoD packages belong to.
# They are removed here, so phase 09 does not remove them a second time.
if (Get-Command -Name Invoke-WinEaseDebloatTargets -ErrorAction SilentlyContinue) {
    Invoke-WinEaseDebloatTargets -Phase '06-fod'
}

# Plugin contributions: capabilities and optional features
foreach ($pluginFod in @($pluginFodRemovals | Where-Object { $_.Kind -ne 'Package' })) {
    Write-Host "  - Removing $($pluginFod.Kind) '$($pluginFod.Name)' (plugin $($pluginFod.PluginId))"
    if ($isDryRunMode) {
        Write-Host "    [DRY] Would remove the $($pluginFod.Kind) '$($pluginFod.Name)'" -ForegroundColor Yellow
        continue
    }
    if ($pluginFod.Kind -eq 'Capability') {
        & dism.exe /English "/image:$scratchDir" /Remove-Capability "/CapabilityName:$($pluginFod.Name)" > $null 2>&1
    } else {
        & dism.exe /English "/image:$scratchDir" /Disable-Feature "/FeatureName:$($pluginFod.Name)" /Remove > $null 2>&1
    }
}

# M2: User extension actions (FOD)
if (Get-Command -Name Invoke-WinEaseUserExtensionActions -ErrorAction SilentlyContinue) {
    try { Invoke-WinEaseUserExtensionActions -PhaseType FOD -ScratchDir $scratchDir -DryRun:$DryRun | Out-Null } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

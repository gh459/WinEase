# Phase 3: 03-staging
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


Write-Host "Copying Windows installation files to $WinEaseDir..." -ForegroundColor Green
$sourcePath = $DriveLetter.TrimEnd('\') + "\"
$copySuccess = $false
# If converting from install.esd, exclude both install.esd and install.wim from initial robocopy
# so we don't spend unnecessary minutes duplicating multi-gigabyte source archives.
$robocopyArgs = @("$sourcePath", "$WinEaseDir", "/E", "/XJ", "/MT:16", "/J", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
if (-not $hasSourceWim -and $hasSourceEsd) {
    $robocopyArgs += @("/XF", "install.esd", "install.wim")
} elseif (-not $hasSourceWim) {
    $robocopyArgs += @("/XF", "install.esd")
}
try {
    & robocopy.exe @robocopyArgs > $null 2>&1
    if ($LASTEXITCODE -lt 8) {
        $copySuccess = $true
    }
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

if (-not $copySuccess) {
    Write-Host "Robocopy completed or unavailable, ensuring files via Copy-Item..." -ForegroundColor Yellow
    Copy-Item -Path "$sourcePath*" -Destination $WinEaseDir -Recurse -Force | Out-Null
}

# Ensure install.wim exists in destination; if not copied by robocopy, copy directly or decompress from install.esd
if (-not (Test-Path -LiteralPath $destWim) -or ((Get-Item -LiteralPath $destWim).Length -lt 1GB)) {
    if (Test-Path -LiteralPath $sourceWim) {
        Write-Host "Copying install.wim directly from $sourceWim..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $sourceWim -Destination $destWim -Force
    } elseif (Test-Path -LiteralPath $sourceEsd) {
        Write-Host "Detected install.esd format (MediaCreationTool ISO). Converting to install.wim..." -ForegroundColor Cyan
        Write-Host "Decompressing LZMS stream to LZX maximum compression via DISM. Please wait..." -ForegroundColor Cyan

        $esdInfoOutput = & dism.exe /English /Get-WimInfo "/WimFile:$sourceEsd"
        $esdIndexEntries = @()
        $curEsdEntry = $null
        foreach ($line in ($esdInfoOutput -split '\r?\n')) {
            if ($line -match '^\s*Index\s*:\s*(\d+)') {
                $curEsdEntry = [PSCustomObject]@{ Index = $matches[1]; Name = "" }
                $esdIndexEntries += $curEsdEntry
            } elseif ($curEsdEntry -and ($line -match '^\s*Name\s*:\s*(.+)')) {
                $curEsdEntry.Name = $matches[1].Trim()
            }
        }
        $availEsdIndices = @($esdIndexEntries | ForEach-Object { $_.Index })
        $proEsd = $esdIndexEntries | Where-Object { $_.Name -match 'Pro' -and $_.Name -notmatch 'Workstation' } | Select-Object -First 1
        $defaultEsdIndex = if ($proEsd) { $proEsd.Index } elseif ($availEsdIndices.Count -gt 0) { $availEsdIndices[0] } else { "1" }

        $chosenEsdIndex = $defaultEsdIndex
        if ([string]::IsNullOrWhiteSpace($index) -or ($index -notin $availEsdIndices)) {
            if (-not $NonInteractive) {
                Write-Host "Available Windows editions in install.esd:" -ForegroundColor Green
                foreach ($entry in $esdIndexEntries) {
                    Write-Host "  [$($entry.Index)] $($entry.Name)"
                }
                $userChoice = Read-Host "Select edition index to decompress into install.wim [Default: $defaultEsdIndex]"
                if (-not [string]::IsNullOrWhiteSpace($userChoice) -and ($userChoice.Trim() -in $availEsdIndices)) {
                    $chosenEsdIndex = $userChoice.Trim()
                }
            }
        } else {
            $chosenEsdIndex = $index
        }

        Write-Host "Decompressing and exporting Index $chosenEsdIndex from install.esd to $destWim..." -ForegroundColor Cyan
        & dism.exe /English /Export-Image "/SourceImageFile:$sourceEsd" "/SourceIndex:$chosenEsdIndex" "/DestinationImageFile:$destWim" /Compress:max
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $destWim) -or ((Get-Item -LiteralPath $destWim).Length -lt 1GB)) {
            # throw (not exit) so the main finally block performs cleanup and stops the transcript exactly once
            throw "DISM failed to convert install.esd to install.wim (Exit code: $LASTEXITCODE)."
        }
        Write-Host "Decompression complete! install.wim created successfully ($([math]::Round((Get-Item -LiteralPath $destWim).Length / 1GB, 2)) GB)." -ForegroundColor Green
        $index = "1"
    } else {
        Write-Host ""
        Write-Host "=========================================================" -ForegroundColor Red
        Write-Host " ERROR: Neither 'install.wim' nor 'install.esd' was found on $DriveLetter!" -ForegroundColor Red
        Write-Host " Please mount a valid Windows 11 installation ISO." -ForegroundColor Yellow
        Write-Host "=========================================================" -ForegroundColor Red
        throw "Neither install.wim nor install.esd was found on $DriveLetter."
    }
}

# Explicitly ensure critical boot files exist in target image
$criticalBootFiles = @(
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "boot\etfsboot.com"); Dest = (Join-Path -Path $WinEaseDir -ChildPath "boot\etfsboot.com"); Dir = (Join-Path -Path $WinEaseDir -ChildPath "boot") },
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "efi\microsoft\boot\efisys.bin"); Dest = (Join-Path -Path $WinEaseDir -ChildPath "efi\microsoft\boot\efisys.bin"); Dir = (Join-Path -Path $WinEaseDir -ChildPath "efi\microsoft\boot") },
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "efi\microsoft\boot\efisys_noprompt.bin"); Dest = (Join-Path -Path $WinEaseDir -ChildPath "efi\microsoft\boot\efisys_noprompt.bin"); Dir = (Join-Path -Path $WinEaseDir -ChildPath "efi\microsoft\boot") },
    @{ Src = (Join-Path -Path $sourcePath -ChildPath "sources\boot.wim"); Dest = (Join-Path -Path $WinEaseDir -ChildPath "sources\boot.wim"); Dir = (Join-Path -Path $WinEaseDir -ChildPath "sources") }
)
foreach ($cbf in $criticalBootFiles) {
    if ((Test-Path -LiteralPath $cbf.Src) -and (-not (Test-Path -LiteralPath $cbf.Dest))) {
        New-Item -ItemType Directory -Force -Path $cbf.Dir -ErrorAction SilentlyContinue | Out-Null
        Copy-Item -LiteralPath $cbf.Src -Destination $cbf.Dest -Force -ErrorAction SilentlyContinue
    }
}

# Configure sources\ei.cfg for universal edition selection without forcing product key prompt
if (-not $SkipEiCfg) {
    $eiCfgPath = Join-Path -Path "$WinEaseDir\sources" -ChildPath "ei.cfg"
    if (-not (Test-Path -LiteralPath $eiCfgPath)) {
        "[Channel]`r`n_Default`r`n[VL]`r`n0`r`n" | Set-Content -LiteralPath $eiCfgPath -Encoding ascii -Force
        Write-Host "Created sources\ei.cfg for universal edition selection." -ForegroundColor Green
    }
    # sources\PID.txt (Pro generic key) is written after index selection, only when the target edition is Pro
}

# Note: On Windows 11 24H2/25H2 (Build 26100+), zeroing appraiserres.dll causes SetupPlatform
# to fail with error 0x8007000D - 0x4002C (ERROR_INVALID_DATA).
# Hardware checks are fully bypassed via LabConfig in boot.wim and autounattend.xml.


# Remove ESD from copy if it exists to avoid duplication
if (Test-Path -LiteralPath "$WinEaseDir\sources\install.esd") {
    Remove-Item -LiteralPath "$WinEaseDir\sources\install.esd" -Force -ErrorAction SilentlyContinue
}

# Image Information and Index Selection
Write-Host "Getting Windows image information:" -ForegroundColor Cyan
$wimInfoOutput = & dism.exe /English /Get-WimInfo "/WimFile:$destWim"
$wimInfoOutput | ForEach-Object { Write-Host $_ }

# Parse available indices and detect Pro edition
$indexEntries = @()
$currentIndex = $null
foreach ($line in ($wimInfoOutput -split '\r?\n')) {
    if ($line -match '^\s*Index\s*:\s*(\d+)') {
        $currentIndex = [PSCustomObject]@{ Index = $matches[1]; Name = "" }
        $indexEntries += $currentIndex
    } elseif ($currentIndex -and ($line -match '^\s*Name\s*:\s*(.+)')) {
        $currentIndex.Name = $matches[1].Trim()
    }
}
$availableIndices = @($indexEntries | ForEach-Object { $_.Index })
$proEntry = $indexEntries | Where-Object { $_.Name -match 'Pro' -and $_.Name -notmatch 'Workstation' } | Select-Object -First 1
$defaultIndex = if ($proEntry) { $proEntry.Index } elseif ($availableIndices.Count -gt 0) { $availableIndices[0] } else { "1" }

if ([string]::IsNullOrWhiteSpace($index) -or ($index -notin $availableIndices)) {
    if (-not $NonInteractive) {
        $promptRange = if ($availableIndices.Count -gt 1) { " ($($availableIndices -join ', '))" } else { "" }
        $defaultLabel = if ($proEntry) { "$defaultIndex ($($proEntry.Name))" } else { $defaultIndex }
        $userInput = Read-Host "Please enter the image index to modify$promptRange [Default: $defaultLabel]"
        if (-not [string]::IsNullOrWhiteSpace($userInput) -and ($userInput.Trim() -in $availableIndices)) {
            $index = $userInput.Trim()
        } else {
            $index = $defaultIndex
        }
    } else {
        $index = $defaultIndex
    }
}
Write-Host "Selected image index: $index" -ForegroundColor Green
$targetEditionEntry = $indexEntries | Where-Object { $_.Index -eq $index } | Select-Object -First 1
$targetEditionName = if ($targetEditionEntry) { $targetEditionEntry.Name } else { "" }
if ($targetEditionName) {
    Write-Host "Target edition name: $targetEditionName" -ForegroundColor Cyan
}

# sources\PID.txt: the Pro generic key only matches a Pro image. The exported install.wim contains
# just the selected edition, so a Pro key with e.g. a Home image makes Windows Setup fail.
$pidTxtPath = Join-Path -Path "$WinEaseDir\sources" -ChildPath "PID.txt"
$isProEdition = ($targetEditionName -match '\bPro\b') -and ($targetEditionName -notmatch 'Workstation|Education|\bN\b')
if ((-not $SkipEiCfg) -and $isProEdition) {
    if (-not (Test-Path -LiteralPath $pidTxtPath)) {
        "[PID]`r`nValue=VK7JG-NPHTM-C97JM-9MPGT-3V66T`r`n" | Set-Content -LiteralPath $pidTxtPath -Encoding ascii -Force
        Write-Host "Created sources\PID.txt with Windows 11 Pro generic key for seamless deployment." -ForegroundColor Green
    }
} elseif (Test-Path -LiteralPath $pidTxtPath) {
    Remove-Item -LiteralPath $pidTxtPath -Force -ErrorAction SilentlyContinue
    Write-Host "Removed sources\PID.txt (selected edition '$targetEditionName' is not Pro)." -ForegroundColor Yellow
}

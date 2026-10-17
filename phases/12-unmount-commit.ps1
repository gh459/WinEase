# Phase 12: 12-unmount-commit
# Extracted from nano11builder.ps1
# Dot-sourced by the main orchestrator


# 12. Unmount and export install image
Write-Host "Unmounting install image and committing changes..." -ForegroundColor Green
Write-Host "  -> Saving WIM image changes to disk. This typically takes 2-5 minutes depending on SSD/HDD speed." -ForegroundColor Cyan
Write-Host "  -> [Notice] DISM progress will update below. Please DO NOT close this window - commit is actively running." -ForegroundColor Yellow

# Ensure working directory is safely outside mount path and release lingering handles
Set-Location -LiteralPath $scriptDir
[GC]::Collect()
[GC]::WaitForPendingFinalizers()

$unmountSuccess = $false
for ($retry = 1; $retry -le 4; $retry++) {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Set-Location -LiteralPath $scriptDir
    Start-Sleep -Seconds 2

    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
    if ($LASTEXITCODE -eq 0) {
        $unmountSuccess = $true
        $script:MountOpened = $false
        break
    }

    Write-Host "Warning: commit unmount failed (attempt $retry/4). Retrying after waiting and garbage collection..." -ForegroundColor Yellow
    Set-Location -LiteralPath $scriptDir
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds (3 * $retry)
}

if (-not $unmountSuccess) {
    Write-Host "Error: Failed to commit changes to mounted image after 4 attempts." -ForegroundColor Red
    Write-Host "Checking if image is in 'Needs Remount' state or locked by external processes..." -ForegroundColor Yellow
    & dism.exe /English /Remount-Image "/MountDir:$scratchDir" > $null 2>&1
    & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /commit
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Critical: Unable to commit changes. Discarding mount to prevent corrupted image..." -ForegroundColor Red
        & dism.exe /English /Unmount-Image "/MountDir:$scratchDir" /discard > $null 2>&1
        $script:MountOpened = $false
        throw "Failed to commit modifications to install image. Build aborted to prevent producing a corrupted ISO."
    } else {
        $script:MountOpened = $false
    }
}

# Phase 16: 16-iso-cleanup
# Extracted from nano11builder.ps1
# Dot-sourced by the main orchestrator


# 16. Final cleanup of ISO root and sources
Write-Host "Performing final cleanup of ISO root..." -ForegroundColor Cyan
$keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "bootmgfw.efi", "setup.exe", "autounattend.xml", "nano11-build-info.json")
Get-ChildItem -Path $nano11Dir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# Clean leftover build diagnostics and setup logs inside sources
$sourcesDir = Join-Path -Path $nano11Dir -ChildPath "sources"
if (Test-Path -LiteralPath $sourcesDir) {
    Remove-Item -Path "$sourcesDir\setupcore.log" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$sourcesDir\*.diagerr" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$sourcesDir\*.diagxml" -Force -ErrorAction SilentlyContinue
    # Remove any broken or empty OEM folders that cause 0x80070002 during Setup file expansion
    $brokenOem = Join-Path -Path $sourcesDir -ChildPath "`$OEM`$"
    if ((Test-Path -LiteralPath $brokenOem) -and ((Get-ChildItem -Path $brokenOem -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0)) {
        Remove-Item -LiteralPath $brokenOem -Recurse -Force -ErrorAction SilentlyContinue
    }

    # UltraSlim ISO payload trim (④ size levers): media files that serve upgrade/repair scenarios
    # are not consumed by the zero-click clean-install flow staged in boot.wim.
    # - sources\sxs\        : NET Framework 3.5 FOD cabs (offline DISM /Add-Package source only)
    # - sources\langpacks\  : standalone language pack cabs (target language is already embedded)
    # - sources\sflist*.dat : upgrade migration inventory lists (clean install never uses them)
    if ($ultraSlimMode) {
        Write-Host "  [UltraSlim] Trimming clean-install-irrelevant media payloads (sources\sxs, sflist*.dat)..." -ForegroundColor Cyan
        Remove-Item -LiteralPath "$sourcesDir\sxs" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$sourcesDir\langpacks" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$sourcesDir\sflist*.dat" -Force -ErrorAction SilentlyContinue
    }

    # Verify no temporary or backup files remain in ISO sources tree
    $suspiciousFiles = Get-ChildItem -Path $sourcesDir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "*backup*" -or $_.Name -like "*temp*" -or $_.Name -like "*export*"
    }
    if ($suspiciousFiles) {
        $badNames = ($suspiciousFiles | ForEach-Object { $_.Name }) -join ", "
        throw "Verification failed: Temporary or backup files remain in ISO sources tree: $badNames"
    }
}

# Phase 16: 16-iso-cleanup
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


# 16. Final cleanup of ISO root and sources
Write-Host "Performing final cleanup of ISO root..." -ForegroundColor Cyan
# Every removal here shrinks the ISO, so a failure is reported: a file that is still in
# the ISO means the size win did not happen.
$cleanupFailures = @()
$keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "bootmgfw.efi", "setup.exe", "autounattend.xml", "WinEase-build-info.json")
Get-ChildItem -Path $WinEaseDir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
    $err = Remove-WinEaseRequiredPath -Path $_.FullName -Label "ISO root $($_.Name)"
    if ($err) { $cleanupFailures += $err }
}

# Clean leftover build diagnostics and setup logs inside sources
$sourcesDir = Join-Path -Path $WinEaseDir -ChildPath "sources"
if (Test-Path -LiteralPath $sourcesDir) {
    $err = Remove-WinEaseRequiredPath -Path (Join-Path -Path $sourcesDir -ChildPath 'setupcore.log') -Label 'sources\setupcore.log'
    if ($err) { $cleanupFailures += $err }
    $err = Remove-WinEaseRequiredPath -Path $sourcesDir -Label 'sources\*.diagerr' -ContentsOnly -Filter '*.diagerr'
    if ($err) { $cleanupFailures += $err }
    $err = Remove-WinEaseRequiredPath -Path $sourcesDir -Label 'sources\*.diagxml' -ContentsOnly -Filter '*.diagxml'
    if ($err) { $cleanupFailures += $err }
    # Remove any broken or empty OEM folders that cause 0x80070002 during Setup file expansion
    $brokenOem = Join-Path -Path $sourcesDir -ChildPath "`$OEM`$"
    if ((Test-Path -LiteralPath $brokenOem) -and ((Get-ChildItem -Path $brokenOem -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0)) {
        $err = Remove-WinEaseRequiredPath -Path $brokenOem -Label 'sources\$OEM$'
        if ($err) { $cleanupFailures += $err }
    }

    # UltraSlim ISO payload trim (4 size levers): media files that serve upgrade/repair scenarios
    # are not consumed by the zero-click clean-install flow staged in boot.wim.
    # - sources\sxs\        : NET Framework 3.5 FOD cabs (offline DISM /Add-Package source only)
    # - sources\langpacks\  : standalone language pack cabs (target language is already embedded)
    # - sources\sflist*.dat : upgrade migration inventory lists (clean install never uses them)
    if ($ultraSlimMode) {
        Write-Host "  [UltraSlim] Trimming clean-install-irrelevant media payloads (sources\sxs, sflist*.dat)..." -ForegroundColor Cyan
        $err = Remove-WinEaseRequiredPath -Path (Join-Path -Path $sourcesDir -ChildPath 'sxs') -Label 'sources\sxs'
        if ($err) { $cleanupFailures += $err }
        $err = Remove-WinEaseRequiredPath -Path (Join-Path -Path $sourcesDir -ChildPath 'langpacks') -Label 'sources\langpacks'
        if ($err) { $cleanupFailures += $err }
        $err = Remove-WinEaseRequiredPath -Path $sourcesDir -Label 'sources\sflist*.dat' -ContentsOnly -Filter 'sflist*.dat'
        if ($err) { $cleanupFailures += $err }
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

if ($cleanupFailures.Count -gt 0) {
    Write-Warning "  - $($cleanupFailures.Count) cleanup removal(s) of the ISO failed:"
    foreach ($failure in $cleanupFailures) { Write-Warning "      $failure" }
    if (Get-Variable -Name 'DiagnosticData' -Scope Script -ErrorAction SilentlyContinue) {
        $script:DiagnosticData.IsoCleanupFailures = @($cleanupFailures)
    }
}
# Phase 9: 09-winsxs
# Extracted from WinEasebuilder.ps1
# Dot-sourced by the main orchestrator


# 9. Component Store (WinSxS) Optimization
# CRITICAL SAFETY RULE (Windows Internals & 24H2 Checkpoint LCU Architecture):
# 1. Manual folder copying of WinSxS via Copy-Item resolves NTFS hardlinks into duplicate physical files,
#    which dramatically inflates disk usage, severs link references to System32, and invalidates SFC / LCU servicing.
# 2. Offline /StartComponentCleanup and /ResetBase on Windows 11 Build 26100+ (24H2/25H2 Germanium)
#    corrupt TurboStack/CBS trees (Error 1392 / 0x80070570 in SortWindows61.nls stream) and permanently break Checkpoint LCU updates (0x800f081f).
# 3. Component store compression is safely and natively achieved without corrupting hardlinks during Phase 13 Export-Image (/Compress:max).

$targetImageBuild = 0
$ntoskrnlPath = Join-Path -Path $scratchDir -ChildPath "Windows\System32\ntoskrnl.exe"
if (Test-Path -LiteralPath $ntoskrnlPath) {
    try {
        $targetImageBuild = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ntoskrnlPath).ProductBuildPart
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
}

# The Advanced Debloat target "WinSxS cleanup (/StartComponentCleanup /ResetBase)" asks for
# the aggressive variant: it also resets the base, which the safe mode never does.
$winSxSAggressive = $false
if (Get-Command -Name Test-WinEaseDebloatTarget -ErrorAction SilentlyContinue) {
    $winSxSAggressive = Test-WinEaseDebloatTarget -Item 'WinSxS cleanup (/StartComponentCleanup /ResetBase) [1-3GB]'
}

if ($safeDebloatMode -and -not $winSxSAggressive) {
    Write-Host "Preserving component store integrity for 100% reliable Windows Setup deployment..." -ForegroundColor Green
    Write-Host "  -> Skipping unstable offline StartComponentCleanup (prevents 0x80070570 stream corruption at 77%)." -ForegroundColor Cyan
    Write-Host "  -> Disk space optimization is safely handled via Phase 13 Export-Image (/Compress:max)." -ForegroundColor Green
} else {
    Write-Host "Component Store Cleanup requested (-SafeDebloatMode:`$false)..." -ForegroundColor Yellow
    if ($targetImageBuild -ge 26100 -and -not $ForceWinSxSCleanup) {
        Write-Warning "Windows 11 Build $targetImageBuild (24H2+ Germanium) detected!"
        Write-Warning "Offline /ResetBase and manual WinSxS pruning are blocked to protect Checkpoint Cumulative Updates (LCU) and prevent TurboStack corruption (0x80070570)."
        Write-Host "  -> Safely deferring component compression to Phase 13 Export-Image (/Compress:max)." -ForegroundColor Green
        Write-Host "  -> Pass -ForceWinSxSCleanup to override (experimental, opt-in; deep-apply verification runs as safety net)." -ForegroundColor DarkYellow
    } else {
        if ($targetImageBuild -ge 26100) {
            Write-Warning "FORCE MODE (-ForceWinSxSCleanup): running offline StartComponentCleanup on 26100+ (checkpoint LCU corruption risk). Deep-apply verification + hash checks follow as safety net."
        }
        Write-Host "Executing DISM native Component Store Cleanup (preserving NTFS hardlinks, no manual file deletions)..." -ForegroundColor Cyan
        & dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  - Component Store cleanup succeeded." -ForegroundColor Green
        } else {
            Write-Warning "  - Component Store cleanup exited with code $LASTEXITCODE (non-fatal, continuing)."
        }
        if ($ForceWinSxSCleanup -or $winSxSAggressive) {
            Write-Host "Attempting /StartComponentCleanup /ResetBase (aggressive mode)..." -ForegroundColor Cyan
            & dism.exe /English "/image:$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  - ResetBase succeeded." -ForegroundColor Green
            } else {
                Write-Warning "  - ResetBase exited with code $LASTEXITCODE (non-fatal). Component cleanup above already applied."
            }
        }
    }
}

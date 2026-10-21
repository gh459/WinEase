# Phase 09b: Physical Debloat (Experimental)
# Rust-based physical deletion of protected Windows components with strict safety guards
# Dot-sourced by the main orchestrator

Write-Host "Configuring physical debloat (experimental)..." -ForegroundColor Cyan

# Resolve paths
$rustBinary = Join-Path -Path $scriptDir -ChildPath "tools\winease-physical-debloat\target\release\winease-physical-debloat.exe"
if (-not (Test-Path -LiteralPath $rustBinary)) {
    $rustBinary = Join-Path -Path $scriptDir -ChildPath "tools\winease-physical-debloat\target\debug\winease-physical-debloat.exe"
}

$hasStandardItems = $script:advancedDebloatStandard -and $script:advancedDebloatStandard.Count -gt 0
$hasExperimentalItems = $script:advancedDebloatExperimental -and $script:advancedDebloatExperimental.Count -gt 0

if (-not $hasStandardItems -and -not $hasExperimentalItems) {
    Write-Host "  [Physical Debloat] No items selected. Skipping." -ForegroundColor DarkGray
    return
}

# Every selected target, in list order and without duplicates. The engine binding decides
# which engine handles a target, so both lists are handled by the same dispatch.
$allSelectedItems = @(
    if ($hasStandardItems) { $script:advancedDebloatStandard }
    if ($hasExperimentalItems) { $script:advancedDebloatExperimental }
)
$allSelectedItems = @($allSelectedItems | Select-Object -Unique)

# --- Execution engine selection (PowerShell <-> Rust) ---------------------------------
# The engine of every target, the target selection and the safe per-target handlers live
# in lib\WinEaseDebloat.ps1 (loaded by the builder) and in config\schema.psd1
# (DebloatEngines). This phase is the Rust engine only: it dispatches the targets whose
# engine is "Rust" to the Rust binary. The safe work of a target is executed by the phase
# that owns it (the Phase field of the table), so one work item has exactly one
# implementation and is never executed twice.
#
# Invariants (enforced here, not only in the UI):
#   * a target that is not selected never runs, whatever engine it carries
#   * a target whose engine is "PowerShell" is never handed to the Rust binary
#   * a target whose engine is "Rust" is handed to the Rust binary and only that one key
#     is dispatched to it
#   * the Rust engine additionally requires the -AllowPhysicalDebloat safety gate

# --- E1 SAFETY GATE: physical deletion is strictly opt-in -----------------------------------
# Selections coming from a JSON profile or the GUI do NOT authorize destructive physical
# deletion by themselves. Without -AllowPhysicalDebloat (CLI) or the GUI consent dialog the
# experimental deletions are skipped with an explicit notice.
$physGateAllowed = $false
if (Get-Variable -Name 'allowPhysicalDebloat' -Scope Script -ErrorAction SilentlyContinue) { $physGateAllowed = [bool]$script:allowPhysicalDebloat }

# --- E1 SAFETY VALIDATION: verify the mount directory before any destructive operation ------
# Rejects empty paths, drive roots, non-existent directories, trees without the offline-image
# marker, and mounts outside the workspace/mount roots.
$physMountError = $null
if ([string]::IsNullOrWhiteSpace("$scratchDir")) {
    $physMountError = "scratchDir is empty"
} else {
    try {
        $physMountFull = [System.IO.Path]::GetFullPath("$scratchDir").TrimEnd('\')
        $physDriveRoot = [System.IO.Path]::GetPathRoot($physMountFull)
        if ($physDriveRoot -and ($physMountFull -ieq $physDriveRoot.TrimEnd('\'))) {
            $physMountError = "scratchDir is a drive root ($physMountFull)"
        } elseif (-not (Test-Path -LiteralPath $physMountFull -PathType Container)) {
            $physMountError = "scratchDir is not an existing directory ($physMountFull)"
        } elseif (-not (Test-Path -LiteralPath (Join-Path -Path $physMountFull -ChildPath 'Windows\System32\config\SYSTEM'))) {
            $physMountError = "Windows\System32\config\SYSTEM marker not found - not a mounted Windows image ($physMountFull)"
        } else {
            $physWorkspaceRoots = @()
            if ($script:BaseWorkDir) { $physWorkspaceRoots += "$($script:BaseWorkDir)" }
            if ($script:MountAllocationRoot) { $physWorkspaceRoots += "$($script:MountAllocationRoot)" }
            if ($baseWorkDir) { $physWorkspaceRoots += "$baseWorkDir" }
            if ($physWorkspaceRoots.Count -gt 0 -and (Get-Command -Name 'Test-WinEasePathWithin' -ErrorAction SilentlyContinue)) {
                $physInside = $false
                foreach ($physRoot in $physWorkspaceRoots) {
                    if (Test-WinEasePathWithin -Path $physMountFull -Root $physRoot) { $physInside = $true; break }
                }
                if (-not $physInside) {
                    $physMountError = "scratchDir is outside the workspace/mount roots ($($physWorkspaceRoots -join ', '))"
                }
            }
        }
    } catch {
        $physMountError = "mount path validation failed: $($_.Exception.Message)"
    }
}
if ($physMountError) {
    Write-Host "  [Physical Debloat] BLOCKED: mount directory failed the safety validation." -ForegroundColor Red
    Write-Host "    Reason: $physMountError" -ForegroundColor Red
    Write-Host "    No deletion was attempted." -ForegroundColor Yellow
    return
}

# --- E2 SAFETY: the component store is never touched by the Rust engine ---------------
# The offline /ResetBase protection for 24H2+ (checkpoint LCU corruption) belongs to the
# component store cleanup, which phase 09-winsxs.ps1 runs. The Rust engine only deletes
# the files of the selected targets, so it does not need the build number here.

# --- DISM helpers for Standard items (servicing-stack removal, no raw file deletion) ---
# The safe (PowerShell) engine is not executed here. Every target declares the phase that
# owns it (config\schema.psd1 -> DebloatEngines -> Phase) and that phase runs it through
# Invoke-WinEaseDebloatTargets. Running the safe work here as well was the reason a target
# could be removed twice - once by its own option and once by this phase.

# A target can be selected in either list. The engine binding decides where it runs, so
# the Rust dispatch collects from both lists and skips the targets the PowerShell engine
# already handled.
# The Rust dispatch collects the selected targets whose engine is "Rust" from both lists.
$rustTargetItems = @($allSelectedItems | Where-Object { (Resolve-WinEaseDebloatEngine -Item $_) -eq 'Rust' })

# --- Process the targets with the Rust engine ---
if ($rustTargetItems.Count -gt 0) {
    if (-not $physGateAllowed) {
        $reqExpCount = $rustTargetItems.Count
        Write-Host ""
        Write-Host "  [Physical Debloat] BLOCKED: -AllowPhysicalDebloat was not specified." -ForegroundColor Yellow
        Write-Host "  [Physical Debloat] $reqExpCount experimental items were NOT executed (experimental physical deletion is strictly opt-in)." -ForegroundColor Yellow
        Write-Host "  [Physical Debloat] Re-run with -AllowPhysicalDebloat to authorize physical deletion (test environments only)." -ForegroundColor DarkYellow
        Write-Host ""
        return
    }

    if (-not (Test-Path -LiteralPath $rustBinary)) {
        Write-Host "  [Physical Debloat] BLOCKED: Rust binary not found at $rustBinary" -ForegroundColor Red
        Write-Host "  [Physical Debloat] Experimental items skipped to avoid unsafe unverified deletion." -ForegroundColor Yellow
        return
    }

    Write-Host "  [Physical Debloat] Rust binary verified: $rustBinary" -ForegroundColor Green

    $experimentalMap = @{}
    foreach ($item in $rustTargetItems) {
        # Engine gate: only the targets that run on the Rust engine are dispatched to the
        # binary, and only their own key is dispatched. The PowerShell engine handled the
        # other targets in the standard loop.
        if (-not ((Resolve-WinEaseDebloatEngine -Item $item) -eq 'Rust')) {
            Write-Host "  [Experimental] Skipping (engine is not Rust): $item" -ForegroundColor DarkGray
            continue
        }
        # The key comes from config\schema.psd1 (DebloatEngines -> RustKey); the regex list
        # inside Get-WinEaseDebloatRustKey is only the fallback for unregistered entries.
        $key = Get-WinEaseDebloatRustKey -Item $item
        if ($key) { $experimentalMap[$key] = $true }
    }

    $resultLogName = if ($isDryRunMode) { "physical-debloat-dryrun.json" } else { "physical-debloat-result.json" }
    $resultLogPath = Join-Path -Path $logDir -ChildPath $resultLogName

    $configObj = [ordered]@{
        dry_run      = [bool]$isDryRunMode
        mount_path   = "$scratchDir"
        log_path     = $resultLogPath
        experimental = $experimentalMap
        # The primary input method language of the image: the Rust engine keeps the
        # input method engine and the fonts of that language.
        primary_ime_lang = "$script:primaryImeLang"
    }

    $configPath = Join-Path -Path $logDir -ChildPath "experimental-debloat.json"
    $configJson = $configObj | ConvertTo-Json -Depth 3

    if (Get-Command -Name 'Write-WinEaseTextFileAtomic' -ErrorAction SilentlyContinue) {
        Write-WinEaseTextFileAtomic -Path $configPath -Content $configJson | Out-Null
    } else {
        [System.IO.File]::WriteAllText($configPath, $configJson, [System.Text.Encoding]::UTF8)
    }
    Write-Host "  [Physical Debloat] Config written: $configPath" -ForegroundColor Green
    Write-Host "  [Physical Debloat] Experimental items: $($experimentalMap.Count)" -ForegroundColor Gray

    if ($isDryRunMode) {
        Write-Host "  [Physical Debloat] DRY RUN MODE: listing targets without deleting" -ForegroundColor Yellow
        $rustArgs = @("--config", $configPath, "--dry-run", "--log-path", $resultLogPath)
    } else {
        $rustArgs = @("--config", $configPath, "--confirm-offline-image", "--log-path", $resultLogPath)
    }

    # Execute Rust binary
    Write-Host "  [Physical Debloat] Executing: $rustBinary $($rustArgs -join ' ')" -ForegroundColor Cyan
    $proc = Start-Process -FilePath $rustBinary -ArgumentList $rustArgs -PassThru -Wait -NoNewWindow
    $exitCode = $proc.ExitCode

    if ($exitCode -eq 0) {
        Write-Host "  [Physical Debloat] Completed successfully (Exit code: 0)" -ForegroundColor Green
        if (Test-Path -LiteralPath $resultLogPath) {
            $result = Get-Content -LiteralPath $resultLogPath -Raw | ConvertFrom-Json
            $deletedLabel = if ($isDryRunMode) { 'Would delete' } else { 'Deleted' }
            Write-Host "  [Physical Debloat] $deletedLabel files: $($result.deleted_files), dirs: $($result.deleted_dirs), reg keys: $($result.deleted_registry_keys), errors: $($result.errors.Count)" -ForegroundColor Gray
            if ($result.errors.Count -gt 0) {
                foreach ($err in $result.errors) {
                    Write-Host "    [ERROR] $err" -ForegroundColor Red
                }
            }
        }
    } elseif ($exitCode -eq 2) {
        throw "Physical debloat aborted: one or more experimental targets were rejected by the allowlist (exit code 2)."
    } elseif ($exitCode -eq 3) {
        throw "Physical debloat aborted: mount directory failed safety validation in Rust tool (exit code 3)."
    } else {
        throw "Physical debloat failed with exit code $exitCode. Aborting build to maintain image integrity."
    }

    # Save summary to physical-debloat.log
    $physLogPath = Join-Path -Path $logDir -ChildPath "physical-debloat.log"
    $logLines = @(
        "Physical Debloat Phase - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Rust binary: $rustBinary",
        "Exit code: $exitCode",
        "DryRun: $isDryRunMode",
        "Standard items: $($script:advancedDebloatStandard.Count)",
        "Experimental items: $($script:advancedDebloatExperimental.Count)"
    )
    if (Test-Path -LiteralPath $resultLogPath) {
        $logLines += (Get-Content -LiteralPath $resultLogPath -Raw)
    }
    $logText = $logLines -join [System.Environment]::NewLine

    if (Get-Command -Name 'Write-WinEaseTextFileAtomic' -ErrorAction SilentlyContinue) {
        Write-WinEaseTextFileAtomic -Path $physLogPath -Content $logText | Out-Null
    } else {
        try { [System.IO.File]::WriteAllText($physLogPath, $logText, [System.Text.Encoding]::UTF8) } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
    }
}

Write-Host "  [Physical Debloat] Phase complete." -ForegroundColor Green

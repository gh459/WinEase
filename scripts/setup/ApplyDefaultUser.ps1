# ApplyDefaultUser.ps1 - Safely load HKU\DefaultUser, apply DefaultUser.ps1, unload hive
$markerDir = "C:\ProgramData\WinEase"
if (-not (Test-Path -LiteralPath $markerDir)) {
    New-Item -ItemType Directory -Force -Path $markerDir -ErrorAction SilentlyContinue | Out-Null
}
$logDir = "$markerDir\Logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
}
$logFile = "$logDir\defaultuser.log"

function Log-DefUser {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $Message" | Add-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath "$markerDir\defaultuser.succeeded", "$markerDir\defaultuser.failed" -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath "$markerDir\defaultuser.started" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue
Log-DefUser "ApplyDefaultUser.ps1 started."
$hiveLoaded = $false
$hasError = $false
$ntUserDat = 'C:\Users\Default\NTUSER.DAT'

try {
    if (-not (Test-Path -LiteralPath $ntUserDat)) {
        throw "NTUSER.DAT not found at $ntUserDat"
    }

    & reg.exe load HKU\DefaultUser $ntUserDat
    $loadExit = $LASTEXITCODE
    if ($loadExit -ne 0) {
        throw "reg.exe load HKU\DefaultUser failed with exit code $loadExit"
    }
    $hiveLoaded = $true
    Log-DefUser "Successfully loaded HKU\DefaultUser"

    $defUserScript = 'C:\Windows\Setup\Scripts\DefaultUser.ps1'
    if (Test-Path -LiteralPath $defUserScript) {
        Log-DefUser "Executing $defUserScript (out-of-process)..."
        & powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File $defUserScript
        $defExit = $LASTEXITCODE
        Log-DefUser "$defUserScript process finished with exit code: $defExit"
        if ($defExit -ne 0) {
            throw "$defUserScript exited with non-zero exit code: $defExit"
        }
        Log-DefUser "Execution of $defUserScript finished successfully."
    } else {
        throw "Required script $defUserScript not found."
    }

    # Post-verification: verify critical DefaultUser registry values applied before hive unload
    $runOnceVal = (Get-ItemProperty -LiteralPath 'Registry::HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'UnattendedSetup' -ErrorAction SilentlyContinue).UnattendedSetup
    if ([string]::IsNullOrWhiteSpace($runOnceVal)) {
        throw "Post-verification failed: HKU\DefaultUser RunOnce UnattendedSetup value is missing or empty!"
    }
    Log-DefUser "Post-verification passed: RunOnce UnattendedSetup registered."
} catch {
    $hasError = $true
    $err = "$($_ | Out-String)"
    Log-DefUser "ERROR in ApplyDefaultUser.ps1: $err"
    Remove-Item -LiteralPath "$markerDir\defaultuser.succeeded" -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath "$markerDir\defaultuser.failed" -Value $err -Encoding ascii -ErrorAction SilentlyContinue
} finally {
    if ($hiveLoaded) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 1

        $unloaded = $false
        for ($i = 1; $i -le 5; $i++) {
            & reg.exe unload HKU\DefaultUser
            $unloadExit = $LASTEXITCODE
            if ($unloadExit -eq 0) {
                $unloaded = $true
                Log-DefUser "Successfully unloaded HKU\DefaultUser on attempt $i."
                break
            }
            Log-DefUser "Attempt $i to unload HKU\DefaultUser returned exit code $unloadExit, retrying in 1s..."
            Start-Sleep -Seconds 1
        }
        if (-not $unloaded) {
            $hasError = $true
            Log-DefUser "ERROR: Failed to unload HKU\DefaultUser after 5 attempts."
            Set-Content -LiteralPath "$markerDir\defaultuser_unload.failed" -Value "Failed to unload HKU\DefaultUser" -Encoding ascii -ErrorAction SilentlyContinue
        } else {
            # Post-verification: verify HKU\DefaultUser is no longer accessible
            if (Test-Path -LiteralPath 'Registry::HKU\DefaultUser') {
                $hasError = $true
                Log-DefUser "ERROR: Post-verification failed: HKU\DefaultUser hive is still accessible after unload!"
                Set-Content -LiteralPath "$markerDir\defaultuser_unload.failed" -Value "Hive still mounted after unload" -Encoding ascii -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($hasError) {
    Log-DefUser "ApplyDefaultUser.ps1 completed WITH ERRORS."
    exit 1
} else {
    Set-Content -LiteralPath "$markerDir\defaultuser.succeeded" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue
    Log-DefUser "ApplyDefaultUser.ps1 completed successfully."
    exit 0
}
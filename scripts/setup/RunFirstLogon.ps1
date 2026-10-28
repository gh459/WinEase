# RunFirstLogon.ps1 - Unified FirstLogon single entry point
$markerDir = "C:\ProgramData\WinEase"
if (-not (Test-Path -LiteralPath $markerDir)) {
    New-Item -ItemType Directory -Force -Path $markerDir -ErrorAction SilentlyContinue | Out-Null
}
$logDir = "$markerDir\Logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
}
$wrapperLogFile  = "$logDir\firstlogon-wrapper.log"
$winhanceSysLog  = "$logDir\winhancements-system.log"
$flChildLog      = "$logDir\firstlogon-child.log"
$winhanceUserLog = "$logDir\winhancements-user.log"

function Write-FirstLogonLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    try {
        [System.IO.File]::AppendAllText($wrapperLogFile, "$entry`r`n", [System.Text.Encoding]::UTF8)
    } catch {
        Add-Content -LiteralPath $wrapperLogFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Invoke-ChildScriptWithLog {
    param(
        [string]$ScriptPath,
        [string]$Arguments,
        [string]$LogPath,
        [string]$Description
    )
    Write-FirstLogonLog "Starting $Description (Script: $ScriptPath, Log: $LogPath)"

    $targetLogDir = [System.IO.Path]::GetDirectoryName($LogPath)
    if (-not (Test-Path -LiteralPath $targetLogDir)) {
        New-Item -ItemType Directory -Force -Path $targetLogDir -ErrorAction Stop | Out-Null
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # Security: Escape single quotes in path and arguments to prevent command injection when interpolated into single-quoted script block
    $escapedScriptPath = $ScriptPath -replace "'", "''"
    $escapedArgPart = if ($Arguments) { " " + ($Arguments -replace "'", "''") } else { "" }
    $psi.Arguments = "-ExecutionPolicy Bypass -NoProfile -NonInteractive -Command `"[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & '$escapedScriptPath'$escapedArgPart; exit `$LASTEXITCODE`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()

    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result

    $sb = [System.Text.StringBuilder]::new()
    if (-not [string]::IsNullOrEmpty($stdoutText)) {
        [void]$sb.Append($stdoutText)
    }
    if (-not [string]::IsNullOrEmpty($stderrText)) {
        if ($sb.Length -gt 0) {
            $last = $sb[$sb.Length - 1]
            if ($last -ne [char]10) {
                [void]$sb.Append("`r`n")
            }
        }
        [void]$sb.Append("[STDERR]`r`n")
        [void]$sb.Append($stderrText)
    }

    $combined = $sb.ToString()

    if (-not [string]::IsNullOrEmpty($combined)) {
        try {
            [System.IO.File]::AppendAllText($LogPath, $combined, [System.Text.Encoding]::UTF8)
        } catch {
            Write-FirstLogonLog "ERROR: Failed to write to child log '$LogPath': $($_.Exception.Message)" "ERROR"
            Add-Content -LiteralPath $LogPath -Value $combined -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }

    $exitCode = $proc.ExitCode
    Write-FirstLogonLog "Finished $Description with exit code $exitCode"
    return $exitCode
}

Remove-Item -LiteralPath "$markerDir\firstlogon.succeeded", "$markerDir\firstlogon.failed", "$markerDir\firstlogon.done", "$markerDir\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath "$markerDir\firstlogon.started" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8 -ErrorAction SilentlyContinue

Write-FirstLogonLog "===== RunFirstLogon.ps1 execution started ====="

# User Identity and Execution Context Tracking
$currentUser = $env:USERNAME
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = if ($currentIdentity.User) { $currentIdentity.User.Value } else { "UNKNOWN" }
$currentPrincipal = [System.Security.Principal.WindowsPrincipal]$currentIdentity
$isAdmin = $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$userProfile = $env:USERPROFILE
$sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

$targetUser = $currentUser
try {
    $csUser = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($csUser -and $csUser -notlike "*NT AUTHORITY*") {
        $targetUser = $csUser.Split('\')[-1]
    }
} catch {}

$targetHivePath = "Registry::HKEY_USERS\$currentSid"
$isHiveAccessible = Test-Path -LiteralPath $targetHivePath -ErrorAction SilentlyContinue

Write-FirstLogonLog "===== Execution Context & Identity Tracking ====="
Write-FirstLogonLog "Execution UserName:    $currentUser"
Write-FirstLogonLog "Execution User SID:    $currentSid"
Write-FirstLogonLog "User Profile Path:     $userProfile"
Write-FirstLogonLog "Session ID:            $sessionId"
Write-FirstLogonLog "Is Elevated Admin:     $isAdmin"
Write-FirstLogonLog "Target Applied User:   $targetUser"
Write-FirstLogonLog "Target HKCU Hive Root: $targetHivePath (Accessible: $isHiveAccessible)"
Write-FirstLogonLog "================================="

try {
    # 1. Verify existence of required setup scripts
    $winhanceScript = 'C:\ProgramData\Winhance\Unattend\Scripts\Winhancements.ps1'
    $firstLogonScript = 'C:\Windows\Setup\Scripts\FirstLogon.ps1'

    if (-not (Test-Path -LiteralPath $winhanceScript)) {
        throw "CRITICAL ERROR: Winhancements.ps1 not found at $winhanceScript"
    }
    if (-not (Test-Path -LiteralPath $firstLogonScript)) {
        throw "CRITICAL ERROR: FirstLogon.ps1 not found at $firstLogonScript"
    }

    # Steps 2-4 always all run: FirstLogon.ps1 contains the AutoLogon teardown and WinRE cleanup,
    # so a Winhancements.ps1 failure must not skip it. Failures are collected and reported afterwards.
    $stepErrors = @()

    # 2. System optimizations: Winhancements.ps1 (System mode)
    $winExit = Invoke-ChildScriptWithLog -ScriptPath $winhanceScript -Arguments "" -LogPath $winhanceSysLog -Description "Winhancements.ps1 (System optimization mode)"
    if ($winExit -ne 0) {
        $stepErrors += "Winhancements.ps1 failed with exit code $winExit"
        Write-FirstLogonLog "Winhancements.ps1 failed with exit code $winExit - continuing with FirstLogon.ps1" "ERROR"
    }

    # 3. Finalization: FirstLogon.ps1
    $flExit = Invoke-ChildScriptWithLog -ScriptPath $firstLogonScript -Arguments "" -LogPath $flChildLog -Description "FirstLogon.ps1 (Service shutdown, tasks, desktop tools)"
    if ($flExit -ne 0) {
        $stepErrors += "FirstLogon.ps1 failed with exit code $flExit"
    }
    if (Test-Path -LiteralPath "$markerDir\firstlogon_script.failed") {
        $stepErrors += "FirstLogon.ps1 reported internal errors in $markerDir\firstlogon_script.failed"
    }

    # 4. User optimizations: Winhancements.ps1 -UserCustomizations
    $userExit = Invoke-ChildScriptWithLog -ScriptPath $winhanceScript -Arguments "-UserCustomizations" -LogPath $winhanceUserLog -Description "Winhancements.ps1 -UserCustomizations"
    if ($userExit -ne 0) {
        $stepErrors += "Winhancements.ps1 -UserCustomizations failed with exit code $userExit"
    }

    if ($stepErrors.Count -gt 0) {
        throw ($stepErrors -join "; ")
    }

    # 5. Post-verification of system and user state
    Write-FirstLogonLog "Verifying post-setup state..."
    if (-not (Test-Path -LiteralPath "$markerDir\firstlogon.done")) {
        throw "Post-verification failed: FirstLogon.ps1 did not create completion marker firstlogon.done"
    }
    if (Test-Path -LiteralPath 'C:\Windows\Setup\Scripts\remove-defender.flag') {
        $chkSvcs = @('MDCoreSvc', 'WinDefend')
        foreach ($cs in $chkSvcs) {
            $svcPath = "Registry::HKLM\SYSTEM\CurrentControlSet\Services\$cs"
            $svcKeyExists = $false
            try {
                $svcKeyExists = Test-Path -LiteralPath $svcPath -ErrorAction Stop
            } catch {
                throw "Post-verification failed: Cannot access Service $cs key ($svcPath): $($_.Exception.Message)"
            }
            if (-not $svcKeyExists) {
                Write-FirstLogonLog "Service $cs key does not exist (absent / removed) - OK"
                continue
            }
            try {
                $prop = Get-ItemProperty -LiteralPath $svcPath -Name "Start" -ErrorAction Stop
            } catch {
                throw "Post-verification failed: Access denied or query failed for Service $cs Start value: $($_.Exception.Message)"
            }
            if ($null -eq $prop -or $null -eq $prop.Start) {
                throw "Post-verification failed: Service $cs exists but Start value is missing or null"
            }
            if ($prop.Start -ne 4) {
                throw "Post-verification failed: Service $cs Start is $($prop.Start) (expected 4 / disabled)"
            }
            Write-FirstLogonLog "Service $cs Start value verified as 4 (disabled) - OK"
        }
    }
    Write-FirstLogonLog "Post-verification passed: all required state verified."

    # 6. Success marker - ONLY created when ALL steps exit 0 AND post-verification passes
    Set-Content -LiteralPath "$markerDir\firstlogon.succeeded" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8 -ErrorAction Stop
    Write-FirstLogonLog "===== RunFirstLogon.ps1 completed successfully =====" "SUCCESS"
} catch {
    $err = "$($_ | Out-String)"
    Write-FirstLogonLog "EXCEPTION in RunFirstLogon.ps1: $err" "ERROR"
    Remove-Item -LiteralPath "$markerDir\firstlogon.succeeded", "$markerDir\firstlogon.done" -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath "$markerDir\firstlogon.failed" -Value $err -Encoding UTF8 -ErrorAction SilentlyContinue
    exit 1
}

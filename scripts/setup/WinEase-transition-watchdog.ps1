# WinEase-transition-watchdog.ps1
# One-shot safety net for the first-boot OOBE -> user session transition.
# If no interactive user session appears while auto-logon is still armed, trigger exactly
# one recovery reboot so the boot-time auto-logon (proven path) can complete the transition.
$ErrorActionPreference = 'SilentlyContinue'
$markerDir = 'C:\ProgramData\WinEase'
$logDir    = "$markerDir\Logs"
$logFile   = "$logDir\transition-watchdog.log"
$guardFile = "$markerDir\watchdog.rebooted"
$taskName  = 'WinEase-TransitionWatchdog'
$winlogon  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
function Write-WLog { param([string]$m) try { Add-Content -LiteralPath $logFile -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 } catch {} }
function Remove-WatchdogTask { & schtasks.exe /delete /tn "$taskName" /f 2>&1 | Out-Null }
function Test-InteractiveSession {
    try {
        $out = & quser.exe 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $rows = @($out | Where-Object { $_ -match '\S' })
            if ($rows.Count -ge 2) { return $true }
        }
    } catch {
        # quser.exe may be unavailable or unsupported in certain Windows editions
    }
    try {
        $expl = Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 }
        if ($expl) { return $true }
    } catch {
        # Get-Process can throw if process query fails or access is restricted
    }
    return $false
}

if (Test-Path -LiteralPath $guardFile) {
    Write-WLog ("post-reboot run: guard marker present, session-active=" + (Test-InteractiveSession))
    Remove-WatchdogTask
    Write-WLog 'watchdog stood down after recovery reboot'
    exit 0
}

Write-WLog 'watchdog armed (first-run instance)'
$deadline = (Get-Date).AddMinutes(15)
$extended = $false
$sessionSeen = $false
$lastBeat = Get-Date

while ($true) {
    if (Test-InteractiveSession) { $sessionSeen = $true; break }
    if ((Get-Date) -ge $deadline) {
        if (-not $extended) {
            $oobe = Get-Process -Name 'msoobe','CloudExperienceHost','CloudExperienceHostBroker' -ErrorAction SilentlyContinue
            if ($oobe) {
                $deadline = (Get-Date).AddMinutes(5)
                $extended = $true
                Write-WLog 'OOBE processes still running; extending wait by 5 minutes'
                continue
            }
        }
        break
    }
    if (((Get-Date) - $lastBeat).TotalMinutes -ge 5) { Write-WLog 'waiting for an interactive session'; $lastBeat = Get-Date }
    Start-Sleep -Seconds 45
}

if ($sessionSeen) {
    Write-WLog 'interactive user session detected; transition OK'
    Remove-WatchdogTask
    exit 0
}

$auto = [string](Get-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon
if ($auto -ne '1') {
    Write-WLog ("no session yet but AutoAdminLogon='" + $auto + "'; autologon phase already finished - no action")
    Remove-WatchdogTask
    exit 0
}

Write-WLog 'no user session detected while auto-logon is armed; triggering one-shot recovery reboot'
Set-Content -LiteralPath $guardFile -Value ("recovery reboot at " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding ascii
& shutdown.exe /r /t 5 /f
exit 0
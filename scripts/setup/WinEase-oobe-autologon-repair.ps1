# WinEase-oobe-autologon-repair.ps1
# Re-assert the Winlogon auto-logon target for the OOBE -> first user session transition.
# msoobe rewrites these values to the temporary defaultuser0 account at the end of OOBE,
# which makes the transition logon fail (1326) and stalls setup on the "Just a moment..." screen.
# Runs from SetupComplete.cmd as the LAST writer before the transition logon is attempted.
$ErrorActionPreference = 'SilentlyContinue'
$user = '__WINEASE_USERNAME__'
$key  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

Set-ItemProperty -LiteralPath $key -Name 'AutoAdminLogon'  -Value '1'    -Type String -Force
Set-ItemProperty -LiteralPath $key -Name 'DefaultUserName' -Value $user -Type String -Force
Set-ItemProperty -LiteralPath $key -Name 'DefaultPassword' -Value '__WINEASE_USERPASSWORD__' -Type String -Force
Set-ItemProperty -LiteralPath $key -Name 'ForceAutoLogon'  -Value '1'    -Type String -Force

$sid = $null
try {
    $sid = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value
} catch { $sid = $null }

if ($sid) {
    Set-ItemProperty -LiteralPath $key -Name 'AutoLogonSID' -Value $sid -Type String -Force
    Write-Output "[OOBE-AutoLogon] keys re-armed for '$user' (AutoLogonSID=$sid)"
} else {
    Remove-ItemProperty -LiteralPath $key -Name 'AutoLogonSID' -Force
    Write-Output "[OOBE-AutoLogon] keys re-armed for '$user' (AutoLogonSID unresolved; stale value removed)"
}
Remove-ItemProperty -LiteralPath $key -Name 'AutoLogonCount' -Force

$check = Get-ItemProperty -LiteralPath $key
Write-Output ("[OOBE-AutoLogon] verified: AutoAdminLogon=" + $check.AutoAdminLogon + " DefaultUserName=" + $check.DefaultUserName + " ForceAutoLogon=" + $check.ForceAutoLogon)
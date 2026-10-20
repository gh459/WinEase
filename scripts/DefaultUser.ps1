& { try {
  # Ensure RunOnce UnattendedSetup is registered in Default User hive
  & reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\UserOnce.ps1" /f 2>$null;
  exit 0;
} catch {
  exit 1;
} } *>&1 >> "C:\Windows\Setup\Scripts\DefaultUser.log";
if (-not $?) { exit 1; }
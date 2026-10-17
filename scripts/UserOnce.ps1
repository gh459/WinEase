& { try {
  # Terminate rogue background sync processes
  Stop-Process -Name 'SearchHost', 'CrossDeviceResume' -Force -ErrorAction SilentlyContinue;

  # Remove SecHealthUI AppX package for current user if Defender was removed
  if (Test-Path 'C:\Windows\Setup\Scripts\remove-defender.flag') {
    Get-AppxPackage "*SecHealthUI*" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue;
  }

  # Clean up RunOnce setup command
  Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'UnattendedSetup' -Force -ErrorAction SilentlyContinue;
} catch {} } *>&1 >> "$env:TEMP\UserOnce.log";
exit 0;
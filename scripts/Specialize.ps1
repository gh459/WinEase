$markerDir = "C:\ProgramData\WinEase";
if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir -ErrorAction SilentlyContinue | Out-Null; }
Remove-Item -LiteralPath "$markerDir\specialize.succeeded", "$markerDir\specialize.failed" -Force -ErrorAction SilentlyContinue;
Set-Content -LiteralPath "$markerDir\specialize.started" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue;

# 0. Defender / Security UI enforcement in the SYSTEM specialize pass. The offline
#    image has already lost the service keys and the payload; this catches services
#    that CBS re-registered during the first boot before SetupComplete runs.
if (Test-Path -LiteralPath "C:\Windows\Setup\Scripts\remove-defender.flag") {
    $defEnforce = "C:\Windows\Setup\Scripts\WinEase-DefenderEnforce.ps1";
    if (Test-Path -LiteralPath $defEnforce) {
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $defEnforce -Quiet 2>&1 | Out-File -FilePath "C:\Windows\Setup\Scripts\Specialize.log" -Append -Encoding utf8 } catch { Write-Verbose "Defender enforcement invocation failed: $($_.Exception.Message)" }
    }
}

& { try {
  # 1. User account password policy
  & net.exe accounts /maxpwage:UNLIMITED 2>$null;

  # 2. Dynamic Network Stack & TCP tuning if flagged
  if (Test-Path "C:\Windows\Setup\Scripts\network-stack.flag") {
    try {
      Set-NetTCPSetting -SettingName InternetCustom -AutoTuningLevelLocal Normal -ScalingHeuristics Disabled -ErrorAction SilentlyContinue;
      Set-NetTCPSetting -SettingName InternetCustom -EcnCapability Enabled -Timestamps Disabled -ErrorAction SilentlyContinue;
      Set-NetOffloadGlobalSetting -ReceiveSideScaling Enabled -ReceiveSegmentCoalescing Disabled -TaskOffload Enabled -ErrorAction SilentlyContinue;
      Disable-NetAdapterLso -Name * -IPv4 -ErrorAction SilentlyContinue;
    } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
  }

  # 3. Dynamic Message Signaled Interrupts (MSI) scan for newly detected PCI hardware
  #    Guarded by the EnableMsiMode option (flag staged by phase 11).
  try {
    if (Test-Path "C:\Windows\Setup\Scripts\enable-msimode.flag") {
      $targetClasses = @('{4d36e968-e325-11ce-bfc1-08002be10318}', '{4d36e972-e325-11ce-bfc1-08002be10318}');
      $pnpDevs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.ClassGuid -in $targetClasses -and $_.InstanceId -like "PCI\*" };
      foreach ($dev in $pnpDevs) {
        $msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties";
        if (-not (Test-Path -LiteralPath $msiPath)) {
          New-Item -Path $msiPath -Force -ErrorAction SilentlyContinue | Out-Null;
        }
        Set-ItemProperty -LiteralPath $msiPath -Name "MSISupported" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue;
      }
    }
  } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }

  # 4. Memory Compression optimization if flagged
  if (Test-Path "C:\Windows\Setup\Scripts\disable-memcompression.flag") {
    try { Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue; } catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
  }

  Set-Content -LiteralPath "C:\ProgramData\WinEase\specialize.succeeded" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii -ErrorAction SilentlyContinue;
} catch {
  $err = "$($_ | Out-String)";
  Remove-Item -LiteralPath "C:\ProgramData\WinEase\specialize.succeeded" -Force -ErrorAction SilentlyContinue;
  Set-Content -LiteralPath "C:\ProgramData\WinEase\specialize.failed" -Value $err -Encoding ascii -ErrorAction SilentlyContinue;
  exit 1;
} } *>&1 >> "C:\Windows\Setup\Scripts\Specialize.log";
if (Test-Path -LiteralPath "C:\ProgramData\WinEase\specialize.failed") { exit 1; }
exit 0;
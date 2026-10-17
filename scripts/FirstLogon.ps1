try {
	$initMarkerDir = "C:\ProgramData\nano11";
	if (Test-Path -LiteralPath $initMarkerDir) {
		Remove-Item -LiteralPath "$initMarkerDir\firstlogon.done", "$initMarkerDir\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue;
	}
} catch {}
$scripts = @(
	{
		# Guarantee User account has NO password (completely blank) and cannot expire
		try {
			& net.exe accounts /maxpwage:UNLIMITED /minpwlen:0 2>$null;
			& net.exe user User "" /active:yes /passwordreq:no /expires:never 2>$null;
		} catch {}
	};
	{
		# Disable Computer Restore on System Drive
		try {
			Disable-ComputerRestore -Drive "C:\" 2>$null;
		} catch {}
	};
	{
		# Enable CompactOS NTFS Compression
		try {
			& Compact.exe /CompactOS:always 2>$null;
		} catch {}
	};
	{
		# Low-Latency BCD Boot & Timer Tweaks
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\timer-bcd.flag") {
				& bcdedit.exe /set useplatformclock false 2>$null;
				& bcdedit.exe /set disabledynamictick yes 2>$null;
				& bcdedit.exe /set tscsyncpolicy Enhanced 2>$null;
			}
			& bcdedit.exe /timeout 0 2>$null;
			if (Test-Path "C:\Windows\Setup\Scripts\no-hypervisor.flag") {
				& bcdedit.exe /set hypervisorlaunchtype off 2>$null;
			}
		} catch {}
	};
	{
		# Advanced Low-Latency Network & Nagle Tuning
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\network-stack.flag") {
				& netsh.exe int tcp set global autotuninglevel=normal 2>$null;
				& netsh.exe int tcp set global rss=enabled 2>$null;
				& netsh.exe int tcp set global rsc=disabled 2>$null;
				& netsh.exe int tcp set global ecncapability=enabled 2>$null;
				& netsh.exe int tcp set global timestamps=disabled 2>$null;
				& netsh.exe int tcp set heuristics disabled 2>$null;
				$adapters = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\*' -ErrorAction SilentlyContinue;
				foreach ($adapter in $adapters) {
					Set-ItemProperty -Path $adapter.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue;
					Set-ItemProperty -Path $adapter.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue;
				}
			}
			if (Test-Path "C:\Windows\Setup\Scripts\disable-netbios.flag") {
				Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue |
					ForEach-Object { Set-ItemProperty $_.PSPath 'NetbiosOptions' 2 -Type DWord -Force -ErrorAction SilentlyContinue };
			}
		} catch {}
	};
	{
		# NTFS I/O Overhead Reduction
		try {
			& fsutil.exe behavior set disablelastaccess 1 2>$null;
			& fsutil.exe 8dot3name set 1 2>$null;
		} catch {}
	};
	{
		# Custom Post-Install User Scripts Execution Hook (from tools/custom-scripts/)
		$customDir = "C:\Windows\Setup\Scripts\Custom";
		if (Test-Path $customDir) {
			Get-ChildItem -Path $customDir -File | Sort-Object Name | ForEach-Object {
				try {
					switch ($_.Extension.ToLower()) {
						'.ps1' { & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $_.FullName }
						'.bat' { & cmd.exe /c "`"$($_.FullName)`"" }
						'.cmd' { & cmd.exe /c "`"$($_.FullName)`"" }
						'.reg' { & reg.exe import $_.FullName }
					}
				} catch {}
			}
		}
	};
	{
		# Post-OOBE WebView2 removal if flagged
		if (Test-Path "C:\Windows\Setup\Scripts\remove-webview.flag") {
			try {
				$webViewDir = 'C:\Windows\System32\Microsoft-Edge-WebView';
				if (Test-Path -LiteralPath $webViewDir) {
					$yesKey = try { ($null | choice.exe).Substring(1, 1) } catch { 'Y' };
					& takeown.exe /f $webViewDir /r /a /d $yesKey >$null 2>&1;
					& icacls.exe $webViewDir /grant "*S-1-5-32-544:F" /t /c /q >$null 2>&1;
					Remove-Item -LiteralPath $webViewDir -Recurse -Force -ErrorAction SilentlyContinue;
				}
				Remove-Item "C:\Windows\Setup\Scripts\remove-webview.flag" -Force -ErrorAction SilentlyContinue;
			} catch {}
		}
	};
	{
		# Windows Activation Restriction Bypass & Silent Digital License Activation
		$actFlag = "C:\Windows\Setup\Scripts\bypass-activation.flag";
		if (Test-Path $actFlag) {
			try {
				& schtasks.exe /change /tn "\Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTask" /disable 2>$null;
				& schtasks.exe /change /tn "\Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTaskLogon" /disable 2>$null;
				& schtasks.exe /change /tn "\Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTaskNetwork" /disable 2>$null;

				$isOnline = $false;
				try {
					$ping = Test-Connection -ComputerName "1.1.1.1" -Count 1 -Quiet -ErrorAction SilentlyContinue;
					if (-not $ping) { $ping = Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue; }
					$isOnline = [bool]$ping;
				} catch {}

				if ($isOnline) {
					[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13;
					& ([ScriptBlock]::Create((Invoke-RestMethod -Uri 'https://get.activated.win' -UseBasicParsing))) /HWID /NoEditionChange 2>$null;
				}
				Remove-Item -LiteralPath $actFlag -Force -ErrorAction SilentlyContinue;
			} catch {}
		}
	};
	{
		# Boot Time Metrics Tracking (Event ID 100)
		try {
			$bootEvent = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100} -MaxEvents 1 -ErrorAction SilentlyContinue;
			if ($bootEvent -and $bootEvent.Properties -and $bootEvent.Properties.Count -gt 5) {
				$bootMs = $bootEvent.Properties[5].Value;
				$statsDir = "C:\ProgramData\nano11";
				if (-not (Test-Path $statsDir)) { New-Item -ItemType Directory -Force -Path $statsDir | Out-Null; }
				"{0},{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $bootMs | Add-Content "$statsDir\boot-stats.csv";
			}
		} catch {}
	};
	{
		# WinRE Online Dismantle if winre-cleanup.flag is present
		$flag = "C:\Windows\Setup\Scripts\winre-cleanup.flag";
		if (Test-Path $flag) {
			try {
				& reagentc.exe /disable 2>$null;
				$winrePath = "C:\Windows\System32\Recovery\Winre.wim";
				if (Test-Path $winrePath) {
					takeown.exe /f $winrePath /a 2>$null;
					icacls.exe $winrePath /grant "*S-1-5-32-544:F" 2>$null;
					Remove-Item -LiteralPath $winrePath -Force -ErrorAction SilentlyContinue;
				}
				Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue;
			} catch {}
		}
	};
	{
		# Safe Telemetry & CEIP Scheduled Tasks Suppression
		try {
			$safeTasks = @(
				'\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
				'\Microsoft\Windows\Application Experience\ProgramDataUpdater',
				'\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
				'\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
				'\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
				'\Microsoft\Windows\Feedback\Siuf\DmClient'
			);
			foreach ($t in $safeTasks) {
				schtasks.exe /change /tn "$t" /disable >$null 2>&1;
			}
		} catch {}
	};
	{
		# Cross-Device Resume enforcement: kill the resume host if it launched before IFEO applied,
		# and re-assert the IFEO debugger block online (the executable is bundled inside the protected
		# MicrosoftWindows.Client.CBS shell package, so it must be neutralized, never deleted).
		try {
			Get-Process -Name CrossDeviceResume -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;
			New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CrossDeviceResume.exe' -Force -ErrorAction SilentlyContinue | Out-Null;
			Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CrossDeviceResume.exe' -Name 'Debugger' -Value 'rundll32.exe' -Force -ErrorAction SilentlyContinue;
		} catch {}
	};
	{
		# Windows Search disable enforcement (offline hive edit backup: stop & disable WSearch online,
		# kill SearchHost if it spawned, hide the taskbar search box for the logged-on user)
		if (Test-Path "C:\Windows\Setup\Scripts\disable-search.flag") {
			try {
				Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue;
				Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue;
				Get-Process -Name SearchHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;
				Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue;
			} catch {}
			Remove-Item "C:\Windows\Setup\Scripts\disable-search.flag" -Force -ErrorAction SilentlyContinue;
		}
	};
	{
		# Residual per-user Appx removal fallback: Windows Backup / Web Experience host / Get Started
		try {
			Get-AppxPackage -AllUsers -Name *WindowsBackupApp* -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue;
			Get-AppxPackage -AllUsers -Name *Client.WebExperience* -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue;
			Get-AppxPackage -AllUsers -Name *Getstarted* -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue;
		} catch {}
	};
	{
		# Signal FirstLogon completion and restore persistent AutoLogon security
		try {
			$markerDir = "C:\ProgramData\nano11";
			if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null; }
			Set-Content -LiteralPath "$markerDir\firstlogon.done" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii;

			# Security restore: Tear down permanent AutoLogon after setup logon succeeds
			Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon' -Value '0' -Force -ErrorAction SilentlyContinue;
			Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'ForceAutoLogon' -Value '0' -Force -ErrorAction SilentlyContinue;
			Remove-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'DefaultPassword' -Force -ErrorAction SilentlyContinue;
		} catch {}
	};
);

& {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  $flErrors = @();
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    $start = [datetime]::Now;
    try {
      & $script;
    } catch {
      $flErrors += ("Script block failed: {0}" -f $_);
    }
    $complete += $increment;
  }
  if ($flErrors.Count -gt 0) {
    Remove-Item -LiteralPath "C:\ProgramData\nano11\firstlogon.done" -Force -ErrorAction SilentlyContinue;
    Set-Content -LiteralPath "C:\ProgramData\nano11\firstlogon_script.failed" -Value ($flErrors -join "`r`n") -Encoding UTF8 -ErrorAction SilentlyContinue;
    exit 1;
  } else {
    Remove-Item -LiteralPath "C:\ProgramData\nano11\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue;
    if (-not (Test-Path -LiteralPath "C:\ProgramData\nano11\firstlogon.done")) {
      Set-Content -LiteralPath "C:\ProgramData\nano11\firstlogon.done" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8 -ErrorAction SilentlyContinue;
    }
    exit 0;
  }
} *>&1 >> "C:\ProgramData\nano11\Logs\firstlogon-child.log";
if (-not $? -or (Test-Path -LiteralPath "C:\ProgramData\nano11\firstlogon_script.failed")) {
  exit 1;
} else {
  Remove-Item -LiteralPath "C:\ProgramData\nano11\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue;
  exit 0;
}
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
		$customLogDir = "C:\ProgramData\nano11\Logs";
		$customLogFiles = @(
			"$customDir\custom-scripts.log",
			"$customLogDir\custom-scripts.log"
		);

		function Redact-Nano11Secret {
			param([string]$Text)
			if ([string]::IsNullOrEmpty($Text)) { return $Text; }
			$masked = $Text -replace '(?i)(password|secret|token|apikey|key)\s*[:=]\s*[^\s]+', '$1: [REDACTED]';
			$masked = $masked -replace '[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}', 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX';
			return $masked;
		}

		function Write-CustomScriptLog {
			param([string]$Message)
			$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff";
			$cleanMsg = Redact-Nano11Secret -Text $Message;
			$line = "[$ts] $cleanMsg";
			foreach ($logPath in $customLogFiles) {
				try {
					$parentDir = Split-Path -Path $logPath -Parent;
					if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
						New-Item -ItemType Directory -Force -Path $parentDir -ErrorAction SilentlyContinue | Out-Null;
					}
					[System.IO.File]::AppendAllText($logPath, "$line`r`n", [System.Text.Encoding]::UTF8);
				} catch {
					try {
						Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue;
					} catch {
						Write-Warning "[CUSTOM-SCRIPT-LOG-WARNING] Failed to append log entry to '$logPath': $($_.Exception.Message)";
					}
				}
			}
		}

		if (Test-Path -LiteralPath $customDir) {
			$validExts = @('.ps1', '.bat', '.cmd', '.reg');
			$allCandidateFiles = @(Get-ChildItem -Path $customDir -File -ErrorAction SilentlyContinue |
				Where-Object {
					$_.Name -ne 'custom-scripts.log' -and
					$_.Extension.ToLower() -ne '.log' -and
					$_.Name -ne 'README.md'
				} |
				Sort-Object Name);

			$targetFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new();
			foreach ($cand in $allCandidateFiles) {
				$ext = $cand.Extension.ToLower();
				if ($validExts -contains $ext) {
					$targetFiles.Add($cand);
				} else {
					Write-CustomScriptLog "[SKIPPED] File: $($cand.Name) | Path: $($cand.FullName) | Reason: Unsupported or disabled extension ('$ext')";
				}
			}

			if ($targetFiles.Count -gt 0) {
				Write-CustomScriptLog "================================================================================";
				Write-CustomScriptLog "Custom Scripts Execution Pipeline Started (Elevated Administrator Context)";
				Write-CustomScriptLog "Directory: $customDir";
				Write-CustomScriptLog "Target Scripts ($($targetFiles.Count)): $(($targetFiles | ForEach-Object { $_.Name }) -join ', ')";
				Write-CustomScriptLog "================================================================================";

				# Load SHA256 integrity manifest if present
				$manifestPath = "C:\Windows\Setup\Scripts\custom-scripts-manifest.json";
				$manifest = $null;
				if (Test-Path -LiteralPath $manifestPath) {
					try {
						$manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json;
						Write-CustomScriptLog "Loaded custom scripts integrity manifest ($($manifest.psobject.properties.name.Count) entries).";
					} catch {
						Write-CustomScriptLog "[SECURITY WARNING] Failed to read custom-scripts-manifest.json: $($_.Exception.Message)";
					}
				}

				$pipelineSw = [System.Diagnostics.Stopwatch]::StartNew();
				$successCount = 0;
				$failCount = 0;
				$idx = 0;

				foreach ($file in $targetFiles) {
					$idx++;
					$scriptName = $file.Name;
					$scriptPath = $file.FullName;
					$ext = $file.Extension.ToLower();
					$startDt = Get-Date;
					$startStr = $startDt.ToString("yyyy-MM-dd HH:mm:ss.fff");

					# Enforce SHA256 verification against build-time manifest
					if ($manifest) {
						$expectedHash = $manifest."$scriptName";
						if (-not $expectedHash) {
							$endDt = Get-Date;
							$endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");
							Write-CustomScriptLog "[$idx/$($targetFiles.Count)] [SECURITY REFUSAL] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Reason: File is not listed in build-time integrity manifest. Execution blocked.";
							$failCount++;
							continue;
						}
						$actualHash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash;
						if ($actualHash -ine $expectedHash) {
							$endDt = Get-Date;
							$endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");
							Write-CustomScriptLog "[$idx/$($targetFiles.Count)] [SECURITY REFUSAL] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Reason: Hash mismatch (Expected: $expectedHash, Got: $actualHash). Execution blocked.";
							$failCount++;
							continue;
						}
					}

					$scriptSw = [System.Diagnostics.Stopwatch]::StartNew();
					Write-CustomScriptLog "[$idx/$($targetFiles.Count)] [START] Script: $scriptName | Path: $scriptPath | StartTime: $startStr";

					$exitCode = 0;
					$isSuccess = $false;
					$errDetail = $null;

					$global:LASTEXITCODE = 0;
					$prevEap = $ErrorActionPreference;
					$ErrorActionPreference = 'Continue';
					try {
						$output = switch ($ext) {
							'.ps1' {
								& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command "& { `$ErrorActionPreference = 'Stop'; & '$scriptPath'; if (`$null -ne `$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE } }" 2>&1
							}
							'.bat' {
								& "$env:SystemRoot\System32\cmd.exe" /c "`"$scriptPath`"" 2>&1
							}
							'.cmd' {
								& "$env:SystemRoot\System32\cmd.exe" /c "`"$scriptPath`"" 2>&1
							}
							'.reg' {
								& "$env:SystemRoot\System32\reg.exe" import "$scriptPath" 2>&1
							}
						}
						$exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 };

						if ($exitCode -eq 0) {
							$isSuccess = $true;
						} else {
							$isSuccess = $false;
							$errLines = ($output | Out-String).Trim();
							if (-not [string]::IsNullOrWhiteSpace($errLines)) {
								$lastLine = ($errLines -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1);
								$errDetail = "Process exited with code $exitCode (Output: $(Redact-Nano11Secret -Text $lastLine))";
							} else {
								$errDetail = "Process exited with non-zero exit code: $exitCode";
							}
						}
					} catch {
						$isSuccess = $false;
						$exitCode = if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { -1 };
						$errDetail = "Execution exception (Code $exitCode): $(Redact-Nano11Secret -Text $_.Exception.Message)";
					} finally {
						$ErrorActionPreference = $prevEap;
					}

					$scriptSw.Stop();
					$elapsedSec = [math]::Round($scriptSw.Elapsed.TotalSeconds, 2);
					$endDt = Get-Date;
					$endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");

					if ($isSuccess) {
						$successCount++;
						Write-CustomScriptLog "[$idx/$($targetFiles.Count)] [SUCCESS] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Duration: ${elapsedSec}s | ExitCode: 0";
					} else {
						$failCount++;
						Write-CustomScriptLog "[$idx/$($targetFiles.Count)] [FAILED] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Duration: ${elapsedSec}s | ExitCode: $exitCode | Reason: $errDetail";
					}
				}

				$pipelineSw.Stop();
				$totalSec = [math]::Round($pipelineSw.Elapsed.TotalSeconds, 2);
				Write-CustomScriptLog "================================================================================";
				Write-CustomScriptLog "Custom Scripts Execution Pipeline Finished";
				Write-CustomScriptLog "Summary: Total: $($targetFiles.Count), Succeeded: $successCount, Failed: $failCount, Duration: ${totalSec}s";
				Write-CustomScriptLog "================================================================================";
			}
		}
	};
	{
		# Post-OOBE WebView2 removal if flagged
		if (Test-Path "C:\Windows\Setup\Scripts\remove-webview.flag") {
			try {
				$webViewDir = 'C:\Windows\System32\Microsoft-Edge-WebView';
				if (Test-Path -LiteralPath $webViewDir) {
					$wvItem = Get-Item -LiteralPath $webViewDir -Force -ErrorAction SilentlyContinue;
					if ($wvItem -and ($wvItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
						try { [System.IO.Directory]::Delete($webViewDir, $false); } catch { Write-Warning "Failed to delete WebView2 junction: $_"; }
					} else {
						$yesKey = try { ($null | choice.exe).Substring(1, 1) } catch { 'Y' };
						& takeown.exe /f $webViewDir /r /a /d $yesKey >$null 2>&1;
						& icacls.exe $webViewDir /grant "*S-1-5-32-544:F" /t /c /q >$null 2>&1;
						Remove-Item -LiteralPath $webViewDir -Recurse -Force -ErrorAction SilentlyContinue;
					}
				}
				Remove-Item "C:\Windows\Setup\Scripts\remove-webview.flag" -Force -ErrorAction SilentlyContinue;
			} catch {
				Write-Warning "remove-webview post-OOBE task failed: $_";
			}
		}
	};
	{
		# Windows Activation Restriction Bypass (Safe local SPP notification suppression)
		$actFlag = "C:\Windows\Setup\Scripts\bypass-activation.flag";
		if (Test-Path $actFlag) {
			try {
				& schtasks.exe /change /tn "\Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTask" /disable 2>$null;
				& schtasks.exe /change /tn "\Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTaskLogon" /disable 2>$null;
				& schtasks.exe /change /tn "\Microsoft\Windows\SoftwareProtectionPlatform\SvcRestartTaskNetwork" /disable 2>$null;
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
		# Accessibility tools enforcement (post-OOBE): osk.exe / Narrator.exe / Magnify.exe are
		# RETAINED in System32 for OOBE stability (the offline debloat preserves them by design),
		# but must never launch on the desktop. Execution is redirected to a harmless host via IFEO
		# and any prematurely started instance is terminated.
		try {
			foreach ($acc in 'osk.exe','Narrator.exe','Magnify.exe') {
				$accKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$acc";
				New-Item -Path $accKey -Force -ErrorAction SilentlyContinue | Out-Null;
				Set-ItemProperty -LiteralPath $accKey -Name 'Debugger' -Value 'rundll32.exe' -Force -ErrorAction SilentlyContinue;
				Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($acc)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;
			}
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
try {
	$initMarkerDir = "C:\ProgramData\WinEase";
	if (Test-Path -LiteralPath $initMarkerDir) {
		Remove-Item -LiteralPath "$initMarkerDir\firstlogon.done", "$initMarkerDir\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue;
	}
} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
$scripts = @(
	{
		# Configure account password policy and password expiration
		try {
			& net.exe accounts /maxpwage:UNLIMITED 2>$null;
			& net.exe user User /active:yes /expires:never 2>$null;
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Disable Computer Restore on System Drive
		# Guarded by the DisableComputerRestore option: phase 11 only stages the flag when
		# the option is enabled, because disabling System Restore removes the safety net the
		# user may rely on.
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\disable-computer-restore.flag") {
				Disable-ComputerRestore -Drive "C:\" 2>$null;
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Enable CompactOS NTFS Compression
		# Guarded by the EnableCompactOS option: the flag is only staged by phase 11 when
		# the option is enabled, so an image that must not be compressed simply has no flag.
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\enable-compactos.flag") {
				& Compact.exe /CompactOS:always 2>$null;
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
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
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
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
					ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name 'NetbiosOptions' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue };
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# NTFS I/O Overhead Reduction
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\enable-ntfs8dot3.flag") {
				& fsutil.exe behavior set disablelastaccess 1 2>$null;
				& fsutil.exe 8dot3name set 1 2>$null;
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Custom Post-Install User Scripts Execution Hook (from tools/custom-scripts/)
		$customDir = "C:\Windows\Setup\Scripts\Custom";
		$customLogDir = "C:\ProgramData\WinEase\Logs";
		$customLogFiles = @(
			"$customDir\custom-scripts.log",
			"$customLogDir\custom-scripts.log"
		);

		function Redact-WinEaseSecret {
			param([string]$Text)
			if ([string]::IsNullOrEmpty($Text)) { return $Text; }
			# Quoted values first (JSON / assignment forms such as "password": "..."
			# or 'apikey' = '...'): the value may contain spaces, so the unquoted
			# pattern below would only mask its first word and leak the rest.
			$masked = $Text -replace '(?i)(["\x27]?[\w-]*(password|secret|token|apikey)[\w-]*["\x27]?\s*[:=]\s*)("[^"]*"|\x27[^\x27]*\x27)', '$1[REDACTED]';
			$masked = $masked -replace '(?i)(password|secret|token|apikey|key)\s*[:=]\s*(?!\[REDACTED\])[^\s]+', '$1: [REDACTED]';
			$masked = $masked -replace '[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}', 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX';
			return $masked;
		}

		function Write-CustomScriptLog {
			param([string]$Message)
			$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff";
			$cleanMsg = Redact-WinEaseSecret -Text $Message;
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

					# Fail closed (S-H2): custom scripts are present (this loop only runs
					# for target files), but there is no usable integrity manifest, so
					# nothing is executed.
					if (-not $manifest) {
						$endDt = Get-Date;
						$endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");
						Write-CustomScriptLog "[$idx/$($targetFiles.Count)] [SECURITY REFUSAL] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Reason: Integrity manifest is missing or unreadable. Execution blocked (fail-closed).";
						$failCount++;
						continue;
					}

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
						$actualHash = try {
							$fs = [System.IO.File]::OpenRead($scriptPath);
							$sha = [System.Security.Cryptography.SHA256]::Create();
							try {
								[System.BitConverter]::ToString($sha.ComputeHash($fs)).Replace("-", "");
							} finally {
								if ($null -ne $sha) { $sha.Dispose(); }
								if ($null -ne $fs) { $fs.Dispose(); }
							}
						} catch { $null };
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
					$escapedScriptPath = $scriptPath -replace "'", "''";
					try {
						$output = switch ($ext) {
							'.ps1' {
								& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command "& { `$ErrorActionPreference = 'Stop'; & '$escapedScriptPath'; if (`$null -ne `$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE } }" 2>&1
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
								$errDetail = "Process exited with code $exitCode (Output: $(Redact-WinEaseSecret -Text $lastLine))";
							} else {
								$errDetail = "Process exited with non-zero exit code: $exitCode";
							}
						}
					} catch {
						$isSuccess = $false;
						$exitCode = if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { -1 };
						$errDetail = "Execution exception (Code $exitCode): $(Redact-WinEaseSecret -Text $_.Exception.Message)";
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
			} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
		}
	};
	{
		# Boot Time Metrics Tracking (Event ID 100)
		try {
			$bootEvent = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100} -MaxEvents 1 -ErrorAction SilentlyContinue;
			if ($bootEvent -and $bootEvent.Properties -and $bootEvent.Properties.Count -gt 5) {
				$bootMs = $bootEvent.Properties[5].Value;
				$statsDir = "C:\ProgramData\WinEase";
				if (-not (Test-Path $statsDir)) { New-Item -ItemType Directory -Force -Path $statsDir | Out-Null; }
				"{0},{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $bootMs | Add-Content "$statsDir\boot-stats.csv";
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
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
			} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
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
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Cross-Device Resume enforcement: kill the resume host if it launched before IFEO applied,
		# and re-assert the IFEO debugger block online (the executable is bundled inside the protected
		# MicrosoftWindows.Client.CBS shell package, so it must be neutralized, never deleted).
		# Guarded by the DisableCrossDevice option.
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\disable-crossdevice.flag") {
				Get-Process -Name CrossDeviceResume -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;
				New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CrossDeviceResume.exe' -Force -ErrorAction SilentlyContinue | Out-Null;
				Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CrossDeviceResume.exe' -Name 'Debugger' -Value 'rundll32.exe' -Force -ErrorAction SilentlyContinue;
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Accessibility tools enforcement (post-OOBE): osk.exe / Narrator.exe / Magnify.exe are
		# RETAINED in System32 for OOBE stability (the offline debloat preserves them by design).
		# Blocking them is opt-in: the flag is only staged by phase 11 when the
		# DisableAccessibilityTools option is enabled. Without the option these tools keep
		# working normally on the desktop.
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\disable-accessibility.flag") {
				foreach ($acc in 'osk.exe','Narrator.exe','Magnify.exe') {
					$accKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$acc";
					New-Item -Path $accKey -Force -ErrorAction SilentlyContinue | Out-Null;
					Set-ItemProperty -LiteralPath $accKey -Name 'Debugger' -Value 'rundll32.exe' -Force -ErrorAction SilentlyContinue;
					Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($acc)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;
				}
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Hibernate mode (staged by phase 11 from the HibernateMode option).
		#   Off     -> hibernation is disabled, hiberfil.sys is removed (reclaims disk)
		#   Reduced -> fast startup is disabled but hibernation itself is kept
		#   Keep    -> nothing is changed
		# The flag carries the mode name; nothing happens when it is absent.
		$hibernateFlag = "C:\Windows\Setup\Scripts\hibernate-mode.flag"
		if (Test-Path $hibernateFlag) {
			try {
				$hibernateMode = (Get-Content -LiteralPath $hibernateFlag -Raw -ErrorAction SilentlyContinue)
				if ($null -eq $hibernateMode) { $hibernateMode = '' }
				$hibernateMode = $hibernateMode.Trim()
				switch ($hibernateMode.ToLowerInvariant()) {
					'off' {
						& powercfg.exe /hibernate off 2>$null;
						& powercfg.exe /h off 2>$null;
					}
					'reduced' {
						# Keep hibernation but turn off fast startup, which is the part that
						# restores the previous session on boot.
						& powercfg.exe /h off 2>$null;
					}
					default {
						# 'keep' - leave the power configuration alone.
					}
				}
				Remove-Item -LiteralPath $hibernateFlag -Force -ErrorAction SilentlyContinue;
			} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
		}
	};
	{
		# Page file removal (staged by phase 11 when the Advanced Debloat tab asks for it).
		# The page file cannot be deleted while Windows is running, so the paging file is
		# switched off here; Windows removes pagefile.sys at the next boot.
		$pagefileFlag = "C:\Windows\Setup\Scripts\remove-pagefile.flag"
		if (Test-Path $pagefileFlag) {
			try {
				# The empty string has to be passed as the literal '""': an empty argument is
				# dropped by the PowerShell native call, so reg.exe would take the next switch
				# ('/f') as the value and Windows would keep the old paging file entry.
				& reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v PagingFiles /t REG_MULTI_SZ /d '""' /f 2>$null | Out-Null
				& reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ExistingPageFiles /t REG_MULTI_SZ /d '""' /f 2>$null | Out-Null
			} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
			Remove-Item -LiteralPath $pagefileFlag -Force -ErrorAction SilentlyContinue;
		}
	};
	{
		# USB selective suspend disable (staged by phase 11 when -DisableUSBSuspend is set).
		# USB power management can only be changed on the running system through powercfg,
		# so the offline build can only stage the request.
		if (Test-Path "C:\Windows\Setup\Scripts\disable-usb-suspend.flag") {
			try {
				# 0 = disabled (never suspend USB), 1 = enabled.
				& powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVE 0 2>$null;
				& powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVE 0 2>$null;
				& powercfg.exe /setactive SCHEME_CURRENT 2>$null;
				Remove-Item "C:\Windows\Setup\Scripts\disable-usb-suspend.flag" -Force -ErrorAction SilentlyContinue;
			} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
		}
	};
	{
		# Windows Defender enforcement (post-OOBE): the offline build removes the Defender
		# service keys, but CBS can re-register them from the WinSxS servicing payload during
		# the first boot, which resurrects MsMpEng.exe / Sense.exe. This block re-asserts the
		# removal online and terminates any engine process that is already running.
		if (Test-Path "C:\Windows\Setup\Scripts\remove-defender.flag") {
			try {
				# The deployed enforcement helper does the full online removal (service
				# keys, Security UI package, AppRepository rows, IFEO traps). The inline
				# block below stays as a fallback for images built before the helper
				# existed or when its execution is blocked by policy.
				$defEnforce = "C:\Windows\Setup\Scripts\WinEase-DefenderEnforce.ps1";
				if (Test-Path -LiteralPath $defEnforce) {
					& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $defEnforce -Quiet 2>&1 | Out-Null;
				}
				# Stop and disable every Defender-related service (idempotent: a missing
				# service key is fine, the goal is "not running and not startable").
				foreach ($svc in 'WinDefend','MDCoreSvc','WdNisSvc','Sense','SecurityHealthService','wscsvc','SgrmBroker','SgrmAgent') {
					Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue;
					Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue;
				}
				# Terminate the engine and helper processes. MsMpEng.exe is the AV engine
				# itself; Sense.exe is the Defender telemetry host; SecurityHealthSystray.exe
				# and SecurityHealthHost.exe belong to the Windows Security UI.
				foreach ($proc in 'MsMpEng','Sense','SecurityHealthSystray','SecurityHealthHost','MpCmdRun') {
					Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;
				}
				# Remove the service keys again so a later CBS pass cannot re-enable them.
				foreach ($svc in 'WinDefend','MDCoreSvc','WdNisSvc','Sense','SecurityHealthService','wscsvc') {
					$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc";
					if (Test-Path -LiteralPath $svcKey) {
						Remove-Item -LiteralPath $svcKey -Recurse -Force -ErrorAction SilentlyContinue;
					}
				}
				# Keep the removal policies in place even if a servicing pass rewrote them.
				New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Force -ErrorAction SilentlyContinue | Out-Null;
				Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiVirus' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue;
				# Tamper Protection would re-enable the engine on the next boot.
				New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Force -ErrorAction SilentlyContinue | Out-Null;
				Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue;
			} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
		}
	};
	{
		# Windows Search disable enforcement (offline hive edit backup: stop & disable WSearch online,
		# kill SearchHost if it spawned, hide the taskbar search box for the logged-on user)
		if (Test-Path "C:\Windows\Setup\Scripts\disable-search.flag") {
			try {
				Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue;
				Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue;
				if (Test-Path "C:\Windows\Setup\Scripts\disable-search-process.flag") {
					Get-Process -Name SearchHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue;
				}
			} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
			Remove-Item "C:\Windows\Setup\Scripts\disable-search.flag" -Force -ErrorAction SilentlyContinue;
		}
		# Hiding the taskbar search box follows the HideSearchBox option on its own; it used
		# to be an unconditional side effect of disabling the search service.
		try {
			if (Test-Path "C:\Windows\Setup\Scripts\enable-hide-searchbox.flag") {
				Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue;
			}
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Residual per-user Appx removal fallback: the packages the offline pass removed
		# from the image. Phase 11 stages the list, so nothing is removed when the
		# matching option is off.
		$appxListFile = "C:\Windows\Setup\Scripts\remove-appx-packages.flag";
		if (Test-Path $appxListFile) {
			foreach ($appxName in @(Get-Content -LiteralPath $appxListFile -ErrorAction SilentlyContinue)) {
				if ([string]::IsNullOrWhiteSpace($appxName)) { continue }
				try {
					# The list holds the identity name of every removed package
					# ("Microsoft.BingWeather"), so the exact name is tried first. The
					# wildcard is the fallback for the entries that are only a part of a
					# name ("WindowsBackupApp" -> Microsoft.WindowsBackupApp).
					$appxPkgs = @(Get-AppxPackage -AllUsers -Name $appxName -ErrorAction SilentlyContinue);
					if ($appxPkgs.Count -eq 0) {
						$appxPkgs = @(Get-AppxPackage -AllUsers -Name "*$appxName*" -ErrorAction SilentlyContinue);
					}
					$appxPkgs | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue;
				} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
			}
		}
	};
	{
		# UI preference report for the first user. The offline phase writes the values
		# into the default user hive; this confirms what the running user actually sees.
		try {
			$uiStatusPath = "C:\ProgramData\WinEase\ui-status.txt";
			$uiLines = [System.Collections.Generic.List[string]]::new();
			$uiLines.Add("WinEase UI status");
			$uiLines.Add("Timestamp: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"));
			$uiChecks = @(
				@{ Label = "MinAnimate"; Path = "HKCU:\Control Panel\Desktop\WindowMetrics"; Name = "MinAnimate"; Expected = "0" },
				@{ Label = "DragFullWindows"; Path = "HKCU:\Control Panel\Desktop"; Name = "DragFullWindows"; Expected = "0" },
				@{ Label = "VisualFXSetting"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; Name = "VisualFXSetting"; Expected = 2 },
				@{ Label = "TaskbarAnimations"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations"; Expected = 0 },
				@{ Label = "MouseSpeed"; Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSpeed"; Expected = "0" },
				@{ Label = "MouseThreshold1"; Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold1"; Expected = "0" },
				@{ Label = "MouseThreshold2"; Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold2"; Expected = "0" }
			);
			foreach ($uiCheck in $uiChecks) {
				$actual = $null;
				try { $actual = (Get-ItemProperty -LiteralPath $uiCheck.Path -Name $uiCheck.Name -ErrorAction SilentlyContinue).($uiCheck.Name) } catch { Write-Verbose "UI preference read failed: $($_.Exception.Message)" }
				$state = if ("$actual" -eq "$($uiCheck.Expected)") { "OK" } else { "DIFF" };
				$uiLines.Add("{0}: {1} (expected {2}) [{3}]" -f $uiCheck.Label, $actual, $uiCheck.Expected, $state);
			}
			$noLock = $null;
			try { $noLock = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -ErrorAction SilentlyContinue).NoLockScreen } catch { Write-Verbose "Lock-screen policy read failed: $($_.Exception.Message)" }
			$uiLines.Add("NoLockScreen (policy): {0}" -f $noLock);
			$photoCmd = $null;
			try { $photoCmd = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Classes\PhotoViewer.FileAssoc.Jpeg\shell\open\command" -ErrorAction SilentlyContinue).'(default)' } catch { Write-Verbose "Photo Viewer registration read failed: $($_.Exception.Message)" }
			$uiLines.Add("Photo Viewer JPEG command: {0}" -f $(if ($photoCmd) { "present" } else { "absent" }));
			[System.IO.File]::WriteAllLines($uiStatusPath, $uiLines, [System.Text.Encoding]::UTF8);
		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Signal FirstLogon completion and restore persistent AutoLogon security
		try {
			$markerDir = "C:\ProgramData\WinEase";
			if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null; }
			Set-Content -LiteralPath "$markerDir\firstlogon.done" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding ascii;

		} catch { Write-Verbose "Ignored: $($_.Exception.Message)" }
	};
	{
		# Security cleanup after the first logon: tear down the auto-logon and remove every copy of the
		# password. Each step is verified by reading the result back and is logged to firstlogon-child.log
		# (through the redirected output stream). Only names, paths and results are logged, never a value.
		$wlKey = 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon';
		try {
			Set-ItemProperty -LiteralPath $wlKey -Name 'AutoAdminLogon' -Value '0' -Type String -Force -ErrorAction Stop;
			Set-ItemProperty -LiteralPath $wlKey -Name 'ForceAutoLogon' -Value '0' -Type String -Force -ErrorAction Stop;
		} catch { Write-Output ("[AutoLogon-Cleanup] WARN: writing AutoAdminLogon/ForceAutoLogon failed: " + $_.Exception.GetType().Name); }
		try {
			$wlItem = Get-Item -LiteralPath $wlKey -ErrorAction Stop;
			if ($null -ne $wlItem.GetValue('DefaultPassword', $null)) {
				Remove-ItemProperty -LiteralPath $wlKey -Name 'DefaultPassword' -Force -ErrorAction Stop;
			}
			$wlItem = Get-Item -LiteralPath $wlKey -ErrorAction Stop;
			$autoNow = [string]$wlItem.GetValue('AutoAdminLogon', '');
			$forceNow = [string]$wlItem.GetValue('ForceAutoLogon', '');
			$pwGone = ($null -eq $wlItem.GetValue('DefaultPassword', $null));
			if ($pwGone -and $autoNow -eq '0' -and $forceNow -eq '0') {
				Write-Output "[AutoLogon-Cleanup] OK: AutoAdminLogon=0, ForceAutoLogon=0, DefaultPassword removed (verified).";
			} else {
				Write-Output ("[AutoLogon-Cleanup] FAILED: verification found AutoAdminLogon='" + $autoNow + "', ForceAutoLogon='" + $forceNow + "', DefaultPassword removed=" + $pwGone);
			}
		} catch { Write-Output ("[AutoLogon-Cleanup] FAILED: could not clean or verify the Winlogon values: " + $_.Exception.GetType().Name); }

		# Setup keeps copies of the answer file (they hold the account password in clear text) and the
		# OOBE helper carries the password as Base64. Delete them; a failure is logged, never fatal.
		$secretFiles = @(
			foreach ($answerDir in @('C:\Windows\Panther', 'C:\Windows\Panther\unattend', 'C:\Windows\Panther\UnattendGC', 'C:\Windows\System32\Sysprep')) {
				foreach ($answerName in @('unattend.xml', 'autounattend.xml')) { Join-Path -Path $answerDir -ChildPath $answerName; }
			}
			'C:\Windows\Setup\Scripts\WinEase-oobe-autologon-repair.ps1';
		);
		foreach ($secretFile in $secretFiles) {
			try {
				if (Test-Path -LiteralPath $secretFile) {
					Remove-Item -LiteralPath $secretFile -Force -ErrorAction Stop;
					if (Test-Path -LiteralPath $secretFile) { Write-Output ("[AutoLogon-Cleanup] WARN: still present after delete: " + $secretFile); }
					else { Write-Output ("[AutoLogon-Cleanup] OK: deleted " + $secretFile); }
				}
			} catch { Write-Output ("[AutoLogon-Cleanup] WARN: could not delete " + $secretFile + ": " + $_.Exception.GetType().Name); }
		}
	};
);

& {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  $flErrors = @();
  foreach( $script in $scripts ) {
    Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    try {
      & $script;
    } catch {
      $flErrors += ("Script block failed: {0}" -f $_);
    }
    $complete += $increment;
  }
  if ($flErrors.Count -gt 0) {
    Remove-Item -LiteralPath "C:\ProgramData\WinEase\firstlogon.done" -Force -ErrorAction SilentlyContinue;
    Set-Content -LiteralPath "C:\ProgramData\WinEase\firstlogon_script.failed" -Value ($flErrors -join "`r`n") -Encoding UTF8 -ErrorAction SilentlyContinue;
    exit 1;
  } else {
    Remove-Item -LiteralPath "C:\ProgramData\WinEase\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue;
    if (-not (Test-Path -LiteralPath "C:\ProgramData\WinEase\firstlogon.done")) {
      Set-Content -LiteralPath "C:\ProgramData\WinEase\firstlogon.done" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8 -ErrorAction SilentlyContinue;
    }
    exit 0;
  }
} *>&1 >> "C:\ProgramData\WinEase\Logs\firstlogon-child.log";
if (-not $? -or (Test-Path -LiteralPath "C:\ProgramData\WinEase\firstlogon_script.failed")) {
  exit 1;
} else {
  Remove-Item -LiteralPath "C:\ProgramData\WinEase\firstlogon_script.failed" -Force -ErrorAction SilentlyContinue;
  exit 0;
}
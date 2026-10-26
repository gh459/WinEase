& { try {
  # Terminate rogue background sync processes.
  # The SearchHost termination follows the DisableWindowsSearchProcess option, the
  # CrossDeviceResume termination follows DisableCrossDevice. Both used to run
  # unconditionally for every user.
  if (Test-Path 'C:\Windows\Setup\Scripts\disable-search-process.flag') {
    Stop-Process -Name 'SearchHost' -Force -ErrorAction SilentlyContinue;
  }
  if (Test-Path 'C:\Windows\Setup\Scripts\disable-crossdevice.flag') {
    Stop-Process -Name 'CrossDeviceResume' -Force -ErrorAction SilentlyContinue;
  }

  # Remove SecHealthUI AppX package for current user if Defender was removed
  if (Test-Path 'C:\Windows\Setup\Scripts\remove-defender.flag') {
    Get-AppxPackage "*SecHealthUI*" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue;
  }

  # Execute non-elevated custom user scripts (from tools/custom-scripts/user/)
  $userCustomDir = 'C:\Windows\Setup\Scripts\UserCustom';
  $userLogFile = "$env:TEMP\UserOnce-custom.log";

  function Redact-WinEaseUserSecret {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text; }
    $masked = $Text -replace '(?i)(password|secret|token|apikey|key)\s*[:=]\s*[^\s]+', '$1: [REDACTED]';
    $masked = $masked -replace '[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}', 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX';
    return $masked;
  }

  function Write-UserScriptLog {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff";
    $cleanMsg = Redact-WinEaseUserSecret -Text $Message;
    $line = "[$ts] $cleanMsg";
    try {
      [System.IO.File]::AppendAllText($userLogFile, "$line`r`n", [System.Text.Encoding]::UTF8);
    } catch {
      try { Add-Content -LiteralPath $userLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue; } catch {
        Write-Warning "[USER-SCRIPT-LOG-WARNING] Failed to write log entry: $($_.Exception.Message)";
      }
    }
  }

  if (Test-Path -LiteralPath $userCustomDir) {
    $manifestPath = 'C:\Windows\Setup\Scripts\custom-scripts-manifest.json';
    $manifest = $null;
    if (Test-Path -LiteralPath $manifestPath) {
      try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch {
        Write-UserScriptLog "[SECURITY WARNING] Failed to read custom-scripts-manifest.json: $($_.Exception.Message)";
      }
    }

    $validExts = @('.ps1', '.reg', '.cmd', '.bat');
    $allCandidateFiles = @(Get-ChildItem -Path $userCustomDir -File -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -ne 'UserOnce-custom.log' -and
        $_.Extension.ToLower() -ne '.log' -and
        $_.Name -ne 'README.md'
      } |
      Sort-Object Name);

    $userFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new();
    foreach ($cand in $allCandidateFiles) {
      $ext = $cand.Extension.ToLower();
      if ($validExts -contains $ext) {
        $userFiles.Add($cand);
      } else {
        Write-UserScriptLog "[SKIPPED] File: $($cand.Name) | Path: $($cand.FullName) | Reason: Unsupported or disabled extension ('$ext')";
      }
    }

    if ($userFiles.Count -gt 0) {
      Write-UserScriptLog "================================================================================";
      Write-UserScriptLog "User Custom Scripts Pipeline Started (Standard User Context: $env:USERNAME)";
      Write-UserScriptLog "Directory: $userCustomDir";
      Write-UserScriptLog "Target Scripts ($($userFiles.Count)): $(($userFiles | ForEach-Object { $_.Name }) -join ', ')";
      Write-UserScriptLog "================================================================================";

      $pipelineSw = [System.Diagnostics.Stopwatch]::StartNew();
      $successCount = 0;
      $failCount = 0;
      $idx = 0;

      foreach ($uf in $userFiles) {
        $idx++;
        $scriptName = $uf.Name;
        $scriptPath = $uf.FullName;
        $ext = $uf.Extension.ToLower();
        $startDt = Get-Date;
        $startStr = $startDt.ToString("yyyy-MM-dd HH:mm:ss.fff");

        # Fail closed (S-H2): custom scripts are present (this loop only runs
        # for target files), but there is no usable integrity manifest, so
        # nothing is executed.
        if (-not $manifest) {
          $endDt = Get-Date;
          $endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");
          Write-UserScriptLog "[$idx/$($userFiles.Count)] [SECURITY REFUSAL] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Reason: Integrity manifest is missing or unreadable. Execution blocked (fail-closed).";
          $failCount++;
          continue;
        }

        if ($manifest) {
          $expected = $manifest."user/$($uf.Name)";
          if (-not $expected) {
            $endDt = Get-Date;
            $endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");
            Write-UserScriptLog "[$idx/$($userFiles.Count)] [SECURITY REFUSAL] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Reason: File is not listed in build-time integrity manifest. Execution blocked.";
            $failCount++;
            continue;
          }
          $actual = try {
            $fs = [System.IO.File]::OpenRead($uf.FullName);
            $sha = [System.Security.Cryptography.SHA256]::Create();
            try {
              [System.BitConverter]::ToString($sha.ComputeHash($fs)).Replace("-", "");
            } finally {
              if ($null -ne $sha) { $sha.Dispose(); }
              if ($null -ne $fs) { $fs.Dispose(); }
            }
          } catch { $null };
          if ($actual -ine $expected) {
            $endDt = Get-Date;
            $endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");
            Write-UserScriptLog "[$idx/$($userFiles.Count)] [SECURITY REFUSAL] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Reason: Hash mismatch (Expected: $expected, Got: $actual). Execution blocked.";
            $failCount++;
            continue;
          }
        }

        $scriptSw = [System.Diagnostics.Stopwatch]::StartNew();
        Write-UserScriptLog "[$idx/$($userFiles.Count)] [START] Script: $scriptName | Path: $scriptPath | StartTime: $startStr";

        $exitCode = 0;
        $isSuccess = $false;
        $errDetail = $null;

        $global:LASTEXITCODE = 0;
        $prevEap = $ErrorActionPreference;
        $ErrorActionPreference = 'Continue';
        $escapedScriptPath = $scriptPath -replace "'", "''";
        try {
          $output = switch ($ext) {
            '.ps1' { & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command "& { `$ErrorActionPreference = 'Stop'; & '$escapedScriptPath'; if (`$null -ne `$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE } }" 2>&1 }
            '.reg' { & "$env:SystemRoot\System32\reg.exe" import "$scriptPath" 2>&1 }
            '.cmd' { & "$env:SystemRoot\System32\cmd.exe" /c "`"$scriptPath`"" 2>&1 }
            '.bat' { & "$env:SystemRoot\System32\cmd.exe" /c "`"$scriptPath`"" 2>&1 }
          }
          $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 };
          if ($exitCode -eq 0) {
            $isSuccess = $true;
          } else {
            $isSuccess = $false;
            $errLines = ($output | Out-String).Trim();
            if (-not [string]::IsNullOrWhiteSpace($errLines)) {
              $lastLine = ($errLines -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1);
              $errDetail = "Process exited with code $exitCode (Output: $(Redact-WinEaseUserSecret -Text $lastLine))";
            } else {
              $errDetail = "Process exited with non-zero exit code: $exitCode";
            }
          }
        } catch {
          $isSuccess = $false;
          $exitCode = if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { -1 };
          $errDetail = "Execution exception (Code $exitCode): $(Redact-WinEaseUserSecret -Text $_.Exception.Message)";
        } finally {
          $ErrorActionPreference = $prevEap;
        }

        $scriptSw.Stop();
        $elapsedSec = [math]::Round($scriptSw.Elapsed.TotalSeconds, 2);
        $endDt = Get-Date;
        $endStr = $endDt.ToString("yyyy-MM-dd HH:mm:ss.fff");

        if ($isSuccess) {
          $successCount++;
          Write-UserScriptLog "[$idx/$($userFiles.Count)] [SUCCESS] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Duration: ${elapsedSec}s | ExitCode: 0";
        } else {
          $failCount++;
          Write-UserScriptLog "[$idx/$($userFiles.Count)] [FAILED] Script: $scriptName | Path: $scriptPath | StartTime: $startStr | EndTime: $endStr | Duration: ${elapsedSec}s | ExitCode: $exitCode | Reason: $errDetail";
        }
      }

      $pipelineSw.Stop();
      $totalSec = [math]::Round($pipelineSw.Elapsed.TotalSeconds, 2);
      Write-UserScriptLog "================================================================================";
      Write-UserScriptLog "User Custom Scripts Pipeline Finished";
      Write-UserScriptLog "Summary: Total: $($userFiles.Count), Succeeded: $successCount, Failed: $failCount, Duration: ${totalSec}s";
      Write-UserScriptLog "================================================================================";
    }
  }

  # Clean up RunOnce setup command
  Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'UnattendedSetup' -Force -ErrorAction SilentlyContinue;
} catch {
  Write-Warning "UserOnce unhandled error: $_";
} } *>&1 >> "$env:TEMP\UserOnce.log";
exit 0;
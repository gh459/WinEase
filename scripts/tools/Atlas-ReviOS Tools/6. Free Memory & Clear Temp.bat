@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Free Memory & Clear Temp
echo ========================================================
echo Cleaning temporary files...
del /s /f /q "%TEMP%\*.*" >nul 2>&1
del /s /f /q "%SystemRoot%\Temp\*.*" >nul 2>&1
powershell.exe -NoProfile -Command "try { $sig = '[DllImport(\"psapi.dll\")] public static extern int EmptyWorkingSet(IntPtr h);'; Add-Type -MemberDefinition $sig -Name 'Mem' -Namespace 'Win32' -ErrorAction SilentlyContinue; Get-Process | ForEach-Object { try { [Win32.Mem]::EmptyWorkingSet($_.Handle) | Out-Null } catch {} }; [GC]::Collect(); Write-Host 'RAM working set trimmed successfully.' -ForegroundColor Green } catch {}"
echo Done.
pause
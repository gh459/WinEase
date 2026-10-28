@echo off
setlocal enabledelayedexpansion
title WinEase Control Center

:: Elevate with UAC administrator privileges if not already elevated
net session >nul 2>&1
if %errorlevel% neq 0 (
    set "SELF_PATH=%~f0"
    powershell.exe -NoProfile -Command "Start-Process cmd.exe -ArgumentList ('/c ' + [char]34 + $env:SELF_PATH + [char]34) -Verb RunAs"
    exit /b
)

:MENU
cls
echo ========================================================
echo                 WinEase Control Center
echo ========================================================
echo   [1] Toggle Windows Defender (Enable / Disable)
echo   [2] Toggle Windows Update   (Enable / Disable)
echo   [3] Toggle Hibernation      (Save RAM-sized GBs on SSD)
echo   [4] Toggle Bluetooth        (Enable / Disable Services)
echo   [5] Toggle Print Spooler    (Enable / Disable Service)
echo   [6] Free Memory ^& Clear Temp (Trim Working Sets ^& Temp)
echo   [7] Install Web Browser     (Chrome, Firefox, Brave...)
echo   [0] Exit
echo ========================================================
set /p choice="Select option [1-7, 0]: "
if "%choice%"=="1" goto DEFENDER
if "%choice%"=="2" goto WU
if "%choice%"=="3" goto HIBERNATE
if "%choice%"=="4" goto BLUETOOTH
if "%choice%"=="5" goto SPOOLER
if "%choice%"=="6" goto FREEMEM
if "%choice%"=="7" goto BROWSER
if "%choice%"=="0" exit /b
goto MENU

:DEFENDER
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service WinDefend -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Windows Defender...
    sc config WinDefend start= disabled >nul 2>&1
    sc stop WinDefend >nul 2>&1
    sc config WdNisSvc start= disabled >nul 2>&1
    sc stop WdNisSvc >nul 2>&1
    sc config Sense start= disabled >nul 2>&1
    sc stop Sense >nul 2>&1
    echo Windows Defender is now DISABLED.
) else (
    echo Enabling Windows Defender...
    sc config WinDefend start= auto >nul 2>&1
    sc start WinDefend >nul 2>&1
    sc config WdNisSvc start= demand >nul 2>&1
    sc start WdNisSvc >nul 2>&1
    sc config Sense start= demand >nul 2>&1
    sc start Sense >nul 2>&1
    echo Windows Defender is now ENABLED.
)
pause
goto MENU

:WU
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service wuauserv -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Windows Update...
    sc config wuauserv start= disabled >nul 2>&1
    sc stop wuauserv >nul 2>&1
    sc config UsoSvc start= disabled >nul 2>&1
    sc stop UsoSvc >nul 2>&1
    echo Windows Update is now DISABLED.
) else (
    echo Enabling Windows Update...
    sc config wuauserv start= auto >nul 2>&1
    sc start wuauserv >nul 2>&1
    sc config UsoSvc start= demand >nul 2>&1
    sc start UsoSvc >nul 2>&1
    echo Windows Update is now ENABLED.
)
pause
goto MENU

:HIBERNATE
echo.
if exist "%SystemDrive%\hiberfil.sys" (
    echo Disabling Hibernation and deleting hiberfil.sys...
    powercfg.exe /hibernate off
    echo Hibernation is now DISABLED.
) else (
    echo Enabling Hibernation...
    powercfg.exe /hibernate on
    echo Hibernation is now ENABLED.
)
pause
goto MENU

:BLUETOOTH
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service bthserv -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Bluetooth...
    sc config bthserv start= disabled >nul 2>&1
    sc stop bthserv >nul 2>&1
    sc config BthAvctpSvc start= disabled >nul 2>&1
    sc stop BthAvctpSvc >nul 2>&1
    echo Bluetooth is now DISABLED.
) else (
    echo Enabling Bluetooth...
    sc config bthserv start= auto >nul 2>&1
    sc start bthserv >nul 2>&1
    sc config BthAvctpSvc start= auto >nul 2>&1
    sc start BthAvctpSvc >nul 2>&1
    echo Bluetooth is now ENABLED.
)
pause
goto MENU

:SPOOLER
echo.
powershell.exe -NoProfile -Command "exit ((Get-Service Spooler -ErrorAction SilentlyContinue).Status -ne 'Running')" >nul 2>&1
if %errorlevel% equ 0 (
    echo Disabling Print Spooler...
    sc config Spooler start= disabled >nul 2>&1
    sc stop Spooler >nul 2>&1
    echo Print Spooler is now DISABLED.
) else (
    echo Enabling Print Spooler...
    sc config Spooler start= auto >nul 2>&1
    sc start Spooler >nul 2>&1
    echo Print Spooler is now ENABLED.
)
pause
goto MENU

:FREEMEM
echo.
echo Cleaning temporary files...
del /s /f /q "%TEMP%\*.*" >nul 2>&1
del /s /f /q "%SystemRoot%\Temp\*.*" >nul 2>&1
powershell.exe -NoProfile -Command "try { $sig = '[DllImport(\"psapi.dll\")] public static extern int EmptyWorkingSet(IntPtr h);'; Add-Type -MemberDefinition $sig -Name 'Mem' -Namespace 'Win32' -ErrorAction SilentlyContinue; Get-Process | ForEach-Object { try { [Win32.Mem]::EmptyWorkingSet($_.Handle) | Out-Null } catch {} }; [GC]::Collect(); Write-Host 'RAM working sets trimmed.' -ForegroundColor Green } catch {}"
echo Done.
pause
goto MENU

:BROWSER
start "" "%~dp0Install-Browser.cmd"
goto MENU
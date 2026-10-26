@echo off
setlocal
title WinEase Builder GUI

:: Fallback for source checkouts without WinEase.exe (built by tools\build-binaries.ps1). Same steps as the exe.

:: Resolve builder script (WinEasebuilder.ps1 or WinEasebuilder-*.ps1)
set "BUILDER=%~dp0WinEasebuilder.ps1"
if not exist "%BUILDER%" (
    for %%F in ("%~dp0WinEasebuilder-*.ps1") do set "BUILDER=%%~fF"
)
if not exist "%BUILDER%" (
    echo.
    echo ==============================================================================
    echo [ERROR] Builder script not found.
    echo Expected file: %~dp0WinEasebuilder.ps1
    echo ==============================================================================
    echo.
    pause
    exit /b 1
)

:: Build / refresh the WinUI 3 window (needs the .NET 8 SDK). -IfStale skips the build when the
:: published exe is newer than its sources, so this check runs on every launch: a stale exe would
:: silently run the GUI without every fix made since it was compiled.
where dotnet >nul 2>&1
if not errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui\winui\build.ps1" -IfStale
    if errorlevel 1 echo [WinEase] WinUI 3 build failed; the classic window will be used.
) else (
    if not exist "%~dp0gui\winui\bin\WinEaseGui.exe" echo [WinEase] .NET 8 SDK not found; using the classic window. Install it and run gui\winui\build.ps1 for the WinUI 3 window.
)

:: Check for admin privileges (net session)
net session >nul 2>&1
if %errorLevel% equ 0 goto :RUN

echo ==============================================================================
echo  WinEase Builder GUI - Windows 11 Image Customization Tool
echo ==============================================================================
echo.
echo [WinEase] Admin privileges required. Please approve the UAC prompt.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File """%BUILDER%""" -GUI' -Verb RunAs } catch { exit 1223 }"
set "ELEVATE_EXIT=%errorLevel%"

if %ELEVATE_EXIT% equ 1223 (
    echo.
    echo ==============================================================================
    echo [ERROR] Admin privileges were not granted (UAC cancelled).
    echo WinEase Builder requires administrator privileges to run.
    echo ==============================================================================
    echo.
    pause
    exit /b 1223
)
exit /b %ELEVATE_EXIT%

:RUN
cd /d "%~dp0"
title WinEase Builder - Windows 11 Image Customization Tool

echo ==============================================================================
echo  WinEase Builder GUI - Windows 11 Image Customization Tool
echo ==============================================================================
echo.
echo [WinEase] Target script: %BUILDER%
echo [WinEase] Opening graphical settings screen...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BUILDER%" -GUI
set "BUILD_EXIT=%errorLevel%"

if %BUILD_EXIT% neq 0 (
    echo.
    echo ==============================================================================
    echo [ERROR] WinEase builder exited with code %BUILD_EXIT%.
    echo Check the latest log file in the logs folder for details.
    echo ==============================================================================
    echo.
    pause
)
exit /b %BUILD_EXIT%
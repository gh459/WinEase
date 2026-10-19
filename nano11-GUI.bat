@echo off
setlocal
title nano11 Builder GUI

:: Resolve builder script (nano11builder.ps1 or nano11builder-*.ps1)
set "BUILDER=%~dp0nano11builder.ps1"
if not exist "%BUILDER%" (
    for %%F in ("%~dp0nano11builder-*.ps1") do set "BUILDER=%%~fF"
)
if not exist "%BUILDER%" (
    echo.
    echo ==============================================================================
    echo [ERROR] Builder script not found.
    echo Expected file: %~dp0nano11builder.ps1
    echo ==============================================================================
    echo.
    pause
    exit /b 1
)

:: Build the WinUI 3 window once (needs the .NET 8 SDK). Without it the builder shows the classic window.
if not exist "%~dp0gui\winui\bin\Nano11Gui.exe" (
    where dotnet >nul 2>&1
    if not errorlevel 1 (
        echo [nano11] Building the WinUI 3 window ^(first launch only^)...
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui\winui\build.ps1"
        if errorlevel 1 echo [nano11] WinUI 3 build failed; the classic window will be used.
    ) else (
        echo [nano11] .NET 8 SDK not found; using the classic window. Install it and run gui\winui\build.ps1 for the WinUI 3 window.
    )
)

:: Check for admin privileges (net session)
net session >nul 2>&1
if %errorLevel% equ 0 goto :RUN

echo ==============================================================================
echo  nano11 Builder GUI - Windows 11 Image Customization Tool
echo ==============================================================================
echo.
echo [nano11] Admin privileges required. Please approve the UAC prompt.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File """%BUILDER%""" -GUI' -Verb RunAs } catch { exit 1223 }"
set "ELEVATE_EXIT=%errorLevel%"

if %ELEVATE_EXIT% equ 1223 (
    echo.
    echo ==============================================================================
    echo [ERROR] Admin privileges were not granted (UAC cancelled).
    echo nano11 Builder requires administrator privileges to run.
    echo ==============================================================================
    echo.
    pause
    exit /b 1223
)
exit /b %ELEVATE_EXIT%

:RUN
cd /d "%~dp0"
title nano11 Builder - Windows 11 Image Customization Tool

echo ==============================================================================
echo  nano11 Builder GUI - Windows 11 Image Customization Tool
echo ==============================================================================
echo.
echo [nano11] Target script: %BUILDER%
echo [nano11] Opening graphical settings screen...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BUILDER%" -GUI
set "BUILD_EXIT=%errorLevel%"

if %BUILD_EXIT% neq 0 (
    echo.
    echo ==============================================================================
    echo [ERROR] nano11 builder exited with code %BUILD_EXIT%.
    echo Check the latest log file in the logs folder for details.
    echo ==============================================================================
    echo.
    pause
)
exit /b %BUILD_EXIT%
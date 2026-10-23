@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Windows Defender
echo ========================================================
sc query WinDefend | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Windows Defender...
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiVirus /t REG_DWORD /d 1 /f >nul 2>&1
    sc config WinDefend start= disabled >nul 2>&1
    sc stop WinDefend >nul 2>&1
    sc config WdNisSvc start= disabled >nul 2>&1
    sc stop WdNisSvc >nul 2>&1
    sc config Sense start= disabled >nul 2>&1
    sc stop Sense >nul 2>&1
    echo Windows Defender has been DISABLED.
) else (
    echo Enabling Windows Defender...
    reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /f >nul 2>&1
    reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiVirus /f >nul 2>&1
    sc config WinDefend start= auto >nul 2>&1
    sc start WinDefend >nul 2>&1
    sc config WdNisSvc start= demand >nul 2>&1
    sc start WdNisSvc >nul 2>&1
    sc config Sense start= demand >nul 2>&1
    sc start Sense >nul 2>&1
    echo Windows Defender has been ENABLED.
)
pause
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Windows Update
echo ========================================================
sc query wuauserv | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Windows Update...
    sc config wuauserv start= disabled >nul 2>&1
    sc stop wuauserv >nul 2>&1
    sc config UsoSvc start= disabled >nul 2>&1
    sc stop UsoSvc >nul 2>&1
    sc config WaaSMedicSvc start= disabled >nul 2>&1
    sc stop WaaSMedicSvc >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f >nul 2>&1
    echo Windows Update has been DISABLED.
) else (
    echo Enabling Windows Update...
    sc config wuauserv start= demand >nul 2>&1
    sc start wuauserv >nul 2>&1
    sc config UsoSvc start= demand >nul 2>&1
    sc start UsoSvc >nul 2>&1
    reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f >nul 2>&1
    echo Windows Update has been ENABLED.
)
pause
@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Bluetooth Services
echo ========================================================
sc query bthserv | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Disabling Bluetooth...
    sc config bthserv start= disabled >nul 2>&1
    sc stop bthserv >nul 2>&1
    sc config BthAvctpSvc start= disabled >nul 2>&1
    sc stop BthAvctpSvc >nul 2>&1
    echo Bluetooth services DISABLED.
) else (
    echo Enabling Bluetooth...
    sc config bthserv start= auto >nul 2>&1
    sc start bthserv >nul 2>&1
    sc config BthAvctpSvc start= auto >nul 2>&1
    sc start BthAvctpSvc >nul 2>&1
    echo Bluetooth services ENABLED.
)
pause
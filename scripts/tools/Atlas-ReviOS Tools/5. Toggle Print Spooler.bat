@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Print Spooler
echo ========================================================
sc query Spooler | find "RUNNING" >nul
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
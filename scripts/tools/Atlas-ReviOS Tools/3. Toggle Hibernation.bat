@echo off
setlocal
echo ========================================================
echo   Atlas/ReviOS Tool: Toggle Hibernation
echo ========================================================
if exist "%SystemDrive%\hiberfil.sys" (
    echo Disabling Hibernation and deleting hiberfil.sys...
    powercfg.exe /h off
    echo Hibernation is now DISABLED (Disk space freed).
) else (
    echo Enabling Hibernation...
    powercfg.exe /h on
    echo Hibernation is now ENABLED.
)
pause
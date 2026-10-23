@echo off
setlocal
title Windows Activation Status
echo ========================================================
echo   WinEase Tool: Windows Activation Status & Helper
echo ========================================================
echo Checking Windows license status...
cscript.exe //nologo %SystemRoot%\System32\slmgr.vbs /dli
echo.
echo To activate Windows with a legitimate digital product key:
echo   slmgr.vbs /ipk YOUR-PRODUCT-KEY
echo   slmgr.vbs /ato
echo.
pause
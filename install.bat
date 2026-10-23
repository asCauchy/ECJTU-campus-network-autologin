@echo off
setlocal EnableExtensions
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ============================================
echo  ECJTU Campus Net Auto-Login  (installer)
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0campus-setup.ps1"
if errorlevel 1 goto fail

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0campus-install-task.ps1"
if errorlevel 1 goto fail

echo.
echo Install finished. Config and logs are stored in this folder.
echo.
pause
exit /b 0

:fail
echo.
echo Installer stopped due to an error. See the messages above.
echo.
pause
exit /b 1

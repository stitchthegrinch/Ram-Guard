@echo off
setlocal
cd /d "%~dp0"

if not exist "Roblox_RAM_Guard_v7_5.ps1" (
    echo ERROR: Roblox_RAM_Guard_v7_5.ps1 was not found.
    echo Make sure you extracted the full ZIP before running this launcher.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Roblox_RAM_Guard_v7_5.ps1"
if errorlevel 1 (
    echo.
    echo Roblox RAM Guard exited with an error.
    pause
)

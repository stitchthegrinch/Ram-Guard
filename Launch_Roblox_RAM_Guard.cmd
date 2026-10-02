@echo off
cd /d "%~dp0"
if not exist "RobloxRAMGuard.ps1" (
  echo ERROR: RobloxRAMGuard.ps1 was not found next to this launcher.
  echo Extract the entire ZIP first, then run this file from the extracted folder.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0RobloxRAMGuard.ps1"
if errorlevel 1 (
  echo.
  echo Roblox RAM Guard closed with an error.
  pause
)

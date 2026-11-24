@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo [!] Run this file as Administrator.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ssh-windows.ps1" %*
echo.
pause

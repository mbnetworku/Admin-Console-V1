@echo off
REM Admin Console
REM Run as administrator: the portal starts by itself with Windows (scheduled task), for hosting on a server / behind IIS.
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tools\Install-Service.ps1"
echo.
pause

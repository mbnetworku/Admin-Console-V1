@echo off
REM Admin Console
REM Run once after copying or updating the tool: removes the 'downloaded from the internet' mark from the tool's files.
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tools\Allow-Tool.ps1"
echo.
pause

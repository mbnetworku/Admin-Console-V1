@echo off
REM Admin Console
REM Puts back a saved version (backups folder) when the tool does not start after an update. Runs as administrator.
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tools\Revert-Update.ps1"
pause

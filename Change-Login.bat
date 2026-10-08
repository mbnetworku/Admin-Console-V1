@echo off
REM Admin Console
cd /d "%~dp0"
REM Runs as local administrator by itself (Windows asks once). Forgot the password? Use Reset-Password.bat instead.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
echo Change the login used to open the Admin Console.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -ChangeLogin
pause

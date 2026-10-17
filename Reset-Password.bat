@echo off
REM Admin Console - the owner login goes back to admin / admin when the old password is forgotten (no old password needed).
cd /d "%~dp0"
REM Runs as local administrator by itself (Windows asks once): being administrator of this PC is the proof that you may reset it.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
echo Reset the owner login of the Admin Console to admin / admin. You do not need the old password.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -ResetLogin
pause

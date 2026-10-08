@echo off
REM Admin Console
cd /d "%~dp0"
echo Change the login used to open the Admin Console.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -ChangeLogin
pause

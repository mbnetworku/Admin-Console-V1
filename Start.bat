@echo off
REM Admin Console
cd /d "%~dp0"
set ST_SHOW=
if /i "%~1"=="window" set ST_SHOW=-ShowWindow
REM Runs as administrator by itself (Windows asks once), so the page is http://supporttool:8080.
REM Start.bat normal  = without administrator rights (page http://localhost:8080)
net session >nul 2>&1
if %errorlevel% neq 0 (
  if /i "%~1"=="normal" goto run
  if /i "%~2"=="normal" goto run
  if defined ST_SHOW (powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'window' -Verb RunAs") else (powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs")
  exit /b
)
:run
powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File" >nul 2>&1
echo Starting Admin Console...
REM The tool checks everything here, then restarts itself in the background with no window and opens the page.
REM Stop it with Shut down in the page. Start-Visible.bat keeps this window (for troubleshooting).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %ST_SHOW%
if errorlevel 1 pause

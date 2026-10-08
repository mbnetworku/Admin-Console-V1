@echo off
REM Admin Console
REM Same as Start.bat, but the tool keeps its PowerShell window open (like before v1.78.0) so you can see every message.
REM Use it only for troubleshooting - Start.bat runs the tool with no window.
call "%~dp0Start.bat" window

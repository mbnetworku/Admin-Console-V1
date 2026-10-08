# Allow-Tool.ps1 - run once per PC (through Allow-Tool.bat, as Administrator). version 1.98.44
# Removes the "downloaded from the internet" mark from every file of the tool, so Windows does not block or warn about the
# PowerShell files. Nothing is sent anywhere and nothing is installed.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # the tool's main folder (this file is in Tools)
Write-Host "Folder: $dir"
Get-ChildItem -Path $dir -Recurse -File | Unblock-File
Write-Host 'Done: all files unblocked.' -ForegroundColor Green

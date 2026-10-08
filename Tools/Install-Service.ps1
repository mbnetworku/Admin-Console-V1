# Install-Service.ps1 - run through Install-Service.bat (as Administrator).
# Makes the Admin Console start by itself when Windows starts (a Windows scheduled task "Admin Console"), so it keeps running
# on a server without anybody signed in - for example behind IIS for many people. Run it again to remove the task.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$server = Join-Path $root 'server.ps1'
$name = 'Admin Console'
Write-Host "Admin Console folder: $root" -ForegroundColor Cyan
$have = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if ($have) {
    Write-Host "The task '$name' exists (runs as $($have.Principal.UserId))."
    $a = Read-Host 'Type R to remove it, U to update it, or press Enter to stop'
    if ($a -match '^[Rr]') { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $name -Confirm:$false; Write-Host 'Removed. The portal no longer starts with Windows.' -ForegroundColor Green; return }
    if ($a -notmatch '^[Uu]') { return }
}
Write-Host ''
Write-Host 'Which Windows account should run the portal?' -ForegroundColor Cyan
Write-Host ' - Use a service account that is a local administrator of this server (for example CONTOSO\svc-adminconsole).'
Write-Host ' - Sign in once as that account and run Start-Visible.bat, so the Microsoft Graph and Exchange Online PowerShell'
Write-Host '   modules are installed for it, and Settings (mail sender, Microsoft app) are saved with its encryption.'
$cred = Get-Credential -Message 'Account that runs the Admin Console (DOMAIN\user)'
if (-not $cred) { return }
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$server`" -Background -NoBrowser" -WorkingDirectory $root
$trg = New-ScheduledTaskTrigger -AtStartup
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
if ($have) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Description 'Admin Console web portal (http://localhost:8080 - publish it with IIS)' | Out-Null
Write-Host "Done: '$name' starts with Windows as $($cred.UserName)." -ForegroundColor Green
$s = Read-Host 'Start it now? (Y/N)'
if ($s -match '^[Yy]') { Start-ScheduledTask -TaskName $name; Write-Host 'Started. Open http://localhost:8080 on this server (or your IIS address).' -ForegroundColor Green }

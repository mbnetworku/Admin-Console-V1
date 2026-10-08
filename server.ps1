# Screen: Server core (start-up, sessions, routing)
# Screen version: 2.10.2   (changes ONLY when this screen changes - not with every release)
# =====================================================================================================================
# WHAT THIS FILE IS: the CORE of the Admin Console. Everything starts here (Start.bat runs it with -Background).
# It does these jobs, in this order:
#   1. Start-up checks: port 8080 free?, old copy still running?, files present?, Microsoft Graph modules installed?, login set up?
#   2. Loads every screen file (backend\...\Screen-*.ps1). A screen only REGISTERS handlers: $ScreenHandlers['/api/xxx'] = { ... }.
#   3. Opens the web server (Net.HttpListener) on http://localhost:8080/ (or http://supporttool:8080/ when run as administrator),
#      and optionally HTTPS (Settings > HTTPS).
#   4. Runs the request loop: one request at a time, each request is loaded with the session of the person who sent it (cookie 'sid').
#   5. Handles the built-in routes itself: sign-in page (/login), main page (/), Microsoft/AD connect and sign-out, timeouts,
#      tab-closed, restart and shutdown. All other /api/ routes live in the Screen-*.ps1 files.
# Data/log files touched here: logs\startup-status.txt, logs\address.txt, logs\server-errors.txt, logs\login-audit-YYYY-MM.csv,
#   log-settings.json, app-defaults.json, shutdown.signal, the Windows hosts file (administrator only).
# Who may use it: anybody can open the sign-in page; every /api/ call needs the page token + a valid sign-in session, then the
#   permission check Get-ApiDenied (see Screen-Users.ps1).
# Switches: -ChangeLogin (change the owner login, asks for the old one), -ResetLogin (forgot it: set a NEW owner login, needs local administrator), -Background (no window), -ShowWindow (keep window), -NoBrowser, -Splash.
# =====================================================================================================================
param(
    [switch]$ChangeLogin,
    [switch]$ResetLogin,   # v2.11.9: Reset-Password.bat - new owner login without the old one (only as local administrator)
    [switch]$Background,   # started by itself with no window (the normal way since v1.78.0)
    [switch]$ShowWindow,   # Start-Visible.bat: keep this PowerShell window, like before (for troubleshooting)
    [switch]$NoBrowser,    # v1.98.41: restarted from the page - the browser tab is already open
    [switch]$Splash        # started by SupportTool.exe: it shows the start-up progress, so no message boxes from here
)
# Stop on the first error (so try/catch works); the Root folder is where this script lives (all other paths are built from it).
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
# ---- Start-up progress (see the next lines): the SupportTool start window reads this text file to show the steps ----
# ---- Start-up progress for the SupportTool.exe window: logs\startup-status.txt, one line per step ----
#   STEP|id|state|label|detail   (state: wait, run, ok, warn, fail)   and at the end   DONE|url   or   ERROR|message   or   SETUP|message
$script:StartFile = Join-Path (Join-Path $Root 'logs') 'startup-status.txt'
$script:StartSteps = [ordered]@{}; $script:StartEnd = ''
# Writes the whole start-up progress to logs\startup-status.txt. It writes a .tmp file first and then renames it, so the reader never
# sees a half-written file. Errors are ignored on purpose (progress display must never stop the start).
function Write-StartFile {
    try {
        New-Item -ItemType Directory -Force (Split-Path $script:StartFile) | Out-Null
        $lines = @("PID|$PID") + @($script:StartSteps.Values | ForEach-Object { 'STEP|{0}|{1}|{2}|{3}' -f $_.id, $_.state, $_.label, ("$($_.detail)" -replace '[\r\n|]+', ' ') })
        if ($script:StartEnd) { $lines += $script:StartEnd }
        $tmp = "$($script:StartFile).tmp"; [IO.File]::WriteAllLines($tmp, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
        Move-Item -Path $tmp -Destination $script:StartFile -Force
    } catch {}
}
# Sets/updates one step of the start-up progress: id = step key, state = wait|run|ok|warn|fail, label = text shown, detail = small text.
function Set-Start([string]$id, [string]$state, [string]$label, [string]$detail = '') {
    if (-not $script:StartSteps.Contains($id)) { $script:StartSteps[$id] = @{ id = $id; label = $label } }
    $st = $script:StartSteps[$id]; $st.state = $state; if ($label) { $st.label = $label }; $st.detail = $detail
    Write-StartFile
}
# Writes the final line of the progress file (DONE|url, ERROR|message or SETUP|message).
function Set-StartEnd([string]$line) { $script:StartEnd = $line; Write-StartFile }
# Version of the whole tool and its release date (shown on the page and in the logs). Each screen also has its own version in its header.
$AppVersion = '2.11.12'; $AppDate = '2026-10-08'
# Detect files copied from different versions: index.html and login.html must carry the same version stamp as this script
$script:VerNote = ''
# The screens that are loaded at start-up: 'Security' means the file Screen-Security.ps1 (its folder comes from $script:CodeDir below).
$ScreenFiles = 'Security', 'Updates', 'AppSetup', 'MailboxCleanup', 'Intune', 'OneDrive', 'Sessions', 'People', 'AddressList', 'Https', 'Sso', 'CloudPassword', 'AccountStatus', 'RevokeMfa', 'Licenses', 'OnPremAd', 'AdCreate', 'BulkCsv', 'ExportReport', 'TeamsMembers', 'DistGroups', 'SharedMailbox', 'Accounts', 'MsLogin', 'GuestUsers', 'AuditLogs', 'EmailTemplates', 'Settings', 'Users', 'OuReport', 'GuestReport'
# Code folders (v2.7.0): frontend\ (the pages) and backend\ (Portal = sign-in, settings, logs; Microsoft365; ActiveDirectory; ExchangeOnline), docs\ (all .md files), Tools\.
# server.ps1, the .bat files and the data files stay in this folder.
# Which code folder each screen file lives in (Screen name -> folder). Used by Get-CodePath.
$script:CodeDir = @{
    'AppSetup' = 'backend\Portal'; 'MailboxCleanup' = 'backend\ExchangeOnline'; 'Intune' = 'backend\Microsoft365'; 'OneDrive' = 'backend\Microsoft365'; 'CloudPassword' = 'backend\Microsoft365'; 'AccountStatus' = 'backend\Microsoft365'; 'RevokeMfa' = 'backend\Microsoft365'; 'TeamsMembers' = 'backend\Microsoft365'; 'GuestUsers' = 'backend\Microsoft365'; 'MsLogin' = 'backend\Microsoft365'; 'AuditLogs' = 'backend\Microsoft365'
    'Licenses' = 'backend\Microsoft365'; 'AdCreate' = 'backend\ActiveDirectory'; 'OnPremAd' = 'backend\ActiveDirectory'; 'BulkCsv' = 'backend\ActiveDirectory'; 'ExportReport' = 'backend\ActiveDirectory'; 'OuReport' = 'backend\ActiveDirectory'; 'GuestReport' = 'backend\Microsoft365'; 'Accounts' = 'backend\ActiveDirectory'
    'DistGroups' = 'backend\ExchangeOnline'; 'SharedMailbox' = 'backend\ExchangeOnline'; 'AddressList' = 'backend\ExchangeOnline'
    'Settings' = 'backend\Portal'; 'Security' = 'backend\Portal'; 'Updates' = 'backend\Portal'; 'Sessions' = 'backend\Portal'; 'Users' = 'backend\Portal'; 'People' = 'backend\Portal'; 'Https' = 'backend\Portal'; 'Sso' = 'backend\Portal'; 'EmailTemplates' = 'backend\Portal'
}
# Returns the full path of a code file: Screen-X.ps1 -> backend\<group>\, *.html -> frontend\, ActivityLog.ps1 -> backend\Portal\,
# anything else stays in the main folder. Input: file name. Output: full path.
function Get-CodePath([string]$file) {
    $n = $file
    if ($file -match '^Screen-(.+)\.ps1$') { $d = $script:CodeDir[$Matches[1]] } elseif ($file -match '\.html$') { $d = 'frontend' } elseif ($file -eq 'ActivityLog.ps1') { $d = 'backend\Portal' } elseif ($file -eq 'DistGroups-Worker.ps1') { $d = 'backend\ExchangeOnline' } else { $d = '' }
    if ($d) { Join-Path (Join-Path $Root $d) $n } else { Join-Path $Root $n }
}
# Clean-up after an update: old loose files from older versions are MOVED to '_old files (can be deleted)' - never deleted.
# Updating by copying the new zip over an old folder leaves the old loose code files in this folder: move them aside (never deleted)
try {
    $oldDir = Join-Path $Root '_old files (can be deleted)'
    # v1.98.44: the .exe files are no longer part of the tool (start it with Start.bat)
    foreach ($ox in @(Get-ChildItem $Root -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'SupportTool.exe', 'SupportTool-Stop.exe', 'exe-source' })) { New-Item -ItemType Directory -Force $oldDir | Out-Null; Move-Item $ox.FullName (Join-Path $oldDir $ox.Name) -Force -ErrorAction SilentlyContinue }
    foreach ($of in @(Get-ChildItem $Root -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Screen-*.ps1' -or $_.Name -in 'ActivityLog.ps1', 'DistGroups-Worker.ps1', 'index.html', 'login.html', 'Allow-Tool.ps1' })) {
        $np = if ($of.Name -eq 'Allow-Tool.ps1') { Join-Path $Root 'Tools\Allow-Tool.ps1' } else { Get-CodePath $of.Name }
        if ($np -ne $of.FullName -and (Test-Path $np)) { New-Item -ItemType Directory -Force $oldDir | Out-Null; Move-Item $of.FullName (Join-Path $oldDir $of.Name) -Force -ErrorAction SilentlyContinue }
    }
} catch {}
# v2.7.0: the code moved into frontend\ and backend\. When this folder still has the old code folders (web, Portal, Microsoft365, ...)
# from an older version, they are moved aside (never deleted) so only one copy of the code is left.
try {
    if ((Test-Path (Join-Path $Root 'backend\Portal\ActivityLog.ps1')) -and (Test-Path (Join-Path $Root 'frontend\index.html'))) {
        $oldDir = Join-Path $Root '_old files (can be deleted)'
        foreach ($od in 'web', 'Portal', 'Microsoft365', 'ExchangeOnline', 'ActiveDirectory') {
            $op = Join-Path $Root $od
            if (Test-Path -LiteralPath $op -PathType Container) { New-Item -ItemType Directory -Force $oldDir | Out-Null; $dn = Join-Path $oldDir $od; if (Test-Path $dn) { $dn = $dn + '-' + (Get-Date -Format 'yyyyMMddHHmmss') }; Move-Item -LiteralPath $op -Destination $dn -Force -ErrorAction SilentlyContinue }
        }
        foreach ($omd in 'CHANGELOG.md', 'TECHNICAL-DOCUMENTS.md') { $op = Join-Path $Root $omd; if (Test-Path -LiteralPath $op) { New-Item -ItemType Directory -Force $oldDir | Out-Null; Move-Item -LiteralPath $op -Destination (Join-Path $oldDir $omd) -Force -ErrorAction SilentlyContinue } }
    }
} catch {}
# v2.8.0: every screen has its OWN version, written in its header ("# Screen version: x.y.z"). It changes only when THAT screen changes,
# so files from different releases live side by side without any error. Only a MISSING file is reported here.
# Reads the screen NAME and VERSION from the header text of a code file ("Screen: ..." and "Screen version: x.y.z").
# Input: the first lines of the file as text. Output: @{ name; version }. The regex stops the name at '|', '-->' or end of line.
function Get-UnitMeta([string]$text) {
    $n = [regex]::Match($text, 'Screen:\s*([^|\r\n]+?)\s*(?:\||-->|\r|\n|$)'); $v = [regex]::Match($text, 'Screen version:\s*([0-9][0-9.]*)')
    @{ name = $(if ($n.Success) { $n.Groups[1].Value.Trim() } else { '' }); version = $(if ($v.Success) { $v.Groups[1].Value } else { '' }) }
}
# the list of every code unit (screens, shared pieces, pages) with its version, read from the headers of the files on disk
# Lists every code file of the tool (screens, activity log, pages, server.ps1) with its name, version and whether it exists on disk.
# Reads only the first 12 lines of each file (the header).
function Get-InstalledUnits {
    $list = @()
    $files = @($ScreenFiles | ForEach-Object { "Screen-$_.ps1" }) + @('ActivityLog.ps1', 'DistGroups-Worker.ps1', 'index.html', 'login.html')
    foreach ($f in $files) {
        $p = Get-CodePath $f; $m = @{ name = ''; version = '' }; $ok = Test-Path $p
        if ($ok) { try { $m = Get-UnitMeta ((Get-Content $p -TotalCount 12 -Encoding UTF8) -join "`n") } catch {} }
        $list += [pscustomobject]@{ file = $f; name = $(if ($m.name) { $m.name } else { $f }); version = "$($m.version)"; present = $ok }
    }
    $sm = @{ name = ''; version = '' }; try { $sm = Get-UnitMeta ((Get-Content $PSCommandPath -TotalCount 12 -Encoding UTF8) -join "`n") } catch {}
    $list += [pscustomobject]@{ file = 'server.ps1'; name = $(if ($sm.name) { $sm.name } else { 'server.ps1' }); version = "$($sm.version)"; present = $true }
    $list
}
try {
    # Check that no file is missing; only a missing file is reported (different versions side by side are fine).
    $miss = @(Get-InstalledUnits | Where-Object { -not $_.present } | ForEach-Object { $_.file })
    if ($miss.Count) { $script:VerNote = 'Missing files: ' + ($miss -join ', ') + '. Copy every file and folder from the zip into the same folder.' }
} catch { $script:VerNote = "Could not check the file versions: $($_.Exception.Message)" }
# A problem that stops the tool. With no window (Background) it is shown in a Windows message box and kept in logs\server-errors.txt.
# Stops the tool because of a problem that cannot be fixed by itself: shows it on screen, writes it to logs\server-errors.txt,
# tells the start window (ERROR|...) and, when running without a window, shows a Windows message box. Then exit code 1.
function Stop-Fatal([string]$msg) {
    Write-Host $msg -ForegroundColor Red
    try { $ld = Join-Path $Root 'logs'; New-Item -ItemType Directory -Force $ld | Out-Null; ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) | Add-Content -Path (Join-Path $ld 'server-errors.txt') -Encoding UTF8 } catch {}
    Set-StartEnd "ERROR|$($msg -replace '[\r\n|]+', ' ')"
    if ($Background -and -not $Splash) { try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($msg, 'Admin Console', 'OK', 'Error') } catch {} }
    exit 1
}
# Start-up step 1 (files): ok = all files found, warn = something missing.
$fileNote = if ($script:VerNote) { $script:VerNote } else { "v$AppVersion - $(@(Get-InstalledUnits).Count) parts, each with its own version" }
Set-Start 'files' $(if ($script:VerNote) { 'warn' } else { 'ok' }) 'Admin Console files' $fileNote
Set-Start 'port' 'run' "Port $Port" 'checking...'
# Fixed port, so the address never changes (change the number here if you need another one); the token stops other web pages from calling the API
# STEP: PORT CHECK. The port is fixed so the address never changes. (Change the number here if you need another one.)
$Port = 8080
# Try to open the port for a moment. If that works, the port is free. If it fails, something already uses it - see the catch below:
# either another copy of this tool (we then stop it or just open its page) or another program (fatal error).
try { $tmp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port); $tmp.Start(); $tmp.Stop() }
catch {
    # Already running (it has no window now)?
    # Ask the program on the port for its page: if it contains 'Support Tool' or 'Admin Console' it is our own tool (and we read its version).
    $mine = $false; $runVer = ''
    try { $pg0 = (Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 4).Content; $mine = ($pg0 -match 'Support Tool|Admin Console'); $mv = [regex]::Match($pg0, 'name="app-version" content="([^"]+)"'); $runVer = if ($mv.Success) { $mv.Groups[1].Value } else { 'old' } } catch {}
    if (-not $mine) { Stop-Fatal "Port $Port is already in use by another program. Close it and start again, or change the port number near the top of server.ps1." }
    # Are WE running as administrator? Needed to restart the old copy so that it uses the friendly address http://supporttool.
    $adm0 = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $runAddr = ''; try { $runAddr = (Get-Content (Join-Path $Root 'logs\address.txt') -Raw -ErrorAction Stop).Trim() } catch {}
    # v1.97.3: an older (or newer) version still running in the background - possibly from another folder - is stopped, so the page always shows THESE files
    # $otherVer = true when the tool that is running has a different version than these files.
    $otherVer = ($runVer -and $runVer -ne $AppVersion)
    if ($otherVer) { Write-Host "Version $runVer of the tool is still running - stopping it and starting v$AppVersion." -ForegroundColor Yellow }
    if ($otherVer -or ($adm0 -and $runAddr -notmatch '^http://supporttool:')) {
        # the running tool was started normally (http://localhost) and this start is as administrator: restart it, so it uses http://supporttool
        Set-Start 'port' 'run' "Port $Port" $(if ($otherVer) { "stopping version $runVer that is still running..." } else { 'restarting the tool that runs without administrator rights...' })
        # Ask the running copy to shut down: it checks for shutdown.signal once per second (see the request loop at the end of this file).
        'restart' | Set-Content -Path (Join-Path $Root 'shutdown.signal') -ErrorAction SilentlyContinue
        $free = $false
        # Wait up to 12 seconds for the port to become free.
        for ($i = 0; $i -lt 12 -and -not $free; $i++) {
            Start-Sleep -Milliseconds 1000
            try { $t2 = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port); $t2.Start(); $t2.Stop(); $free = $true } catch {}
        }
        if (-not $free) {   # it did not answer the stop request (an older version, another folder, or stuck): close its PowerShell by the port - we are administrator, so we may
            try {
                foreach ($c in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)) {
                    $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                    if ($pr -and $pr.ProcessName -match '^(powershell|pwsh)') { Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue }
                }
            } catch {}
            for ($i = 0; $i -lt 8 -and -not $free; $i++) { Start-Sleep -Milliseconds 1000; try { $t2 = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port); $t2.Start(); $t2.Stop(); $free = $true } catch {} }
        }
        Remove-Item (Join-Path $Root 'shutdown.signal') -Force -ErrorAction SilentlyContinue
        if (-not $free -and $otherVer) { Stop-Fatal "Version $runVer of the Admin Console is still running and did not stop. Use Session > Shut down in its page (or restart the PC), then start v$AppVersion again." }
        if (-not $free) { Stop-Fatal 'The tool is running without administrator rights and did not stop. Use Session > Shut down in its page, then start it again as administrator.' }
    } else {
        # Same version already running and nothing to change: just open its page (the rest of the line shows it and ends this script).
        $openUrl = if ($adm0 -and $runAddr) { $runAddr } else { "http://localhost:$Port/" }
        Write-Host 'The Admin Console is already running - opening it.' -ForegroundColor Cyan; Set-Start 'port' 'ok' "Port $Port" 'the tool is already running'; Set-StartEnd "DONE|$openUrl|already"; Start-Process $openUrl; exit 0
    }
}
# Port is ours now.
Set-Start 'port' 'ok' "Port $Port" 'free'
# v1.97.4: the port changed from 8765 to 8080 - an older copy of the tool still running on 8765 is stopped (best effort), so only one copy runs
try {
    # Best effort: stop an old copy that still runs on the previous port 8765 (errors are ignored).
    $op = (Invoke-WebRequest -Uri 'http://localhost:8765/' -UseBasicParsing -TimeoutSec 3).Content
    if ($op -match 'Support Tool|Admin Console') {
        Write-Host 'An older copy of the Admin Console is still running on port 8765 - stopping it.' -ForegroundColor Yellow
        foreach ($c in @(Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue)) {
            $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($pr -and $pr.ProcessName -match '^(powershell|pwsh)') { Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue }
        }
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and "$($_.CommandLine)" -match '"?([^"]*\\)server\.ps1' -and ((Test-Path (Join-Path $Matches[1] 'Screen-GuestUsers.ps1')) -or (Test-Path (Join-Path $Matches[1] 'Microsoft365\Screen-GuestUsers.ps1'))) } | ForEach-Object {
            try { $t8 = (Invoke-WebRequest -Uri 'http://localhost:8765/' -UseBasicParsing -TimeoutSec 2).Content } catch { $t8 = '' }
            if ($t8 -match 'Support Tool|Admin Console') { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }
} catch {}
# Random token created at every start. The page gets it (__TOKEN__) and must send it in the X-Token header of every /api/ call,
# so a different web page in the browser cannot call the API.
$Token = [guid]::NewGuid().ToString('N')
$StopFile = Join-Path $Root 'shutdown.signal'   # written by SupportTool-Stop.exe
# shutdown.signal exists (written by the stop program or by a newer copy that wants the port): shut down cleanly.
if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }   # an old request must not stop this new start
# Log folder (can be moved by Settings > Log settings, see the next block).
$LogDir = Join-Path $Root 'logs'; New-Item -ItemType Directory -Force $LogDir | Out-Null
$DefaultLogDir = $LogDir; $script:LogTz = ''; $script:LogTzMode = 'device'
# Log settings (screen Log settings): where the logs are kept on this PC, and which time zone the log times use
try {
    # Read log-settings.json: tzMode/tz = fixed time zone for log times; localDir = another folder for the logs (local drive or UNC path).
    $lcf = Join-Path $Root 'log-settings.json'
    if (Test-Path $lcf) {
        $lc = Get-Content $lcf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($lc.tzMode)" -eq 'fixed' -and "$($lc.tz)" -match '^[A-Za-z0-9_/+-]{1,40}$') { $script:LogTzMode = 'fixed'; $script:LogTz = "$($lc.tz)" }
        if ("$($lc.localDir)" -match '^([A-Za-z]:\\|\\\\)') { New-Item -ItemType Directory -Force "$($lc.localDir)" -ErrorAction Stop | Out-Null; $LogDir = "$($lc.localDir)".TrimEnd('\') }
    }
} catch { Write-Host "Log settings were not applied: $($_.Exception.Message)" -ForegroundColor Yellow }
# The Microsoft Graph PowerShell modules this tool needs (all are installed in the SAME version, see Initialize-Graph).
$Mods = 'Microsoft.Graph.Authentication','Microsoft.Graph.Users','Microsoft.Graph.Identity.SignIns','Microsoft.Graph.Identity.DirectoryManagement'
# Front-end sign-in: only SALTED HASHES of the username and password are stored, inside this script (next line).
# The hashes cannot be turned back into the password, and nothing is saved anywhere else on the PC.
# To change the login, run Change-Login.bat - it rewrites the next line.
$EmbeddedAuth = '{"v":1,"it":100000,"us":"ekFZyA8ppEXEFAIJIojTBQ==","uh":"uzYHysQJMMQunIttZ04gaPzCC/rAnf6WSDrC+wEKvVA=","ps":"zYfWKGcUWyx+GfCtjFEjSA==","ph":"JnyBwqkEjEUHx0n//BZDd0Fk1cwrPwM/Psnh8waoftk="}'
# Owner login data (decoded from the line above) and the old file location that is removed on start-up.
$script:Auth = $null
$OldAuthFile = Join-Path (Join-Path $env:LOCALAPPDATA 'PasswordResetTool') 'auth.dat'
# Default values of the per-person state: on-premises AD sign-in (AdCred = typed account, kept in memory only), Microsoft sign-in,
# tool-login session and login lockout counters. With several people these are swapped in and out per request (see Use-Sess).
$script:AdCred = $null; $script:AdLast = Get-Date; $script:AdFails = 0; $script:AdLockUntil = [datetime]::MinValue; $script:AdIdleMins = 30; $script:AdAutoMins = 0; $script:AdLogoutAt = $null
$script:Session = $null; $script:LoginFails = 0; $script:LoginLockUntil = [datetime]::MinValue
# v1.98.11: 5 wrong passwords lock THAT username for 15 minutes (other people can still sign in) - see Screen-Users.ps1
$script:LoginMaxFails = 5; $script:LoginLockMins = 15
# The front-door login ends after 30 minutes without use, or 8 hours after signing in (whichever comes first). Ending it also closes the Microsoft and on-premises sign-ins.
$script:SessStart = [datetime]::MinValue; $script:SessLast = [datetime]::MinValue; $script:SessIdleMins = 30; $script:SessMaxHours = 8
$script:WhoUpn = $null; $script:WhoSam = $null; $script:WhoSynced = $false; $script:WhoDom = $null
$script:Who = $null; $script:Dom = @{}; $script:LogoutAt = $null; $script:AutoMins = 0; $script:WhoName = $null


# =====================================================================================================================
# v2.0.0 MULTI-USER: every signed-in person has their OWN session - their own Microsoft sign-in, their own on-premises AD
# sign-in, their own Exchange Online connection, timers and passwords waiting to be e-mailed. The server handles one request
# at a time; before each request the state of THAT person's session is loaded into the variables the screens use, and saved
# back afterwards. Microsoft Graph has one connection per process, so it is switched to the right person when needed.
# =====================================================================================================================
# The session store: session id (the random value in the 'sid' cookie) -> hashtable with that person's saved variables.
$script:Sessions = @{}          # sid -> state of that session
# There is only ONE Microsoft Graph connection per process, so we remember which session it currently belongs to.
$script:GraphSid = $null        # whose Microsoft Graph connection is loaded right now
# Names of all script variables that belong to ONE person's session. Use-Sess loads them, Save-Sess stores them back.
# Groups: tool login (Session*), Microsoft sign-in (Who*, Ms*, Spo*), AD sign-in (Ad*), timers, search options, Exchange/distribution-group jobs.
$script:PerSess = @('MsOld', 'Session', 'SessUser', 'SessStart', 'SessLast', 'SessIp', 'SessPc', 'SessUa',
    'Who', 'WhoUpn', 'WhoName', 'WhoSam', 'WhoDisp', 'WhoSynced', 'WhoDom', 'WhoFirst', 'WhoLast', 'CertInfo',
    'SpoAdmin', 'SpoTok', 'SpoExp', 'SpoRefresh', 'SpoClient', 'SpoDev', 'MsRefresh', 'MsExp', 'MsScopes', 'MsTenant', 'MsNote', 'MsErr', 'MsTokFail', 'MsRepairAt', 'MsAccess', 'MsClient', 'MsSecret', 'MsPublicOnly', 'MsDev',
    'LogoutAt', 'AutoMins', 'Dom', 'ResetSecrets',
    'AdCred', 'AdLogoutAt', 'AdAutoMins', 'AdLast', 'AdInfo', 'AdFails', 'AdLockUntil', 'AdNote',
    'CloseAt', 'CloseAct', 'TmNames', 'TmWho', 'FindFields', 'FindVia', 'ReportVia',
    'DgAutoFor', 'DgPid', 'DgJobs', 'MbxJobs')
# The 'empty' value of every PerSess variable, taken once at start (Save-SessDefaults). New sessions start from these.
$script:SessDefaults = @{}
# Remember the current (empty) values of all PerSess variables as the defaults.
function Save-SessDefaults {
    foreach ($n in $script:PerSess) { $v = Get-Variable -Scope Script -Name $n -ValueOnly -ErrorAction SilentlyContinue; $script:SessDefaults[$n] = $v }
}
# Gives a fresh empty copy of the default for variable $n. Hashtables must be new objects, otherwise two sessions would share one.
function New-SessValue($n) {
    $v = $script:SessDefaults[$n]
    if ($v -is [System.Collections.Specialized.OrderedDictionary]) { return [ordered]@{} }
    if ($v -is [hashtable]) { return @{} }
    if ($n -eq 'AdLast') { return Get-Date }
    $v
}
# load the variables of one session (or the empty defaults when $sid is not a live session)
# Load a session: copies the saved values of session $sid into the script variables the screens use.
# $sid empty/unknown = 'nobody signed in' (all defaults). Called before every request and for every timer check.
function Use-Sess($sid) {
    $st = if ($sid) { $script:Sessions[$sid] } else { $null }
    foreach ($n in $script:PerSess) { Set-Variable -Scope Script -Name $n -Value $(if ($st -and $st.ContainsKey($n)) { $st[$n] } else { New-SessValue $n }) }
    if (Get-Command Set-DgPaths -ErrorAction SilentlyContinue) { Set-DgPaths }
}
# store the variables back into the session they belong to (a session that was ended is removed)
# Store the script variables back into the session they belong to (end of every request).
#  - if $sid is no longer the current session (logout, timeout, replaced by a new sign-in) the old session is deleted;
#  - a sign-in that failed halfway (no SessUser) is deleted, so no half-built session stays behind.
function Save-Sess($sid) {
    $cur = $script:Session
    if ($sid -and $sid -ne $cur) { $script:Sessions.Remove($sid) }   # logged out, timed out or replaced by a new sign-in
    if ($cur -and -not $script:SessUser) { $script:Sessions.Remove($cur); return }   # a sign-in that failed half-way never leaves a session behind
    if ($cur) { $st = @{}; foreach ($n in $script:PerSess) { $st[$n] = Get-Variable -Scope Script -Name $n -ValueOnly -ErrorAction SilentlyContinue }; $script:Sessions[$cur] = $st }
}
# a new sign-in always starts from an empty state, never from the state of the session that was loaded before
# Set every PerSess variable to its empty default. A new sign-in always starts from an empty state.
function Reset-SessVars { foreach ($n in $script:PerSess) { Set-Variable -Scope Script -Name $n -Value (New-SessValue $n) }; if (Get-Command Set-DgPaths -ErrorAction SilentlyContinue) { Set-DgPaths } }
# Microsoft Graph: make sure the connection is the one of the loaded session (or no connection at all)
# Make the one shared Microsoft Graph connection belong to the loaded person: if nobody is signed in to Microsoft it is disconnected;
# if another person's connection is loaded, it is re-created from THIS person's saved token (refresh token, old sign-in token or certificate).
function Use-SessGraph {
    if (-not $script:Who) {
        if ($script:GraphSid) { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}; $script:GraphSid = $null }
        return
    }
    if ($script:GraphSid -eq $script:Session -and $script:Session) { return }
    try {
        if ($script:MsRefresh) {
            if ($script:MsAccess -and $script:MsExp -and (Get-Date) -lt $script:MsExp.AddMinutes(-3)) { Connect-MsToken $script:MsAccess }
            else { Update-MsToken -Force }
        } elseif ($script:MsOld -and $script:MsAccess -and $script:MsExp -and (Get-Date) -lt $script:MsExp) { Connect-MsToken $script:MsAccess
        } elseif ($script:CertInfo -and $script:CertInfo.Thumb) {
            Connect-MgGraph -TenantId $script:CertInfo.Tenant -ClientId $script:CertInfo.AppId -CertificateThumbprint $script:CertInfo.Thumb -NoWelcome
        } else { throw 'no token' }
        $script:GraphSid = $script:Session
    } catch {
        $script:GraphSid = $null
        Write-Host "Microsoft sign-in of $($script:SessUser.name) could not be loaded: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
# v2.0.0: an access token for this person's Microsoft Graph sign-in (for background work that must not use the shared connection)
# Returns a valid Graph access token of this person (renewed when it expires in < 20 minutes). For background jobs that must not use the shared connection.
function Get-SessGraphToken {
    if ($script:MsRefresh) {
        if (-not $script:MsAccess -or -not $script:MsExp -or (Get-Date) -gt $script:MsExp.AddMinutes(-20)) { Update-MsToken -Force }
        return $script:MsAccess
    }
    Use-SessGraph
    try { $m = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id' -OutputType HttpResponseMessage -ErrorAction Stop; return "$($m.RequestMessage.Headers.Authorization.Parameter)" } catch { return $null }
}
# Returns all live sessions as a list of @{ sid; st } (st = the saved variables).
function Get-SessList {
    @($script:Sessions.GetEnumerator() | ForEach-Object { $st = $_.Value; [pscustomobject]@{ sid = $_.Key; st = $st } })
}
# Creates a new session id: 32 random bytes from the Windows crypto generator, written as 64 hex characters (cannot be guessed).
function New-SessToken { $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ([BitConverter]::ToString($b)).Replace('-', '').ToLower() }
# A short, safe public id (first 6 bytes of a SHA-256 hash) for a session id; used to show sessions without revealing the real cookie value.
function Get-SessId($sid) { $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("sess:$sid")); ([BitConverter]::ToString($h, 0, 6)).Replace('-', '').ToLower() }

# v2.0.0: on-premises AD sign-in of the loaded session (used by the AD box and by the account an administrator set for a person)
# Sign in to on-premises AD with the typed account ($u = DOMAIN\user or UPN, $pw = password). The password is checked by AD itself
# (RefreshCache fails if wrong). On success the account is kept in memory (AdCred). Returns @{ other = is it a different account than the linked one; self = its own status }.
function Connect-AdAccount($u, $pw) {
    Add-Type -AssemblyName System.DirectoryServices
    $dnc = "$((Get-RootDse).Properties['defaultNamingContext'].Value)"   # v2.8.1: the DC chosen in Settings (or Windows' own choice)
    if (-not $dnc) { throw 'Could not find the Active Directory domain of this PC.' }
    $auth = [DirectoryServices.AuthenticationTypes]'Secure, Sealing, Signing'
    $e = New-Object DirectoryServices.DirectoryEntry("$(Get-LdapPrefix)$dnc", $u, $pw, $auth)
    $e.RefreshCache()
    # Any AD account may be used (for example a separate admin account) - AD itself checks the password and the rights.
    $bound = Get-BoundSam $e $u
    $other = -not (Test-AdMatch $u $bound)
    $script:AdCred = @{ User = $u; Sam = $bound; Dnc = $dnc; Pass = (ConvertTo-SecureString $pw -AsPlainText -Force) }
    $script:AdLast = Get-Date; $script:AdInfo = $null
    $selfSam = ("$u" -replace '^.*\\', '') -replace '@.*$', ''
    $self = $null; try { $o = Get-OnPremStatus $selfSam $null $selfSam; $self = @{ found = $o.found; enabled = $o.enabled; locked = $o.locked; expires = $o.expires; pwdSet = $o.pwdSet } } catch {}
    @{ other = $other; self = $self }
}
# the AD account an administrator set for this tool user (Settings > Users), or $null
# The AD account an administrator assigned to this tool user in Settings > Users, or $null (owner, AD sign-ins and SSO users have none).
function Get-AssignedAd { $u = $script:SessUser; if (-not $u -or $u.owner -or $u.ad -or ($u.sso -and -not $u.toolUser)) { return $null }; $t = Get-ToolUserRec "$($u.name)"; if ($t -and "$($t.adUser)") { return @{ user = "$($t.adUser)"; passEnc = "$($t.adPassEnc)"; lock = ($t.adLock -ne $false) } }; $null }
# At portal sign-in: automatically sign in to AD with the account the administrator assigned (password stored encrypted, see Unprotect-MailSecret).
# A failure is only noted (AdNote) and logged - it never blocks the portal sign-in.
function Connect-AssignedAd($tu) {
    $a = Get-AssignedAd; if (-not $a -or -not $a.passEnc -or -not $script:AdAvail) { return }
    try {
        $u = $a.user; if ($u -notmatch '[\\@]') { $u = "$env:USERDOMAIN\$u" }
        [void](Connect-AdAccount $u (Unprotect-MailSecret $a.passEnc))
        $script:AdLogoutAt = if ($script:AdAutoMins -gt 0) { (Get-Date).AddMinutes($script:AdAutoMins) } else { $null }
        Write-LoginLog $u 'On-prem AD sign-in: Success (account set by the administrator)'
    } catch { $script:AdNote = "The AD account your administrator set ($($a.user)) could not sign in: $(Get-ErrMsg $_)"; Write-LoginLog "$($a.user)" "On-prem AD sign-in (set by the administrator): Failed - $(Get-ErrMsg $_)" }
}
# Everything this tool is allowed to do. There is deliberately NO delete endpoint (disable is allowed, with a confirmation).
# WHITELIST of every API path the server will answer. Any other /api/ path gets '403 not allowed' (see the request loop). A screen file must add
# its paths here before the page can call them. There is deliberately no delete endpoint.
$AllowedApi = @('/api/guestrep-run', '/api/ourep-ous', '/api/ourep-run', '/api/ad-server', '/api/email-img-all', '/api/sso-ms-offer', '/api/sso-ms-choice', '/api/sso-ms-mine', '/api/email-custom-save', '/api/lic-read', '/api/lic-groups', '/api/lic-change', '/api/adc-meta', '/api/adc-check', '/api/adc-validate', '/api/adc-create', '/api/spo-forget', '/api/mfa-list-many', '/api/mfa-mail', '/api/sec-tfa-reset', '/api/sec-get', '/api/sec-save', '/api/sec-unblock', '/api/sec-lockfolder', '/api/update-info', '/api/update-upload', '/api/update-discard', '/api/update-install', '/api/update-revert', '/api/update-delete', '/api/appsetup-info', '/api/appsetup-start', '/api/appsetup-poll', '/api/intune-action', '/api/mp-status', '/api/mp-lookup', '/api/mp-run', '/api/gjob', '/api/gjob-cancel', '/api/intune-run', '/api/spo-status', '/api/spo-code-start', '/api/spo-code-poll', '/api/od-usage', '/api/od-lookup', '/api/od-delete', '/api/od-restore', '/api/sess-signout', '/api/ms-device-start', '/api/ms-device-poll', '/api/msapp-get', '/api/msapp-save', '/api/sess-end', '/api/reset-mail-preview', '/api/restart', '/api/sess-now', '/api/sess-history', '/api/status', '/api/connect', '/api/known-accounts', '/api/ms-login-start', '/api/guest-invite', '/api/app-defaults', '/api/users-list', '/api/logs-logins', '/api/users-save', '/api/users-delete', '/api/users-adcheck', '/api/adlogin-get', '/api/adlogin-save', '/api/me-password', '/api/email-tpl-list', '/api/email-tpl-save', '/api/email-tpl-reset', '/api/email-img-save', '/api/email-img-remove', '/api/email-tpl-preview', '/api/audit-cloud', '/api/audit-ad', '/api/audit-job', '/api/audit-cancel', '/api/audit-ad-events', '/api/tab-closed', '/api/logs-config', '/api/logs-config-save', '/api/logs-autocopy', '/api/reset', '/api/search', '/api/enable', '/api/disable', '/api/mfa-list', '/api/mfa-revoke', '/api/mfa-log', '/api/autologout', '/api/ad-autologout', '/api/session-timeout', '/api/signout-all', '/api/signout', '/api/ad-connect', '/api/ad-disconnect', '/api/logout', '/api/teams-find', '/api/teams-members', '/api/teams-add', '/api/teams-log',
    '/api/onprem-suffixes', '/api/onprem-search', '/api/onprem-report', '/api/onprem', '/api/onprem-account', '/api/bulk-resolve', '/api/bulk-apply', '/api/bulk-groupsearch', '/api/bulk-groupcheck', '/api/dg-status', '/api/dg-install', '/api/dg-start', '/api/dg-stop', '/api/dg-run', '/api/dg-log', '/api/dg-file', '/api/groupsearch', '/api/usersearch', '/api/mail-settings', '/api/mail-test', '/api/mailacct-start', '/api/mailacct-browser', '/api/mailacct-poll', '/api/mailacct-signout', '/api/suggest', '/api/audit-userfind', '/api/sso-get', '/api/sso-save', '/api/sso-metadata', '/api/sso-logo', '/api/ssl-info', '/api/ssl-upload', '/api/ssl-save', '/api/ssl-iis', '/api/gal-check', '/api/gal-ad', '/api/gal-cloud', '/api/onprem-userinfo', '/api/people-list', '/api/people-settings', '/api/people-save', '/api/people-delete', '/api/people-enable', '/api/people-import', '/api/people-adsearch', '/api/people-adimport', '/api/people-adlink', '/api/people-adsync', '/api/reset-mail-info', '/api/reset-mail', '/api/logs-status', '/api/logs-settings', '/api/logs-sync', '/api/logs-recent', '/api/logs-search', '/api/me-prefs', '/api/home-info', '/api/logs-open', '/api/export-save', '/api/log-event', '/api/mbx-info', '/api/mbx-change', '/api/mbx-result', '/api/mbx-people', '/api/mbx-notify', '/api/shutdown')
# Time for the logs: the clock AND time zone of the device the page is open on (the browser sends them with every request);
# until the first request it is this PC's own clock. Get-NowText gives the zone name, for example UTC+03:00 (Asia/Riyadh).
# Time zone of the browser: the page sends X-TZ-Min / X-TZ-Name with each request so log times match the person's clock.
$script:ClientTzMin = $null; $script:ClientTzName = ''
$script:CloseAt = $null; $script:CloseAct = ''   # the browser tab was closed: what to do if no page comes back within a few seconds
# Current time in the browser's time zone (or this PC's clock before the first request). Used for log timestamps.
function Get-Now { if ($null -ne $script:ClientTzMin) { [datetime]::UtcNow.AddMinutes($script:ClientTzMin) } else { Get-Date } }
# Time zone text for logs, for example 'UTC+03:00 (Asia/Riyadh)'. Offset is in minutes -> sign, hours, minutes.
function Get-TzText {
    $m = if ($null -ne $script:ClientTzMin) { [int]$script:ClientTzMin } else { [int][TimeZoneInfo]::Local.GetUtcOffset([datetime]::UtcNow).TotalMinutes }
    $sg = if ($m -lt 0) { '-' } else { '+' }; $a = [math]::Abs($m)
    ('UTC{0}{1:00}:{2:00}' -f $sg, [math]::Floor($a / 60), ($a % 60)) + $(if ($script:ClientTzName) { " ($($script:ClientTzName))" } else { '' })
}
# Sends a JSON answer to the browser: $obj is converted to JSON (depth 5), $code is the HTTP status (200 ok, 400 error, 403 forbidden...).
# Also keeps the answer for the activity log and, when Microsoft Graph says the sign-in is gone, tries to renew it first.
function Send($ctx, $obj, $code = 200) {
    $script:ActResp = $obj; $script:ActCode = $code   # for the activity log
    $js = ($obj | ConvertTo-Json -Depth 5)
    # v1.98.8: Microsoft Graph says the session is gone -> show 'not signed in' at once, so the Microsoft 365 screens lock again
    if ($script:Who -and $js -match 'Authentication needed|Please call Connect-MgGraph') {
        # v1.98.13: renew the Graph session at once; only when that fails is the person shown as signed out (the screens then lock)
        if (Repair-MsGraph -Force) { }
        else { Clear-Who; $script:MsErr = 'The Microsoft 365 sign-in has ended. Sign in again from Settings > Connections.' }
        $js = ($obj | ConvertTo-Json -Depth 5) -replace 'Authentication needed\. Please call Connect-MgGraph\.?', 'The Microsoft 365 session had expired and was renewed - please try again.'
    }
    $b = [Text.Encoding]::UTF8.GetBytes($js)
    $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
}
# Makes a random 16-character password from characters that are easy to read (no 0/O, 1/l/I) and repeats until it has an upper-case letter,
# a lower-case letter, a digit and one of ! @ # $ %. Uses the crypto random generator, not Get-Random.
function New-TempPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%'.ToCharArray()
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    do {
        $p = ''
        1..16 | ForEach-Object { $b = New-Object byte[] 4; $rng.GetBytes($b); $p += $chars[[BitConverter]::ToUInt32($b, 0) % $chars.Length] }
    } until ($p -cmatch '[A-Z]' -and $p -cmatch '[a-z]' -and $p -match '\d' -and $p -match '[!@#$%]')
    $p
}
# Start-up: makes sure the NuGet provider and ALL Microsoft Graph modules are installed in the SAME version and loads them.
# Reason: mixing versions gives assembly conflicts. Installs for the current user only (no administrator needed). Reports each step to the start window.
function Initialize-Graph {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($m in $Mods) { Set-Start $m 'wait' $m 'waiting' }
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Write-Host 'Installing NuGet package provider...'
        Set-Start 'nuget' 'run' 'NuGet package provider' 'installing (needed to install modules)...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Set-Start 'nuget' 'ok' 'NuGet package provider' 'installed'
    }
    # Pin every Graph module to ONE version so assemblies never mix
    # Script block that returns the highest installed version of Microsoft.Graph.Authentication; every other module is matched to it.
    $get = { Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1 -ExpandProperty Version }
    $ver = & $get
    if (-not $ver) {
        Write-Host 'Microsoft Graph not found - installing (first run only, this can take a few minutes)...'
        Set-Start 'Microsoft.Graph.Authentication' 'run' 'Microsoft.Graph.Authentication' 'not installed - installing the latest version (first run, can take a few minutes)...'
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
        $ver = & $get
    }
    Write-Host "Microsoft Graph SDK version: $ver"
    foreach ($m in $Mods) {
        if (Get-Module -ListAvailable $m | Where-Object { $_.Version -eq $ver }) { Write-Host "  [installed] $m"; Set-Start $m 'ok' $m "installed $ver" }
        else {
            Write-Host "  [installing] $m ..."
            $had = @(Get-Module -ListAvailable $m | Sort-Object Version -Descending | Select-Object -First 1).Version
            Set-Start $m 'run' $m $(if ($had) { "installing $ver (installed: $had - versions must match)..." } else { "not installed - installing $ver..." })
            try { Install-Module $m -RequiredVersion $ver -Scope CurrentUser -Force -AllowClobber }
            catch { Set-Start $m 'fail' $m "install failed: $($_.Exception.Message)"; throw }
            Write-Host "  [installed] $m"; Set-Start $m 'ok' $m "installed $ver (just now)"
        }
    }
    Set-Start 'import' 'run' 'Loading Microsoft Graph' 'this takes a few seconds...'
    foreach ($m in $Mods) { Import-Module $m -RequiredVersion $ver -Force -ErrorAction Stop }
    Set-Start 'import' 'ok' 'Loading Microsoft Graph' "Microsoft Graph SDK $ver loaded"
    $script:GraphVer = "$ver"
}
# Converts a SecureString to normal text and wipes the temporary memory copy straight away (ZeroFreeBSTR).
function ConvertTo-Plain($ss) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
# Password hash: PBKDF2 (Rfc2898DeriveBytes) of $text with the salt, $iter rounds, 32 bytes out. Used for the owner username and password.
function Get-PwHash($text, [byte[]]$salt, [int]$iter) {
    $k = New-Object Security.Cryptography.Rfc2898DeriveBytes("$text", $salt, $iter)
    try { $k.GetBytes(32) } finally { $k.Dispose() }
}
# Compares two byte arrays in constant time (always walks all bytes) so the time taken cannot reveal how much of a hash matched.
function Test-Bytes($a, $b) {
    if ($a.Length -ne $b.Length) { return $false }
    $diff = 0; for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
    $diff -eq 0
}
# Only salted hashes of the username AND password are kept, written into the $EmbeddedAuth line of this script.
# Saves a new owner login: makes random salts, hashes username and password, and REWRITES the $EmbeddedAuth line inside this script file.
# The regex (?m)^$EmbeddedAuth = '...' finds that line. Throws if the line cannot be found.
function Save-Auth($user, $pass) {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $it = 100000
    $s1 = New-Object byte[] 16; $s2 = New-Object byte[] 16; $rng.GetBytes($s1); $rng.GetBytes($s2)
    $json = [ordered]@{ v = 1; it = $it
        us = [Convert]::ToBase64String($s1); uh = [Convert]::ToBase64String((Get-PwHash $user $s1 $it))
        ps = [Convert]::ToBase64String($s2); ph = [Convert]::ToBase64String((Get-PwHash $pass $s2 $it)) } | ConvertTo-Json -Compress
    $me = $PSCommandPath
    $txt = [IO.File]::ReadAllText($me)
    $line = "`$EmbeddedAuth = '$json'"
    $new = [regex]::Replace($txt, "(?m)^\`$EmbeddedAuth = '[^']*'", [Text.RegularExpressions.MatchEvaluator]{ param($m) $line })
    if ($new -ceq $txt -and $txt -notlike "*$json*") { throw 'Could not find the login line inside server.ps1.' }
    [IO.File]::WriteAllText($me, $new, (New-Object Text.UTF8Encoding($false)))
    $script:Auth = $json | ConvertFrom-Json
}
# Reads the embedded login data (JSON) into an object; $null if it is damaged.
function Read-Auth { try { $EmbeddedAuth | ConvertFrom-Json } catch { $null } }
# Checks the OWNER login: both username and password hashes must match (both are always computed, so the time does not show which was wrong).
function Test-Login($user, $pass) {
    $a = $script:Auth; if (-not $a) { return $false }
    $it = [int]$a.it
    $uOk = Test-Bytes (Get-PwHash $user ([Convert]::FromBase64String($a.us)) $it) ([Convert]::FromBase64String($a.uh))
    $pOk = Test-Bytes (Get-PwHash $pass ([Convert]::FromBase64String($a.ps)) $it) ([Convert]::FromBase64String($a.ph))
    $uOk -and $pOk
}
# Console questions to create/change the owner login (first start, or Change-Login.bat with -ChangeLogin). $verifyOld = ask for the old login first.
# Password must have 8+ characters and be typed twice. Returns $true when saved.
function Invoke-LoginSetup($verifyOld) {
    if ($verifyOld -and $script:Auth) {
        $ou = Read-Host 'Current login username'; $op = ConvertTo-Plain (Read-Host 'Current login password' -AsSecureString)
        if (-not (Test-Login $ou $op)) { Write-Host 'The current username or password is incorrect.' -ForegroundColor Red; return $false }
    }
    Write-Host ''
    Write-Host 'Create the login for this tool. Only salted hashes are stored, inside server.ps1 - nothing is saved elsewhere.' -ForegroundColor Cyan
    $nu = "$(Read-Host 'New username')".Trim()
    if (-not $nu) { Write-Host 'Username cannot be empty.' -ForegroundColor Red; return $false }
    $p1 = ConvertTo-Plain (Read-Host 'New password (min 8 characters)' -AsSecureString)
    $p2 = ConvertTo-Plain (Read-Host 'Confirm password' -AsSecureString)
    if ($p1.Length -lt 8) { Write-Host 'The password must be at least 8 characters.' -ForegroundColor Red; return $false }
    if ($p1 -cne $p2) { Write-Host 'The passwords do not match.' -ForegroundColor Red; return $false }
    try { Save-Auth $nu $p1 } catch { Write-Host "Could not save the login: $($_.Exception.Message)" -ForegroundColor Red; return $false }
    # Normal window: keep asking until a login has been created.
    if (-not $script:Auth) { Write-Host 'Could not save the login.' -ForegroundColor Red; return $false }
    Write-Host 'Login saved.' -ForegroundColor Green; $true
}
# One CSV cell for the log files: quoted, one line, and a cell that starts with = + - @ is prefixed with an apostrophe so Excel cannot run it as a formula
function ConvertTo-CsvCell($v) {
    $s = ("$v" -replace '[\r\n]', ' ')
    if ($s -match '^[=+\-@\t]' -and $s -ne '-' -and $s -notmatch '^[+-]?\d[\d\s().-]*$') { $s = "'" + $s }
    '"' + ($s -replace '"', '""') + '"'
}
# Which PC a request comes from: the IP address and, when the network can say, its name (cached; looked up for at most 1.5 seconds)
$script:PcCache = @{}; $script:ClientIp = ''; $script:ClientPc = ''; $script:SessIp = ''; $script:SessPc = ''
# Name of the PC behind an IP address (reverse DNS, waits max 1.5 seconds, result cached). Local addresses give this PC's name.
function Get-ClientPc($ip) {
    if (-not $ip) { return '' }
    if ($ip -in '127.0.0.1', '::1') { return "$env:COMPUTERNAME (this PC)" }
    if ($script:PcCache.ContainsKey($ip)) { return $script:PcCache[$ip] }
    $n = ''
    try { $t = [Net.Dns]::GetHostEntryAsync($ip); if ($t.Wait(1500)) { $n = "$($t.Result.HostName)" } } catch {}
    $script:PcCache[$ip] = $n; $n
}
# Finds the real client IP of a request. Normally RemoteEndPoint; behind IIS the request comes from 127.0.0.1 so the last address
# in the X-Forwarded-For header is used (only trusted when the request comes from this server itself).
function Set-ClientInfo($ctx) {
    try {
        $ip = "$($ctx.Request.RemoteEndPoint.Address)"
        # v2.0.0: behind IIS (reverse proxy on this server) the real PC is in X-Forwarded-For - trusted only from this server itself
        if ($ip -in '127.0.0.1', '::1', '::ffff:127.0.0.1') { $xf = @("$($ctx.Request.Headers['X-Forwarded-For'])".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })[-1];   # v2.4.0: the LAST address is the one IIS added - the first ones can be faked by the PC
 if ($xf -match '^[0-9a-fA-F:.]{3,45}$') { $ip = ($xf -replace '^(\d+\.\d+\.\d+\.\d+):\d+$', '$1') } }
        $script:ClientIp = $ip; $script:ClientPc = Get-ClientPc $script:ClientIp
    } catch { $script:ClientIp = ''; $script:ClientPc = '' }
}
# Appends one row to logs\login-audit-YYYY-MM.csv: time, Windows user, typed username, result, client IP and PC name.
# Old files without the IP columns get them added. Marks the logs as changed so they are copied to SharePoint.
function Write-LoginLog($user, $result) {
    $f = Join-Path $LogDir ('login-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    $hdr = 'Time,WindowsUser,EnteredUsername,Result,ClientIP,ClientPC'
    if (-not (Test-Path $f)) { $hdr | Out-File $f -Encoding utf8 }
    else { try { $l = @(Get-Content $f -TotalCount 1 -Encoding UTF8); if ($l.Count -and $l[0] -notmatch 'ClientIP') { $all = @(Get-Content $f -Encoding UTF8); $all[0] = $all[0].TrimEnd() + ',ClientIP,ClientPC'; $all | Set-Content $f -Encoding UTF8 } } catch {} }
    $ip = $script:ClientIp; $pc = $script:ClientPc
    if ("$result" -like 'Session expired*') { $ip = $script:SessIp; $pc = $script:SessPc }   # nobody is making a request then: use the PC that signed in
    $vals = @(('{0:s}' -f (Get-Now)), [Security.Principal.WindowsIdentity]::GetCurrent().Name, $user, $result, $ip, $pc) |
        ForEach-Object { ConvertTo-CsvCell $_ }
    ($vals -join ',') | Add-Content $f
    $script:SpDirty = $true; $script:SpLastAct = Get-Date   # copied to SharePoint like the other logs
}
# Forget who is signed in to Microsoft (call this before every new Microsoft sign-in, and whenever it fails or ends)
# Forget the Microsoft sign-in of the loaded session (name, tokens, certificate, SharePoint admin token, timers, passwords waiting to be e-mailed).
# Call before every new Microsoft sign-in and whenever it fails or ends. Exchange Online worker is stopped too.
function Clear-Who {
    if ($script:Who -and (Get-Command Stop-DgWorker -ErrorAction SilentlyContinue)) { Stop-DgWorker }   # Exchange Online signs out together with Microsoft
    $script:CertInfo = $null; $script:DgAutoFor = $null; $script:MsOld = $false
    $script:WhoFirst = $null; $script:WhoLast = $null; $script:WhoDisp = $null
    $script:Who = $null; $script:WhoName = $null; $script:WhoUpn = $null; $script:WhoSam = $null; $script:WhoSynced = $false; $script:WhoDom = $null
    $script:LogoutAt = $null; $script:Dom = @{}
    $script:MsRefresh = $null; $script:MsExp = $null; $script:MsScopes = $null; $script:MsAccess = $null; $script:MsClient = $null; $script:MsSecret = $null; $script:MsPublicOnly = $false
    $script:SpoAdmin = $null; $script:SpoTok = $null; $script:SpoExp = $null; $script:SpoRefresh = $null; $script:SpoClient = $null; $script:SpoDev = $null   # v2.1.0: SharePoint admin sign-in
    $script:ResetSecrets = @{}   # passwords waiting to be emailed are dropped on sign-out
    if (Get-Command Set-DgPaths -ErrorAction SilentlyContinue) { Set-DgPaths }
}
# End the tool login and every sign-in that hangs off it
# Forget the on-premises AD sign-in (and its own auto sign-out timer)
function Clear-Ad { $script:AdCred = $null; $script:AdLogoutAt = $null }
# Sign out of Microsoft: first write the sign-out in the activity log and copy the logs to SharePoint (that needs the sign-in)
# Sign out of Microsoft Graph for the loaded session: first writes the sign-out in the activity log and copies logs to SharePoint
# (needs the sign-in), then disconnects - but only if the shared connection is this person's own.
function Exit-StGraph($why) {
    if ($script:Who -and (Get-Command Sync-SpLogs -ErrorAction SilentlyContinue)) {
        try { Use-SessGraph; Write-ActRow 'Sign-in' $(if ($why) { $why } else { 'Microsoft sign-out' }) "$($script:Who)" 'Done' ''; Sync-SpLogs } catch {}
    }
    # v2.0.0: only this person's Graph connection is closed (another person's is never touched)
    if (-not $script:GraphSid -or $script:GraphSid -eq $script:Session) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null; $script:GraphSid = $null }
}
# v2.0.0: shut down / restart - sign every session out (Microsoft, AD, Exchange Online) and forget them
# Shut down/restart: signs EVERY session out (Microsoft, AD, Exchange) and empties the session store.
function Stop-AllSessions($why) {
    foreach ($sx in @(Get-SessList)) {
        try { Use-Sess $sx.sid; Exit-StGraph $why; Clear-Who; Clear-Ad } catch {}
    }
    $script:Sessions = @{}; Use-Sess $null
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}; $script:GraphSid = $null
}
# Sign out of Microsoft AND on-premises AD, but keep the tool login (the portal) open
function Stop-AllSignIns {
    Exit-StGraph
    Clear-Who; Clear-Ad
}
# Ends the tool login of the loaded session (and its Microsoft and AD sign-ins). $why is printed in the window.
function Stop-ToolSession($why) {
    Exit-StGraph 'Microsoft sign-out (portal session ended)'
    Clear-Who; Clear-Ad; $script:Session = $null; $script:SessUser = $null
    if ($why) { Write-Host $why -ForegroundColor Yellow }
}
# Ends the loaded tool login when it was not used for SessIdleMins (default 30) or is older than SessMaxHours (8 hours).
function Test-SessionTimeout {
    if (-not $script:Session) { return }
    $now = Get-Date
    $why = if (($now - $script:SessLast).TotalMinutes -ge $script:SessIdleMins) { "not used for $($script:SessIdleMins) minutes" }
           elseif (($now - $script:SessStart).TotalHours -ge $script:SessMaxHours) { "open for $($script:SessMaxHours) hours" }
           else { $null }
    if ($why) {
        Write-LoginLog '(tool login)' "Session expired ($why)"
        Stop-ToolSession "Tool login ended ($why). The Microsoft and on-premises sign-ins were closed too."
    }
}
# Is this request from a valid signed-in browser? Steps: (1) timeouts, (2) the tool account must still exist/be enabled/not expired,
# (3) the 'sid' cookie must equal the loaded session id, (4) optional IP binding (Security setting bindIp). Returns $true/$false.
function Test-Session($ctx) {
    Test-SessionTimeout
    if ($script:Session -and $script:SessUser -and -not $script:SessUser.owner) {   # v1.98.9: the login expired (or the AD account did) while signed in
        if ($script:SessUser.sso -and -not $script:SessUser.toolUser) { $why = $null } elseif ($script:SessUser.ad) { $why = Get-ToolUserBlock ([pscustomobject]@{ adSam = $script:SessUser.adSam }) }   # AD sign-in: expired / disabled in AD
        else {
            $tu = $null; foreach ($x in (Read-ToolUsers)) { if ("$($x.username)" -ieq "$($script:SessUser.name)") { $tu = $x } }
            $why = if (-not $tu -or $tu.enabled -eq $false) { 'This account was removed or disabled.' } else { Get-ToolUserBlock $tu }
        }
        if ($why) { Write-LoginLog "$($script:SessUser.name)" "Session ended: $why"; Stop-ToolSession "Tool login of $($script:SessUser.name) ended: $why" }
    }
    $c = $ctx.Request.Cookies['sid']
    $ok = [bool]($script:Session -and $c -and $c.Value -ceq $script:Session)
    # v2.4.0: a stolen cookie does not work from another PC - the session belongs to the IP address that signed in
    if ($ok -and $script:SecCfg.bindIp -and $script:SessIp -and "$($script:ClientIp)" -and "$($script:ClientIp)" -ne "$($script:SessIp)") { try { Write-LoginLog "$($script:SessUser.name)" "Session refused: used from $($script:ClientIp), signed in from $($script:SessIp)" } catch {}; return $false }
    if ($ok) { $script:SessLast = Get-Date }
    $ok
}
# Time of the automatic AD sign-out as an ISO text (UTC) for the page, or $null.
function Get-AdLogoutIso { if ($script:AdLogoutAt -and $script:AdCred) { $script:AdLogoutAt.ToUniversalTime().ToString('o') } else { $null } }
# Time of the automatic Microsoft sign-out as an ISO text (UTC) for the page, or $null.
function Get-LogoutIso { if ($script:LogoutAt) { $script:LogoutAt.ToUniversalTime().ToString('o') } else { $null } }
# Minutes -> readable text: 1440 = '1 day', 120 = '2 hours', otherwise 'N minutes'.
function Format-Mins($m) {
    if ($m % 1440 -eq 0) { $n = $m / 1440; return "$n day$(if ($n -ne 1) {'s'})" }
    if ($m % 60 -eq 0) { $n = $m / 60; return "$n hour$(if ($n -ne 1) {'s'})" }
    "$m minutes"
}
# Cloud password expiry date of a Graph user: 'Never expires' when policy says so, else last change + the domain's validity days
# (cached per domain; needs Domain.Read.All). Returns text.
function Get-PwdExpiry($u) {
    try {
        if ($u.PasswordPolicies -match 'DisablePasswordExpiration') { return 'Never expires' }
        $dn = "$($u.UserPrincipalName)".Split('@')[-1]
        if (-not $script:Dom.ContainsKey($dn)) {
            try { $script:Dom[$dn] = (Get-MgDomain -DomainId $dn -ErrorAction Stop).PasswordValidityPeriodInDays } catch { $script:Dom[$dn] = $null }
        }
        $days = $script:Dom[$dn]
        if ($null -eq $days) { return 'Unknown (needs Domain.Read.All)' }
        if ($days -ge 2147483647 -or $days -le 0) { return 'Never expires' }
        if (-not $u.LastPasswordChangeDateTime) { return 'Unknown' }
        return ('{0:yyyy-MM-dd}' -f $u.LastPasswordChangeDateTime.AddDays($days))
    } catch { return 'Unknown' }
}
# Looks up one account in on-premises AD (ADSI, no RSAT needed). Tries sAMAccountName, UPN, then the name. Returns a hashtable:
# found, enabled, locked, expires, pwdSet, pwNever, mobile, phone, note. Flags used: userAccountControl 2 = disabled, 0x10000 = password never expires,
# 0x10 in msDS-User-Account-Control-Computed = locked out.
function Get-OnPremStatus($sam, $upn, $name) {
    # Uses ADSI (built into Windows) - no RSAT / ActiveDirectory module needed, only a domain-joined PC
    $o = @{ found = 'Unknown'; enabled = '-'; expires = '-'; locked = '-'; pwdSet = '-'; pwNever = '-'; note = ''; mobile = ''; phone = '' }
    # LDAP filter escape: \ * ( ) are replaced so typed text cannot change the search filter.
    $esc = { param($v) ("$v" -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29') }
    try {
        $adRoot = New-AdEntry
        $cands = @()
        if ($sam) { $cands += "(sAMAccountName=$(& $esc $sam))" }
        if ($upn) { $cands += "(userPrincipalName=$(& $esc $upn))" }
        if ($name -notmatch '@') { $cands += "(sAMAccountName=$(& $esc $name))" }
        $res = $null
        foreach ($c in $cands) {
            $ds = New-Object DirectoryServices.DirectorySearcher
            $ds.SearchRoot = $adRoot
            $ds.Filter = "(&(objectCategory=person)(objectClass=user)$c)"
            foreach ($p in 'samaccountname', 'useraccountcontrol', 'accountexpires', 'pwdlastset', 'msds-user-account-control-computed', 'mobile', 'telephonenumber') { [void]$ds.PropertiesToLoad.Add($p) }
            $res = $ds.FindOne()
            if ($res) { break }
        }
        if (-not $res) { $o.found = 'No'; return $o }
        $o.found = 'Yes'
        if ($res.Properties['mobile'].Count) { $o.mobile = "$($res.Properties['mobile'][0])" }; if ($res.Properties['telephonenumber'].Count) { $o.phone = "$($res.Properties['telephonenumber'][0])" }   # v2.2.1
        $uac = [int]$res.Properties['useraccountcontrol'][0]
        $o.enabled = if ($uac -band 2) { 'Disabled' } else { 'Enabled' }
        $o.pwNever = if ($uac -band 0x10000) { 'Yes' } else { 'No' }   # DONT_EXPIRE_PASSWORD
        $ae = [int64]$res.Properties['accountexpires'][0]
        $o.expires = if ($ae -eq 0 -or $ae -eq [int64]::MaxValue) { 'Never' } else {
            # AD stores the start of the day AFTER the last working day; show the last day the account works, like AD Users and Computers
            $dt = [DateTime]::FromFileTime($ae); $p = '{0:yyyy-MM-dd}' -f $dt.AddSeconds(-1)
            if ($dt -lt (Get-Date)) { "EXPIRED $p" } else { $p }
        }
        $pl = [int64]$res.Properties['pwdlastset'][0]
        $o.pwdSet = if ($pl -gt 0) { '{0:yyyy-MM-dd}' -f [DateTime]::FromFileTime($pl) } else { 'Must change at next logon' }
        if ($res.Properties['msds-user-account-control-computed'].Count -gt 0) {
            $o.locked = if ([int]$res.Properties['msds-user-account-control-computed'][0] -band 0x10) { 'Yes' } else { 'No' }
        }
        if ($uac -band 0x10000) { $o.note = 'Password never expires' }
    } catch { $o.note = $_.Exception.Message }
    $o
}
# Same LDAP escaping as above, as a function.
function ConvertTo-LdapValue($v) { ("$v" -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29') }
# Finds one AD user (or group when $kind='group') by exact name. Users: sAMAccountName or UPN (or only the ticked fields sam/upn/mail).
# Falls back to the part before '@' as sAMAccountName. Returns the search result or $null.
function Find-AdObject($kind, $name) {
    $n = ConvertTo-LdapValue $name
    # $script:FindFields (set by the On-premises AD search box) limits an exact user look-up to the ticked fields: sam, upn, mail
    $ff = @(); if ($kind -ne 'group' -and $script:FindFields) { $ff = @($script:FindFields) }
    $f = if ($kind -eq 'group') { "(&(objectCategory=group)(|(sAMAccountName=$n)(cn=$n)))" } elseif ($ff.Count) {
        $parts = ''
        if ($ff -contains 'sam') { $parts += "(sAMAccountName=$n)" }
        if ($ff -contains 'upn') { $parts += "(userPrincipalName=$n)" }
        if ($ff -contains 'mail') { $parts += "(mail=$n)" }
        if (-not $parts) { $script:FindVia = ''; return $null }
        "(&(objectCategory=person)(objectClass=user)(|$parts))"
    } else { "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$n)(userPrincipalName=$n)))" }
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.Filter = $f
    foreach ($p in 'distinguishedname', 'grouptype', 'samaccountname', 'userprincipalname') { [void]$ds.PropertiesToLoad.Add($p) }
    $script:FindVia = ''
    $res = $ds.FindOne()
    if (-not $res -and $kind -ne 'group' -and "$name" -match '@' -and (-not $ff.Count -or $ff -contains 'sam')) {
        $local = ("$name" -split '@')[0]
        if ($local) {
            $ds.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $local)))"
            $res = $ds.FindOne(); if ($res) { $script:FindVia = 'sam' }
        }
    }
    $res
}
# Report lookup: exact username / UPN / email first, then the part before @ as username, then a description contains-match (can return several users)
# Exact name first; otherwise a partial name is completed when it matches exactly one security group
# One account when an email/domain is given; otherwise every account whose sign-in name starts with the typed username
# Finds cloud (Entra ID) users: one user when an e-mail/UPN or domain is given, otherwise up to 10 users whose UPN starts with the name
# or whose mailNickname matches. Returns an array (empty when not found).
function Resolve-EntraUsers($name, $dom, $props) {
    $upn = if ($name -match '@') { $name } elseif ($dom) { "$name@$dom" } else { $null }
    if ($upn) {
        try { return @(Get-MgUser -UserId $upn -Property $props -ErrorAction Stop) }
        catch { if ($_.Exception.Message -match 'ResourceNotFound|does not exist|not found') { return @() } else { throw } }
    }
    $n = $name -replace "'", "''"
    $u = @(Get-MgUser -Filter "startsWith(userPrincipalName,'$n@')" -Property $props -Top 10 -ErrorAction Stop)
    if ($u.Count -eq 0) { $u = @(Get-MgUser -Filter "mailNickname eq '$n'" -Property $props -Top 10 -ErrorAction Stop) }
    return $u
}
# Reset the cloud (Entra ID) password of the same person, using the same password that was just set on-premises
# Splits a pasted list of group names (new lines, commas or semicolons) into a clean list without empty or duplicate entries.
function Get-GroupList($text) { @("$text" -split '[\r\n,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }
# Is this text a valid domain/UPN suffix (letters, digits, dots, hyphens; not starting or ending with a dot/hyphen)?
function Test-UpnSuffix($x) { "$x" -match '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' }
# On-premises AD: every lookup/change uses the credentials the operator typed in (kept in memory only)
# Opens an LDAP connection (DirectoryEntry) with the typed AD account of the loaded session; $dn = another object, default = domain root.
# Secure+Sealing+Signing = encrypted and signed LDAP. Throws if nobody signed in to AD.
function New-AdEntry($dn) {
    $c = $script:AdCred
    if (-not $c) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
    Add-Type -AssemblyName System.DirectoryServices
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($c.Pass)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $script:AdLast = Get-Date
    $auth = [DirectoryServices.AuthenticationTypes]'Secure, Sealing, Signing'
    New-Object DirectoryServices.DirectoryEntry("$(Get-LdapPrefix)$(if ($dn) { $dn } else { $c.Dnc })", $c.User, $plain, $auth)   # v2.8.1: chosen DC
}
# The on-premises account that belongs to the Microsoft (Entra) account that signed in (synced accounts only)
# The on-premises account linked to the signed-in Microsoft account (only for synced accounts): upn, sam, domain; else $null.
function Get-Linked { if ($script:Who -and $script:WhoSynced -and $script:WhoSam) { @{ upn = $script:WhoUpn; sam = $script:WhoSam; domain = $script:WhoDom } } else { $null } }
# Does the typed AD account belong to the same person as the Microsoft sign-in? True when no link exists.
function Test-AdMatch($u, $boundSam) {
    $l = Get-Linked; if (-not $l) { return $true }
    $sam = ("$u" -replace '^.*\\', '') -replace '@.*$', ''
    ($sam -eq $l.sam) -or ("$u" -eq $l.upn) -or ($boundSam -and ("$boundSam" -eq $l.sam))
}
# The real sAMAccountName of the account that just signed in (the user may have typed a UPN whose first part differs from it)
# After AD accepted the password: finds the real sAMAccountName of that account (the typed UPN may differ from it).
function Get-BoundSam($entry, $typed) {
    $ds = $null
    try {
        $s = ("$typed" -replace '^.*\\', '') -replace '@.*$', ''
        $ds = New-Object DirectoryServices.DirectorySearcher($entry)
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$(ConvertTo-LdapValue $s))(userPrincipalName=$(ConvertTo-LdapValue $typed))))"
        [void]$ds.PropertiesToLoad.Add('samaccountname')
        $r = $ds.FindOne()
        if ($r) { "$($r.Properties['samaccountname'][0])" } else { $null }
    } catch { $null } finally { if ($ds) { $ds.Dispose() } }
}
# Random whole number 0..max-1 from the crypto generator.
function Get-RandInt($max) {
    if (-not $script:Rng) { $script:Rng = [Security.Cryptography.RandomNumberGenerator]::Create() }
    $b = New-Object byte[] 4; $script:Rng.GetBytes($b); [int]([BitConverter]::ToUInt32($b, 0) % $max)
}
# Rule: at least 8 characters, and it must not start or end with a special character
# Password rule of this tool: 8+ characters, first and last must be a letter or digit (regex ^[A-Za-z0-9](.*[A-Za-z0-9])\z).
function Test-AdPwRule($p) { "$p".Length -ge 8 -and "$p" -match '^[A-Za-z0-9](.*[A-Za-z0-9])\z' }
# Random password of length $len for AD resets: first/last are letters or digits, has upper, lower, digit and a special character.
function New-AdPassword($len) {
    $alnum = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
    $spec = '!@#$%'.ToCharArray(); $all = $alnum + $spec
    do {
        $c = New-Object char[] $len
        $c[0] = $alnum[(Get-RandInt $alnum.Length)]; $c[$len - 1] = $alnum[(Get-RandInt $alnum.Length)]
        for ($i = 1; $i -lt ($len - 1); $i++) { $c[$i] = $all[(Get-RandInt $all.Length)] }
        $c[1 + (Get-RandInt ($len - 2))] = $spec[(Get-RandInt $spec.Length)]
        $p = -join $c
    } until ($p -cmatch '[A-Z]' -and $p -cmatch '[a-z]' -and $p -match '\d' -and $p -match '[!@#$%]' -and (Test-AdPwRule $p))
    $p
}
# Short error text from an error record (uses the inner exception message when there is one).
function Get-ErrMsg($e) { if ($e.Exception.InnerException) { $e.Exception.InnerException.Message } else { $e.Exception.Message } }
# Appends a row to logs\reset-audit-YYYY-MM.csv: who reset which user, how and the result.
function Write-Log($r, $method, $result) {
    $f = Join-Path $LogDir ('reset-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,Admin,Target,Method,Result,ExistsInEntra,AccountStatus,AccountType,PasswordExpiry,Synced' | Out-File $f -Encoding utf8 }
    $vals = @(('{0:s}' -f (Get-Now)), $script:Who, $r.upn, $method, $result, $r.exists, $r.enabled, $r.type, $r.pwdExpiry, $r.synced) |
        ForEach-Object { ConvertTo-CsvCell $_ }
    ($vals -join ',') | Add-Content $f
}

# Detailed log of every Revoke MFA action (one row per user). It holds method NAMES only - never phone numbers or passwords.
# Every sign-in method Revoke MFA can show and remove (the password cannot be removed and is not listed).
#   kind 'mfa'   = removed by "Remove the MFA methods"
#   kind 'tap'   = removed by "Delete the Temporary Access Pass"
#   kind 'other' = never removed in bulk, only when you press Remove on that one method

# Find one cloud user from a UPN, an email address or a username@domain

# Is this PC joined to an AD domain? If not, all on-premises features are switched off.
$script:AdAvail = try { [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { $false }
# Load the owner login; remove the old DPAPI login file from earlier versions if it still exists.
$script:Auth = Read-Auth
if (Test-Path $OldAuthFile) { try { Remove-Item $OldAuthFile -Force; Write-Host 'Removed the old saved login file from this PC (the login now lives inside the script).' -ForegroundColor Yellow } catch {} }
# Change-Login.bat: ask for old + new login, save it and quit.
# v2.11.9: Reset-Password.bat. For when the owner password is forgotten: no old password is asked, because being LOCAL ADMINISTRATOR of this PC is the proof.
if ($ResetLogin) {
    $isAdm = $false; try { $isAdm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
    if (-not $isAdm) { Write-Host 'Run Reset-Password.bat as administrator (right-click > Run as administrator).' -ForegroundColor Red; exit 1 }
    Write-Host 'Reset the owner login. You do not need the old password.' -ForegroundColor Cyan
    if (-not (Invoke-LoginSetup $false)) { exit 1 }
    try { Write-LoginLog 'Owner' 'Owner login was reset with Reset-Password.bat' } catch {}
    Write-Host 'Done. Open the tool and sign in with the new login. (Other people: reset their password in Settings > Users.)'; exit 0
}
if ($ChangeLogin) {
    if (-not (Invoke-LoginSetup $true)) { exit 1 }
    Write-Host 'Login updated. Start the tool with Start.bat.'; exit 0
}
# First start in background mode but no login yet: typing is needed, so open a normal window once and stop here.
if ($Background -and -not $script:Auth) {
    # First-time login setup needs typing: run the normal start once in a window (it goes to the background by itself afterwards)
    Set-Start 'login' 'warn' 'Tool login' 'not set up yet - answer the questions in the window that opened'
    Set-StartEnd 'SETUP|First-time setup: choose the username and password for the tool in the window that opened. The tool then starts by itself.'
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Splash" -WorkingDirectory $Root
    exit 0
}
if (-not $script:Auth) {
    Write-Host 'First-time setup: this script has no login yet.' -ForegroundColor Yellow
    while (-not (Invoke-LoginSetup $false)) { }
}
Set-Start 'login' 'ok' 'Tool login' 'set up'
# STEP: Microsoft Graph modules (install if missing, load).
Write-Host 'Checking Microsoft Graph modules...'
try { Initialize-Graph }
catch {
    Write-Host 'Check your internet connection, or remove old versions with: Get-InstalledModule Microsoft.Graph* | Uninstall-Module -AllVersions -Force'
    Stop-Fatal "Could not prepare the Microsoft Graph modules: $($_.Exception.Message). Check the internet connection and start again."
}
# Exchange Online module: only needed by Distribution groups and Shared mailbox (they can install it) - shown for information
try { $exoV = @(Get-Module -ListAvailable ExchangeOnlineManagement | Sort-Object Version -Descending | Select-Object -First 1).Version } catch { $exoV = $null }
if ($exoV) { Set-Start 'exo' 'ok' 'ExchangeOnlineManagement' "installed $exoV (Distribution groups, Shared mailbox)" }
else { Set-Start 'exo' 'warn' 'ExchangeOnlineManagement' 'not installed - only needed for Distribution groups and Shared mailbox (install it there)' }
Set-Start 'screens' 'run' 'Screens' 'loading...'
# Friendly address: http://supporttool:PORT/  (needs Administrator once, to add a hosts-file entry)
# Screens: each screen of the tool has its own back-end file (Screen-<name>.ps1). The files only register their handlers; shared code and the sign-in stay here.
# STEP: LOAD THE SCREENS. $ScreenHandlers maps an API path to a script block. Each Screen-*.ps1 is dot-sourced (run in this scope)
# and adds its own entries, e.g. $ScreenHandlers['/api/xxx'] = { ... }. A missing file stops the start.
$ScreenHandlers = @{}
foreach ($scr in $ScreenFiles) {
    $scrPath = Get-CodePath "Screen-$scr.ps1"
    if (-not (Test-Path $scrPath)) { Stop-Fatal "Missing file $scrPath. Copy every file and folder from the zip into the same folder." }
    . $scrPath
}
# One activity log for every screen, saved here and copied to SharePoint
$alPath = Get-CodePath 'ActivityLog.ps1'
if (-not (Test-Path $alPath)) { Stop-Fatal 'Missing file backend\Portal\ActivityLog.ps1. Copy every file and folder from the zip into the same folder.' }
. $alPath
# First run: ask if the user wants to minimize (run in background)
# First run only: ask in a small window whether to run in the background; the answer is saved in app-defaults.json (minimizeOnStart).
$AppDefFile = Join-Path $Root 'app-defaults.json'
$firstRun = $false
if (Test-Path $AppDefFile) {
    try {
        $appCfg = Get-Content $AppDefFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $appCfg.minimizeOnStart) { $firstRun = $true }
    } catch { $firstRun = $true }
} else { $firstRun = $true }
if ($firstRun -and -not $Splash -and -not $Background -and -not $ShowWindow) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $frm = New-Object System.Windows.Forms.Form
        $frm.Text = 'Admin Console - First Run'
        $frm.Size = New-Object System.Drawing.Size(420, 200)
        $frm.StartPosition = 'CenterScreen'
        $frm.FormBorderStyle = 'FixedDialog'
        $frm.MaximizeBox = $false
        $frm.MinimizeBox = $false
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = 'Would you like to run Admin Console in the background (minimized)?'
        $lbl.AutoSize = $false
        $lbl.TextAlign = 'MiddleCenter'
        $lbl.Size = New-Object System.Drawing.Size(380, 80)
        $lbl.Location = New-Object System.Drawing.Point(20, 20)
        $btnYes = New-Object System.Windows.Forms.Button
        $btnYes.Text = 'Yes (Minimize)'
        $btnYes.Size = New-Object System.Drawing.Size(140, 35)
        $btnYes.Location = New-Object System.Drawing.Point(50, 120)
        $btnYes.Add_Click({ $frm.DialogResult = 'Yes'; $frm.Close() })
        $btnNo = New-Object System.Windows.Forms.Button
        $btnNo.Text = 'No (Show Window)'
        $btnNo.Size = New-Object System.Drawing.Size(140, 35)
        $btnNo.Location = New-Object System.Drawing.Point(230, 120)
        $btnNo.Add_Click({ $frm.DialogResult = 'No'; $frm.Close() })
        $frm.Controls.Add($lbl)
        $frm.Controls.Add($btnYes)
        $frm.Controls.Add($btnNo)
        $result = $frm.ShowDialog()
        if ($result -eq 'Yes') {
            $ShowWindow = $false
            $appCfg = [ordered]@{ minimizeOnStart = $true }
            if (Test-Path $AppDefFile) {
                try { $j = Get-Content $AppDefFile -Raw -Encoding UTF8 | ConvertFrom-Json; $appCfg = $j } catch {}
            }
            $appCfg.minimizeOnStart = $true
            try { ($appCfg | ConvertTo-Json) | Out-File $AppDefFile -Encoding utf8 -Force } catch {}
        } else {
            $appCfg = [ordered]@{ minimizeOnStart = $false }
            if (Test-Path $AppDefFile) {
                try { $j = Get-Content $AppDefFile -Raw -Encoding UTF8 | ConvertFrom-Json; $appCfg = $j } catch {}
            }
            $appCfg.minimizeOnStart = $false
            try { ($appCfg | ConvertTo-Json) | Out-File $AppDefFile -Encoding utf8 -Force } catch {}
        }
    } catch {
        Write-Host "First-run dialog error (ignoring): $($_.Exception.Message)"
    }
}

# Everything that may need typing (first-time login setup) or can fail early has run with the window. Now the tool restarts itself
# in the background with NO window. Start-Visible.bat (-ShowWindow) keeps the window, like before.
# Hand-over: everything that needs typing or can fail is done. Now restart this script hidden (-Background) and end this window.
if (-not $Background -and -not $ShowWindow) {
    Write-Host 'Starting the Admin Console in the background (no window). The page opens in a moment - use Shut down in the page to stop it.' -ForegroundColor Cyan
    Start-Process -FilePath 'powershell.exe' -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Background" + $(if ($Splash) { ' -Splash' } else { '' })) -WindowStyle Hidden -WorkingDirectory $Root
    exit 0
}
Set-Start 'screens' 'ok' 'Screens' "$($ScreenFiles.Count) screens and the activity log loaded"
# The Microsoft sign-in of newer Graph modules (Windows broker, WAM) must be given a window. Started with no console at all, the
# process has none ('A window handle must be configured'), so make sure there is a console window - hidden, never shown.
try {
    # Small Windows API helpers so a hidden console window can exist (the Microsoft sign-in needs a window handle).
    Add-Type -Namespace StWin -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern bool AllocConsole();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
'@ -ErrorAction Stop
} catch {}
# Makes sure the process has a console window (creates one if started without), hidden when running in the background.
function Confirm-SignInWindow {
    try {
        if ([StWin.Native]::GetConsoleWindow() -eq [IntPtr]::Zero) { [void][StWin.Native]::AllocConsole() }
        $h = [StWin.Native]::GetConsoleWindow()
        if ($Background -and $h -ne [IntPtr]::Zero) { [void][StWin.Native]::ShowWindow($h, 0) }   # 0 = hidden
        return ($h -ne [IntPtr]::Zero)
    } catch { return $false }
}
if ($Background) { [void](Confirm-SignInWindow) }
if ($Background) {
    # No window: the Windows sign-in broker (WAM) of newer Microsoft Graph modules needs one, so sign in through the web browser instead
    try { $o = Get-Command Set-MgGraphOption -ErrorAction Stop; if ($o.Parameters.ContainsKey('DisableLoginByWAM')) { Set-MgGraphOption -DisableLoginByWAM $true } } catch {}
}
# STEP: ADDRESS / HOSTS / URL RESERVATION. Friendly name: http://supporttool:8080/ (needs a hosts-file entry = administrator).
# Without administrator the tool still works on http://localhost:8080/.
$HostName = 'supporttool'   # change this to any simple name you like
# Is this PowerShell running as administrator? (Needed for the hosts file and for binding the HTTPS certificate.)
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Address = 'localhost'; $listener = $null
Set-Start 'web' 'run' 'Web page' 'starting...'
# Creates and starts the HTTP listener. $withName = also answer on http://supporttool:PORT/. If HTTPS is enabled in Settings and the
# certificate exists in the machine store, it is bound to the HTTPS port and https://+:PORT/ is added. If that fails, falls back to http only.
function New-Listener($withName) {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add("http://localhost:$Port/")
    if ($withName) { $l.Prefixes.Add("http://${HostName}:$Port/") }
    # v1.98.31: HTTPS with your certificate (Settings > HTTPS / SSL certificate) - needs administrator; the certificate is bound to the port in HTTP.sys
    $script:HttpsOn = $false
    try { $hc = Get-HttpsCfg; if ($hc.enabled -and $IsAdmin -and $hc.thumb -and (Get-Item "Cert:\LocalMachine\My\$($hc.thumb)" -ErrorAction SilentlyContinue)) {
        if ((Get-SslBinding $hc.port) -ne "$($hc.thumb)".ToUpper()) { Set-SslBinding $hc.port $hc.thumb }
        $l.Prefixes.Add("https://+:$($hc.port)/"); $script:HttpsOn = $true; Write-Host "HTTPS: also answering on https://$(if ($hc.host) { $hc.host } else { $env:COMPUTERNAME }):$($hc.port)/" -ForegroundColor Green } } catch { Write-Host "HTTPS could not be started: $($_.Exception.Message)" -ForegroundColor Yellow }
    try { $l.Start() } catch {
        if (-not $script:HttpsOn) { throw }
        Write-Host "HTTPS could not start ($($_.Exception.Message)) - the tool runs on http only. Check Settings > HTTPS (is the port used by IIS?)." -ForegroundColor Yellow
        $script:HttpsOn = $false; $script:HttpsErr = $_.Exception.Message; try { $l.Close() } catch {}
        $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$Port/"); if ($withName) { $l.Prefixes.Add("http://${HostName}:$Port/") }; $l.Start()
    }
    $l
}
if ($IsAdmin) {
    try {
        # Add '127.0.0.1 supporttool' to the Windows hosts file if it is not there yet, flush the DNS cache, check the line was really saved
        # (security software may block it), then start the listener with the friendly name. On any error fall back to localhost.
        $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
        if (-not (Select-String -Path $hostsFile -Pattern "^\s*127\.0\.0\.1\s+$HostName\s*$" -Quiet)) {
            Add-Content -Path $hostsFile -Value "`r`n127.0.0.1`t$HostName"
        }
        try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns *> $null } catch {}   # forget an earlier 'unknown name' answer
        if (-not (Select-String -Path $hostsFile -Pattern "^\s*127\.0\.0\.1\s+$HostName\s*$" -Quiet)) { throw "the hosts file entry for '$HostName' was not saved (security software may block changes to the hosts file)" }
        $listener = New-Listener $true; $Address = $HostName
    } catch { $script:HostsErr = $_.Exception.Message; Write-Host "Could not enable the friendly address ($($_.Exception.Message)) - using localhost." -ForegroundColor Yellow; try { $listener.Stop() } catch {}; $listener = $null; $Address = 'localhost' }
}
# No friendly name possible: start on localhost only. If even that fails the tool cannot run.
if (-not $listener) { try { $listener = New-Listener $false } catch { Stop-Fatal "The Admin Console could not start its web page on port $Port`: $($_.Exception.Message)" } }
if ($script:VerNote) { Write-Host $script:VerNote -ForegroundColor Yellow }
# Tell the user and the start window the address, remember it in logs\address.txt, and open the browser (not after a restart).
Write-Host "Admin Console v$AppVersion running at http://${Address}:$Port/  (use the Shut down button in the page to stop)"
if ($Address -eq 'localhost') { Write-Host "Started normally, so the page is http://localhost:$Port/ . To use http://${HostName}:$Port/ start the tool as administrator (right-click > Run as administrator)." -ForegroundColor Yellow }
try { "http://${Address}:$Port/" | Set-Content -Path (Join-Path $Root 'logs\address.txt') -Encoding ASCII } catch {}
if ($IsAdmin -and $Address -eq 'localhost' -and $script:HostsErr) { Set-Start 'web' 'warn' 'Web page' "http://localhost:$Port/ - http://supporttool could not be used: $($script:HostsErr)" }
else { Set-Start 'web' 'ok' 'Web page' $("http://${Address}:$Port/" + $(if ($Address -eq 'localhost') { ' (start as administrator for http://supporttool)' } else { '' })) }
Set-StartEnd "DONE|http://${Address}:$Port/"
if (-not $NoBrowser) { Start-Process "http://${Address}:$Port/" }

# =====================================================================================================================
# THE REQUEST LOOP. One request at a time. Each round: (a) wait for a request while running the once-per-second timers,
# (b) load the sender's session, (c) security gate, (d) read the body, (e) checks (whitelist, token, session, permission),
# (f) route with `switch ($path)`: screen handlers first, then the built-in routes, (g) always save the session afterwards.
# =====================================================================================================================
Save-SessDefaults   # v2.0.0: the empty state every new session starts from
Use-Sess $null
while ($listener.IsListening) {
    # Wait for a request, checking the auto sign-out timer once per second
    # Start waiting for the next request; the inner loop wakes up every 1000 ms to do the background work below.
    $task = $listener.GetContextAsync()
    while (-not $task.Wait(1000)) {
        # v2.0.0: the timers of EVERY session (auto sign-out, AD idle time, portal timeout, Microsoft token renewal, closed tab)
        # Timer work for EVERY session each second: AD idle timeout, AD/Microsoft auto sign-out, tool login timeout, token renewal,
        # and the 'browser tab closed' action (sign out or shut down after 12 seconds without a page coming back).
        $stopNow = $false
        foreach ($sx in @(Get-SessList)) {
            $sid = $sx.sid
            try {
                Use-Sess $sid
                if ($script:AdCred -and ((Get-Date) - $script:AdLast).TotalMinutes -ge $script:AdIdleMins) {
                    Clear-Ad; Write-Host "On-premises AD sign-in of $($script:SessUser.name) ended after inactivity." -ForegroundColor Yellow
                }
                if ($script:AdCred -and $script:AdLogoutAt -and (Get-Date) -ge $script:AdLogoutAt) {
                    Clear-Ad; Write-Host "Auto sign-out: on-premises AD sign-in of $($script:SessUser.name) ended." -ForegroundColor Yellow
                }
                if ($script:Who -and $script:LogoutAt -and (Get-Date) -ge $script:LogoutAt) {
                    Exit-StGraph 'Auto sign-out (Microsoft)'
                    Clear-Who
                    Write-Host "Auto sign-out: Microsoft sign-in of $($script:SessUser.name) ended." -ForegroundColor Yellow
                }
                Test-SessionTimeout
                Update-MsToken
                if ($script:CloseAt -and (Get-Date) -ge $script:CloseAt) {   # the tab was closed and no page came back (a reload does): do what was chosen
                    $ca = $script:CloseAct; $script:CloseAt = $null
                    if ($ca -eq 'shutdown' -and @(Get-SessList).Count -gt 1) { $ca = 'signout'; Write-Host 'Tab closed: other people are signed in, so the server keeps running (only this person is signed out).' -ForegroundColor Yellow }   # v2.0.0
                    if ($ca -eq 'signout') { try { Write-ActRow 'Tool' 'Tab closed' '' 'Done - signed out of Microsoft and AD' '' } catch {}; Stop-AllSignIns; Write-Host 'Tab closed: signed out of Microsoft and AD.' -ForegroundColor Yellow }
                    elseif ($ca -eq 'shutdown') { try { Write-ActRow 'Tool' 'Shut down' '' 'Done - tab closed' '' } catch {}; $stopNow = $true }
                }
            } catch { Write-Host "Session timer: $($_.Exception.Message)" -ForegroundColor Yellow }
            finally { Save-Sess $sid }
            if ($stopNow) { break }
        }
        if ($stopNow) { Stop-AllSessions 'Microsoft sign-out (tab closed, tool shut down)'; $listener.Stop(); Write-Host 'Server stopped (tab closed).'; break }
        # the log copy to SharePoint uses the Microsoft sign-in of the person who has been signed in the longest
        # Copy the logs to SharePoint using the Microsoft sign-in of the person signed in the longest.
        $spx = @(Get-SessList | Where-Object { $_.st.Who } | Sort-Object { $_.st.SessStart } | Select-Object -First 1)
        if ($spx.Count) { try { Use-Sess $spx[0].sid; Use-SessGraph; Invoke-SpIdle } catch {} finally { Save-Sess $spx[0].sid } }
        Use-Sess $null
        if (Test-Path $StopFile) {   # SupportTool-Stop.exe: shut down cleanly, like the Shut down button
            Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
            try { Write-ActRow 'Tool' 'Shut down' '' 'Done - stop signal' '' } catch {}
            Stop-AllSessions 'Microsoft sign-out (tool shut down)'
            $listener.Stop(); Write-Host 'Server stopped (stop signal).'
            break
        }
    }
    if (-not $listener.IsListening) { break }
    # A request arrived. Reset what the activity log remembers about it.
    $ctx = $task.Result
    $script:ActResp = $null; $script:ActCode = 0
    # v2.0.0: load the session of the browser that sent this request (by its cookie)
    # Which session? Look up the 'sid' cookie in the session store; unknown cookie = nobody signed in.
    $csid = $null; try { $ck = $ctx.Request.Cookies['sid']; if ($ck -and $script:Sessions.ContainsKey("$($ck.Value)")) { $csid = "$($ck.Value)" } } catch {}
    Use-Sess $csid
    # v2.4.0: allowed IP addresses, HTTPS only, request size, security headers - before anything of the request is read
    Set-ClientInfo $ctx
    if (Invoke-SecGate $ctx ([bool]$csid)) { Use-Sess $null; continue }
    try {
        $d = $null
        $script:SsoRawBody = $null
        # Read the body. For /sso/ paths keep the raw form text (SAML); otherwise it is JSON and becomes $d (the 'd' fields used by all handlers).
        if ($ctx.Request.HasEntityBody) { $raw = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd(); if ($ctx.Request.Url.AbsolutePath -like '/sso/*') { $script:SsoRawBody = $raw } else { $d = $raw | ConvertFrom-Json } }   # v1.98.32: SAML answers are form posts
        $path = $ctx.Request.Url.AbsolutePath
        Set-ClientInfo $ctx
        if (Get-Command Add-SeenClient -ErrorAction SilentlyContinue) { Add-SeenClient $ctx $path }   # v1.98.39: Who is signed in screen
        try {
            # Take the browser time zone from the headers (offset must be within +-14 hours; the name is checked with a simple regex).
            $tzh = $ctx.Request.Headers['X-TZ-Min']
            if ($tzh -match '^-?\d{1,4}$' -and [math]::Abs([int]$tzh) -le 14 * 60) { $script:ClientTzMin = [int]$tzh; $tzn = "$($ctx.Request.Headers['X-TZ-Name'])"; $script:ClientTzName = $(if ($tzn -match '^[A-Za-z0-9_/+-]{1,40}$') { $tzn } else { '' }) }
        } catch {}
        # CHECK 1: only whitelisted API paths. CHECK 2: correct X-Token AND a valid sign-in session. CHECK 3: this user's permission for the path.
        if ($path -like '/api/*' -and $path -notin $AllowedApi) { Send $ctx @{ error = 'This action is not allowed. The tool can unlock, enable, disable, reset passwords, revoke MFA, change groups, add Teams members, set expiry and search - it never deletes accounts.' } 403; continue }
        if ($path -like '/api/*' -and ($ctx.Request.Headers['X-Token'] -ne $Token -or -not (Test-Session $ctx))) { Send $ctx @{ error = 'Forbidden' } 403; continue }
        if ($path -like '/api/*') { $deny = Get-ApiDenied $path $d; if ($deny) { Send $ctx @{ error = $deny; denied = $true } 403; continue } }
        # Any API call from an open page cancels a pending 'tab closed' action (a reload would otherwise sign the person out).
        if ($path -like '/api/*' -and $path -ne '/api/tab-closed') { $script:CloseAt = $null }
        # Make the shared Microsoft Graph connection belong to this person, and renew it if it ended (except while connecting).
        if ($path -like '/api/*' -or $path -eq '/') { Use-SessGraph }   # v2.0.0: Microsoft Graph as THIS person
        if ($path -like '/api/*' -and $script:Who -and $path -notin '/api/connect', '/api/ms-login-start') { if (-not (Repair-MsGraph)) { Clear-Who; $script:MsErr = 'The Microsoft 365 sign-in has ended. Sign in again from Settings > Connections.' } }   # any page that is still open cancels a pending tab-closed action (reload, second tab)
        # ROUTING. First entry: any path registered by a Screen-*.ps1 file runs that screen's script block. Then the built-in routes.
        switch ($path) {
            { $ScreenHandlers.ContainsKey($_) } { $screenFn = $ScreenHandlers[$_]; . $screenFn }
            { $_ -like '/sso/*' } { Invoke-SsoRoute $ctx $path; break }   # v1.98.32: single sign-on (OIDC / SAML)
            # GET /login-logo : the optional logo for the single sign-on button (a sso-logo.svg/.png file next to the tool). 404 when none.
            '/login-logo' {
                # v1.98.34: the logo on the single sign-on button - a file named sso-logo.svg / .png next to the tool (Settings > Single sign-on)
                $lf = Get-SsoLogo; if (-not $lf) { $ctx.Response.StatusCode = 404; $ctx.Response.Close(); break }
                $b = [IO.File]::ReadAllBytes($lf.FullName); $ctx.Response.ContentType = $(if ($lf.Extension -eq '.svg') { 'image/svg+xml' } else { 'image/png' }); $ctx.Response.Headers.Add('Cache-Control', 'max-age=3600'); $ctx.Response.Headers.Set('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src data:; sandbox"); $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()   # v2.4.0: a picture can never run script
            }
            # GET /login-info : answers for the sign-in page before sign-in: is 'Sign in with AD' offered, which SSO mode/button, SSO-only?
            '/login-info' {
                # v1.98.11: for the sign-in page (before signing in): is "Sign in with AD" offered?
                $ac = Get-AdLoginCfg
                $sc = Get-SsoCfg
                Send $ctx @{ ad = [bool]($ac.enabled -and $script:AdAvail -and @($ac.groups).Count); domain = "$env:USERDOMAIN"; sso = $(if ($sc.mode -ne 'off') { $sc.mode } else { '' }); ssoButton = "$($sc.button)"; ssoOnly = [bool]($sc.mode -ne 'off' -and $sc.ssoOnly); ssoLogo = "$(Get-SsoLogo | ForEach-Object { $_.LastWriteTime.Ticks })" }
            }
            # POST /login : the sign-in. Body: username, password, mode ('ad' or portal), optional 2-step code.
            # Order: SSO-only check -> empty check -> IP block -> account lock (5 wrong = 15 min) -> check password (owner hash, tool user, or AD)
            # -> 2-step code -> create a NEW session + cookie. A wrong password waits 700 ms (slows guessing) and counts towards the lock.
            '/login' {
                if ($ctx.Request.HttpMethod -ne 'POST') { Send $ctx @{ error = 'Not found' } 404; break }
                $mode = if ("$($d.mode)" -eq 'ad') { 'ad' } else { 'portal' }
                $ssc = Get-SsoCfg; if ($ssc.mode -ne 'off' -and $ssc.ssoOnly -and -not (Test-Login $d.username $d.password)) { Start-Sleep -Milliseconds 700; Write-LoginLog $d.username 'Refused (single sign-on only)'; Send $ctx @{ error = 'This portal uses single sign-on only - click "' + $ssc.button + '".' } 403; break }   # v1.98.33: the owner login still works (emergency)
                # Key used for the lock counter (username + mode).
                $key = Get-LoginKey $d.username $mode
                if (-not "$($d.username)".Trim() -or -not "$($d.password)") { Send $ctx @{ error = 'Type your username and password.' } 400; break }
                $ipb = Test-IpLoginBlocked "$($script:ClientIp)"; if ($ipb) { Write-LoginLog $d.username "Refused (this PC $($script:ClientIp) is blocked after too many wrong passwords)"; Send $ctx @{ error = "Too many wrong passwords from this PC. Try again after $($ipb.ToString('HH:mm'))." } 429; break }   # v2.4.0
                # locked? only THIS username is told - everyone else signs in normally
                $lk = Get-LoginLock $key
                if ($lk) {
                    $w = [int][math]::Ceiling(($lk - (Get-Date)).TotalMinutes)
                    Write-LoginLog $d.username 'Refused (locked after wrong passwords)'
                    Send $ctx @{ error = "This account is locked after $($script:LoginMaxFails) wrong passwords. Try again in $w minute$(if ($w -ne 1) { 's' }) (at $($lk.ToString('HH:mm')))."; lockedUntil = $lk.ToUniversalTime().ToString('o') } 429; break
                }
                # Check the password. $loginWho = 'owner', a tool-user record, or an AD result; $null = wrong.
                $loginWho = $null; $adWho = $null
                if ($mode -eq 'ad') {
                    $adWho = Test-AdPortalLogin $d.username $d.password
                    if ($adWho.denied) { Write-LoginLog $d.username "Refused (AD): $($adWho.denied)"; Clear-LoginFails $key; Send $ctx @{ error = $adWho.denied } 403; break }
                    if ($adWho.ok) { $loginWho = $adWho }
                } else {
                    if (Test-Login $d.username $d.password) { $loginWho = 'owner' } else { $loginWho = Test-ToolUserLogin $d.username $d.password }
                    if ($loginWho -and $loginWho -isnot [string] -and $loginWho.denied) { Write-LoginLog $d.username "Refused: $($loginWho.denied)"; Clear-LoginFails $key; Send $ctx @{ error = $loginWho.denied } 403; break }   # expired (portal or AD)
                }
                if ($loginWho) {   # v2.4.0: 2-step sign-in (authenticator app) after the password
                    $tfKey = if ($adWho) { "ad:$($adWho.sam)" } elseif ($loginWho -is [string]) { 'owner' } else { "u:$($loginWho.username)" }
                    $tfAdm = [bool]($loginWho -is [string] -or ($adWho -and "$($adWho.role)" -eq 'admin') -or (-not $adWho -and $loginWho -isnot [string] -and "$($loginWho.role)" -eq 'admin'))
                    $tfa = Invoke-TfaGate $tfKey "$($d.username)".Trim() $tfAdm $d
                    if ($tfa) { if ($tfa.bad) { Add-IpLoginFail "$($script:ClientIp)"; $f = Add-LoginFail $key; Write-LoginLog $d.username 'Failed (wrong 2-step code)'; if ($f.locked) { $tfa = @{ ok = $false; error = "Too many wrong codes - this account is locked for $($script:LoginLockMins) minutes." } } }; Send $ctx $tfa $(if ($tfa.needOtp -or $tfa.enroll) { 200 } else { 429 }); break }
                }
                if ($loginWho) {
                    # Success: build the new session. Name shown in logs: Owner / AD name / tool user name.
                    $nm = if ($loginWho -is [string]) { 'Owner' } elseif ($adWho) { "$($adWho.name)" } else { "$($loginWho.username)" }
                    # v2.0.0: many people can be signed in at the same time - each gets a new, empty session of their own
                    # (a session this browser had before is closed: its Microsoft and AD sign-ins end)
                    if ($script:Session) { try { Exit-StGraph 'Microsoft sign-out (new portal sign-in in this browser)'; Clear-Who; Clear-Ad } catch {} }
                    Reset-SessVars
                    Clear-LoginFails $key; $script:Session = New-SessToken; $script:SessStart = Get-Date; $script:SessLast = $script:SessStart; $script:SessUa = "$($ctx.Request.UserAgent)"
                    $script:SessIp = $script:ClientIp; $script:SessPc = $script:ClientPc
                    if ($adWho) {
                        $script:SessUser = @{ name = $adWho.name; owner = $false; role = $adWho.role; perms = @($adWho.perms); mustChange = $false; ad = $true; adSam = $adWho.sam; adGroup = $adWho.group }
                        # one sign-in for both: the portal AND the on-premises AD screens use this AD account
                        $script:AdCred = @{ User = $adWho.user; Sam = $adWho.sam; Dnc = $adWho.dnc; Pass = (ConvertTo-SecureString "$($d.password)" -AsPlainText -Force) }; $script:AdLast = Get-Date
                        $script:AdLogoutAt = if ($script:AdAutoMins -gt 0) { (Get-Date).AddMinutes($script:AdAutoMins) } else { $null }
                        Write-LoginLog $d.username "Success (AD sign-in, group $($adWho.group), role $($adWho.role))"
                    } else {
                        Set-SessUser $loginWho; if ($loginWho -isnot [string]) { Set-UserLastLogin $nm }
                        Write-LoginLog $d.username $(if ($loginWho -is [string]) { 'Success (owner sign-in)' } else { 'Success (normal sign-in, tool user)' })
                        if ($loginWho -isnot [string]) { Connect-AssignedAd $loginWho }   # v2.0.0: the AD account an administrator set for this person
                    }
                    # Give the browser its session cookie: HttpOnly (scripts cannot read it), SameSite=Lax; 'Secure' is added when HTTPS is used.
                    $ctx.Response.Headers.Add('Set-Cookie', "sid=$($script:Session); Path=/; HttpOnly; SameSite=Lax" + (Get-CookieSecure $ctx))
                    Send $ctx @{ ok = $true }
                } else {
                    Start-Sleep -Milliseconds 700
                    Add-IpLoginFail "$($script:ClientIp)"
                    $f = Add-LoginFail $key
                    Write-LoginLog $d.username $(if ($f.locked) { "Failed - locked for $($script:LoginLockMins) minutes" } else { "Failed ($($f.fails) of $($script:LoginMaxFails))" })
                    $why = if ($adWho -and $adWho.error) { $adWho.error } else { 'Incorrect username or password.' }
                    if ($f.locked) { Send $ctx @{ error = "$why This account is now locked for $($script:LoginLockMins) minutes (until $($f.until.ToString('HH:mm'))) after $($script:LoginMaxFails) wrong passwords."; lockedUntil = $f.until.ToUniversalTime().ToString('o') } 429 }
                    else { $left = $script:LoginMaxFails - $f.fails; Send $ctx @{ error = "$why $left attempt$(if ($left -ne 1) { 's' }) left before this account is locked for $($script:LoginLockMins) minutes." } 401 }
                }
            }
            # GET / : the main page. Mail/Microsoft sign-in return links are completed first. Without a valid session the SIGN-IN page (login.html) is
            # shown; with one, index.html with __APPVER__, __TOKEN__ (API token) and __LOGTZ__ filled in. no-store = never cached.
            '/' {
                if ($ctx.Request.QueryString['state'] -and "$($ctx.Request.QueryString['state'])".StartsWith('mail') -and $script:MailAuth.ContainsKey("$($ctx.Request.QueryString['state'])")) { Complete-MailAcctLogin $ctx; break }   # v1.98.37: mail account sign-in
                if ($ctx.Request.QueryString['state'] -and ($ctx.Request.QueryString['code'] -or $ctx.Request.QueryString['error'])) { Complete-MsLogin $ctx; break }
                if (-not (Test-Session $ctx)) {
                    $b = [Text.Encoding]::UTF8.GetBytes((Get-Content (Get-CodePath 'login.html') -Raw -Encoding UTF8).Replace('__APPVER__', $AppVersion))
                    $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.Headers.Add('Cache-Control', 'no-store')
                    $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close(); break
                }
                $b = [Text.Encoding]::UTF8.GetBytes((Get-Content (Get-CodePath 'index.html') -Raw -Encoding UTF8).Replace('__APPVER__', $AppVersion).Replace('__TOKEN__', $Token).Replace('__LOGTZ__', $script:LogTz))
                $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.Headers.Add('Cache-Control', 'no-store')
                $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
            }
            # /api/status : state of the signed-in person for the page (who is connected, timers, notes). Checks the Graph session first.
            '/api/status' { if ($script:Who) { if (-not (Repair-MsGraph)) { Clear-Who; $script:MsErr = 'The Microsoft 365 sign-in has ended (no Microsoft Graph session). Sign in again from Settings > Connections.' } }; $msE = $script:MsErr; $msN = $script:MsNote; $script:MsErr = $null; $script:MsNote = $null; Send $ctx @{ user = @{ name = $script:SessUser.name; owner = [bool]$script:SessUser.owner; role = $script:SessUser.role; perms = @($script:SessUser.perms); mustChange = [bool]$script:SessUser.mustChange }; version = $AppVersion; verNote = $script:VerNote; name = $script:WhoName; autoMins = $script:AutoMins; logoutAt = (Get-LogoutIso); adAutoMins = $script:AdAutoMins; adLogoutAt = (Get-AdLogoutIso); sessIdleMins = $script:SessIdleMins; ad = $script:AdAvail; graph = $script:GraphVer; who = $script:Who; adUser = $(if ($script:AdCred) { $script:AdCred.User } else { $null }); linked = (Get-Linked); scopes = $(if ($script:Who) { @(Get-MsScopes) } else { @() }); msError = $msE; msNote = $msN; adNote = $(if ($script:AdNote) { $n = $script:AdNote; $script:AdNote = $null; $n } else { $null }); multi = @{ sessions = $script:Sessions.Count + $(if ($script:Session -and -not $script:Sessions.ContainsKey($script:Session)) { 1 } else { 0 }); msApp = [bool](Get-MsAppCfg).clientId; assignedMs = $(if ($am = Get-AssignedMs) { $am.upn } else { '' }); assignedMsLock = [bool]$(if ($am) { $am.lock } else { $false }); assignedAd = $(if ($aa = Get-AssignedAd) { $aa.user } else { '' }); assignedAdLock = [bool]$(if ($aa) { $aa.lock } else { $false }) } } }
            # /api/connect : Microsoft sign-in. mode 'cert' = app + certificate (tenantId, clientId, thumbprint); otherwise the old interactive
            # Connect-MgGraph window (only on the server itself). Body also: autoMins (auto sign-out 5-1440 min), hint (account the person chose).
            '/api/connect' {
                # Start from a clean slate: a failed or cancelled sign-in must never leave the previous person's identity behind
                Exit-StGraph 'Microsoft sign-out (new sign-in)'
                Clear-Who
                try {
                    if ($d.mode -eq 'cert') {
                        Connect-MgGraph -TenantId $d.tenantId -ClientId $d.clientId -CertificateThumbprint $d.thumbprint -NoWelcome; $script:GraphSid = $script:Session
                        $script:CertInfo = @{ AppId = "$($d.clientId)"; Thumb = "$($d.thumbprint)"; Tenant = "$($d.tenantId)"; Org = $null }
                        try { $script:CertInfo.Org = "$((@((Get-MgOrganization -ErrorAction Stop).VerifiedDomains) | Where-Object { $_.IsInitial } | Select-Object -First 1).Name)" } catch {}
                    } else {
                        # v2.0.0: several people use the tool at the same time, so a sign-in window on the server cannot be used
                        # v2.4.0: the old sign-in (Connect-MgGraph window) - only when you sit at the server, because the window opens there
                        if (-not $d.old) { throw 'Use "Choose on the Microsoft page" or "Sign in with a code" to connect to Microsoft.' }
                        # The old sign-in opens a window ON THE SERVER, so it is refused for requests from other PCs.
                        $own = @('127.0.0.1', '::1', '::ffff:127.0.0.1'); try { $own += @([Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | ForEach-Object { "$_" }) } catch {}
                        if ("$($script:ClientIp)" -notin $own) { throw 'The old sign-in opens a window on the server, so it only works on the server itself. From this PC use "Choose on the Microsoft page" or "Sign in with a code".' }
                        $script:GraphSid = $null; try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}
                        # Microsoft Graph permissions (scopes) asked for at sign-in; the person must have the matching admin roles.
                        $scopes = 'DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'Device.ReadWrite.All', 'Reports.Read.All', 'User.Read.All', 'Domain.Read.All', 'User.EnableDisableAccount.All', 'User-PasswordProfile.ReadWrite.All', 'UserAuthenticationMethod.ReadWrite.All', 'Group.ReadWrite.All', 'Mail.Send', 'Mail.Send.Shared', 'Sites.ReadWrite.All', 'User.Invite.All', 'AuditLog.Read.All', 'Directory.Read.All'
                        [void](Confirm-SignInWindow)
                        $cp = @{ Scopes = $scopes; NoWelcome = $true }; if ("$($d.tenantId)".Trim()) { $cp.TenantId = "$($d.tenantId)".Trim() }
                        try { Connect-MgGraph @cp }
                        catch {
                            # Workaround: newer Graph modules use the Windows broker (WAM) which needs a window; if that fails, retry with browser sign-in.
                            if ($_.Exception.Message -notmatch 'window handle|WAM|parent-window|broker') { throw }
                            # The Windows sign-in (WAM) could not use the window: sign in through the web browser instead
                            $o = Get-Command Set-MgGraphOption -ErrorAction SilentlyContinue
                            if ($o -and $o.Parameters.ContainsKey('DisableLoginByWAM')) {
                                Set-MgGraphOption -DisableLoginByWAM $true
                                try { Connect-MgGraph @cp }
                                catch { throw "Microsoft sign-in could not open: $($_.Exception.Message) | Start the tool with Start-Visible.bat once and sign in there, or update the Microsoft Graph module." }
                            } else { throw "Microsoft sign-in needs a window that the tool does not have in the background. Start the tool with Start-Visible.bat, or update the Microsoft Graph module (Update-Module Microsoft.Graph.Authentication). Details: $($_.Exception.Message)" }
                        }
                    }
                    if ($d.old -and $d.mode -ne 'cert') {   # keep this person's token: other people switch the shared Graph connection
                        $script:GraphSid = $script:Session; $script:MsRefresh = $null; $script:MsOld = $true
                        try { $m = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id' -OutputType HttpResponseMessage -ErrorAction Stop; $script:MsAccess = "$($m.RequestMessage.Headers.Authorization.Parameter)"; $script:MsExp = (Get-Date).AddMinutes(55) } catch {}
                    }
                    $c = Get-MgContext
                    if (-not $c -or (-not $c.Account -and -not $c.ClientId)) { throw 'Microsoft sign-in did not finish (no Microsoft Graph session). Try Connect again.' }
                    $script:Who = if ($c.Account) { $c.Account } else { "app:$($c.ClientId)" }
                    try {
                        if ($c.Account) {
                            $me = Get-MgUser -UserId $c.Account -Property GivenName, Surname, DisplayName, UserPrincipalName, OnPremisesSamAccountName, OnPremisesSyncEnabled, OnPremisesDomainName
                            $script:WhoUpn = "$($me.UserPrincipalName)"; $script:WhoSam = "$($me.OnPremisesSamAccountName)"
                            $script:WhoSynced = [bool]$me.OnPremisesSyncEnabled; $script:WhoDom = "$($me.OnPremisesDomainName)"
                            $script:WhoName = ("$($me.GivenName) $($me.Surname)").Trim()
                            if (-not $script:WhoName) { $script:WhoName = "$($me.DisplayName)" }
                            $script:WhoFirst = "$($me.GivenName)"; $script:WhoLast = "$($me.Surname)"; $script:WhoDisp = "$($me.DisplayName)"
                        } else { $script:WhoName = 'Certificate sign-in (app)' }
                    } catch {}
                    # Remember the account (name only - never a password) for the account pop-up; say when it is not the one that was chosen
                    if ($c.Account) { Save-RecentAccount $c.Account $script:WhoName }
                    $hintNote = $null
                    if ($c.Account -and "$($d.hint)".Trim() -and "$($d.hint)".Trim() -ine "$($c.Account)") { $hintNote = "You chose $("$($d.hint)".Trim()) but Microsoft signed you in as $($c.Account). Sign out and connect again, then pick the right account in the Microsoft window (or Use another account)." }
                    $script:AutoMins = [int]$d.autoMins
                    if ($script:AutoMins -ne 0 -and ($script:AutoMins -lt 5 -or $script:AutoMins -gt 1440)) { $script:AutoMins = 0 }
                    $script:LogoutAt = if ($script:AutoMins -gt 0) { (Get-Date).AddMinutes($script:AutoMins) } else { $null }
                } catch {
                    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
                    Clear-Who
                    throw
                }
                # An on-premises sign-in made earlier stays open, also when it is a different (for example admin) AD account
                $cnNote = $hintNote
                Send $ctx @{ ok = $true; who = $script:Who; name = $script:WhoName; scopes = @($c.Scopes); logoutAt = (Get-LogoutIso); linked = (Get-Linked); adUser = $(if ($script:AdCred) { $script:AdCred.User } else { $null }); adNote = $cnNote }
            }
            # /api/autologout : Body minutes (0 = off, else 5-1440). Sets when the Microsoft sign-in ends by itself.
            '/api/autologout' {
                $m = [int]$d.minutes
                if ($m -ne 0 -and ($m -lt 5 -or $m -gt 1440)) { throw 'Auto sign-out must be between 5 minutes and 24 hours.' }
                $script:AutoMins = $m
                $script:LogoutAt = if ($m -gt 0 -and $script:Who) { (Get-Date).AddMinutes($m) } else { $null }
                Send $ctx @{ ok = $true; logoutAt = (Get-LogoutIso) }
            }
            # /api/ad-autologout : same for the on-premises AD sign-in.
            '/api/ad-autologout' {
                $m = [int]$d.minutes
                if ($m -ne 0 -and ($m -lt 5 -or $m -gt 1440)) { throw 'Auto sign-out must be between 5 minutes and 24 hours.' }
                $script:AdAutoMins = $m
                $script:AdLogoutAt = if ($m -gt 0 -and $script:AdCred) { (Get-Date).AddMinutes($m) } else { $null }
                Send $ctx @{ ok = $true; adLogoutAt = (Get-AdLogoutIso) }
            }
            # /api/session-timeout : minutes (5-480) of inactivity after which the tool login ends.
            '/api/session-timeout' {
                $m = [int]$d.minutes
                if ($m -lt 5 -or $m -gt 480) { throw 'The tool login timeout must be between 5 minutes and 8 hours.' }
                $script:SessIdleMins = $m
                $script:SessLast = Get-Date
                Write-LoginLog '(tool login)' "Timeout set to $m minutes"
                Send $ctx @{ ok = $true; sessIdleMins = $script:SessIdleMins }
            }
            # /api/signout-all : sign out of Microsoft and AD, keep the tool login.
            '/api/signout-all' {
                Stop-AllSignIns
                Write-LoginLog '(tool login)' 'Signed out of Microsoft and on-premises AD (tool login kept)'
                Send $ctx @{ ok = $true }
            }
            # /api/signout : sign out of Microsoft only.
            '/api/signout' {
                Exit-StGraph
                Clear-Who
                Send $ctx @{ ok = $true }
            }
            # /api/ad-connect : on-premises AD sign-in. Body: username, password, optional autoMins. 3 failures lock this for 60 seconds.
            '/api/ad-connect' {
                if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so on-premises sign-in is unavailable.' }
                if ((Get-Date) -lt $script:AdLockUntil) {
                    $w = [int][math]::Ceiling(($script:AdLockUntil - (Get-Date)).TotalSeconds)
                    Send $ctx @{ error = "Too many failed on-premises sign-ins. Try again in $w seconds." } 429; break
                }
                $u = "$($d.username)".Trim(); $pw = "$($d.password)"
                if (-not $u -or -not $pw) { throw 'Enter your on-premises username and password.' }
                if ($u -notmatch '[\\@]') { $u = "$env:USERDOMAIN\$u" }
                $asg = Get-AssignedAd
                if ($asg -and $asg.lock -and (("$u" -replace '^.*\\', '' -replace '@.*$', '') -ine ("$($asg.user)" -replace '^.*\\', '' -replace '@.*$', ''))) { throw "Your administrator set this portal account to use the AD account $($asg.user) - sign in with that account." }
                try { $r = Connect-AdAccount $u $pw }
                catch {
                    $script:AdFails++
                    if ($script:AdFails -ge 3) { $script:AdFails = 0; $script:AdLockUntil = (Get-Date).AddSeconds(60) }
                    Write-LoginLog '(not recorded)' 'On-prem AD sign-in: Failed'
                    Start-Sleep -Milliseconds 700
                    throw ('On-premises sign-in failed: ' + (Get-ErrMsg $_))
                }
                $script:AdFails = 0
                if ($null -ne $d.autoMins) { $am = [int]$d.autoMins; if ($am -eq 0 -or ($am -ge 5 -and $am -le 1440)) { $script:AdAutoMins = $am } }
                $script:AdLogoutAt = if ($script:AdAutoMins -gt 0) { (Get-Date).AddMinutes($script:AdAutoMins) } else { $null }
                Write-LoginLog $u $(if ($r.other) { "On-prem AD sign-in: Success (separate AD account - the Microsoft sign-in is $($script:WhoUpn), linked to $((Get-Linked).sam))" } else { 'On-prem AD sign-in: Success' })
                Send $ctx @{ ok = $true; user = $u; adLogoutAt = (Get-AdLogoutIso); self = $r.self }
            }
            # /api/logout : ends the tool login completely and deletes the cookie (Max-Age=0).
            '/api/logout' {
                Exit-StGraph 'Microsoft sign-out (tool logout)'
                Clear-Who
                Clear-Ad; $script:Session = $null; $script:SessUser = $null
                Write-LoginLog '(tool login)' 'Logout'
                $ctx.Response.Headers.Add('Set-Cookie', 'sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0')
                Send $ctx @{ ok = $true }
            }
            # /api/ad-disconnect : forget the AD sign-in only.
            '/api/ad-disconnect' {
                Clear-Ad
                Send $ctx @{ ok = $true }
            }
            # /api/tab-closed : the page says its tab is closing. Body action: 'signout' or 'shutdown'. It is only done after 12 seconds if no page
            # calls the server again (a reload does). 'shutdown' is only for people allowed to control the server.
            '/api/tab-closed' {
                $a = "$($d.action)"
                if ($a -eq 'shutdown' -and -not (Test-CanServer)) { $a = 'signout' }   # v1.98.41: only people allowed to restart / shut down the server
                if ($a -in 'signout', 'shutdown') { $script:CloseAct = $a; $script:CloseAt = (Get-Date).AddSeconds(12) }
                Send $ctx @{ ok = $true }
            }
            # /api/restart : answers first, signs everybody out, stops the listener and starts a NEW hidden copy of this script after 4 seconds
            # (-Background -NoBrowser: no window, no new tab). Ending the loop lets the old copy exit.
            '/api/restart' {
                Send $ctx @{ ok = $true }
                try { Write-ActRow 'Tool' 'Restart' '' 'Done' '' } catch {}
                try { Write-LoginLog "$($script:SessUser.name)" 'Server restarted from the page' } catch {}
                Stop-AllSessions 'Microsoft sign-out (tool restarted)'
                $listener.Stop(); Write-Host 'Server restarting...'
                # a new copy starts a few seconds later (same rights - administrator - as this one), with no window and no new browser tab
                $cmd = "Start-Sleep -Seconds 4; & '" + ($PSCommandPath -replace "'", "''") + "' -Background -NoBrowser"
                Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`"" -WindowStyle Hidden -WorkingDirectory $Root
            }
            # /api/shutdown : the Shut down button. Signs everybody out and stops the server.
            '/api/shutdown' {
                Send $ctx @{ ok = $true }
                try { Write-ActRow 'Tool' 'Shut down' '' 'Done' '' } catch {}
                Stop-AllSessions 'Microsoft sign-out (tool shut down)'
                $listener.Stop(); Write-Host 'Server stopped.'
            }
            # Unknown path.
            default { Send $ctx @{ error = 'Not found' } 404 }
        }
    } catch {
        # Any error thrown by a handler becomes a JSON error {error} with HTTP 400 (the page shows the text).
        try { Send $ctx @{ error = $_.Exception.Message } 400 } catch {}
    } finally {
        # activity log: who did what, on which screen, to which user - after the answer was sent, so it never slows the page
        if ($null -ne $script:ActResp) { try { Write-Activity $path $d $script:ActResp $script:ActCode } catch { Write-Host "Activity log: $($_.Exception.Message)" -ForegroundColor Yellow } }
        Save-Sess $csid   # v2.0.0: keep this person's state for their next request
    }
}
# last copy of the logs to SharePoint when the tool stops (the sessions were already signed out above)
try { if ($script:Who) { Sync-SpLogs } } catch {}

# Screen-DistGroups.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Distribution groups
# Screen version: 2.7.0   (changes ONLY when this screen changes - not with every release)

# Microsoft Graph cannot change distribution-list membership, so Exchange Online needs its own connection. It is tied to the
# Microsoft sign-in in the sidebar: when you are signed in there and open this screen, the tool connects Exchange Online by itself
# with the SAME account (or the same app and certificate), in a hidden background process (DistGroups-Worker.ps1), and it signs out
# together with Microsoft. Runs are job files dropped in DistributionGroups\WebUI_Jobs\Pending. No other files are needed.
#
# Fixes compared with the old WebUI-Server.ps1:
#  - files and logs can only be read from a job this server queued (by job id), never from any path on the PC
#  - it is behind the Admin Console login and token (the old server had no login at all)
#  - no machine-wide execution policy change (the worker is started with -ExecutionPolicy Bypass for that process only)
#  - the admin UPN is checked and quoted before it goes on the worker's command line (no command injection)
#  - lists arrive as UTF-8 JSON, so Arabic or accented names are not garbled
#  - the default domain is only added to plain aliases (no @ and no spaces), so a group named "Sales Team" is not broken
#  - the worker status uses the heartbeat file's time stamp, so it works with any Windows date format

# SCREEN: Distribution groups (add / remove members in bulk, export members) - plus the Exchange Online connection used by other screens.
# Endpoints: /api/dg-status (state of the connection, module, jobs), /api/dg-install (install the Exchange Online module), /api/dg-start,
# /api/dg-stop (connect / disconnect), /api/dg-run (queue a job), /api/dg-log (log of a job), /api/dg-file (download a result file).
# How it works: this file only QUEUES jobs (job_<id>.json in the Pending folder). DistGroups-Worker.ps1 runs hidden in the background, is
# connected to Exchange Online, picks up the jobs and writes logs / CSV reports into the job's Logs folder.
# Exchange Online is not reachable through Microsoft Graph, which is why a separate worker is needed.
# Needs: sign-in to Microsoft in the sidebar (the same account is used for Exchange Online).
#
# Folders and files used (all under <tool folder>\DistributionGroups). Set-DgPaths later moves the job folders to one folder per account.
$script:DgRoot    = Join-Path $Root 'DistributionGroups'
$script:DgJobsDir = Join-Path $script:DgRoot 'WebUI_Jobs'
$script:DgPending = Join-Path $script:DgJobsDir 'Pending'
$script:DgUploads = Join-Path $script:DgRoot 'WebUI_Uploads'
$script:DgBeat    = Join-Path $script:DgJobsDir 'heartbeat.txt'
$script:DgStop    = Join-Path $script:DgJobsDir 'stop.signal'
# Runtime state: jobs started by this server, and whether the ExchangeOnlineManagement PowerShell module is installed (cached).
$script:DgJobs    = [ordered]@{}   # jobs queued by this server: id -> info (kept until the server stops)
$script:DgExo     = $null          # cached: is the ExchangeOnlineManagement module installed?
# Create the folders on start-up if they do not exist yet (Done / Failed are where the worker moves finished job files).
foreach ($dgDir in @($script:DgRoot, $script:DgJobsDir, $script:DgPending, (Join-Path $script:DgJobsDir 'Done'), (Join-Path $script:DgJobsDir 'Failed'), $script:DgUploads)) {
    if (-not (Test-Path $dgDir)) { New-Item -ItemType Directory -Force $dgDir | Out-Null }
}

# Path of the background worker script.
$script:DgWorker = Join-Path $Root 'backend\ExchangeOnline\DistGroups-Worker.ps1'
# v2.0.0: every Microsoft account has its OWN Exchange Online connection (worker) and job folder:
# DistributionGroups\Users\<account>\WebUI_Jobs. Called whenever the loaded session changes.
$script:DgBaseJobs = $script:DgJobsDir
# Points all job paths (Pending, heartbeat, stop signal, error file) to the folder of the signed-in Microsoft account, so every admin has his own
# Exchange Online connection and job queue. The account name is turned into a safe folder name (only a-z 0-9 . _ - ; max 80 characters).
# Creates the folders if needed. Called whenever the signed-in session changes.
function Set-DgPaths {
    $root = $script:DgBaseJobs
    if ($script:Who) { $safe = ("$($script:Who)".ToLower() -replace '[^a-z0-9._-]', '_'); if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }; $root = Join-Path (Join-Path (Join-Path $script:DgRoot 'Users') $safe) 'WebUI_Jobs' }
    if ($root -ne $script:DgJobsDir) {
        $script:DgJobsDir = $root; $script:DgPending = Join-Path $root 'Pending'
        $script:DgBeat = Join-Path $root 'heartbeat.txt'; $script:DgStop = Join-Path $root 'stop.signal'; $script:DgErrFile = Join-Path $root 'worker-errors.txt'
        foreach ($dd in @($root, $script:DgPending, (Join-Path $root 'Done'), (Join-Path $root 'Failed'))) { if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force $dd | Out-Null } }
    }
}
# Checks that the worker script exists and reads its version from the line '# version x.y.z' inside it. Returns worker / version / expected (tool version).
function Get-DgFiles {
    $ok = Test-Path $script:DgWorker; $ver = ''
    if ($ok) { $m = [regex]::Match((Get-Content $script:DgWorker -Raw -Encoding UTF8), '# version ([0-9.]+)'); if ($m.Success) { $ver = $m.Groups[1].Value } }
    [ordered]@{ worker = $ok; version = $ver; expected = $AppVersion }
}

# Reads the worker status. The worker rewrites heartbeat.txt every few seconds ('Status|time|version'). If the file has not been touched for too
# long the worker is reported as 'Stale' (probably dead). Returns status, lastSeen, version, age and an error detail when there is one.
# Worker status from the heartbeat file "Status|time". Staleness uses the file's own time stamp (works with any date format).
function Get-DgWorker {
    if (-not (Test-Path $script:DgBeat)) { return @{ status = 'NotStarted'; lastSeen = '' } }
    $fi = Get-Item $script:DgBeat
    $line = "$(Get-Content -Path $script:DgBeat -Raw -ErrorAction SilentlyContinue)".Trim()
    $st = (($line -split '\|')[0]).Trim(); if (-not $st) { $st = 'Unknown' }
    $wv = if (@($line -split '\|').Count -ge 3) { (($line -split '\|')[2]).Trim() } else { '' }   # older workers did not write their version
    $age = ((Get-Date) - $fi.LastWriteTime).TotalSeconds
    $seen = '{0:HH:mm:ss}' -f $fi.LastWriteTime
    # How old the heartbeat may be: 600 s while a job runs, 300 s while signing in, otherwise 30 s.
    $limit = $(if ($st -match 'running a job') { 600 } elseif ($st -match '^(Signing in|Starting)') { 300 } else { 30 })   # a big group read, or the Microsoft sign-in window waiting for you (password / MFA)
    if ($age -gt $limit) { return @{ status = 'Stale'; lastSeen = $seen; last = $st; version = $wv; detail = (Get-DgWorkerErr) } }
    @{ status = $st; lastSeen = $seen; version = $wv; age = [int]$age; detail = $(if ($st -match '^Error') { Get-DgWorkerErr } else { '' }) }
}

# Adds one line to the monthly audit file logs\dg-audit-yyyy-MM.csv: time, Windows user that runs the tool, job id, action, counts and result.
function Write-DgAudit($jobId, $action, $groups, $users, $result) {
    $f = Join-Path $LogDir ('dg-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,WindowsUser,Job,Action,Groups,Users,Result' | Out-File $f -Encoding utf8 }
    $vals = @(('{0:s}' -f (Get-Now)), [Security.Principal.WindowsIdentity]::GetCurrent().Name, $jobId, $action, $groups, $users, $result) | ForEach-Object { ConvertTo-CsvCell $_ }
    ($vals -join ',') | Add-Content $f
}

# Cleans a list sent by the page. $items = raw entries, $domain = default domain (or empty), $what = name used in error messages, $max = most
# entries allowed. Throws on control characters, entries over 256 characters, or too many entries. Returns a string array.
# Clean a list from the page: trim, drop empty and duplicate entries, refuse control characters, add the default domain to plain aliases
function Get-DgList($items, $domain, $what, $max) {
    $seen = @{}; $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($items)) {
        $v = "$x".Trim()
        if (-not $v) { continue }
        if ($v -match '[\x00-\x1f]') { throw "$what contains a line break or another control character: $v" }
        if ($v.Length -gt 256) { throw "$what has an entry longer than 256 characters." }
        if ($domain -and $v -notmatch '@' -and $v -notmatch '\s') { $v = "$v@$domain" }   # alias only - "Sales Team" stays a name
        $k = $v.ToLower(); if ($seen[$k]) { continue }; $seen[$k] = 1
        $out.Add($v)
    }
    if ($out.Count -gt $max) { throw "$what has $($out.Count) entries - up to $max at a time." }
    , $out.ToArray()
}

# Finds a job that THIS server queued (by id). Files can only be read for these jobs, never for an arbitrary path.
function Get-DgJob($id) {
    $j = $script:DgJobs["$id"]
    if (-not $j) { throw 'That run is not known to this server (it may be from before the server was restarted).' }
    $j
}
# Works out the state of a job by looking where the worker put its job file (Running, Done, Failed folders, or still Pending) and at its log.
# Queued / Running / Done / Failed, from where the worker has put the job file
function Get-DgJobState($j) {
    if (Test-Path (Join-Path (Join-Path $script:DgJobsDir 'Running') $j.file)) { return 'Running' }
    foreach ($s in 'Done', 'Failed') {
        if (@(Get-ChildItem -Path (Join-Path $script:DgJobsDir $s) -Filter "$($j.file)*" -File -ErrorAction SilentlyContinue).Count) { return $s }
    }
    if (Test-Path (Join-Path $script:DgPending $j.file)) {
        if (@(Get-ChildItem -Path $j.logFolder -Filter 'FullRunLog_*.log' -File -ErrorAction SilentlyContinue).Count) { return 'Running' }
        return 'Queued'
    }
    # Fallback: the log file decides. Written in the last 60 seconds = Running, older = Finished.
    # Not in Pending, Done or Failed: the worker took it. Running while its log is still being written, Finished after a quiet minute.
    $log = @(Get-ChildItem -Path $j.logFolder -Filter 'FullRunLog_*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($log.Count) { if (((Get-Date) - $log[0].LastWriteTime).TotalSeconds -lt 60) { return 'Running' }; return 'Finished' }
    'Queued'
}
# Lists the .csv / .log files in a job's log folder (newest first, max 100). 'report' marks the files the page shows as result reports.
# Result files of one job: only CSV and log files inside that job's own log folder
function Get-DgJobFiles($j) {
    if (-not (Test-Path $j.logFolder)) { return @() }
    $base = (Resolve-Path $j.logFolder).Path.TrimEnd('\', '/')
    @(Get-ChildItem -Path $j.logFolder -Recurse -File -Include '*.csv', '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 100 | ForEach-Object {
        [pscustomobject]@{ name = $_.FullName.Substring($base.Length).TrimStart('\', '/'); size = $_.Length; time = ('{0:HH:mm:ss}' -f $_.LastWriteTime)
            report = ($_.Name -like 'FinalGroupMembership_*' -or $_.Name -like 'AllGroupsMembers_*' -or $_.Name -like 'Results_*' -or $_.Name -like 'Overflow_*') }
    })
}

# File where the worker writes startup errors (for example PowerShell could not run the script).
# The hidden worker's own error output (for example PowerShell could not start the script) - shown on the screen when it fails
$script:DgErrFile = Join-Path $script:DgJobsDir 'worker-errors.txt'   # written by the worker itself when something goes wrong
# Returns the text to show when the worker has a problem: a syntax error in the worker script, or the last 15 lines of worker-errors.txt.
function Get-DgWorkerErr {
    $pe = Get-DgParseErr; if ($pe) { return "DistGroups-Worker.ps1 cannot run: $pe" }
    if (Test-Path $script:DgErrFile) { return ((@(Get-Content -Path $script:DgErrFile -Tail 15 -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() })) -join "`n") }
    ''
}
# Parses the worker script with the PowerShell parser (no run) and returns the first 3 syntax errors as text, or '' if it is fine.
# Can this Windows PowerShell read the worker script? (checked by the same PowerShell that starts it)
function Get-DgParseErr {
    if (-not (Test-Path $script:DgWorker)) { return '' }
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:DgWorker, [ref]$null, [ref]$e)
    if (@($e).Count) { return ((@($e) | Select-Object -First 3 | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') }
    ''
}
# Disconnects the worker: removes the saved sign-in token, then writes stop.signal (the worker sees it and closes).
# Ask the background Exchange connection to sign out and close (it checks for this file every second)
function Stop-DgWorker {
    $tf = Join-Path $script:DgJobsDir 'token.dat'; if (Test-Path $tf) { Remove-Item $tf -Force -ErrorAction SilentlyContinue }   # v2.0.0: never leave the sign-in behind
    $w = Get-DgWorker
    if ($w.status -notin 'NotStarted', 'Stopped', 'Stale') { try { 'stop' | Set-Content -Path $script:DgStop -Encoding UTF8 } catch {} }
    if ($w.status -match '^(Signing in|Starting)' -or $w.status -eq 'Stale') { Stop-DgStuck }   # waiting in the sign-in: it cannot read stop.signal
}
# A worker this server started that is still running but not connected (for example stuck in the sign-in): close that process.
# It cannot see stop.signal while the Microsoft sign-in is waiting, so it is ended directly - it has not made any change yet.
# Kills a worker process that is still waiting in the Microsoft sign-in (it cannot see stop.signal there). Only kills a powershell process.
function Stop-DgStuck {
    if (-not $script:DgPid) { return }
    try { $p = Get-Process -Id $script:DgPid -ErrorAction Stop; if ($p.ProcessName -match '^powershell') { Stop-Process -Id $script:DgPid -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 } } catch {}
    $script:DgPid = $null
}
# Start the hidden Exchange Online connection for whoever is signed in to Microsoft in the sidebar
# Starts the worker as a hidden powershell.exe for the signed-in account. Throws a clear message if not signed in, the worker file is missing,
# or the sign-in method cannot work. The sign-in method is chosen in this order:
#   1. the admin's own Microsoft app token (works from other PCs) - handed over in an encrypted token file (DPAPI, current Windows user only)
#   2. a certificate (app-only) - the values are checked so nothing unexpected reaches the command line
#   3. the admin's UPN (browser sign-in on this PC) - only if it looks like a valid e-mail address (prevents command injection)
function Start-DgWorker {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections, or the M365 / AD button at the top right). Exchange Online uses the same sign-in.' }
    if (-not (Get-DgFiles).worker) { throw "backend\ExchangeOnline\DistGroups-Worker.ps1 is missing from $Root. Copy every file and folder from the Admin Console zip into the same folder." }
    if (Test-Path $script:DgStop) { Remove-Item $script:DgStop -Force -ErrorAction SilentlyContinue }
    # Command line of the worker. Bypass applies to this one process only; the machine policy is not changed.
    $wargs = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:DgWorker)`" -JobsRoot `"$($script:DgJobsDir)`""
    $app = Get-MsAppCfg
    if ($script:MsRefresh -and $script:MsClient -and $app.exo -and $script:MsClient -eq "$($app.clientId)") {
        # v2.0.0: no window - the worker signs in to Exchange Online with this person's own portal sign-in (works for people on other PCs)
        $tf = Join-Path $script:DgJobsDir 'token.dat'
        $tj = @{ client = $script:MsClient; tenant = $script:MsTenant; refresh = $script:MsRefresh; upn = "$($script:WhoUpn)"; secret = $(if ($script:MsSecret) { Unprotect-MailSecret $script:MsSecret } else { '' }) } | ConvertTo-Json -Compress
        (ConvertTo-SecureString $tj -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -Path $tf -Encoding ASCII
        $wargs += " -TokenFile `"$tf`""
    # The sign-in window opens on the machine running the tool. If the admin is on another PC, stop with an explanation instead.
    } elseif (-not $script:CertInfo -and "$($script:ClientIp)" -notin '127.0.0.1', '::1', '::ffff:127.0.0.1', '') {
        # v2.0.0: the Exchange Online sign-in window would open on the SERVER, not on this person's PC
        throw 'Exchange Online from another PC needs the Microsoft app with Exchange.Manage (Settings > Connections > Microsoft app, tick "Exchange Online with this app"). Then sign out of Microsoft and connect again.'
    } elseif ($script:CertInfo) {
        if (-not $script:CertInfo.Org) { throw "Exchange Online needs the tenant's onmicrosoft.com domain for the certificate sign-in, and it could not be read (the app needs Organization.Read.All)." }
        foreach ($v in $script:CertInfo.AppId, $script:CertInfo.Thumb, $script:CertInfo.Org) { if ("$v" -notmatch '^[A-Za-z0-9.-]+$') { throw 'The certificate sign-in details contain unexpected characters.' } }
        $wargs += " -AppId `"$($script:CertInfo.AppId)`" -CertificateThumbprint `"$($script:CertInfo.Thumb)`" -Organization `"$($script:CertInfo.Org)`""
    } elseif ("$($script:WhoUpn)" -match '^[A-Za-z0-9._%+''-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
        $wargs += " -AdminUPN `"$($script:WhoUpn)`""
    }
    'Starting|' + ('{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)) | Set-Content -Path $script:DgBeat -Encoding UTF8
    $pe = Get-DgParseErr; if ($pe) { throw "DistGroups-Worker.ps1 cannot run in Windows PowerShell: $pe - copy every file from the same zip again." }
    Remove-Item $script:DgErrFile -Force -ErrorAction SilentlyContinue
    Stop-DgStuck   # never two workers at once
    # Start the worker; remember its process id (to stop it if stuck) and for which sign-in it was started (so it is started only once).
    $pr = Start-Process -FilePath 'powershell.exe' -ArgumentList $wargs -WorkingDirectory $script:DgRoot -WindowStyle Hidden -PassThru   # never a visible PowerShell window - the sign-in opens in the web browser
    $script:DgPid = $pr.Id
    $script:DgAutoFor = $script:Who
}

# ENDPOINT /api/dg-status - polled by the page. Input: $d.auto (start the connection by itself), $d.recheck (look for the module again).
# Returns the module state, worker status, the last 20 jobs and the number of waiting job files. May start / restart the worker.
$ScreenHandlers['/api/dg-status'] = {
        if ($null -eq $script:DgExo -or $d.recheck) { $script:DgExo = [bool](Get-Module -ListAvailable -Name ExchangeOnlineManagement) }
        $note = ''
        # Automatic connection management: (1) the signed-in person changed -> sign the old connection out, (2) the worker is from an older tool version ->
        # restart it, (3) not running and not yet started for this sign-in -> start it. Only once per sign-in, so a failure does not open sign-in windows again and again.
        if ($d.auto -and $script:Who -and $script:DgExo) {
            $w = Get-DgWorker
            # Connected as somebody else than the Microsoft sign-in (the person changed): sign that connection out first
            if ($w.status -match '^Connected as (.+?)( - |$)' -and -not $script:CertInfo -and $script:WhoUpn -and $Matches[1] -ine $script:WhoUpn) { Stop-DgWorker; $script:DgAutoFor = $null; $note = 'Switching Exchange Online to ' + $script:WhoUpn + '...' }
            # still the worker of an older version of the tool (it kept running in the background after the update): restart it
            elseif ($w.status -match '^Connected' -and $w.version -ne $AppVersion -and $w.status -notmatch 'running a job') { Stop-DgWorker; $script:DgAutoFor = $null; $note = "Restarting Exchange Online with the new version of the tool (the running connection is from $(if ($w.version) { "v$($w.version)" } else { 'an older version' }))..." }
            # Start once per Microsoft sign-in (after an error it waits for Try again, so it never keeps opening sign-in windows)
            elseif ($w.status -in 'NotStarted', 'Stopped', 'Stale' -and $script:DgAutoFor -ne $script:Who) { try { Start-DgWorker } catch { $note = $_.Exception.Message } }
        }
        # Last 20 jobs, newest first, with their current state.
        $jobs = @($script:DgJobs.Values | Select-Object -Last 20 | ForEach-Object {
            [pscustomobject]@{ id = $_.id; time = $_.time; action = $_.action; summary = $_.summary; state = (Get-DgJobState $_) } })
        [array]::Reverse($jobs)
        # Module install progress. When the install has just finished, look for the module again.
        $inst = Get-DgInstall
        if ($inst -and $inst.state -eq 'running') { $script:DgInstApplied = $false }
        elseif ($inst -and $inst.state -eq 'done' -and -not $script:DgInstApplied) {   # the background install just finished: look for the module again
            $script:DgInstApplied = $true; $script:DgExo = [bool](Get-Module -ListAvailable -Name ExchangeOnlineManagement); $script:DgExoVer = $null
        }
        if ($null -eq $script:DgExoVer -or $d.recheck) { $script:DgExoVer = "$(@(Get-Module -ListAvailable -Name ExchangeOnlineManagement | Sort-Object Version -Descending | Select-Object -First 1).Version)" }
        Send $ctx @{ ok = $true; install = $inst; exoVersion = $script:DgExoVer; files = (Get-DgFiles); folder = $script:DgRoot; exo = $script:DgExo; worker = (Get-DgWorker); jobs = $jobs; ms = $script:Who; msUpn = $script:WhoUpn; cert = [bool]$script:CertInfo; note = $note
            pending = @(Get-ChildItem -Path $script:DgPending -Filter 'job_*.json' -File -ErrorAction SilentlyContinue).Count }
}

# Module installation: log file and process id of the background installer.
$script:DgInstLog = Join-Path $script:DgJobsDir 'module-install.log'
$script:DgInstPid = $null
# Reads the install log. State: running (process alive), done (last line has DONE), failed (FAILED) or unknown. Returns state + last 4 lines.
# Is the background install still running? done / failed / running, with the last lines of its log
function Get-DgInstall {
    if (-not (Test-Path $script:DgInstLog)) { return $null }
    $lines = @(Get-Content -Path $script:DgInstLog -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() })
    $running = $false
    if ($script:DgInstPid) { try { $running = [bool](Get-Process -Id $script:DgInstPid -ErrorAction Stop) } catch { $running = $false } }
    $last = if ($lines.Count) { "$($lines[-1])" } else { '' }
    $state = if ($running) { 'running' } elseif ($last -match 'DONE') { 'done' } elseif ($last -match 'FAILED') { 'failed' } else { 'unknown' }
    if (-not $running) { $script:DgInstPid = $null }
    @{ state = $state; text = (($lines | Select-Object -Last 4) -join "`n") }
}
# ENDPOINT /api/dg-install - no input. Writes a small script (module-install.ps1) and runs it hidden. It installs ExchangeOnlineManagement for the
# current Windows user from the PowerShell Gallery (needs internet; TLS 1.2 is switched on for old PowerShell; NuGet provider first if missing).
$ScreenHandlers['/api/dg-install'] = {
        # Installs (or updates) the Exchange Online module in the background - no window. Progress comes with dg-status (install).
        $cur = Get-DgInstall
        if ($cur -and $cur.state -eq 'running') { throw 'The Exchange Online module is already being installed - wait a moment.' }
        $ps1 = Join-Path $script:DgJobsDir 'module-install.ps1'
        # Double single quotes so the path is safe inside the single-quoted string of the generated script.
        $logq = $script:DgInstLog -replace "'", "''"
        @(
            '$ErrorActionPreference = ''Stop'''
            "`$log = '$logq'"
            'function L($m) { (''{0:HH:mm:ss}  {1}'' -f (Get-Date), $m) | Add-Content -Path $log -Encoding UTF8 }'
            'try {'
            '    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12'
            '    L ''Installing the ExchangeOnlineManagement module for this Windows user...'''
            '    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) { L ''Installing the NuGet package provider...''; Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }'
            '    Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop'
            '    $v = @(Get-Module -ListAvailable ExchangeOnlineManagement | Sort-Object Version -Descending)[0].Version'
            '    L "DONE - version $v is installed."'
            '} catch { L ("FAILED: " + $_.Exception.Message) }'
        ) | Set-Content -Path $ps1 -Encoding UTF8
        ('{0:HH:mm:ss}  Starting the install...' -f (Get-Date)) | Set-Content -Path $script:DgInstLog -Encoding UTF8
        $pr = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"" -WindowStyle Hidden -PassThru
        $script:DgInstPid = $pr.Id; $script:DgExo = $null
        Send $ctx @{ ok = $true }
}

# ENDPOINT /api/dg-start - the 'Try again / Sign in again' button. Starts the Exchange Online connection for the signed-in Microsoft account.
$ScreenHandlers['/api/dg-start'] = {
        # Try again: connect Exchange Online with the account that is signed in to Microsoft (never a different one)
        $w = Get-DgWorker
        if ($w.status -match '^Connected') { throw "Exchange Online is already $($w.status.ToLower())." }
        if ($w.status -match '^(Signing in|Starting)') { Stop-DgWorker }   # Sign in again: a sign-in that is stuck is closed first (Start-DgWorker ends that process)
        Start-DgWorker
        Send $ctx @{ ok = $true }
}

# ENDPOINT /api/dg-stop - asks the worker to disconnect and close.
$ScreenHandlers['/api/dg-stop'] = {
        # The worker checks for this file every second, disconnects from Exchange Online and closes its own window
        'stop' | Set-Content -Path $script:DgStop -Encoding UTF8
        Send $ctx @{ ok = $true }
}

# ENDPOINT /api/dg-run - queues a job. Input: $d.action (Add / Remove / Both / Export), $d.domain (default domain for plain aliases),
# $d.maxPerGroup (empty = no limit), $d.spread (All / Fill), $d.addGroups, $d.addUsers, $d.removeGroups, $d.removeUsers, $d.exportGroups,
# $d.exportMode (Combined / PerGroup), $d.logFolder (optional output folder). Writes CSV files with the users and the job file.
# Returns { ok, id, summary, logFolder }. Progress: /api/dg-log.
$ScreenHandlers['/api/dg-run'] = {
        $w = Get-DgWorker
        if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections, or the M365 / AD button at the top right).' }
        if ($w.status -notmatch '^Connected') { throw "Exchange Online is not connected yet (status: $($w.status)). Wait until it says Connected." }
        $action = "$($d.action)"
        if ($action -notin 'Add', 'Remove', 'Both', 'Export') { throw 'Choose Add, Remove, Both or Export.' }
        # The default domain must look like contoso.com (letters, digits, dots and hyphens; a dot and a 2+ letter ending).
        $dgDom = "$($d.domain)".Trim().TrimStart('@')
        if ($dgDom -and $dgDom -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$') { throw 'The default domain must look like contoso.com.' }
        $max = 0
        if ("$($d.maxPerGroup)".Trim()) {
            if (-not [int]::TryParse("$($d.maxPerGroup)".Trim(), [ref]$max) -or $max -lt 1 -or $max -gt 100000) { throw 'Maximum members per group must be a whole number from 1 to 100000, or empty for no limit.' }
        }
        # Job id = time stamp to the millisecond. Each job has its own folder for its input CSVs and logs.
        $id = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $runFolder = Join-Path $script:DgUploads $id
        $logFolder = Join-Path $runFolder 'Logs'
        $custom = "$($d.logFolder)".Trim()
        # The admin may choose another output folder; it must be a full path and not a protected place (Test-SafeOutFolder). A sub folder with the job id is used.
        if ($custom) {
            if (-not [IO.Path]::IsPathRooted($custom) -or $custom.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { throw 'The output folder must be a full path, for example C:\Temp\DG-Logs.' }
            if (-not (Test-SafeOutFolder $custom)) { throw 'That folder is not allowed (system folders, Program Files, the tool folder and drive roots are blocked). Use for example C:\Temp\DG-Logs or a share.' }   # v2.4.0
            $logFolder = Join-Path $custom $id   # its own subfolder, so the log and report of this run are found exactly
        }
        New-Item -ItemType Directory -Force $runFolder, $logFolder | Out-Null
        # Spread: 'All' = add every user to every group, 'Fill' = fill the groups one after the other up to the maximum (needs the maximum).
        $spread = $(if ("$($d.spread)" -eq 'Fill') { 'Fill' } else { 'All' })
        if ($action -in 'Add', 'Both' -and $spread -eq 'Fill' -and -not $max) { throw 'Fill the groups in order needs a maximum number of members per group.' }
        $job = [ordered]@{ Action = $action; MaxMembersPerGroup = $max; SpreadMode = $spread }
        $parts = @(); $nG = 0; $nU = 0
        # ADD part: validate the groups (max 500) and users (max 50000), save the users in AddUsers.csv, and describe the work in $parts.
        if ($action -in 'Add', 'Both') {
            $g = Get-DgList $d.addGroups $dgDom 'Add groups' 500; if (-not $g.Count) { throw 'Type or load at least one group to add to.' }
            $u = Get-DgList $d.addUsers $dgDom 'Users to add' 50000; if (-not $u.Count) { throw 'Type or load at least one user to add.' }
            $p = Join-Path $runFolder 'AddUsers.csv'; Set-Content -Path $p -Value (@('Email') + $u) -Encoding UTF8
            $job.AddGroupIdentities = $g; $job.AddUsersCsvPath = $p
            $parts += $(if ($spread -eq 'Fill') { "add $($u.Count) spread over $($g.Count) group(s), max $max each" } else { "add $($u.Count) to $($g.Count) group(s)" + $(if ($max) { ", max $max each" } else { '' }) }); $nG += $g.Count; $nU += $u.Count
        }
        # REMOVE part: same as above with RemoveUsers.csv.
        if ($action -in 'Remove', 'Both') {
            $g = Get-DgList $d.removeGroups $dgDom 'Remove groups' 500; if (-not $g.Count) { throw 'Type or load at least one group to remove from.' }
            $u = Get-DgList $d.removeUsers $dgDom 'Users to remove' 50000; if (-not $u.Count) { throw 'Type or load at least one user to remove.' }
            $p = Join-Path $runFolder 'RemoveUsers.csv'; Set-Content -Path $p -Value (@('Email') + $u) -Encoding UTF8
            $job.RemoveGroupIdentities = $g; $job.RemoveUsersCsvPath = $p
            $parts += "remove $($u.Count) from $($g.Count) group(s)"; $nG += $g.Count; $nU += $u.Count
        }
        # EXPORT part: only the groups are needed; ExportMode decides one combined file or one file per group.
        if ($action -eq 'Export') {
            $g = Get-DgList $d.exportGroups $dgDom 'Groups to export' 500; if (-not $g.Count) { throw 'Type or load at least one group to export.' }
            $job.ExportGroupIdentities = $g
            $job.ExportMode = $(if ("$($d.exportMode)" -eq 'PerGroup') { 'PerGroup' } else { 'Combined' })
            $parts += "export $($g.Count) group(s) ($($job.ExportMode))"; $nG += $g.Count
        }
        $job.LogFolder = $logFolder
        $file = "job_$id.json"
        # Dropping this file in Pending is what starts the work: the worker watches that folder.
        ($job | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $script:DgPending $file) -Encoding UTF8
        $summary = ($parts -join ' and ')
        $script:DgJobs[$id] = @{ id = $id; file = $file; logFolder = $logFolder; action = $action; summary = $summary; time = ('{0:HH:mm:ss}' -f (Get-Date)) }
        Write-DgAudit $id $action $nG $nU "Queued: $summary"
        Send $ctx @{ ok = $true; id = $id; summary = $summary; logFolder = $logFolder }
}

# ENDPOINT /api/dg-log - Input: $d.id (job id). Returns the job state, the last 400 lines of its newest FullRunLog and the list of result files.
$ScreenHandlers['/api/dg-log'] = {
        $j = Get-DgJob $d.id
        $log = @(Get-ChildItem -Path $j.logFolder -Filter 'FullRunLog_*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $text = ''
        if ($log.Count) { $text = (@(Get-Content -Path $log[0].FullName -Tail 400 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n") }
        Send $ctx @{ ok = $true; state = (Get-DgJobState $j); log = $text; files = @(Get-DgJobFiles $j); logFolder = $j.logFolder; summary = $j.summary }
}

# ENDPOINT /api/dg-file - download one result file. Input: $d.id (job id), $d.name (file name relative to the job's log folder). Returns { name, text }.
$ScreenHandlers['/api/dg-file'] = {
        # Only a file listed for that job (inside its own log folder) can be downloaded
        $j = Get-DgJob $d.id
        $name = "$($d.name)"
        $hit = @(Get-DgJobFiles $j | Where-Object { $_.name -eq $name })
        if (-not $hit.Count) { throw 'That file is not part of this run.' }
        $full = Join-Path $j.logFolder $name
        # Second safety check: the real full path must still be inside the job's log folder (blocks .. tricks). Files over 50 MB are refused.
        $base = (Resolve-Path $j.logFolder).Path; $real = (Resolve-Path $full).Path
        if (-not $real.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'That file is not part of this run.' }
        if ((Get-Item $real).Length -gt 50MB) { throw "That file is larger than 50 MB - open it from the folder instead: $real" }
        Send $ctx @{ ok = $true; name = (Split-Path $real -Leaf); text = [IO.File]::ReadAllText($real) }
}

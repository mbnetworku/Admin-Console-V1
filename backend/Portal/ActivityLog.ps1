# ActivityLog.ps1 - one activity log for every screen, saved locally AND copied to SharePoint. Loaded by server.ps1; do not run it on its own.
# Screen: Activity log (shared by all screens)
# Screen version: 2.8.1   (changes ONLY when this screen changes - not with every release)
#
# Local:      logs\activity\<yyyy-MM>\activity-<yyyy-MM-dd>.csv   (one row per user / target, per action)
#             plus the per-screen logs that already existed (reset-audit, mfa-audit, onprem-audit, teams-audit, dg-audit, mail-audit, login-audit)
# SharePoint: <library>\<folder>\<yyyy-MM>\<COMPUTER>\<the same file names>      e.g. Documents\Admin Console\2026-10\HELPDESK-PC1\activity-2026-10-01.csv
#             Every log file that changed is uploaded again (whole file, replaced), a few seconds after the last action, while the tool is idle.
# Passwords, passes and tokens are NEVER written: request fields whose name looks like a secret are dropped before logging.

# WHAT THIS FILE DOES: the one activity log used by every screen. Each action is written as a row in a daily CSV on this computer, and the CSV files
# are copied (uploaded again when changed) to a SharePoint document library through Microsoft Graph. It also serves the Logs screens.
# FUNCTIONS used by other files: Write-ActRow (write one row), Write-Activity (called by server.ps1 after every request), Invoke-SpIdle (called once a second).
# ENDPOINTS: /api/logs-status, -settings, -config, -config-save, -autocopy, -sync, -recent, -logins, -search, -open, /api/export-save, /api/log-event.
# DATA: logs\activity\<month>\activity-<date>.csv, login-audit-<month>.csv, sharepoint-settings.json (Root), sharepoint-sync.json (LogDir), log-settings.json.
# GRAPH: Invoke-MgGraphRequest to sites / drives / items (upload needs Sites.ReadWrite.All; the signed-in Microsoft account must be allowed to edit the site).
# PERMISSION: Test-CanLogs ('See all logs') decides whether a person sees everybody's rows or only their own; the sign-in log needs that permission.
#
# Folder of the daily activity CSV files (created if missing).
$script:ActDir = Join-Path $LogDir 'activity'; New-Item -ItemType Directory -Force $script:ActDir | Out-Null
# Settings of the SharePoint copy (on/off, site address, library, folder).
$script:SpCfgFile = Join-Path $Root 'sharepoint-settings.json'
# Remembers which file version (size + time) was already uploaded, so only changed files are sent again.
$script:SpStateFile = Join-Path $LogDir 'sharepoint-sync.json'
# Sync timers: SpDirty = something changed and needs uploading; SpLastAct = time of the last logged action; SpNextTry = do not try before this time
# (after an error); SpLastScan = last full scan of the log folder.
$script:SpDirty = $true; $script:SpLastAct = Get-Date; $script:SpNextTry = Get-Date; $script:SpLastScan = [datetime]::MinValue
# Status shown on the Logs screen (state, message, time of the last copy, number of waiting files, link to the folder).
$script:SpStatus = @{ state = 'Waiting'; message = 'Not synced yet.'; at = $null; pending = 0; folderUrl = $null; site = $null }
# Remembers the SharePoint site and library (drive) IDs so they are not looked up for every upload. The key changes when settings or the account change.
$script:SpCache = @{ key = $null; driveId = $null; siteId = $null; webUrl = $null }
# Name of this computer and the Windows account the tool runs as - both are written in every log row.
$script:Computer = "$env:COMPUTERNAME"; if (-not $script:Computer) { $script:Computer = [Environment]::MachineName }
$script:WinUser = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { "$env:USERDOMAIN\$env:USERNAME" }

# ---------------- which API call is which screen / action ----------------
# Calls that only poll or fill a drop-down are not logged (they would flood the log).
# API calls that are never logged (look-ups, drop-down fills, polling) - they would only fill the log with noise.
$script:ActSkip = @('/api/sso-ms-offer', '/api/sso-ms-choice', '/api/sso-ms-mine', '/api/lic-read', '/api/lic-groups', '/api/lic-change', '/api/adc-meta', '/api/adc-check', '/api/adc-validate', '/api/adc-create', '/api/mfa-list-many', '/api/sec-tfa-reset', '/api/sec-get', '/api/sec-save', '/api/sec-unblock', '/api/sec-lockfolder', '/api/update-info', '/api/update-upload', '/api/update-discard', '/api/update-install', '/api/update-revert', '/api/update-delete', '/api/appsetup-info', '/api/appsetup-start', '/api/appsetup-poll', '/api/intune-action', '/api/mp-status', '/api/mp-lookup', '/api/mp-run', '/api/gjob', '/api/gjob-cancel', '/api/spo-status', '/api/spo-code-poll', '/api/spo-code-start', '/api/od-delete', '/api/od-restore', '/api/od-usage', '/api/od-lookup', '/api/intune-run', '/api/ms-device-poll', '/api/sess-now', '/api/msapp-get', '/api/status', '/api/known-accounts', '/api/ms-login-start', '/api/tab-closed', '/api/logs-config', '/api/audit-ad-events', '/api/audit-cloud', '/api/audit-ad', '/api/audit-job', '/api/audit-cancel', '/api/email-tpl-list', '/api/email-tpl-preview', '/api/dg-status', '/api/dg-log', '/api/dg-file', '/api/mfa-log', '/api/teams-log', '/api/onprem-suffixes',
    '/api/reset-mail-info', '/api/groupsearch', '/api/usersearch', '/api/bulk-groupsearch', '/api/bulk-groupcheck', '/api/logs-status', '/api/logs-recent', '/api/logs-open', '/api/signout', '/api/shutdown', '/api/mbx-result', '/api/mbx-people', '/api/users-list')
# Only the API paths listed here are logged. Each maps to @(screen name, action text) shown in the log. A path that is not here is never written.
$script:ActMap = @{
    '/api/reset'            = @('Reset cloud passwords', 'Reset password')
    '/api/reset-mail'       = @('Reset cloud passwords', 'Email new password')
    '/api/mail-settings'    = @('Reset cloud passwords', 'Email settings')
    '/api/enable'           = @('Check account status', 'Enable account')
    '/api/disable'          = @('Check account status', 'Disable account')
    '/api/mfa-revoke'       = @('Revoke MFA', 'Revoke / require re-register MFA')
    '/api/mfa-mail'         = @('Revoke MFA', 'Email Authenticator set-up')
    '/api/onprem'           = @('On-premises AD', 'Change account')
    '/api/onprem-account'   = @('On-premises AD', 'Account action')
    '/api/bulk-apply'       = @('Bulk & report', 'Bulk change')
    '/api/teams-add'        = @('Teams members', 'Add to team')
    '/api/guest-invite'     = @('Guest users', 'Invite guest')
    '/api/guestrep-run'     = @('Guest users report', 'Run report')
    '/api/mbx-notify'       = @('Shared mailbox', 'E-mail people about the mailbox')
    '/api/app-defaults'     = @('Settings', 'Change defaults')
    '/api/ad-server'        = @('Settings', 'Change AD server')
    '/api/users-save'       = @('Settings', 'Save tool user')
    '/api/users-delete'     = @('Settings', 'Remove tool user')
    '/api/me-password'      = @('Settings', 'Change own tool password')
    '/api/email-tpl-save'   = @('Email messages', 'Change e-mail wording')
    '/api/email-img-save'   = @('Email messages', 'Set e-mail picture')
    '/api/email-img-remove' = @('Email messages', 'Remove e-mail picture')
    '/api/email-tpl-reset'  = @('Email messages', 'Reset e-mail wording to default')
    '/api/dg-run'           = @('Distribution groups', 'Run job')
    '/api/dg-install'       = @('Distribution groups', 'Install module')
    '/api/dg-start'         = @('Distribution groups', 'Connect Exchange Online')
    '/api/dg-stop'          = @('Distribution groups', 'Disconnect Exchange Online')
    '/login'                = @('Tool login', 'Log in to the tool')
    '/api/logout'           = @('Tool login', 'Log out of the tool')
    '/api/connect'          = @('Sign-in', 'Microsoft sign-in')
    '/api/signout-all'      = @('Sign-in', 'Sign out of both')
    '/api/ad-connect'       = @('Sign-in', 'On-premises AD sign-in')
    '/api/ad-disconnect'    = @('Sign-in', 'On-premises AD sign-out')
    '/api/autologout'       = @('Settings', 'Microsoft auto sign-out')
    '/api/ad-autologout'    = @('Settings', 'AD auto sign-out')
    '/api/session-timeout'  = @('Settings', 'Portal timeout')
    '/api/logs-settings'    = @('Settings', 'Log settings')
    '/api/logs-autocopy'    = @('Settings', 'Copy logs to the cloud on/off')
    '/api/logs-config-save' = @('Settings', 'Log settings (time zone / folder)')
    '/api/export-save'      = @('Export', 'Export / download')
    '/api/mbx-change'       = @('Shared mailbox', 'Queue changes')
    '/api/spo-forget'       = @('OneDrive & storage', 'Forget SharePoint admin sign-in')
    '/api/mail-test'        = @('Settings', 'Send a test e-mail')
    '/api/adlogin-save'     = @('Settings', 'Change AD sign-in for the portal')
    '/api/sso-metadata'     = @('Settings', 'Upload single sign-on metadata')
    '/api/sso-logo'         = @('Settings', 'Change single sign-on logo')
    '/api/gal-cloud'        = @('Address list', 'Hide / show in address list (Exchange Online)')
    '/api/people-save'      = @('People database', 'Save person')
    '/api/people-delete'    = @('People database', 'Remove person')
    '/api/people-enable'    = @('People database', 'Enable / disable person')
    '/api/people-import'    = @('People database', 'Import people')
    '/api/people-adimport'  = @('People database', 'Import from AD')
    '/api/people-adlink'    = @('People database', 'Link to AD account')
    '/api/people-adsync'    = @('People database', 'Sync with AD')
    '/api/people-settings'  = @('People database', 'Change settings')
    '/api/me-prefs'         = @('Settings', 'Change my appearance / layout')
    '/api/update-discard'   = @('Settings', 'Remove uploaded update')
    '/api/mailacct-signout' = @('Settings', 'Sign out the mail account')
    '/api/log-event'        = @('Other', 'Event')
}

# ---------------- writing ----------------
# Returns the CSV path for a given day (logs\activity\yyyy-MM\activity-yyyy-MM-dd.csv) and creates the month folder if needed.
function Get-ActFile([datetime]$t) {
    $dir = Join-Path $script:ActDir ('{0:yyyy-MM}' -f $t); New-Item -ItemType Directory -Force $dir | Out-Null
    Join-Path $dir ('activity-{0:yyyy-MM-dd}.csv' -f $t)
}
# Writes ONE row to today's log. Inputs: $screen, $action, $target (who/what), $result (Done / Failed...), $detail. Other columns (time, computer,
# Windows user, Microsoft account, AD account, tool user, client IP/PC) are filled in here. Safe to call from any screen.
function Write-ActRow($screen, $action, $target, $result, $detail) {
    $t = Get-Now; $f = Get-ActFile $t
    # Column names of a new file.
    $hdr = 'Time,Computer,WindowsUser,MicrosoftAccount,AdAccount,Screen,Action,Target,Result,Details,TimeZone,ToolUser,ClientIP,ClientPC'
    if (-not (Test-Path $f)) { $hdr | Out-File $f -Encoding utf8 }
    else {   # a file started by an older version has no TimeZone column: add it to the header (older rows simply have it empty)
        try { $l = @(Get-Content $f -TotalCount 1 -Encoding UTF8); if ($l.Count -and $l[0] -notmatch 'ClientIP') { $add = $(if ($l[0] -notmatch 'TimeZone') { ',TimeZone,ToolUser,ClientIP,ClientPC' } elseif ($l[0] -notmatch 'ToolUser') { ',ToolUser,ClientIP,ClientPC' } else { ',ClientIP,ClientPC' }); $all = @(Get-Content $f -Encoding UTF8); $all[0] = $all[0].TrimEnd() + $add; $all | Set-Content $f -Encoding UTF8 } } catch {}
    }
    # The on-premises AD account, if signed in. Then the row is built; values are joined by commas (the text fields are quoted by the helper that builds $vals).
    $ad = if ($script:AdCred) { "$($script:AdCred.User)" } else { '' }
    $vals = @(('{0:yyyy-MM-dd HH:mm:ss}' -f $t), $script:Computer, $script:WinUser, "$($script:Who)", $ad, $screen, $action, $target, $result, $detail, (Get-TzText), $(if ($script:SessUser) { "$($script:SessUser.name)" } else { '' }), $script:ClientIp, $script:ClientPc) | ForEach-Object { ConvertTo-CsvCell $_ }
    # Retry up to 5 times, 150 ms apart: the SharePoint sync may be reading the file at the same moment and Windows then refuses the write.
    for ($i = 0; $i -lt 5; $i++) { try { ($vals -join ',') | Add-Content $f -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 150 } }   # the sync may be reading the file
    $script:SpDirty = $true; $script:SpLastAct = Get-Date
}
# Request fields worth keeping in Details. Anything that looks like a secret is dropped; long lists are shortened.
# Regex of request field names that look like a secret (password, token, certificate, key...). Such fields are never written to the log.
$script:ActSecret = 'pass|pw$|^pw[A-Z]?$|secret|token|thumb|cred|^password|customPassword|^tap$|cert|key$'
# Turns the request fields ($d) into a short text 'name=value, name=value' for the Details column. Secret-looking fields (except harmless pw options),
# empty values, the names in $skip and nested objects are left out. Lists show the first 8 items; the whole text is cut at 600 characters.
function Get-ActDetail($d, $skip) {
    if (-not $d) { return '' }
    $parts = @()
    foreach ($p in $d.PSObject.Properties) {
        $n = $p.Name; $v = $p.Value
        if ($n -match $script:ActSecret -and $n -notmatch '^(pwOnce|pwLength|pwMode|pwNever|clearPwNever)$') { continue }
        if ($n -in $skip) { continue }
        if ($null -eq $v -or "$v" -eq '') { continue }
        if ($v -is [array] -or $v -is [Collections.IList]) {
            $arr = @($v); if (-not $arr.Count) { continue }
            if ($arr[0] -is [string] -or $arr[0] -is [ValueType]) { $s = (@($arr | Select-Object -First 8) -join '; ') + $(if ($arr.Count -gt 8) { " (+$($arr.Count - 8) more)" } else { '' }) }
            else { $s = "$($arr.Count) item(s)" }
        } elseif ($v -is [psobject] -and $v -isnot [string] -and $v -isnot [ValueType]) { continue }
        else { $s = "$v" }
        $parts += "$n=$s"
    }
    $o = $parts -join ', '; if ($o.Length -gt 600) { $o = $o.Substring(0, 600) + '...' }; $o
}
# Picks the person/object a result row is about: the first non-empty of upn, sam, user, email, name, input.
function Get-ActTarget($x) {
    foreach ($k in 'upn', 'sam', 'user', 'email', 'name', 'input') {
        $v = $x.$k; if ($v -and "$v" -ne '-') { return "$v" }
    }
    ''
}
# Builds the Result text for one result row of a response: Done / Done - message / Failed: message, or a list of the useful fields, including who an e-mail was sent to.
function Get-ActRowResult($x) {
    $to = if ($x.to) { " (to: $($x.to)$(if ($x.cc) { "; cc: $($x.cc)" }))" } else { '' }
    if ($null -ne $x.ok) { if ($x.ok) { return $(if ($x.message -and $x.message -ne 'OK') { "Done - $($x.message)$to" } else { "Done$to" }) } else { return "Failed: $($x.message)$to" } }
    if ($x.status) { return ("$($x.status)" + $(if ($x.message) { " - $($x.message)" } else { '' })) }
    if ($x.found -eq 'No') { return ('Not found' + $(if ($x.message) { " - $($x.message)" } elseif ($x.note) { " - $($x.note)" } else { '' })) }
    $bits = @()
    foreach ($k in 'action', 'enabled', 'locked', 'expiry', 'member', 'pwReset', 'cloud', 'group', 'exists') { $v = $x.$k; if ($v -and "$v" -ne '-') { $bits += "${k}: $v" } }
    if ($x.message) { $bits += "$($x.message)" } elseif ($x.note) { $bits += "$($x.note)" }
    if ($bits.Count) { $bits -join '; ' } else { 'Done' }
}
# Called by server.ps1 after every request. $resp = what the tool answered, $code = HTTP status.
# Called by server.ps1 after every request. $path = API path, $d = request body, $resp = answer, $code = HTTP status. Decides if and how the call is logged:
# only paths in ActMap, one row per result row (user) when the answer has a list, otherwise one row for the whole call. Failures are logged as 'Failed'.
function Write-Activity($path, $d, $resp, $code) {
    if ($path -notlike '/api/*' -and $path -ne '/login') { return }
    if ($path -in $script:ActSkip) { return }
    # These two paths are used both to read and to save; only a save is logged.
    if (($path -in @('/api/mail-settings', '/api/app-defaults', '/api/ad-server')) -and -not $d.save) { return }   # just reading the settings
    # v2.5.5: ONLY actions are logged (changes, deletes, creations, settings, sign-ins). Opening a screen, looking something up,
    # reading a report or a list is never written - and no raw API names appear in the log.
    $m = $script:ActMap[$path]; if (-not $m) { return }
    if ($path -eq '/api/me-prefs' -and -not ($d.save -or $d.reset)) { return }
    $screen = $m[0]; $action = $m[1]
    # Reset password: the action text says whether it was a Temporary Access Pass or a password, and whether it is one-time.
    if ($path -eq '/api/reset') {
        $action = if ($d.method -eq 'tap') { 'Temporary Access Pass' + $(if ($d.tapOnce -ne $false) { ' (one-time use)' } else { ' (multi-use)' }) }
                  else { 'Reset password' + $(if ($d.pwOnce -ne $false) { ' (one-time - must change at next sign-in)' } else { ' (normal password)' }) }
    }
    # Saving an export: log it under the screen the file belongs to (from its name).
    if ($path -eq '/api/export-save') {
        $sc = Get-ExpScreen "$($d.name)"
        $what = if ("$($d.name)" -match '^dg-') { 'Download run file' } else { 'Export / download' }
        Write-ActRow $sc $what "$($resp.file)" $(if ($resp.error) { "Failed: $($resp.error)" } else { "Saved - $($resp.rows) row(s)" }) $(if ($d.view) { "screen=$($d.view)" } else { '' }); return
    }
    # Browser-side events (show/copy a password) are logged only when the event was accepted.
    if ($path -eq '/api/log-event') { if ($resp.ok) { Write-ActRow "$($d.screen)" "$($d.action)" "$($d.target)" 'Done' '' }; return }
    if ($d.action -and $path -in '/api/onprem-account', '/api/bulk-apply', '/api/dg-run') { $action = "$action ($($d.action))" }
    # Details = the request fields, without the ones already shown in the Target column (names, lists of users, large texts).
    $detail = Get-ActDetail $d @('usernames', 'upn', 'upns', 'sams', 'rows', 'emails', 'queries', 'items', 'username', 'save', 'auto', 'text', 'name', 'view', 'message', 'guests', 'recipients', 'blocks', 'variant', 'data', 'layout')
    if ($path -eq '/login') { $detail = ''; if ($code -eq 200) { $action = 'Log in to the tool' } }
    # Did the call fail? Either the answer has an error text or the HTTP status is 400 or higher.
    $err = if ($resp -and $resp.error) { "Failed: $($resp.error)" } elseif ($code -ge 400) { "Failed ($code)" } else { $null }
    # Failed call: one row with the targets taken from the request (the answer has none).
    if ($err) {
        $tg = @(@($d.usernames) + @($d.upn) + @($d.sams) + @($d.emails) + @($d.queries) + @($d.upns) | Where-Object { $_ }) -join '; '
        if ($path -eq '/login') { $tg = '' }
        Write-ActRow $screen $action $tg $err $detail; return
    }
    # Find the list of per-person results in the answer (results, members or users). One log row is written for each of them.
    $rows = $null
    if ($resp) { foreach ($k in 'results', 'members', 'users') { if ($null -ne $resp.$k -and @($resp.$k).Count) { $rows = @($resp.$k); break } } }
    if ($path -in '/api/teams-members', '/api/teams-find') { $rows = $null }   # a member list is a look-up, not one action per member
    # Per-person rows - but not for pure look-ups (search, reports), which fall through to the single-row case below.
    if ($rows -and $path -notin '/api/search', '/api/onprem-search', '/api/bulk-resolve', '/api/onprem-report') {
        foreach ($x in $rows) {
            $tg = Get-ActTarget $x
            if ($x.team) { $tg = "$tg (team: $($x.team))" }
            Write-ActRow $screen $action $tg (Get-ActRowResult $x) $detail
        }
        return
    }
    # one row for the whole call
    # Single row for the whole call: choose the Target text by path (the user, the mailbox, the job id, the signed-in account...).
    $tg = switch ($path) {
        { $_ -in '/api/enable', '/api/disable', '/api/mfa-list', '/api/mfa-revoke', '/api/mfa-mail' } { "$($d.upn)" }
        '/api/connect' { "$($script:Who)" }
        '/api/ad-connect' { $(if ($script:AdCred) { "$($script:AdCred.User)" } else { '' }) }
        '/api/dg-run' { "job $($resp.id)" }
        { $_ -in '/api/mbx-info', '/api/mbx-change' } { "$($d.mailbox)" }
        '/login' { $(if ($code -eq 200) { "$($d.username)" } else { '' }) }
        default { @(@($d.usernames) + @($d.sams) + @($d.queries) + @($d.groupIds) | Where-Object { $_ } | Select-Object -First 20) -join '; ' }
    }
    # Choose the Result text for the single row.
    $res = 'Done'
    if ($path -in '/api/audit-cloud', '/api/audit-ad' -and $resp) { $res = "$($resp.count) row(s) shown" + $(if ($resp.truncated) { ' (limit reached)' } else { '' }) }
    if ($path -eq '/api/mfa-revoke' -and $resp) { $res = "Removed $(@($resp.removed).Count), failed $(@($resp.failed).Count)" + $(if ($resp.signedOut) { ', signed out of all sessions' } else { '' }) }
    elseif ($rows) {
        $res = "$(@($rows).Count) result(s)"
        if ($path -eq '/api/search') { $res += ' - ' + ((@($rows) | ForEach-Object { "$(Get-ActTarget $_): $($_.exists)/$($_.enabled)" } | Select-Object -First 10) -join '; ') }
    } elseif ($path -in '/api/dg-run', '/api/mbx-change' -and $resp.summary) { $res = "Queued - $($resp.summary) (each step is logged when it finishes)" }
    if ($path -eq '/api/mfa-revoke' -and $resp -and @($resp.removed).Count) { $detail = (($detail, ('methods removed: ' + ((@($resp.removed) | ForEach-Object { if ($_ -is [string]) { $_ } else { "$($_.type)$($_.name)" } }) -join '; '))) | Where-Object { $_ }) -join ', ' }
    Write-ActRow $screen $action $tg $res $detail
}

# ---------------- SharePoint ----------------
# Reads sharepoint-settings.json. Defaults are used for missing values; copying to SharePoint is ON by default (an old file without 'auto' is switched on).
function Get-SpCfg {
    $c = [ordered]@{ enabled = $true; auto = $true; siteUrl = 'https://stuuobedu.sharepoint.com/sites/Logs'; library = 'Documents'; folder = 'Admin Console' }
    if (Test-Path $script:SpCfgFile) {
        try { $j = Get-Content $script:SpCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } }; if ($null -eq $j.auto) { $c.enabled = $true } } catch {}   # a settings file from before 1.97.2: copying to the cloud is now automatic by default
    }
    $c
}
# Reads sharepoint-sync.json: for each local file the stamp (size|time) it had when it was last uploaded.
function Get-SpState {
    $h = @{}
    if (Test-Path $script:SpStateFile) { try { (Get-Content $script:SpStateFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = "$($_.Value)" } } catch {} }
    $h
}
# Saves that list. Errors are ignored: the worst case is that a file is uploaded once more.
function Save-SpState($h) { try { ([pscustomobject]$h | ConvertTo-Json) | Out-File $script:SpStateFile -Encoding utf8 } catch {} }
# Local log files that should be in SharePoint, with the path they get there (month folder, then this computer)
# Lists the local log files that belong in SharePoint (CSV logs; .txt/.log only inside the exports folder) with their SharePoint path:
# <yyyy-MM>/<COMPUTER>/[Exports/]<file name>. 'stamp' = size + time, used to see if a file changed.
function Get-SpFiles {
    $out = @()
    foreach ($f in @(Get-ChildItem -Path $LogDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.csv', '.txt', '.log' })) {
        $mo = if ($f.Name -match '(\d{4}-\d{2})') { $Matches[1] } else { '{0:yyyy-MM}' -f $f.LastWriteTime }
        $rel = $f.FullName.Substring($LogDir.Length).TrimStart('\', '/')
        $isExp = $rel -match '^exports[\\/]'
        if (-not $isExp -and $f.Extension -ne '.csv') { continue }
        $sub = if ($isExp) { 'Exports/' } else { '' }
        $out += [pscustomobject]@{ file = $f; key = $rel; remote = "$mo/$($script:Computer)/$sub$($f.Name)"; stamp = ('{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks) }
    }
    $out
}
# Files whose stamp differs from the last uploaded one = still to upload.
function Get-SpPending { $st = Get-SpState; @(Get-SpFiles | Where-Object { $st[$_.key] -ne $_.stamp }) }
# URL-encodes each part of a SharePoint path (spaces and special characters) and keeps the slashes.
function ConvertTo-SpPath($p) { (($p -split '/') | Where-Object { $_ } | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/' }
# Finds the SharePoint site and the document library (drive) from the settings via Graph and stores the IDs in $script:SpCache.
# Throws a readable error if the address is wrong or the library does not exist (the error lists the libraries that do).
function Resolve-SpDrive($cfg) {
    $key = "$($cfg.siteUrl)|$($cfg.library)|$($script:Who)"
    if ($script:SpCache.key -eq $key -and $script:SpCache.driveId) { return }
    $u = [uri]"$($cfg.siteUrl)".Trim().TrimEnd('/')
    if ($u.Scheme -ne 'https' -or $u.Host -notmatch '\.sharepoint\.com$') { throw 'The SharePoint site must look like https://<tenant>.sharepoint.com/sites/<site>.' }
    $site = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/sites/$($u.Host):$($u.AbsolutePath)") -ErrorAction Stop
    $drives = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/drives" -ErrorAction Stop).value)
    $lib = "$($cfg.library)".Trim()
    # Match the library by display name or by the last part of its URL (also URL-decoded), ignoring case.
    $drv = $drives | Where-Object { $_.name -ieq $lib -or ("$($_.webUrl)" -split '/')[-1] -ieq $lib -or [uri]::UnescapeDataString(("$($_.webUrl)" -split '/')[-1]) -ieq $lib } | Select-Object -First 1
    if (-not $drv) {
        # The default library has different names in different languages; ask Graph for the site's default drive instead.
        if ($lib -in '', 'Documents', 'Shared Documents') { $drv = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/drive" -ErrorAction Stop }
        else { throw "Library '$lib' not found on the site. Libraries there: $((@($drives | ForEach-Object { $_.name })) -join ', ')" }
    }
    $script:SpCache = @{ key = $key; driveId = $drv.id; siteId = $site.id; webUrl = "$($drv.webUrl)" }
}
# Uploads one local file to SharePoint ($remote = path inside the document library), replacing the old copy.
function Send-SpFile($fullPath, $remote) {
    # copy first so the tool can keep writing the log while it uploads
    # Work on a temporary copy; it is always deleted again in the finally block.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('st-log-' + [guid]::NewGuid().ToString('N') + '.csv')
    Copy-Item -LiteralPath $fullPath -Destination $tmp -Force
    try {
        $base = "https://graph.microsoft.com/v1.0/drives/$($script:SpCache.driveId)/root:/$(ConvertTo-SpPath $remote)"
        $len = (Get-Item -LiteralPath $tmp).Length
        # Graph accepts a simple PUT only up to about 4 MB; below 3.5 MB use it, otherwise use an upload session.
        if ($len -le 3.5MB) {
            Invoke-MgGraphRequest -Method PUT -Uri "${base}:/content" -InputFilePath $tmp -ContentType 'text/csv' -ErrorAction Stop | Out-Null
        } else {
            # big file: upload session in 5 MB chunks (multiple of 320 KiB)
            $sess = Invoke-MgGraphRequest -Method POST -Uri "${base}:/createUploadSession" -Body (@{ item = @{ '@microsoft.graph.conflictBehavior' = 'replace' } } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
            # Upload in 5 MB pieces. Each piece is sent with a Content-Range header; the upload URL is pre-authorised so no Graph token is added.
            $bytes = [IO.File]::ReadAllBytes($tmp); $chunk = 320KB * 16; $pos = 0
            while ($pos -lt $bytes.Length) {
                $n = [Math]::Min($chunk, $bytes.Length - $pos); $part = New-Object byte[] $n; [Array]::Copy($bytes, $pos, $part, 0, $n)
                $req = [Net.HttpWebRequest]::Create($sess.uploadUrl); $req.Method = 'PUT'
                $req.Headers.Add('Content-Range', "bytes $pos-$($pos + $n - 1)/$($bytes.Length)"); $req.ContentLength = $n
                $s = $req.GetRequestStream(); $s.Write($part, 0, $n); $s.Close(); $req.GetResponse().Close()
                $pos += $n
            }
        }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
# Upload every log file that changed since its last upload. Needs the Microsoft sign-in (Graph).
# Uploads all changed log files. -Force means the user pressed the sync button. Sets $script:SpStatus for the screen. On any error the next try
# is in 2 minutes and the logs stay safe on this computer. Stops at the first failed file.
function Sync-SpLogs([switch]$Force) {
    $cfg = Get-SpCfg
    $script:SpStatus.site = "$($cfg.siteUrl)"
    if (-not $cfg.enabled) { $script:SpStatus.state = 'Off'; $script:SpStatus.message = 'Copying logs to SharePoint is switched off - logs are saved on this computer only.'; $script:SpDirty = $false; return }
    $pend = @(Get-SpPending); $script:SpStatus.pending = $pend.Count
    if (-not $pend.Count) { $script:SpDirty = $false; if ($script:SpStatus.state -ne 'Error') { $script:SpStatus.state = 'Up to date'; $script:SpStatus.message = 'All logs are in SharePoint.' }; if (-not $Force) { return } }
    # No Microsoft sign-in yet: wait (the upload starts by itself after someone signs in, see Invoke-SpIdle).
    if (-not $script:Who) { $script:SpStatus.state = 'Waiting'; $script:SpStatus.message = "$($pend.Count) log file(s) waiting - they are copied to SharePoint after you sign in to Microsoft."; return }
    if (-not $pend.Count) { $script:SpStatus.state = 'Up to date'; return }
    # Look up site and library. 403/Forbidden usually means the sign-in lacks Sites.ReadWrite.All or the account cannot edit the site.
    try { Resolve-SpDrive $cfg } catch {
        $m = $_.Exception.Message
        if ($m -match '403|Forbidden|accessDenied|Authorization') { $m += ' | Sign out of Microsoft and in again so the tool can ask for Sites.ReadWrite.All, and make sure your account can edit the site (with a certificate sign-in the app needs the Sites.ReadWrite.All application permission).' }
        $script:SpStatus.state = 'Error'; $script:SpStatus.message = "SharePoint: $m"; $script:SpNextTry = (Get-Date).AddMinutes(2); return
    }
    $st = Get-SpState; $done = 0; $fail = $null
    foreach ($p in $pend) {
        try { Send-SpFile $p.file.FullName "$($cfg.folder)/$($p.remote)"; $st[$p.key] = $p.stamp; $done++ }
        catch { $fail = "$($p.file.Name): $($_.Exception.Message)"; break }
    }
    Save-SpState $st
    $script:SpStatus.pending = @(Get-SpPending).Count
    $script:SpStatus.folderUrl = "$($script:SpCache.webUrl)/$(ConvertTo-SpPath $cfg.folder)"
    if ($fail) {
        $script:SpStatus.state = 'Error'; $script:SpStatus.message = "Upload failed - $fail. It is tried again in 2 minutes; the logs are safe on this computer."; $script:SpNextTry = (Get-Date).AddMinutes(2)
    } else {
        $script:SpStatus.state = 'Up to date'; $script:SpStatus.message = "Copied $done file(s) to SharePoint."; $script:SpStatus.at = (Get-Date).ToUniversalTime().ToString('o'); $script:SpDirty = $false
    }
}
# Called by server.ps1 once a second while no request is waiting
# Called by server.ps1 about once a second while nothing else is happening. Starts an upload about 1 second after the last action,
# right after someone signs in to Microsoft, and every 10 minutes as a safety scan.
function Invoke-SpIdle {
    # the moment someone signs in to Microsoft (or the signed-in account changes) the waiting logs are copied - nothing to click
    if ($script:Who -ne $script:SpSeenWho) {
        $script:SpSeenWho = $script:Who
        if ($script:Who) { $script:SpDirty = $true; $script:SpLastAct = (Get-Date).AddSeconds(-10); $script:SpNextTry = Get-Date; $script:SpCache.key = $null }
    }
    if ((Get-Date) -lt $script:SpNextTry) { return }
    $quiet = ((Get-Date) - $script:SpLastAct).TotalSeconds
    $scan = ((Get-Date) - $script:SpLastScan).TotalMinutes -ge 10   # also pick up files changed outside a request (for example after a restart)
    if (($script:SpDirty -and $quiet -ge 1) -or $scan) {   # about 1 second after the last action
        $script:SpLastScan = Get-Date
        try { Sync-SpLogs } catch { $script:SpStatus.state = 'Error'; $script:SpStatus.message = "SharePoint: $($_.Exception.Message)"; $script:SpNextTry = (Get-Date).AddMinutes(2) }
    }
}

# ---------------- API for the Logs panel ----------------
# Endpoint: /api/logs-status - no input. Sends the SharePoint settings, the copy status, the local log folder and today's file.
$ScreenHandlers['/api/logs-status'] = {
    if (-not $script:SpStatus.at -and $script:SpStatus.state -ne 'Error') { $script:SpStatus.pending = @(Get-SpPending).Count }
    Send $ctx @{ ok = $true; settings = (Get-SpCfg); status = $script:SpStatus; local = $LogDir; computer = $script:Computer; today = (Get-ActFile (Get-Now)) }
}
# Endpoint: /api/logs-settings - body { enabled, siteUrl, library, folder }. Validates the site address (https://<tenant>.sharepoint.com/sites|teams/<name>) and the
# folder name, saves the settings and forgets what was uploaded so that everything is copied to the new place.
$ScreenHandlers['/api/logs-settings'] = {
    $c = Get-SpCfg
    $u = "$($d.siteUrl)".Trim().TrimEnd('/')
    if ($u -notmatch '^https://[a-z0-9-]+\.sharepoint\.com/(sites|teams)/[^/?#]+$') { throw 'Enter the site address like https://contoso.sharepoint.com/sites/Logs' }
    $fo = ("$($d.folder)".Trim() -replace '[\\]+', '/').Trim('/')
    if ($fo -match '[*:<>?"|#%]') { throw 'The folder name cannot contain * : < > ? " | # %' }
    $c.enabled = [bool]$d.enabled; $c.siteUrl = $u; $c.library = $(if ("$($d.library)".Trim()) { "$($d.library)".Trim() } else { 'Documents' }); $c.folder = $(if ($fo) { $fo } else { 'Admin Console' })
    ($c | ConvertTo-Json) | Out-File $script:SpCfgFile -Encoding utf8
    $script:SpCache.key = $null; $script:SpStatus.state = 'Waiting'; $script:SpStatus.message = 'Settings saved.'; $script:SpNextTry = Get-Date
    Remove-Item $script:SpStateFile -ErrorAction SilentlyContinue   # new place: copy everything again
    $script:SpDirty = $true; $script:SpLastAct = (Get-Date).AddSeconds(-10)
    Send $ctx @{ ok = $true; settings = $c }
}
# Screen Log settings: time zone of the log times, and the folder on this PC
# Endpoint: /api/logs-config - no input. Sends the log time zone settings and the local log folder (and whether it was changed from the default).
$ScreenHandlers['/api/logs-config'] = {
    Send $ctx @{ ok = $true; tzMode = $script:LogTzMode; tz = $script:LogTz; localDir = "$LogDir"; defaultDir = "$DefaultLogDir"; custom = ("$LogDir" -ne "$DefaultLogDir"); computer = $script:Computer; tzNow = (Get-TzText) }
}
# Endpoint: /api/logs-config-save - body { tzMode: device|fixed, tz, localDir }. Sets the time zone of the log times and the local log folder.
# The folder must be a full local or UNC path and must be writable (a test file is created and deleted). Saved in log-settings.json.
$ScreenHandlers['/api/logs-config-save'] = {
    $mode = "$($d.tzMode)"; if ($mode -notin 'device', 'fixed') { throw 'Choose the time zone of this device or a fixed time zone.' }
    $tz = "$($d.tz)".Trim()
    if ($mode -eq 'fixed' -and $tz -notmatch '^[A-Za-z0-9_/+-]{1,40}$') { throw 'Choose a time zone from the list.' }
    $dir = "$($d.localDir)".Trim().TrimEnd('\', '/')
    if (-not $dir) { $dir = "$DefaultLogDir" }
    elseif ($dir -notmatch '^([A-Za-z]:\\|\\\\)' -or $dir -match '[*?"<>|]') { throw 'Type the full folder path, for example D:\SupportTool\logs or \\server\share\logs.' }
    try {
        New-Item -ItemType Directory -Force $dir -ErrorAction Stop | Out-Null
        # Prove that the folder is writable before using it.
        $probe = Join-Path $dir ('.write-test-' + [guid]::NewGuid().ToString('N')); 'x' | Set-Content -LiteralPath $probe -ErrorAction Stop; Remove-Item -LiteralPath $probe -Force
    } catch { throw "This folder cannot be used: $($_.Exception.Message)" }
    $moved = ("$dir" -ne "$LogDir")
    $script:LogTzMode = $mode; $script:LogTz = $(if ($mode -eq 'fixed') { $tz } else { '' })
    ([ordered]@{ tzMode = $mode; tz = $script:LogTz; localDir = $(if ("$dir" -eq "$DefaultLogDir") { '' } else { $dir }) } | ConvertTo-Json) | Out-File (Join-Path $Root 'log-settings.json') -Encoding utf8
    # The folder changed: switch all log paths to it now (no restart needed) and upload everything again.
    if ($moved) {
        $script:LogDir = $dir; $LogDir = $dir
        $script:ActDir = Join-Path $LogDir 'activity'; New-Item -ItemType Directory -Force $script:ActDir | Out-Null
        $script:SpStateFile = Join-Path $LogDir 'sharepoint-sync.json'
        $script:SpDirty = $true; $script:SpLastAct = (Get-Date).AddSeconds(-10); $script:SpNextTry = Get-Date
    }
    Send $ctx @{ ok = $true; moved = $moved; localDir = "$LogDir" }
}
# Endpoint: /api/logs-autocopy - body { enabled }. Switches the automatic copy to SharePoint on or off.
$ScreenHandlers['/api/logs-autocopy'] = {
    # the switch for copying the logs to the cloud automatically (on by default)
    $c = Get-SpCfg
    $c.enabled = [bool]$d.enabled; $c.auto = $true
    ($c | ConvertTo-Json) | Out-File $script:SpCfgFile -Encoding utf8
    if ($c.enabled) { $script:SpStatus.state = 'Waiting'; $script:SpStatus.message = 'Copying to the cloud is on.'; $script:SpDirty = $true; $script:SpLastAct = (Get-Date).AddSeconds(-10); $script:SpNextTry = Get-Date }
    else { $script:SpStatus.state = 'Off'; $script:SpStatus.message = 'Copying logs to SharePoint is switched off - logs are saved on this computer only.'; $script:SpDirty = $false }
    Send $ctx @{ ok = $true; settings = $c; status = $script:SpStatus }
}
# Endpoint: /api/logs-sync - no input. 'Sync now' button: forgets the cached site IDs and uploads straight away.
$ScreenHandlers['/api/logs-sync'] = {
    $script:SpNextTry = Get-Date; $script:SpCache.key = $null
    Sync-SpLogs -Force
    Send $ctx @{ ok = $true; status = $script:SpStatus }
}
# Endpoint: /api/logs-recent - body { days (1-31) }. The newest rows (max 1000) of the activity log. Without the 'See all logs' permission
# only the person's own actions are returned.
$ScreenHandlers['/api/logs-recent'] = {
    # newest activity rows (from the local files), for the Activity log window
    $days = [Math]::Max(1, [Math]::Min(31, [int]$(if ($d.days) { $d.days } else { 1 })))
    $rows = @()
    for ($i = 0; $i -lt $days; $i++) {
        $f = Get-ActFile ((Get-Now).AddDays(-$i))
        if (Test-Path $f) { $rows += @(Import-Csv -LiteralPath $f -Encoding UTF8) }
    }
    if (-not (Test-CanLogs)) { $me = "$($script:SessUser.name)"; $rows = @($rows | Where-Object { $_.ToolUser -ieq $me }) }   # without the 'See all logs' permission: only your own actions
    $rows = @($rows | Sort-Object Time -Descending | Select-Object -First 1000)
    Send $ctx @{ ok = $true; rows = $rows; days = $days }
}
# Endpoint: /api/logs-logins - body { days (1-93) }. Tool sign-in rows (max 1000) from the login-audit files of the last 4 months. Sign-ins whose time cannot be read are kept.
$ScreenHandlers['/api/logs-logins'] = {
    # every tool sign-in (who, result, IP address, PC) - only for the owner, administrators and people allowed to see all logs
    $days = [Math]::Max(1, [Math]::Min(93, [int]$(if ($d.days) { $d.days } else { 7 })))
    $from = (Get-Now).AddDays(-$days); $rows = @()
    foreach ($m in @(0, 1, 2, 3)) {
        $f = Join-Path $LogDir ('login-audit-{0:yyyy-MM}.csv' -f (Get-Date).AddMonths(-$m))
        if (Test-Path $f) { try { $rows += @(Import-Csv -LiteralPath $f -Encoding UTF8) } catch {} }
    }
    $rows = @($rows | Where-Object { try { [datetime]$_.Time -ge $from } catch { $true } } | Sort-Object Time -Descending | Select-Object -First 1000)
    Send $ctx @{ ok = $true; rows = $rows; days = $days }
}
# v1.98.14: Log viewer screen - READ ONLY search of the activity log and the sign-in log (nothing is changed, moved or deleted)
# { kind:'activity'|'signin', from:'yyyy-MM-dd', to:'yyyy-MM-dd', q, user, screen, result:'all'|'ok'|'fail' }
# Endpoint: /api/logs-search - read-only search used by the Log viewer. Steps: 1) read the local CSV files of the chosen days (or the SharePoint copies from all computers
# when source = 'sp'), 2) restrict to the person's own rows without 'See all logs', 3) filter by text / user / screen / result, 4) send the newest 5000 rows.
$ScreenHandlers['/api/logs-search'] = {
    $kind = if ("$($d.kind)" -eq 'signin') { 'signin' } else { 'activity' }
    if ($kind -eq 'signin' -and -not (Test-CanLogs)) { throw 'Seeing the sign-in log needs the "See all logs" permission.' }
    $ci = [Globalization.CultureInfo]::InvariantCulture; $today = (Get-Now).Date
    $to = $today; $from = $today.AddDays(-6)
    try { if ("$($d.to)") { $to = [datetime]::ParseExact("$($d.to)", 'yyyy-MM-dd', $ci) } } catch { throw 'The "to" date is not valid.' }
    try { if ("$($d.from)") { $from = [datetime]::ParseExact("$($d.from)", 'yyyy-MM-dd', $ci) } } catch { throw 'The "from" date is not valid.' }
    # Swap the dates if they were given in the wrong order; the range is limited to one year.
    if ($from -gt $to) { $x = $from; $from = $to; $to = $x }
    if (($to - $from).TotalDays -gt 366) { throw 'Choose at most one year at a time.' }
    $rows = New-Object System.Collections.ArrayList; $files = New-Object System.Collections.ArrayList   # v1.98.24: where every row comes from
    if ($kind -eq 'activity') {
        for ($t = $from; $t -le $to; $t = $t.AddDays(1)) {
            $f = Join-Path (Join-Path $script:ActDir ('{0:yyyy-MM}' -f $t)) ('activity-{0:yyyy-MM-dd}.csv' -f $t)
            if (Test-Path -LiteralPath $f) { try { $n = 0; $fn = [IO.Path]::GetFileName($f); foreach ($r in @(Import-Csv -LiteralPath $f -Encoding UTF8)) { $r | Add-Member -NotePropertyName LogFile -NotePropertyValue $fn -Force; [void]$rows.Add($r); $n++ }; [void]$files.Add(@{ name = $fn; path = $f; rows = $n }) } catch {} }
        }
        if (-not (Test-CanLogs)) { $me = "$($script:SessUser.name)"; $rows = [System.Collections.ArrayList]@($rows | Where-Object { $_.ToolUser -ieq $me }) }   # only your own actions
    } else {
        for ($m = New-Object DateTime($from.Year, $from.Month, 1); $m -le $to; $m = $m.AddMonths(1)) {
            $f = Join-Path $LogDir ('login-audit-{0:yyyy-MM}.csv' -f $m)
            if (Test-Path -LiteralPath $f) { try { $n = 0; $fn = [IO.Path]::GetFileName($f); foreach ($r in @(Import-Csv -LiteralPath $f -Encoding UTF8)) { $tm = $null; try { $tm = [datetime]"$($r.Time)" } catch {}; if (-not $tm -or ($tm.Date -ge $from -and $tm.Date -le $to)) { $r | Add-Member -NotePropertyName LogFile -NotePropertyValue $fn -Force; [void]$rows.Add($r); $n++ } }; [void]$files.Add(@{ name = $fn; path = $f; rows = $n }) } catch {} }
        }
    }
    # v2.4.0: source 'sp' = the copies in SharePoint, from EVERY computer that runs the tool (read only - downloaded, never changed)
    # Search the SharePoint copies instead of the local files. The Graph helper $kids lists a folder; downloaded files are cached by their eTag so
    # unchanged files are not downloaded again on the next search.
    $spSrc = ("$($d.source)" -eq 'sp')
    if ($spSrc) {
        $rows = New-Object System.Collections.ArrayList; $files = New-Object System.Collections.ArrayList
        $cfg = Get-SpCfg
        if (-not $script:Who) { throw 'Searching the SharePoint logs needs the Microsoft sign-in. Connect to Microsoft first (Settings > Connections or the M365 button).' }
        Use-SessGraph
        try { Resolve-SpDrive $cfg } catch { throw "SharePoint: $($_.Exception.Message)" }
        $drv = $script:SpCache.driveId
        if (-not $global:SpLogCache) { $global:SpLogCache = @{} }
        $kids = { param($path) try { @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/drives/$drv/root:/$(ConvertTo-SpPath $path):/children?`$top=999&`$select=id,name,eTag,folder,file,lastModifiedDateTime" -ErrorAction Stop).value) } catch { if ("$($_.Exception.Message)" -match '404|itemNotFound|NotFound') { @() } else { throw } } }
        # File names to read: one activity file per day, or the login-audit file of each month. Layout in SharePoint: <folder>/<month>/<computer>/<file>.
        $want = New-Object System.Collections.Generic.HashSet[string]
        if ($kind -eq 'activity') { for ($t = $from; $t -le $to; $t = $t.AddDays(1)) { [void]$want.Add(('activity-{0:yyyy-MM-dd}.csv' -f $t)) } }
        $months = @(); for ($m = New-Object DateTime($from.Year, $from.Month, 1); $m -le $to; $m = $m.AddMonths(1)) { $months += $m }
        foreach ($m in $months) {
            $mo = '{0:yyyy-MM}' -f $m
            if ($kind -ne 'activity') { [void]$want.Add("login-audit-$mo.csv") }
            foreach ($pc in @(& $kids "$($cfg.folder)/$mo" | Where-Object { $_.folder })) {
                foreach ($it in @(& $kids "$($cfg.folder)/$mo/$($pc.name)" | Where-Object { $_.file -and $want.Contains("$($_.name)") })) {
                    $ck = "$($it.id)"; $c = $global:SpLogCache[$ck]
                    if (-not $c -or $c.etag -ne "$($it.eTag)") {
                        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('st-splog-' + [guid]::NewGuid().ToString('N') + '.csv')
                        try { Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/drives/$drv/items/$($it.id)/content" -OutputFilePath $tmp -ErrorAction Stop; $c = @{ etag = "$($it.eTag)"; rows = @(Import-Csv -LiteralPath $tmp -Encoding UTF8) }; $global:SpLogCache[$ck] = $c }
                        catch { continue } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                    }
                    $n = 0
                    foreach ($r0 in $c.rows) {
                        if ($kind -ne 'activity') { $tm = $null; try { $tm = [datetime]"$($r0.Time)" } catch {}; if ($tm -and ($tm.Date -lt $from -or $tm.Date -gt $to)) { continue } }
                        $r = $r0.PSObject.Copy(); $r | Add-Member -NotePropertyName Computer -NotePropertyValue "$($pc.name)" -Force; $r | Add-Member -NotePropertyName LogFile -NotePropertyValue "$($pc.name)/$($it.name)" -Force
                        [void]$rows.Add($r); $n++
                    }
                    [void]$files.Add(@{ name = "$($pc.name)/$($it.name)"; path = "SharePoint: $($cfg.folder)/$mo/$($pc.name)/$($it.name)"; rows = $n })
                }
            }
        }
        if ($kind -eq 'activity' -and -not (Test-CanLogs)) { $me = "$($script:SessUser.name)"; $rows = [System.Collections.ArrayList]@($rows | Where-Object { $_.ToolUser -ieq $me }) }
    }
    $all = @($rows)
    $users = @($all | ForEach-Object { if ($kind -eq 'activity') { "$($_.ToolUser)" } else { "$($_.EnteredUsername)" } } | Where-Object { $_ } | Sort-Object -Unique)
    $screens = @(if ($kind -eq 'activity') { $all | ForEach-Object { "$($_.Screen)" } | Where-Object { $_ } | Sort-Object -Unique })
    $q = "$($d.q)".Trim(); $u = "$($d.user)"; $sc = "$($d.screen)"; $res = "$($d.result)"
    # Words in the Result column that mean the action did not succeed (used by the result filter ok / fail).
    $bad = 'fail|error|refused|denied|locked|not allowed|forbidden|expired'
    # Apply the filters. Text search: every word typed must appear somewhere in the row (any order, ignoring case).
    $hit = @($all | Where-Object {
        $r = $_
        if ($u) { $who = if ($kind -eq 'activity') { "$($r.ToolUser)" } else { "$($r.EnteredUsername)" }; if ($who -ine $u) { return $false } }
        if ($sc -and "$($r.Screen)" -ine $sc) { return $false }
        if ($res -eq 'ok' -and "$($r.Result)" -match $bad) { return $false }
        if ($res -eq 'fail' -and "$($r.Result)" -notmatch $bad) { return $false }
        if ($q) { $txt = (@($r.PSObject.Properties | ForEach-Object { "$($_.Value)" }) -join ' '); foreach ($w in ($q -split '\s+')) { if ($w -and $txt.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false } } }
        $true
    } | Sort-Object Time -Descending)
    # Maximum rows sent to the page; 'more' tells the page that the result was cut.
    $max = 5000
    Send $ctx @{ ok = $true; kind = $kind; from = $from.ToString('yyyy-MM-dd'); to = $to.ToString('yyyy-MM-dd'); total = $all.Count; count = $hit.Count; more = ($hit.Count -gt $max)
                 rows = @($hit | Select-Object -First $max); users = $users; screens = $screens; all = [bool](Test-CanLogs)
                 source = @{ sp = $spSrc; computer = $(if ($spSrc) { 'all computers (SharePoint)' } else { "$env:COMPUTERNAME" }); folder = $(if ($kind -eq 'activity') { "$($script:ActDir)" } else { "$LogDir" }); files = @($files); cloud = $(try { $sc = Get-SpCfg; if ($sc.enabled) { "$($sc.siteUrl) > $($sc.library) > $($sc.folder)" } else { '' } } catch { '' }) } }
}
# Endpoint: /api/logs-open - opens the local log folder in Windows Explorer (works because the tool runs on this computer).
$ScreenHandlers['/api/logs-open'] = {
    # opens the local logs folder in Explorer on this computer (the tool runs here)
    Start-Process explorer.exe -ArgumentList "`"$LogDir`""
    Send $ctx @{ ok = $true }
}

# ---------------- exports: every CSV you download is also kept here and in SharePoint ----------------
# Exports: every CSV the user downloads is also stored under logs\exports and copied to SharePoint. This table maps the start of a file name to the screen name.
$script:ExpScreens = [ordered]@{ 'reset-results' = 'Reset cloud passwords'; 'account-status' = 'Check account status'; 'mfa-' = 'Revoke MFA'; 'onprem-' = 'On-premises AD'
    'user-report' = 'Bulk & report'; 'bulk-' = 'Bulk & report'; 'teams-' = 'Teams members'; 'dg-' = 'Distribution groups'; 'activity' = 'Logs' }
# Returns the screen name for an export file name (first matching prefix), or 'Export'.
function Get-ExpScreen($name) { foreach ($k in $script:ExpScreens.Keys) { if ("$name" -like "$k*") { return $script:ExpScreens[$k] } }; 'Export' }
# Endpoint: /api/export-save - body { name, text, view }. Saves a copy of the CSV the browser just downloaded (max 20 MB).
$ScreenHandlers['/api/export-save'] = {
    # { name, text, view } - the browser sends the same CSV it just downloaded
    # Clean the file name: remove any folder part, replace unsafe characters by _, collapse '..' and trim spaces/dots (stops path tricks).
    $name = ([IO.Path]::GetFileName("$($d.name)") -replace '[^\w.\- ]', '_' -replace '\.{2,}', '_').Trim(' .')
    if (-not $name) { $name = 'export.csv' }
    if ($name -notmatch '\.(csv|txt|log)$') { $name += '.csv' }
    $text = "$($d.text)"
    if ($text.Length -gt 20MB) { throw 'The export is larger than 20 MB - it was downloaded but not saved in the logs.' }
    if ($text.StartsWith([char]0xFEFF)) { $text = $text.Substring(1) }
    $t = Get-Now; $dir = Join-Path $LogDir ('exports\{0:yyyy-MM}' -f $t); New-Item -ItemType Directory -Force $dir | Out-Null
    $base = '{0:yyyy-MM-dd_HHmmss}_{1}' -f $t, $name; $file = Join-Path $dir $base; $i = 2
    # If the name exists already, add _2, _3 ... before the file ending.
    while (Test-Path $file) { $file = Join-Path $dir ($base -replace '(\.[a-z]+)$', "_$i`$1"); $i++ }
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $true))   # with BOM, so Excel shows accents right
    $rows = [Math]::Max(0, @($text -split "`r?`n" | Where-Object { $_ }).Count - 1)
    $script:SpDirty = $true; $script:SpLastAct = Get-Date
    Send $ctx @{ ok = $true; file = (Split-Path $file -Leaf); rows = $rows }
}
# Things that only happen in the browser but matter for the audit (showing or copying a password)
# Browser-only events that are worth an audit row (showing or copying a password).
$script:UiEvents = @('Reveal passwords', 'Hide passwords', 'Copy password', 'Copy pass', 'Copy AD password')
# Endpoint: /api/log-event - body { action, screen, target }. Only the listed events and screens are accepted; the row itself is written by Write-Activity after this handler.
$ScreenHandlers['/api/log-event'] = {
    if ("$($d.action)" -notin $script:UiEvents) { throw 'Unknown event.' }
    if ("$($d.screen)" -notin 'Reset cloud passwords', 'On-premises AD') { throw 'Unknown screen.' }
    $tg = "$($d.target)"; if ($tg.Length -gt 300) { $tg = $tg.Substring(0, 300) }
    $d.target = $tg
    Send $ctx @{ ok = $true }
}

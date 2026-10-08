# Screen-MailboxCleanup.ps1 - back end for the Mailbox cleanup screen.
# Screen: Mailbox cleanup
# Screen version: 2.5.0   (changes ONLY when this screen changes - not with every release)
# Loaded by server.ps1 at start-up; do not run it on its own.
#
# Deletes the MAIL of user mailboxes (all mail folders, chosen folders, or only items older than a date) - the mailbox and the
# account stay. Microsoft Graph cannot open other people's mailboxes with an admin's own sign-in, so this uses your OWN app
# registration (Settings > Connections > Microsoft app) with the APPLICATION permission Mail.ReadWrite (admin consent) and a
# client secret. Items are deleted with permanentDelete (they go to Recoverable Items > Purges and disappear after the
# retention time; a litigation hold or retention policy can still keep them). Calendar, contacts and tasks are not touched.
# Permission in the portal: "Delete mailbox data" (off by default). Every run is logged (activity log + logs\mailbox-cleanup-audit-yyyy-MM.csv).

# SCREEN: Mailbox cleanup (delete the mail inside user mailboxes).
# Endpoints: /api/mp-status (is the app ready?), /api/mp-lookup (read folder sizes, background job 'mplook'),
# /api/mp-run (do the deletion, background job 'mprun'). Completed runs are written to the audit CSV by Complete-GJob_mprun.
# Uses Microsoft Graph with an APPLICATION token (client-credentials) from the admin's own app registration - not the admin's sign-in.
# The Graph jobs run in the background (Start-GJob); the code of those jobs is kept in the here-strings below, so it carries no comments
# inside (a comment inside a here-string would become part of the job script).
#
# Gets an app-only Graph token using the saved app (client id, tenant, DPAPI-protected secret). Throws 'NEED_APP' if the app is not set up.
# Returns @{ token; roles; ok; client; tenant; secret } where ok = the token really contains the Mail.ReadWrite application role.
function Get-MpAppToken {
    $c = Get-MsAppCfg
    if (-not $c.clientId -or -not $c.secretEnc) { throw 'NEED_APP' }
    $ten = $(if ($c.tenant) { "$($c.tenant)" } else { throw 'NEED_APP' })
    $r = Invoke-MsToken @{ client_id = "$($c.clientId)"; client_secret = (Unprotect-MailSecret "$($c.secretEnc)"); grant_type = 'client_credentials'; scope = 'https://graph.microsoft.com/.default' } $ten
    # Read the 'roles' claim inside the token to learn which application permissions were really granted (admin consent given or not).
    $roles = @((Get-IdClaims $r.access_token).roles)
    @{ token = "$($r.access_token)"; roles = $roles; ok = ($roles -contains 'Mail.ReadWrite'); client = "$($c.clientId)"; tenant = $ten; secret = (Unprotect-MailSecret "$($c.secretEnc)") }
}
# ENDPOINT /api/mp-status - tells the page if the Microsoft app exists (app) and has Mail.ReadWrite (mailRw). Nothing is changed.
# Returns { ok, app, mailRw, error, roles }. 'NEED_APP' is not an error here, it just means the app is not set up yet.
$ScreenHandlers['/api/mp-status'] = {
    $o = @{ ok = $true; app = $false; mailRw = $false; error = ''; roles = @() }
    try { $t = Get-MpAppToken; $o.app = $true; $o.mailRw = $t.ok; $o.roles = @($t.roles) } catch { if ("$($_.Exception.Message)" -ne 'NEED_APP') { $o.error = "$($_.Exception.Message)"; $o.app = $true } }
    Send $ctx $o
}
# Job helper code (here-string, runs inside the background job). It contains: Update-MpTok (renews the app token 5 minutes before it ends),
# Set-MpSize (reads folder size from MAPI property 0x0E08), Get-MpFolders (walks all mail folders and sub folders, breadth first, 250 per page)
# and Get-MpWellKnown (maps folder ids to names such as inbox / sentitems so the standard folders can be recognised in any language).
# functions for the jobs (app token that renews itself)
$script:MpPrelude = @'
function Update-MpTok { if ((Get-Date) -lt $p.TokUntil) { return }
    $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($p.Tenant)/oauth2/v2.0/token" -Body @{ client_id = $p.Client; client_secret = $p.Secret; grant_type = 'client_credentials'; scope = 'https://graph.microsoft.com/.default' } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    $p.Token = "$($r.access_token)"; $p.TokUntil = (Get-Date).AddSeconds([int]$r.expires_in - 300) }
# v2.4.9: the folder size is the MAPI property PR_MESSAGE_SIZE_EXTENDED (0x0E08) - Graph has no sizeInBytes on mailFolder
function Set-MpSize($f) { $v = 0; try { $x = @($f.singleValueExtendedProperties | Where-Object { "$($_.id)" -match '0x0E08' })[0]; if ($x) { $v = [double]$x.value } } catch {}; $f | Add-Member -NotePropertyName sizeInBytes -NotePropertyValue $v -Force }
function Get-MpFolders($u) {   # every mail folder (also sub folders), with its parent
    $all = New-Object Collections.Generic.List[object]; $queue = New-Object Collections.Generic.Queue[object]
    $top = (Invoke-G "beta/users/$u/mailFolders?`$top=250&`$select=id,displayName,totalItemCount,childFolderCount,parentFolderId&`$expand=singleValueExtendedProperties(`$filter=id eq 'Long 0x0E08')").value
    foreach ($f in @($top)) { Set-MpSize $f; $f | Add-Member -NotePropertyName path -NotePropertyValue "$($f.displayName)" -Force; $f | Add-Member -NotePropertyName level -NotePropertyValue 0 -Force; $all.Add($f); if ($f.childFolderCount -gt 0) { $queue.Enqueue($f) } }
    while ($queue.Count) { $pf = $queue.Dequeue(); Update-MpTok
        $uri = "beta/users/$u/mailFolders/$($pf.id)/childFolders?`$top=250&`$select=id,displayName,totalItemCount,childFolderCount,parentFolderId&`$expand=singleValueExtendedProperties(`$filter=id eq 'Long 0x0E08')"
        while ($uri) { $r = Invoke-G $uri; foreach ($f in @($r.value)) { Set-MpSize $f; $f | Add-Member -NotePropertyName path -NotePropertyValue "$($pf.path)\$($f.displayName)" -Force; $f | Add-Member -NotePropertyName level -NotePropertyValue ($pf.level + 1) -Force; $all.Add($f); if ($f.childFolderCount -gt 0) { $queue.Enqueue($f) } }; $uri = $r.'@odata.nextLink' } }
    , $all.ToArray()
}
$wk = @{ inbox = 'Inbox'; sentitems = 'Sent Items'; deleteditems = 'Deleted Items'; junkemail = 'Junk Email'; drafts = 'Drafts'; archive = 'Archive'; outbox = 'Outbox'; conversationhistory = 'Conversation History' }
function Get-MpWellKnown($u) { $o = @{}; foreach ($k in $wk.Keys) { try { $f = Invoke-G "v1.0/users/$u/mailFolders/$k`?`$select=id"; $o["$($f.id)"] = $k } catch {} }; $o }
'@
# Job code for the look-up (read only): for each mailbox, find the user, then add up item count and size of all folders and list the top level
# folders. Respects the Stop button ($p.Sync.cancel) and reports progress in $p.Sync. A friendly note replaces the typical 'no mailbox' errors.
$script:MpLookWork = @'
$rows = New-Object Collections.Generic.List[object]; $p.Sync.total = @($p.Items).Count; $i = 0
foreach ($it in @($p.Items)) {
    if ($p.Sync.cancel) { throw 'Stopped.' }
    $i++; $p.Sync.done = $i; $p.Sync.step = "Reading $it"; Update-MpTok
    $r = [ordered]@{ input = "$it"; upn = ''; name = ''; account = ''; items = 0; sizeGB = 0; folders = 0; ok = $false; note = ''; list = @() }
    try {
        # v2.4.8: the person is found with YOUR sign-in (it can read users); the app only needs Mail.ReadWrite to open the mailbox
        $pre = $p.Known["$it"]
        if ($pre) { $usr = [pscustomobject]@{ id = "$($pre.id)"; userPrincipalName = "$($pre.upn)"; displayName = "$($pre.name)"; accountEnabled = $pre.enabled } }
        elseif ($p.Unknown -contains "$it") { throw "$($p.UnknownWhy["$it"])" }
        else { $usr = Invoke-G ("v1.0/users/$([uri]::EscapeDataString("$it"))?`$select=id,userPrincipalName,displayName,accountEnabled,mail") }
        $r.upn = "$($usr.userPrincipalName)"; $r.name = "$($usr.displayName)"; $r.account = $(if ($usr.accountEnabled) { 'Enabled' } else { 'Disabled' })
        $fs = Get-MpFolders $usr.id; $known = Get-MpWellKnown $usr.id
        $t = 0; $b = 0.0; foreach ($f in $fs) { $t += [int64]$f.totalItemCount; $b += [double]$f.sizeInBytes }
        $r.items = $t; $r.sizeGB = [math]::Round($b / 1GB, 2); $r.folders = $fs.Count; $r.ok = $true
        $r.list = @($fs | Where-Object { $_.level -eq 0 -and ($_.totalItemCount -gt 0 -or $_.childFolderCount -gt 0) } | ForEach-Object { [ordered]@{ name = "$($_.displayName)"; items = [int64]$_.totalItemCount; known = [string]$known["$($_.id)"] } })
    } catch { $r.note = "$_"; if ($r.note -match 'MailboxNotEnabledForRESTAPI|mailbox is either inactive|not found|ResourceNotFound') { $r.note = 'No mailbox for this user (or it is not in Exchange Online).' } }
    $rows.Add($r)
}
@{ rows = $rows.ToArray() }
'@
# Job code for the deletion. For every mailbox: list all folders, pick the folders that match the chosen scope, then delete the mail.
# Remove-MpItems deletes in pages of 200 messages, sent to Graph as $batch requests of 20 (the Graph maximum).
#   - Method: POST .../permanentDelete first (goes to Recoverable Items > Purges). If Graph refuses it on the very first try, it falls back to DELETE.
#   - HTTP 429 = Graph is throttling: wait 5 seconds and continue. 3 rounds in a row without any success = give up on this folder.
#   - With a date ($since) only items received before that date are deleted, and no folders are removed.
#   - Without a date and with 'remove folders' on, non-standard folders are deleted completely (children first: folders sorted by level, deepest first).
# Result rows (Done / Partly done / Failed / Stopped / Skipped) are returned to Complete-GJob_mprun.
$script:MpRunWork = @'
$res = New-Object Collections.Generic.List[object]; $p.Sync.total = 0
$since = $(if ($p.Before) { ([datetime]$p.Before).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
$method = 'permanentDelete'
function Remove-MpItems($u, $fid, $label) {
    $n = 0; $bad = 0; $stuck = 0
    for (;;) {
        if ($p.Sync.cancel) { break }
        Update-MpTok
        $q = "v1.0/users/$u/mailFolders/$fid/messages?`$select=id&`$top=200" + $(if ($since) { "&`$filter=receivedDateTime lt $since" } else { '' })
        $ids = @((Invoke-G $q).value | ForEach-Object { $_.id }); if (-not $ids.Count) { break }
        $okThis = 0
        for ($k = 0; $k -lt $ids.Count; $k += 20) {
            $chunk = @($ids[$k..([Math]::Min($k + 19, $ids.Count - 1))])
            $reqs = @(); $j = 0; foreach ($id in $chunk) { $j++; $reqs += @{ id = "$j"; method = $(if ($script:method -eq 'permanentDelete') { 'POST' } else { 'DELETE' }); url = "/users/$u/messages/$id" + $(if ($script:method -eq 'permanentDelete') { '/permanentDelete' } else { '' }) } }
            $br = Invoke-G 'v1.0/$batch' 'POST' @{ requests = $reqs }
            $wait = 0
            foreach ($x in @($br.responses)) { $st = [int]$x.status
                if ($st -ge 200 -and $st -lt 300) { $n++; $okThis++ } elseif ($st -eq 429) { $wait = [Math]::Max($wait, 5) } elseif ($st -in 400, 404, 405 -and $script:method -eq 'permanentDelete' -and $n -eq 0 -and $okThis -eq 0) { $script:method = 'DELETE' } else { $bad++ } }
            if ($wait) { Start-Sleep -Seconds $wait }
            $p.Sync.done = [int]$p.Sync.done + $okThis; $p.Sync.step = "$($p.Cur): $label - $n deleted"
        }
        if ($okThis -eq 0) { $stuck++; if ($stuck -ge 3) { break } } else { $stuck = 0 }
    }
    @{ n = $n; bad = $bad }
}
foreach ($u in @($p.Users)) {
    if ($p.Sync.cancel) { $res.Add([ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); mailbox = $u; result = 'Skipped'; deleted = 0; failed = 0; foldersRemoved = 0; message = 'Stopped by the user' }); continue }
    $p.Cur = $u; $p.Sync.step = "$u - reading folders..."; Update-MpTok
    $row = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); mailbox = $u; result = ''; deleted = 0; failed = 0; foldersRemoved = 0; message = '' }
    try {
        $fs = Get-MpFolders $u; $known = Get-MpWellKnown $u
        $byId = @{}; foreach ($f in $fs) { $byId["$($f.id)"] = $f }
        $topOf = { param($f) $x = $f; while ($x.parentFolderId -and $byId.ContainsKey("$($x.parentFolderId)")) { $x = $byId["$($x.parentFolderId)"] }; $x }
        $want = { param($f) $t = & $topOf $f; $k = $known["$($t.id)"]; if ($p.Scope -contains 'all') { return $true }; if ($k) { return ($p.Scope -contains $k) }; return ($p.Scope -contains 'other') }
        $targets = @($fs | Where-Object { & $want $_ } | Sort-Object level -Descending)
        foreach ($f in $targets) {
            if ($p.Sync.cancel) { break }
            $isKnown = [bool]$known["$($f.id)"]
            $parentTargeted = ($f.parentFolderId -and $byId.ContainsKey("$($f.parentFolderId)") -and (& $want $byId["$($f.parentFolderId)"]) -and -not $known["$($f.parentFolderId)"] -and $f.level -gt 0)
            if (-not $since -and -not $isKnown -and $p.RemoveFolders) {
                if ($parentTargeted) { continue }   # removed together with its parent folder
                try { [void](Invoke-G "beta/users/$u/mailFolders/$($f.id)/permanentDelete" 'POST' @{}); $row.foldersRemoved++; $row.deleted += [int64]$f.totalItemCount; continue } catch { }
            }
            if ([int64]$f.totalItemCount -gt 0 -or $since) { $x = Remove-MpItems $u $f.id $f.path; $row.deleted += $x.n; $row.failed += $x.bad }
        }
        $row.result = $(if ($p.Sync.cancel) { 'Stopped' } elseif ($row.failed) { 'Partly done' } else { 'Done' })
        $row.message = "$($row.deleted) item(s) deleted" + $(if ($row.foldersRemoved) { ", $($row.foldersRemoved) folder(s) removed" } else { '' }) + $(if ($row.failed) { ", $($row.failed) could not be deleted" } else { '' }) + $(if ($script:method -ne 'permanentDelete') { ' (deleted - moved to Recoverable Items)' } else { ' (permanently deleted)' })
    } catch { $row.result = 'Failed'; $row.message = "$_" }
    $res.Add($row)
}
@{ rows = $res.ToArray() }
'@
# ENDPOINT /api/mp-lookup - read only. Input: $d.items (mailboxes: e-mail / UPN / user name, max 100).
# Finds each person with the ADMIN's own Microsoft sign-in (Find-CloudUser), then starts the 'mplook' background job with the app token.
# Returns { ok, id } - the page polls the job for the rows (name, account state, item count, size, folders).
$ScreenHandlers['/api/mp-lookup'] = {
    # Clean the list: trim, drop empty entries, remove duplicates.
    $items = @(@($d.items) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $items.Count) { throw 'Type at least one mailbox (e-mail / UPN).' }
    if ($items.Count -gt 100) { throw 'Up to 100 mailboxes at a time.' }
    try { $t = Get-MpAppToken } catch { if ("$($_.Exception.Message)" -eq 'NEED_APP') { throw 'Microsoft app not set up yet - click "Set it up now" above (or Settings > Connections > Microsoft app).' }; throw }
    if (-not $t.ok) { throw 'The Microsoft app does not have the APPLICATION permission Mail.ReadWrite (with admin consent).' }
    # Why the people are looked up here and not in the job: the app only has Mail.ReadWrite and may not read user accounts.
    # v2.4.8: find the people with the signed-in person's own Microsoft sign-in (also a username alone, e.g. 20196376) - the app
    # (Mail.ReadWrite only) is not allowed to read user accounts, that gave "Insufficient privileges"
    $known = @{}; $unknown = @(); $why = @{}
    if ($script:Who) {
        foreach ($it in $items) {
            try { $u = Find-CloudUser $it; $known[$it] = @{ id = "$($u.Id)"; upn = "$($u.UserPrincipalName)"; name = "$($u.DisplayName)"; enabled = $u.AccountEnabled } }
            catch { $m = "$($_.Exception.Message)"; if ($m -match 'No cloud account|matches several|More than one|not a valid') { $unknown += $it; $why[$it] = $m } }
        }
    # Without a Microsoft sign-in we cannot resolve a bare user name, so full e-mail addresses are required.
    } elseif (@($items | Where-Object { $_ -notmatch '@' }).Count) { throw 'Type full e-mail addresses (name@domain), or connect to Microsoft first so a username alone can be found.' }
    # Start the background job. The token is valid about an hour; TokUntil (45 min) tells the job when to renew it. Known/Unknown pass the look-up results.
    $id = Start-GJob 'mplook' ($script:MpPrelude + "`n" + $script:MpLookWork) @{ Token = $t.token; TokUntil = (Get-Date).AddMinutes(45); Client = $t.client; Tenant = $t.tenant; Secret = $t.secret; Items = $items; Known = $known; Unknown = $unknown; UnknownWhy = $why } 'Look up mailboxes'
    Send $ctx @{ ok = $true; id = $id }
}
# Called by the job system when the 'mprun' job ends ($res = result rows, $err = error text or empty, $j = the job).
# Writes one line per mailbox into the monthly audit file logs\mailbox-cleanup-audit-yyyy-MM.csv and into the activity log.
function Complete-GJob_mprun($j, $res, $err) {
    $f = Join-Path $LogDir ('mailbox-cleanup-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,PortalUser,Mailbox,Folders,OlderThan,Result,Deleted,Failed,FoldersRemoved,Message' | Out-File $f -Encoding utf8 }
    foreach ($r in @($res.rows)) {
        # One CSV line: time, portal user who started it, mailbox, folders, date limit, result, counts, message (ConvertTo-CsvCell quotes/escapes each value).
        $vals = @($r.time, $j.user, $r.mailbox, (@($j.arg.Scope) -join ' '), $j.arg.Before, $r.result, $r.deleted, $r.failed, $r.foldersRemoved, $r.message) | ForEach-Object { ConvertTo-CsvCell $_ }
        ($vals -join ',') | Add-Content $f
        Write-ActRow 'Mailbox cleanup' 'Delete mailbox data' $r.mailbox $r.result $r.message
    }
    if ($err) { Write-ActRow 'Mailbox cleanup' 'Delete mailbox data' '' "Failed: $err" '' }
    # Mark the saved state as changed so it is written to disk.
    $script:SpDirty = $true
}
# ENDPOINT /api/mp-run - DELETES MAIL. Input: $d.confirm (must be exactly DELETE, case sensitive), $d.users (e-mail addresses, max 50),
# $d.scope (folder names or 'all' / 'other'), $d.before (optional yyyy-mm-dd: only older mail), $d.removeFolders (also remove the folders).
# Returns { ok, id } of the 'mprun' background job. The action is written to the activity log when it starts.
$ScreenHandlers['/api/mp-run'] = {
    if ("$($d.confirm)" -cne 'DELETE') { throw 'Type DELETE to confirm.' }
    # Only accept entries that look like name@domain (one @, no spaces).
    $users = @(@($d.users) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[^@\s]+@[^@\s]+$' } | Select-Object -Unique)
    if (-not $users.Count) { throw 'Choose at least one mailbox.' }
    if ($users.Count -gt 50) { throw 'Up to 50 mailboxes at a time.' }
    # Keep only known scope values, so nothing unexpected is passed on to the job.
    $scope = @(@($d.scope) | ForEach-Object { "$_" } | Where-Object { $_ -in 'all', 'inbox', 'sentitems', 'deleteditems', 'junkemail', 'drafts', 'archive', 'outbox', 'conversationhistory', 'other' })
    if (-not $scope.Count) { throw 'Choose which folders.' }
    # Optional date limit: must look like 2025-01-31 (4-2-2 digits), be a real date, and not be in the future.
    $before = "$($d.before)".Trim(); if ($before -and $before -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'The date must be yyyy-mm-dd.' }
    if ($before -and [datetime]::ParseExact($before, 'yyyy-MM-dd', $null) -gt (Get-Date)) { throw 'The date cannot be in the future.' }
    try { $t = Get-MpAppToken } catch { if ("$($_.Exception.Message)" -eq 'NEED_APP') { throw 'Microsoft app not set up yet - click "Set it up now" above (or Settings > Connections > Microsoft app).' }; throw }
    if (-not $t.ok) { throw 'The Microsoft app does not have the APPLICATION permission Mail.ReadWrite (with admin consent).' }
    # Start the deletion job in the background with the app token and the checked options.
    $id = Start-GJob 'mprun' ($script:MpPrelude + "`n" + $script:MpRunWork) @{ Token = $t.token; TokUntil = (Get-Date).AddMinutes(45); Client = $t.client; Tenant = $t.tenant; Secret = $t.secret; Users = $users; Scope = $scope; Before = $before; RemoveFolders = [bool]$d.removeFolders; Cur = '' } "Delete mailbox data of $($users.Count) mailbox(es)"
    Write-ActRow 'Mailbox cleanup' 'Delete mailbox data' "$($users.Count) mailbox(es)" 'Started' "folders=$($scope -join ','); olderThan=$before"
    Send $ctx @{ ok = $true; id = $id }
}

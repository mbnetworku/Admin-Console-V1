# Screen-SharedMailbox.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Shared mailbox
# Screen version: 2.0.0   (changes ONLY when this screen changes - not with every release)

# Exchange Online cannot be changed through Microsoft Graph, so the work is done by the same background Exchange Online worker as
# Distribution groups (DistGroups-Worker.ps1, signed in with your Microsoft account). This file queues the job, waits for its
# Result_<id>.json, adds the Entra details (licenses, sign-in allowed) and can block sign-in after the conversion.
# Nothing is ever deleted: the account and the mail stay; only the access you tick is removed.

# SCREEN: Shared mailbox (look up a mailbox, convert it shared <-> regular, give / remove access, block sign-in, e-mail the people).
# Endpoints: /api/mbx-info (look up), /api/mbx-change (apply changes), /api/mbx-result (poll a job), /api/mbx-people (type-ahead people search),
# /api/mbx-notify (e-mail the people). The helpers Test-MbxId and New-MbxJob are also used by the Address list and Distribution groups screens.
# Data: job files in the Exchange Online worker folders ($script:DgPending / $script:DgUploads), Result_<id>.json written by the worker,
# Microsoft Graph (Get-MgUser, Update-MgUser, licenses) for the Entra part, and the mail settings (Get-MailCfg) for the e-mails.
# Needs: sign-in to Microsoft (the same sign-in is used by Exchange Online). Jobs are only known to this server run (lost on restart).
#
# In-memory list of the jobs started since the server started.
$script:MbxJobs = [ordered]@{}   # id -> job info (this server's jobs only)

# Checks a typed mailbox / person value: trims it, refuses empty text, control characters, double quotes and more than 256 characters
# (these would break the PowerShell command that the worker builds). $what is the word used in the error message. Returns the clean text.
function Test-MbxId($v, $what) {
    $v = "$v".Trim()
    if (-not $v) { throw "Type the $what." }
    if ($v -match '[\x00-\x1f"]' -or $v.Length -gt 256) { throw "The $what contains characters that are not allowed." }
    $v
}
# Queues one job for the Exchange Online worker. $job = ordered hashtable with Action + options, $summary = text shown to the admin.
# Checks that Microsoft is signed in, the worker is Connected and runs the same tool version, then writes job_<id>.json into the
# 'pending' folder (the worker picks it up) and remembers it in $script:MbxJobs. Returns the job id (mbx_yyyyMMdd_HHmmss_fff).
function New-MbxJob($job, $summary) {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections, or the M365 / AD button at the top right). Exchange Online uses the same sign-in.' }
    $w = Get-DgWorker
    if ($w.status -notmatch '^Connected') { throw "Exchange Online is not connected yet (status: $($w.status)). Wait until it says Connected." }
    if ($w.version -ne $AppVersion) { throw 'Exchange Online is still connected with the worker of an older version of the tool - it restarts by itself in a few seconds; try again when it says Connected.' }
    $id = 'mbx_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    # Each job gets its own Logs folder; the worker writes Result_<id>.json and FullRunLog_<id>.log there.
    $logFolder = Join-Path (Join-Path $script:DgUploads $id) 'Logs'
    New-Item -ItemType Directory -Force $logFolder | Out-Null
    $job.LogFolder = $logFolder
    $file = "job_$id.json"
    ($job | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $script:DgPending $file) -Encoding UTF8
    $script:MbxJobs[$id] = @{ id = $id; file = $file; logFolder = $logFolder; action = $job.Action; mailbox = $job.Mailbox; summary = $summary; block = [bool]$job.Block; unblock = [bool]$job.Unblock; logged = $false; extra = $null; time = (Get-Date) }
    $id
}

# ENDPOINT /api/mbx-info - read only. Input: $d.mailbox (e-mail address or user name). Queues an 'MbxInfo' job. Returns { ok, id }; poll /api/mbx-result.
$ScreenHandlers['/api/mbx-info'] = {
    $mb = Test-MbxId $d.mailbox 'mailbox (email address or username)'
    $id = New-MbxJob ([ordered]@{ Action = 'MbxInfo'; Mailbox = $mb }) "Look up $mb"
    Send $ctx @{ ok = $true; id = $id }
}

# ENDPOINT /api/mbx-change - changes a mailbox. Input: $d.mailbox, $d.convert ('' / Shared / Regular), $d.grantUsers[] with $d.fullAccess / $d.autoMap /
# $d.sendAs / $d.sendOnBehalf, $d.remove[] (user + the rights to take away), $d.block, $d.unblock (sign-in of the Entra account).
# Builds one 'MbxChange' job for the worker. Returns { ok, id, summary }; poll /api/mbx-result.
$ScreenHandlers['/api/mbx-change'] = {
    $mb = Test-MbxId $d.mailbox 'mailbox'
    # Only these three values are allowed (nothing = do not convert).
    $conv = "$($d.convert)"; if ($conv -notin '', 'Shared', 'Regular') { throw 'Unknown conversion.' }
    $grant = @(); $seen = @{}
    # People who get access: skip blanks and duplicates (case-insensitive), validate each, and require at least one kind of access.
    foreach ($u in @($d.grantUsers)) {
        $v = "$u".Trim(); if (-not $v -or $seen[$v.ToLower()]) { continue }; $seen[$v.ToLower()] = 1
        $v = Test-MbxId $v 'person'
        if (-not ($d.fullAccess -or $d.sendAs -or $d.sendOnBehalf)) { throw 'Choose what the people get: Full Access, Send As and / or Send on behalf.' }
        $grant += [ordered]@{ user = $v; fullAccess = [bool]$d.fullAccess; autoMap = [bool]$d.autoMap; sendAs = [bool]$d.sendAs; sendOnBehalf = [bool]$d.sendOnBehalf }
    }
    if ($grant.Count -gt 50) { throw 'Up to 50 people at a time.' }
    $remove = @()
    # People who lose access: skip rows where no right is ticked.
    foreach ($r in @($d.remove)) {
        if (-not $r -or -not ($r.fullAccess -or $r.sendAs -or $r.sendOnBehalf)) { continue }
        $remove += [ordered]@{ user = (Test-MbxId $r.user 'person'); fullAccess = [bool]$r.fullAccess; sendAs = [bool]$r.sendAs; sendOnBehalf = [bool]$r.sendOnBehalf }
    }
    if (-not $conv -and -not $grant.Count -and -not $remove.Count -and -not $d.block -and -not $d.unblock) { throw 'Nothing to change - tick Convert, add people or tick access to remove.' }
    # Build the short text shown to the admin (e.g. 'convert to shared, give access to 2'). Unblock is only honoured together with a convert to Regular.
    $parts = @()
    if ($conv -eq 'Shared') { $parts += 'convert to shared' } elseif ($conv -eq 'Regular') { $parts += 'convert to user mailbox' }
    if ($grant.Count) { $parts += "give access to $($grant.Count)" }
    if ($remove.Count) { $parts += "remove access of $($remove.Count)" }
    if ($d.block) { $parts += 'block sign-in' }
    if ($d.unblock) { $parts += 'allow sign-in' }
    $job = [ordered]@{ Action = 'MbxChange'; Mailbox = $mb; Convert = $conv; Grant = $grant; Remove = $remove; Block = [bool]$d.block; Unblock = [bool]($d.unblock -and $conv -eq 'Regular') }
    $id = New-MbxJob $job ("$mb - " + ($parts -join ', '))
    Send $ctx @{ ok = $true; id = $id; summary = $script:MbxJobs[$id].summary }
}

# Reads the Entra account of the mailbox from Microsoft Graph. $info = the 'info' part of the worker result (entraId or upn).
# Returns found / enabled / synced / licenses / note. Never throws: problems are put in 'note'.
# Entra details of the mailbox's account: sign-in allowed, synced from AD, licenses (a shared mailbox up to 50 GB needs none)
function Get-MbxEntra($info) {
    $o = [ordered]@{ found = $false; enabled = $null; synced = $false; licenses = @(); note = '' }
    $key = if ($info.entraId) { $info.entraId } else { $info.upn }
    if (-not $key) { return $o }
    try {
        $u = Get-MgUser -UserId $key -Property Id, AccountEnabled, OnPremisesSyncEnabled -ErrorAction Stop
        $o.found = $true; $o.enabled = [bool]$u.AccountEnabled; $o.synced = [bool]$u.OnPremisesSyncEnabled
        try { $o.licenses = @(Get-MgUserLicenseDetail -UserId $u.Id -ErrorAction Stop | ForEach-Object { "$($_.SkuPartNumber)" }) } catch { $o.note = 'Licenses could not be read.' }
    } catch { $o.note = "Entra account not read: $($_.Exception.Message)" }
    $o
}

# ENDPOINT /api/mbx-result - polled by the page every few seconds. Input: $d.id (job id from mbx-info / mbx-change / gal-cloud).
# Reads the worker's result file and, once the job is finished, does the Entra part ONCE (block / allow sign-in, read licenses)
# and writes the activity log rows ONCE. Returns { state, summary, result, entra, block, unblock, log (last 200 lines), worker }.
$ScreenHandlers['/api/mbx-result'] = {
    $j = $script:MbxJobs["$($d.id)"]
    if (-not $j) { throw 'That job is not known to this server (it may be from before a restart).' }
    # Job state from the worker (Queued / Running / Finished / Failed...). A result file that already exists means the work is Done.
    $state = Get-DgJobState $j
    $resFile = Join-Path $j.logFolder ("Result_$($j.id).json")
    $res = $null
    if (Test-Path $resFile) { try { $res = Get-Content $resFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    if ($res -and $state -in 'Running', 'Queued', 'Finished') { $state = 'Done' }
    # Runs only once per job: $j.extra is empty until the follow-up work has been done and then keeps its answers.
    if ($state -in 'Done', 'Failed', 'Finished' -and -not $j.extra) {
        $j.extra = @{ entra = $null; block = $null; unblock = $null }
        if ($res -and $res.info) {
            # Block sign-in of the Entra account. Skipped (with a message) when the account is not found, the conversion failed, the account is synced
            # from on-premises AD (it must be disabled in AD), or is already blocked.
            # block sign-in after converting (only when the conversion did not fail)
            $convFailed = @($res.steps | Where-Object { $_.step -like 'Convert*' -and -not $_.ok }).Count
            if ($j.block) {
                $e0 = Get-MbxEntra $res.info
                if (-not $e0.found) { $j.extra.block = @{ ok = $false; message = 'The Entra account was not found, so sign-in was not blocked.' } }
                elseif ($convFailed) { $j.extra.block = @{ ok = $false; message = 'Not blocked, because the conversion failed.' } }
                elseif ($e0.synced) { $j.extra.block = @{ ok = $false; message = 'The account is synced from on-premises AD - disable it there (On-premises AD screen).' } }
                elseif ($e0.enabled -eq $false) { $j.extra.block = @{ ok = $true; message = 'Sign-in was already blocked.' } }
                else {
                    try { Update-MgUser -UserId $res.info.entraId -AccountEnabled:$false -ErrorAction Stop; $j.extra.block = @{ ok = $true; message = 'Sign-in blocked - nobody can sign in as this user; the people with access still open the mailbox.' } }
                    catch { $j.extra.block = @{ ok = $false; message = "Could not block sign-in: $($_.Exception.Message)" } }
                }
            }
            # Same checks as above, in the other direction. The user then needs an Exchange Online license again.
            # allow sign-in again after converting back to a user mailbox (only when the conversion did not fail)
            if ($j.unblock) {
                $e1 = Get-MbxEntra $res.info
                if (-not $e1.found) { $j.extra.unblock = @{ ok = $false; message = 'The Entra account was not found, so sign-in was not changed.' } }
                elseif ($convFailed) { $j.extra.unblock = @{ ok = $false; message = 'Not changed, because the conversion failed.' } }
                elseif ($e1.synced) { $j.extra.unblock = @{ ok = $false; message = 'The account is synced from on-premises AD - enable it there (On-premises AD screen).' } }
                elseif ($e1.enabled -eq $true) { $j.extra.unblock = @{ ok = $true; message = 'Sign-in was already allowed.' } }
                else {
                    try { Update-MgUser -UserId $res.info.entraId -AccountEnabled:$true -ErrorAction Stop; $j.extra.unblock = @{ ok = $true; message = 'Sign-in allowed - the user can sign in again (the account needs an Exchange Online license).' } }
                    catch { $j.extra.unblock = @{ ok = $false; message = "Could not allow sign-in: $($_.Exception.Message)" } }
                }
            }
            $j.extra.entra = Get-MbxEntra $res.info
        }
        # Write the activity log. 'MbxHide' jobs belong to the Address list screen, 'MbxChange' jobs to this screen.
        # activity log: one row per step, written once when the job ends
        if (-not $j.logged -and (Get-Command Write-ActRow -ErrorAction SilentlyContinue)) {
            $j.logged = $true
            if ($j.action -eq 'MbxHide' -and $res) { foreach ($s in @($res.steps)) { Write-ActRow 'Address list' "$($s.step) (Exchange Online)" "$($s.target)" $(if ($s.ok) { "Done - $($s.message)" } else { "Failed: $($s.message)" }) '' } }
            if ($j.action -eq 'MbxChange') {
                if ($res) {
                    foreach ($s in @($res.steps)) { Write-ActRow 'Shared mailbox' "$($s.step)" ("$($j.mailbox)" + $(if ("$($s.target)" -ine "$($j.mailbox)" -and "$($s.target)" -ine "$($res.info.email)") { " -> $($s.target)" } else { '' })) $(if ($s.ok) { 'Done' + $(if ($s.message) { " - $($s.message)" } else { '' }) } else { "Failed: $($s.message)" }) '' }
                    if ($res.error) { Write-ActRow 'Shared mailbox' 'Change mailbox' "$($j.mailbox)" "Failed: $($res.error)" '' }
                } else { Write-ActRow 'Shared mailbox' 'Change mailbox' "$($j.mailbox)" "Failed: the job ended without a result ($state)" '' }
                if ($j.extra.unblock) { Write-ActRow 'Shared mailbox' 'Allow sign-in' "$($j.mailbox)" $(if ($j.extra.unblock.ok) { "Done - $($j.extra.unblock.message)" } else { "Failed: $($j.extra.unblock.message)" }) '' }
                if ($j.extra.block) { Write-ActRow 'Shared mailbox' 'Block sign-in' "$($j.mailbox)" $(if ($j.extra.block.ok) { "Done - $($j.extra.block.message)" } else { "Failed: $($j.extra.block.message)" }) '' }
            }
        }
    }
    $log = ''
    # Send the last 200 lines of the worker's log so the page can show progress.
    $lf = Join-Path $j.logFolder ("FullRunLog_$($j.id).log")
    if (Test-Path $lf) { $log = (@(Get-Content -Path $lf -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n") }
    Send $ctx @{ ok = $true; id = $j.id; state = $state; action = $j.action; summary = $j.summary; result = $res; entra = $(if ($j.extra) { $j.extra.entra }); block = $(if ($j.extra) { $j.extra.block }); unblock = $(if ($j.extra) { $j.extra.unblock }); log = $log; worker = (Get-DgWorker) }
}

# ENDPOINT /api/mbx-people - Input: $d.q (at least 2 characters). Returns { people[] } with name, email, upn, enabled, title, guest.
# Type-ahead search for people (Give access to / Find the mailbox): Microsoft Graph, so it is instant and does not wait for Exchange.
# Searches the start of the name, email, UPN or username; up to 12 results.
$ScreenHandlers['/api/mbx-people'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections, or the M365 / AD button at the top right).' }
    # Remove quotes, backslashes and control characters (they would break the $search expression), and limit to 64 characters.
    $q = ("$($d.q)" -replace '["\\\x00-\x1f]', '').Trim()
    if ($q.Length -lt 2) { Send $ctx @{ ok = $true; people = @() }; return }
    if ($q.Length -gt 64) { $q = $q.Substring(0, 64) }
    $props = 'Id', 'DisplayName', 'Mail', 'UserPrincipalName', 'AccountEnabled', 'JobTitle', 'Department', 'UserType'
    $term = $q -replace '@.*$', ''   # "ali@contoso" -> search "ali" in every field, then keep the ones that match the whole text
    # Graph $search syntax: match the start of any of these fields. Needs ConsistencyLevel=eventual (see the call below).
    $search = '"displayName:{0}" OR "mail:{0}" OR "userPrincipalName:{0}" OR "givenName:{0}" OR "surname:{0}"' -f $term
    $list = @()
    try { $list = @(Get-MgUser -Search $search -ConsistencyLevel eventual -CountVariable n -Property $props -Top 25 -ErrorAction Stop) }
    catch { throw "Search failed: $($_.Exception.Message)" }
    # If the admin typed a full address, keep only users whose mail or UPN really starts with it.
    if ($q -match '@') { $list = @($list | Where-Object { "$($_.Mail)" -like "$q*" -or "$($_.UserPrincipalName)" -like "$q*" }) }
    $out = @($list | Select-Object -First 12 | ForEach-Object {
        [pscustomobject]@{ name = "$($_.DisplayName)"; email = $(if ($_.Mail) { "$($_.Mail)" } else { "$($_.UserPrincipalName)" }); upn = "$($_.UserPrincipalName)"
            enabled = [bool]$_.AccountEnabled; title = (@("$($_.JobTitle)", "$($_.Department)") | Where-Object { $_ }) -join ' - '; guest = ("$($_.UserType)" -eq 'Guest') }
    })
    Send $ctx @{ ok = $true; people = $out }
}

# (see the note above) The next function builds the HTML of that e-mail.
# ---- e-mail the people: how to open and use the shared mailbox (or that it is a normal mailbox again) - ONE e-mail per person.
# Sent from a sender mailbox you choose (never from your own account), like the password and guest e-mails. English first, Arabic below.
# Builds the HTML body of the notification e-mail. $kind = 'shared' (how to open the mailbox) or 'regular' (it is a normal mailbox again),
# $first/$name/$addr = person's first name, mailbox name and address, $rights = this person's access, $msg = optional own text (HTML-encoded),
# $sig = signature, $cfg = mail settings, $names = name parts. English text first, then the Arabic version (right-to-left). Returns HTML.
function New-MbxMailHtmlRaw($kind, $first, $name, $addr, $rights, $msg, $sig, $cfg, $names = $null) {
    # The wording comes from the Email messages screen; the layout, your own message and the list of the person's access are built here.
    # Small helper: HTML-encode text so a typed message cannot inject markup.
    $h = { param($t) [Net.WebUtility]::HtmlEncode("$t") }
    $id = if ($kind -eq 'regular') { 'mbxRegular' } else { 'mbxShared' }
    if (-not $names) { $names = Get-EmailNames $id $first '' $first }
    # Values that can be placed in the wording (placeholders such as the first name, address and the self-service links).
    $v = @{ first = $names.first; last = $names.last; full = $names.full; greet = $names.greet; name = "$name"; addr = "$addr"; sspr = "$($cfg.ssprUrl)"; mfa = "$($cfg.mfaUrl)" }
    $custom = ''
    if ("$msg".Trim()) { $custom = '<div style="margin:14px 0;padding:12px 16px;background:#f1f5f9;border-left:4px solid #2563eb;border-radius:6px;white-space:pre-wrap">' + (& $h "$msg".Trim()) + '</div>' }
    $liE = 'margin:6px 0'
    # Style strings reused below: right-to-left block for Arabic, and list styles that put the indent on the correct side for each language.
    $rtlOpen = '<div dir="rtl" lang="ar" style="font-family:Segoe UI,Tahoma,Arial,sans-serif;font-size:15px;color:#1f2937;line-height:1.7;text-align:right;border-top:2px solid #e5e7eb;margin-top:24px;padding-top:14px">'
    $ulE = '<ul style="margin:0 0 0 18px;padding:0">'; $ulA = '<ul style="margin:0 18px 0 0;padding:0">'
    $ttl = '<p style="margin-bottom:4px"><b>'
    $en = ''; $ar = ''
    if ($kind -eq 'regular') {
        $raw = @{}
        $en = "<p>$(Get-EmailPart $id 'hello' 'en' $v $raw)</p><p>$(Get-EmailPart $id 'intro' 'en' $v $raw)</p>$custom" +
              "$ttl$(Get-EmailPart $id 'signTitle' 'en' $v $raw)</b></p>$ulE" + (Get-EmailItems $id 'signList' 'en' $v $raw $liE) + '</ul>'
        $ar = "<p>$(Get-EmailPart $id 'hello' 'ar' $v $raw)</p><p>$(Get-EmailPart $id 'intro' 'ar' $v $raw)</p>" +
              "$ttl$(Get-EmailPart $id 'signTitle' 'ar' $v $raw)</b></p>$ulA" + (Get-EmailItems $id 'signList' 'ar' $v $raw $liE) + '</ul>'
    } else {
        $auto = Get-EmailPart $id $(if ($rights.fullAccess -and $rights.autoMap) { 'autoYes' } else { 'autoNo' }) 'en' $v @{}
        $raw = @{ auto = $auto }
        $rk = @(); if ($rights.fullAccess) { $rk += 'rFull' }; if ($rights.sendAs) { $rk += 'rSendAs' }; if ($rights.sendOnBehalf) { $rk += 'rBehalf' }
        $rEn = ''; $rAr = ''
        if ($rk.Count) {
            $rEn = "$ttl$(Get-EmailPart $id 'rightsTitle' 'en' $v $raw)</b></p>$ulE" + (($rk | ForEach-Object { "<li style=""$liE"">$(Get-EmailPart $id $_ 'en' $v $raw)</li>" }) -join '') + '</ul>'
            $rAr = "$ttl$(Get-EmailPart $id 'rightsTitle' 'ar' $v $raw)</b></p>$ulA" + (($rk | ForEach-Object { "<li style=""$liE"">$(Get-EmailPart $id $_ 'ar' $v $raw)</li>" }) -join '') + '</ul>'
        }
        $en = "<p>$(Get-EmailPart $id 'hello' 'en' $v $raw)</p><p>$(Get-EmailPart $id 'intro' 'en' $v $raw)</p>$custom$rEn" +
              "$ttl$(Get-EmailPart $id 'openTitle' 'en' $v $raw)</b></p><ol style=""margin:0 0 0 18px;padding:0"">" + (Get-EmailItems $id 'open' 'en' $v $raw $liE) + '</ol>' +
              "$ttl$(Get-EmailPart $id 'howTitle' 'en' $v $raw)</b></p>$ulE" + (Get-EmailItems $id 'how' 'en' $v $raw $liE) + '</ul>'
        $ar = "<p>$(Get-EmailPart $id 'hello' 'ar' $v $raw)</p><p>$(Get-EmailPart $id 'intro' 'ar' $v $raw)</p>$rAr" +
              "$ttl$(Get-EmailPart $id 'openTitle' 'ar' $v $raw)</b></p><ol style=""margin:0 18px 0 0;padding:0"">" + (Get-EmailItems $id 'open' 'ar' $v $raw $liE) + '</ol>' +
              "$ttl$(Get-EmailPart $id 'howTitle' 'ar' $v $raw)</b></p>$ulA" + (Get-EmailItems $id 'how' 'ar' $v $raw $liE) + '</ul>'
    }
    # Glue it together: English part + signature, then the Arabic part + signature.
    $sg = & $h $sig
    '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937;line-height:1.55;max-width:640px">' + $en + (Get-EmailSigHtml $sig) + $rtlOpen + $ar + (Get-EmailSigHtml $sig -Rtl) + "</div></div>"
}

# ENDPOINT /api/mbx-notify - sends one e-mail per person. Input: $d.kind (shared / regular), $d.mailbox, $d.mailboxName, $d.message (max 2000),
# $d.sender (mailbox to send from; never the admin's own account), $d.subject, $d.recipients[] (email, name, rights).
# Returns { ok, sender, results[] } with a status per person (Sent / Failed / Invalid). Max 50 people. Every mail is written to the mail log.
$ScreenHandlers['/api/mbx-notify'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections, or the M365 / AD button at the top right).' }
    $kind = if ("$($d.kind)" -eq 'regular') { 'regular' } else { 'shared' }
    $mb = Test-MbxId $d.mailbox 'mailbox'
    $mbName = "$($d.mailboxName)".Trim(); if (-not $mbName) { $mbName = $mb }
    $msg = "$($d.message)".Trim(); if ($msg.Length -gt 2000) { throw 'The message is too long (up to 2000 characters).' }
    $c = Get-MailCfg
    $snd = "$($d.sender)".Trim(); if (-not $snd) { $snd = "$($c.sender)".Trim() }
    if (-not (Test-MailAddr $snd)) { throw 'Type the sender: the mailbox the e-mails are sent from (for example it-noreply@contoso.com).' }
    if (Test-OwnAddr $snd) { throw 'The sender cannot be your own account. Type another (shared or service) mailbox.' }
    # Remember the chosen sender (and keep a list of the last 10) in the mail settings file for next time. A failed save is ignored.
    if ($snd -ine "$($c.sender)" -or -not (@($c.senders) -contains $snd)) {
        $c.sender = $snd; $c.senders = @(@($snd) + @($c.senders | Where-Object { "$_" -and "$_" -ine $snd }) | Select-Object -First 10)
        try { ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8 } catch {}
    }
    $subject = "$($d.subject)".Trim()
    if (-not $subject) { $subject = (Get-EmailSubject $(if ($kind -eq 'regular') { 'mbxRegular' } else { 'mbxShared' })).Replace('{mailbox}', $mb) }
    $list = @(); $seen = @{}
    # Clean the recipient list: remove spaces, lower-case, skip blanks and duplicates.
    foreach ($r in @($d.recipients)) {
        $em = ("$($r.email)" -replace '\s', '').Trim().ToLower(); if (-not $em -or $seen[$em]) { continue }; $seen[$em] = 1
        $list += [pscustomobject]@{ email = $em; name = "$($r.name)".Trim(); rights = $r.rights }
    }
    if (-not $list.Count) { throw 'Choose at least one person to e-mail.' }
    if ($list.Count -gt 50) { throw 'Up to 50 people at a time.' }
    $res = New-Object System.Collections.ArrayList
    # Send to each person on their own, so one bad address does not stop the rest.
    foreach ($p in $list) {
        $r = [ordered]@{ email = $p.email; name = $p.name; status = ''; message = '' }
        try {
            if (-not (Test-MailAddr $p.email)) { $r.status = 'Invalid'; throw 'Not a valid email address' }
            # First name for the greeting: first word of the name; if no name was given, guess it from the e-mail (ali.khan@ -> Ali).
            $first = if ($p.name) { ($p.name -split '\s+')[0] } else { $lp = (($p.email -split '@')[0] -split '[._-]')[0]; if ($lp.Length -gt 1) { $lp.Substring(0, 1).ToUpper() + $lp.Substring(1) } else { $lp } }
            # If no rights were passed, assume Full Access with automapping.
            $rt = if ($p.rights) { $p.rights } else { [pscustomobject]@{ fullAccess = $true; autoMap = $true; sendAs = $false; sendOnBehalf = $false } }
            # the person's name comes from THEIR account in your tenant (not from the mailbox, and not typed by hand)
            $eid = if ($kind -eq 'regular') { 'mbxRegular' } else { 'mbxShared' }
            $tn = Get-EmailTenantName $p.email
            $nms = if ($tn -and ($tn.given -or $tn.sn -or $tn.disp)) { Get-EmailNames $eid $tn.given $tn.sn $tn.disp } else { Get-EmailNames $eid '' '' $(if ($p.name) { $p.name } else { $first }) }
            if ($nms.first) { $first = $nms.first }
            $html = New-MbxMailHtml $kind $first $mbName $mb $rt $msg "$($c.signature)" $c $nms
            # Microsoft Graph sendMail request body (HTML mail; saveToSentItems follows the mail setting).
            $body = @{ message = @{ subject = $subject; body = @{ contentType = 'HTML'; content = $html }; toRecipients = @(@{ emailAddress = @{ address = $p.email } }); importance = 'normal' }; saveToSentItems = [bool]$c.saveCopy }
            $att = @(Get-EmailAttach $(if ($kind -eq 'regular') { 'mbxRegular' } else { 'mbxShared' })); if ($att.Count) { $body.message.attachments = $att }
            $snd = Send-ToolMail $snd $body
            $r.status = 'Sent'; $r.message = "Sent from $snd"
            Write-MailLog $mb $snd $p.email "Sent (shared mailbox: $kind)"
        } catch {
            $m = Get-MailErr $_.Exception.Message; if (-not $r.status) { $r.status = 'Failed' }; $r.message = $m
            Write-MailLog $mb $snd $p.email "Failed (shared mailbox: $kind): $m"
        }
        [void]$res.Add([pscustomobject]$r)
        # Short pause between mails to stay below the Graph sending limits.
        Start-Sleep -Milliseconds 250
    }
    Send $ctx @{ ok = $true; sender = $snd; results = $res }
}

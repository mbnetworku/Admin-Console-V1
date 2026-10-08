# Screen-AuditLogs.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Audit & event logs
# Screen version: 2.8.1   (changes ONLY when this screen changes - not with every release)

#   cloud (Microsoft 365 / Entra ID):  Microsoft Graph  auditLogs/directoryAudits (who changed what)  and  auditLogs/signIns (who signed in)
#   ad    (on-premises Active Directory): Windows event logs of a domain controller (Security log: account created / changed / password
#          reset / locked out / group changes / failed logons, plus the Directory Service and System logs), read with the AD account
#          you signed in with on the On-premises AD screen.

# Audit & event logs screen - endpoints: /api/audit-cloud (start a Microsoft 365 / Entra log search), /api/audit-ad (start a domain controller
# event-log search), /api/audit-job (poll a running search), /api/audit-cancel (stop it), /api/audit-ad-events (list of known AD event ids).
# Searches run in a background PowerShell thread (see Start-AuditJob) so the tool stays usable; the page asks for the state every second.
# Cloud needs the Microsoft sign-in with the AuditLog.Read.All permission (and an Entra admin role that may read logs).
# AD needs the on-premises AD sign-in ($script:AdCred) and rights to read the event log of the domain controller. Nothing is saved to disk.
#
# Most rows one search may return (also the cap for the 'max' value sent by the page).
$global:AuditMaxRows = 2000
# the basic sign-in fields - used when 'MFA and Conditional Access details' is switched off (the full record is large and slower to download)
$global:SignInSelect = 'id,createdDateTime,userPrincipalName,userDisplayName,appDisplayName,ipAddress,clientAppUsed,conditionalAccessStatus,riskLevelDuringSignIn,status,location,deviceDetail'

# Returns the value as text; null becomes an empty string (so the page never shows 'null').
function Get-AuditStr($v) { if ($null -eq $v) { '' } else { "$v" } }

# Stops with a clear message if nobody is signed in to Microsoft, or if the token lacks the AuditLog.Read.All permission.
function Test-AuditReady {
    if (-not $script:Who) { throw 'Not connected. Sign in to Microsoft first.' }
    $sc = @(Get-MsScopes)
    if ($sc.Count -and ($sc -notcontains 'AuditLog.Read.All')) {
        throw 'This screen needs the AuditLog.Read.All permission. Sign out of Microsoft, connect again and approve it (an administrator may have to approve it once for your organization).'
    }
}

# Reads a Graph list page by page (follows @odata.nextLink). Inputs: $uri first URL, $max rows wanted. Returns a list of raw records.
# Safety stops: enough rows, or 60 pages. A comma before $rows stops PowerShell from unrolling the list.
function Get-AuditPages($uri, $max) {
    $rows = New-Object Collections.Generic.List[object]; $pages = 0
    while ($uri -and $rows.Count -lt $max -and $pages -lt 60) {
        # v2.0.0: a background log search uses ITS OWN token (several people are signed in; the shared Graph connection may change meanwhile)
        # Background thread: call Graph with the token that was handed to this job. Main thread: use the shared Graph connection.
        $r = if ($global:AuTok) { $u2 = $(if ($uri -match '^https://') { $uri } else { 'https://graph.microsoft.com/' + "$uri".TrimStart('/') }); Invoke-RestMethod -Method GET -Uri $u2 -Headers @{ Authorization = "Bearer $($global:AuTok)"; ConsistencyLevel = 'eventual' } -ErrorAction Stop }
             else { Invoke-MgGraphRequest -Method GET -Uri $uri }
        foreach ($x in @($r.value)) { $rows.Add($x) }
        $uri = $r.'@odata.nextLink'; $pages++
    }
    , $rows
}

# Turns one directoryAudits record (who changed what) into a flat row for the page.
# Actor = user UPN, else name, else the app; targets = affected objects; changes = 'property: old -> new' (values cut at 80 characters).
function Convert-DirAudit($a) {
    $actor = ''
    if ($a.initiatedBy.user.userPrincipalName) { $actor = "$($a.initiatedBy.user.userPrincipalName)" }
    elseif ($a.initiatedBy.user.displayName) { $actor = "$($a.initiatedBy.user.displayName)" }
    elseif ($a.initiatedBy.app.displayName) { $actor = "$($a.initiatedBy.app.displayName) (app)" }
    $tg = @(); $chg = @()
    foreach ($t in @($a.targetResources)) {
        $n = if ($t.userPrincipalName) { $t.userPrincipalName } elseif ($t.displayName) { $t.displayName } else { $t.id }
        if ($n) { $tg += "$n" }
        foreach ($m in @($t.modifiedProperties)) {
            if (-not $m.displayName) { continue }
            # Graph gives old/new values as JSON text like ["abc"]; remove line breaks and the brackets/quotes so they read normally.
            $o = ("$($m.oldValue)" -replace '[\r\n]+', ' ').Trim('[', ']', '"', ' '); $nw = ("$($m.newValue)" -replace '[\r\n]+', ' ').Trim('[', ']', '"', ' ')
            if ($o.Length -gt 80) { $o = $o.Substring(0, 80) + '...' }; if ($nw.Length -gt 80) { $nw = $nw.Substring(0, 80) + '...' }
            $chg += $(if ($o) { "$($m.displayName): $o -> $nw" } else { "$($m.displayName): $nw" })
        }
    }
    [ordered]@{
        time = Get-AuditStr $a.activityDateTime; category = Get-AuditStr $a.category; activity = Get-AuditStr $a.activityDisplayName
        result = Get-AuditStr $a.result; reason = Get-AuditStr $a.resultReason; actor = $actor; target = ($tg -join '; ')
        changes = ($chg -join ' | '); service = Get-AuditStr $a.loggedByService; ip = Get-AuditStr $a.initiatedBy.user.ipAddress; id = Get-AuditStr $a.id
    }
}

# Get-SignInReason - input: the Entra sign-in error code. Returns an easy sentence, or '' for success / unknown codes (0 = success).
# plain-language reason for a Microsoft Entra sign-in error code (the code alone is hard to read)
function Get-SignInReason($code) {
    switch ("$code") {
        '0' { '' }
        '50126' { 'Wrong username or password' }
        '50053' { 'Account locked - too many wrong passwords (smart lockout)' }
        '50057' { 'Account is disabled' }
        '50055' { 'The password has expired' }
        '50034' { 'The username does not exist in this directory' }
        '50058' { 'Silent sign-in failed - the user has to sign in again' }
        '50072' { 'The user has to register for multifactor authentication (MFA)' }
        '50074' { 'MFA was required and was not completed' }
        '50076' { 'MFA required by policy and not completed' }
        '50079' { 'The user has to register security info (MFA) first' }
        '50097' { 'Device authentication is required' }
        '50105' { 'The user is not assigned to this application' }
        '50132' { 'Session ended because the password changed or the user was signed out everywhere' }
        '50133' { 'Session expired because the password changed' }
        '50144' { 'The on-premises Active Directory password has expired' }
        '50158' { 'An external security challenge was not satisfied' }
        '50173' { 'The sign-in token expired - the user must sign in again' }
        '500121' { 'MFA failed (denied, timed out or wrong code)' }
        '53000' { 'Blocked by Conditional Access - the device is not compliant' }
        '53001' { 'Blocked by Conditional Access - the device is not domain joined' }
        '53002' { 'Blocked by Conditional Access - the application is not approved' }
        '53003' { 'Blocked by Conditional Access' }
        '53004' { 'Blocked - the user must complete security info registration' }
        '530032' { 'Blocked by a security policy of the organization' }
        '65001' { 'The user or an administrator has not agreed to let the app in (consent)' }
        '70043' { 'The sign-in session expired from inactivity' }
        '700082' { 'The refresh token expired from inactivity' }
        '90072' { 'The user comes from another organization and has to sign in there' }
        default { '' }
    }
}

# Turns one signIns record into a flat row: result, plain reason, place, MFA status and method, Conditional Access policies, device, risk.
# Input $s = raw Graph sign-in. The full record (MFA/CA details) is only present when the search was started with 'full' on.
function Get-SignInInfo($s) {
    # everything about one sign-in, in words: result, why it failed, IP, place, MFA, method, Conditional Access
    $loc = @($s.location.city, $s.location.state, $s.location.countryOrRegion | Where-Object { $_ } | Select-Object -Unique) -join ', '
    $ec = "$($s.status.errorCode)"
    $ok = ($ec -eq '0')
    $why = ''
    if (-not $ok) {
        $fr = "$($s.status.failureReason)"; $fx = Get-SignInReason $ec; $ad = "$($s.status.additionalDetails)"
        $why = if ($fx) { $fx } else { $fr }
        if ($fx -and $fr -and $fr -ne $fx) { $why += " (Microsoft: $fr)" }
        if ($ad -and $ad -ne $fr -and $ad -ne 'MFA required in Azure AD') { $why += " - $ad" }
    }
    # MFA and method used
    $req = "$($s.authenticationRequirement)"
    # authenticationRequirement says whether the sign-in needed one or several factors.
    $mfa = if ($req -match 'multi') { 'MFA required' } elseif ($req -match 'single') { 'No MFA (one factor)' } else { '' }
    $steps = @(); $used = @()
    foreach ($a in @($s.authenticationDetails)) {
        if (-not $a -or -not $a.authenticationMethod) { continue }
        $okS = ($a.succeeded -eq $true)
        $det = "$($a.authenticationStepResultDetail)"
        $steps += ("$($a.authenticationMethod)" + $(if ($det) { " - $det" } else { '' }) + $(if ($okS) { ' (OK)' } else { ' (FAILED)' }))
        if ($okS -and "$($a.authenticationMethod)" -notmatch '^Previously satisfied$') { $used += "$($a.authenticationMethod)" }
    }
    if ($mfa -eq 'MFA required') {
        # (kept for information) true when a step text shows MFA was done.
        $mfaDone = ($steps -join ' ') -match 'MFA completed|MFA requirement satisfied|satisfied by claim'
        if ($ok) { $mfa = 'MFA required and completed' } elseif ($steps -match 'FAILED') { $mfa = 'MFA required - not completed' }
    }
    # Conditional Access
    $blk = @(); $pol = @()
    foreach ($c in @($s.appliedConditionalAccessPolicies)) {
        if (-not $c -or -not $c.displayName) { continue }
        # Only policies that really applied are listed; 'failure' means that policy blocked the sign-in.
        $res = "$($c.result)"; if ($res -eq 'notApplied' -or $res -eq 'notEnabled') { continue }
        $gc = @($c.enforcedGrantControls | Where-Object { $_ }) -join ' + '
        $pol += "$($c.displayName): $res" + $(if ($gc) { " [$gc]" } else { '' })
        if ($res -eq 'failure') { $blk += "$($c.displayName)" + $(if ($gc) { " [$gc]" } else { '' }) }
    }
    $caBlk = $blk -join '; '
    # Error codes 53000-530032 mean Conditional Access blocked it, even if the policy name is not in the record.
    if (-not $ok -and -not $caBlk -and $ec -in '53000', '53001', '53002', '53003', '530032') { $caBlk = 'Conditional Access blocked it (the policy name is not shown for this sign-in)' }
    # Device state words: Compliant / Managed / join type.
    $dev = @(); $dd = $s.deviceDetail
    if ($dd) {
        if ($dd.isCompliant -eq $true) { $dev += 'Compliant' } elseif ($dd.isCompliant -eq $false) { $dev += 'Not compliant' }
        if ($dd.isManaged -eq $true) { $dev += 'Managed' } elseif ($dd.isManaged -eq $false) { $dev += 'Not managed' }
        if ($dd.trustType) { $dev += "$($dd.trustType)" }
    }
    [ordered]@{
        time = Get-AuditStr $s.createdDateTime; user = Get-AuditStr $s.userPrincipalName; name = Get-AuditStr $s.userDisplayName
        app = Get-AuditStr $s.appDisplayName; resource = Get-AuditStr $s.resourceDisplayName
        result = $(if ($ok) { 'Success' } else { 'Failure' }); errorCode = $ec; reason = $why
        ip = Get-AuditStr $s.ipAddress; location = $loc
        mfa = $mfa; methods = ($used -join ', '); steps = ($steps -join ' | ')
        caBlocked = $caBlk; caPolicies = ($pol -join ' | '); caStatus = Get-AuditStr $s.conditionalAccessStatus
        client = Get-AuditStr $s.clientAppUsed; device = Get-AuditStr $s.deviceDetail.displayName; deviceState = ($dev -join ', ')
        os = Get-AuditStr $s.deviceDetail.operatingSystem; browser = Get-AuditStr $s.deviceDetail.browser
        interactive = $(if ($null -eq $s.isInteractive) { '' } elseif ($s.isInteractive) { 'Interactive' } else { 'Non-interactive' })
        risk = (@($s.riskLevelDuringSignIn, $s.riskLevelAggregated | Where-Object { $_ -and $_ -ne 'none' -and $_ -ne 'hidden' } | Select-Object -Unique) -join ', ')
        userId = Get-AuditStr $s.userId; correlationId = Get-AuditStr $s.correlationId; id = Get-AuditStr $s.id
    }
}

# Old name kept for compatibility - same as Get-SignInInfo.
function Convert-SignIn($s) { Get-SignInInfo $s }

# ---- background jobs: a log search can take minutes, so it runs in its own PowerShell thread. The tool stays free for every other screen
# (passwords, MFA, AD changes ...) and the search can be stopped. The screen starts a job, asks for its state every second and can cancel it.
# All running/finished searches, by job id.
$global:AuditJobs = @{}
# Names of the functions copied into the background thread (a new thread does not see the functions of this file).
$global:AuditFns = 'Get-AuditStr', 'Get-AuditPages', 'Convert-DirAudit', 'Get-SignInReason', 'Get-SignInInfo', 'Convert-SignIn', 'Get-LogonTypeText', 'Get-NtStatusText', 'Get-KerbText', 'Get-EvField', 'Convert-AdEvent', 'Get-ErrMsg'

# Returns the source text of a function so it can be pasted into the background thread's script.
function Get-AuditFnText($n) { "function $n {`n$((Get-Item "function:$n").ScriptBlock.ToString())`n}" }

# Starts a search in its own thread. Inputs: $action/$target/$detail (labels), $work (script block to run), $arg (hashtable passed as $p).
# Returns the job id. Old jobs (over 15 minutes) are stopped first; at most 4 searches may run at once.
function Start-AuditJob($action, $target, $detail, [scriptblock]$work, $arg) {
    $now = Get-Date
    foreach ($k in @($global:AuditJobs.Keys)) {
        $o = $global:AuditJobs[$k]
        if (($now - $o.started).TotalMinutes -gt 15) { try { [void]$o.ps.BeginStop($null, $null) } catch {}; $global:AuditJobs.Remove($k) }
    }
    if (@($global:AuditJobs.Values | Where-Object { -not $_.handle.IsCompleted }).Count -ge 4) { throw 'Four log searches are already running. Stop one of them first.' }
    # The thread loads the same Graph module version as the main program, and gets the signed-in person's token and the shared settings.
    $gm = Get-Module Microsoft.Graph.Authentication | Select-Object -First 1; $arg.GraphModVer = $(if ($gm) { "$($gm.Version)" } else { '' })
    if ($script:Who) { $arg.Token = Get-SessGraphToken }   # v2.0.0
    $arg.AdEvents = $global:AdEvents; $arg.SignInSelect = $global:SignInSelect; $arg.MaxRows = $global:AuditMaxRows
    $prelude = (@($global:AuditFns | ForEach-Object { Get-AuditFnText $_ }) -join "`n")
    # Script text for the thread: load Graph module, define the helper functions ($prelude), run the work block with $p.
    $text = "param(`$p)`nif (`$p.GraphModVer) { try { Import-Module Microsoft.Graph.Authentication -RequiredVersion `$p.GraphModVer -ErrorAction Stop } catch {} }`n$prelude`n`$global:AdEvents = `$p.AdEvents; `$global:SignInSelect = `$p.SignInSelect; `$global:AuditMaxRows = `$p.MaxRows; `$global:AuTok = `$p.Token`n& {`n" + $work.ToString() + "`n} `$p"
    $ps = [powershell]::Create()
    [void]$ps.AddScript($text).AddArgument($arg)
    $h = $ps.BeginInvoke()
    $id = [guid]::NewGuid().ToString('N')
    $global:AuditJobs[$id] = @{ ps = $ps; handle = $h; started = $now; action = $action; target = $target; detail = $detail }
    $id
}

# /api/audit-job - request: $d.id (job id). Returns { state = running, secs } while working; when finished the result rows { state = done, ... }.
# Errors found in the thread (Graph error, empty result) are thrown here so the page shows them.
$ScreenHandlers['/api/audit-job'] = {
    $j = $global:AuditJobs["$($d.id)"]
    if (-not $j) { throw 'This log search is no longer available (it was stopped or took too long). Search again.' }
    if (-not $j.handle.IsCompleted) { Send $ctx @{ ok = $true; state = 'running'; secs = [int]((Get-Date) - $j.started).TotalSeconds }; return }
    $res = $null; $err = ''
    try { $out = @($j.ps.EndInvoke($j.handle)); if ($out.Count) { $res = $out[$out.Count - 1] } } catch { $err = Get-ErrMsg $_ }
    if (-not $err -and $j.ps.Streams.Error.Count) { $err = "$($j.ps.Streams.Error[0])" }
    if (-not $err -and $res -and $res.error) { $err = "$($res.error)" }
    if (-not $err -and -not ($res -is [hashtable])) { $err = 'The log search returned nothing.' }
    try { $j.ps.Dispose() } catch {}
    $global:AuditJobs.Remove("$($d.id)")
    if ($err) { throw $err }   # v2.5.5: reading logs is not an action - not logged
    $res.state = 'done'
    Send $ctx $res
}

# /api/audit-cancel - request: $d.id. Asks the thread to stop and forgets the job. Always answers ok.
$ScreenHandlers['/api/audit-cancel'] = {
    $j = $global:AuditJobs["$($d.id)"]
    if ($j) {
        try { [void]$j.ps.BeginStop($null, $null) } catch {}
        $global:AuditJobs.Remove("$($d.id)")
        # v2.5.5: not logged (reading)
    }
    Send $ctx @{ ok = $true }
}

# Runs in the thread. $p = { uri, fetch (rows to read), max (rows to keep), text (filter), kind, days }.
# Reads the log, converts each record, applies the text filter, and returns { ok, rows, count, truncated, ... } or { error }.
# the work of a cloud search (runs in the background thread)
$global:AuditCloudWork = {
    param($p)
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { $raw = Get-AuditPages $p.uri $p.fetch }
        catch {
            $m = Get-ErrMsg $_
            # Permission problem: tell the operator which admin role is needed.
            if ($m -match 'Forbidden|Authorization_RequestDenied|403') { return @{ error = "Microsoft refused to show these logs: $m  (You need a role such as Reports Reader, Security Reader or Global Reader; sign-in logs also need Microsoft Entra ID P1 or P2.)" } }
            return @{ error = $m }
        }
        $rows = @(); $trunc = $false; $text = "$($p.text)"
        foreach ($x in $raw) {
            $r = if ($p.kind -eq 'directory') { Convert-DirAudit $x } else { Convert-SignIn $x }
            # Text filter: keep a row only if its text contains what was typed (lower case compare).
            if ($text) { if (-not (($r.Values -join ' ').ToLower().Contains($text))) { continue } }
            $rows += $r
            if ($rows.Count -ge $p.max) { $trunc = $true; break }
        }
        # Mark as 'truncated' when the log had at least as many rows as the limit (there may be more).
        if (-not $trunc -and $raw.Count -ge $p.max -and -not $text) { $trunc = $true }
        return @{ ok = $true; kind = $p.kind; days = $p.days; count = $rows.Count; truncated = $trunc; secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); fetched = $raw.Count; rows = $rows }
    } catch { return @{ error = (Get-ErrMsg $_) } }
}

# /api/audit-cloud - request: $d.kind (signins | directory), $d.days (1-30), $d.max, $d.text, $d.category, $d.failedOnly, $d.full.
# Builds the Graph URL with an OData filter and starts the background job. Returns { ok, job }.
$ScreenHandlers['/api/audit-cloud'] = {
    Test-AuditReady
    $kind = if ("$($d.kind)" -eq 'signins') { 'signins' } else { 'directory' }
    # Limits: 1-30 days (Entra keeps about 30 days of logs); default 7. Rows: default 500, never above AuditMaxRows.
    $days = [int]$d.days; if ($days -lt 1) { $days = 7 }; if ($days -gt 30) { $days = 30 }
    $max = [int]$d.max; if ($max -lt 10) { $max = 500 }; if ($max -gt $global:AuditMaxRows) { $max = $global:AuditMaxRows }
    $text = "$($d.text)".Trim().ToLower()
    # Start time in the UTC format Graph expects, for example 2026-01-31T08:00:00Z.
    $since = (Get-Date).ToUniversalTime().AddDays(-$days).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    if ($kind -eq 'directory') {
        $flt = "activityDateTime ge $since"
        $cat = "$($d.category)".Trim()
        # Category goes into the filter, so only letters are allowed (blocks filter injection).
        if ($cat -match '^[A-Za-z]+$') { $flt += " and category eq '$cat'" }
        if ($d.failedOnly) { $flt += " and result eq 'failure'" }
        $uri = 'https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$top=999&$filter=' + [uri]::EscapeDataString($flt) + '&$orderby=' + [uri]::EscapeDataString('activityDateTime desc')
    } else {
        $flt = "createdDateTime ge $since"
        # If the search text is a whole email address, let Graph filter by that user (fast) instead of filtering afterwards.
        if ($text -match '^[a-z0-9._%+''-]+@[a-z0-9.-]+$') { $flt += " and userPrincipalName eq '" + ($text -replace "'", "''") + "'"; $text = '' }
        if ($d.failedOnly) { $flt += ' and status/errorCode ne 0' }
        # full = MFA, authentication method and Conditional Access details (a bigger download); light = only the basic fields
        $full = if ($null -eq $d.full) { $true } else { [bool]$d.full }
        $uri = 'https://graph.microsoft.com/v1.0/auditLogs/signIns?$top=' + $(if ($full) { '500' } else { '999&$select=' + $global:SignInSelect }) + '&$filter=' + [uri]::EscapeDataString($flt)
    }
    # With a text filter we read more records than we show, because many will be filtered out.
    $fetch = if ($text) { $global:AuditMaxRows * 2 } else { $max }
    $arg = @{ uri = $uri; fetch = $fetch; max = $max; text = $text; kind = $kind; days = $days }
    $id = Start-AuditJob $(if ($kind -eq 'signins') { 'Read sign-in log' } else { 'Read cloud audit log' }) "$($d.text)" "kind=$kind; days=$days; max=$max$(if ($d.category) { '; category=' + $d.category })$(if ($d.failedOnly) { '; failures only' })" $global:AuditCloudWork $arg
    Send $ctx @{ ok = $true; job = $id }
}

# ---- on-premises AD: Windows event logs of a domain controller
# Windows Security event id -> plain description (accounts, groups, sign-ins, directory objects).
$global:AdEvents = [ordered]@{
    '4720' = 'User account created'; '4722' = 'User account enabled'; '4723' = 'Password change attempted (by the user)'; '4724' = 'Password reset (by an administrator)'
    '4725' = 'User account disabled'; '4726' = 'User account deleted'; '4738' = 'User account changed'; '4740' = 'Account locked out'; '4767' = 'Account unlocked'
    '4781' = 'Account name changed'; '4728' = 'Added to a global security group'; '4729' = 'Removed from a global security group'; '4732' = 'Added to a local security group'
    '4733' = 'Removed from a local security group'; '4756' = 'Added to a universal security group'; '4757' = 'Removed from a universal security group'
    '4727' = 'Security group created'; '4730' = 'Security group deleted'; '4731' = 'Local security group created'; '4734' = 'Local security group deleted'
    '4735' = 'Local security group changed'; '4737' = 'Global security group changed'; '4754' = 'Universal security group created'; '4758' = 'Universal security group deleted'
    '4625' = 'Failed sign-in'; '4624' = 'Successful sign-in'; '4648' = 'Sign-in with explicit credentials'; '4768' = 'Kerberos ticket requested (TGT)'; '4771' = 'Kerberos pre-authentication failed'
    '4776' = 'NTLM password check'; '4662' = 'Directory object accessed'; '5136' = 'Directory object changed'; '5137' = 'Directory object created'; '5141' = 'Directory object deleted'
}
# Ready-made groups of event ids that the page can choose from.
$global:AdEventSets = @{
    accounts = @('4720', '4722', '4723', '4724', '4725', '4726', '4738', '4740', '4767', '4781')
    groups   = @('4727', '4728', '4729', '4730', '4731', '4732', '4733', '4734', '4735', '4737', '4754', '4756', '4757', '4758')
    logons   = @('4624', '4625', '4648', '4768', '4771', '4776')
    objects  = @('5136', '5137', '5141')
}

# Reads one named field (for example TargetUserName) from the XML of a Windows event. Returns '' if missing.
function Get-EvField($xml, $name) {
    $n = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($n) { "$($n.'#text')" } else { '' }
}

# Logon type number of event 4624/4625 -> words.
function Get-LogonTypeText($t) {
    switch ("$t") {
        '2' { 'Interactive (at the keyboard)' } '3' { 'Network (shared folder, mapped drive)' } '4' { 'Batch (scheduled task)' } '5' { 'Service' }
        '7' { 'Unlock' } '8' { 'Network (clear text)' } '9' { 'New credentials (RunAs)' } '10' { 'Remote Desktop' } '11' { 'Cached (offline) sign-in' }
        default { if ("$t" -and "$t" -ne '-') { "Type $t" } else { '' } }
    }
}
# NTSTATUS code of a failed logon (event 4625/4776) -> reason in words.
function Get-NtStatusText($h) {
    switch ("$h".ToLower()) {
        '0xc0000064' { 'The username does not exist' } '0xc000006a' { 'Wrong password' } '0xc000006d' { 'Sign-in failed (wrong username or password)' }
        '0xc000006e' { 'Account restriction' } '0xc000006f' { 'Outside the allowed sign-in hours' } '0xc0000070' { 'Not allowed from this workstation' }
        '0xc0000071' { 'The password has expired' } '0xc0000072' { 'The account is disabled' } '0xc000015b' { 'The user may not sign in this way (logon right missing)' }
        '0xc0000193' { 'The account has expired' } '0xc0000224' { 'The user must change the password at next sign-in' } '0xc0000234' { 'The account is locked out' }
        '0xc000018c' { 'The trust relationship with the domain failed' } '0xc0000133' { 'Clock difference between the computers is too large' }
        default { '' }
    }
}
# Kerberos error code (events 4768/4771) -> reason in words.
function Get-KerbText($h) {
    switch ("$h".ToLower()) {
        '0x6' { 'The username does not exist' } '0x7' { 'Server not found in the directory' } '0x12' { 'The account is disabled, locked out or expired' }
        '0x17' { 'The password has expired' } '0x18' { 'Wrong password' } '0x25' { 'Clock difference between the computers is too large' }
        '0x1f' { 'Integrity check failed' } '0x20' { 'The ticket has expired' } '0x3c' { 'Generic failure' }
        default { '' }
    }
}

# Turns one Windows event into a flat row: time, id, text, result (Success/Failure), who did it, target, IP, workstation, logon type, reason, details.
function Convert-AdEvent($e) {
    $x = $null; try { $x = [xml]$e.ToXml() } catch {}
    $id = "$($e.Id)"
    $what = if ($global:AdEvents.Contains($id)) { $global:AdEvents[$id] } else { ("$($e.Message)" -split "[\r\n]")[0] }
    $by = ''; $tg = ''; $extra = ''; $result = ''; $why = ''; $ip = ''; $ws = ''; $lt = ''
    if ($x) {
        # 'By' = the account that did the action (DOMAIN\name); computer accounts (name ending in $) are shown without the domain.
        $by = Get-EvField $x 'SubjectUserName'; $sd = Get-EvField $x 'SubjectDomainName'; if ($by -and $sd -and $by -notmatch '\$$') { $by = "$sd\$by" }
        $tg = Get-EvField $x 'TargetUserName'; if (-not $tg) { $tg = Get-EvField $x 'ObjectDN' }
        if (-not $tg) { $tg = Get-EvField $x 'MemberName' }
        # Target gets DOMAIN\ in front, except for group-membership events where the target is rebuilt below.
        $td = Get-EvField $x 'TargetDomainName'; if ($tg -and $td -and $id -notin '4728', '4729', '4732', '4733', '4756', '4757') { $tg = "$td\$tg" }
        $bits = @()
        # Add the useful extra fields as 'Name: value' details. '-' and %%1793 (Windows 'no value') are skipped.
        foreach ($f in 'MemberName', 'Status', 'SubStatus', 'AttributeLDAPDisplayName', 'AttributeValue', 'SamAccountName', 'DisplayName', 'UserPrincipalName', 'PrivilegeList') {
            $v = Get-EvField $x $f; if ($v -and $v -ne '-' -and $v -ne '%%1793' -and $v -ne $tg) { $bits += "${f}: $v" }
        }
        # who signed in from where, and why it failed
        # Regex removes the IPv6 prefix ::ffff: from IPv4 addresses; '-' and ::1 (local) are treated as empty.
        $ip = (Get-EvField $x 'IpAddress') -replace '^::ffff:', ''; if ($ip -eq '-' -or $ip -eq '::1') { $ip = '' }
        $ws = Get-EvField $x 'WorkstationName'; if (-not $ws) { $ws = Get-EvField $x 'Workstation' }; if ($ws -eq '-') { $ws = '' }
        $lt = Get-LogonTypeText (Get-EvField $x 'LogonType')
        $st = Get-EvField $x 'Status'; $sub = Get-EvField $x 'SubStatus'
        # Success/failure by event id: 4624/4648 = success; 4625, 4771 = failure; 4768/4776 depend on the status (0x0 = success).
        switch ($id) {
            '4624' { $result = 'Success' }
            '4648' { $result = 'Success' }
            '4625' { $result = 'Failure'; $why = Get-NtStatusText $(if ($sub -and $sub -ne '0x0') { $sub } else { $st }); if (-not $why) { $why = "Status $st $sub".Trim() } }
            '4768' { if ($st -eq '0x0') { $result = 'Success' } else { $result = 'Failure'; $why = Get-KerbText $st; if (-not $why) { $why = "Kerberos code $st" } } }
            '4771' { $result = 'Failure'; $why = Get-KerbText $st; if (-not $why) { $why = "Kerberos code $st" } }
            '4776' { if ($st -eq '0x0') { $result = 'Success' } else { $result = 'Failure'; $why = Get-NtStatusText $st; if (-not $why) { $why = "NTLM code $st" } } }
        }
        if ($id -in '4728', '4729', '4732', '4733', '4756', '4757') {
            # for a group change the person who was added or removed is the target; the group goes in the details
            $g = Get-EvField $x 'TargetUserName'; $mem = Get-EvField $x 'MemberName'
            # Regex: takes the first part of the member's distinguished name (CN=John Smith,OU=...), allowing escaped commas, and removes backslashes.
            $mn = if ($mem -match '^CN=((?:\\.|[^,])+)') { $Matches[1] -replace '\\', '' } else { $mem }
            if ($mn) { $tg = $mn }
            $bits = @($bits | Where-Object { $_ -notmatch '^MemberName:' })
            if ($g) { $bits = @("Group: $g") + $bits }
        }
        $extra = $bits -join ' | '
    }
    [ordered]@{
        time = $e.TimeCreated.ToUniversalTime().ToString('o'); eventId = $id; log = "$($e.LogName)"; event = $what; result = $result; by = $by; target = $tg
        ip = $ip; workstation = $ws; logonType = $lt; reason = $why; details = $extra; level = "$($e.LevelDisplayName)"; computer = "$($e.MachineName)"; provider = "$($e.ProviderName)"
    }
}

# Runs in the thread. $p = { flt (Get-WinEvent filter), dc, local, user/pass, maxEvents, max, text, log, days }.
# Reads the events from the domain controller and converts them; known errors (denied, unreachable) get a readable message.
# the work of an AD event-log search (runs in the background thread)
$global:AuditAdWork = {
    param($p)
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $args2 = @{ FilterHashtable = $p.flt; ErrorAction = 'Stop' }
        # A remote domain controller is read with the saved AD credential; the local PC needs none.
        if (-not $p.local) { $args2.ComputerName = $p.dc; $args2.Credential = New-Object Management.Automation.PSCredential($p.user, $p.pass) }
        $ev = @()
        try { $ev = @(Get-WinEvent @args2 -MaxEvents $p.maxEvents) }
        catch {
            $m = Get-ErrMsg $_
            # Get-WinEvent throws this when nothing matches - that is a normal empty result, not an error.
            if ($m -match 'No events were found') { $ev = @() }
            elseif ($m -match 'denied|Access is denied|unauthorized') { return @{ error = "The domain controller $($p.dc) refused to show its $($p.log) log: $m  (The AD account needs to be a member of Event Log Readers or Domain Admins.)" } }
            elseif ($m -match 'RPC server|network path|not found|unavailable') { return @{ error = "Could not reach $($p.dc) to read its event log: $m  (Check the name and that Remote Event Log Management is allowed in the firewall of that server.)" } }
            else { return @{ error = $m } }
        }
        $rows = @(); $text = "$($p.text)"
        foreach ($e in $ev) {
            $r = Convert-AdEvent $e
            if ($text -and -not (($r.Values -join ' ').ToLower().Contains($text))) { continue }
            $rows += $r
            if ($rows.Count -ge $p.max) { break }
        }
        $trunc = ($rows.Count -ge $p.max)
        return @{ ok = $true; dc = $p.dc; log = $p.log; days = $p.days; count = $rows.Count; truncated = $trunc; secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); rows = $rows }
    } catch { return @{ error = (Get-ErrMsg $_) } }
}

# /api/audit-ad - request: $d.days (1-90), $d.max, $d.text, $d.log, $d.dc (domain controller, optional), $d.set / $d.ids (event ids), $d.level.
# Builds the event filter and starts the background job. Returns { ok, job, dc }.
$ScreenHandlers['/api/audit-ad'] = {
    if (-not $script:AdCred) { throw 'Sign in to On-premises AD first (the On-premises AD screen), then come back here.' }
    $days = [int]$d.days; if ($days -lt 1) { $days = 1 }; if ($days -gt 90) { $days = 90 }
    $max = [int]$d.max; if ($max -lt 10) { $max = 500 }; if ($max -gt $global:AuditMaxRows) { $max = $global:AuditMaxRows }
    $text = "$($d.text)".Trim().ToLower()
    # Only these four Windows logs may be read.
    $log = "$($d.log)"; if ($log -notin 'Security', 'Directory Service', 'System', 'Application') { $log = 'Security' }
    $dc = "$($d.dc)".Trim()
    # Regex: a host name (letters, digits, dot, underscore, dash) - blocks anything unusual.
    if ($dc -and $dc -notmatch '^[A-Za-z0-9._-]{1,255}$') { throw 'The domain controller name has characters that are not allowed.' }
    # No DC typed: use the one this PC is talking to (RootDSE), else the logon server.
    # v2.8.1: the DC chosen in Settings first, then the one Windows picks (RootDSE).
    if (-not $dc) { $sc = Get-AdServerCfg; if ($sc.mode -eq 'manual') { $dc = $sc.server } }
    if (-not $dc) { try { $dc = "$((Get-RootDse).Properties['dnsHostName'].Value)" } catch {} }
    if (-not $dc) { $dc = "$env:LOGONSERVER" -replace '^\\\\', '' }
    if (-not $dc) { throw 'Could not find a domain controller. Type its name in the box.' }
    $ids = @()
    if ($log -eq 'Security') {
        $set = "$($d.set)"
        # Which event ids: custom list (3-5 digit numbers, max 40), a ready-made set, all known ids, or accounts by default.
        if ($set -eq 'custom') { $ids = @(@($d.ids) | ForEach-Object { "$_" } | Where-Object { $_ -match '^\d{3,5}$' } | Select-Object -First 40) }
        elseif ($global:AdEventSets.ContainsKey($set)) { $ids = $global:AdEventSets[$set] }
        elseif ($set -eq 'all') { $ids = @($global:AdEvents.Keys) }
        else { $ids = $global:AdEventSets['accounts'] }
    }
    # Get-WinEvent filter. When no ids are chosen, optionally limit by level (1 critical, 2 error, 3 warning).
    $flt = @{ LogName = $log; StartTime = (Get-Date).AddDays(-$days) }
    if ($ids.Count) { $flt.Id = [int[]]$ids }
    elseif ($d.level -eq 'errors') { $flt.Level = 1, 2 } elseif ($d.level -eq 'warnings') { $flt.Level = 1, 2, 3 }
    # reading the log of the PC you are on needs no credentials; a remote domain controller is read with the AD account of the tool
    # True when the chosen DC is this PC.
    $local = ($dc -split '\.')[0] -ieq $env:COMPUTERNAME
    $script:AdLast = Get-Date
    $arg = @{ flt = $flt; dc = $dc; local = $local; user = $script:AdCred.User; pass = $script:AdCred.Pass; maxEvents = $(if ($text) { $global:AuditMaxRows * 3 } else { $max + 1 }); text = $text; max = $max; log = $log; days = $days }
    $id = Start-AuditJob 'Read AD event log' "$($d.text)" "log=$log on $dc; days=$days; max=$max$(if ($d.set -and $log -eq 'Security') { '; events=' + $d.set })" $global:AuditAdWork $arg
    Send $ctx @{ ok = $true; job = $id; dc = $dc }
}

# /api/audit-ad-events - no request fields. Returns the list of known event ids and names for the page's pick list.
$ScreenHandlers['/api/audit-ad-events'] = {
    $o = @(); foreach ($k in $global:AdEvents.Keys) { $o += @{ id = $k; name = $global:AdEvents[$k] } }
    Send $ctx @{ ok = $true; events = $o }
}

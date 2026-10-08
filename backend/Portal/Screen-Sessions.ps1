# Screen-Sessions.ps1 - back end for the "Who is signed in" screen. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Who is signed in
# Screen version: 2.0.2   (changes ONLY when this screen changes - not with every release)

# Administrators only. Read only.
#  * Signed in now: EVERY person using the tool (v2.0.0: many at the same time), how they signed in
#    (Owner, tool user, AD group, SSO OIDC / SAML), the IP address and PC name, when they started and were last active,
#    and their Microsoft / on-premises AD sign-ins.
#  * Open now: every PC that has the page open (signed in or still on the sign-in page), seen in the last 2 minutes.
#  * History: the sign-in log (logs\login-audit-yyyy-MM.csv) with the method worked out from each row.

# Screen: Who is signed in. Endpoints: /api/sess-now (list), /api/sess-end (end a session), /api/sess-signout (end AD / Microsoft sign-in only),
# /api/sess-history (sign-in log). Reads logs\login-audit-yyyy-MM.csv and the in-memory session table (Get-SessList, $script:Sessions).
# Uses Exit-StGraph / Clear-Ad / Clear-Who to end Microsoft and AD sign-ins. Administrators only (see header).
#
# SeenClients = in-memory list of every browser that touched the tool, key 'ip|browser'. Lost when the tool restarts.
$script:SeenClients = @{}
# Called by server.ps1 on each request. Records/updates this client (IP, PC, browser, signed-in or not, which page).
# Inputs: $ctx (HTTP context), $path (URL path). Never throws - tracking must not break a request.
function Add-SeenClient($ctx, $path) {
    try {
        $ip = $script:ClientIp; if (-not $ip) { return }
        if ($path -like '/api/sess-*') { }   # the admin looking at this screen counts too
        # Signed in = the request's 'sid' cookie equals the current session id (case-sensitive compare).
        $c = $ctx.Request.Cookies['sid']
        $on = [bool]($script:Session -and $c -and $c.Value -ceq $script:Session)
        $ua = "$($ctx.Request.UserAgent)"
        # Work out the browser name from the User-Agent. Order matters: Edge and Chrome also contain 'Safari/'.
        $br = if ($ua -match 'Edg/') { 'Edge' } elseif ($ua -match 'Chrome/') { 'Chrome' } elseif ($ua -match 'Firefox/') { 'Firefox' } elseif ($ua -match 'Safari/') { 'Safari' } elseif ($ua) { 'Other' } else { '' }
        $k = "$ip|$br"
        $o = $script:SeenClients[$k]
        if (-not $o) { $o = @{ ip = $ip; pc = $script:ClientPc; browser = $br; first = Get-Date; hits = 0 }; $script:SeenClients[$k] = $o }
        $o.last = Get-Date; $o.hits++; $o.signedIn = $on; $o.pc = $script:ClientPc
        $o.user = if ($on -and $script:SessUser) { "$($script:SessUser.name)" } else { '' }
        # Page: the tool itself, the sign-in page, or keep the last known value for other paths (images, scripts).
        $o.page = if ($path -eq '/' -or $path -like '/api/*') { 'Tool' } elseif ($path -like '/login*' -or $path -like '/sso/*') { 'Sign-in page' } else { $o.page }
        # Housekeeping: forget clients not seen for 12 hours so the list does not grow forever.
        foreach ($x in @($script:SeenClients.Keys)) { if (((Get-Date) - $script:SeenClients[$x].last).TotalHours -ge 12) { $script:SeenClients.Remove($x) } }
    } catch {}
}
# Turns a session user object into readable text for how they signed in (owner, SSO, AD group, or normal tool user).
function Get-SessMethod($u) {
    if (-not $u) { return '' }
    if ($u.owner) { return 'Owner (local password)' }
    if ($u.sso) { return "SSO - $($u.sso)" }
    if ($u.ad) { return "AD account (group $($u.adGroup))" }
    'Normal - tool user'
}
# Works out the sign-in method from the text of a login-log Result column (the log has no separate method column).
function Get-LogMethod($res) {
    $r = "$res"
    if ($r -match 'OIDC') { return 'SSO - OIDC' }
    if ($r -match 'SAML') { return 'SSO - SAML' }
    if ($r -match 'single sign-on') { return 'SSO' }
    if ($r -match '\(AD|AD sign-in') { return 'AD account' }
    if ($r -match 'owner') { return 'Owner' }
    if ($r -match '^(Success|Failed|Refused)') { return 'Normal' }
    ''
}
# Handler /api/sess-now. No input. Sends { sessions, current, open, recent, server }:
# sessions = everyone signed in, open = browsers seen in the last 2 minutes, recent = up to 30 older ones.
$ScreenHandlers['/api/sess-now'] = {
    # v2.0.0: EVERY signed-in person (many at the same time), with their Microsoft and AD sign-ins
    $now = Get-Date; $mine = $script:Session
    # Script block that builds one row for a session: $sid = session id, $st = that session's saved variables. Times are sent as UTC ISO text.
    $one = { param($sid, $st)
        $u = $st.SessUser; if (-not $u) { return }
        [ordered]@{ id = (Get-SessId $sid); me = ($sid -eq $mine); user = "$($u.name)"; role = "$($u.role)"; method = Get-SessMethod $u
            ip = "$($st.SessIp)"; pc = "$($st.SessPc)"; browser = $(Get-UaName "$($st.SessUa)")
            start = $(if ($st.SessStart) { ([datetime]$st.SessStart).ToUniversalTime().ToString('o') } else { '' }); last = $(if ($st.SessLast) { ([datetime]$st.SessLast).ToUniversalTime().ToString('o') } else { '' })
            ms = "$($st.WhoUpn)"; ad = $(if ($st.AdCred) { "$($st.AdCred.User)" } else { '' }) }
    }
    $list = @()
    # Loop over all stored sessions. The caller's own session lives in live script variables, so those are copied into a hashtable ($script:PerSess names).
    foreach ($sx in @(Get-SessList)) { $sid = $sx.sid; $st = $(if ($sid -eq $mine) { $h = @{}; foreach ($n in $script:PerSess) { $h[$n] = Get-Variable -Scope Script -Name $n -ValueOnly -ErrorAction SilentlyContinue }; $h } else { $sx.st }); $o = & $one $sid $st; if ($o) { $list += $o } }
    # Safety: if my own session is not in the table yet, still show it.
    if ($mine -and -not $script:Sessions.ContainsKey($mine)) { $h = @{}; foreach ($n in $script:PerSess) { $h[$n] = Get-Variable -Scope Script -Name $n -ValueOnly -ErrorAction SilentlyContinue }; $o = & $one $mine $h; if ($o) { $list += $o } }
    $list = @($list | Sort-Object { $_.start })
    # Open now: clients active within 120 seconds, signed-in ones first.
    $open = @($script:SeenClients.Values | Where-Object { ($now - $_.last).TotalSeconds -le 120 } | Sort-Object { -not $_.signedIn }, ip | ForEach-Object {
        [ordered]@{ ip = $_.ip; pc = $_.pc; browser = $_.browser; signedIn = [bool]$_.signedIn; user = $_.user; page = $_.page; first = $_.first.ToUniversalTime().ToString('o'); last = $_.last.ToUniversalTime().ToString('o') } })
    # Recent: clients idle for more than 120 seconds, newest first, at most 30.
    $recent = @($script:SeenClients.Values | Where-Object { ($now - $_.last).TotalSeconds -gt 120 } | Sort-Object last -Descending | Select-Object -First 30 | ForEach-Object {
        [ordered]@{ ip = $_.ip; pc = $_.pc; browser = $_.browser; user = $_.user; page = $_.page; last = $_.last.ToUniversalTime().ToString('o') } })
    Send $ctx @{ ok = $true; sessions = $list; current = $(if ($list.Count) { $list[0] } else { $null }); open = $open; recent = $recent; server = "$env:COMPUTERNAME"; max = 0 }
}
# v2.0.0: an administrator ends another person's session (their Microsoft, AD and Exchange Online sign-ins end too)
# Handler /api/sess-end. Input $d.id = session id (from the list). Ends that person's whole session. Cannot end your own (use Log out).
# Switches temporarily into the target session (Use-Sess) to log them out, then always switches back (finally). Sends { ok, user }.
$ScreenHandlers['/api/sess-end'] = {
    $id = "$($d.id)"; $mine = $script:Session
    $target = @(Get-SessList | Where-Object { (Get-SessId $_.sid) -eq $id } | Select-Object -First 1)
    if (-not $target.Count) { throw 'That session has already ended.' }
    if ($target[0].sid -eq $mine) { throw 'This is your own session - use Session > Log out.' }
    $by = "$($script:SessUser.name)"
    Save-Sess $mine
    # Act inside the target session: write the log lines and stop the session (also ends their Microsoft / AD / Exchange sign-ins).
    try { Use-Sess $target[0].sid; $endWho = "$($script:SessUser.name)"; Write-LoginLog $endWho "Session ended by $by"; Stop-ToolSession "Session of $endWho ended by $by." }
    finally { Save-Sess $target[0].sid; Use-Sess $mine }
    try { Write-ActRow 'Who is signed in' 'End session' $endWho "Done - by $by" '' } catch {}
    Send $ctx @{ ok = $true; user = $endWho }
}
# v2.0.2: an administrator signs another person out of on-premises AD and/or Microsoft - their portal session stays open
# Handler /api/sess-signout. Input $d.id = session id, $d.what = 'ad', 'ms' or 'both'. Ends only the AD and/or Microsoft sign-in;
# the person stays signed in to the portal. Sends { ok, user, done } where done lists what was ended.
$ScreenHandlers['/api/sess-signout'] = {
    $id = "$($d.id)"; $what = "$($d.what)"; if ($what -notin 'ad', 'ms', 'both') { throw 'Choose what to sign out.' }
    $mine = $script:Session; $by = "$($script:SessUser.name)"
    $target = @(Get-SessList | Where-Object { (Get-SessId $_.sid) -eq $id } | Select-Object -First 1)
    # The admin may sign themselves out of AD/Microsoft: their own session is not always in the list, so build a stand-in.
    if (-not $target.Count -and $mine -and (Get-SessId $mine) -eq $id) { $target = @([pscustomobject]@{ sid = $mine }) }
    if (-not $target.Count) { throw 'That session has already ended.' }
    $tsid = $target[0].sid; $done = @()
    if ($tsid -ne $mine) { Save-Sess $mine; Use-Sess $tsid }
    try {
        $soName = "$($script:SessUser.name)"
        # Only act on what is actually signed in. Clear-Ad drops the stored AD credential.
        if ($what -in 'ad', 'both' -and $script:AdCred) { $u = "$($script:AdCred.User)"; Clear-Ad; $done += "AD ($u)"; Write-LoginLog $soName "On-prem AD sign-in ended by $by" }
        # Exit-StGraph disconnects Microsoft Graph / Exchange Online; Clear-Who forgets the Microsoft account.
        if ($what -in 'ms', 'both' -and $script:Who) { $u = "$($script:Who)"; Exit-StGraph "Microsoft sign-out by $by"; Clear-Who; $done += "Microsoft ($u)" }
    } finally { if ($tsid -ne $mine) { Save-Sess $tsid; Use-Sess $mine } }
    # Nothing was signed in: tell the admin instead of reporting a fake success.
    if (-not $done.Count) { throw "$soName is not signed in to that." }
    try { Write-ActRow 'Who is signed in' 'Sign out' $soName ("Done - " + ($done -join ', ') + " - by $by") '' } catch {}
    Send $ctx @{ ok = $true; user = $soName; done = $done }
}
# Browser name from a User-Agent string (same rules as in Add-SeenClient).
function Get-UaName($ua) { if ($ua -match 'Edg/') { 'Edge' } elseif ($ua -match 'Chrome/') { 'Chrome' } elseif ($ua -match 'Firefox/') { 'Firefox' } elseif ($ua -match 'Safari/') { 'Safari' } elseif ($ua) { 'Other' } else { '' } }
# Handler /api/sess-history. Input $d.days (1-93, default 7). Sends { rows, days }: newest first, max 2000 rows,
# each with time, user, result, method, ip, pc and kind (ok / bad / info for colouring).
$ScreenHandlers['/api/sess-history'] = {
    $days = [Math]::Max(1, [Math]::Min(93, [int]$(if ($d.days) { $d.days } else { 7 })))
    $from = (Get-Now).Date.AddDays(1 - $days); $rows = @()
    # Read this month's log file and the 3 months before it (one CSV per month).
    foreach ($m in 0..3) {
        $f = Join-Path $LogDir ('login-audit-{0:yyyy-MM}.csv' -f (Get-Date).AddMonths(-$m))
        if (Test-Path $f) { try { $rows += @(Import-Csv -LiteralPath $f -Encoding UTF8) } catch {} }
    }
    # Keep rows newer than the start date, and only sign-in related results (Success, Failed, Refused, Logout, Session..., On-prem AD sign-in).
    $out = @($rows | Where-Object { try { [datetime]$_.Time -ge $from } catch { $false } } | Where-Object { "$($_.Result)" -match '^(Success|Failed|Refused|Logout|Session)' -or "$($_.Result)" -like 'On-prem AD sign-in*' } |
        Sort-Object Time -Descending | Select-Object -First 2000 | ForEach-Object {
            $r = "$($_.Result)"
            [ordered]@{ time = "$($_.Time)"; user = "$($_.EnteredUsername)"; result = $r; method = Get-LogMethod $r; ip = "$($_.ClientIP)"; pc = "$($_.ClientPC)"
                kind = $(if ($r -like 'Success*') { 'ok' } elseif ($r -match '^(Failed|Refused)') { 'bad' } else { 'info' }) } })
    Send $ctx @{ ok = $true; rows = $out; days = $days }
}

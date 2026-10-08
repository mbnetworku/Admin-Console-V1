# Screen-TeamsMembers.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Teams members
# Screen version: 2.0.0   (changes ONLY when this screen changes - not with every release)

# WHAT IT DOES: finds Microsoft Teams, lists their owners and members, and adds people to teams as Member or Owner. Never removes anyone.
# ENDPOINTS: POST /api/teams-find (field queries = up to 10 search texts), POST /api/teams-members (groupIds, up to 20 teams),
# POST /api/teams-add (groupIds up to 5, emails up to 25, role Member|Owner), POST /api/teams-log (downloads the audit log as one CSV).
# GRAPH (v1.0, through the signed-in Microsoft connection): /groups (search, filter), /groups/{id}/members and /owners, /users, with the
# Group.ReadWrite.All permission (or Directory.ReadWrite.All). The Guest users screen reuses the helper functions in this file.
# DATA: writes teams-audit-yyyy-MM.csv in the Logs folder. Permission: whatever the signed-in person may do in Teams (must be a team owner/admin).
# It uses the Microsoft sign-in from the sidebar and needs the Group.ReadWrite.All permission. Nothing is ever removed or deleted here.

# TmGuidRx = regex for a GUID (object id): 8-4-4-4-12 hex characters. TmGroupSel = the group fields we ask Graph for.
$script:TmGuidRx = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:TmGroupSel = '$select=id,displayName,mailNickname,mail,resourceProvisioningOptions'
# TmNames = cache of team id -> team name (for the log). TmWho = who it was cached for, so another sign-in starts with an empty cache.
$script:TmNames = @{}; $script:TmWho = $null

# Adds one line to this month's Teams audit CSV (creates the file with its header first). Inputs: team name and id, the e-mail, role,
# status and message. Also records the Windows user and the Microsoft admin who did it. ConvertTo-CsvCell protects commas and quotes.
function Write-TeamsLog($team, $gid, $email, $role, $status, $message) {
    $f = Join-Path $LogDir ('teams-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,WindowsUser,Admin,Team,TeamId,Email,Role,Status,Message' | Out-File $f -Encoding utf8 }
    $vals = @(('{0:s}' -f (Get-Now)), [Security.Principal.WindowsIdentity]::GetCurrent().Name, $script:Who, $team, $gid, $email, $role, $status, $message) |
        ForEach-Object { ConvertTo-CsvCell $_ }
    ($vals -join ',') | Add-Content $f
}

# Must be signed in to Microsoft, with the Teams permission; also forgets cached team names when another person signs in
# Throws a friendly error unless signed in to Microsoft with a suitable permission. An empty scope list is accepted (unknown).
function Test-TmReady {
    if (-not $script:Who) { throw 'Not connected. Sign in to Microsoft first.' }
    $sc = @(Get-MsScopes)
    if ($sc.Count -and ($sc -notcontains 'Group.ReadWrite.All') -and ($sc -notcontains 'Directory.ReadWrite.All')) {
        throw 'This screen needs the Group.ReadWrite.All permission. Sign out of Microsoft, connect again and approve it (an administrator may have to approve it once for your organization).'
    }
    if ($script:TmWho -ne $script:Who) { $script:TmNames = @{}; $script:TmWho = $script:Who }
}

# Turns a Graph error into readable text: uses the 'message' in the JSON error body if present, else the exception message.
function Get-TmErr($e) {
    $msg = $null
    try { $j = $e.ErrorDetails.Message | ConvertFrom-Json; if ($j.error.message) { $msg = "$($j.error.message)" } } catch {}
    if (-not $msg) { $msg = if ($e.Exception.InnerException) { $e.Exception.InnerException.Message } else { $e.Exception.Message } }
    $msg
}
# Returns the HTTP status code (404, 403 ...) of a failed web call, or 0 if there is none.
function Get-TmCode($e) {
    try { return [int]$e.Exception.Response.StatusCode } catch {}
    0
}
# One Microsoft Graph call through the sidebar sign-in (retries when Microsoft says "slow down")
# Calls Microsoft Graph. $method GET/POST..., $url full address or a path (v1.0 is added), $body object sent as JSON, -Eventual adds the
# ConsistencyLevel header that Graph needs for $search queries. Waits 3 seconds and retries (3 tries) on 429/503 (Microsoft says slow down).
# On failure throws an error with a clearer text; the HTTP code is kept in $ex.Data['code'] for callers.
function Invoke-TmGraph($method, $url, $body = $null, [switch]$Eventual) {
    if ($url -notmatch '^https://') { $url = 'https://graph.microsoft.com/v1.0' + $url }
    for ($try = 0; $try -lt 3; $try++) {
        $p = @{ Method = $method; Uri = $url; OutputType = 'PSObject'; ErrorAction = 'Stop' }
        if ($Eventual) { $p.Headers = @{ ConsistencyLevel = 'eventual' } }
        if ($null -ne $body) { $p.Body = ($body | ConvertTo-Json -Depth 5 -Compress); $p.ContentType = 'application/json' }
        try { return (Invoke-MgGraphRequest @p) }
        catch {
            $code = Get-TmCode $_; $msg = Get-TmErr $_
            if (($code -eq 429 -or $code -eq 503) -and $try -lt 2) { Start-Sleep -Seconds 3; continue }
            if ($code -eq 403 -or $msg -match 'Authorization_RequestDenied|Insufficient privileges') {
                $msg += ' (You may not be an owner of this team, or the Group.ReadWrite.All permission is missing - sign out of Microsoft and connect again.)'
            }
            $ex = New-Object Exception($msg); $ex.Data['code'] = $code; throw $ex
        }
    }
}
# Reads every page of a Graph list by following @odata.nextLink (safety stop after 100 pages). Returns all items as an array.
function Get-TmAll($url) {
    $list = New-Object System.Collections.ArrayList; $pages = 0
    while ($url -and $pages -lt 100) {
        $r = Invoke-TmGraph GET $url; $pages++
        foreach ($v in @($r.value)) { [void]$list.Add($v) }
        $url = $r.'@odata.nextLink'
    }
    $list.ToArray()
}
# True if the group is a real Microsoft Team (Graph marks these with 'Team' in resourceProvisioningOptions), not just a normal group.
function Is-Team($g) { @($g.resourceProvisioningOptions) -contains 'Team' }

# Search by object ID, group email or name (a name search finds Teams whose name contains or starts with the text)
# Looks for teams. Input $q can be an object id, an e-mail of the group, or a name. Returns { GroupId, DisplayName, MailNickName, type }.
function Find-Teams($q) {
    $f = @(); $type = 'Name'
    if ($q -match $script:TmGuidRx) {
        $type = 'Object ID'
        # Object id: read that group directly.
        try { $f = @(Invoke-TmGraph GET ("/groups/$q" + '?' + $script:TmGroupSel)) } catch { $f = @() }
    } elseif ($q -match '@') {
        $type = 'Email'
        # Email: exact match on the group's mail. Spaces are removed and a single quote is doubled (the OData way to escape it).
        $e = ($q -replace '\s', '').Replace("'", "''")
        $f = @((Invoke-TmGraph GET ('/groups?$filter=' + [uri]::EscapeDataString("mail eq '$e'") + '&' + $script:TmGroupSel)).value)
    } else {
        # Name: first a Graph $search on displayName (finds names containing the text). Quotes and backslashes are removed so they cannot break
        # the search text. If that finds no Team, try 'starts with' as a fallback.
        $k = [uri]::EscapeDataString(($q -replace '["\\]', ''))
        $f = @((Invoke-TmGraph GET ('/groups?$search=%22displayName:' + $k + '%22&' + $script:TmGroupSel + '&$top=50') -Eventual).value)
        if (-not @($f | Where-Object { Is-Team $_ }).Count) {
            $e = [uri]::EscapeDataString("startswith(displayName,'" + $q.Replace("'", "''") + "')")
            $f = @((Invoke-TmGraph GET ('/groups?$filter=' + $e + '&' + $script:TmGroupSel + '&$top=50') -Eventual).value)
        }
    }
    foreach ($g in $f) {
        if ($g -and (Is-Team $g)) {
            $shown = if ($g.mail) { $g.mail } else { $g.mailNickname }
            [pscustomobject]@{ GroupId = "$($g.id)"; DisplayName = "$($g.displayName)"; MailNickName = "$shown"; type = $type }
        }
    }
}
# Only a group that really is a Microsoft Team may be changed; its name is remembered for the log
# Safety check before any change: the id must be a valid GUID and the group must be a real Team. Returns its name (cached for the log).
function Get-TmTeamName($gid) {
    if ("$gid" -notmatch $script:TmGuidRx) { throw 'That is not a valid team ID.' }
    if (-not $script:TmNames[$gid]) {
        $g = Invoke-TmGraph GET ("/groups/$gid" + '?' + $script:TmGroupSel)
        if (-not (Is-Team $g)) { throw 'That group is not a Microsoft Team, so it was not changed.' }
        $script:TmNames[$gid] = "$($g.displayName)"
    }
    $script:TmNames[$gid]
}
# Finds a person in the directory by e-mail/UPN. First tries /users/{email}, then a filter on the mail attribute (works for guests whose UPN
# looks different). Returns the user object (id, displayName) or $null. Permission errors (401/403) are passed on instead of hidden.
function Find-TmUser($email) {
    try {
        $u = Invoke-TmGraph GET ('/users/' + [uri]::EscapeDataString($email) + '?$select=id,displayName')
        if ($u.id) { return $u }
    } catch { if ($_.Exception.Data['code'] -in 401, 403) { throw } }
    $e = [uri]::EscapeDataString("mail eq '" + $email.Replace("'", "''") + "'")
    $v = @((Invoke-TmGraph GET ('/users?$filter=' + $e + '&$select=id,displayName')).value)
    if ($v.Count) { return $v[0] }
    $null
}
# True if the user is in the group's list ($kind = 'members' or 'owners'); a 404 from Graph means no.
function Test-TmMember($gid, $uid, $kind) {
    try { Invoke-TmGraph GET "/groups/$gid/$kind/${uid}?`$select=id" | Out-Null; return $true } catch { return $false }
}
# Adds one person; returns Added or Skipped (already there) with a short note
# Adds one person to one team. $gid team id, $user object with .id, $role 'Member' or 'Owner'. Returns { status = Added|Skipped, message }.
# Graph needs the person added as a member first, then (for Owner) also to /owners. 'Already exists' answers are treated as Skipped, not errors.
function Add-TmOne($gid, $user, $role) {
    $uid = "$($user.id)"
    $ref = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$uid" }
    $wasMember = $false
    try { Invoke-TmGraph POST "/groups/$gid/members/`$ref" $ref | Out-Null }
    catch {
        $err = $_
        if ($err.Exception.Message -match 'already exist' -or (Test-TmMember $gid $uid 'members')) { $wasMember = $true } else { throw $err }
    }
    if ($role -eq 'Owner') {
        try { Invoke-TmGraph POST "/groups/$gid/owners/`$ref" $ref | Out-Null }
        catch {
            $err = $_
            if ($err.Exception.Message -match 'already exist' -or (Test-TmMember $gid $uid 'owners')) { return @{ status = 'Skipped'; message = 'Already an owner' } }
            throw $err
        }
        return @{ status = 'Added'; message = $(if ($wasMember) { 'Was already a member - now an owner' } else { '' }) }
    }
    if ($wasMember) { return @{ status = 'Skipped'; message = 'Already a member' } }
    @{ status = 'Added'; message = '' }
}
# Lists everybody in a team with role Owner or Member (an owner who is not in the members list is added too). Returns name, email, role, userId.
function Get-TmMembers($gid) {
    $sel = '?$select=id,displayName,userPrincipalName,mail&$top=999'
    $owners = @(Get-TmAll "/groups/$gid/owners$sel")
    $members = @(Get-TmAll "/groups/$gid/members$sel")
    $ownerIds = @{}; foreach ($o in $owners) { $ownerIds["$($o.id)"] = 1 }
    $memberIds = @{}
    foreach ($m in $members) {
        $memberIds["$($m.id)"] = 1
        $mail = if ($m.userPrincipalName) { $m.userPrincipalName } else { $m.mail }
        $role = if ($ownerIds["$($m.id)"]) { 'Owner' } else { 'Member' }
        [pscustomobject]@{ name = "$($m.displayName)"; email = "$mail"; role = $role; userId = "$($m.id)" }
    }
    foreach ($o in $owners) {
        if (-not $memberIds["$($o.id)"]) {
            $mail = if ($o.userPrincipalName) { $o.userPrincipalName } else { $o.mail }
            [pscustomobject]@{ name = "$($o.displayName)"; email = "$mail"; role = 'Owner'; userId = "$($o.id)" }
        }
    }
}
# Writes the audit-log line for one add and returns the same facts as a result row for the page.
function New-TmResult($team, $gid, $email, $role, $status, $message) {
    Write-TeamsLog $team $gid $email $role $status $message
    [pscustomobject]@{ team = $team; email = $email; status = $status; message = $message }
}

# Handler: search teams for each typed text (spaces tidied, max 10 texts, 200 characters each). Duplicates are dropped; names are cached.
$ScreenHandlers['/api/teams-find'] = {
        Test-TmReady
        $qs = @($d.queries | ForEach-Object { ("$_" -replace '\s+', ' ').Trim() } | Where-Object { $_ })
        if ($qs.Count -gt 10) { throw 'Search for up to 10 teams at a time.' }
        $seen = @{}; $out = @()
        foreach ($q in $qs) {
            if ($q.Length -gt 200) { throw 'A search text is too long.' }
            foreach ($t in @(Find-Teams $q)) {
                if ($t -and -not $seen[$t.GroupId]) { $seen[$t.GroupId] = 1; $script:TmNames[$t.GroupId] = $t.DisplayName; $out += $t }
            }
        }
        Send $ctx @{ ok = $true; teams = @($out | Sort-Object DisplayName) }
}

# Handler: list owners and members of the chosen teams. Each listing is also written to the audit log.
$ScreenHandlers['/api/teams-members'] = {
        Test-TmReady
        $ids = @($d.groupIds | ForEach-Object { "$_" } | Where-Object { $_ })
        if (-not $ids.Count) { throw 'Choose a team first.' }
        if ($ids.Count -gt 20) { throw 'Choose up to 20 teams at a time.' }
        $rows = New-Object System.Collections.ArrayList
        foreach ($gid in $ids) {
            $tn = Get-TmTeamName $gid
            $list = @(Get-TmMembers $gid)
            foreach ($x in $list) { [void]$rows.Add([pscustomobject]@{ team = $tn; groupId = $gid; name = $x.name; email = $x.email; role = $x.role; userId = $x.userId }) }
            Write-TeamsLog $tn $gid '' '' 'Members listed' "$($list.Count) members"
        }
        Send $ctx @{ ok = $true; members = @($rows.ToArray()) }
}

# Handler: add every e-mail to every chosen team with the chosen role. Each person gets their own result row (Added, Skipped, Invalid, Failed)
# and one failure does not stop the rest. Guests must be invited first (Guest users screen).
$ScreenHandlers['/api/teams-add'] = {
        Test-TmReady
        $role = if ("$($d.role)" -eq 'Owner') { 'Owner' } else { 'Member' }
        $ids = @($d.groupIds | ForEach-Object { "$_" } | Where-Object { $_ })
        $emails = @($d.emails | ForEach-Object { "$_" } | Where-Object { $_ })
        if (-not $ids.Count) { throw 'Choose a team first.' }
        if (-not $emails.Count) { throw 'Add at least one email address.' }
        if ($ids.Count -gt 5 -or $emails.Count -gt 25) { throw 'Too many at once - send smaller batches.' }
        $results = New-Object System.Collections.ArrayList
        foreach ($gid in $ids) {
            $tn = Get-TmTeamName $gid
            foreach ($raw in $emails) {
                # Normalise the address, then check it looks like name@domain.tld before calling Graph.
                $email = ($raw -replace '\s', '').Trim().ToLower()
                if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { [void]$results.Add((New-TmResult $tn $gid $email $role 'Invalid' 'Not a valid email')); continue }
                try {
                    $u = Find-TmUser $email
                    if (-not $u) { [void]$results.Add((New-TmResult $tn $gid $email $role 'Failed' 'User not found in your organization (guests must be invited first)')); continue }
                    $r = Add-TmOne $gid $u $role
                    [void]$results.Add((New-TmResult $tn $gid $email $role $r.status $r.message))
                } catch {
                    [void]$results.Add((New-TmResult $tn $gid $email $role 'Failed' $_.Exception.Message))
                }
            }
        }
        Send $ctx @{ ok = $true; results = @($results.ToArray()) }
}

$ScreenHandlers['/api/teams-log'] = {
        # (Handler: reads the monthly teams-audit CSV files in order and sends them as one text.) Only the first file's header is kept.
        # All saved Teams log files joined into one CSV (header once)
        $files = @(Get-ChildItem -Path $LogDir -Filter 'teams-audit-*.csv' -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if (-not $files.Count) { throw 'There is no Teams log yet. It is created the first time you use the Teams members screen.' }
        $lines = @()
        foreach ($f in $files) {
            $c = @(Get-Content $f.FullName -Encoding UTF8)
            if (-not $lines.Count) { $lines += $c } elseif ($c.Count -gt 1) { $lines += $c[1..($c.Count - 1)] }
        }
        Send $ctx @{ ok = $true; csv = ($lines -join "`r`n"); files = $files.Count }
}

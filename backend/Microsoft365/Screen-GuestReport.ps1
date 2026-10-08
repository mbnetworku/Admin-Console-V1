# Screen-GuestReport.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Guest users report
# Screen version: 2.11.0   (changes ONLY when this screen changes - not with every release)

# WHAT IT DOES: the "Guest users report" screen. READ ONLY. Lists every guest (outside) user of Microsoft Entra ID with:
#   display name, e-mail, user principal name, when the guest was CREATED, the LAST SIGN-IN, whether the INVITATION was ACCEPTED
#   (and when), whether the account is enabled, and the GROUPS the guest is a member of (all group names in ONE cell, separated by "; ",
#   each followed by its kind in brackets: "M365 group", "Teams group", "Security group", "Distribution list", "Mail-enabled security").
# ENDPOINT: POST /api/guestrep-run. Request: {} (no fields). Reply: { ok, rows [...], count, signIn (true when last sign-in could be read),
#   notes [text, ...] }.
# GRAPH (needs the Microsoft sign-in; User.Read.All, AuditLog.Read.All for the last sign-in, Directory.Read.All for the groups - all already
#   in the normal sign-in scopes):
#   GET /users?$filter=userType eq 'Guest'&$select=...,signInActivity  (120 per page when signInActivity is asked, follows @odata.nextLink)
#   POST /$batch with GET /users/{id}/memberOf/microsoft.graph.group (20 guests per call)
# If Microsoft refuses signInActivity (no AuditLog.Read.All, or no Entra ID P1/P2 licence) the report is still made, without that column,
#   and a note tells the person why. If the groups of some guests cannot be read, a note says so.
# No limit on the number of guests (all pages are read).

# Stops the request with a clear message unless somebody is signed in to Microsoft.
function Test-GuestRepReady {
    if (-not $script:Who) { throw 'Not connected. Sign in to Microsoft first (Settings > Connections, or the M365 / AD button at the top right).' }
}
# Turns a Graph date (text or DateTime) into local time "yyyy-MM-dd HH:mm". Empty or unreadable -> ''.
function Format-GuestRepDate($v) {
    if (-not $v) { return '' }
    try { $dt = $(if ($v -is [datetime]) { $v } else { [datetime]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }); return $dt.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { return '' }
}
# Names the kind of a group record from Graph: Teams group (Microsoft 365 group that has a team), M365 group (Unified),
# Security group, Mail-enabled security, Distribution list.
function Get-GuestRepGroupKind($g) {
    $types = @($g.groupTypes); $prov = @($g.resourceProvisioningOptions)
    if ($types -contains 'Unified') { if ($prov -contains 'Team') { return 'Teams group' } else { return 'M365 group' } }
    if ($g.securityEnabled -and $g.mailEnabled) { return 'Mail-enabled security' }
    if ($g.securityEnabled) { return 'Security group' }
    if ($g.mailEnabled) { return 'Distribution list' }
    'Group'
}
# Reads ALL pages of a Graph list. $uri first URL. Returns the list of records (a comma stops PowerShell from unrolling it).
function Get-GuestRepPages([string]$uri) {
    $rows = New-Object Collections.Generic.List[object]
    while ($uri) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        foreach ($x in @($r.value)) { $rows.Add($x) }
        $uri = $r.'@odata.nextLink'
    }
    , $rows
}

# Handler /api/guestrep-run: builds the whole report (read only).
$ScreenHandlers['/api/guestrep-run'] = {
    Test-GuestRepReady
    $notes = @(); $signIn = $true
    $base = 'https://graph.microsoft.com/v1.0/users?$filter=' + [uri]::EscapeDataString("userType eq 'Guest'")
    $sel  = 'id,displayName,mail,userPrincipalName,createdDateTime,externalUserState,externalUserStateChangeDateTime,accountEnabled,companyName'
    # First try WITH the sign-in activity; if Microsoft refuses it, read again without and remember to tell the person.
    try { $guests = Get-GuestRepPages ($base + '&$top=120&$select=' + $sel + ',signInActivity') }
    catch {
        $signIn = $false; $why = "$($_.Exception.Message)"
        $notes += 'The last sign-in column is empty: Microsoft did not allow reading it (it needs the AuditLog.Read.All permission and an Entra ID P1/P2 licence). Sign out of Microsoft and connect again to approve the permission. (' + $why + ')'
        $guests = Get-GuestRepPages ($base + '&$top=999&$select=' + $sel)
    }
    # Groups of every guest, 20 guests per $batch call. A failure only leaves that guest's groups empty and is counted.
    $grp = @{}; $failed = 0; $gl = @($guests)
    for ($i = 0; $i -lt $gl.Count; $i += 20) {
        $chunk = @($gl[$i..([Math]::Min($i + 19, $gl.Count - 1))])
        $reqs = @(); for ($k = 0; $k -lt $chunk.Count; $k++) { $reqs += @{ id = "$k"; method = 'GET'; url = "/users/$($chunk[$k].id)/memberOf/microsoft.graph.group?`$select=id,displayName,groupTypes,resourceProvisioningOptions,securityEnabled,mailEnabled&`$top=999" } }
        try {
            $br = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body (@{ requests = $reqs } | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop
            foreach ($r in @($br.responses)) {
                $u = $chunk[[int]$r.id]
                if ([int]$r.status -eq 200) { $grp[$u.id] = @($r.body.value) } else { $failed++ }
            }
        } catch { $failed += $chunk.Count }
    }
    if ($failed) { $notes += "The groups of $failed guest(s) could not be read, so their Groups cell is empty." }
    $rows = New-Object Collections.Generic.List[object]
    foreach ($u in $gl) {
        $items = @($grp[$u.id] | Where-Object { $_ } | Sort-Object { "$($_.displayName)" } | ForEach-Object { "$($_.displayName) ($(Get-GuestRepGroupKind $_))" })
        # Last sign-in: the last SUCCESSFUL one when known, otherwise the last attempt.
        $last = ''
        if ($signIn -and $u.signInActivity) { $last = Format-GuestRepDate $(if ($u.signInActivity.lastSuccessfulSignInDateTime) { $u.signInActivity.lastSuccessfulSignInDateTime } else { $u.signInActivity.lastSignInDateTime }) }
        $st = "$($u.externalUserState)"
        $inv = if ($st -eq 'Accepted') { 'Accepted' } elseif ($st -eq 'PendingAcceptance') { 'Not accepted' } elseif ($st) { $st } else { 'Unknown' }
        $rows.Add([pscustomobject][ordered]@{
            name = "$($u.displayName)"; mail = "$($u.mail)"; upn = "$($u.userPrincipalName)"; company = "$($u.companyName)"
            created = (Format-GuestRepDate $u.createdDateTime); lastSignIn = $last; invitation = $inv
            accepted = $(if ($inv -eq 'Accepted') { Format-GuestRepDate $u.externalUserStateChangeDateTime } else { '' })
            enabled = $(if ($u.accountEnabled -eq $false) { 'Disabled' } else { 'Enabled' })
            groupCount = $items.Count; groups = ($items -join '; ') })
    }
    $sorted = @($rows | Sort-Object name)
    Send $ctx @{ ok = $true; rows = $sorted; count = $sorted.Count; signIn = $signIn; notes = $notes }
}

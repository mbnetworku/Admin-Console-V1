# Screen-People.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: People database (Settings)
# Screen version: 2.4.0   (changes ONLY when this screen changes - not with every release)

# Works on its own (without AD). Linking with on-premises Active Directory is OPTIONAL: turn it on in the screen, then you can
# import people from AD, link a record to an AD account, and refresh linked records from AD. Nothing is ever written to AD.
# Saved in people-db.json next to the tool (a copy of the previous version is kept as people-db.bak.json).

# WHAT THIS SCREEN DOES: Settings > People database - a list of people kept by the tool itself (name, username, email, department, phone, note).
# ENDPOINTS: /api/people-list, -settings, -save, -delete, -import (CSV rows), -adsearch, -adimport, -adlink, -adsync, -enable.
# DATA: people-db.json (encrypted with DPAPI, readable only on this server) and the backup people-db.bak.json. AD is only READ (LDAP search
# through New-AdEntry / DirectorySearcher) and only when 'Link with Active Directory' is on. No Microsoft Graph or Exchange calls.
# PERMISSION: this file does no permission check of its own; the server only lets signed-in portal users reach the handlers.
#
# Location of the people database file.
$script:PeopleFile = Join-Path $Root 'people-db.json'
# Loads the database. Returns { linkAd, people[] }. If the file does not exist an empty database is returned.
# A damaged file stops with an error (instead of silently starting empty) so nobody overwrites the data by mistake.
function Get-PeopleDb {
    $db = [ordered]@{ linkAd = $false; people = @() }
    if (Test-Path $script:PeopleFile) {
        try {
            $j = (Read-SecureText $script:PeopleFile) | ConvertFrom-Json
            $db.linkAd = [bool]$j.linkAd
            $db.people = @($j.people | Where-Object { $_ } | ForEach-Object { ConvertTo-PersonRow $_ })
        } catch { throw "people-db.json could not be read ($($_.Exception.Message)). Restore it from people-db.bak.json." }
    }
    $db
}
# Turns any object into a clean person record with all fields present (missing ones become empty text).
# 'enabled' is true unless it is explicitly false, so old records without the field count as active.
function ConvertTo-PersonRow($p) {
    [ordered]@{
        id = "$($p.id)"; first = "$($p.first)"; last = "$($p.last)"; username = "$($p.username)"; email = "$($p.email)"
        dept = "$($p.dept)"; phone = "$($p.phone)"; note = "$($p.note)"
        adSam = "$($p.adSam)"; adDn = "$($p.adDn)"; adSync = "$($p.adSync)"; updated = "$($p.updated)"; enabled = ($p.enabled -ne $false); changedBy = "$($p.changedBy)"
    }
}
# Saves the database: first copies the current file to people-db.bak.json (one step of undo), then writes the new content encrypted.
function Save-PeopleDb($db) {
    if (Test-Path $script:PeopleFile) { Copy-Item $script:PeopleFile (Join-Path $Root 'people-db.bak.json') -Force -ErrorAction SilentlyContinue }
    $out = [ordered]@{ linkAd = [bool]$db.linkAd; people = @($db.people) }
    Write-SecureText $script:PeopleFile ($out | ConvertTo-Json -Depth 5)   # v2.4.0: encrypted (DPAPI, this server only)
}
# Builds the standard answer of every people endpoint: the whole list, the link setting, whether AD is available on this PC,
# the signed-in AD account name and a message for the page.
function Get-PeopleReply($db, $msg) {
    @{ ok = $true; linkAd = [bool]$db.linkAd; adAvail = [bool]$script:AdAvail; adUser = $(if ($script:AdCred) { "$($script:AdCred.User)" } else { '' }); people = @($db.people); message = "$msg" }
}
# Stops with a clear error unless AD linking is switched on, this PC is domain-joined and an AD sign-in exists. Used before every AD action.
function Test-PeopleAd($db) {
    if (-not $db.linkAd) { throw 'Linking with Active Directory is off. Turn on "Link with Active Directory" at the top of this screen first.' }
    if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so AD linking is unavailable. The database still works without AD.' }
    if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections).' }
}
# Reads the wanted attributes from one AD search result row. The helper script block $g returns the first value or '' when the attribute is empty.
function Get-AdPersonProps($r) {
    $g = { param($n) if ($r.Properties[$n] -and $r.Properties[$n].Count) { "$($r.Properties[$n][0])" } else { '' } }
    [ordered]@{ sam = (& $g 'samaccountname'); first = (& $g 'givenname'); last = (& $g 'sn'); email = (& $g 'mail'); upn = (& $g 'userprincipalname')
        dept = (& $g 'department'); phone = (& $g 'telephonenumber'); dn = (& $g 'distinguishedname'); display = (& $g 'displayname') }
}
# Searches AD for user accounts. $filter is an extra LDAP filter part, $max the maximum number of results. Returns a list of simple records.
# The caller must pass user text through ConvertTo-LdapValue first (prevents LDAP filter injection).
function Find-AdPeople($filter, $max) {
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = $max; $ds.PageSize = 0
    # Only load the attributes we need - faster and less data from the domain controller.
    foreach ($p in 'samaccountname', 'givenname', 'sn', 'mail', 'userprincipalname', 'department', 'telephonenumber', 'distinguishedname', 'displayname') { [void]$ds.PropertiesToLoad.Add($p) }
    # Limit to real user accounts (not computers or contacts) and add the caller's filter.
    $ds.Filter = "(&(objectCategory=person)(objectClass=user)$filter)"
    @($ds.FindAll() | ForEach-Object { Get-AdPersonProps $_ })
}
# Current local time as text, used for the 'updated' and 'adSync' fields.
function Get-NowIso { (Get-Date).ToString('yyyy-MM-dd HH:mm') }

# Endpoint: /api/people-list - no input. Sends the whole database.
$ScreenHandlers['/api/people-list'] = { Send $ctx (Get-PeopleReply (Get-PeopleDb) '') }

# Endpoint: /api/people-settings - saves the 'Link with Active Directory' switch.
$ScreenHandlers['/api/people-settings'] = {
    # { linkAd:true|false } - linking with AD is optional; turning it off keeps the link details, they are just not used
    $db = Get-PeopleDb; $db.linkAd = [bool]$d.linkAd; Save-PeopleDb $db
    Send $ctx (Get-PeopleReply $db $(if ($db.linkAd) { 'Linking with Active Directory is on.' } else { 'Linking with Active Directory is off. The database works on its own.' }))
}

# Endpoint: /api/people-save - creates (id empty) or edits one person. Checks the required fields, the email format and that username
# and email are not used by another person (case-insensitive).
$ScreenHandlers['/api/people-save'] = {
    # { id (empty = new), first, last, username, email, dept, phone, note }
    $db = Get-PeopleDb
    $first = "$($d.first)".Trim(); $last = "$($d.last)".Trim(); $user = "$($d.username)".Trim(); $mail = "$($d.email)".Trim()
    if (-not $first) { throw 'Enter the first name.' }
    if (-not $last) { throw 'Enter the last name.' }
    if (-not $user) { throw 'Enter the username.' }
    # No spaces or the characters " < > in a username.
    if ($user -match '[\s"<>]') { throw 'The username cannot contain spaces or the characters " < >.' }
    # Simple email check: something@something.something, with no spaces, ; , < > or quotes.
    if ($mail -and $mail -notmatch '^[^@\s;,<>"]+@[^@\s;,<>"]+\.[^@\s;,<>"]+$') { throw "Not a valid email address: $mail" }
    $id = "$($d.id)"
    # Duplicate check - ignore the record being edited (same id).
    $dup = @($db.people | Where-Object { $_.username -ieq $user -and $_.id -ne $id })
    if ($dup.Count) { throw "The username $user is already in the database ($($dup[0].first) $($dup[0].last))." }
    if ($mail) { $dupM = @($db.people | Where-Object { $_.email -and $_.email -ieq $mail -and $_.id -ne $id }); if ($dupM.Count) { throw "The email $mail is already used by $($dupM[0].first) $($dupM[0].last)." } }
    $row = $null
    # Edit: find the record by id. New: create an empty record with a fresh GUID (32 hex characters) and add it to the list.
    if ($id) { $row = $db.people | Where-Object { $_.id -eq $id } | Select-Object -First 1; if (-not $row) { throw 'This person is no longer in the database (removed by someone else?). Refresh the list.' } }
    else { $row = ConvertTo-PersonRow @{ id = [guid]::NewGuid().ToString('n') }; $db.people = @($db.people) + @($row) }
    $row.first = $first; $row.last = $last; $row.username = $user; $row.email = $mail
    $row.dept = "$($d.dept)".Trim(); $row.phone = "$($d.phone)".Trim(); $row.note = "$($d.note)".Trim(); $row.updated = Get-NowIso
    # Active / Disabled is only changed when the page sent the field.
    if ($null -ne $d.enabled) { $row.enabled = [bool]$d.enabled }
    Save-PeopleDb $db
    Send $ctx (Get-PeopleReply $db "Saved $first $last.")
}

# Endpoint: /api/people-delete - removes the chosen records from this database only. The answer tells how many were removed.
$ScreenHandlers['/api/people-delete'] = {
    # { ids:[...] } - removes the records from THIS database only; never touches AD or Microsoft 365
    $db = Get-PeopleDb; $ids = @($d.ids | ForEach-Object { "$_" })
    $before = @($db.people).Count
    $db.people = @($db.people | Where-Object { $_.id -notin $ids })
    Save-PeopleDb $db
    Send $ctx (Get-PeopleReply $db "Removed $($before - @($db.people).Count) from the database (AD and Microsoft 365 are not touched).")
}

# Endpoint: /api/people-import - imports rows read from a CSV file by the page. A row whose username already exists is updated,
# otherwise a new person is added. Invalid rows are skipped; the first 5 skip reasons are shown in the message.
$ScreenHandlers['/api/people-import'] = {
    # { rows:[{first,last,username,email,dept,phone,note}] } - from a CSV file; a username already in the database is updated
    $db = Get-PeopleDb; $add = 0; $upd = 0; $skip = @()
    foreach ($r in @($d.rows)) {
        $u = "$($r.username)".Trim(); $f = "$($r.first)".Trim(); $l = "$($r.last)".Trim(); $m = "$($r.email)".Trim()
        if (-not $u -or -not $f -or -not $l) { $skip += "$u$f$l (first name, last name and username are needed)"; continue }
        if ($m -and $m -notmatch '^[^@\s;,<>"]+@[^@\s;,<>"]+\.[^@\s;,<>"]+$') { $skip += "$u (email $m is not valid)"; continue }
        $row = $db.people | Where-Object { $_.username -ieq $u } | Select-Object -First 1
        if ($row) { $upd++ } else { $row = ConvertTo-PersonRow @{ id = [guid]::NewGuid().ToString('n') }; $db.people = @($db.people) + @($row); $add++ }
        $row.first = $f; $row.last = $l; $row.username = $u; $row.email = $m
        # Optional columns only overwrite the stored value when the CSV cell is not empty.
        foreach ($k in 'dept', 'phone', 'note') { if ("$($r.$k)".Trim()) { $row[$k] = "$($r.$k)".Trim() } }
        $row.updated = Get-NowIso
    }
    Save-PeopleDb $db
    $msg = "Added $add, updated $upd." + $(if ($skip.Count) { " Skipped $($skip.Count): " + (($skip | Select-Object -First 5) -join '; ') } else { '' })
    Send $ctx (Get-PeopleReply $db $msg)
}

# Endpoint: /api/people-adsearch - searches AD (read only, max 50 results) and marks the users that are already in the database (inDb).
$ScreenHandlers['/api/people-adsearch'] = {
    # { q } - find AD users by name, username or email (read only)
    $db = Get-PeopleDb; Test-PeopleAd $db
    $q = "$($d.q)".Trim(); if ($q.Length -lt 2) { throw 'Type at least 2 characters to search AD.' }
    # Escape the search text for LDAP, then match the start of names/username/mail, or any part of the display name.
    $n = ConvertTo-LdapValue $q
    $list = Find-AdPeople "(|(sAMAccountName=$n*)(givenName=$n*)(sn=$n*)(displayName=*$n*)(mail=$n*)(userPrincipalName=$n*))" 50
    # Build a lookup of AD usernames that are already linked.
    $known = @{}; foreach ($p in $db.people) { if ($p.adSam) { $known[$p.adSam.ToLower()] = $true } }
    Send $ctx @{ ok = $true; results = @($list | ForEach-Object { $_.inDb = [bool]$known["$($_.sam)".ToLower()]; $_ }) }
}

# Endpoint: /api/people-adimport - for each chosen AD username (max 500) add the person, or update the existing one, and link it to AD.
$ScreenHandlers['/api/people-adimport'] = {
    # { sams:[...] } - add (or update) people from AD and link them
    $db = Get-PeopleDb; Test-PeopleAd $db; $add = 0; $upd = 0; $miss = @()
    foreach ($s in @($d.sams | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 500)) {
        $a = @(Find-AdPeople "(sAMAccountName=$(ConvertTo-LdapValue $s))" 1) | Select-Object -First 1
        if (-not $a) { $miss += $s; continue }
        # An existing record is matched by its AD link or by the same username.
        $row = $db.people | Where-Object { $_.adSam -ieq $a.sam -or $_.username -ieq $a.sam } | Select-Object -First 1
        if ($row) { $upd++ } else { $row = ConvertTo-PersonRow @{ id = [guid]::NewGuid().ToString('n') }; $db.people = @($db.people) + @($row); $add++ }
        # Copy the AD details; if there is no given name the display name is used, and if there is no mail the UPN is used as email.
        $row.username = $a.sam; $row.first = $(if ($a.first) { $a.first } else { $a.display }); $row.last = $a.last
        $row.email = $(if ($a.email) { $a.email } else { $a.upn }); if ($a.dept) { $row.dept = $a.dept }; if ($a.phone) { $row.phone = $a.phone }
        $row.adSam = $a.sam; $row.adDn = $a.dn; $row.adSync = Get-NowIso; $row.updated = Get-NowIso
    }
    Save-PeopleDb $db
    Send $ctx (Get-PeopleReply $db ("Imported from AD: added $add, updated $upd." + $(if ($miss.Count) { " Not found: $($miss -join ', ')" } else { '' })))
}

# Endpoint: /api/people-adlink - links one record to an AD account (sam), or removes the link when sam is empty.
# With copy:true the AD name, email, department and phone also replace the stored values. One AD account can only be linked once.
$ScreenHandlers['/api/people-adlink'] = {
    # { id, sam } - link one record to an AD account (sam empty = unlink). Copies the AD details only when copy:true.
    $db = Get-PeopleDb
    $row = $db.people | Where-Object { $_.id -eq "$($d.id)" } | Select-Object -First 1; if (-not $row) { throw 'This person is no longer in the database.' }
    $sam = "$($d.sam)".Trim()
    # Unlink: only clears the link fields, the person stays. No AD access is needed for this.
    if (-not $sam) { $row.adSam = ''; $row.adDn = ''; $row.adSync = ''; Save-PeopleDb $db; Send $ctx (Get-PeopleReply $db "$($row.first) $($row.last) is no longer linked to AD (the record stays)."); return }
    Test-PeopleAd $db
    $a = @(Find-AdPeople "(sAMAccountName=$(ConvertTo-LdapValue $sam))" 1) | Select-Object -First 1
    if (-not $a) { throw "No AD user with the username $sam." }
    $other = $db.people | Where-Object { $_.adSam -ieq $a.sam -and $_.id -ne $row.id } | Select-Object -First 1
    if ($other) { throw "$($a.sam) is already linked to $($other.first) $($other.last)." }
    $row.adSam = $a.sam; $row.adDn = $a.dn; $row.adSync = Get-NowIso
    if ($d.copy) { if ($a.first) { $row.first = $a.first }; if ($a.last) { $row.last = $a.last }; if ($a.email -or $a.upn) { $row.email = $(if ($a.email) { $a.email } else { $a.upn }) }; if ($a.dept) { $row.dept = $a.dept }; if ($a.phone) { $row.phone = $a.phone } }
    $row.updated = Get-NowIso
    Save-PeopleDb $db
    Send $ctx (Get-PeopleReply $db "$($row.first) $($row.last) is linked to the AD account $($a.sam).")
}

# Endpoint: /api/people-adsync - refreshes every linked person from AD. People whose AD account no longer exists are listed in the message.
$ScreenHandlers['/api/people-adsync'] = {
    # refresh every linked record from AD (first name, last name, email, department, phone)
    $db = Get-PeopleDb; Test-PeopleAd $db; $ok = 0; $gone = @()
    foreach ($row in @($db.people | Where-Object { $_.adSam })) {
        $a = @(Find-AdPeople "(sAMAccountName=$(ConvertTo-LdapValue $row.adSam))" 1) | Select-Object -First 1
        if (-not $a) { $gone += $row.adSam; continue }
        if ($a.first) { $row.first = $a.first }; if ($a.last) { $row.last = $a.last }
        if ($a.email -or $a.upn) { $row.email = $(if ($a.email) { $a.email } else { $a.upn }) }
        if ($a.dept) { $row.dept = $a.dept }; if ($a.phone) { $row.phone = $a.phone }
        $row.adDn = $a.dn; $row.adSync = Get-NowIso; $ok++
    }
    Save-PeopleDb $db
    Send $ctx (Get-PeopleReply $db ("Refreshed $ok linked people from AD." + $(if ($gone.Count) { " No longer in AD: $($gone -join ', ')" } else { '' })))
}

# Endpoint: /api/people-enable - marks the chosen people Active or Disabled in this database only. Records who made the change.
$ScreenHandlers['/api/people-enable'] = {
    # v1.98.10: { ids:[...], enabled:true|false } - mark people Active or Disabled in THIS database (AD and Microsoft 365 are not touched)
    $db = Get-PeopleDb; $ids = @($d.ids | ForEach-Object { "$_" }); $on = [bool]$d.enabled; $n = 0
    if (-not $ids.Count) { throw 'Select at least one person.' }
    foreach ($row in $db.people) { if ($row.id -in $ids -and $row.enabled -ne $on) { $row.enabled = $on; $row.updated = Get-NowIso; $row.changedBy = "$($script:SessUser.name)"; $n++ } }
    Save-PeopleDb $db
    Send $ctx (Get-PeopleReply $db ("$(if ($on) { 'Enabled' } else { 'Disabled' }) $n $(if ($n -eq 1) { 'person' } else { 'people' }) in the database (AD and Microsoft 365 are not touched)."))
}

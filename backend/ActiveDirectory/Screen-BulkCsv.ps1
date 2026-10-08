# Screen-BulkCsv.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Bulk & report
# Screen version: 2.0.0   (changes ONLY when this screen changes - not with every release)

# Step 1 (/api/bulk-resolve) only READS: every row is matched to exactly one AD account, nothing is changed.
# Step 2 (/api/bulk-apply) changes only the accounts that step 1 matched, by their exact username.

# ==== OVERVIEW ====
# Screen 'Bulk & report': take a list of users (from a CSV pasted/loaded in the browser), find them in on-premises AD, show a status report,
# and optionally apply ONE action to all matched users (unlock, enable, disable, add to a group, set account expiry).
# Endpoints registered below:
#   /api/bulk-resolve     step 1: match every input row to AD account(s) - read only
#   /api/bulk-groupsearch search groups by text - read only
#   /api/bulk-groupcheck  which users are already members of a chosen group - read only
#   /api/bulk-apply       step 2: apply the chosen action to the matched usernames (this one changes AD)
# Uses on-premises AD only (DirectorySearcher/ADSI with the AD sign-in $script:AdCred). Each change is written to the AD log (Write-AdLog).
# Limit: 500 users per request. Who may use it: any signed-in portal user allowed to open this screen who has signed in to AD.
#
# Searches AD for user objects with an LDAP filter. $filter = LDAP filter, $max = maximum number of results. Returns an array of search results.
function Find-AdUsersBy($filter, $max) {
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = $max
    $ds.Filter = $filter
    foreach ($p in 'distinguishedname', 'samaccountname') { [void]$ds.PropertiesToLoad.Add($p) }
    @($ds.FindAll())
}

# Stops with a clear message if the PC is not domain joined or nobody has signed in to on-premises AD yet.
function Test-BkAd {
    if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so on-premises AD is unavailable.' }
    if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
}

# Input: $sam (username). Returns a hashtable with enabled, locked, expires, expired, modified, pwdSet and upn as display text ('-' if user not found).
# Status, lock-out, account expiry, password last set and last modified time of one account (read only). Also used by Export report.
function Get-BkInfo($sam) {
    $o = @{ enabled = '-'; locked = '-'; expires = '-'; expired = $false; modified = '-'; pwdSet = '-'; upn = '' }
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry)
    $ds.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $sam)))"
    foreach ($p in 'useraccountcontrol', 'accountexpires', 'whenchanged', 'lockouttime', 'msds-user-account-control-computed', 'pwdlastset', 'userprincipalname') { [void]$ds.PropertiesToLoad.Add($p) }
    $u = $ds.FindOne()
    if (-not $u) { return $o }
    $pr = $u.Properties
    # userAccountControl bit 2 (value 2) = account disabled.
    $uac = [int]$pr['useraccountcontrol'][0]
    $o.enabled = if ($uac -band 2) { 'Disabled' } else { 'Enabled' }
    # Lock-out: the computed attribute bit 0x10 (LOCKOUT) is the reliable flag; if AD does not return it fall back to lockoutTime > 0.
    if ($pr['msds-user-account-control-computed'].Count -gt 0) { $o.locked = if ([int]$pr['msds-user-account-control-computed'][0] -band 0x10) { 'Yes' } else { 'No' } }
    elseif ($pr['lockouttime'].Count -gt 0) { $o.locked = if ([int64]$pr['lockouttime'][0] -gt 0) { 'Yes' } else { 'No' } }
    else { $o.locked = 'No' }
    # accountExpires: 0 or the max Int64 value both mean 'never expires'. Otherwise it is a Windows FILETIME.
    $ae = if ($pr['accountexpires'].Count -gt 0) { [int64]$pr['accountexpires'][0] } else { [int64]0 }
    if ($ae -eq 0 -or $ae -eq [int64]::MaxValue) { $o.expires = 'Never' }
    else {
        $at = [DateTime]::FromFileTime($ae)
        $o.expires = '{0:yyyy-MM-dd}' -f $at.AddSeconds(-1)   # AD stores the start of the next day; show the last day the account works, like AD Users and Computers
        $o.expired = ($at -lt (Get-Date))
    }
    if ($pr['userprincipalname'].Count -gt 0) { $o.upn = "$($pr['userprincipalname'][0])" }
    # pwdLastSet = 0 means the user must change the password at next sign-in.
    if ($pr['pwdlastset'].Count -gt 0) { $pl = [int64]$pr['pwdlastset'][0]; $o.pwdSet = if ($pl -gt 0) { '{0:yyyy-MM-dd HH:mm}' -f [DateTime]::FromFileTime($pl) } else { 'Must change at next sign-in' } }
    if ($pr['whenchanged'].Count -gt 0) {
        # whenChanged comes back in UTC; convert to local time for display.
        $wc = $pr['whenchanged'][0]
        if ($wc -is [datetime]) { if ($wc.Kind -ne 'Local') { $wc = $wc.ToLocalTime() }; $o.modified = '{0:yyyy-MM-dd HH:mm}' -f $wc }
    }
    $o
}

# Converts a found group into a simple object. Input: a search result $g. Returns dn, name, sam, type, scope, mail, protected, desc.
# Groups of every kind: security, mail-enabled security and distribution
function Get-BkGroupInfo($g) {
    $pr = $g.Properties
    $gt = [int64]$pr['grouptype'][0]
    # groupType flags: 0x80000000 = security group (otherwise distribution). Scope bits: 8 = Universal, 4 = Domain local, 2 = Global.
    $sec = ($gt -band 0x80000000L) -ne 0
    $mail = if ($pr['mail'].Count -gt 0) { "$($pr['mail'][0])" } else { '' }
    $type = if ($sec -and $mail) { 'Mail-enabled security' } elseif ($sec) { 'Security' } else { 'Distribution' }
    $scope = if ($gt -band 8) { 'Universal' } elseif ($gt -band 4) { 'Domain local' } elseif ($gt -band 2) { 'Global' } else { '' }
    # adminCount = 1 marks groups protected by AD (administrative groups); the screen asks for extra confirmation before adding people to them.
    $prot = ($pr['admincount'].Count -gt 0 -and [int]$pr['admincount'][0] -eq 1)
    [pscustomobject]@{
        dn = "$($pr['distinguishedname'][0])"; name = "$($pr['cn'][0])"; sam = "$($pr['samaccountname'][0])"
        type = $type; scope = $scope; mail = $mail; protected = $prot
        desc = $(if ($pr['description'].Count -gt 0) { "$($pr['description'][0])" } else { '' })
    }
}
# Creates a search object for groups with the attributes this screen needs. $filter = LDAP filter, $max = result limit.
function New-BkGroupSearcher($filter, $max) {
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = $max; $ds.Filter = $filter
    foreach ($p in 'distinguishedname', 'grouptype', 'samaccountname', 'cn', 'description', 'mail', 'admincount') { [void]$ds.PropertiesToLoad.Add($p) }
    $ds
}
# Finds one group by its distinguished name (DN). Throws if none is chosen or it does not exist. Returns the search result.
# The exact group chosen on screen (by its distinguished name)
function Get-BkGroup($dn) {
    if (-not "$dn") { throw 'Choose a group first.' }
    $g = (New-BkGroupSearcher "(&(objectCategory=group)(distinguishedName=$(ConvertTo-LdapValue $dn)))" 2).FindOne()
    if (-not $g) { throw 'That group was not found in on-premises AD. Search for it again.' }
    $g
}

# Fills a result row $r (display fields) from a found account $ures, then adds status data from Get-BkInfo. Read only.
# Fill one result row from a found account
function Set-BkRow($r, $ures) {
    $ue = $ures.GetDirectoryEntry()
    $r.sam = "$($ures.Properties['samaccountname'][0])"
    $x = "$($ue.Properties['displayName'].Value)"; if ($x) { $r.name = $x }
    $x = "$($ue.Properties['userPrincipalName'].Value)"; if ($x) { $r.upn = $x }
    $x = "$($ue.Properties['mail'].Value)"; if ($x) { $r.mail = $x }
    $x = "$($ue.Properties['mobile'].Value)"; if ($x) { $r.mobile = $x }
    $x = @($ue.Properties['description'] | ForEach-Object { "$_" }) -join ' '; if ($x) { $r.desc = $x }
    $i = Get-BkInfo $r.sam
    $r.enabled = $i.enabled; $r.locked = $i.locked; $r.expires = $i.expires; $r.expired = $i.expired; $r.modified = $i.modified; $r.pwdSet = $i.pwdSet
}

# POST /api/bulk-resolve - input: $d.rows, each with sam, upn, email, desc (any of them). Sends back $results: one row per matched account,
# with found = Yes / No / Several / Conflict / Error and a note explaining why nothing can be changed.
# Step 1 for the Bulk & report screen. Read only.
# A username / UPN / email must match exactly one account. A description that matches several accounts lists every one of them
# (up to 50, marked multi) so they can be reported on; the screen only lets them be changed after the operator allows it.
$ScreenHandlers['/api/bulk-resolve'] = {
        Test-BkAd
        $rows = @($d.rows)
        if ($rows.Count -eq 0) { throw 'The list has no users.' }
        if ($rows.Count -gt 500) { throw 'Up to 500 lines at a time. Split the list and look up again.' }
        # Maximum number of accounts listed for one description that matches many accounts.
        $cap = 50
        $results = New-Object System.Collections.ArrayList; $n = 0
        foreach ($row in $rows) {
            $n++
            $inSam = "$($row.sam)".Trim(); $inUpn = "$($row.upn)".Trim(); $inMail = "$($row.email)".Trim(); $inDesc = "$($row.desc)".Trim()
            # Text shown in the 'input' column: the first value the row has.
            $shown = (@($inSam, $inUpn, $inMail, $inDesc) | Where-Object { $_ } | Select-Object -First 1)
            # Script block that makes a new empty result row (so a description match can create many rows).
            $mk = { [ordered]@{ n = $n; input = "$shown"; found = 'No'; matchedBy = '-'; multi = $false; multiN = 0; sam = '-'; name = '-'; upn = '-'; mail = '-'; mobile = '-'; desc = '-'; enabled = '-'; locked = '-'; expires = '-'; expired = $false; pwdSet = '-'; modified = '-'; note = '' } }
            $r = & $mk
            try {
                $hits = @{}   # distinct accounts found through username / UPN / email
                $how = @()
                # Try username, UPN and email one by one. Each must find at most one account; the accounts found are collected in $hits (by username).
                foreach ($pair in @(@('Username', $inSam), @('UPN', $inUpn), @('Email', $inMail))) {
                    $val = $pair[1]; if (-not $val) { continue }
                    $v = ConvertTo-LdapValue $val
                    $found = @(Find-AdUsersBy "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$v)(userPrincipalName=$v)(mail=$v)))" 3)
                    # Second try: for an address that matched nothing, use the part before the @ as the username.
                    if (-not $found.Count -and $val -match '@') {   # john@contoso.com -> username john
                        $local = ($val -split '@')[0]
                        if ($local) { $found = @(Find-AdUsersBy "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $local)))" 3) }
                    }
                    if ($found.Count -gt 1) { $r.found = 'Several'; $r.note = "$($pair[0]) '$val' matches more than one account - nothing can be changed for this row."; break }
                    if ($found.Count -eq 1) { $s = "$($found[0].Properties['samaccountname'][0])"; $hits[$s.ToLower()] = $found[0]; $how += $pair[0] }
                }
                # Decide the row: several matches -> refuse; different accounts for sam/upn/email -> conflict; exactly one -> fill the row; none -> try the description.
                if ($r.found -eq 'Several') { }
                elseif ($hits.Count -gt 1) { $r.found = 'Conflict'; $r.note = 'The username, UPN and email in this row belong to different accounts - nothing can be changed for this row.' }
                elseif ($hits.Count -eq 1) { $r.found = 'Yes'; $r.matchedBy = ($how | Select-Object -Unique) -join ' + '; Set-BkRow $r @($hits.Values)[0] }
                # Description search: exact match first, then 'contains' (*text*). Asks for cap+1 results to know if there are more than the cap.
                elseif ($inDesc) {
                    $dv = ConvertTo-LdapValue $inDesc
                    $found = @(Find-AdUsersBy "(&(objectCategory=person)(objectClass=user)(description=$dv))" ($cap + 1))
                    $via = 'Description (exact)'
                    if (-not $found.Count) { $found = @(Find-AdUsersBy "(&(objectCategory=person)(objectClass=user)(description=*$dv*))" ($cap + 1)); $via = 'Description (contains)' }
                    if ($found.Count -eq 1) { $r.found = 'Yes'; $r.matchedBy = $via; Set-BkRow $r $found[0] }
                    elseif ($found.Count -gt 1) {
                        # Several accounts share this description: add one row per account (marked multi); the screen only allows changing them after the operator allows it.
                        $more = $found.Count -gt $cap; $list = @($found | Select-Object -First $cap)
                        foreach ($f in $list) {
                            $x = & $mk; $x.found = 'Yes'; $x.matchedBy = $via; $x.multi = $true; $x.multiN = $list.Count
                            try { Set-BkRow $x $f } catch { $x.found = 'Error'; $x.note = Get-ErrMsg $_ }
                            [void]$results.Add([pscustomobject]$x)
                        }
                        if ($more) { $x = & $mk; $x.found = 'Several'; $x.note = "More than $cap accounts have '$inDesc' in their description - only the first $cap are listed. Type more of the description to narrow it."; [void]$results.Add([pscustomobject]$x) }
                        continue
                    }
                    else { $r.note = 'No account has this username, UPN, email or description.' }
                } else { $r.note = 'No account has this username, UPN or email.' }
            } catch { $r.found = 'Error'; $r.note = Get-ErrMsg $_ }
            [void]$results.Add([pscustomobject]$r)
        }
        Send $ctx @{ ok = $true; results = @($results.ToArray()) }
}

# Find groups to add the users to (read only). All kinds: security, mail-enabled security, distribution.
# POST /api/bulk-groupsearch - input: $d.q (at least 2 characters). Sends up to 30 matching groups (name, mail, sam or display name contains the text).
$ScreenHandlers['/api/bulk-groupsearch'] = {
        Test-BkAd
        $q = "$($d.q)".Trim(); $out = @()
        if ($q.Length -ge 2) {
            $n = ConvertTo-LdapValue $q
            $ds = New-BkGroupSearcher "(&(objectCategory=group)(|(sAMAccountName=*$n*)(cn=*$n*)(displayName=*$n*)(mail=*$n*)))" 30
            foreach ($g in @($ds.FindAll())) { $out += Get-BkGroupInfo $g }
        }
        Send $ctx @{ ok = $true; groups = @($out | Sort-Object name) }
}

# Which of the matched users are already in the chosen group (read only)
# POST /api/bulk-groupcheck - input: $d.groupDn and $d.sams (usernames). Sends members = @{username = Yes / No / Unknown} and the group info.
$ScreenHandlers['/api/bulk-groupcheck'] = {
        Test-BkAd
        $g = Get-BkGroup "$($d.groupDn)"; $ge = $g.GetDirectoryEntry()
        $sams = @($d.sams | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($sams.Count -gt 500) { throw 'Up to 500 users at a time.' }
        $m = @{}
        foreach ($sam in $sams) {
            try {
                $u = Find-AdObject 'user' $sam
                # IsMember asks AD whether the user is in the group; any error is reported as 'Unknown' instead of stopping the whole check.
                $m[$sam] = if (-not $u) { 'Unknown' } elseif ([bool]$ge.Invoke('IsMember', $u.GetDirectoryEntry().Path)) { 'Yes' } else { 'No' }
            } catch { $m[$sam] = 'Unknown' }
        }
        Send $ctx @{ ok = $true; members = $m; group = (Get-BkGroupInfo $g) }
}

# POST /api/bulk-apply - THE ONLY endpoint here that changes AD. Input: $d.action (unlock / enable / disable / group / expiry), $d.sams (exact usernames from step 1),
# and per action: $d.groupDn + $d.confirmProtected (group), $d.expiryMode never/days/date + $d.expiryDays / $d.expiryDate (expiry).
# Sends one result row per user (found, action done, current status, message).
$ScreenHandlers['/api/bulk-apply'] = {
        Test-BkAd
        $act = "$($d.action)"
        if ($act -notin 'unlock', 'enable', 'disable', 'group', 'expiry') { throw 'Unknown action.' }
        $sams = @($d.sams | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($sams.Count -eq 0) { throw 'No users to change.' }
        if ($sams.Count -gt 500) { throw 'Up to 500 users at a time.' }

        # Prepare the action once before the loop: for 'group' look up the group (protected admin groups need confirmation).
        $logWhat = "Bulk CSV account action: $act"; $gEntry = $null; $gInfo = $null
        if ($act -eq 'group') {
            $g = Get-BkGroup "$($d.groupDn)"; $gInfo = Get-BkGroupInfo $g
            if ($gInfo.protected -and -not [bool]$d.confirmProtected) { throw "'$($gInfo.name)' is a protected administrative group. Confirm it on screen before adding people to it." }
            $gEntry = $g.GetDirectoryEntry()
            $logWhat = "Bulk CSV add to group: $($gInfo.name) ($($gInfo.type))"
        }
        # Prepare the expiry value: 'never' = 0; otherwise a date in the future. Stored as a FILETIME of the NEXT day's start so the account works to the end of the chosen day.
        $expFt = $null; $expDay = $null; $expLabel = '-'
        if ($act -eq 'expiry') {
            $mode = "$($d.expiryMode)"
            if ($mode -eq 'never') { $expFt = '0'; $expDay = 'Never'; $expLabel = 'Removed (never expires)' }
            elseif ($mode -eq 'days' -or $mode -eq 'date') {
                $day = if ($mode -eq 'days') { (Get-Date).Date.AddDays([int]$d.expiryDays) } else { [datetime]::ParseExact("$($d.expiryDate)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
                if ($day -lt (Get-Date).Date) { throw 'The expiry date cannot be in the past.' }
                $expFt = "$($day.AddDays(1).ToFileTime())"   # AD convention: the account works until the END of the chosen day
                $expDay = '{0:yyyy-MM-dd}' -f $day; $expLabel = "End of $expDay"
            } else { throw 'Choose the new expiry date.' }
            $logWhat = "Bulk CSV set account expiry: $expLabel"
        }

        $results = @()
        foreach ($sam in $sams) {
            # One result row per username. Each user is looked up again by exact username - a description or other text is never used to change an account.
            $r = [ordered]@{ user = $sam; found = 'No'; action = '-'; enabled = '-'; locked = '-'; expires = '-'; modified = '-'; member = '-'; message = '' }
            $logGroup = '-'; $logExp = '-'
            try {
                # Safety: the account found must have exactly the requested username, otherwise it is treated as not found.
                $ures = Find-AdObject 'user' $sam
                if (-not $ures -or "$($ures.Properties['samaccountname'][0])" -ine $sam) { $r.message = 'User not found in on-premises AD' }
                else {
                    $r.found = 'Yes'; $ue = $ures.GetDirectoryEntry()
                    try {
                        switch ($act) {
                            # Unlock = set lockoutTime to 0.
                            'unlock' { $ue.Properties['lockoutTime'].Value = 0; $ue.CommitChanges(); $r.action = 'Unlocked' }
                            'enable' {
                                # Enable = clear bit 2 of userAccountControl (only if currently disabled).
                                $uac = [int]$ue.Properties['userAccountControl'].Value
                                if ($uac -band 2) { $ue.Properties['userAccountControl'].Value = ($uac -band (-bnot 2)); $ue.CommitChanges(); $r.action = 'Enabled now' } else { $r.action = 'Already enabled' }
                            }
                            'disable' {
                                # Disable: strip DOMAIN\ or @domain from the signed-in name so we can refuse to disable our own account.
                                $me = ("$($script:AdCred.User)" -replace '^.*\\', '') -replace '@.*$', ''
                                if ($sam -ieq $me) { throw 'You cannot disable the account you are signed in with.' }
                                $uac = [int]$ue.Properties['userAccountControl'].Value
                                if ($uac -band 2) { $r.action = 'Already disabled' } else { $ue.Properties['userAccountControl'].Value = ($uac -bor 2); $ue.CommitChanges(); $r.action = 'Disabled now' }
                            }
                            # Add to group: skip if already a member.
                            'group' {
                                if ([bool]$gEntry.Invoke('IsMember', $ue.Path)) { $r.action = 'Already a member' }
                                else { $gEntry.Invoke('Add', $ue.Path); $r.action = 'Added' }
                                $r.member = 'Yes'; $logGroup = $r.action
                            }
                            # Set expiry: skip when the account already has that date.
                            'expiry' {
                                $cur = (Get-BkInfo $sam).expires
                                if ($cur -eq $expDay) { $r.action = 'Already this date' }
                                else { $ue.Properties['accountExpires'].Value = $expFt; $ue.CommitChanges(); $r.action = $(if ($expDay -eq 'Never') { 'Expiry removed' } else { 'Expiry set' }) }
                                $logExp = "$expLabel (was $cur)"
                            }
                        }
                    } catch {
                        $r.action = 'Failed'; $r.message = Get-ErrMsg $_
                        if ($act -eq 'group') { $logGroup = 'Failed'; $r.member = '-' }
                        if ($act -eq 'expiry') { $logExp = 'Failed' }
                    }
                    # Read the status again after the change so the report shows the real current values.
                    $i = Get-BkInfo $sam
                    $r.enabled = $i.enabled; $r.locked = $i.locked; $r.expires = $i.expires; $r.modified = $i.modified
                }
            } catch { $r.message = Get-ErrMsg $_ }
            $en = if ($act -in 'unlock', 'enable', 'disable') { $r.action } else { '-' }
            # Write one line per user to the AD log (who, what, result).
            Write-AdLog @{ user = $sam; group = $logGroup; expiry = $logExp; message = $r.message; enabled = $en; pwReset = '-'; upn = '-' } $logWhat
            $results += [pscustomobject]$r
        }
        Send $ctx @{ ok = $true; results = $results; group = $gInfo }
}

# Screen-OnPremAd.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: On-premises AD
# Screen version: 2.8.1   (changes ONLY when this screen changes - not with every release)


# ==== OVERVIEW ====
# Screen 'On-premises AD': look up users in on-premises Active Directory and change them (password reset, unlock/enable/disable, groups, expiry, UPN, names).
# Endpoints registered below:
#   /api/onprem-suffixes  UPN domains for the UPN-change drop-down (read only)
#   /api/onprem-search    status report for a list of usernames incl. group membership (read only)
#   /api/onprem           the main CHANGE endpoint: password, groups, expiry, enable, UPN, names (changes AD, optionally Entra password)
#   /api/usersearch      find users by text for the picker (read only)
#   /api/groupsearch    find security groups by text (read only)
#   /api/onprem-account   unlock / enable / disable a list of users
#   /api/onprem-userinfo  current names/description/email of one user (read only)
#   /api/suggest         type-ahead suggestions from AD, Microsoft 365 (Graph) and the People list (read only)
#   /api/audit-userfind   find a user in AD or Entra for the Audit & event logs screen (read only)
# Uses: on-premises AD (DirectorySearcher/ADSI with the AD sign-in $script:AdCred); Microsoft Graph (Get-MgUser, Update-MgUser, Invoke-MgGraphRequest)
# only for the optional cloud password sync, the suggestions and the Entra user search.
# Writes the monthly audit file logs\onprem-audit-yyyy-MM.csv (Write-AdLog). Passwords are shown once to the operator and kept only in memory.
# Who may use it: any signed-in portal user allowed to open this screen who has signed in to AD (and to Microsoft 365 for the cloud parts).
#
# Finds users for a report. $term = text typed, $max = result limit. Order: exact username/UPN/email, then the part before @ as username, then description.
function Find-AdReportUsers($term, $max) {
    $n = ConvertTo-LdapValue $term
    # One more than $max, so the caller can tell that there are more results than shown.
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = $max + 1
    foreach ($p in 'distinguishedname', 'samaccountname') { [void]$ds.PropertiesToLoad.Add($p) }
    $script:ReportVia = 'Username/Email'
    $ds.Filter = "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$n)(userPrincipalName=$n)(mail=$n)))"
    $res = @($ds.FindAll())
    if (-not $res.Count -and "$term" -match '@') {
        $local = ("$term" -split '@')[0]
        if ($local) { $ds.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $local)))"; $res = @($ds.FindAll()) }
    }
    if (-not $res.Count) {
        $script:ReportVia = 'Description'
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(description=*$n*))"
        $res = @($ds.FindAll())
    }
    $res
}

# Finds SECURITY groups whose name, cn or display name contains $q. 1.2.840.113556.1.4.803 is the 'bit AND' matching rule; 2147483648 = security flag.
# Returns an array of search results, at most $max.
function Find-AdGroups($q, $max) {
    $n = ConvertTo-LdapValue $q
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry)
    $ds.Filter = "(&(objectCategory=group)(groupType:1.2.840.113556.1.4.803:=2147483648)(|(sAMAccountName=*$n*)(cn=*$n*)(displayName=*$n*)))"
    $ds.SizeLimit = $max
    foreach ($p in 'distinguishedname', 'grouptype', 'samaccountname', 'cn', 'description') { [void]$ds.PropertiesToLoad.Add($p) }
    @($ds.FindAll())
}

# Turns a typed group name into exactly one group. Tries an exact match, then a 'contains' search. Returns the group, $null if none,
# and throws (listing up to 5 names) if several groups match.
function Resolve-AdGroup($name) {
    $g = Find-AdObject 'group' $name
    if ($g) { return $g }
    $all = @(Find-AdGroups $name 6)
    if ($all.Count -eq 1) { return $all[0] }
    if ($all.Count -gt 1) { throw ("'$name' matches several groups (" + ((@($all | Select-Object -First 5 | ForEach-Object { "$($_.Properties['cn'][0])" })) -join ', ') + ") - type more of the name or pick one from the list.") }
    $null
}

# Also resets the password of the matching Entra (cloud) account. Input: $sam, $upns (UPN candidates), $pw new password, $force = must change at next sign-in.
# Needs Microsoft Graph with permission to update users (User.ReadWrite.All or similar). Returns a text result for the report.
function Set-CloudPassword($sam, $upns, $pw, $force) {
    $props = 'Id', 'UserPrincipalName', 'OnPremisesSyncEnabled', 'OnPremisesSamAccountName'
    $u = $null
    # First try the UPNs; if no cloud user is found, search by the synced on-premises username.
    foreach ($x in @($upns)) { if ($x -and -not $u) { try { $u = Get-MgUser -UserId "$x" -Property $props -ErrorAction Stop } catch {} } }
    if (-not $u -and $sam) {
        # Single quotes are doubled so they are safe inside the OData filter. ConsistencyLevel eventual is required by Graph for this filter.
        $q = "$sam" -replace "'", "''"
        $f = @(Get-MgUser -Filter "onPremisesSamAccountName eq '$q'" -ConsistencyLevel eventual -CountVariable cnt -Property $props -Top 5 -ErrorAction SilentlyContinue)
        if ($f.Count -eq 1) { $u = $f[0] } elseif ($f.Count -gt 1) { return 'Failed: several cloud accounts match this username' }
    }
    if (-not $u) { return 'Not found in Entra' }
    try {
        Update-MgUser -UserId $u.Id -PasswordProfile @{ Password = $pw; ForceChangePasswordNextSignIn = [bool]$force }
        "Reset in Entra ($($u.UserPrincipalName))"
    } catch {
        $m = Get-ErrMsg $_
        # Synced accounts normally cannot be changed in Entra; the on-premises password arrives there through password hash sync.
        if ($u.OnPremisesSyncEnabled) { "Failed: $m - this account is synced from on-premises AD, so the new password reaches Entra by password hash sync within a few minutes." }
        else { "Failed: $m" }
    }
}

# Appends one line to the monthly audit CSV. $r = result hashtable (user, group, expiry, message, enabled, pwReset, upn, cloud, pwNever, name), $group = text about groups.
# The password itself is never written. The header is upgraded automatically when an older file has fewer columns.
function Write-AdLog($r, $group) {
    $f = Join-Path $LogDir ('onprem-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    $hdr = 'Time,WindowsUser,Target,Group,GroupResult,AccountExpiry,Message,AccountEnabled,PasswordReset,AdAccount,UpnChange,CloudPassword,PasswordNeverExpires,NameChange'
    if (-not (Test-Path $f)) { $hdr | Out-File $f -Encoding utf8 }
    else { $c = @(Get-Content $f -Encoding UTF8); if ($c.Count -gt 0 -and $c[0] -notlike '*NameChange') { $c[0] = $hdr; $c | Set-Content $f -Encoding UTF8 } }
    # Columns: time, Windows user running the tool, target, group info, expiry, message, ... then every value is quoted for CSV.
    $vals = @(('{0:s}' -f (Get-Now)), [Security.Principal.WindowsIdentity]::GetCurrent().Name, $r.user, $group, $r.group, $r.expiry, $r.message, $r.enabled, $r.pwReset, $script:AdCred.User, $r.upn, $r.cloud, $r.pwNever, $r.name) |
        ForEach-Object { ConvertTo-CsvCell $_ }
    ($vals -join ',') | Add-Content $f
}

# POST /api/onprem-suffixes - no input. Sends the UPN domains available (domain, forest root, extra UPN suffixes, and the signed-in M365 user's domain as a suggestion).
$ScreenHandlers['/api/onprem-suffixes'] = {
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        $list = New-Object System.Collections.Generic.List[string]
        # Helper: converts a naming context like DC=corp,DC=com to corp.com.
        $toDns = { param($nc) ((("$nc" -split ',') | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.') }
        $dom = & $toDns $script:AdCred.Dnc; if ($dom) { $list.Add($dom) }
        try {
            $rd = Get-RootDse   # v2.8.1: chosen DC
            $rootDom = & $toDns "$($rd.Properties['rootDomainNamingContext'].Value)"; if ($rootDom) { $list.Add($rootDom) }
            $cfg = "$($rd.Properties['configurationNamingContext'].Value)"
            $pe = New-AdEntry "CN=Partitions,$cfg"
            foreach ($x in $pe.Properties['uPNSuffixes']) { if ("$x") { $list.Add("$x") } }
        } catch {}
        $sug = $null; if ("$script:WhoUpn" -match '@') { $sug = ("$script:WhoUpn" -split '@')[-1]; $list.Add($sug) }
        Send $ctx @{ ok = $true; suffixes = @($list | Select-Object -Unique); suggest = $sug; domain = $dom }
}

# POST /api/onprem-search - read only. Input: $d.usernames (list), $d.group (optional group names to check membership), $d.fields (which fields to match: sam/upn/mail).
# Sends one result row per name (found, status, UPN, mail, phone, description, membership in the chosen groups) plus notes about groups.
$ScreenHandlers['/api/onprem-search'] = {
        if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so the on-premises lookup is unavailable.' }
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        $groupNames = Get-GroupList $d.group; $group = $groupNames -join ', '; $gEntries = @(); $notes = @()
        foreach ($gn in $groupNames) {
            $g = Find-AdObject 'group' $gn
            if (-not $g) { $notes += "Group '$gn' was not found in on-premises AD." }
            # groupType is a negative number for security groups (high bit set); zero or positive = distribution group.
            elseif ([int]$g.Properties['grouptype'][0] -ge 0) { $notes += "'$gn' is a distribution group, not a security group." }
            else { $gEntries += [pscustomobject]@{ name = $gn; entry = $g.GetDirectoryEntry() } }
        }
        $groupNote = $notes -join ' '
        $results = @()
        # $script:FindFields tells Find-AdObject (server.ps1) which attributes to use for the exact look-up. 'none' = only name/description ticked.
        $script:FindFields = @(@($d.fields) | ForEach-Object { "$_" } | Where-Object { $_ -in 'sam', 'upn', 'mail' })
        if (@($d.fields | Where-Object { "$_" }).Count -and -not $script:FindFields.Count) { $script:FindFields = @('none') }   # v1.98.45: no 'fields' sent (@(\$null) has 1 item) is NOT 'only name / description'   # only name / description ticked: no exact look-up
        foreach ($name in @($d.usernames | ForEach-Object { "$_".Trim() } | Where-Object { $_ })) {
            $r = [ordered]@{ user = $name; found = 'No'; sam = '-'; display = '-'; mail = '-'; mobile = ''; phone = ''; desc = '-'; upn = '-'; upnMatch = '-'; enabled = '-'; locked = '-'; expires = '-'; pwdSet = '-'; pwNever = '-'; members = @(); note = '' }
            try {
                # Look the user up, then read status via Get-OnPremStatus and details from the directory entry.
                $ures = Find-AdObject 'user' $name; $via = $script:FindVia
                if ($ures) {
                    $sam = "$($ures.Properties['samaccountname'][0])"
                    $o = Get-OnPremStatus $sam $null $sam
                    $r.found = $o.found; $r.enabled = $o.enabled; $r.locked = $o.locked; $r.expires = $o.expires; $r.pwdSet = $o.pwdSet; $r.pwNever = $o.pwNever; $r.note = $o.note
                    $curUpn = if ($ures.Properties['userprincipalname'].Count -gt 0) { "$($ures.Properties['userprincipalname'][0])" } else { '' }
                    $r.upn = if ($curUpn) { $curUpn } else { '(none)' }
                    # If a UPN was typed, tell whether the account's real UPN is the same (maybe it was found through its username only).
                    if ($name -match '@') {
                        $r.upnMatch = if ($curUpn -ieq $name) { 'Yes' } else { 'No' }
                        if ($r.upnMatch -eq 'No') { $r.note = (("Matched by username '$sam'. Its on-premises UPN is $($r.upn), not $name. " + $r.note).Trim()) }
                    }
                    $ue = $ures.GetDirectoryEntry()
                    $r.sam = $sam
                    $dn = "$($ue.Properties['displayName'].Value)"; if ($dn) { $r.display = $dn }
                    $ml = "$($ue.Properties['mail'].Value)"; if ($ml) { $r.mail = $ml }
                    $r.mobile = "$($ue.Properties['mobile'].Value)"; $r.phone = "$($ue.Properties['telephoneNumber'].Value)"   # v2.2.1
                    $dsc = @($ue.Properties['description'] | ForEach-Object { "$_" }) -join ' '; if ($dsc) { $r.desc = $dsc }
                    # Group changes: add or remove the user; 'Already a member' / 'Not a member' are not errors.
                    foreach ($ge in $gEntries) {
                        # Membership per chosen group: Yes / No / Unknown (error).
                        $m = try { if ($ge.entry.Invoke('IsMember', $ue.Path)) { 'Yes' } else { 'No' } } catch { 'Unknown' }
                        $r.members += [pscustomobject]@{ group = $ge.name; member = $m }
                    }
                }
            } catch { $r.note = Get-ErrMsg $_ }
            $results += [pscustomobject]$r
        }
        $script:FindFields = $null
        Send $ctx @{ ok = $true; results = $results; groupNote = $groupNote; group = $group }
}

# POST /api/onprem - the main CHANGE endpoint. Several options can be combined and are applied to every username in $d.usernames, in this order:
# enable account, clear 'password never expires', change UPN, reset password (+ optional Entra sync), group add/remove, account expiry, names/description/email.
# Input: $d.usernames, $d.addGroups, $d.removeGroups, $d.expiryMode (never/days/date) + expiryDays/expiryDate, $d.enableAccount, $d.clearPwNever,
# $d.nameFirst/nameLast/nameDisplay/nameFull/nameDesc/nameMail (ONE user only), $d.upnMode (fixed/typed) + upnSuffix, $d.pwMode (gen/custom) + pwLength/password,
# $d.pwOnce (must change at next sign-in), $d.syncCloud (also reset in Entra). Each option is checked first; one failing option does not stop the others for that user.
# Sends one result row per user; the new password is returned once so it can be handed over.
$ScreenHandlers['/api/onprem'] = {
        if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so on-premises changes are unavailable.' }
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        # Group names to add and to remove (split from lines/commas); the same group cannot be in both lists.
        $addNames = @(Get-GroupList ((@($d.addGroups) | ForEach-Object { "$_" }) -join "`n")); $remNames = @(Get-GroupList ((@($d.removeGroups) | ForEach-Object { "$_" }) -join "`n"))
        foreach ($x in $addNames) { if ($remNames -contains $x) { throw "'$x' is in both the add list and the remove list." } }
        $group = (@($(if ($addNames.Count) { 'Add: ' + ($addNames -join ', ') }), $(if ($remNames.Count) { 'Remove: ' + ($remNames -join ', ') })) | Where-Object { $_ }) -join ' | '
        $mode = "$($d.expiryMode)"
        $enableAcc = [bool]$d.enableAccount
        $clearNever = [bool]$d.clearPwNever
        # Name changes: allowed for ONE user only. Limits are the AD limits (64 for first/last/full name, 256 display name, 1024 description).
        $nFirst = "$($d.nameFirst)".Trim(); $nLast = "$($d.nameLast)".Trim(); $nDisp = "$($d.nameDisplay)".Trim(); $nFull = "$($d.nameFull)".Trim(); $nDesc = $d.nameDesc; $nMail = $d.nameMail
        $nameOn = [bool]($nFirst -or $nLast -or $nDisp -or $nFull -or $null -ne $nDesc -or $null -ne $nMail)
        if ($nameOn) {
            if (@($d.usernames | ForEach-Object { "$_".Trim() } | Where-Object { $_ }).Count -ne 1) { throw 'Name changes can only be made for one user at a time (use Single user).' }
            if ($nFirst.Length -gt 64 -or $nLast.Length -gt 64) { throw 'First name and last name can be at most 64 characters.' }
            if ($nFull.Length -gt 64) { throw 'The full name can be at most 64 characters.' }
            if ($nDisp.Length -gt 256) { throw 'The display name can be at most 256 characters.' }
            if (("$nFirst$nLast$nDisp$nFull") -match '[\r\n]') { throw 'Names cannot contain line breaks.' }
            # Email shape check: something@something.something without spaces or ; , < > characters. An empty value clears the field.
            if ($null -ne $nMail) { $nMail = "$nMail".Trim(); if ($nMail -and $nMail -notmatch '^[^@\s;,<>"]+@[^@\s;,<>"]+\.[^@\s;,<>"]+$') { throw "Not a valid email address: $nMail" } }
            if ($null -ne $nDesc) { $nDesc = "$nDesc".Trim(); if ($nDesc.Length -gt 1024) { throw 'The description can be at most 1024 characters.' } }
        }
        # UPN change: 'fixed' = same suffix for everybody, 'typed' = take the suffix from each typed user@domain, anything else = no UPN change.
        $upnMode = "$($d.upnMode)"; $upnSuffix = "$($d.upnSuffix)".Trim().TrimStart('@')
        if ($upnMode -eq 'fixed') { if (-not (Test-UpnSuffix $upnSuffix)) { throw 'Enter a valid domain for the UPN, for example company.com.' } }
        elseif ($upnMode -ne 'typed') { $upnMode = 'none' }
        $syncCloud = [bool]$d.syncCloud
        # Password: 'gen' = generate (8-32 characters), 'custom' = use the typed one (must pass the AD rule), otherwise no reset. Default: user must change it at next sign-in.
        $pwMode = "$($d.pwMode)"; $pwOnce = $true; $pwLen = 12
        if ($null -ne $d.pwOnce) { $pwOnce = [bool]$d.pwOnce }
        if ($pwMode -eq 'gen') {
            $pwLen = [int]$d.pwLength
            if ($pwLen -lt 8 -or $pwLen -gt 32) { throw 'Password length must be between 8 and 32.' }
        } elseif ($pwMode -eq 'custom') {
            if (-not (Test-AdPwRule $d.password)) { throw 'The password must be at least 8 characters and cannot start or end with a special character.' }
        } else { $pwMode = 'none' }
        if ($pwMode -eq 'none') { $syncCloud = $false }
        # Refuse an empty request: at least one action must be chosen.
        if (-not $group -and ($mode -eq '' -or $mode -eq 'none') -and -not $enableAcc -and -not $clearNever -and -not $nameOn -and $pwMode -eq 'none' -and $upnMode -eq 'none') { throw 'Choose a name change, a UPN change, a password reset, a security group, an account expiry, the enable option, the Password never expires option, or a combination.' }
        $gEntries = @(); $bad = @()
        # Look up every group first, so a wrong group name stops the whole request before anything is changed.
        $wanted = @($addNames | ForEach-Object { [pscustomobject]@{ n = $_; a = 'add' } }) + @($remNames | ForEach-Object { [pscustomobject]@{ n = $_; a = 'remove' } })
        foreach ($w in $wanted) {
            $gn = $w.n; $g = $null
            try { $g = Resolve-AdGroup $gn } catch { $bad += $_.Exception.Message; continue }
            if (-not $g) { $bad += "Group '$gn' was not found in on-premises AD." }
            elseif ([int]$g.Properties['grouptype'][0] -ge 0) { $bad += "'$gn' is a distribution group, not a security group." }
            else { $gEntries += [pscustomobject]@{ name = "$($g.Properties['cn'][0])"; act = $w.a; entry = $g.GetDirectoryEntry() } }
        }
        if ($bad.Count) { throw ($bad -join ' ') }
        # Expiry value: 'never' = 0; otherwise a date that must not be in the past, stored as a FILETIME.
        $expFt = $null; $expLabel = '-'
        if ($mode -eq 'never') { $expFt = '0'; $expLabel = 'Removed (never expires)' }
        elseif ($mode -eq 'days' -or $mode -eq 'date') {
            $day = if ($mode -eq 'days') { (Get-Date).Date.AddDays([int]$d.expiryDays) } else { [datetime]::ParseExact("$($d.expiryDate)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
            if ($day -lt (Get-Date).Date) { throw 'The expiry date cannot be in the past.' }
            $expFt = "$($day.AddDays(1).ToFileTime())"   # AD convention: account is valid until the END of the chosen day
            $expLabel = 'End of {0:yyyy-MM-dd}' -f $day
        }
        $results = @()
        # Main loop: apply the chosen changes to each user. Every step has its own try/catch so one failure is reported but does not stop the rest.
        foreach ($name in @($d.usernames | ForEach-Object { "$_".Trim() } | Where-Object { $_ })) {
            $r = [ordered]@{ user = $name; found = 'No'; enabled = '-'; upn = '-'; pwReset = '-'; pwNever = '-'; name = '-'; password = ''; cloud = '-'; group = '-'; groups = @(); expiry = '-'; message = '' }
            try {
                $ures = Find-AdObject 'user' $name
                if (-not $ures) { $r.message = 'User not found in on-premises AD' }
                else {
                    $r.found = 'Yes'; $ue = $ures.GetDirectoryEntry(); $msgs = @()
                    # for 'Email the new password': the account's UPN, display name and AD email address (never the password)
                    $r.acct = "$($ue.Properties['userPrincipalName'].Value)"; $r.disp = "$($ue.Properties['displayName'].Value)"; $r.adMail = "$($ue.Properties['mail'].Value)"; $r.given = "$($ue.Properties['givenName'].Value)"; $r.sn = "$($ue.Properties['sn'].Value)"; $r.mailKey = ''
                    # Enable account: userAccountControl bit 2 = disabled; clear it.
                    if ($enableAcc) {
                        try {
                            $uac = [int]$ue.Properties['userAccountControl'].Value
                            if ($uac -band 2) {
                                $ue.Properties['userAccountControl'].Value = ($uac -band (-bnot 2))
                                $ue.CommitChanges(); $r.enabled = 'Enabled now'
                            } else { $r.enabled = 'Already enabled' }
                        } catch { $r.enabled = 'Failed'; $msgs += "Enable: $(Get-ErrMsg $_)" }
                    }
                    # Remove 'Password never expires' (bit 0x10000 of userAccountControl).
                    if ($clearNever) {
                        try {
                            $uac2 = [int]$ue.Properties['userAccountControl'].Value
                            if ($uac2 -band 0x10000) {
                                $ue.Properties['userAccountControl'].Value = ($uac2 -band (-bnot 0x10000))
                                $ue.CommitChanges(); $r.pwNever = 'Removed'
                            } else { $r.pwNever = 'Was not set' }
                        } catch { $r.pwNever = 'Failed'; $msgs += "Password never expires: $(Get-ErrMsg $_)" }
                    }
                    # UPN change: keep the part before @, replace the domain part.
                    if ($upnMode -ne 'none') {
                        try {
                            $cur = "$($ue.Properties['userPrincipalName'].Value)"
                            $local = if ($cur -match '@') { ($cur -split '@')[0] } else { "$($ue.Properties['sAMAccountName'].Value)" }
                            $suf = if ($upnMode -eq 'typed') { if ($name -match '@') { ($name -split '@')[-1].Trim() } else { '' } } else { $upnSuffix }
                            if (-not (Test-UpnSuffix $suf)) { $r.upn = 'Skipped'; $msgs += 'UPN: no domain was typed for this user (use user@domain).' }
                            else {
                                $new = "$local@$suf"
                                if ($cur -ieq $new) { $r.upn = "Already $new" }
                                else { $ue.Properties['userPrincipalName'].Value = $new; $ue.CommitChanges(); $r.upn = "Changed: $cur -> $new"; $r.acct = $new }
                            }
                        } catch { $r.upn = 'Failed'; $msgs += "UPN: $(Get-ErrMsg $_)" }
                    }
                    # Password reset in AD with SetPassword; pwdLastSet = 0 afterwards forces a change at next sign-in.
                    if ($pwMode -ne 'none') {
                        $pw = $null
                        try {
                            $pw = if ($pwMode -eq 'gen') { New-AdPassword $pwLen } else { "$($d.password)" }
                            $ue.Invoke('SetPassword', $pw)
                            $r.password = $pw
                            $r.pwReset = if ($pwOnce) { 'Reset - must change at next sign-in' } else { 'Reset - normal password' }
                        } catch { $r.pwReset = 'Failed'; $msgs += "Password: $(Get-ErrMsg $_)" }
                        if ($r.password -and $pwOnce) {
                            try { $ue.Properties['pwdLastSet'].Value = 0; $ue.CommitChanges() }
                            catch { $r.pwReset = 'Reset - but could not force a change at next sign-in'; $msgs += "Force change: $(Get-ErrMsg $_)"; try { if ([int]$ue.Properties['userAccountControl'].Value -band 0x10000) { $msgs += "This account has 'Password never expires' set, which blocks it. Tick 'Remove Password never expires' and apply again." } } catch { } }
                        }
                        # keep the new password in memory (60 minutes, never on disk) so it can be emailed to the user - same as Reset cloud passwords
                        if ($r.password -and $null -ne $script:ResetSecrets) {
                            $mk = if ($r.acct) { $r.acct } else { "$($ue.Properties['sAMAccountName'].Value)" }
                            $script:ResetSecrets[$mk.ToLower()] = @{ secret = $r.password; tap = $false; ad = $true; pwOnce = [bool]($pwOnce -and $r.pwReset -like '*must change*'); name = $(if ($r.disp) { $r.disp } else { $name }); upn = $mk; at = (Get-Date); mins = 0; once = $false; adMail = $r.adMail; given = $r.given; sn = $r.sn }
                            $r.mailKey = $mk
                        }
                        # Optional: also set the same password on the cloud (Entra) account through Microsoft Graph.
                        if ($syncCloud -and $r.password) {
                            if (-not $script:Who) { $r.cloud = 'Skipped - not signed in to Microsoft' }
                            else {
                                try {
                                    $cs = "$($ue.Properties['sAMAccountName'].Value)"; $cu = "$($ue.Properties['userPrincipalName'].Value)"
                                    $r.cloud = Set-CloudPassword $cs @($cu, $(if ($name -match '@') { $name })) $r.password $pwOnce
                                } catch { $r.cloud = "Failed: $(Get-ErrMsg $_)" }
                            }
                        } elseif ($syncCloud) { $r.cloud = 'Skipped - the on-premises reset failed' }
                    }
                    foreach ($ge in $gEntries) {
                        $res = ''
                        try {
                            $isMem = [bool]$ge.entry.Invoke('IsMember', $ue.Path)
                            if ($ge.act -eq 'add') {
                                if ($isMem) { $res = 'Already a member' } else { $ge.entry.Invoke('Add', $ue.Path); $res = 'Added' }
                            } else {
                                if ($isMem) { $ge.entry.Invoke('Remove', $ue.Path); $res = 'Removed' } else { $res = 'Not a member' }
                            }
                        } catch { $res = 'Failed'; $msgs += "Group $($ge.name): $(Get-ErrMsg $_)" }
                        $r.groups += [pscustomobject]@{ group = $ge.name; result = $res }
                    }
                    if ($r.groups.Count) { $r.group = (($r.groups | ForEach-Object { "$($_.group)=$($_.result)" }) -join '; ') }
                    # Account expiry.
                    if ($null -ne $expFt) {
                        try { $ue.Properties['accountExpires'].Value = $expFt; $ue.CommitChanges(); $r.expiry = $expLabel }
                        catch { $r.expiry = 'Failed'; $msgs += "Expiry: $(Get-ErrMsg $_)" }
                    }
                    # Names: attributes are saved first; the full name (CN) needs a separate Rename. Empty description / email clears the attribute.
                    if ($nameOn) {
                        try {
                            $done = @()
                            if ($nFirst) { $ue.Properties['givenName'].Value = $nFirst; $done += 'First name' }
                            if ($nLast) { $ue.Properties['sn'].Value = $nLast; $done += 'Last name' }
                            if ($nDisp) { $ue.Properties['displayName'].Value = $nDisp; $done += 'Display name' }
                            if ($null -ne $nDesc) { if ($nDesc) { $ue.Properties['description'].Value = $nDesc } else { $ue.Properties['description'].Clear() }; $done += 'Description' }
                            if ($null -ne $nMail) { if ($nMail) { $ue.Properties['mail'].Value = $nMail } else { $ue.Properties['mail'].Clear() }; $done += 'Email' }
                            if ($done.Count) { $ue.CommitChanges() }
                            if ($nFull) {
                                # Escape characters that have a special meaning in a distinguished name (, + " \ < > ; =) and a leading # or space / trailing space.
                                $cn = $nFull -replace '([,+"\\<>;=])', '\$1'
                                if ($cn -match '^[#\s]') { $cn = '\' + $cn }
                                if ($cn -match '\s$') { $cn = $cn.Substring(0, $cn.Length - 1) + '\ ' }
                                $ue.Rename("CN=$cn"); $done += 'Full name'
                            }
                            $r.name = 'Changed: ' + ($done -join ', ')
                        } catch { $r.name = 'Failed'; $msgs += "Name: $(Get-ErrMsg $_)" }
                    }
                    $r.message = ($msgs -join ' | ')
                }
            } catch { $r.message = Get-ErrMsg $_ }
            # Audit line for this user (never contains the password).
            Write-AdLog $r $group
            $results += [pscustomobject]$r
        }
        Send $ctx @{ ok = $true; group = $group; results = $results }
}

# POST /api/usersearch - read only. Input: $d.q (at least 2 characters), $d.fields (sam/upn/mail/name/desc to search in) or the older $d.by.
# Sends at most 50 users (more = true when there are more) with name, description, UPN, mail and a disabled flag.
$ScreenHandlers['/api/usersearch'] = {
        if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so the on-premises lookup is unavailable.' }
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        $q = "$($d.q)".Trim(); $out = @(); $more = $false
        if ($q.Length -ge 2) {
            $n = ConvertTo-LdapValue $q
            $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry)
            $fl = @(@($d.fields) | ForEach-Object { "$_" } | Where-Object { $_ -in 'sam', 'upn', 'mail', 'name', 'desc' })
            $fp = ''
            if ($fl -contains 'sam') { $fp += "(sAMAccountName=*$n*)" }
            if ($fl -contains 'upn') { $fp += "(userPrincipalName=*$n*)" }
            if ($fl -contains 'mail') { $fp += "(mail=*$n*)" }
            if ($fl -contains 'name') { $fp += "(displayName=*$n*)(cn=*$n*)" }
            if ($fl -contains 'desc') { $fp += "(description=*$n*)" }
            $ds.Filter = if ($fp) { "(&(objectCategory=person)(objectClass=user)(|$fp))" } else { switch ("$($d.by)") {
                'name' { "(&(objectCategory=person)(objectClass=user)(|(displayName=*$n*)(cn=*$n*)))" }
                'sam' { "(&(objectCategory=person)(objectClass=user)(sAMAccountName=*$n*))" }
                'upn' { "(&(objectCategory=person)(objectClass=user)(userPrincipalName=*$n*))" }
                'any' { "(&(objectCategory=person)(objectClass=user)(|(description=*$n*)(displayName=*$n*)(cn=*$n*)(sAMAccountName=*$n*)(userPrincipalName=*$n*)(mail=*$n*)))" }
                default { "(&(objectCategory=person)(objectClass=user)(description=*$n*))" }
            } }
            # 51 = 50 shown + 1 to find out whether more exist.
            $ds.SizeLimit = 51
            foreach ($p in 'samaccountname', 'displayname', 'description', 'userprincipalname', 'mail', 'useraccountcontrol') { [void]$ds.PropertiesToLoad.Add($p) }
            $res = @($ds.FindAll())
            if ($res.Count -gt 50) { $more = $true; $res = @($res | Select-Object -First 50) }
            foreach ($u in $res) {
                $pr = $u.Properties
                $out += [pscustomobject]@{
                    sam = "$($pr['samaccountname'][0])"
                    name = $(if ($pr['displayname'].Count -gt 0) { "$($pr['displayname'][0])" } else { '' })
                    desc = $(if ($pr['description'].Count -gt 0) { "$($pr['description'][0])" } else { '' })
                    upn = $(if ($pr['userprincipalname'].Count -gt 0) { "$($pr['userprincipalname'][0])" } else { '' })
                    mail = $(if ($pr['mail'].Count -gt 0) { "$($pr['mail'][0])" } else { '' })
                    disabled = $(if ($pr['useraccountcontrol'].Count -gt 0) { (([int]$pr['useraccountcontrol'][0]) -band 2) -ne 0 } else { $false })
                }
            }
        }
        Send $ctx @{ ok = $true; users = @($out | Sort-Object name, sam); more = $more }
}

# POST /api/groupsearch - read only. Input: $d.q (at least 2 characters). Sends up to 25 security groups (sam, name, description).
$ScreenHandlers['/api/groupsearch'] = {
        if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so the on-premises lookup is unavailable.' }
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        $q = "$($d.q)".Trim(); $out = @()
        if ($q.Length -ge 2) {
            foreach ($g in (Find-AdGroups $q 25)) {
                $out += [pscustomobject]@{ sam = "$($g.Properties['samaccountname'][0])"; name = "$($g.Properties['cn'][0])"; desc = $(if ($g.Properties['description'].Count -gt 0) { "$($g.Properties['description'][0])" } else { '' }) }
            }
        }
        Send $ctx @{ ok = $true; groups = @($out | Sort-Object name) }
}

# POST /api/onprem-account - Input: $d.action (unlock / enable / disable) and $d.usernames. Sends one result row per user.
# Disable is refused for the account that the tool is signed in with, so nobody locks themselves out.
$ScreenHandlers['/api/onprem-account'] = {
        if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so on-premises changes are unavailable.' }
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        $act = "$($d.action)"
        if ($act -notin 'unlock', 'enable', 'disable') { throw 'Unknown action.' }
        $results = @()
        foreach ($name in @($d.usernames | ForEach-Object { "$_".Trim() } | Where-Object { $_ })) {
            $r = [ordered]@{ user = $name; found = 'No'; action = '-'; enabled = '-'; locked = '-'; message = '' }
            try {
                $ures = Find-AdObject 'user' $name
                if (-not $ures) { $r.message = 'User not found in on-premises AD' }
                else {
                    $r.found = 'Yes'; $ue = $ures.GetDirectoryEntry()
                    try {
                        if ($act -eq 'unlock') { $ue.Properties['lockoutTime'].Value = 0; $ue.CommitChanges(); $r.action = 'Unlocked' }
                        else {
                            $uac = [int]$ue.Properties['userAccountControl'].Value
                            if ($act -eq 'enable') {
                                if ($uac -band 2) { $ue.Properties['userAccountControl'].Value = ($uac -band (-bnot 2)); $ue.CommitChanges(); $r.action = 'Enabled now' } else { $r.action = 'Already enabled' }
                            } else {
                                # Remove DOMAIN\ or @domain from the signed-in name and compare it with the target.
                                $tSam = "$($ures.Properties['samaccountname'][0])"; $me = ("$($script:AdCred.User)" -replace '^.*\\', '') -replace '@.*$', ''
                                if ($tSam -ieq $me) { throw 'You cannot disable the account you are signed in with.' }
                                if ($uac -band 2) { $r.action = 'Already disabled' } else { $ue.Properties['userAccountControl'].Value = ($uac -bor 2); $ue.CommitChanges(); $r.action = 'Disabled now' }
                            }
                        }
                    } catch { $r.action = 'Failed'; $r.message = Get-ErrMsg $_ }
                    $sm = "$($ures.Properties['samaccountname'][0])"
                    $o = Get-OnPremStatus $sm $null $sm
                    $r.enabled = $o.enabled; $r.locked = $o.locked
                }
            } catch { $r.message = Get-ErrMsg $_ }
            # Audit line for this account action.
            Write-AdLog @{ user = $name; group = '-'; expiry = '-'; message = $r.message; enabled = $r.action; pwReset = '-'; upn = '-' } "Account action: $act"
            $results += [pscustomobject]$r
        }
        Send $ctx @{ ok = $true; results = $results }
}

$ScreenHandlers['/api/onprem-userinfo'] = {
    # v1.98.8: { user } - the current names, description and email of ONE AD user, to fill in the boxes before you change them (read only)
    if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain.' }
    if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections).' }
    $ures = Find-AdObject 'user' "$($d.user)".Trim(); if (-not $ures) { throw "User not found in on-premises AD: $($d.user)" }
    $ue = $ures.GetDirectoryEntry(); $g = { param($n) $v = $ue.Properties[$n].Value; if ($null -eq $v) { '' } else { "$v" } }
    Send $ctx @{ ok = $true; info = [ordered]@{ sam = (& $g 'sAMAccountName'); first = (& $g 'givenName'); last = (& $g 'sn'); disp = (& $g 'displayName'); full = (& $g 'cn'); desc = (& $g 'description'); mail = (& $g 'mail'); upn = (& $g 'userPrincipalName') } }
}

$ScreenHandlers['/api/suggest'] = {
    # v1.98.8: { q, src:'ad'|'ms'|'any' } - suggestions while you type in a user search box: username (sAMAccountName), UPN, email,
    # display name, first name, last name and description. Read only. AD and Microsoft 365 are asked only when you are signed in to them.
    # Output list; sources are AD, Microsoft 365 (Graph) and the People list. Fewer than 2 typed characters returns nothing.
    $q = "$($d.q)".Trim(); $out = New-Object System.Collections.ArrayList; $src = "$($d.src)"; if (-not $src) { $src = 'any' }
    $by = "$($d.by)"; if ($by -notin 'name', 'desc', 'both') { $by = 'both' }   # v1.98.15: search by username / name, by description, or both
    if ($q.Length -lt 2) { Send $ctx @{ ok = $true; items = @() }; return }
    $adErr = ''
    if ($src -in 'ad', 'any' -and $script:AdAvail -and $script:AdCred) {
        # v1.98.47: names and descriptions are asked separately (one big OR filter can time out in a large domain), and an error is shown, not hidden
        $n = ConvertTo-LdapValue $q
        $flts = @()
        if ($by -ne 'desc') { $flts += "(|(sAMAccountName=$n*)(userPrincipalName=$n*)(mail=$n*)(displayName=*$n*)(givenName=$n*)(sn=$n*)(cn=*$n*))" }
        if ($by -ne 'name') { $flts += "(description=*$n*)" }
        foreach ($fx in $flts) {
            try {
                # Time limits (8 s on the server, 10 s on this side) so a slow domain controller cannot hang the type-ahead box.
                $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = 15; $ds.ServerTimeLimit = [TimeSpan]::FromSeconds(8); $ds.ClientTimeout = [TimeSpan]::FromSeconds(10)
                $ds.Filter = "(&(objectCategory=person)(objectClass=user)$fx)"
                foreach ($p in 'samaccountname', 'displayname', 'givenname', 'sn', 'description', 'userprincipalname', 'mail', 'useraccountcontrol') { [void]$ds.PropertiesToLoad.Add($p) }
                foreach ($u in @($ds.FindAll())) { $pr = $u.Properties; $v = { param($k) if ($pr[$k].Count) { "$($pr[$k][0])" } else { '' } }
                    [void]$out.Add([ordered]@{ src = 'AD'; sam = (& $v 'samaccountname'); name = (& $v 'displayname'); first = (& $v 'givenname'); last = (& $v 'sn'); desc = (& $v 'description'); upn = (& $v 'userprincipalname'); mail = (& $v 'mail'); disabled = $(if ($pr['useraccountcontrol'].Count) { (([int]$pr['useraccountcontrol'][0]) -band 2) -ne 0 } else { $false }) }) }
            } catch { $adErr = Get-ErrMsg $_ }
        }
    }
    if ($src -in 'ms', 'any' -and $script:Who) {
        try {
            # Microsoft 365 search: Graph $search needs ConsistencyLevel: eventual. Double quotes are removed because they delimit the search terms.
            $t = $q -replace '"', ''
            $flt = """displayName:$t"" OR ""mail:$t"" OR ""userPrincipalName:$t"" OR ""givenName:$t"" OR ""surname:$t"""
            $uri = 'https://graph.microsoft.com/v1.0/users?$top=15&$select=displayName,givenName,surname,mail,userPrincipalName,onPremisesSamAccountName,accountEnabled,jobTitle,department,employeeId&$search=' + [uri]::EscapeDataString($flt)
            $vals = @()
            if ($by -ne 'desc') { $vals += @((Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop).value) }
            if ($by -ne 'name') {   # Entra has no description: look in employee ID, job title and department instead
                $e = $t -replace "'", "''"
                $u2 = 'https://graph.microsoft.com/v1.0/users?$top=15&$count=true&$select=displayName,givenName,surname,mail,userPrincipalName,onPremisesSamAccountName,accountEnabled,jobTitle,department,employeeId&$filter=' + [uri]::EscapeDataString("startswith(employeeId,'$e') or startswith(jobTitle,'$e') or startswith(department,'$e')")
                try { $vals += @((Invoke-MgGraphRequest -Method GET -Uri $u2 -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop).value) } catch {}
            }
            foreach ($u in $vals) { [void]$out.Add([ordered]@{ src = 'M365'; sam = "$($u.onPremisesSamAccountName)"; name = "$($u.displayName)"; first = "$($u.givenName)"; last = "$($u.surname)"; desc = (@("$($u.employeeId)", "$($u.jobTitle)", "$($u.department)") | Where-Object { $_ }) -join ' - '; upn = "$($u.userPrincipalName)"; mail = "$($u.mail)"; disabled = ($u.accountEnabled -eq $false) }) }
        } catch {}
    }
    # Also search the People list kept by the portal (if that module is loaded), first 10 hits.
    if ($src -eq 'any' -and (Get-Command Get-PeopleDb -ErrorAction SilentlyContinue)) {
        try { foreach ($p in @((Get-PeopleDb).people | Where-Object { "$($_.first) $($_.last) $($_.username) $($_.email)" -like "*$q*" } | Select-Object -First 10)) {
            [void]$out.Add([ordered]@{ src = 'People'; sam = $p.username; name = ("$($p.first) $($p.last)").Trim(); first = $p.first; last = $p.last; desc = $p.dept; upn = ''; mail = $p.email; disabled = ($p.enabled -eq $false) }) } } catch {}
    }
    # Remove duplicates (same UPN / username / mail seen from several sources) and return the first 25.
    $seen = @{}; $items = @(foreach ($i in $out) { $k = ("$($i.upn)|$($i.sam)|$($i.mail)").ToLower(); if (-not $seen[$k]) { $seen[$k] = 1; $i } })
    Send $ctx @{ ok = $true; items = @($items | Select-Object -First 25); adError = $adErr }
}

# v1.98.16: Audit & event logs - find the user first. { q, src:'ms'|'ad', by } - read only. Errors are returned (not hidden), so the page can say why.
# Entra (by): any | upn | mail | id (object ID) | emp (employee ID) | name.   AD (by): any | sam | upn | emp (employeeID / employeeNumber) | desc | name
# POST /api/audit-userfind - read only. Input: $d.q (at least 2 characters), $d.src ('ad' or Microsoft 365/Entra), $d.by (search field).
# Sends up to 50 users (source, username, UPN, mail, name, employee id, department, disabled flag).
$ScreenHandlers['/api/audit-userfind'] = {
    $q = "$($d.q)".Trim(); $by = "$($d.by)"; if (-not $by) { $by = 'any' }
    if ($q.Length -lt 2) { throw 'Type at least 2 characters.' }
    $out = New-Object System.Collections.ArrayList
    if ("$($d.src)" -eq 'ad') {
        if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain.' }
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections).' }
        $n = ConvertTo-LdapValue $q
        # Which LDAP filter pieces belong to each 'by' choice; an unknown choice searches all of them.
        $parts = @{ sam = "(sAMAccountName=$n*)"; upn = "(userPrincipalName=$n*)(mail=$n*)"; emp = "(employeeID=$n*)(employeeNumber=$n*)"; desc = "(description=*$n*)"; name = "(displayName=*$n*)(givenName=$n*)(sn=$n*)(cn=*$n*)" }
        $f = if ($parts.ContainsKey($by)) { $parts[$by] } else { ($parts.Values -join '') }
        $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = 50
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(|$f))"
        foreach ($p in 'samaccountname', 'userprincipalname', 'mail', 'displayname', 'description', 'employeeid', 'employeenumber', 'useraccountcontrol', 'department') { [void]$ds.PropertiesToLoad.Add($p) }
        foreach ($r in @($ds.FindAll())) { $pr = $r.Properties; $v = { param($k) if ($pr[$k].Count) { "$($pr[$k][0])" } else { '' } }
            [void]$out.Add([ordered]@{ src = 'AD'; sam = (& $v 'samaccountname'); upn = (& $v 'userprincipalname'); mail = (& $v 'mail'); name = (& $v 'displayname'); desc = (& $v 'description')
                emp = $(if (& $v 'employeeid') { & $v 'employeeid' } else { & $v 'employeenumber' }); dept = (& $v 'department'); id = ''; disabled = $(if ($pr['useraccountcontrol'].Count) { (([int]$pr['useraccountcontrol'][0]) -band 2) -ne 0 } else { $false }) }) }
    } else {
        if (-not $script:Who) { throw 'Sign in to Microsoft 365 first (Settings > Connections).' }
        $e = $q -replace "'", "''"
        $sel = 'id,displayName,userPrincipalName,mail,employeeId,jobTitle,department,accountEnabled,onPremisesSamAccountName'
        $list = @()
        # The text looks like an object ID (GUID) - read that user directly.
        if ($q -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -and $by -in 'any', 'id') {
            try { $list += @(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$q`?`$select=$sel" -ErrorAction Stop) } catch {}
        }
        if ($by -ne 'id') {
            # Graph $filter text for the chosen field (startswith is supported with ConsistencyLevel eventual and $count=true). Single quotes were doubled in $e.
            $fl = switch ($by) {
                'upn'  { "startswith(userPrincipalName,'$e')" }
                'mail' { "startswith(mail,'$e')" }
                'emp'  { "startswith(employeeId,'$e')" }
                'name' { "startswith(displayName,'$e') or startswith(givenName,'$e') or startswith(surname,'$e')" }
                default { "startswith(userPrincipalName,'$e') or startswith(mail,'$e') or startswith(employeeId,'$e') or startswith(displayName,'$e') or startswith(givenName,'$e') or startswith(surname,'$e')" }
            }
            $uri = "https://graph.microsoft.com/v1.0/users?`$top=50&`$count=true&`$select=$sel&`$filter=" + [uri]::EscapeDataString($fl)
            try { $list += @((Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop).value) }
            catch { throw "Microsoft 365 search failed: $($_.Exception.Message)" }
        }
        foreach ($u in $list) { [void]$out.Add([ordered]@{ src = 'Entra'; sam = "$($u.onPremisesSamAccountName)"; upn = "$($u.userPrincipalName)"; mail = "$($u.mail)"; name = "$($u.displayName)"
            desc = (@("$($u.jobTitle)") | Where-Object { $_ }) -join ''; emp = "$($u.employeeId)"; dept = "$($u.department)"; id = "$($u.id)"; disabled = ($u.accountEnabled -eq $false) }) }
    }
    # Remove duplicates; 'more' is true when the 50 limit was reached.
    $seen = @{}; $items = @(foreach ($i in $out) { $k = ("$($i.upn)|$($i.sam)|$($i.id)").ToLower(); if (-not $seen[$k]) { $seen[$k] = 1; $i } })
    Send $ctx @{ ok = $true; users = @($items | Sort-Object { $_.name }); more = ($items.Count -ge 50) }
}

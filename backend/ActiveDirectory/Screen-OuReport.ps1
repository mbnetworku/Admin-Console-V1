# Screen-OuReport.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Users report
# Screen version: 2.10.3   (changes ONLY when this screen changes - not with every release)

# WHAT IT DOES: the "Users report" screen (it was called "OU report" in 2.10.0). The person picks one OU of the on-premises Active Directory (from the list of OUs that really exist)
# and gets one row per user account in it: e-mail, user principal name, account name (sAMAccountName), display name, first name, last name,
# account expiry date, status (Enabled / Disabled / Locked out / Expired), description, when the object was last modified, whether the
# password never expires, and the OU the user is in. The page shows the table and can download it as a CSV file.
# READ ONLY: nothing in AD is changed. No Microsoft Graph / Exchange calls.
# ENDPOINTS: POST /api/ourep-ous  (no input; replies { ok, ous = [{ dn, name, path, desc }] })
#            POST /api/ourep-run  (input: ous = array of distinguished names of OUs from the list (1 to 50; v2.10.2), or ou = one DN, subtree = true/false (include sub-OUs, default true);
#                                  replies { ok, rows, count, truncated, ouPath, ouPaths })
# DATA: reads AD through the AD sign-in held in $script:AdCred (New-AdEntry). Uses Get-AdcOus (Screen-AdCreate.ps1) for the OU list.
# PERMISSION: the "Bulk & report" permission (see $script:ApiNeed in Screen-Users.ps1) and an on-premises AD sign-in.

# NO limit (2.10.3): every user of the chosen OUs is reported. The value is only a safety ceiling that cannot be reached in practice.
$script:OuRepMax = [int]::MaxValue

# Stops the request with a clear message unless this PC is domain joined and the person has signed in to on-premises AD.
function Test-OuRepReady {
    if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so the Users report is unavailable.' }
    if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
}
# Reads the first value of an AD property as text ('' when the attribute is empty). $p = result Properties, $n = lower-case attribute name.
function Get-OuRepVal($p, [string]$n) { if ($p[$n].Count -gt 0) { "$($p[$n][0])" } else { '' } }
# The readable OU path of the container a user sits in, for example "contoso.com/Staff/IT". $dn = the user's distinguished name.
# The first part (CN=user) is dropped; the OU= parts are un-escaped and put top-down; the DC= parts give the domain name.
function Get-OuRepPath([string]$dn) {
    $parts = @($dn -split '(?<!\\),'); if ($parts.Count -gt 1) { $parts = $parts[1..($parts.Count - 1)] }
    $ou = @($parts | Where-Object { $_ -match '^OU=' } | ForEach-Object { $_.Substring(3) -replace '\\(.)', '$1' }); [array]::Reverse($ou)
    $dom = (($parts | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.')
    "$dom/" + ($ou -join '/')
}

# Handler /api/ourep-ous: the OUs of the domain for the drop-down (cached for 10 minutes per session by Get-AdcOus).
$ScreenHandlers['/api/ourep-ous'] = {
    Test-OuRepReady
    Send $ctx @{ ok = $true; ous = @(Get-AdcOus | ForEach-Object { @{ dn = $_.dn; name = $_.name; path = $_.path; desc = $_.desc } }) }
}

# Handler /api/ourep-run: builds the report for ONE OR SEVERAL OUs (v2.10.2). Every OU must be one of the OUs in the list (so a made-up DN can never be used
# as a search root). A user who is reached twice (an OU and its sub-OU both chosen) appears once. The rows of all OUs are joined and sorted by OU, then account name.
$ScreenHandlers['/api/ourep-run'] = {
    Test-OuRepReady
    $wanted = @(@($d.ous) + @($d.ou) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $wanted.Count) { throw 'Choose at least one OU.' }
    if ($wanted.Count -gt 50) { throw 'Choose up to 50 OUs at a time.' }
    $all = @(Get-AdcOus); $targets = @()
    foreach ($w in $wanted) { $h = @($all | Where-Object { $_.dn -ieq $w })[0]; if (-not $h) { throw "OU not found: $w - choose OUs from the list." }; $targets += $h }
    # Include the sub-OUs unless the person switched that off (OneLevel = only users directly in the OU).
    $sub = $true; if ($null -ne $d.subtree) { $sub = [bool]$d.subtree }
    $rows = New-Object Collections.Generic.List[object]; $seen = New-Object 'Collections.Generic.HashSet[string]'; $trunc = $false
    foreach ($hit in $targets) {
        if ($trunc) { break }
        $ds = New-Object DirectoryServices.DirectorySearcher((New-AdEntry $hit.dn))
        $ds.Filter = '(&(objectCategory=person)(objectClass=user))'
        $ds.PageSize = 1000
        $ds.SearchScope = $(if ($sub) { 'Subtree' } else { 'OneLevel' })
        foreach ($pn in 'distinguishedname', 'mail', 'userprincipalname', 'samaccountname', 'displayname', 'givenname', 'sn', 'accountexpires', 'useraccountcontrol', 'description', 'whenchanged', 'lockouttime', 'msds-user-account-control-computed') { [void]$ds.PropertiesToLoad.Add($pn) }
        try {
            foreach ($r in $ds.FindAll()) {
                $p = $r.Properties
                $dnU = Get-OuRepVal $p 'distinguishedname'
                # Already listed through another chosen OU: skip it.
                if (-not $seen.Add($dnU.ToLower())) { continue }
                if ($rows.Count -ge $script:OuRepMax) { $trunc = $true; break }
                # userAccountControl: bit 2 (0x2) = disabled, bit 0x10000 = password never expires.
                $uac = 0; if ($p['useraccountcontrol'].Count) { $uac = [int]$p['useraccountcontrol'][0] }
                $disabled = [bool]($uac -band 2); $pwNever = [bool]($uac -band 0x10000)
                # Lock-out: the computed attribute bit 0x10 is the reliable flag; otherwise lockoutTime > 0.
                $locked = $false
                if ($p['msds-user-account-control-computed'].Count) { $locked = [bool]([int]$p['msds-user-account-control-computed'][0] -band 0x10) } elseif ($p['lockouttime'].Count) { $locked = ([int64]$p['lockouttime'][0] -gt 0) }
                # accountExpires: 0 or the largest Int64 mean "never"; otherwise a FILETIME (the start of the next day, so show the last working day).
                $exp = 'Never'; $expired = $false
                if ($p['accountexpires'].Count) { $ae = [int64]$p['accountexpires'][0]; if ($ae -ne 0 -and $ae -ne [int64]::MaxValue) { $at = [DateTime]::FromFileTime($ae); $exp = '{0:yyyy-MM-dd}' -f $at.AddSeconds(-1); $expired = ($at -lt (Get-Date)) } }
                $status = if ($disabled) { 'Disabled' } elseif ($locked) { 'Locked out' } elseif ($expired) { 'Expired' } else { 'Enabled' }
                # whenChanged is UTC; shown in local time.
                $chg = ''; if ($p['whenchanged'].Count) { $wc = $p['whenchanged'][0]; if ($wc -is [datetime]) { if ($wc.Kind -ne 'Local') { $wc = $wc.ToLocalTime() }; $chg = '{0:yyyy-MM-dd HH:mm}' -f $wc } }
                $desc = (@($p['description'] | ForEach-Object { "$_" }) -join ' ')
                $rows.Add([pscustomobject][ordered]@{
                    mail = (Get-OuRepVal $p 'mail'); upn = (Get-OuRepVal $p 'userprincipalname'); sam = (Get-OuRepVal $p 'samaccountname'); name = (Get-OuRepVal $p 'displayname')
                    first = (Get-OuRepVal $p 'givenname'); last = (Get-OuRepVal $p 'sn'); expires = $exp; status = $status; desc = $desc; changed = $chg
                    pwNever = $(if ($pwNever) { 'Yes' } else { 'No' }); ou = (Get-OuRepPath $dnU) })
            }
        } finally { $ds.Dispose() }
    }
    $sorted = @($rows | Sort-Object ou, sam)
    $paths = @($targets | ForEach-Object { $_.path })
    Send $ctx @{ ok = $true; rows = $sorted; count = $sorted.Count; truncated = $trunc; ouPath = ($paths -join '; '); ouPaths = $paths; subtree = $sub }
}

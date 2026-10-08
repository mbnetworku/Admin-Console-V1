# Screen-AddressList.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Address list
# Screen version: 2.8.1   (changes ONLY when this screen changes - not with every release)

#  * Accounts SYNCED from on-premises AD: the setting lives in AD (msExchHideFromAddressLists). The tool sets it in AD and
#    Entra Connect copies it to Exchange Online at the next sync (usually within 30 minutes).
#  * CLOUD-ONLY mailboxes: Exchange Online (Set-Mailbox -HiddenFromAddressListsEnabled), through the Exchange Online worker.
# Nothing else is changed. Check is read only.

# SCREEN: Address list (hide / show users in the Global Address List).
# Endpoints: /api/gal-check (read only look-up), /api/gal-ad (change in on-premises AD), /api/gal-cloud (queue an Exchange Online job).
# Uses: Microsoft Graph /users (read), on-premises AD via ADSI/DirectorySearcher, and the Exchange Online worker (MbxHide job).
# Permission: the same sign-in rules as every other /api call handled by server.ps1; AD changes need the AD sign-in from Settings > Connections.
#
# Cache for Test-GalSchema: $null = not checked yet, otherwise True/False.
$script:GalSchema = $null
# Returns True if the AD schema contains the Exchange attribute msExchHideFromAddressLists (Exchange schema was installed).
# The answer is cached. On any error it returns $false.
function Test-GalSchema {
    # does this AD have the Exchange attribute msExchHideFromAddressLists? (needed to hide synced users)
    if ($null -ne $script:GalSchema) { return $script:GalSchema }
    try {
        # Look in the AD schema partition for an attribute definition with that name; FindOne returns nothing if it does not exist.
        $sc = "$((Get-RootDse).Properties['schemaNamingContext'].Value)"
        $ds = New-Object DirectoryServices.DirectorySearcher((New-AdEntry $sc)); $ds.Filter = '(lDAPDisplayName=msExchHideFromAddressLists)'
        $script:GalSchema = [bool]$ds.FindOne()
    } catch { return $false }
    $script:GalSchema
}
# Finds user objects in AD. $sam may be a sAMAccountName, DOMAIN\name, UPN or e-mail address. Returns an array of search results
# (SizeLimit 2: we only need to know whether there is none, one, or more than one match).
function Get-GalAd($sam) {
    # Strip a leading DOMAIN\ and a trailing @suffix to get the plain logon name, and escape it for use in an LDAP filter.
    $n = ConvertTo-LdapValue (("$sam" -replace '^.*\\', '') -replace '@.*$', '')
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = 2
    # Match a real user account by logon name, UPN or e-mail address.
    $ds.Filter = "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$n)(userPrincipalName=$(ConvertTo-LdapValue $sam))(mail=$(ConvertTo-LdapValue $sam))))"
    foreach ($p in 'samaccountname', 'displayname', 'mail', 'userprincipalname', 'msexchhidefromaddresslists', 'distinguishedname') { [void]$ds.PropertiesToLoad.Add($p) }
    @($ds.FindAll())
}
# ENDPOINT /api/gal-check - read only. Input: $d.users (list of names / e-mail addresses, max 200).
# For each user: looks it up in Microsoft 365 (Graph) and in AD, and decides which place must be changed (method = ad / cloud / none).
# Returns { ok, users[], schema, ad, ms }.
$ScreenHandlers['/api/gal-check'] = {
    # { users:[...] } - for every user: where the setting must be changed (AD or Exchange Online) and whether it is hidden now
    # Clean the list: trim, drop empty entries, remove duplicates, limit to 200.
    $list = @($d.users | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique -First 200)
    if (-not $list.Count) { throw 'Type at least one user.' }
    # Only check the Exchange schema when we are signed in to AD; otherwise $null (unknown).
    $schema = if ($script:AdAvail -and $script:AdCred) { Test-GalSchema } else { $null }
    $out = @()
    foreach ($u in $list) {
        # One result row per user. synced = is the account synced from on-premises AD; adHidden = current AD value.
        $r = [ordered]@{ user = $u; name = ''; upn = ''; mail = ''; entra = 'Not checked'; synced = $null; adSam = ''; adFound = $false; adHidden = $null; method = ''; note = '' }
        # Step 1: Microsoft 365 look-up (only if signed in to Microsoft 365; $script:Who holds the signed-in admin).
        if ($script:Who) {
            try {
                # Double any single quote so the value is safe inside the OData filter string.
                $f = $u -replace "'", "''"
                # Graph: find the user by UPN, mail or on-premises logon name. ConsistencyLevel=eventual is required for this kind of filter.
                $g = @((Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/users?`$select=id,displayName,userPrincipalName,mail,onPremisesSyncEnabled,onPremisesSamAccountName&`$filter=" + [uri]::EscapeDataString("userPrincipalName eq '$f' or mail eq '$f' or onPremisesSamAccountName eq '$f'")) -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop).value)
                # Nothing found and the user typed no '@': try again, treating the text as the first part of the UPN (startswith needs $count=true).
                if (-not $g.Count -and $u -notmatch '@') { $g = @((Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/users?`$count=true&`$select=id,displayName,userPrincipalName,mail,onPremisesSyncEnabled,onPremisesSamAccountName&`$filter=" + [uri]::EscapeDataString("startswith(userPrincipalName,'$f@')")) -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop).value) }
                # Exactly one match = good. Several matches = ask the admin to be more specific. None = not found.
                if ($g.Count -eq 1) { $x = $g[0]; $r.entra = 'Found'; $r.name = "$($x.displayName)"; $r.upn = "$($x.userPrincipalName)"; $r.mail = "$($x.mail)"; $r.synced = [bool]$x.onPremisesSyncEnabled; $r.adSam = "$($x.onPremisesSamAccountName)" }
                elseif ($g.Count -gt 1) { $r.entra = 'Several'; $r.note = 'Several Microsoft 365 accounts match - use the full e-mail address.' }
                else { $r.entra = 'Not found' }
            } catch { $r.entra = 'Error'; $r.note = "Microsoft 365: $($_.Exception.Message)" }
        }
        # Step 2: AD look-up. Skipped for cloud-only accounts (synced = false) because they have no AD object.
        if ($script:AdAvail -and $script:AdCred -and ($r.synced -ne $false)) {
            try {
                # Prefer the AD logon name Microsoft 365 gave us; otherwise use what the admin typed.
                $a = @(Get-GalAd $(if ($r.adSam) { $r.adSam } else { $u }))
                # Exactly one AD user: remember its logon name, fill in missing name / mail, and read whether it is currently hidden.
                # (Hidden = the msExchHideFromAddressLists value is true; a missing value means visible.)
                if ($a.Count -eq 1) { $p = $a[0].Properties; $r.adFound = $true; $r.adSam = "$($p['samaccountname'][0])"; if (-not $r.name -and $p['displayname'].Count) { $r.name = "$($p['displayname'][0])" }; if (-not $r.mail -and $p['mail'].Count) { $r.mail = "$($p['mail'][0])" }
                    $r.adHidden = if ($p['msexchhidefromaddresslists'].Count) { [bool]$p['msexchhidefromaddresslists'][0] } else { $false } }
            } catch { $r.note = ($r.note + " AD: $($_.Exception.Message)").Trim() }
        }
        # Decide where the change must be made: 'ad' for synced users (Entra Connect copies it up), 'cloud' for cloud-only mailboxes, 'none' if not found.
        $r.method = if ($r.synced -eq $true -or ($r.entra -ne 'Found' -and $r.adFound)) { 'ad' } elseif ($r.entra -eq 'Found') { 'cloud' } else { 'none' }
        # Helpful notes when the change cannot be made yet (no AD sign-in, or the AD schema has no Exchange attributes).
        if ($r.method -eq 'ad' -and -not $r.adFound) { $r.note = ($r.note + ' Synced from AD - sign in to on-premises AD (Settings > Connections) to change it.').Trim() }
        if ($r.method -eq 'ad' -and $schema -eq $false) { $r.note = ($r.note + ' Your AD has no Exchange attributes (msExchHideFromAddressLists) - the AD schema must be extended for Exchange (Exchange setup /PrepareSchema) before synced users can be hidden.').Trim() }
        if ($r.method -eq 'none' -and -not $r.note) { $r.note = 'Not found in Microsoft 365 or AD.' }
        $out += $r
    }
    # Send the result rows plus flags telling the page whether AD / Microsoft 365 were available.
    Send $ctx @{ ok = $true; users = $out; schema = $schema; ad = [bool]($script:AdAvail -and $script:AdCred); ms = [bool]$script:Who }
}
# ENDPOINT /api/gal-ad - changes AD. Input: $d.sams (AD logon names, max 200), $d.hide (true = hide, false = show again).
# Sets or clears msExchHideFromAddressLists on each user. Entra Connect copies it to Exchange Online later. Returns { ok, results[] }.
$ScreenHandlers['/api/gal-ad'] = {
    # { sams:[...], hide:true|false } - set msExchHideFromAddressLists in on-premises AD (Entra Connect copies it to Exchange Online)
    if (-not $script:AdAvail -or -not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections).' }
    if ((Test-GalSchema) -eq $false) { throw 'Your AD has no Exchange attributes (msExchHideFromAddressLists). Extend the AD schema for Exchange first (Exchange setup /PrepareSchema), then try again.' }
    # Process each user separately so one failure does not stop the others.
    $hide = [bool]$d.hide; $out = @()
    foreach ($s in @($d.sams | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique -First 200)) {
        $r = [ordered]@{ user = $s; ok = $false; message = '' }
        try {
            # Must match exactly one AD user, otherwise report an error for this row.
            $a = @(Get-GalAd $s); if ($a.Count -ne 1) { throw $(if ($a.Count) { 'Several AD users match.' } else { 'Not found in AD.' }) }
            $e = $a[0].GetDirectoryEntry()
            # Hide = set the attribute to true. Show = clear (remove) the attribute. CommitChanges writes it to AD.
            if ($hide) { $e.Properties['msExchHideFromAddressLists'].Value = $true } else { $e.Properties['msExchHideFromAddressLists'].Clear() }
            $e.CommitChanges()
            $r.ok = $true; $r.message = $(if ($hide) { 'Hidden in AD. Entra Connect copies it to Exchange Online at the next sync (usually within 30 minutes); the address book then updates within a few hours.' } else { 'Shown again in AD. Exchange Online follows after the next Entra Connect sync.' })
        } catch { $r.message = "$($_.Exception.Message)" }
        # Write one line to the activity log (only if the logging function is loaded).
        if (Get-Command Write-ActRow -ErrorAction SilentlyContinue) { Write-ActRow 'Address list' $(if ($hide) { 'Hide from address list (AD)' } else { 'Show in address list (AD)' }) $s $(if ($r.ok) { 'Done' } else { "Failed: $($r.message)" }) '' }
        $out += $r
    }
    Send $ctx @{ ok = $true; results = $out }
}
# ENDPOINT /api/gal-cloud - cloud-only mailboxes. Input: $d.mailboxes (list), $d.hide (true/false).
# Does not change anything itself: it queues an 'MbxHide' job for the Exchange Online worker (Set-Mailbox -HiddenFromAddressListsEnabled).
# Returns { ok, id }; the page then polls /api/mbx-result with that id.
$ScreenHandlers['/api/gal-cloud'] = {
    # { mailboxes:[...], hide } - cloud-only mailboxes: Exchange Online, through the Exchange Online worker. Result: /api/mbx-result
    # Validate every mailbox name (Test-MbxId throws on bad input), remove duplicates, limit to 200.
    $mbs = @($d.mailboxes | ForEach-Object { Test-MbxId $_ 'mailbox' } | Select-Object -Unique -First 200)
    if (-not $mbs.Count) { throw 'No mailbox to change.' }
    $hide = [bool]$d.hide
    $id = New-MbxJob ([ordered]@{ Action = 'MbxHide'; Mailbox = ($mbs -join ', '); Mailboxes = $mbs; Hide = $hide }) ("$(if ($hide) { 'Hide' } else { 'Show' }) $($mbs.Count) mailbox(es) in the address list")
    Send $ctx @{ ok = $true; id = $id }
}

# Screen-AccountStatus.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Account status
# Screen version: 2.2.1   (changes ONLY when this screen changes - not with every release)


# Account status screen - endpoints: /api/search (look up users), /api/enable, /api/disable.
# Uses Microsoft Graph (Get-MgUser / Update-MgUser, needs the Entra sign-in in $script:Who) and optionally on-premises AD
# (Get-OnPremStatus, needs $script:AdAvail and $script:AdCred). Enable/Disable log the action with Write-Log.
#
# /api/search - request fields: $d.entra, $d.onprem (which directories to search), $d.domain (optional), $d.usernames (list).
# Returns { ok, results = one row per user found, more = true when a domain listing was cut at 100 users }.
$ScreenHandlers['/api/search'] = {
        # Used to drop duplicate names typed by the operator (case-insensitive).
        $seenNames = @{}
        # Check the search choices and that the needed connections (Entra / AD domain / AD sign-in) exist before doing any work.
        $doEntra = [bool]$d.entra; $doAd = [bool]$d.onprem
        if (-not ($doEntra -or $doAd)) { throw 'Choose Entra ID, on-premises AD, or both.' }
        if ($doEntra -and -not $script:Who) { throw 'Connect to Entra first, or search on-premises AD only.' }
        if ($doAd -and -not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so the on-premises lookup is unavailable.' }
        if ($doAd -and -not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        # $pre = users already loaded by a domain listing; $more = more than 100 users exist in the domain.
        # $props = the Graph user fields we need (kept in one list so every lookup asks for the same data).
        $dom = "$($d.domain)".Trim(); $results = @(); $pre = @{}; $more = $false
        $props = 'Id', 'DisplayName', 'UserPrincipalName', 'MobilePhone', 'BusinessPhones', 'AccountEnabled', 'UserType', 'PasswordPolicies', 'LastPasswordChangeDateTime', 'OnPremisesSyncEnabled', 'OnPremisesSamAccountName', 'OnPremisesLastSyncDateTime'
        # Clean the typed names: trim, remove blanks and duplicates (each name once, in the order typed).
        $nameList = @($d.usernames | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $seenNames[$_.ToLower()] } | ForEach-Object { $seenNames[$_.ToLower()] = 1; $_ })   # each name once, in the order typed
        # Only a domain was given: ask Graph for its users. Top 101 so we can tell whether there are more than 100.
        # ConsistencyLevel eventual + CountVariable is required by Graph for the endsWith filter on userPrincipalName.
        # Domain only (no username typed): list the users of that domain, first 100
        if ($nameList.Count -eq 0 -and $dom) {
            $dom = $dom.TrimStart('@')
            if (-not $doEntra) { throw 'Type at least one username, or use the Entra ID search with a domain.' }
            if (-not (Test-UpnSuffix $dom)) { throw 'The domain is not valid.' }
            $list = @(Get-MgUser -Filter "endsWith(userPrincipalName,'@$dom')" -ConsistencyLevel eventual -CountVariable domCnt -Property $props -Top 101 -ErrorAction Stop)
            if ($list.Count -gt 100) { $more = $true; $list = @($list | Select-Object -First 100) }
            foreach ($lu in $list) { $pre["$($lu.UserPrincipalName)"] = $lu }
            $nameList = @($list | ForEach-Object { "$($_.UserPrincipalName)" })
            if ($nameList.Count -eq 0) { throw "No users found in the domain $dom." }
        }
        # Main loop: one typed name can give several rows (the same name may match more than one Entra user).
        foreach ($name in $nameList) {
            $rows = @()
            if ($doEntra) {
                # Entra lookup: reuse the pre-loaded user if there is one, otherwise search (Resolve-EntraUsers). An error becomes an 'Unknown' row.
                $found = @(); $err = $null
                try { if ($pre.ContainsKey($name)) { $found = @($pre[$name]) } else { $found = @(Resolve-EntraUsers $name $dom $props) } } catch { $err = $_.Exception.Message }
                if ($err) { $rows += @{ u = $null; ex = 'Unknown'; msg = $err } }
                elseif ($found.Count -eq 0) { $rows += @{ u = $null; ex = 'No'; msg = $(if (-not $dom -and $name -notmatch '@') { 'Not found in Entra (all domains were searched)' } else { 'Not found in Entra' }) } }
                else { foreach ($fu in $found) { $rows += @{ u = $fu; ex = 'Yes'; msg = '' } } }
            } else { $rows += @{ u = $null; ex = '-'; msg = '' } }
            # Build the result row for each match: Entra fields first, then the on-premises AD fields when requested.
            foreach ($row in $rows) {
                $u = $row.u
                # UPN to show: the real one if found; otherwise what was typed (adding @domain when only a short name was typed).
                $upn = if ($u) { "$($u.UserPrincipalName)" } elseif ($name -match '@') { $name } elseif ($dom) { "$name@$dom" } else { $null }
                $r = [ordered]@{ user = $name; upn = $upn; name = $(if ($u) { "$($u.DisplayName)" } else { '' }); exists = $row.ex; enabled = '-'; type = '-'; pwdExpiry = '-'; synced = '-'; lastSync = '-'; message = $row.msg; adFound = '-'; adEnabled = '-'; adExpires = '-'; adLocked = '-'; adPwdSet = '-'; adNote = '' }
                $sam = $null
                if ($u) {
                    # Translate Graph values into the plain text shown on the screen.
                    $r.enabled = if ($u.AccountEnabled) { 'Enabled' } else { 'Disabled' }
                    $r.type = "$($u.UserType)"
                    $r.synced = if ($u.OnPremisesSyncEnabled) { 'Yes (on-prem)' } else { 'No (cloud)' }
                    $r.lastSync = if ($u.OnPremisesLastSyncDateTime) { '{0:yyyy-MM-dd HH:mm}' -f $u.OnPremisesLastSyncDateTime } else { '-' }
                    # Password expiry text (depends on the password policy of the user / domain).
                    $r.pwdExpiry = Get-PwdExpiry $u
                    $r.mobile = "$($u.MobilePhone)"; $r.phone = (@($u.BusinessPhones) | Where-Object { $_ }) -join ', '   # v2.2.1
                    # The on-premises account name is used to find the same person in AD.
                    $sam = $u.OnPremisesSamAccountName
                }
                if ($doAd) {
                    # Ask on-premises AD for the same person (by sAMAccountName, UPN or name) and copy its values into the row.
                    $o = Get-OnPremStatus $sam $upn $name
                    $r.adMobile = $o.mobile; $r.adPhone = $o.phone; $r.adFound = $o.found; $r.adEnabled = $o.enabled; $r.adExpires = $o.expires; $r.adLocked = $o.locked; $r.adPwdSet = $o.pwdSet; $r.adNote = $o.note
                }
                $results += [pscustomobject]$r
            }
        }
        # Send all rows back to the browser.
        Send $ctx @{ ok = $true; results = $results; more = $more }
}

# /api/enable - request: $d.upn. Turns on a cloud-only Entra account (AccountEnabled = true). Needs User.ReadWrite.All.
$ScreenHandlers['/api/enable'] = {
        if (-not $script:Who) { throw 'Not connected. Sign in first.' }
        $u = Get-MgUser -UserId "$($d.upn)" -Property Id, UserPrincipalName, OnPremisesSyncEnabled
        # Synced accounts are controlled by AD; a change in Entra would be overwritten, so it is refused.
        if ($u.OnPremisesSyncEnabled) { throw 'This account is synced from on-premises AD. Enable it in Active Directory.' }
        Update-MgUser -UserId $u.Id -AccountEnabled:$true
        Write-Log @{ upn = $u.UserPrincipalName; exists = 'Yes'; enabled = 'Enabled'; type = '-'; pwdExpiry = '-'; synced = 'No (cloud)' } 'enable' 'Account enabled'
        Send $ctx @{ ok = $true }
}

# /api/disable - request: $d.upn. Turns off a cloud-only Entra account. Same rules as enable, plus a safety check below.
$ScreenHandlers['/api/disable'] = {
        if (-not $script:Who) { throw 'Not connected. Sign in first.' }
        $u = Get-MgUser -UserId "$($d.upn)" -Property Id, UserPrincipalName, OnPremisesSyncEnabled
        # Safety: stop the operator locking themselves out.
        if ("$($u.UserPrincipalName)" -ieq "$($script:Who)" -or "$($u.UserPrincipalName)" -ieq "$($script:WhoUpn)") { throw 'You cannot disable the account you are signed in with.' }
        if ($u.OnPremisesSyncEnabled) { throw 'This account is synced from on-premises AD. Disable it in Active Directory.' }
        Update-MgUser -UserId $u.Id -AccountEnabled:$false
        Write-Log @{ upn = $u.UserPrincipalName; exists = 'Yes'; enabled = 'Disabled'; type = '-'; pwdExpiry = '-'; synced = 'No (cloud)' } 'disable' 'Account disabled'
        Send $ctx @{ ok = $true }
}

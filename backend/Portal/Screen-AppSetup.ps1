# Screen-AppSetup.ps1 - "Create the Microsoft app automatically" (Settings > Connections > Microsoft app). Administrators only.
# Screen: App setup (Settings > Connections)
# Screen version: 2.6.1   (changes ONLY when this screen changes - not with every release)
# Loaded by server.ps1 at start-up; do not run it on its own.
#
# A Global Administrator signs in ONCE with a code (through Microsoft's own Azure CLI app, which every tenant has), and the
# portal then creates its own app registration "Admin Console" with ONLY the permissions for the parts you tick, gives admin
# consent, adds a client secret when one is needed (Mailbox cleanup), and saves it in Settings. That admin sign-in is used only
# for this and is not kept.

# WHAT THIS SCREEN DOES: automatically creates (or updates) the portal's own Microsoft Entra app registration, so nobody has to do it by hand in the Azure portal.
# ENDPOINTS: /api/appsetup-info (list of feature choices), /api/appsetup-start (begin device-code sign-in), /api/appsetup-poll (finish and create the app).
# MICROSOFT CALLS: login.microsoftonline.com device-code + token endpoints; Microsoft Graph v1.0 (applications, servicePrincipals,
# oauth2PermissionGrants, appRoleAssignedTo, addPassword). The signed-in admin needs Global Administrator rights.
# DATA: the result (client ID, tenant, encrypted secret) is saved to the Microsoft app settings file ($script:MsAppFile) via Get-MsAppCfg.
# PERMISSION: administrators only. The Global Admin's own token is used only during this run and is never stored.
#
# Client ID of Microsoft's own Azure CLI app. It is used only for the admin's one-time device-code sign-in.
$script:AsClient = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'   # Microsoft Azure CLI (first-party, present in every tenant)
# Sign-ins in progress, one per portal session: device code, tenant, expiry time and the options the admin chose.
$global:AsPending = @{}
# what each part of the portal needs (resource app id -> delegated scopes / application roles)
# The parts of the portal the admin can tick. Each entry lists what it needs: 'graph' = delegated Graph permissions, 'graphRoles' = application
# permissions, 'exo' = Exchange Online, 'spo' = SharePoint, 'secret' = a client secret must be created. Only ticked parts get permissions.
$script:AsFeatures = [ordered]@{
    base     = @{ label = 'Basic (always): users, passwords, MFA, groups, Teams, guests, e-mail, logs to SharePoint, audit logs'; graph = @('User.Read', 'User.Read.All', 'User.ReadWrite.All', 'LicenseAssignment.ReadWrite.All', 'Directory.Read.All', 'Domain.Read.All', 'User.EnableDisableAccount.All', 'User-PasswordProfile.ReadWrite.All', 'UserAuthenticationMethod.ReadWrite.All', 'Group.ReadWrite.All', 'Mail.Send', 'Mail.Send.Shared', 'Sites.ReadWrite.All', 'User.Invite.All', 'AuditLog.Read.All', 'openid', 'profile', 'offline_access') }
    reports  = @{ label = 'OneDrive & storage: usage reports (GB used per OneDrive, site, mailbox)'; graph = @('Reports.Read.All') }
    intune   = @{ label = 'Devices (Intune): read, delete and retire devices, delete Entra devices'; graph = @('DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'Device.ReadWrite.All') }
    exo      = @{ label = 'Exchange Online without a window (Distribution groups, Shared mailbox, Address list)'; exo = @('Exchange.Manage') }
    spo      = @{ label = 'OneDrive delete / size with the same sign-in (SharePoint admin)'; spo = @('AllSites.FullControl') }
    mailbox  = @{ label = 'Mailbox cleanup (APPLICATION permissions Mail.ReadWrite and User.Read.All + a client secret)'; graphRoles = @('Mail.ReadWrite', 'User.Read.All'); secret = $true }
}
# Endpoint: /api/appsetup-info - no input. Sends the list of features (key + label) and the client ID currently saved.
$ScreenHandlers['/api/appsetup-info'] = {
    Send $ctx @{ ok = $true; features = @($script:AsFeatures.Keys | ForEach-Object { @{ key = $_; label = $script:AsFeatures[$_].label } }); current = "$((Get-MsAppCfg).clientId)" }
}
# Endpoint: /api/appsetup-start - body { features[], redirects[], name, tenant }. Validates the input and asks Microsoft for a device code.
# Sends { userCode, url, interval, expires }: the admin opens the url and types the code. The page then calls /api/appsetup-poll.
$ScreenHandlers['/api/appsetup-start'] = {
    # Keep only known feature keys; 'base' is always included.
    $feat = @(@($d.features) | ForEach-Object { "$_" } | Where-Object { $script:AsFeatures.Contains($_) }); if ($feat -notcontains 'base') { $feat = @('base') + $feat }
    # Sign-in addresses must be https://host[:port]/ or http://localhost[:port]/ (trailing slash required). Duplicates are removed.
    $redir = @(@($d.redirects) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^(https://[A-Za-z0-9.-]+(:\d+)?/|http://localhost(:\d+)?/)$' } | Select-Object -Unique)
    if (-not $redir.Count) { throw 'Add at least one sign-in address: https://your-portal/ or http://localhost:8080/' }
    $name = "$($d.name)".Trim(); if (-not $name) { $name = 'Admin Console' }; if ($name.Length -gt 80) { throw 'The name is too long.' }
    # Tenant: a domain name or directory ID. 'organizations' lets any work account sign in when the admin leaves it empty.
    $ten = "$($d.tenant)".Trim(); if (-not $ten) { $ten = 'organizations' } elseif ($ten -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'The tenant must be a domain or a directory ID.' }
    # Step 1 of the device-code flow. The scope asks for Graph with the rights of the signed-in admin (.default) plus a refresh token.
    try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$ten/oauth2/v2.0/devicecode" -Body @{ client_id = $script:AsClient; scope = 'https://graph.microsoft.com/.default offline_access' } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch { $m = $_.Exception.Message; try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.error_description) { $m = ("$($j.error_description)" -split "`r?`n")[0] } } catch {}; throw "Microsoft did not give a sign-in code: $m" }
    # Remember the pending sign-in for this portal session until the admin finishes (or the code expires).
    $global:AsPending[(Get-SessId $script:Session)] = @{ code = "$($r.device_code)"; tenant = $ten; until = (Get-Date).AddSeconds([int]$r.expires_in); features = $feat; redirects = $redir; name = $name }
    Send $ctx @{ ok = $true; userCode = "$($r.user_code)"; url = "$($r.verification_uri)"; interval = [int]$r.interval; expires = [int]$r.expires_in }
}
# Calls Microsoft Graph v1.0 with the admin's access token. $tok = token, $method = GET/POST/PATCH, $uri = path after /v1.0/, $body = object sent as JSON (or $null).
# Returns the parsed answer. On an error it throws the readable Graph message instead of the generic web error text.
function Invoke-AsG($tok, $method, $uri, $body) {
    $h = @{ Authorization = "Bearer $tok" }
    try {
        if ($null -ne $body) { return Invoke-RestMethod -Method $method -Uri "https://graph.microsoft.com/v1.0/$uri" -Headers $h -Body ($body | ConvertTo-Json -Depth 8) -ContentType 'application/json' -ErrorAction Stop }
        Invoke-RestMethod -Method $method -Uri "https://graph.microsoft.com/v1.0/$uri" -Headers $h -ErrorAction Stop
    } catch { $m = $_.Exception.Message; try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.error.message) { $m = "$($j.error.message)" } } catch {}; throw $m }
}
# Endpoint: /api/appsetup-poll - no input. Called repeatedly by the page. While the admin has not finished signing in it answers { pending = true }.
# When the token arrives it does the whole job: find permission IDs, create/update the app, give admin consent, make a secret if needed and save settings.
$ScreenHandlers['/api/appsetup-poll'] = {
    $k = Get-SessId $script:Session; $pd = $global:AsPending[$k]
    if (-not $pd) { throw 'Start "Create the app automatically" again.' }
    # The device code lives only a few minutes (expires_in from Microsoft).
    if ((Get-Date) -gt $pd.until) { $global:AsPending.Remove($k); throw 'The code has expired. Start again.' }
    # Step 2 of the device-code flow: ask for the token. Microsoft refuses until the admin has signed in, which is normal while waiting.
    try { $t = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($pd.tenant)/oauth2/v2.0/token" -Body @{ client_id = $script:AsClient; grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = $pd.code } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch {
        # Work out Microsoft's error code (for example authorization_pending) from the error body.
        $m = $_.Exception.Message; $code = ''
        try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; $code = "$($j.error)"; if ($j.error_description) { $m = ("$($j.error_description)" -split "`r?`n")[0] } } catch {}
        # Fallback when the body cannot be read: treat a plain HTTP 400 as 'still waiting'.
        if (-not $code -and $m -match '\(400\)') { $code = 'authorization_pending' }   # v2.4.3: the answer could not be read - while waiting Microsoft answers 400, so keep waiting (the code expiry still ends it)
        # Still waiting for the admin: tell the page to ask again. Any other error ends the attempt.
        if ($code -in 'authorization_pending', 'slow_down') { Send $ctx @{ ok = $true; pending = $true }; return }
        $global:AsPending.Remove($k); throw "Sign-in failed: $m"
    }
    $global:AsPending.Remove($k)
    # Read the tenant ID (tid) and the admin's name (upn) from the token, for the saved settings and the activity log.
    $tok = "$($t.access_token)"; $tid = "$((Get-IdClaims $tok).tid)"; $asWho = "$((Get-IdClaims $tok).upn)"
    # $steps collects the plain-language progress lines that are sent back to the page at the end.
    $steps = New-Object Collections.Generic.List[string]
    # the permission ids of Microsoft Graph, Exchange Online and SharePoint in this tenant (looked up - nothing hard-coded)
    # Helper: finds the service principal of a Microsoft app (Graph, Exchange, SharePoint) in this tenant, to read its permission IDs.
    $sp = { param($appId) @((Invoke-AsG $tok GET "servicePrincipals?`$filter=appId eq '$appId'&`$select=id,appId,oauth2PermissionScopes,appRoles" $null).value)[0] }
    # 00000003-0000-0000-c000-000000000000 is the fixed ID of Microsoft Graph.
    $graph = & $sp '00000003-0000-0000-c000-000000000000'; if (-not $graph) { throw 'Microsoft Graph was not found in the tenant.' }
    $res = [ordered]@{}   # appId -> @{ sp; scopes; roles }
    # Helper: adds the wanted delegated scopes / application roles to $res under the resource app they belong to, without duplicates.
    $add = { param($spo, $scopes, $roles) if (-not $spo) { return }; $a = "$($spo.appId)"; if (-not $res.Contains($a)) { $res[$a] = @{ sp = $spo; scopes = New-Object Collections.Generic.List[string]; roles = New-Object Collections.Generic.List[string] } }; foreach ($s in @($scopes)) { if ($s -and -not $res[$a].scopes.Contains($s)) { $res[$a].scopes.Add($s) } }; foreach ($s in @($roles)) { if ($s -and -not $res[$a].roles.Contains($s)) { $res[$a].roles.Add($s) } } }
    # Go through the ticked features and collect the permissions. Exchange Online (00000002-0000-0ff1-ce00-...) and SharePoint (00000003-0000-0ff1-ce00-...)
    # are only used if they exist in the tenant.
    $needSecret = $false
    foreach ($f in $pd.features) {
        $fd = $script:AsFeatures[$f]
        if ($fd.graph) { & $add $graph $fd.graph @() }
        if ($fd.graphRoles) { & $add $graph @() $fd.graphRoles }
        if ($fd.exo) { $x = & $sp '00000002-0000-0ff1-ce00-000000000000'; if ($x) { & $add $x $fd.exo @() } else { $steps.Add('Exchange Online is not in this tenant - skipped.') } }
        if ($fd.spo) { $x = & $sp '00000003-0000-0ff1-ce00-000000000000'; if ($x) { & $add $x $fd.spo @() } else { $steps.Add('SharePoint is not in this tenant - skipped.') } }
        if ($fd.secret) { $needSecret = $true }
    }
    # Convert permission NAMES into the permission IDs Microsoft needs ('requiredResourceAccess'). Names not found in this tenant are listed in $missing.
    $rra = @(); $missing = @()
    foreach ($a in $res.Keys) {
        $o = $res[$a]; $acc = @()
        foreach ($s in $o.scopes) { $x = @($o.sp.oauth2PermissionScopes | Where-Object { $_.value -eq $s })[0]; if ($x) { $acc += @{ id = "$($x.id)"; type = 'Scope' } } elseif ($s -notin 'openid', 'profile', 'offline_access') { $missing += $s } }
        foreach ($s in $o.roles) { $x = @($o.sp.appRoles | Where-Object { $_.value -eq $s })[0]; if ($x) { $acc += @{ id = "$($x.id)"; type = 'Role' } } else { $missing += "$s (application)" } }
        # openid/profile/offline_access are standard sign-in scopes; they are added to the app but never reported as missing.
        foreach ($s in @('openid', 'profile', 'offline_access')) { if ($o.scopes.Contains($s)) { $x = @($o.sp.oauth2PermissionScopes | Where-Object { $_.value -eq $s })[0]; if ($x) { $acc += @{ id = "$($x.id)"; type = 'Scope' } } } }
        if ($acc.Count) { $rra += @{ resourceAppId = $a; resourceAccess = @($acc | Sort-Object { $_.id } -Unique) } }
    }
    # Tell the admin which permissions were left out.
    if ($missing.Count) { $steps.Add('Not found in this tenant (left out): ' + ($missing -join ', ')) }
    # 1) the app registration. v2.4.4: if the portal's app already exists (the saved one, or one with the same name) it is UPDATED -
    #    the permissions and sign-in addresses are added to it - instead of creating a second app.
    # v2.6.1: the single sign-on (OIDC) address is added as a Web redirect too, so Settings > Single sign-on can use this same app and secret
    # Address for single sign-on (OIDC callback) so the same app can be used by Settings > Single sign-on. Ignored if SSO is not configured.
    $ssoWeb = @(); try { $ssoWeb = @("$((Get-SsoCfg).baseUrl)".TrimEnd('/') + '/sso/oidc/callback') } catch {}
    # Look for an existing app to update instead of creating a second one: first the saved client ID (if it is a GUID and belongs to this tenant),
    # then an app with the same display name (only if exactly one exists; several matches are reported and nothing is guessed).
    $cfg0 = Get-MsAppCfg; $app = $null; $updated = $false
    try {
        if ("$($cfg0.clientId)" -match '^[0-9a-fA-F-]{36}$' -and ("$($cfg0.tenant)" -eq $tid -or -not "$($cfg0.tenant)" -or "$($cfg0.tenant)" -notmatch '^[0-9a-fA-F-]{36}$')) { $app = @((Invoke-AsG $tok GET "applications?`$filter=appId eq '$($cfg0.clientId)'&`$select=id,appId,displayName,requiredResourceAccess,publicClient,web" $null).value)[0] }
        if (-not $app) { $nm = "$($pd.name)".Replace("'", "''"); $same = @((Invoke-AsG $tok GET "applications?`$filter=displayName eq '$nm'&`$select=id,appId,displayName,requiredResourceAccess,publicClient,web" $null).value); if ($same.Count -eq 1) { $app = $same[0] } elseif ($same.Count -gt 1) { $steps.Add("There are $($same.Count) apps named '$($pd.name)' - the newest one is updated.") ; $app = $same[-1] } }
    } catch { $app = $null }
    # Update path: PATCH the existing app. Permissions and addresses are only ADDED, nothing is removed.
    if ($app) {
        # merge the permissions: keep what the app has, add what was ticked
        $merged = [ordered]@{}
        # Start from the permissions the app already has, then add the new ones that are not there yet.
        foreach ($r in @($app.requiredResourceAccess)) { $merged["$($r.resourceAppId)"] = @(@($r.resourceAccess) | ForEach-Object { @{ id = "$($_.id)"; type = "$($_.type)" } }) }
        foreach ($r in $rra) { $have = @($merged["$($r.resourceAppId)"]); foreach ($x in $r.resourceAccess) { if (-not ($have | Where-Object { $_.id -eq $x.id -and $_.type -eq $x.type })) { $have += $x } }; $merged["$($r.resourceAppId)"] = $have }
        $rraAll = @($merged.Keys | ForEach-Object { @{ resourceAppId = $_; resourceAccess = @($merged[$_]) } })
        $uris = @(@($app.publicClient.redirectUris) + @($pd.redirects) | Where-Object { $_ } | Select-Object -Unique)
        $webU = @(@($app.web.redirectUris) + @($ssoWeb) | Where-Object { $_ } | Select-Object -Unique)
        # isFallbackPublicClient lets the portal sign in without a secret (public client); redirect URIs are the allowed sign-in addresses.
        [void](Invoke-AsG $tok PATCH "applications/$($app.id)" @{ requiredResourceAccess = $rraAll; isFallbackPublicClient = $true; publicClient = @{ redirectUris = $uris }; web = @{ redirectUris = $webU } })
        $updated = $true
        $steps.Add("Existing app '$($app.displayName)' updated (client ID $($app.appId)) - no new app was created. Permissions were added; nothing was removed.")
    } else {
        # Create path: a new single-tenant app (AzureADMyOrg) with the chosen permissions and addresses.
        $app = Invoke-AsG $tok POST 'applications' @{ displayName = $pd.name; signInAudience = 'AzureADMyOrg'; isFallbackPublicClient = $true; publicClient = @{ redirectUris = @($pd.redirects) }; web = @{ redirectUris = @($ssoWeb) }; requiredResourceAccess = $rra; notes = "Created by the Admin Console portal on $(Get-Date -Format 'yyyy-MM-dd') by $asWho." }
        $steps.Add("App registration '$($pd.name)' created (client ID $($app.appId)).")
    }
    # The app needs an 'enterprise application' (service principal) in the tenant before consent can be given.
    $me = @((Invoke-AsG $tok GET "servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id" $null).value)[0]
    # Create it. Right after the app is created Entra may need a moment to replicate, so retry up to 10 times, 2 seconds apart.
    if (-not $me) { for ($i = 0; $i -lt 10 -and -not $me; $i++) { try { $me = Invoke-AsG $tok POST 'servicePrincipals' @{ appId = "$($app.appId)" } } catch { if ($i -ge 9) { throw }; Start-Sleep -Seconds 2 } }; $steps.Add('Enterprise application created.') }
    # 2) admin consent: delegated permissions for everyone in the organization (existing consent is extended), and application permissions (only the missing ones)
    # Application permissions that are already granted (resourceId|roleId), so they are not granted twice.
    $assigned = @(); try { $assigned = @((Invoke-AsG $tok GET "servicePrincipals/$($me.id)/appRoleAssignments" $null).value | ForEach-Object { "$($_.resourceId)|$($_.appRoleId)" }) } catch {}
    # For every resource (Graph, Exchange, SharePoint): grant delegated permissions for all users, then application permissions.
    foreach ($a in $res.Keys) {
        $o = $res[$a]
        if ($o.scopes.Count) {
            # Delegated consent: if a tenant-wide grant already exists it is extended with the new scopes, otherwise a new one is created.
            $g = $null; try { $g = @((Invoke-AsG $tok GET "oauth2PermissionGrants?`$filter=clientId eq '$($me.id)' and resourceId eq '$($o.sp.id)' and consentType eq 'AllPrincipals'" $null).value)[0] } catch {}
            if ($g) { $all = @(("$($g.scope)" -split '\s+') + @($o.scopes) | Where-Object { $_ } | Select-Object -Unique); [void](Invoke-AsG $tok PATCH "oauth2PermissionGrants/$($g.id)" @{ scope = ($all -join ' ') }) }
            else { [void](Invoke-AsG $tok POST 'oauth2PermissionGrants' @{ clientId = "$($me.id)"; consentType = 'AllPrincipals'; resourceId = "$($o.sp.id)"; scope = ($o.scopes -join ' ') }) }
            $steps.Add("Admin consent given: $($o.scopes -join ', ')")
        }
        # Application permissions: skip ones already granted, otherwise assign the role to the app (this is the admin consent for roles).
        foreach ($s in $o.roles) { $x = @($o.sp.appRoles | Where-Object { $_.value -eq $s })[0]; if (-not $x) { continue }
            if ($assigned -contains "$($o.sp.id)|$($x.id)") { $steps.Add("Application permission already granted: $s"); continue }
            [void](Invoke-AsG $tok POST "servicePrincipals/$($o.sp.id)/appRoleAssignedTo" @{ principalId = "$($me.id)"; resourceId = "$($o.sp.id)"; appRoleId = "$($x.id)" }); $steps.Add("Application permission granted: $s") }
    }
    # 3) a client secret only when a part needs it (Mailbox cleanup) - an existing saved secret of the same app is kept
    # The client secret (only for Mailbox cleanup). Keep a saved secret of the same app when Microsoft still accepts it; otherwise create a new one.
    $secretEnc = ''
    $sameApp = ("$($cfg0.clientId)" -eq "$($app.appId)")
    if ($sameApp -and "$($cfg0.secretEnc)") {
        # v2.4.5: keep the saved secret only if Microsoft still accepts it (it may be expired, deleted, or the secret ID was saved instead of the value)
        $okSec = $false
        # Test the saved secret with a real client-credentials token request. Up to 3 tries, because a new secret can take a few seconds to work.
        for ($i = 0; $i -lt 3 -and -not $okSec; $i++) {
            try { $sv = Unprotect-MailSecret "$($cfg0.secretEnc)"; [void](Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tid/oauth2/v2.0/token" -Body @{ client_id = "$($app.appId)"; client_secret = $sv; grant_type = 'client_credentials'; scope = 'https://graph.microsoft.com/.default' } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop); $okSec = $true }
            catch { $em = "$(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message })"; if ($em -match 'AADSTS7000215|AADSTS7000222|AADSTS7000216|invalid_client|Key not valid|decrypt') { break }; Start-Sleep -Seconds 2 }
        }
        # Microsoft error codes AADSTS7000215/7000222/7000216 = wrong, expired or unknown secret; those stop the retries at once.
        if ($okSec) { $secretEnc = "$($cfg0.secretEnc)" } else { $steps.Add('The saved client secret is not valid any more (expired, deleted or wrong value) - a new one is made.') }
    }
    # Create a new secret valid for 24 months. It is shown by Microsoft only once, so it is encrypted (Protect-MailSecret) and saved straight away.
    if ($needSecret -and -not $secretEnc) { $pw = Invoke-AsG $tok POST "applications/$($app.id)/addPassword" @{ passwordCredential = @{ displayName = 'Admin Console portal'; endDateTime = (Get-Date).AddMonths(24).ToUniversalTime().ToString('o') } }; $secretEnc = Protect-MailSecret "$($pw.secretText)"; $steps.Add('Client secret created (valid 2 years) and stored encrypted in the portal.') }
    elseif ($needSecret) { $steps.Add('The saved client secret is kept.') }
    # 4) save it in Settings > Connections > Microsoft app
    # Save the new client ID, tenant and encrypted secret as the portal's Microsoft app settings.
    $c = Get-MsAppCfg; $c.clientId = "$($app.appId)"; $c.tenant = $tid; $c.exo = (($pd.features -contains 'exo') -or ($sameApp -and [bool]$cfg0.exo)); $c.secretEnc = $secretEnc
    ($c | ConvertTo-Json) | Out-File $script:MsAppFile -Encoding utf8
    $steps.Add('Saved in Settings > Connections > Microsoft app.')
    # Activity log entry; a logging problem must never break the setup.
    try { Write-ActRow 'Settings' $(if ($updated) { 'Update Microsoft app' } else { 'Create Microsoft app' }) "$($app.appId)" "Done - by $asWho" (($pd.features) -join ',') } catch {}
    Send $ctx @{ ok = $true; done = $true; updated = $updated; clientId = "$($app.appId)"; tenant = $tid; steps = @($steps); by = $asWho }
}

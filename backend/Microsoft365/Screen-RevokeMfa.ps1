# Screen-RevokeMfa.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Revoke MFA
# Screen version: 2.6.2   (changes ONLY when this screen changes - not with every release)


# Revoke MFA screen - endpoints: /api/mfa-list (one user's sign-in methods), /api/mfa-list-many (up to 200 users),
# /api/mfa-mail (email set-up instructions), /api/mfa-revoke (remove methods / Temporary Access Pass / sign out), /api/mfa-log (download log).
# Uses Microsoft Graph: users, users/{id}/authentication/methods, DELETE authentication/<type>/<id>, revokeSignInSessions, $batch,
# and the mail-sending helpers (Send-ToolMail). Cloud (Entra) accounts only. Needs the Microsoft sign-in ($script:Who) with rights such as
# UserAuthenticationMethod.ReadWrite.All, User.ReadWrite.All (revoke sessions) and Mail.Send. Data file: mfa-audit-YYYY-MM.csv in $LogDir.
#
# Write-MfaLog - adds one line to this month's MFA audit CSV.
# Inputs: $upn target user, $action text, $methods removed (list), $failed (list), $signed (Yes/No/-), $result (free text).
function Write-MfaLog($upn, $action, $methods, $failed, $signed, $result) {
    $f = Join-Path $LogDir ('mfa-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    # New month = new file, so write the header line first.
    if (-not (Test-Path $f)) { 'Time,WindowsUser,Admin,Target,Action,MethodsRemoved,Failed,SignedOut,Result' | Out-File $f -Encoding utf8 }
    # Columns: time, Windows user running the tool, signed-in admin, target, action, methods, failures, signed-out flag, result.
    # Each value goes through ConvertTo-CsvCell so commas and quotes cannot break the CSV.
    $vals = @(('{0:s}' -f (Get-Now)), [Security.Principal.WindowsIdentity]::GetCurrent().Name, $script:Who, $upn, $action, (@($methods) -join '; '), (@($failed) -join '; '), $signed, $result) |
        ForEach-Object { ConvertTo-CsvCell $_ }
    ($vals -join ',') | Add-Content $f
}

# Table: Graph method type -> seg (URL part used to delete it), label (shown to the operator) and kind:
# mfa = real second-factor methods (removed by 'Remove MFA'), tap = Temporary Access Pass, other = recovery email / Windows Hello etc. (only on request).
$MfaTypes = @{
    '#microsoft.graph.phoneAuthenticationMethod'                  = @{ seg = 'phoneMethods'; label = 'Phone'; kind = 'mfa' }
    '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod' = @{ seg = 'microsoftAuthenticatorMethods'; label = 'Microsoft Authenticator'; kind = 'mfa' }
    '#microsoft.graph.softwareOathAuthenticationMethod'           = @{ seg = 'softwareOathMethods'; label = 'Authenticator app (code)'; kind = 'mfa' }
    '#microsoft.graph.fido2AuthenticationMethod'                  = @{ seg = 'fido2Methods'; label = 'Security key / passkey (FIDO2)'; kind = 'mfa' }
    '#microsoft.graph.hardwareOathAuthenticationMethod'           = @{ seg = 'hardwareOathMethods'; label = 'Hardware token (OATH)'; kind = 'mfa' }
    '#microsoft.graph.temporaryAccessPassAuthenticationMethod'    = @{ seg = 'temporaryAccessPassMethods'; label = 'Temporary Access Pass'; kind = 'tap' }
    '#microsoft.graph.emailAuthenticationMethod'                  = @{ seg = 'emailMethods'; label = 'Recovery email'; kind = 'other' }
    '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' = @{ seg = 'windowsHelloForBusinessMethods'; label = 'Windows Hello for Business'; kind = 'other' }
    '#microsoft.graph.platformCredentialAuthenticationMethod'     = @{ seg = 'platformCredentialMethods'; label = 'Platform credential (Mac)'; kind = 'other' }
}

# Returns the sign-in methods of a user (by object id) as a clean list. Calls GET users/{id}/authentication/methods.
function Get-MfaMethods($userId) {
    ConvertTo-MfaMethods (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$userId/authentication/methods" -ErrorAction Stop).value
}

# Fields read for every user (only what the screen needs, so calls are fast).
# v2.4.0: faster - plain Graph REST calls with only the fields needed (no Get-MgUser), and many users in one $batch
$script:MfaUserSel = 'id,userPrincipalName,displayName,givenName,surname,accountEnabled,onPremisesSyncEnabled,mail,otherMails'
# Small wrapper: GET a Graph v1.0 path. -Eventual adds ConsistencyLevel: eventual, which Graph needs for advanced filters / $count.
function Invoke-MfaG($uri, [switch]$Eventual) { $h = @{}; if ($Eventual) { $h.ConsistencyLevel = 'eventual' }; Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/$uri" -Headers $h -ErrorAction Stop }
# Turns a raw Graph user (lower-case JSON names) into an object with the property names used in the rest of this file.
function ConvertTo-MfaUser($u) { [pscustomobject]@{ Id = "$($u.id)"; UserPrincipalName = "$($u.userPrincipalName)"; DisplayName = "$($u.displayName)"; GivenName = "$($u.givenName)"; Surname = "$($u.surname)"; AccountEnabled = $u.accountEnabled; OnPremisesSyncEnabled = $u.onPremisesSyncEnabled; Mail = "$($u.mail)"; OtherMails = @($u.otherMails | Where-Object { $_ } | ForEach-Object { "$_" }) } }
# Finds ONE cloud account from what the operator typed (email, UPN, object id, or just a username). Throws a clear message if none or several match.
# Order: direct lookup if it has @ or is a GUID, then mail/UPN filter, then (username only) UPN prefix, mailNickname, on-prem sAMAccountName.
function Find-CloudUser($name) {
    $n = "$name".Trim()
    if (-not $n) { throw 'Type the username or email of the user.' }
    # These characters would change the Graph URL, so they are refused.
    if ($n -match '[\\/?#]') { throw 'That is not a valid username or email.' }
    $sel = $script:MfaUserSel
    # Has an @ or looks like a GUID (36 hex chars and dashes): try a direct lookup; if it fails, fall through to the filters.
    if ($n -match '@' -or $n -match '^[0-9a-fA-F-]{36}$') { try { return (ConvertTo-MfaUser (Invoke-MfaG "users/$([uri]::EscapeDataString($n))?`$select=$sel")) } catch {} }
    # Single quotes are doubled so the name is safe inside an OData filter string.
    $q = $n.Replace("'", "''")
    $f = @((Invoke-MfaG "users?`$filter=$([uri]::EscapeDataString("mail eq '$q' or userPrincipalName eq '$q'"))&`$select=$sel&`$top=2").value)
    if ($f.Count -eq 1) { return (ConvertTo-MfaUser $f[0]) }
    if ($f.Count -gt 1) { throw "More than one account matches $n. Type the full sign-in name (UPN)." }
    if ($n -notmatch '@') {
        # Username only (no domain): the part before the @, the mail nickname, or the on-premises username
        foreach ($flt in "startsWith(userPrincipalName,'$q@')", "mailNickname eq '$q'", "onPremisesSamAccountName eq '$q'") {
            $f = @(); try { $f = @((Invoke-MfaG "users?`$filter=$([uri]::EscapeDataString($flt))&`$select=$sel&`$top=10&`$count=true" -Eventual).value) } catch {}
            if ($f.Count -eq 1) { return (ConvertTo-MfaUser $f[0]) }
            if ($f.Count -gt 1) { throw ("'$n' matches several accounts (" + ((@($f | Select-Object -First 5 | ForEach-Object { "$($_.userPrincipalName)" })) -join ', ') + "). Type the full sign-in name (UPN).") }
        }
    }
    throw "No cloud account found for $n."
}
# Converts the Graph list of methods into simple rows { id, seg, label, kind, detail }. Method types not in $MfaTypes are ignored.
# detail = the phone number, email address, TAP lifetime, or device name, shown next to the label.
function ConvertTo-MfaMethods($value) {
    $out = @()
    foreach ($m in @($value)) {
        $t = $MfaTypes["$($m['@odata.type'])"]; if (-not $t) { continue }
        $detail = switch ($t.seg) {
            'phoneMethods' { ("$($m['phoneType']) $($m['phoneNumber'])").Trim() }
            'emailMethods' { "$($m['emailAddress'])" }
            'temporaryAccessPassMethods' { $x = "lifetime $($m['lifetimeInMinutes']) min"; if ($m['isUsableOnce']) { $x += ', one-time' }; if ($m['methodUsabilityReason']) { $x += ", $($m['methodUsabilityReason'])" }; $x }
            'softwareOathMethods' { '' }
            default { "$($m['displayName'])" }
        }
        $label = $t.label; if ($t.seg -eq 'phoneMethods' -and $m['phoneType']) { $label = "Phone ($($m['phoneType']))" }
        $out += @{ id = "$($m['id'])"; seg = $t.seg; label = $label; kind = $t.kind; detail = $detail }
    }
    $out
}
# Builds the answer for the browser for one user: name, enabled state, synced flag, all email addresses and the list of methods.
function Get-MfaUserView($u, $methods) {
    $en = if ($null -eq $u.AccountEnabled) { 'Unknown' } elseif ($u.AccountEnabled) { 'Enabled' } else { 'Disabled' }
    # Collect all real email addresses of the user (mail + other mails), trimmed and without duplicates - used as targets for the set-up email.
    $mails = @(@($u.Mail) + @($u.OtherMails) | Where-Object { "$_" -match '@' } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
    @{ ok = $true; upn = $u.UserPrincipalName; displayName = "$($u.DisplayName)"; given = "$($u.GivenName)"; sn = "$($u.Surname)"; enabled = $en; synced = [bool]$u.OnPremisesSyncEnabled; mails = $mails
       methods = @($methods | ForEach-Object { @{ id = $_.id; kind = $_.kind; label = $_.label; detail = $_.detail } }) }
}
# /api/mfa-list - request: $d.upn (name, email or UPN). Returns the user and the sign-in methods.
$ScreenHandlers['/api/mfa-list'] = {
        if (-not $script:Who) { throw 'Not connected. Sign in first.' }
        $u = Find-CloudUser $d.upn
        Send $ctx (Get-MfaUserView $u @(Get-MfaMethods $u.Id))
}
# /api/mfa-list-many - request: $d.names (list, max 200). Returns { users = one entry per name, in the same order; failures have ok=false + error }.
# Graph $batch allows 20 sub-requests per call, hence the chunks of 20 below.
# v2.4.0: many users at once - full addresses are read 20 at a time with Graph $batch (one request instead of 40); names without @ one by one
$ScreenHandlers['/api/mfa-list-many'] = {
        if (-not $script:Who) { throw 'Not connected. Sign in first.' }
        $names = @(@($d.names) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 200)
        # $res keeps the typed order; each name starts empty and is filled with its result later.
        $res = [ordered]@{}; foreach ($n in $names) { $res[$n] = $null }
        $found = @{}   # name -> user
        # Step 1: names with @ (and no URL-breaking characters) are read in batches of 20 with Graph $batch.
        $full = @($names | Where-Object { $_ -match '@' -and $_ -notmatch '[\\/?#]' })
        for ($i = 0; $i -lt $full.Count; $i += 20) {
            $chunk = @($full[$i..([Math]::Min($i + 19, $full.Count - 1))])
            # Build the list of sub-requests; the id ties each answer back to its name.
            $reqs = @(); for ($k = 0; $k -lt $chunk.Count; $k++) { $reqs += @{ id = "$k"; method = 'GET'; url = "/users/$([uri]::EscapeDataString($chunk[$k]))?`$select=$($script:MfaUserSel)" } }
            try { $br = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body (@{ requests = $reqs } | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop
                foreach ($r in @($br.responses)) { if ([int]$r.status -eq 200) { $found[$chunk[[int]$r.id]] = ConvertTo-MfaUser $r.body } } } catch {}
        }
        # Step 2: names the batch did not find (short usernames, or errors) are looked up one by one; a failure is stored as that name's error.
        foreach ($n in $names) { if (-not $found.ContainsKey($n)) { try { $found[$n] = Find-CloudUser $n } catch { $res[$n] = @{ ok = $false; name = $n; error = "$($_.Exception.Message)" } } } }
        # Step 3: read the sign-in methods of all found users, again 20 per $batch call.
        # the sign-in methods of everyone found, 20 users per $batch
        $ul = @($names | Where-Object { $found[$_] })
        $meth = @{}
        for ($i = 0; $i -lt $ul.Count; $i += 20) {
            $chunk = @($ul[$i..([Math]::Min($i + 19, $ul.Count - 1))])
            $reqs = @(); for ($k = 0; $k -lt $chunk.Count; $k++) { $reqs += @{ id = "$k"; method = 'GET'; url = "/users/$($found[$chunk[$k]].Id)/authentication/methods" } }
            # Send the batch; each answer has a status (200 = ok). Failed users get an error text instead of methods.
            $br = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body (@{ requests = $reqs } | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop
            foreach ($r in @($br.responses)) { $nm = $chunk[[int]$r.id]; if ([int]$r.status -eq 200) { $meth[$nm] = @(ConvertTo-MfaMethods $r.body.value) } else { $meth[$nm] = $null; $res[$nm] = @{ ok = $false; name = $nm; error = "Could not read the sign-in methods: $($r.body.error.message)" } } }
        }
        foreach ($n in $ul) { if ($null -ne $meth[$n]) { $v = Get-MfaUserView $found[$n] $meth[$n]; $v.name = $n; $res[$n] = $v } }
        Send $ctx @{ ok = $true; users = @($names | ForEach-Object { $res[$_] }) }
}
# Builds the HTML of the 'set up Authenticator again' email. $s = person { name, given, sn, upn, note }, $cfg = mail settings.
function New-MfaMailHtml($s, $cfg) { Format-EmailLayout 'mfa' (New-MfaMailHtmlRaw $s $cfg) }
# Does the real work for the email: text comes from the editable email templates (Get-EmailPart), English first and Arabic (right-to-left) below if it exists.
function New-MfaMailHtmlRaw($s, $cfg) {
    # Script block $h: makes text safe to put inside HTML.
    $h = { [Net.WebUtility]::HtmlEncode("$args") }
    $nm = Get-EmailNames 'mfa' $s.given $s.sn $s.name
    $v = @{ first = $nm.first; last = $nm.last; full = $nm.full; greet = $nm.greet; name = "$($s.name)"; upn = "$($s.upn)"; signature = "$(Get-EmailSigFirst $cfg.signature)" }
    # Link to the MFA registration page: the configured one if it starts with https://, otherwise Microsoft's default page.
    $url = if ("$($cfg.mfaUrl)" -match '^https://') { "$($cfg.mfaUrl)" } else { 'https://aka.ms/mysecurityinfo' }
    # Optional note typed by the operator, shown in a highlighted box (HTML-encoded).
    $note = "$($s.note)".Trim(); $noteHtml = if ($note) { '<div style="margin:14px 0;padding:12px 16px;background:#f1f5f9;border-left:4px solid #2563eb;border-radius:6px;white-space:pre-wrap">' + (& $h $note) + '</div>' } else { '' }
    # Placeholder values for the templates: English version, and the Arabic version (dir=ltr keeps the link readable inside right-to-left text).
    $rawE = @{ mfa_link = "<a href=""$(& $h $url)"" style=""color:#2563eb;font-weight:600"">$(& $h ($url -replace '^https://', ''))</a>"; note = $noteHtml }
    $rawA = @{ mfa_link = "<a href=""$(& $h $url)"" style=""color:#2563eb;font-weight:600"" dir=""ltr"">$(& $h ($url -replace '^https://', ''))</a>"; note = $noteHtml }
    $T = { param($k, $l, $raw) Get-EmailPart 'mfa' $k $l $v $raw }
    $pFoot = 'color:#64748b;font-size:12px'
    # English part: greeting, intro, numbered steps, button link, closing, footer and signature.
    $html = '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937;line-height:1.55">' +
        "<p>$(& $T 'hello' 'en' $rawE)</p><p>$(& $T 'intro' 'en' $rawE)</p>$noteHtml" +
        "<p style=""margin-bottom:4px""><b>$(& $T 'stepsTitle' 'en' $rawE)</b></p><ol style=""margin-top:0;padding-left:22px;line-height:1.7"">" + (Get-EmailItems 'mfa' 'steps' 'en' $v $rawE '') + '</ol>' +
        "<p style=""margin:18px 0""><a href=""$(& $h $url)"" style=""background:#2563eb;color:#ffffff;text-decoration:none;padding:11px 22px;border-radius:8px;font-weight:600;display:inline-block"">Open security info</a></p>" +
        "<p>$(& $T 'closing' 'en' $rawE)</p><p style=""$pFoot"">$(& $T 'footer' 'en' $rawE)</p>" + (Get-EmailSigHtml $cfg.signature)
    # Arabic part is added only when an Arabic intro text exists in the templates.
    if ((Get-EmailText 'mfa' 'intro' 'ar').Trim()) {
        $html += '<div dir="rtl" lang="ar" style="font-family:Segoe UI,Tahoma,Arial,sans-serif;font-size:15px;color:#1f2937;line-height:1.7;text-align:right;border-top:2px solid #e5e7eb;margin-top:22px;padding-top:14px">' +
            "<p>$(& $T 'hello' 'ar' $rawA)</p><p>$(& $T 'intro' 'ar' $rawA)</p>" +
            "<p style=""margin-bottom:4px""><b>$(& $T 'stepsTitle' 'ar' $rawA)</b></p><ol style=""margin-top:0;padding-right:22px;padding-left:0"">" + (Get-EmailItems 'mfa' 'steps' 'ar' $v $rawA '') + '</ol>' +
            "<p>$(& $T 'closing' 'ar' $rawA)</p><p style=""$pFoot"">$(& $T 'footer' 'ar' $rawA)</p>" + (Get-EmailSigHtml $cfg.signature -Rtl) + '</div>'
    }
    $html + '</div>'
}
# /api/mfa-mail - request: $d.upn, $d.to (list of addresses, max 5), $d.note (optional), $d.preview (true = only return the HTML).
# Sends through Microsoft Graph as the configured sender. Returns { ok, from, to } or, for preview, { html, subject }.
# v2.4.0: email the person how to set up Microsoft Authenticator again { upn, to:[addresses], note, preview }
$ScreenHandlers['/api/mfa-mail'] = {
        if (-not $script:Who) { throw 'Not connected. Sign in first.' }
        $c = Get-MailCfg
        $u = Find-CloudUser $d.upn
        $s = @{ name = $u.DisplayName; given = $u.GivenName; sn = $u.Surname; upn = $u.UserPrincipalName; note = "$($d.note)" }
        # Preview: show the email in the browser; the inline picture is embedded as base64 because the cid: image only exists in a real email.
        if ($d.preview) {
            $html = New-MfaMailHtml $s $c; $pi = Get-EmailImage 'mfa'; if ($pi) { $html = "$html".Replace('cid:emailimg', 'data:' + $pi.type + ';base64,' + [Convert]::ToBase64String($pi.bytes)) }
            Send $ctx @{ ok = $true; html = "$html"; subject = (Get-EmailSubject 'mfa') }; return
        }
        $to = @(@($d.to) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if (-not $to.Count) { throw 'Add at least one email address.' }
        # Regex: simple email check - something@something.something with no spaces, quotes, commas, semicolons or angle brackets.
        foreach ($a in $to) { if ($a -notmatch '^[^@\s<>",;]+@[^@\s<>",;]+\.[^@\s<>",;]+$') { throw "Not a valid email address: $a" } }
        if ($to.Count -gt 5) { throw 'At most 5 addresses per person.' }
        # Graph sendMail body: subject, HTML content and the recipients.
        $body = @{ message = @{ subject = (Get-EmailSubject 'mfa'); body = @{ contentType = 'HTML'; content = (New-MfaMailHtml $s $c) }; toRecipients = @($to | ForEach-Object { @{ emailAddress = @{ address = $_ } } }); importance = 'normal' }; saveToSentItems = [bool]$c.saveCopy }
        # Add the template's attachments / inline images, if any.
        $att = @(Get-EmailAttach 'mfa'); if ($att.Count) { $body.message.attachments = $att }
        # Send. On error the failure is written to the mail log in readable form before it is thrown again.
        try { $snd = Send-ToolMail "$($c.sender)" $body } catch { $m = Get-MailErr $_.Exception.Message; Write-MailLog $u.UserPrincipalName "$($c.sender)" ($to -join '; ') "Failed (Authenticator set-up email): $m"; throw "The email was not sent: $m" }
        Write-MailLog $u.UserPrincipalName $snd ($to -join '; ') 'Sent (Authenticator set-up email)'
        Write-MfaLog $u.UserPrincipalName 'email-setup' @() @() '-' "Set-up email sent to $($to -join ', ') from $snd"
        Send $ctx @{ ok = $true; from = $snd; to = $to }
}

# /api/mfa-revoke - request: $d.upn, $d.removeMfa, $d.removeTap, $d.methodIds (list), $d.signOut. Each option is separate.
# Returns { ok, removed, failed, signedOut, signOutError, reregister, leftMfa }. Everything is written to the MFA log and the main log.
$ScreenHandlers['/api/mfa-revoke'] = {
        if (-not $script:Who) { throw 'Not connected. Sign in first.' }
        # Separate choices, nothing happens that was not asked for:
        #   removeMfa  = remove all MFA methods (phone, Authenticator, code app, security key)
        #   removeTap  = delete the Temporary Access Pass
        #   methodIds  = remove exactly these methods of the user (any kind), one by one
        #   signOut    = sign the user out everywhere (they must log in again)
        # Read the choices as true/false (missing = false).
        $doRemove = $false; if ($null -ne $d.removeMfa) { $doRemove = [bool]$d.removeMfa }
        $doTap = $false; if ($null -ne $d.removeTap) { $doTap = [bool]$d.removeTap }
        $doSignOut = $false; if ($null -ne $d.signOut) { $doSignOut = [bool]$d.signOut }
        $ids = @(); if ($d.methodIds) { $ids = @($d.methodIds | ForEach-Object { "$_" }) }
        if (-not $doRemove -and -not $doTap -and -not $doSignOut -and -not $ids.Count) { throw 'Choose at least one action.' }
        # v2.5.3: removing the MFA methods = REQUIRE RE-REGISTER MFA: every sign-in session is always ended too, so the old phone / app
        # cannot be used any more and the person must register MFA again at the next sign-in. This is not optional.
        if ($doRemove) { $doSignOut = $true }
        # Build the action name for the log, e.g. 'mfa-revoke+sign-out'.
        $acts = @()
        if ($ids.Count) { $acts += 'remove-method' }
        if ($doRemove) { $acts += 'mfa-revoke' }
        if ($doTap) { $acts += 'tap-delete' }
        # Sign-out: revokeSignInSessions ends all refresh tokens, so the user must sign in again everywhere.
        if ($doSignOut) { $acts += 'sign-out' }
        $action = $acts -join '+'
        $target = "$($d.upn)"
        try {
            $u = Find-CloudUser $d.upn
            $target = "$($u.UserPrincipalName)"
            # Safety: never let the operator do this to the account they are signed in with (they could lock themselves out).
            if ($target -ieq "$($script:Who)" -or $target -ieq "$($script:WhoUpn)") { throw 'You cannot do this to the account you are signed in with, because you could lock yourself out.' }
            $removed = @(); $failed = @(); $signedOut = $false; $signErr = $null
            if ($doRemove -or $doTap -or $ids.Count) {
                # Decide which methods to delete: the ones picked by id, all 'mfa' kind (if removeMfa), the TAP (if removeTap).
                # $seen remembers picked ids so a missing one can be reported.
                $seen = @(); $todo = @()
                foreach ($m in @(Get-MfaMethods $u.Id)) {
                    $pick = ($ids -contains $m.id) -or ($doRemove -and $m.kind -eq 'mfa') -or ($doTap -and $m.kind -eq 'tap')
                    if (-not $pick) { continue }
                    $seen += $m.id
                    # Regex: ids may only contain letters, digits, _ and - (\z = end of text); anything else is refused so it cannot alter the URL.
                    if ($m.id -notmatch '^[A-Za-z0-9_-]+\z') { $failed += "$($m.label): unexpected id"; continue }
                    $todo += $m
                }
                # Microsoft will not delete the user's DEFAULT method while other methods remain, and the default is usually the
                # Authenticator app or the mobile phone. So delete those last, and retry anything that failed once the others are gone.
                # Delete order (low number first). Phone (mobile) gets +1 so it is deleted last.
                $order = @{ softwareOathMethods = 1; fido2Methods = 2; temporaryAccessPassMethods = 3; emailMethods = 4; windowsHelloForBusinessMethods = 4; platformCredentialMethods = 4; microsoftAuthenticatorMethods = 5; phoneMethods = 6 }
                $todo = @($todo | Sort-Object { $o = $order[$_.seg]; if ($null -eq $o) { $o = 4 }; if ($_.label -eq 'Phone (mobile)') { $o + 1 } else { $o } })
                $left = @()
                # Up to 3 passes: failed deletions are retried after the others are gone. Stop if nothing was removed in a pass (a retry would not help).
                for ($pass = 1; $pass -le 3 -and $todo.Count; $pass++) {
                    $left = @(); $before = $removed.Count
                    foreach ($m in $todo) {
                        try {
                            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/users/$($u.Id)/authentication/$($m.seg)/$($m.id)" | Out-Null
                            $removed += $m.label
                        } catch { $left += [pscustomobject]@{ m = $m; err = (Get-ErrMsg $_) } }
                    }
                    if (-not $left.Count -or $removed.Count -eq $before) { break }   # nothing left, or the retry would not help
                    $todo = @($left | ForEach-Object { $_.m })
                }
                foreach ($x in $left) { $failed += "$($x.m.label): $($x.err)" }
                foreach ($i in $ids) { if ($seen -notcontains $i) { $failed += 'A selected method was not found (already removed?)' } }
            }
            if ($doSignOut) {
                try { Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$($u.Id)/revokeSignInSessions" | Out-Null; $signedOut = $true }
                catch { $signErr = Get-ErrMsg $_; $failed += "Sign-out: $signErr" }
            }
            # v2.5.3: check what is really left - re-registration is only required when NO MFA method remains and the sessions are ended
            $leftMfa = @(); $rereg = $false
            if ($doRemove) {
                # v2.6.2: Microsoft often answers "deleted" for the default method (usually Authenticator) but keeps it for a few
                # seconds, or only lets it go after the other methods are really gone. So check again several times and delete
                # whatever is still there (fresh IDs each time) - no need to run Revoke again by hand.
                # Seconds to wait before each re-check (about 28 seconds in total).
                $waits = @(2, 3, 4, 5, 6, 8)
                for ($k = 0; $k -lt $waits.Count; $k++) {
                    Start-Sleep -Seconds $waits[$k]
                    $still = @(); try { $still = @(Get-MfaMethods $u.Id | Where-Object { $_.kind -eq 'mfa' -and "$($_.id)" -match '^[A-Za-z0-9_-]+\z' }) } catch { $failed += "Could not check the remaining methods: $(Get-ErrMsg $_)"; break }
                    if (-not $still.Count) { break }
                    $still = @($still | Sort-Object { $o = $order[$_.seg]; if ($null -eq $o) { $o = 4 }; $o })
                    foreach ($m in $still) { try { Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/users/$($u.Id)/authentication/$($m.seg)/$($m.id)" | Out-Null; if ($removed -notcontains $m.label) { $removed += $m.label } } catch {} }
                }
                try { $leftMfa = @(Get-MfaMethods $u.Id | Where-Object { $_.kind -eq 'mfa' } | ForEach-Object { $_.label }) } catch {}
                # Re-registration is guaranteed only if no MFA method remains AND all sessions were ended.
                $rereg = (-not $leftMfa.Count) -and $signedOut
                if ($leftMfa.Count) { $failed += "Still registered: $($leftMfa -join ', ') - Microsoft did not let it go after several tries. Wait a minute and click Revoke again, or remove it in Entra ID > the user > Authentication methods." }
            }
            # Build the short result text used in both logs and the screen.
            $parts = @()
            if ($doRemove -or $doTap -or $ids.Count) { $parts += "Removed $($removed.Count) method(s), $($failed.Count) failed" }
            if ($doRemove) { $parts += $(if ($rereg) { 'MFA re-registration required at next sign-in' } else { 'MFA re-registration NOT complete' }) }
            if ($doSignOut) { $parts += $(if ($signedOut) { 'sessions revoked' } else { 'sessions NOT revoked' }) }
            $signTxt = if (-not $doSignOut) { '-' } elseif ($signedOut) { 'Yes' } else { 'No' }
            Write-MfaLog $target $action $removed $failed $signTxt ($parts -join '; ')
            Write-Log @{ upn = $target; exists = 'Yes'; enabled = '-'; type = '-'; pwdExpiry = '-'; synced = '-' } $action ($parts -join '; ')
            Send $ctx @{ ok = $true; removed = @($removed); failed = @($failed); signedOut = $signedOut; signOutError = $signErr; reregister = $rereg; leftMfa = @($leftMfa) }
        } catch {
            Write-MfaLog $target $action @() @() '-' ("Failed: " + (Get-ErrMsg $_))
            throw
        }
}

# /api/mfa-log - no request fields. Joins all mfa-audit-*.csv files (oldest first) into one CSV text; returns { ok, csv, files }.
$ScreenHandlers['/api/mfa-log'] = {
        # All saved MFA log files joined into one CSV (header once)
        $files = @(Get-ChildItem -Path $LogDir -Filter 'mfa-audit-*.csv' -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if (-not $files.Count) { throw 'There is no MFA log yet. It is created the first time you use Revoke MFA.' }
        $lines = @()
        foreach ($f in $files) {
            $c = @(Get-Content $f.FullName -Encoding UTF8)
            # Keep the header line only from the first file; skip it in the others.
            if (-not $lines.Count) { $lines += $c } elseif ($c.Count -gt 1) { $lines += $c[1..($c.Count - 1)] }
        }
        Send $ctx @{ ok = $true; csv = ($lines -join "`r`n"); files = $files.Count }
}

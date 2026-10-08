# Screen-CloudPassword.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Cloud password + Email sender
# Screen version: 2.5.1   (changes ONLY when this screen changes - not with every release)


# Cloud password + Email sender screen - endpoints: /api/reset (reset Entra passwords or make a Temporary Access Pass), /api/reset-mail-info,
# /api/reset-mail, /api/reset-mail-preview (email the new password), /api/mail-settings, /api/mail-test (sender settings), and
# /api/mailacct-start, -poll, -signout, -browser (sign in a separate mail account). Uses Microsoft Graph (Update-MgUser, Temporary Access Pass,
# sendMail) and, for 'both', on-premises AD (SetPassword). Data files: mail-settings.json in $Root, mail-audit-YYYY-MM.csv in $LogDir.
# New passwords are kept in memory only ($script:ResetSecrets) for a short time; secrets in mail-settings.json are encrypted with DPAPI.
# Needs the Microsoft sign-in ($script:Who) with an Entra admin role that may reset passwords and the Mail.Send permission to send.
# ---- Email the new password to the user (v1.78.0) ----
# The sender is a separate mailbox (shared / service mailbox) saved in mail-settings.json - never the signed-in admin's own address.
# In-memory store of freshly made passwords / passes, by lower-case UPN (never written to disk).
if (-not $script:ResetSecrets) { $script:ResetSecrets = @{} }
# File with the email settings (sender, subjects, signature, sending mode).
$script:MailCfgFile = Join-Path $Root 'mail-settings.json'
# Returns the email settings: defaults first, then the values saved in mail-settings.json laid over them.
function Get-MailCfg {
    $c = [ordered]@{ sender = ''; subject = 'Your new password'; subjectTap = 'Your university account password'; changeUrl = 'https://mysignins.microsoft.com/security-info/password/change'; ssprUrl = 'https://aka.ms/sspr'; mfaUrl = 'https://aka.ms/mysecurityinfo'; saveCopy = $false; signature = 'IT Support'; senders = @(); cc = ''; sigMode = 'standard'; sigHtml = ''; sigData = ''; sendMode = 'signin'; appTenant = ''; appClientId = ''; appSecretEnc = ''; acctUser = ''; acctTenant = ''; acctRefreshEnc = '' }
    if (Test-Path $script:MailCfgFile) {
        try { $j = Get-Content $script:MailCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } } } catch {}
    }
    $c.senders = @($c.senders | Where-Object { "$_" })   # always a list (one saved sender comes back as a plain string)
    $c
}
# True when the text looks like an email address (regex: something@something.something, no spaces, ; , < > or quotes).
function Test-MailAddr($a) { "$a" -match '^[^@\s;,<>"]+@[^@\s;,<>"]+\.[^@\s;,<>"]+$' }
# True when the address is the signed-in person's own (only checked in 'signin' mode - a sender must be a shared/service mailbox).
function Test-OwnAddr($a) { if ((Get-MailMode) -ne 'signin') { return $false }; $a = "$a".Trim(); ($script:WhoUpn -and $a -ieq "$($script:WhoUpn)") -or ($script:Who -and $a -ieq "$($script:Who)") }
# Forgets saved passwords older than 60 minutes (see the age test in the line below).
function Clear-OldSecrets { foreach ($k in @($script:ResetSecrets.Keys)) { if (((Get-Date) - $script:ResetSecrets[$k].at).TotalMinutes -gt 60) { $script:ResetSecrets.Remove($k) } } }
# Adds one line to this month's mail audit CSV. Inputs: $upn (user), $sender, $to (addresses), $result. The password is never logged.
function Write-MailLog($upn, $sender, $to, $result) {
    $f = Join-Path $LogDir ('mail-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,Admin,Sender,User,SentTo,Result' | Out-File $f -Encoding utf8 }
    ((@(('{0:s}' -f (Get-Now)), $script:Who, $sender, $upn, $to, $result) | ForEach-Object { ConvertTo-CsvCell $_ }) -join ',') | Add-Content $f   # no password in this log
}
# Arabic wording for a number of minutes (days when it divides by 1440, otherwise hours/minutes), with the correct singular / dual / plural form.
function Get-ArDuration([int]$m) {
    # Arabic wording of the pass lifetime (written as HTML character codes so this file stays plain ASCII)
    $u = if ($m % 1440 -eq 0) { @(($m / 1440), '&#1610;&#1608;&#1605; &#1608;&#1575;&#1581;&#1583;', '&#1610;&#1608;&#1605;&#1610;&#1606;', '&#1571;&#1610;&#1575;&#1605;', '&#1610;&#1608;&#1605;&#1611;&#1575;') } elseif ($m % 60 -eq 0) { @(($m / 60), '&#1587;&#1575;&#1593;&#1577; &#1608;&#1575;&#1581;&#1583;&#1577;', '&#1587;&#1575;&#1593;&#1578;&#1610;&#1606;', '&#1587;&#1575;&#1593;&#1575;&#1578;', '&#1587;&#1575;&#1593;&#1577;') } else { @($m, '&#1583;&#1602;&#1610;&#1602;&#1577; &#1608;&#1575;&#1581;&#1583;&#1577;', '&#1583;&#1602;&#1610;&#1602;&#1578;&#1610;&#1606;', '&#1583;&#1602;&#1575;&#1574;&#1602;', '&#1583;&#1602;&#1610;&#1602;&#1577;') }
    $n = [int]$u[0]
    if ($n -eq 1) { return $u[1] }
    if ($n -eq 2) { return $u[2] }
    if ($n -ge 3 -and $n -le 10) { return "$n $($u[3])" }
    "$n $($u[4])"
}
# Builds the HTML of the 'your new password' email. $s = reset result kept in memory { upn, name, secret, ad, tap, once, pwOnce, at, mins }, $cfg = email settings.
# Three kinds: ad (on-premises AD password), tap (Temporary Access Pass) and temp (normal cloud password). English first, Arabic (right-to-left) below.
function New-PwMailHtmlRaw($s, $cfg) {
    # The texts of these e-mails come from the Email messages screen (Screen-EmailTemplates.ps1); the layout, the boxes and the password itself stay here.
    # Script block $h: makes any text safe to put inside HTML.
    $h = { [Net.WebUtility]::HtmlEncode("$args") }
    # Kind 1 - on-premises AD password email.
    # Kind 2 - Temporary Access Pass email.
    $nm = Get-EmailNames $(if ($s.ad) { 'ad' } elseif ($s.tap) { 'tap' } else { 'temp' }) $s.given $s.sn $s.name   # the owner of the account (from your tenant), not the address the e-mail goes to
    $v = @{ first = $nm.first; last = $nm.last; full = $nm.full; greet = $nm.greet; name = "$($s.name)"; upn = "$($s.upn)"; signature = "$(Get-EmailSigFirst $cfg.signature)" }
    # Script block $T: gets one editable text part (kind, key, language) from the templates and fills in the placeholders.
    $T = { param($id, $k, $l, $raw) Get-EmailPart $id $k $l $v $raw }
    # Inline styles (email programs ignore style sheets): $box = password box, $pYel / $pBlu = yellow / blue notice boxes, $pFoot = small footer.
    $box = 'font-size:20px;font-family:Consolas,monospace;background:#f1f5f9;border:1px solid #cbd5e1;border-radius:8px;padding:12px 16px;display:inline-block;letter-spacing:1px'
    $pYel = 'background:#fef3c7;border:1px solid #fcd34d;border-radius:8px;padding:10px 14px'
    $pBlu = 'background:#eff6ff;border:1px solid #bfdbfe;border-radius:8px;padding:10px 14px'
    $pFoot = 'color:#64748b;font-size:12px'
    # Start of the Arabic block (closed at the end of each version).
    $rtl = '<div dir="rtl" lang="ar" style="font-family:Segoe UI,Tahoma,Arial,sans-serif;font-size:15px;color:#1f2937;line-height:1.7;text-align:right;border-top:2px solid #e5e7eb;margin-top:22px;padding-top:14px">'
    $sig = Get-EmailSigHtml $cfg.signature; $sigR = Get-EmailSigHtml $cfg.signature -Rtl
    if ($s.ad) {
        # On-premises AD password: one-time (must change at the next sign-in) or a normal password, then the Microsoft Authenticator advice
        $lnk = { param($u) "<a href=""$(& $h $u)"" style=""color:#2563eb;font-weight:600"" dir=""ltr"">$(& $h ($u -replace '^https://', ''))</a>" }
        $raw = @{ change_link = (& $lnk "$($cfg.changeUrl)"); mfa_link = (& $lnk "$($cfg.mfaUrl)"); sspr_link = (& $lnk "$($cfg.ssprUrl)") }
        # Which notice to show: 'must change at next sign-in' or 'normal password'.
        $nk = if ($s.pwOnce) { 'once' } else { 'normal' }
        # Whole email as one joined text: greeting, intro, password box, notices, footer, signature, then the Arabic copy.
        return '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937;line-height:1.5">' +
        "<p>$(& $T 'ad' 'hello' 'en' $raw)</p>" +
        "<p>$(& $T 'ad' 'intro' 'en' $raw)</p>" +
        "<p style=""margin:4px 0"">$(& $T 'ad' 'label' 'en' $raw)</p><p style=""$box"">$(& $h $s.secret)</p>" +
        "<p style=""$pYel"">$(& $T 'ad' $nk 'en' $raw)</p>" +
        "<p style=""$pBlu"">$(& $T 'ad' 'advice' 'en' $raw)</p>" +
        "<p style=""$pFoot"">$(& $T 'ad' 'footer' 'en' $raw)</p>" + $sig +
        $rtl +
        "<p>$(& $T 'ad' 'hello' 'ar' $raw)</p>" +
        "<p>$(& $T 'ad' 'intro' 'ar' $raw)</p>" +
        "<p style=""margin:4px 0"">$(& $T 'ad' 'label' 'ar' $raw)</p><p dir=""ltr"" style=""$box"">$(& $h $s.secret)</p>" +
        "<p style=""$pYel"">$(& $T 'ad' $nk 'ar' $raw)</p>" +
        "<p style=""$pBlu"">$(& $T 'ad' 'advice' 'ar' $raw)</p>" +
        "<p style=""$pFoot"">$(& $T 'ad' 'footer' 'ar' $raw)</p>" +
        "$sigR</div></div>"
    }
    if ($s.tap) {
        # Temporary Access Pass: what to do, where, and the deadline (the lifetime chosen when the pass was made)
        $enC = [Globalization.CultureInfo]::GetCultureInfo('en-US')
        # Deadline = time the pass was made + its lifetime in minutes; shown in English and (Gregorian calendar, Arabic names) in Arabic.
        $until = ([datetime]$s.at).AddMinutes([int]$s.mins)
        $deadline = $until.ToString("h:mm tt 'on' dddd d MMMM yyyy", $enC)
        $arC = [Globalization.CultureInfo]::GetCultureInfo('ar-AE'); $arF = $arC.DateTimeFormat.Clone(); $arF.Calendar = New-Object Globalization.GregorianCalendar
        $deadlineAr = $until.ToString("dddd d MMMM yyyy h:mm tt", $arF)   # Gregorian date with Arabic day / month names
        $url = 'https://aka.ms/mysecurityinfo'
        $rawE = @{ tap_link = "<a href=""$url"" style=""color:#2563eb;font-weight:600"">aka.ms/mysecurityinfo</a>"; within = (& $h (Format-Mins $s.mins)); deadline = (& $h $deadline) }
        $rawA = @{ tap_link = "<a href=""$url"" style=""color:#2563eb;font-weight:600"" dir=""ltr"">aka.ms/mysecurityinfo</a>"; within = (Get-ArDuration $s.mins); deadline = (& $h $deadlineAr) }
        # Extra sentence only for one-time passes.
        $rawE.once = if ($s.once) { Get-EmailPart 'tap' 'once' 'en' $v $rawE } else { '' }
        $rawA.once = if ($s.once) { Get-EmailPart 'tap' 'once' 'ar' $v $rawA } else { '' }
        # Whole TAP email as one joined text (English, then Arabic).
        return '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937;line-height:1.5">' +
        "<p>$(& $T 'tap' 'hello' 'en' $rawE)</p>" +
        "<p>$(& $T 'tap' 'intro' 'en' $rawE)</p>" +
        "<p style=""margin:4px 0"">$(& $T 'tap' 'label' 'en' $rawE)</p><p style=""$box"">$(& $h $s.secret)</p>" +
        "<p style=""$pYel"">$(& $T 'tap' 'deadline' 'en' $rawE)</p>" +
        "<p style=""margin-bottom:4px""><b>$(& $T 'tap' 'stepsTitle' 'en' $rawE)</b></p><ol style=""margin-top:0;padding-left:22px"">" +
        (Get-EmailItems 'tap' 'steps' 'en' $v $rawE '') + '</ol>' +
        "<p>$(& $T 'tap' 'closing' 'en' $rawE)</p>" +
        "<p style=""$pFoot"">$(& $T 'tap' 'footer' 'en' $rawE)</p>" + $sig +
        # ---- Arabic (same content, right to left) ----
        $rtl +
        "<p>$(& $T 'tap' 'hello' 'ar' $rawA)</p>" +
        "<p>$(& $T 'tap' 'intro' 'ar' $rawA)</p>" +
        "<p style=""margin:4px 0"">$(& $T 'tap' 'label' 'ar' $rawA)</p><p dir=""ltr"" style=""$box"">$(& $h $s.secret)</p>" +
        "<p style=""$pYel"">$(& $T 'tap' 'deadline' 'ar' $rawA)</p>" +
        "<p style=""margin-bottom:4px""><b>$(& $T 'tap' 'stepsTitle' 'ar' $rawA)</b></p><ol style=""margin-top:0;padding-right:22px;padding-left:0"">" +
        (Get-EmailItems 'tap' 'steps' 'ar' $v $rawA '') + '</ol>' +
        "<p>$(& $T 'tap' 'closing' 'ar' $rawA)</p>" +
        "<p style=""$pFoot"">$(& $T 'tap' 'footer' 'ar' $rawA)</p>" +
        "$sigR</div></div>"
    }
    # Kind 3 - normal temporary cloud password. This last expression is the returned HTML (English, then Arabic).
    $nk = if ($s.pwOnce) { 'ruleOnce' } else { 'ruleKeep' }
    '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937">' +
    "<p>$(& $T 'temp' 'hello' 'en' @{})</p>" +
    "<p>$(& $T 'temp' 'intro' 'en' @{})</p>" +
    "<p style=""$box"">$(& $h $s.secret)</p>" +
    "<p>$(& $T 'temp' $nk 'en' @{})</p>" +
    "<p style=""$pFoot"">$(& $T 'temp' 'footer' 'en' @{})</p>" + $sig +
    # ---- Arabic (same content, right to left) ----
    $rtl +
    "<p>$(& $T 'temp' 'hello' 'ar' @{})</p>" +
    "<p>$(& $T 'temp' 'intro' 'ar' @{})</p>" +
    "<p dir=""ltr"" style=""$box"">$(& $h $s.secret)</p>" +
    "<p>$(& $T 'temp' $nk 'ar' @{})</p>" +
    "<p style=""$pFoot"">$(& $T 'temp' 'footer' 'ar' @{})</p>" +
    "$sigR</div></div>"
}
# Adds a plain hint to common mail errors (no Send As right, bad sender mailbox, missing Mail.Send permission). Returns the text.
function Get-MailErr($m) {
    if ($m -match 'ErrorSendAsDenied|SendAs|Access is denied|ErrorAccessDenied|403|Forbidden') { return "$m | Your account needs 'Send As' (or 'Send on behalf') permission on the sender mailbox: Exchange admin center > Mailboxes > the sender > Delegation. With a certificate sign-in the app needs the Mail.Send application permission." }
    if ($m -match 'MailboxNotEnabledForRESTAPI|ResourceNotFound|ErrorInvalidUser|not found') { return "$m | The sender address is not an Exchange Online mailbox in this tenant - check the sender in Email settings." }
    if ($m -match 'scope|Mail\.Send') { return "$m | Sign out of Microsoft and sign in again so the tool can ask for the Mail.Send permission." }
    $m
}

# /api/mail-settings - read: {} ; save: { save:true, sendMode, sender, subject, subjectTap, changeUrl, ssprUrl, mfaUrl, signature, sigMode, sigHtml, saveCopy, app... }.
# Checks every value, saves mail-settings.json and returns the settings without the encrypted secrets.
$ScreenHandlers['/api/mail-settings'] = {
    # read: {}  /  save: { save:true, sender, subject, saveCopy, signature }
    $c = Get-MailCfg
    if ($d.save) {
        if ($null -ne $d.sendMode) {   # v1.98.30: how the e-mails are sent
            $sm = "$($d.sendMode)"; if ($sm -notin 'signin', 'me', 'app', 'account') { throw 'Choose how the e-mails are sent.' }
            # App mode: tenant (regex: id or domain name), client id (GUID) and secret. A blank secret keeps the saved one unless the client id changed.
            if ($sm -eq 'app') { $at = "$($d.appTenant)".Trim(); $ai = "$($d.appClientId)".Trim(); $as = "$($d.appSecret)"
                if ($at -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'Type the Tenant ID (directory ID or domain).' }
                if ($ai -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Type the Application (client) ID - a GUID.' }
                if ($as) { $c.appSecretEnc = Protect-MailSecret $as } elseif (-not $c.appSecretEnc -or $ai -ne $c.appClientId) { throw 'Type the client secret (its Value, not its ID).' }
                $c.appTenant = $at; $c.appClientId = $ai; $script:MailAppTok = $null }
            if ($sm -eq 'account' -and -not $c.acctRefreshEnc) { throw 'Sign in the mail account first (button below).' }
            $c.sendMode = $sm
        }
        # Sender mailbox: in 'me' mode it is the signed-in person's own address; otherwise what was typed. It must not be the operator's own account.
        $snd = "$($d.sender)".Trim(); if ($c.sendMode -eq 'me' -and $script:WhoUpn) { $snd = "$($script:WhoUpn)" } elseif ($c.sendMode -eq 'account' -and -not $snd) { $snd = "$($c.acctUser)" }
        if (-not (Test-MailAddr $snd)) { throw 'Enter the sender mailbox as an email address, e.g. it-noreply@contoso.com.' }
        if (Test-OwnAddr $snd) { throw 'The sender cannot be your own account. Use a shared or service mailbox, e.g. it-noreply@contoso.com.' }
        $c.sender = $snd
        if ("$($d.subject)".Trim()) { $c.subject = "$($d.subject)".Trim() }
        if ("$($d.subjectTap)".Trim()) { $c.subjectTap = "$($d.subjectTap)".Trim() }
        # Only https:// links are accepted (these links go into emails).
        foreach ($k in 'changeUrl', 'ssprUrl', 'mfaUrl') {   # websites named in the On-premises AD password email
            $v = "$($d.$k)".Trim()
            if ($v) { if ($v -notmatch '^https://[^\s"<>]+$') { throw "The website must start with https:// ($v)." }; $c[$k] = $v }
        }
        if ("$($d.signature)".Trim()) { $c.signature = "$($d.signature)".Trim() }
        if ($null -ne $d.sigMode) {   # v1.98.8: custom (designed) signature
            $sm = "$($d.sigMode)"; if ($sm -notin 'standard', 'custom') { throw 'Choose Standard or Custom signature.' }
            $c.sigMode = $sm; $c.sigHtml = Get-SafeSigHtml "$($d.sigHtml)"; $c.sigData = "$($d.sigData)"
            if ($sm -eq 'custom' -and -not $c.sigHtml.Trim()) { throw 'The custom signature is empty. Fill in at least a name, or choose Standard.' }
        }
        $c.saveCopy = [bool]$d.saveCopy
        # Remember up to 10 senders, newest first, for the From list.
        $c.senders = @(@($snd) + @($c.senders | Where-Object { "$_" -and "$_" -ine $snd }) | Select-Object -First 10)
        ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8
    }
    Send $ctx @{ ok = $true; settings = (Get-MailCfgView $c); own = "$(if ($script:WhoUpn) { $script:WhoUpn } else { '' })" }
}

# /api/reset-mail-info - request: $d.upns (list). For each user returns possible email targets: personal (alternate) email, manager, own mailbox,
# and the on-premises AD mail. 'ready' tells whether a password is still held in memory. Returns { users, settings }.
$ScreenHandlers['/api/reset-mail-info'] = {
    # For each reset user: where the email could go. Their own mailbox is no use if they cannot sign in yet,
    # so the alternate (personal) email comes first, then the manager.
    if (-not $script:Who) { throw 'Not connected. Sign in first.' }
    Clear-OldSecrets
    $out = @()
    foreach ($upn in @($d.upns | ForEach-Object { "$_".Trim() } | Where-Object { $_ })) {
        $o = [ordered]@{ upn = $upn; ready = [bool]$script:ResetSecrets[$upn.ToLower()]; suggest = ''; source = ''; options = @() }
        try {
            $u = Get-MgUser -UserId $upn -Property Id, Mail, OtherMails, UserPrincipalName -ErrorAction Stop
            $opts = @()
            foreach ($m in @($u.OtherMails)) { if (Test-MailAddr $m) { $opts += [ordered]@{ address = "$m"; label = 'Alternate email' } } }
            try { $mg = Get-MgUserManager -UserId $u.Id -ErrorAction Stop; $mm = "$($mg.AdditionalProperties['mail'])"; if (Test-MailAddr $mm) { $opts += [ordered]@{ address = $mm; label = "Manager ($($mg.AdditionalProperties['displayName']))" } } } catch {}
            $own = if ($u.Mail) { "$($u.Mail)" } else { "$($u.UserPrincipalName)" }
            if (Test-MailAddr $own) { $opts += [ordered]@{ address = $own; label = 'Their own mailbox' } }
            $sec = $script:ResetSecrets[$upn.ToLower()]
            if ($sec -and $sec.adMail -and (Test-MailAddr $sec.adMail) -and -not ($opts | Where-Object { $_.address -ieq $sec.adMail })) { $opts += [ordered]@{ address = "$($sec.adMail)"; label = 'Email in AD' } }
            $o.options = @($opts)
            if ($opts.Count) { $o.suggest = $opts[0].address; $o.source = $opts[0].label }
        } catch {
            $sec = $script:ResetSecrets[$upn.ToLower()]
            if ($sec -and $sec.adMail -and (Test-MailAddr $sec.adMail)) { $o.options = @([ordered]@{ address = "$($sec.adMail)"; label = 'Email in AD' }); $o.suggest = "$($sec.adMail)"; $o.source = 'Email in AD' }
        }
        $out += [pscustomobject]$o
    }
    $c = Get-MailCfg
    Send $ctx @{ ok = $true; users = $out; settings = $c }
}

# /api/reset-mail - request: $d.items [{ upn, to }], optional $d.sender, $d.subject, $d.subjectTap, $d.cc, $d.bcc. Sends the new password email for each user.
# Returns { results (ok / message per user), sender }. Limits: 5 'to', 5 Cc and 5 Bcc addresses.
$ScreenHandlers['/api/reset-mail'] = {
    # { items: [ { upn, to } ] } - the password itself is taken from server memory, never from the browser
    if (-not $script:Who) { throw 'Not connected. Sign in first.' }
    Clear-OldSecrets
    $c = Get-MailCfg
    # the sender can be typed in the send window (e.g. another shared mailbox); empty = the saved one
    $snd = if ("$($d.sender)".Trim()) { "$($d.sender)".Trim() } else { "$($c.sender)".Trim() }
    if (-not (Test-MailAddr $snd)) { throw 'Set the sender mailbox first (Email settings), or type it in the From box.' }
    if (Test-OwnAddr $snd) { throw 'The sender cannot be your own account. Use a shared or service mailbox.' }
    $subjChanged = $false
    if ("$($d.subject)".Trim() -and "$($d.subject)".Trim() -ne "$($c.subject)") { $c.subject = "$($d.subject)".Trim(); $subjChanged = $true }
    if ("$($d.subjectTap)".Trim() -and "$($d.subjectTap)".Trim() -ne "$($c.subjectTap)") { $c.subjectTap = "$($d.subjectTap)".Trim(); $subjChanged = $true }
    # Cc: extra people who get a copy of every email (e.g. the team lead)
    # Regex '[;,\s]+' splits the typed list on semicolons, commas or spaces.
    $cc = @("$($d.cc)" -split '[;,\s]+' | Where-Object { $_ })
    $badCc = @($cc | Where-Object { -not (Test-MailAddr $_) }); if ($badCc.Count) { throw "Cc: not a valid email address: $($badCc -join ', ')" }
    if ($cc.Count -gt 5) { throw 'Cc: at most 5 addresses.' }
    $bcc = @("$($d.bcc)" -split '[;,\s]+' | Where-Object { $_ })   # v1.98.21: Bcc - hidden copies (not saved as a default)
    $badBcc = @($bcc | Where-Object { -not (Test-MailAddr $_) }); if ($badBcc.Count) { throw "Bcc: not a valid email address: $($badBcc -join ', ')" }
    if ($bcc.Count -gt 5) { throw 'Bcc: at most 5 addresses.' }
    # remember the sender: it becomes the default and is offered in the From list next time
    # Save sender / subject / Cc as the new defaults when they changed (Bcc is never saved).
    if ($subjChanged -or $snd -ine "$($c.sender)" -or "$($d.cc)" -ne "$($c.cc)") {
        $c.sender = $snd; $c.cc = ($cc -join '; ')
        $c.senders = @(@($snd) + @($c.senders | Where-Object { "$_" -and "$_" -ine $snd }) | Select-Object -First 10)
        try { ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8 } catch {}
    }
    $res = @()
    # One email per user. A problem with one user is stored in its result and does not stop the others.
    foreach ($it in @($d.items)) {
        $upn = "$($it.upn)".Trim(); $to = @("$($it.to)" -split '[;,\s]+' | Where-Object { $_ })
        $r = [ordered]@{ upn = $upn; to = ($to -join '; '); cc = ($cc -join '; '); bcc = ($bcc -join '; '); ok = $false; message = '' }
        try {
            if (-not $to.Count) { throw 'No email address to send to.' }
            if ($to.Count -gt 5) { throw 'At most 5 addresses per user.' }
            $bad = @($to | Where-Object { -not (Test-MailAddr $_) }); if ($bad.Count) { throw "Not a valid email address: $($bad -join ', ')" }
            # The password comes from tool memory, not from the browser.
            $s = $script:ResetSecrets[$upn.ToLower()]
            if (-not $s) { throw 'The password is no longer held by the tool (more than 60 minutes ago, or the tool was restarted). Reset again to send a new one.' }
            # Graph sendMail message. saveToSentItems follows the 'save a copy' setting.
            $msg = @{
                message = @{
                    subject = $(if ($s.tap) { "$($c.subjectTap)" } else { "$($c.subject)" })   # Temporary Access Pass emails have their own subject
                    body = @{ contentType = 'HTML'; content = (New-PwMailHtml $s $c) }
                    toRecipients = @($to | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
                    ccRecipients = @($cc | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
                    bccRecipients = @($bcc | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
                    importance = 'high'
                }
                saveToSentItems = [bool]$c.saveCopy
            }
            # Use the first/last name from Entra for the greeting; then add the template's attachments / images, if any.
            $tn = Get-EmailTenantName $s.upn; if ($tn -and ($tn.given -or $tn.sn)) { $s.given = $tn.given; $s.sn = $tn.sn }   # first / last name from the account in your tenant
            $att = @(Get-EmailAttach $(if ($s.ad) { 'ad' } elseif ($s.tap) { 'tap' } else { 'temp' })); if ($att.Count) { $msg.message.attachments = $att }   # the picture of the e-mail (Email messages screen)
            try {
                $snd = Send-ToolMail $snd $msg
            } catch { throw (Get-MailErr $_.Exception.Message) }
            $r.ok = $true; $r.message = "Sent from $snd"
            Write-MailLog $upn $snd ($r.to + $(if ($r.cc) { ' | cc ' + $r.cc })) 'Sent'
        } catch { $r.message = $_.Exception.Message; Write-MailLog $upn $snd ($r.to + $(if ($r.cc) { ' | cc ' + $r.cc })) "Failed: $($r.message)" }
        $res += [pscustomobject]$r
    }
    Send $ctx @{ ok = $true; results = $res; sender = $snd }
}

# /api/reset - request: $d.usernames (list), $d.domain, $d.method (cloud | both | tap), $d.pwLength (8-32) or $d.customPassword, $d.pwOnce
# (must change at next sign-in), $d.tapMinutes (60-480), $d.tapOnce, $d.enableAccount, $d.cloudOnlyOk.
# For each name: find the Entra user, reset the password (or create the Temporary Access Pass), keep the secret in memory, log the result.
# Returns { ok, results } with one row per name (secret is shown on the screen only).
$ScreenHandlers['/api/reset'] = {
        $seenNames = @{}
        if (-not $script:Who) { throw 'Not connected. Sign in first.' }
        $dom = "$($d.domain)".Trim(); $results = @(); $doneIds = @{}
        $props = 'Id', 'DisplayName', 'UserPrincipalName', 'AccountEnabled', 'UserType', 'PasswordPolicies', 'LastPasswordChangeDateTime', 'OnPremisesSyncEnabled', 'OnPremisesSamAccountName'
        # Defaults: TAP lifetime 60 minutes, one-time use, generated password length 12, user must change it at next sign-in.
        $mins = 60; $once = $true; $pwLen = 12; $pwOnce = $true
        if ($null -ne $d.pwOnce) { $pwOnce = [bool]$d.pwOnce }
        # 'both' = set the same password in on-premises AD and in Microsoft 365 (so it works at once and is not a one-time password).
        $both = ($d.method -eq 'both')   # v2.5.1: the same NEW password in Microsoft 365 AND on-premises AD - a normal password, not temporary
        if ($both) { $pwOnce = $false; if (-not $script:AdCred -and -not $d.cloudOnlyOk) { throw 'Sign in to on-premises AD first (the AD button at the top right) - the password is set in AD and in Microsoft 365 at the same time.' } }
        # Password rules: a typed password must pass Test-AdPwRule; a generated one must be 8-32 characters.
        if ($d.method -ne 'tap') {
            if ($d.customPassword) {
                if (-not (Test-AdPwRule $d.customPassword)) { throw 'The password must be at least 8 characters and cannot start or end with a special character.' }
            } else {
                $pwLen = [int]$d.pwLength
                if ($pwLen -lt 8 -or $pwLen -gt 32) { throw 'Password length must be between 8 and 32.' }
            }
        }
        if ($d.method -eq 'tap') {
            if ($d.tapMinutes) { $mins = [int]$d.tapMinutes }
            if ($null -ne $d.tapOnce) { $once = [bool]$d.tapOnce }
            # Microsoft allows the Temporary Access Pass lifetime of 1 to 8 hours here (60-480 minutes).
            if ($mins -lt 60 -or $mins -gt 480) { throw 'Temporary Access Pass lifetime must be between 1 and 8 hours.' }
        }
        # each user once - the same name twice used to reset the account twice, so the first password shown no longer worked
        foreach ($name in @($d.usernames | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $seenNames[$_.ToLower()] } | ForEach-Object { $seenNames[$_.ToLower()] = 1; $_ })) {   # each name once, in the order typed
            # UPN to show: as typed, or name + @domain.
            $upn = if ($name -match '@') { $name } elseif ($dom) { "$name@$dom" } else { $null }
            $r = [ordered]@{ user = $name; upn = $upn; name = ''; ok = $false; secret = ''; message = ''; exists = 'Unknown'; enabled = '-'; type = '-'; pwdExpiry = '-'; synced = '-'; note = '' }
            try {
                # Find the user. Zero or several matches stop this name with a clear message (never reset an unclear account).
                try { $found = @(Resolve-EntraUsers $name $dom $props) }
                catch { throw "Lookup failed: $($_.Exception.Message)" }
                if ($found.Count -eq 0) {
                    $r.exists = 'No'
                    throw $(if (-not $dom -and $name -notmatch '@') { 'Account not found in Entra (all domains were searched).' } else { 'Account not found in Entra.' })
                }
                if ($found.Count -gt 1) {
                    $r.exists = 'Yes'
                    throw ('Several accounts match: ' + ((@($found | ForEach-Object { $_.UserPrincipalName })) -join ', ') + ' - enter the domain or the full email.')
                }
                $u = $found[0]
                $r.exists = 'Yes'; $r.upn = $u.UserPrincipalName; $r.name = "$($u.DisplayName)"
                # Same rule as Revoke MFA: never reset the account you are signed in with (it can lock you out mid-session)
                if ("$($u.UserPrincipalName)" -ieq "$($script:Who)" -or "$($u.UserPrincipalName)" -ieq "$($script:WhoUpn)") { throw 'This is the account you are signed in with. Reset your own password in the Microsoft portal instead, so you are not locked out.' }
                # Also stops the same account typed in two different ways.
                if ($doneIds["$($u.Id)"]) { throw "Same account as '$($doneIds["$($u.Id)"])' above - it is reset only once, so the password shown there is the one that works." }
                $doneIds["$($u.Id)"] = $name
                $r.enabled = if ($u.AccountEnabled) { 'Enabled' } else { 'Disabled' }
                $r.type = "$($u.UserType)"
                $r.synced = if ($u.OnPremisesSyncEnabled) { 'Yes (on-prem)' } else { 'No (cloud)' }
                $r.pwdExpiry = Get-PwdExpiry $u
                # Optional: enable a disabled account first. Synced accounts cannot be enabled here (must be done in AD).
                if ($d.enableAccount -and $r.enabled -eq 'Disabled') {
                    try {
                        Update-MgUser -UserId $u.Id -AccountEnabled:$true
                        $r.enabled = 'Enabled'; $r.note = 'Account was disabled - now enabled.'
                    } catch {
                        $r.note = if ($r.synced -like 'Yes*') { 'Could not enable: account is synced from on-premises AD - enable it there.' } else { "Could not enable the account: $($_.Exception.Message)" }
                    }
                }
                try {
                    if ($d.method -eq 'tap') {
                        # Temporary Access Pass: Graph creates it and returns the pass once; isUsableOnce / lifetimeInMinutes come from the request.
                        $t = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId $u.Id -BodyParameter @{ isUsableOnce = $once; lifetimeInMinutes = $mins }
                        $secret = $t.TemporaryAccessPass
                    } else {
                        # Password: the one typed by the operator or a random one (New-AdPassword).
                        $secret = if ($d.customPassword) { "$($d.customPassword)" } else { New-AdPassword $pwLen }
                        if ($both) {
                            # 1) on-premises AD (synced accounts): the password, no change at the next sign-in, unlocked
                            $adDone = $false
                            if ($u.OnPremisesSyncEnabled) {
                                if (-not $script:AdCred) { throw 'This account is synced from on-premises AD - sign in to AD first.' }
                                $sam = "$($u.OnPremisesSamAccountName)"; if (-not $sam) { $sam = ("$($u.UserPrincipalName)" -split '@')[0] }
                                $hit = Find-AdObject 'user' $sam; if (-not $hit) { $hit = Find-AdObject 'user' "$($u.UserPrincipalName)" }
                                if (-not $hit) { throw "The on-premises AD account '$sam' was not found - nothing was changed." }
                                $ue = New-AdEntry "$($hit.Properties['distinguishedname'][0])"
                                # SetPassword is the AD 'reset password' call. Then pwdLastSet = -1 clears 'must change at next sign-in' and lockoutTime = 0 unlocks the account.
                                try { $ue.Invoke('SetPassword', $secret) } catch { $em = Get-ErrMsg $_; throw "On-premises AD did not accept the password: $em$(if ($em -match 'password|0x800708C5') { ' (it does not meet the domain password policy)' })" }
                                try { $ue.Properties['pwdLastSet'].Value = -1; $ue.CommitChanges() } catch {}
                                try { if ([int64]"$($ue.Properties['lockoutTime'].Value)" -gt 0) { $ue.Properties['lockoutTime'].Value = 0; $ue.CommitChanges() } } catch {}
                                $adDone = $true
                            }
                            # 2) Microsoft 365: the same password now (works with password writeback / cloud accounts); otherwise password hash sync brings it within about 2 minutes
                            $cloudNote = ''
                            try { Update-MgUser -UserId $u.Id -PasswordProfile @{ Password = $secret; ForceChangePasswordNextSignIn = $false } -ErrorAction Stop; $cloudNote = 'Microsoft 365: set now.' }
                            catch { if ($adDone) { $cloudNote = 'Microsoft 365: arrives with the next AD sync (about 2 minutes, password hash sync).' } else { throw } }
                            $r.note = ((($r.note + ' ') + $(if ($adDone) { 'On-premises AD: set (no change needed at sign-in, unlocked). ' } else { 'Cloud-only account (no on-premises AD). ' }) + $cloudNote).Trim())
                        } else {
                        # Cloud-only password reset; ForceChangePasswordNextSignIn makes it a one-time password.
                        Update-MgUser -UserId $u.Id -PasswordProfile @{ Password = $secret; ForceChangePasswordNextSignIn = $pwOnce }
                        }
                    }
                } catch { throw "Reset failed: $($_.Exception.Message)" }
                try { $r.pwdExpiry = Get-PwdExpiry (Get-MgUser -UserId $u.Id -Property $props) } catch {}
                $r.ok = $true; $r.secret = $secret; $r.message = 'OK'; $r.kind = $(if ($d.method -eq 'tap') { 'tap' } elseif ($both) { 'both' } elseif ($pwOnce) { 'onetime' } else { 'permanent' }); $r.tapMins = $(if ($d.method -eq 'tap') { $mins } else { 0 }); $r.tapOnce = [bool]$once; $r.sam = "$($u.OnPremisesSamAccountName)"   # v2.5.1: for the View window
                # kept in memory only (never on disk) for up to 60 minutes, so 'Email the password' never sends a password back from the browser
                # Keep the secret in memory so the 'Email the password' button can use it later.
                $script:ResetSecrets["$($u.UserPrincipalName)".ToLower()] = @{ ad = $both; secret = $secret; tap = ($d.method -eq 'tap'); mins = $mins; once = $once; pwOnce = $pwOnce; name = "$($u.DisplayName)"; upn = "$($u.UserPrincipalName)"; at = (Get-Date) }
                if ($d.method -eq 'tap') {
                    $tn = "Temporary Access Pass valid for $(Format-Mins $mins), " + $(if ($once) { 'one-time use.' } else { 'can be used more than once.' })
                    $r.note = (($r.note + ' ' + $tn).Trim())
                }
                Write-Log $r $d.method 'Success'
            } catch {
                $m = $_.Exception.Message
                # Permission problem: add a hint about the needed Entra role.
                if ($m -match 'Insufficient privileges|Authorization_RequestDenied') { $m += ' | Your account needs an Entra admin role (Helpdesk / Password / User Administrator; Privileged Authentication Administrator to reset admin accounts). If the role is PIM-eligible, activate it, then reconnect.' }
                $r.message = $m; Write-Log $r $d.method "Failed: $m"
            }
            $results += [pscustomobject]$r
        }
        Send $ctx @{ ok = $true; results = $results }
}

# /api/mail-test - request: $d.to (address), $d.sigMode, $d.sigHtml, $d.signature. Sends a short test email so the signature can be checked.
$ScreenHandlers['/api/mail-test'] = {
    # v1.98.8: { to, sigMode, sigHtml, signature } - sends a short test e-mail from the sender mailbox with the signature as it is on the screen (saved or not)
    if (-not $script:Who -and (Get-MailMode) -in 'signin', 'me') { throw 'Sign in to Microsoft 365 first (Settings > Connections).' }
    $c = Get-MailCfg; $snd = Get-MailSender "$($c.sender)"; if (-not (Test-MailAddr $snd)) { throw 'Save a sender mailbox first (above).' }
    $to = "$($d.to)".Trim(); if (-not (Test-MailAddr $to)) { throw 'Enter the address to send the test to.' }
    $sig = if ("$($d.sigMode)" -eq 'custom') { Get-CustomSigBlock (Get-SafeSigHtml "$($d.sigHtml)") } else { Get-EmailSigHtml "$($d.signature)" -Standard }
    $html = Add-EmailTheme ('<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937"><p>Hello,</p><p>This is a test e-mail from the Admin Console, to check how the signature looks. You can ignore it.</p>' + $sig + '</div>')
    $msg = @{ message = @{ subject = 'Admin Console - test e-mail (signature)'; body = @{ contentType = 'HTML'; content = $html }; toRecipients = @(@{ emailAddress = @{ address = $to } }) }; saveToSentItems = $false }
    try { $snd = Send-ToolMail $snd $msg }
    catch { throw (Get-MailErr $_.Exception.Message) }
    Send $ctx @{ ok = $true; message = "Test e-mail sent from $snd to $to." }
}

# ---- v1.98.30: how the e-mails are sent (Settings > Email sender) ----
#  signin  : your Microsoft sign-in, from the sender mailbox (Send As / Send on behalf needed) - as before
#  me      : from the mailbox of the person signed in to Microsoft 365
#  app     : an app registration (tenant ID, client ID, client secret) with the Mail.Send application permission
#  account : a separate mail account, signed in once with a code (device code) - used only to send e-mails
# Secrets and the account's refresh token are stored encrypted for this Windows account (DPAPI), never sent to the page.
# Encrypts text with DPAPI (only this Windows account on this PC can decrypt it). Returns '' for empty input.
function Protect-MailSecret([string]$t) { if (-not $t) { return '' }; ConvertTo-SecureString $t -AsPlainText -Force | ConvertFrom-SecureString }
# Reverse of Protect-MailSecret: returns the plain text.
function Unprotect-MailSecret([string]$e) { if (-not $e) { return '' }; $ss = ConvertTo-SecureString $e; $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss); try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } }
# The chosen sending mode; anything unknown means 'signin'.
function Get-MailMode { $m = "$((Get-MailCfg).sendMode)"; if ($m -in 'me', 'app', 'account') { $m } else { 'signin' } }
# Cached access tokens for the app and for the separate mail account.
$script:MailAppTok = $null; $script:MailAcctTok = $null
# Gets (and caches until shortly before expiry) an app-only token using the saved tenant / client id / encrypted secret.
function Get-MailAppToken($c) {
    if ($script:MailAppTok -and $script:MailAppTok.key -eq "$($c.appTenant)|$($c.appClientId)" -and (Get-Date) -lt $script:MailAppTok.exp) { return $script:MailAppTok.tok }
    if (-not $c.appTenant -or -not $c.appClientId -or -not $c.appSecretEnc) { throw 'The app registration is not complete - fill in Tenant ID, Client ID and Client secret in Settings > Email sender.' }
    $r = Invoke-MsToken @{ client_id = "$($c.appClientId)"; client_secret = (Unprotect-MailSecret "$($c.appSecretEnc)"); grant_type = 'client_credentials'; scope = 'https://graph.microsoft.com/.default' } "$($c.appTenant)"
    $script:MailAppTok = @{ key = "$($c.appTenant)|$($c.appClientId)"; tok = "$($r.access_token)"; exp = (Get-Date).AddSeconds([int]$r.expires_in - 300) }
    $script:MailAppTok.tok
}
# Gets a token for the separate mail account from its saved refresh token. If Microsoft sends a new refresh token it is saved (encrypted).
function Get-MailAcctToken($c) {
    if ($script:MailAcctTok -and $script:MailAcctTok.user -eq "$($c.acctUser)" -and (Get-Date) -lt $script:MailAcctTok.exp) { return $script:MailAcctTok.tok }
    if (-not $c.acctRefreshEnc) { throw 'No mail account is signed in - Settings > Email sender > Sign in the mail account.' }
    try { $r = Invoke-MsToken @{ client_id = $script:MsClientId; grant_type = 'refresh_token'; refresh_token = (Unprotect-MailSecret "$($c.acctRefreshEnc)"); scope = 'https://graph.microsoft.com/Mail.Send offline_access' } $(if ($c.acctTenant) { "$($c.acctTenant)" } else { 'organizations' }) }
    catch { throw "The mail account $($c.acctUser) must sign in again (Settings > Email sender): $_" }
    if ($r.refresh_token) { $c2 = Get-MailCfg; $c2.acctRefreshEnc = Protect-MailSecret "$($r.refresh_token)"; ($c2 | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8 }
    $script:MailAcctTok = @{ user = "$($c.acctUser)"; tok = "$($r.access_token)"; exp = (Get-Date).AddSeconds([int]$r.expires_in - 300) }
    $script:MailAcctTok.tok
}
# Returns the mailbox the email really comes from for the current mode (own mailbox for 'me', the mail account for 'account', else the typed one).
function Get-MailSender($typed) {
    # the mailbox the e-mail really comes from, for the chosen way of sending
    $m = Get-MailMode; $c = Get-MailCfg
    if ($m -eq 'me') { if (-not $script:WhoUpn) { throw 'Sign in to Microsoft 365 first - e-mails are sent from your own mailbox.' }; return "$($script:WhoUpn)" }
    if ($m -eq 'account' -and -not "$typed".Trim()) { return "$($c.acctUser)" }
    "$typed".Trim()
}
# Sends one email through Graph sendMail in the chosen mode and returns the sender used. 'app' / 'account' call REST with their own token;
# the other modes use the signed-in Graph connection.
function Send-ToolMail($snd, $msgObj) {
    # sends one e-mail the way chosen in Settings > Email sender; returns the mailbox it was sent from
    $c = Get-MailCfg; $m = Get-MailMode; $snd = Get-MailSender $snd
    $json = $msgObj | ConvertTo-Json -Depth 8; $uri = 'https://graph.microsoft.com/v1.0/users/' + [uri]::EscapeDataString($snd) + '/sendMail'
    if ($m -in 'app', 'account') {
        $tok = if ($m -eq 'app') { Get-MailAppToken $c } else { Get-MailAcctToken $c }
        try { Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $tok" } -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -ErrorAction Stop | Out-Null }
        catch { $e = $_.Exception.Message; try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.error.message) { $e = "$($j.error.code): $($j.error.message)" } } catch {}
            throw $(if ($m -eq 'app') { "$e | The app needs the Mail.Send APPLICATION permission with admin consent (and, if limited, an application access policy that includes $snd)." } else { "$e | The mail account $($c.acctUser) needs Send As on $snd (or send from its own mailbox)." }) }
    } else {
        Invoke-MgGraphRequest -Method POST -Uri $uri -Body $json -ContentType 'application/json; charset=utf-8' -ErrorAction Stop | Out-Null
    }
    $snd
}
# Copy of the settings for the browser, without the encrypted secrets.
function Get-MailCfgView($c) { $o = [ordered]@{}; foreach ($k in $c.Keys) { if ($k -notin 'appSecretEnc', 'acctRefreshEnc') { $o[$k] = $c[$k] } }; $o.hasAppSecret = [bool]$c.appSecretEnc; $o.acctSigned = [bool]$c.acctRefreshEnc; $o }
$script:MailDev = $null
# /api/mailacct-start - request: $d.tenant (optional). Starts the 'device code' sign-in of the separate mail account.
# Returns the code and web address the operator must open, and how long it is valid.
$ScreenHandlers['/api/mailacct-start'] = {
    # { tenant } - start the sign-in of the separate mail account: returns a code to type at microsoft.com/devicelogin
    $t = "$($d.tenant)".Trim(); if (-not $t) { $t = 'organizations' } elseif ($t -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'The organization must be a domain or a directory ID.' }
    try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$t/oauth2/v2.0/devicecode" -Body @{ client_id = $script:MsClientId; scope = 'https://graph.microsoft.com/Mail.Send offline_access openid profile' } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch { throw "Could not start the sign-in: $($_.Exception.Message)" }
    $script:MailDev = @{ code = "$($r.device_code)"; tenant = $t; until = (Get-Date).AddSeconds([int]$r.expires_in) }
    Send $ctx @{ ok = $true; userCode = "$($r.user_code)"; url = "$($r.verification_uri)"; expires = [int]$r.expires_in; interval = [int]$r.interval }
}
# /api/mailacct-poll - no fields. Asks Microsoft whether the code was used. Answers { pending:true } while waiting; when done, saves the account
# (refresh token encrypted) and returns the settings. The user name comes from the id token (JWT) payload.
$ScreenHandlers['/api/mailacct-poll'] = {
    if (-not $script:MailDev) { throw 'Start the sign-in first.' }
    if ((Get-Date) -gt $script:MailDev.until) { $script:MailDev = $null; throw 'The code expired - start again.' }
    try { $r = Invoke-MsToken @{ client_id = $script:MsClientId; grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = $script:MailDev.code } $script:MailDev.tenant }
    catch { $m = "$_"; if ($m -match 'AADSTS70016|authorization_pending|pending') { Send $ctx @{ ok = $true; pending = $true }; return }; if ($m -match 'AADSTS70019|expired') { $script:MailDev = $null }; throw "Sign-in did not finish: $m" }
    # JWT payload is base64url: convert - and _ back to + and /, add = padding, then decode to read preferred_username and tid.
    $p = ("$($r.id_token)" -split '\.')[1]; $p = $p.Replace('-', '+').Replace('_', '/'); while ($p.Length % 4) { $p += '=' }
    $cl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    $c = Get-MailCfg; $c.acctUser = "$($cl.preferred_username)"; $c.acctTenant = "$($cl.tid)"; $c.acctRefreshEnc = Protect-MailSecret "$($r.refresh_token)"
    if (-not $c.sender) { $c.sender = $c.acctUser }
    ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8
    $script:MailDev = $null; $script:MailAcctTok = @{ user = $c.acctUser; tok = "$($r.access_token)"; exp = (Get-Date).AddSeconds([int]$r.expires_in - 300) }
    if (Get-Command Write-ActRow -ErrorAction SilentlyContinue) { Write-ActRow 'Settings' 'Mail account signed in' $c.acctUser 'Done' '' }
    Send $ctx @{ ok = $true; pending = $false; user = $c.acctUser; settings = (Get-MailCfgView $c) }
}
# /api/mailacct-signout - no fields. Removes the saved mail account and its token; falls back to 'signin' mode if it was in use.
$ScreenHandlers['/api/mailacct-signout'] = {
    $c = Get-MailCfg; $u = $c.acctUser; $c.acctUser = ''; $c.acctRefreshEnc = ''; $c.acctTenant = ''; if ($c.sendMode -eq 'account') { $c.sendMode = 'signin' }
    ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8; $script:MailAcctTok = $null
    if (Get-Command Write-ActRow -ErrorAction SilentlyContinue) { Write-ActRow 'Settings' 'Mail account signed out' "$u" 'Done' '' }
    Send $ctx @{ ok = $true; settings = (Get-MailCfgView $c) }
}

# v1.98.37: sign in the separate mail account on the normal Microsoft sign-in page (a pop-up window), instead of a code
# Pending browser sign-ins by 'state' value (each lasts 15 minutes).
$script:MailAuth = @{}
# /api/mailacct-browser - request: $d.origin (this tool's address), $d.tenant. Starts a normal pop-up Microsoft sign-in (authorization code + PKCE).
# Returns the sign-in URL. The reply comes back to Complete-MailAcctLogin below.
$ScreenHandlers['/api/mailacct-browser'] = {
    $origin = "$($d.origin)".TrimEnd('/')
    if ($origin -notmatch '^http://(localhost|127\.0\.0\.1|[A-Za-z0-9-]+):' + $Port + '$') { throw "Open the tool on this computer at http://localhost:$Port to sign in the mail account (Microsoft allows only that address for this sign-in) - or use 'Use a code instead'." }
    $tenant = "$($d.tenant)".Trim(); if (-not $tenant) { $tenant = 'organizations' } elseif ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'The organization must be a domain or a directory ID.' }
    # PKCE: a random verifier, its SHA-256 hash as the challenge, and a random state value to match the reply.
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rb = New-Object byte[] 48; $rng.GetBytes($rb); $verifier = ConvertTo-B64Url $rb
    $sb = New-Object byte[] 24; $rng.GetBytes($sb); $state = 'mail' + (ConvertTo-B64Url $sb)
    $challenge = ConvertTo-B64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    foreach ($k in @($script:MailAuth.Keys)) { if (((Get-Date) - $script:MailAuth[$k].time).TotalMinutes -gt 15) { $script:MailAuth.Remove($k) } }
    $script:MailAuth[$state] = @{ verifier = $verifier; tenant = $tenant; time = (Get-Date) }
    $q = [ordered]@{ client_id = $script:MsClientId; response_type = 'code'; redirect_uri = "http://localhost:$Port"; response_mode = 'query'; scope = 'https://graph.microsoft.com/Mail.Send offline_access openid profile'; state = $state; code_challenge = $challenge; code_challenge_method = 'S256'; prompt = 'select_account' }
    Send $ctx @{ ok = $true; url = ("https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize?" + (($q.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString("$($_.Value)"))" }) -join '&')) }
}
# Called when Microsoft sends the browser back to this tool after the pop-up sign-in. Input: $ctx (the web request).
# Exchanges the code for tokens, saves the account, and shows a small page that tells the operator it worked (or why not).
function Complete-MailAcctLogin($ctx) {
    $qs = $ctx.Request.QueryString; $st = $script:MailAuth["$($qs['state'])"]; $script:MailAuth.Remove("$($qs['state'])")
    $title = 'Mail account signed in'; $msg = ''; $ok = $false
    try {
        if (-not $st) { throw 'This sign-in link is not valid any more - start again in Settings > Email sender.' }
        if ($qs['error']) { throw "$($qs['error_description'])" }
        $r = Invoke-MsToken @{ client_id = $script:MsClientId; grant_type = 'authorization_code'; code = "$($qs['code'])"; redirect_uri = "http://localhost:$Port"; code_verifier = $st.verifier; scope = 'https://graph.microsoft.com/Mail.Send offline_access openid profile' } $st.tenant
        $p = ("$($r.id_token)" -split '\.')[1]; $p = $p.Replace('-', '+').Replace('_', '/'); while ($p.Length % 4) { $p += '=' }
        $cl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
        $c = Get-MailCfg; $c.acctUser = "$($cl.preferred_username)"; $c.acctTenant = "$($cl.tid)"; $c.acctRefreshEnc = Protect-MailSecret "$($r.refresh_token)"
        ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8
        $script:MailAcctTok = @{ user = $c.acctUser; tok = "$($r.access_token)"; exp = (Get-Date).AddSeconds([int]$r.expires_in - 300) }
        if (Get-Command Write-ActRow -ErrorAction SilentlyContinue) { Write-ActRow 'Settings' 'Mail account signed in' $c.acctUser 'Done' '' }
        $msg = "E-mails can now be sent with $($c.acctUser). This window closes by itself."; $ok = $true
    } catch { $title = 'Sign-in failed'; $msg = "$($_.Exception.Message)" }
    $h = "<!doctype html><html><head><meta charset='utf-8'><title>Admin Console</title></head><body style='font-family:Segoe UI,Arial;text-align:center;margin-top:16vh'><h2>$([Net.WebUtility]::HtmlEncode($title))</h2><p style='color:#64748b'>$([Net.WebUtility]::HtmlEncode($msg))</p><script>try{window.opener&&window.opener.postMessage('mailacct-$(if ($ok) { 'ok' } else { 'fail' })','*')}catch(e){}$(if ($ok) { 'setTimeout(function(){window.close()},1500)' })</script></body></html>"
    $b = [Text.Encoding]::UTF8.GetBytes($h); $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
}

# /api/reset-mail-preview - request: $d.upn, optional $d.subject. Returns { html, subject, password, kind } for the preview window.
# v1.98.50: show the exact e-mail (with the real password) before it is sent - read only, nothing is sent
$ScreenHandlers['/api/reset-mail-preview'] = {
    Clear-OldSecrets
    $upn = "$($d.upn)".Trim(); $s = $script:ResetSecrets[$upn.ToLower()]
    if (-not $s) { throw 'The password is no longer held by the tool (more than 60 minutes ago, or the tool was restarted). Reset again.' }
    $c = Get-MailCfg
    $subj = "$($d.subject)".Trim(); if (-not $subj) { $subj = $(if ($s.tap) { "$($c.subjectTap)" } else { "$($c.subject)" }) }
    try { $tn = Get-EmailTenantName $s.upn; if ($tn -and ($tn.given -or $tn.sn)) { $s.given = $tn.given; $s.sn = $tn.sn } } catch {}
    $html = New-PwMailHtml $s $c
    $pi = Get-EmailImage $(if ($s.ad) { 'ad' } elseif ($s.tap) { 'tap' } else { 'temp' })
    # The inline picture is embedded as base64 for the preview (a real email uses the cid: attachment).
    if ($pi) { $html = "$html".Replace('cid:emailimg', 'data:' + $pi.type + ';base64,' + [Convert]::ToBase64String($pi.bytes)) }
    Send $ctx @{ ok = $true; html = "$html"; subject = $subj; password = "$($s.secret)"; kind = $(if ($s.tap) { 'Temporary Access Pass' } elseif ($s.pwOnce) { 'One-time password (must change at next sign-in)' } else { 'Password' }); name = "$($s.name)" }
}

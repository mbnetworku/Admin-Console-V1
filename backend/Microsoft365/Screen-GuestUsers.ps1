# Screen-GuestUsers.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Guest users
# Screen version: 2.0.0   (changes ONLY when this screen changes - not with every release)

# WHAT IT DOES: invites outside people (guests) into Microsoft Entra ID / the organization, optionally e-mails them the invitation and
# adds them to up to 5 Teams. One row of result per e-mail address.
# ENDPOINT: POST /api/guest-invite. Request fields: guests [{email,name}], mode (sender|microsoft|both|none), resend, message, subject,
# sender, redirectUrl, teams [group ids]. Reply: { ok, results [...], sender, mode }.
# GRAPH: POST /invitations (needs User.Invite.All, or User.ReadWrite.All / Directory.ReadWrite.All), GET /users/{id}, GET /organization,
# sendMail from the sender mailbox (via Send-ToolMail) and team membership through the Teams helpers in Screen-TeamsMembers.ps1.
# Data files: the mail settings file (remembers the sender), the mail log and Teams log. Permission: the signed-in Microsoft user's rights.
#
# (the original description of the screen follows)
# and send the invitation e-mail yourself from a SENDER MAILBOX you choose (never from your own account), with your own message.
# How the invitation is sent (mode):
#   sender    - the guest is created WITHOUT Microsoft's own e-mail (sendInvitationMessage = false); the tool then e-mails the personal
#               redeem link from the sender mailbox you typed (Graph sendMail, needs Send As on that mailbox - same as the password e-mails)
#   microsoft - Microsoft sends its standard invitation (with your message in it) - it comes from Microsoft, not from your account
#   both      - Microsoft sends its invitation AND the tool e-mails the link from the sender mailbox (v1.97.4)
#   none      - the guest is only created; nobody is e-mailed (the link is shown so you can pass it on)
# Already a guest in your organization? With 'resend' (default on) the invitation is sent again the same way (v1.97.4).

# Checks, before anything else, that the person is signed in to Microsoft and the token has a scope that allows inviting guests.
# If the scope list is empty (unknown) the check is skipped and Microsoft itself will refuse later if needed.
function Test-GuestReady {
    if (-not $script:Who) { throw 'Not connected. Sign in to Microsoft first.' }
    $sc = @(Get-MsScopes)
    if ($sc.Count -and ($sc -notcontains 'User.Invite.All') -and ($sc -notcontains 'User.ReadWrite.All') -and ($sc -notcontains 'Directory.ReadWrite.All')) {
        throw 'This screen needs the User.Invite.All permission. Sign out of Microsoft, connect again and approve it (an administrator may have to approve it once for your organization).'
    }
}
# Builds the HTML of the invitation e-mail. $name = guest name, $url = personal redeem link, $msg = optional own message,
# $org = organization name, $sig = signature. Texts come from the Email messages screen (Get-EmailPart); button, layout and the message box
# are fixed here. Everything typed by a person is HTML-encoded so it cannot inject HTML. Returns the HTML text.
function New-GuestMailHtmlRaw($name, $url, $msg, $org, $sig) {
    # The wording comes from the Email messages screen; the button, the layout and your own message stay here.
    $e = { param($t) [Net.WebUtility]::HtmlEncode("$t") }
    $gn = Get-EmailNames 'guest' '' '' $name
    $v = @{ name = "$name"; first = $gn.first; last = $gn.last; full = $gn.full; greet = $gn.greet; org = "$org" }; $raw = @{ url = "$url" }
    $P = { param($k, $l) Get-EmailPart 'guest' $k $l $v $raw }
    $hk = if ($name) { 'helloNamed' } else { 'helloPlain' }
    $ik = if ($org) { 'intro' } else { 'introPlain' }
    $custom = ''
    if ("$msg".Trim()) { $custom = '<div style="margin:16px 0;padding:12px 16px;background:#f1f5f9;border-left:4px solid #2563eb;border-radius:6px;white-space:pre-wrap">' + (& $e "$msg".Trim()) + '</div>' }
    $html = @"
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#0f172a;line-height:1.55;max-width:620px">
<p>$(& $P $hk 'en')</p>
<p>$(& $P $ik 'en')</p>
$custom
<p>$(& $P 'instruction' 'en')</p>
<p style="margin:20px 0"><a href="$url" style="background:#2563eb;color:#ffffff;text-decoration:none;padding:11px 22px;border-radius:8px;font-weight:600;display:inline-block">$(& $P 'button' 'en')</a></p>
<p style="color:#64748b;font-size:12.5px">$(& $P 'fallback' 'en')<br>$url</p>
$(Get-EmailSigHtml $sig)
</div>
"@
    # Optional Arabic part (empty by default - fill the Arabic boxes on the Email messages screen to add it)
    # Arabic part: only added when someone filled the Arabic boxes. It is put inside the closing </div> of the English part (right-to-left block).
    if ((Get-EmailText 'guest' $ik 'ar').Trim()) {
        $btnAr = (& $P 'button' 'ar'); if (-not $btnAr.Trim()) { $btnAr = (& $P 'button' 'en') }
        $html = $html.Substring(0, $html.LastIndexOf('</div>')) +
            '<div dir="rtl" lang="ar" style="font-family:Segoe UI,Tahoma,Arial,sans-serif;font-size:15px;color:#1f2937;line-height:1.7;text-align:right;border-top:2px solid #e5e7eb;margin-top:22px;padding-top:14px">' +
            "<p>$(& $P $hk 'ar')</p><p>$(& $P $ik 'ar')</p><p>$(& $P 'instruction' 'ar')</p>" +
            "<p style=""margin:20px 0""><a href=""$url"" style=""background:#2563eb;color:#ffffff;text-decoration:none;padding:11px 22px;border-radius:8px;font-weight:600;display:inline-block"">$btnAr</a></p>" +
            "<p style=""color:#64748b;font-size:12.5px"">$(& $P 'fallback' 'ar')<br><span dir=""ltr"">$url</span></p>" +
            "$(Get-EmailSigHtml $sig -Rtl)</div></div>"
    }
    $html
}

# Handler: validate the request first (guests, mode, sender, redirect, teams), then process the guests one by one.
$ScreenHandlers['/api/guest-invite'] = {
    Test-GuestReady
    # Clean the guest list: remove spaces, lower-case, skip empty and duplicate addresses. Limit 100 per run to protect Graph and the mailbox.
    # ---- the guests
    $guests = @(); $seen = @{}
    foreach ($g in @($d.guests)) {
        $em = ("$($g.email)" -replace '\s', '').Trim().ToLower(); if (-not $em) { continue }
        if ($seen[$em]) { continue }; $seen[$em] = 1
        $guests += [pscustomobject]@{ email = $em; name = "$($g.name)".Trim() }
    }
    if (-not $guests.Count) { throw 'Add at least one email address.' }
    if ($guests.Count -gt 100) { throw 'Up to 100 guests at a time.' }
    # ---- how the invitation is sent
    $mode = "$($d.mode)"; if ($mode -notin 'sender', 'microsoft', 'both', 'none') { throw 'Choose how the invitation is sent.' }
    $resend = ($null -eq $d.resend) -or [bool]$d.resend   # already a guest: send the invitation again (default yes)
    # $msSend = Microsoft sends its own e-mail; $toolSend = this tool sends the e-mail from the sender mailbox.
    $msSend = ($mode -in 'microsoft', 'both'); $toolSend = ($mode -in 'sender', 'both')
    $msg = "$($d.message)".Trim(); if ($msg.Length -gt 2000) { throw 'The message is too long (up to 2000 characters).' }
    $c = Get-MailCfg; $snd = ''; $subject = "$($d.subject)".Trim(); if (-not $subject) { $subject = Get-EmailSubject 'guest' }
    if ($toolSend) {
        $snd = "$($d.sender)".Trim(); if (-not $snd) { $snd = "$($c.sender)".Trim() }
        if (-not (Test-MailAddr $snd)) { throw 'Type the sender: the mailbox the invitation is sent from (for example it-noreply@contoso.com).' }
        if (Test-OwnAddr $snd) { throw 'The sender cannot be your own account. Type another (shared or service) mailbox.' }
        # Remember the sender (and the last 10 used) in the mail settings file so it is pre-filled next time. A failed save is not important.
        if ($snd -ine "$($c.sender)" -or -not (@($c.senders) -contains $snd)) {   # remember it, like the password e-mails
            $c.sender = $snd; $c.senders = @(@($snd) + @($c.senders | Where-Object { "$_" -and "$_" -ine $snd }) | Select-Object -First 10)
            try { ($c | ConvertTo-Json) | Out-File $script:MailCfgFile -Encoding utf8 } catch {}
        }
    }
    # Page the guest sees after accepting. Must be https and contain no spaces, quotes or < > (it goes into the invitation request).
    $redirect = "$($d.redirectUrl)".Trim(); if (-not $redirect) { $redirect = 'https://myapplications.microsoft.com/' }
    if ($redirect -notmatch '^https://[^\s"<>]+$') { throw 'The page the guest lands on after accepting must be an https address.' }
    # Optional: team group ids to add each guest to. Names are looked up once and the organization name is read for the e-mail text.
    # ---- Teams (optional)
    $gids = @($d.teams | ForEach-Object { "$_" } | Where-Object { $_ })
    if ($gids.Count -gt 5) { throw 'Up to 5 teams at a time.' }
    $tnames = @{}
    if ($gids.Count) { Test-TmReady; foreach ($gid in $gids) { $tnames[$gid] = Get-TmTeamName $gid } }
    $org = ''; try { $org = "$((Invoke-TmGraph GET '/organization?$select=displayName').value[0].displayName)" } catch {}
    $res = New-Object System.Collections.ArrayList
    # Main loop: one guest at a time. $r is the result row shown in the table, $parts collects the sentences for the Message column.
    # An error for one guest is caught at the bottom and does not stop the others.
    foreach ($g in $guests) {
        $r = [ordered]@{ email = $g.email; name = $g.name; status = ''; message = ''; mail = ''; teams = ''; link = '' }
        $parts = @()
        try {
            if ($g.email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $r.status = 'Invalid'; throw 'Not a valid email address' }
            $uid = $null; $url = $null
            # Is this address already in the directory? A real member gets no invitation; an existing guest is re-invited only when 'resend' is on.
            $u = Find-TmUser $g.email; $again = $false
            if ($u) {
                $uid = "$($u.id)"; $ui = $null
                # Read the user's type (Member/Guest) and invitation state; if this lookup fails we simply carry on without it.
                try { $ui = Invoke-TmGraph GET ('/users/' + $uid + '?$select=id,displayName,userType,externalUserState,mail') } catch {}
                $state = "$($ui.externalUserState)"
                if ("$($ui.userType)" -ne 'Guest') {
                    $r.status = 'Already a member'; $r.mail = 'Not sent'; $parts += 'This is an account of your own organization (not a guest) - no invitation is needed'
                } elseif (-not $resend) {
                    $r.status = 'Already a guest'; $r.mail = 'Not sent'; $parts += "Already a guest$(if ($state) { " ($state)" }) - invitation not sent again (Send again was off)"
                } else { $again = $true; $parts += "Already a guest$(if ($state) { " ($state)" }) - invitation sent again" }
            }
            # Create (or re-create the link for) the invitation: Graph POST /invitations. sendInvitationMessage tells Microsoft whether to e-mail the guest.
            # The reply holds the guest's user id and the personal redeem link, which we show and, in sender mode, e-mail ourselves.
            if (-not $u -or $again) {
                $inv = @{ invitedUserEmailAddress = $g.email; inviteRedirectUrl = $redirect; sendInvitationMessage = $msSend }
                if ($g.name -and -not $again) { $inv.invitedUserDisplayName = $g.name }
                if ($msSend) { $mi = @{ messageLanguage = 'en-US' }; if ($msg) { $mi.customizedMessageBody = $msg }; $inv.invitedUserMessageInfo = $mi }
                $o = Invoke-TmGraph POST '/invitations' $inv
                $uid = "$($o.invitedUser.id)"; $url = "$($o.inviteRedeemUrl)"; $r.link = $url
                $r.status = if ($again -and $mode -eq 'none') { 'Already a guest (new link)' } elseif ($again) { 'Invitation re-sent' } else { 'Invited' }
                if (-not $again) { $parts += 'Guest created' }
                $ms = "$($o.status)"   # PendingAcceptance = waiting for the guest; Completed = Microsoft redeemed it by itself and sends no e-mail
                $mails = @()
                if ($msSend) {
                    if ($ms -eq 'Completed') { $mails += 'Microsoft: invitation already accepted - Microsoft may not send an email (choose Both or the sender mailbox to be sure)'; $parts += 'Microsoft reports the invitation as already accepted (Completed), so its email may not arrive' }
                    else { $mails += 'Sent by Microsoft (from invites@microsoft.com - ask the guest to check Junk)'; $parts += 'invitation sent by Microsoft' }
                }
                # Send the invitation e-mail from the chosen sender mailbox (Graph sendMail). A failure is logged and shown, the guest stays created.
                if ($toolSend) {
                    try {
                        $body = @{ message = @{ subject = $subject; body = @{ contentType = 'HTML'; content = (New-GuestMailHtml $g.name $url $msg $org "$($c.signature)") }
                                    toRecipients = @(@{ emailAddress = @{ address = $g.email } }); importance = 'normal' }; saveToSentItems = [bool]$c.saveCopy }
                        $att = @(Get-EmailAttach 'guest'); if ($att.Count) { $body.message.attachments = $att }
                        $snd = Send-ToolMail $snd $body
                        $mails += "Sent from $snd"; $parts += "invitation emailed from $snd"
                        Write-MailLog $g.email $snd $g.email $(if ($again) { 'Sent (guest invitation, re-sent)' } else { 'Sent (guest invitation)' })
                    } catch {
                        $m = Get-MailErr $_.Exception.Message; $mails += "Not sent from ${snd}: $m"; $parts += 'the email from the sender mailbox failed (the link is in the table)'
                        Write-MailLog $g.email $snd $g.email "Failed (guest invitation): $m"
                    }
                }
                if ($mode -eq 'none') { $mails += 'Not sent'; $parts += 'no email sent' }
                $r.mail = $mails -join '; '
            }
            # Add the guest to each chosen team. A just-created guest can take a few seconds to appear in Entra, so on 'not found' type errors we wait
            # 3 seconds and retry (up to 4 tries). Every result is written to the Teams log.
            if ($gids.Count -and $uid) {
                $tr = @()
                foreach ($gid in $gids) {
                    $done = $false; $last = ''
                    for ($try = 0; $try -lt 4 -and -not $done; $try++) {
                        try { $a = Add-TmOne $gid ([pscustomobject]@{ id = $uid }) 'Member'; $tr += "$($tnames[$gid]): $(if ($a.status -eq 'Skipped') { $a.message } else { 'added' })"; Write-TeamsLog $tnames[$gid] $gid $g.email 'Member' $a.status $a.message; $done = $true }
                        catch { $last = $_.Exception.Message; if ($last -match 'does not exist|Request_ResourceNotFound|not found') { Start-Sleep -Seconds 3 } else { break } }
                    }
                    if (-not $done) { $tr += "$($tnames[$gid]): FAILED - $last"; Write-TeamsLog $tnames[$gid] $gid $g.email 'Member' 'Failed' $last }
                }
                $r.teams = $tr -join '; '; $parts += "Teams: $($r.teams)"
                # If any team failed, change the status so the table shows it.
                if ($r.teams -match 'FAILED') { $r.status = if ($r.status -in 'Invited', 'Invitation re-sent') { "$($r.status) (Teams failed)" } else { 'Teams failed' } }
            } elseif (-not $gids.Count) { $r.teams = 'Not asked' }
            $r.message = $parts -join ' - '
        # Anything that went wrong for this guest: mark as Failed (unless a clearer status like Invalid was already set) and show the reason.
        } catch {
            if (-not $r.status -or $r.status -in 'Invited', 'Invitation re-sent') { $r.status = 'Failed' }
            $r.message = (@($parts) + $_.Exception.Message) -join ' - '
        }
        [void]$res.Add([pscustomobject]$r)
    }
    # Reply with all result rows.
    Send $ctx @{ ok = $true; results = @($res.ToArray()); sender = $snd; mode = $mode }
}

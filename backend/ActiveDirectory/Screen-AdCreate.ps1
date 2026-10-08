# Screen-AdCreate.ps1 - back end for the "Create AD users" screen. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Create AD users
# Screen version: 2.9.0   (changes ONLY when this screen changes - not with every release)
#
# STRICTLY CREATION ONLY:
#  * creates new user accounts in an EXISTING organizational unit (OU) - never creates, renames or deletes an OU
#  * never deletes, moves, renames or changes an existing account (if the username / UPN already exists, the row is refused)
#  * the only change to an existing object: the new user is added to the groups you chose
# Single user or many from a CSV file - the same checks and username rules for both.
#
# Username rules (suggestion): letters only - no numbers, dots or special characters.
#   A title before a dot is removed ("kl.salman ali" -> "salman ali"). Last name = last word.
#   First try: first letter of the first name + last name (salman ali -> sali).
#   If taken: the first letters of the other names are added one by one before the last name
#   (Ali Ahmad Khan Salman -> asalman -> aasalman -> aaksalman). Nothing else is ever added (no numbers).

# ==== OVERVIEW ====
# CREATE-ONLY screen: it only creates NEW AD user accounts. No delete, no OU creation, no moves, no edits of existing accounts.
# (The only existing objects touched: the chosen groups get the new user added as a member.)
# Endpoints registered below:
#   /api/adc-meta      list of UPN domains and existing OUs for the drop-downs
#   /api/adc-check     live check of ONE row while typing (name/description in use, username suggestions)
#   /api/adc-validate  check up to 500 rows (CSV import or several users) - changes nothing
#   /api/adc-create    really create the users (needs the word CREATE as confirmation); max 500 rows
# Uses: on-premises Active Directory only (DirectorySearcher / ADSI via the AD sign-in held in $script:AdCred). No Graph, no Exchange.
# Writes an audit CSV (logs\ad-create-audit-yyyy-MM.csv) and an activity-log row for every row processed.
# Who may use it: any signed-in portal user who is allowed to open this screen and has signed in to on-premises AD.
#
# Cache of the OU list per signed-in session, so the OU query is not repeated on every key press (kept 10 minutes).
$script:AdcOuCache = @{}   # session -> @{ at; list }

# Splits a full name into usable parts. Input: full name text. Returns a hashtable:
#   words = cleaned words, ascii = same words in plain a-z lower case (accents removed), first / last = first and last cleaned word.
function Get-AdcNameParts([string]$full) {
    # Step 1: split on spaces; if a word contains a dot take only the part after the last dot (removes titles like 'kl.' or 'Dr.').
    # Step 2: keep only letters, apostrophe and hyphen (\p{L} = any letter in any language) and trim ' and - from the ends.
    # Step 3: ascii = decompose accents (FormD), drop everything that is not A-Z, lower case. Used for usernames.
    $t = "$full".Trim()
    # a title / prefix before a dot belongs to the word: "kl.salman" -> "salman", "Dr. Ali" -> "Ali"
    $words = @($t -split '\s+' | Where-Object { $_ } | ForEach-Object { if ($_ -match '\.') { ($_ -split '\.')[-1] } else { $_ } } | Where-Object { $_ })
    $clean = @($words | ForEach-Object { ($_ -replace "[^\p{L}'-]", '').Trim("'-") } | Where-Object { $_ })
    $ascii = @($clean | ForEach-Object { ($_.Normalize([Text.NormalizationForm]::FormD) -replace '[^A-Za-z]', '').ToLower() } | Where-Object { $_ })
    $first = $(if ($clean.Count) { $clean[0] } else { '' }); $last = $(if ($clean.Count -gt 1) { $clean[-1] } else { '' })
    @{ words = $clean; ascii = $ascii; first = $first; last = $last }
}
# Builds the list of username suggestions for a full name: initials of the leading names + last name, longer one by one.
# Input: full name. Returns an array of strings (letters only, max 20 characters = AD sAMAccountName limit for logon names).
# every allowed suggestion, in order (letters only, at most 20 characters)
function Get-AdcCandidates([string]$full) {
    $p = Get-AdcNameParts $full; $a = @($p.ascii)
    if (-not $a.Count) { return @() }
    if ($a.Count -eq 1) { return @($a[0].Substring(0, [Math]::Min(20, $a[0].Length))) }
    $last = $a[-1]; $pre = @($a[0..($a.Count - 2)]); $out = @()
    for ($k = 1; $k -le $pre.Count; $k++) {
        $ini = (@($pre[0..($k - 1)] | ForEach-Object { $_.Substring(0, 1) }) -join '')
        $c = "$ini$last"; if ($c.Length -gt 20) { $c = $c.Substring(0, 20) }
        if ($out -notcontains $c) { $out += $c }
    }
    $out
}
# Creates an LDAP search object on the domain root. $filter = LDAP filter, $props = attributes to load, $size = max results (0 = no limit).
# PageSize 500 makes AD return results in pages so lists over 1000 entries still work. Caller must Dispose() it.
function Get-AdcSearcher($filter, [string[]]$props, $size = 0) {
    $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.Filter = $filter; $ds.PageSize = 500
    if ($size) { $ds.SizeLimit = $size }
    foreach ($p in $props) { [void]$ds.PropertiesToLoad.Add($p) }
    $ds
}
# Looks in AD for an existing account that already uses this username (sAMAccountName), UPN or e-mail (also as a proxy address).
# Returns an array of hashtables (sam, upn, mail, name) - empty array means everything is free. Maximum 20 hits.
function Test-AdcTaken([string]$sam, [string]$upn, [string]$mail) {
    $parts = @()
    if ($sam) { $parts += "(sAMAccountName=$(ConvertTo-LdapValue $sam))" }
    if ($upn) { $parts += "(userPrincipalName=$(ConvertTo-LdapValue $upn))"; $parts += "(proxyAddresses=smtp:$(ConvertTo-LdapValue $upn))" }
    if ($mail) { $parts += "(mail=$(ConvertTo-LdapValue $mail))"; $parts += "(proxyAddresses=smtp:$(ConvertTo-LdapValue $mail))" }
    if (-not $parts.Count) { return @() }
    $ds = Get-AdcSearcher ("(|" + ($parts -join '') + ")") @('samaccountname', 'userprincipalname', 'mail', 'displayname') 20
    try { @($ds.FindAll() | ForEach-Object { @{ sam = "$($_.Properties['samaccountname'][0])"; upn = "$($_.Properties['userprincipalname'][0])"; mail = "$($_.Properties['mail'][0])"; name = "$($_.Properties['displayname'][0])" } }) } finally { $ds.Dispose() }
}
# Returns all existing OUs (dn, name, readable path like domain/Parent/Child, description) sorted by path.
# The result is cached for 10 minutes per session because the OU search can be slow in big domains.
function Get-AdcOus {
    $k = Get-SessId $script:Session; $c = $script:AdcOuCache[$k]
    if ($c -and ((Get-Date) - $c.at).TotalMinutes -lt 10) { return $c.list }
    $ds = Get-AdcSearcher '(objectCategory=organizationalUnit)' @('distinguishedname', 'name', 'description')
    $list = @()
    try {
        foreach ($r in $ds.FindAll()) {
            $dn = "$($r.Properties['distinguishedname'][0])"
            # Split the distinguished name on commas that are not escaped (\,) and keep the OU= parts, un-escaping them; reverse to get top-down order.
            # The DC= parts are joined with dots to give the domain name.
            $ou = @(($dn -split '(?<!\\),') | Where-Object { $_ -match '^OU=' } | ForEach-Object { $_.Substring(3) -replace '\\(.)', '$1' }); [array]::Reverse($ou)
            $dom = ((($dn -split '(?<!\\),') | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.')
            $list += @{ dn = $dn; name = "$($r.Properties['name'][0])"; path = "$dom/" + ($ou -join '/'); desc = "$($r.Properties['description'][0])" }
        }
    } finally { $ds.Dispose() }
    $list = @($list | Sort-Object { $_.path })
    $script:AdcOuCache[$k] = @{ at = Get-Date; list = $list }
    $list
}
# Stops the request with a clear message unless this PC is domain joined and the user has signed in to on-premises AD.
function Test-AdcReady { if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so AD accounts cannot be created here.' }; if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the AD button at the top right).' } }
# Returns the UPN suffixes (the part after @) that may be used: the domain itself plus extra suffixes configured in the forest (Partitions container).
function Get-AdcSuffixes {
    $list = New-Object Collections.Generic.List[string]
    $dom = ((("$($script:AdCred.Dnc)" -split ',') | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.'); if ($dom) { $list.Add($dom) }
    # Extra UPN suffixes are stored on CN=Partitions in the configuration naming context. Errors are ignored (the domain name is still offered).
    try { $rd = Get-RootDse; $cfg = "$($rd.Properties['configurationNamingContext'].Value)"; $pe = New-AdEntry "CN=Partitions,$cfg"; foreach ($x in $pe.Properties['uPNSuffixes']) { if ("$x") { $list.Add("$x") } } } catch {}
    @($list | Select-Object -Unique)
}
# Escapes a name so it is safe as the CN= part of a distinguished name (LDAP rules: , + " \ < > ; = need a backslash, and a leading space/# or trailing space).
function ConvertTo-AdcCn([string]$s) { $s = $s -replace '([,+"\\<>;=])', '\$1'; if ($s -match '^[ #]') { $s = '\' + $s }; if ($s -match ' $') { $s = $s.Substring(0, $s.Length - 1) + '\ ' }; $s }

# Checks ONE user row without changing anything. Input: $r = row (description, displayName, givenName, sn, upnDomain, sam, mail, ou, title,
# department, company, expires, groups), $suffixes = allowed UPN domains, $ouSet = existing OUs by DN.
# Returns an object with the cleaned values plus errors (block creation), warnings (only shown), suggestions and ok = true when no errors.
# one row: normalise + check everything (nothing is changed)
function Test-AdcRow($r, $suffixes, $ouSet) {
    $o = [ordered]@{ errors = @(); warnings = @(); suggestions = @() }
    # Description and display name are mandatory; length limits come from AD (description 1024, CN 64).
    $desc = "$($r.description)".Trim(); $disp = "$($r.displayName)".Trim()
    if (-not $desc) { $o.errors += 'Description is required.' } elseif ($desc.Length -gt 1024) { $o.errors += 'The description is too long.' }
    if (-not $disp) { $o.errors += 'Full name / display name is required.' } elseif ($disp.Length -gt 64) { $o.errors += 'The full name can be at most 64 characters (it is also the name of the account in AD).' }
    if ("$desc$disp" -match '[\r\n]') { $o.errors += 'No line breaks in the description or the name.' }
    $np = Get-AdcNameParts $disp
    # First/last name: use what was typed, otherwise take them from the full name.
    $o.givenName = $(if ("$($r.givenName)".Trim()) { "$($r.givenName)".Trim() } else { $np.first }); $o.sn = $(if ("$($r.sn)".Trim()) { "$($r.sn)".Trim() } else { $np.last })
    # same description or name already in AD?
    # Warn (not block) when another user already has the same description or name, so the operator can avoid duplicates.
    if ($desc -or $disp) {
        $f = @(); if ($desc) { $f += "(description=$(ConvertTo-LdapValue $desc))" }; if ($disp) { $f += "(displayName=$(ConvertTo-LdapValue $disp))"; $f += "(cn=$(ConvertTo-LdapValue $disp))" }
        $ds = Get-AdcSearcher ("(&(objectCategory=person)(objectClass=user)(|" + ($f -join '') + "))") @('samaccountname', 'displayname', 'description', 'distinguishedname', 'useraccountcontrol') 25
        try { $o.matches = @($ds.FindAll() | ForEach-Object { @{ sam = "$($_.Properties['samaccountname'][0])"; name = "$($_.Properties['displayname'][0])"; desc = "$($_.Properties['description'][0])"; dn = "$($_.Properties['distinguishedname'][0])"; enabled = -not ([int]"$($_.Properties['useraccountcontrol'][0])" -band 2) } }) } finally { $ds.Dispose() }
        foreach ($m in $o.matches) {
            if ($desc -and $m.desc -ieq $desc) { $o.warnings += "Description already used by $($m.sam) ($($m.name))." }
            if ($disp -and $m.name -ieq $disp) { $o.warnings += "Name already used by $($m.sam)." }
        }
    }
    # UPN domain
    # UPN domain: use the chosen one (leading @ removed) or the first allowed one; it must be a real domain/suffix of this AD.
    $dom = "$($r.upnDomain)".Trim().TrimStart('@'); if (-not $dom) { $dom = @($suffixes)[0] }
    if ($suffixes -notcontains $dom) { $o.errors += "UPN domain '$dom' is not one of the domains of this AD ($($suffixes -join ', '))." }
    $o.upnDomain = $dom
    # username: typed, or the first free suggestion
    # Username: check every suggestion for being free. If the user typed none, use the first free suggestion.
    $cands = @(Get-AdcCandidates $disp)
    foreach ($c in $cands) { $o.suggestions += @{ sam = $c; free = -not @(Test-AdcTaken $c "$c@$dom" '').Count } }
    $sam = "$($r.sam)".Trim()
    if (-not $sam) { $fr = @($o.suggestions | Where-Object { $_.free })[0]; if ($fr) { $sam = $fr.sam } else { $o.errors += 'Every suggested username is taken - type a username yourself.' } }
    if ($sam) {
        # Username rules: 1-20 characters, letters/digits/dot/underscore/hyphen only, and no dot at the start or end.
        if ($sam -notmatch '^[A-Za-z0-9._-]{1,20}$') { $o.errors += 'The username may have only letters, digits, . _ - and at most 20 characters.' }
        elseif ($sam -match '^\.|\.$') { $o.errors += 'The username cannot start or end with a dot.' }
    }
    $o.sam = $sam; $o.upn = $(if ($sam) { "$sam@$dom" } else { '' })
    # Simple e-mail shape check: something@something.something without spaces or ; , < > characters.
    $mail = "$($r.mail)".Trim(); if ($mail -and $mail -notmatch '^[^@\s;,<>"]+@[^@\s;,<>"]+\.[^@\s;,<>"]+$') { $o.errors += "Not a valid email address: $mail" }
    $o.mail = $mail; $o.mailSuggest = $o.upn
    # Refuse the row if the username, UPN or e-mail already exists - this tool never changes an existing account.
    if ($sam) { foreach ($t in @(Test-AdcTaken $sam $o.upn $mail)) { $o.errors += "Already in AD: $($t.sam) $(if ($t.upn) { "($($t.upn))" }) - the tool never changes an existing account." } }
    # OU: must exist (never created)
    $ou = "$($r.ou)".Trim()
    if (-not $ou) { $o.errors += 'Choose the OU.' }
    # Find the OU by its DN, or by its readable path. Unknown OU = error (OUs are never created).
    else { $hit = $ouSet[$ou.ToLower()]; if (-not $hit) { $hit = @($ouSet.Values | Where-Object { $_.path -ieq $ou })[0] }; if ($hit) { $o.ou = $hit.dn; $o.ouPath = $hit.path } else { $o.errors += "OU not found: $ou - choose an existing OU (new OUs are never created)." } }
    # Optional text fields, max 128 characters each.
    foreach ($k in 'title', 'department', 'company') { $v = "$($r.$k)".Trim(); if ($v.Length -gt 128) { $o.errors += "$k is too long." }; $o[$k] = $v }
    # expiry
    # Optional account expiry date in yyyy-mm-dd format; a date in the past is refused.
    $exp = "$($r.expires)".Trim(); $o.expires = ''
    if ($exp) { try { $dt = [datetime]::ParseExact($exp, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); if ($dt.Date -lt (Get-Date).Date) { $o.errors += 'The expiry date is in the past.' } else { $o.expires = $dt.ToString('yyyy-MM-dd') } } catch { $o.errors += 'The account expiry date must be yyyy-mm-dd.' } }
    # groups: must exist
    # Every group name must exist in AD; the group name and DN are stored for the create step.
    $o.groups = @(); $o.groupDns = @()
    foreach ($g in @(Get-GroupList ((@($r.groups) | ForEach-Object { "$_" }) -join "`n"))) {
        try { $ge = Resolve-AdGroup $g } catch { $o.errors += "$($_.Exception.Message)"; continue }
        if ($ge) { $o.groups += "$($ge.Properties['cn'][0])"; $o.groupDns += "$($ge.Properties['distinguishedname'][0])" } else { $o.errors += "Group not found: $g" }
    }
    $o.description = $desc; $o.displayName = $disp
    $o.ok = -not $o.errors.Count
    $o
}
# Returns the OU list as a hashtable keyed by lower-case DN, for fast look-ups in Test-AdcRow.
function Get-AdcOuSet { $h = @{}; foreach ($x in (Get-AdcOus)) { $h[$x.dn.ToLower()] = $x }; $h }

# POST /api/adc-meta - no input. Sends the allowed UPN suffixes and the OU list for the form drop-downs.
$ScreenHandlers['/api/adc-meta'] = {
    Test-AdcReady
    Send $ctx @{ ok = $true; suffixes = @(Get-AdcSuffixes); ous = @(Get-AdcOus) }
}
# POST /api/adc-check - input: one user row in $d. Sends back the checked row (errors, warnings, suggestions). Changes nothing.
$ScreenHandlers['/api/adc-check'] = {
    # live checks while typing: description / name in use, suggestions
    Test-AdcReady
    $sfx = @(Get-AdcSuffixes)
    $o = Test-AdcRow $d $sfx (Get-AdcOuSet)
    Send $ctx @{ ok = $true; row = $o }
}
# POST /api/adc-validate - input: $d.rows (1 to 500 rows). Sends back every checked row. Changes nothing.
$ScreenHandlers['/api/adc-validate'] = {
    Test-AdcReady
    # Safety limit of 500 rows per request.
    $rows = @($d.rows); if (-not $rows.Count) { throw 'No users to check.' }; if ($rows.Count -gt 500) { throw 'Up to 500 users at a time.' }
    $sfx = @(Get-AdcSuffixes); $set = Get-AdcOuSet
    $out = @(); $seen = @{}
    foreach ($r in $rows) {
        $o = Test-AdcRow $r $sfx $set
        # two rows of the file must not get the same username / UPN
        if ($o.sam) { $k = $o.sam.ToLower(); if ($seen.ContainsKey($k)) { $o.errors += "The username $($o.sam) is used twice in this list (row $($seen[$k]))."; $o.ok = $false } else { $seen[$k] = $out.Count + 1 } }
        $out += $o
    }
    Send $ctx @{ ok = $true; rows = $out }
}
# ---- v2.9.0: e-mail with the username and password to the new person ----
# Builds the 'New user account' e-mail (template 'newuser', edited in Settings > Email messages). $s = { name, given, sn, upn, sam, secret, pwOnce }, $cfg = mail settings.
# The password is shown in a box; {password}, {password_text}, {username} and {logo} work in own HTML too. The extra variable is cleared even after an error.
function New-NewUserMailHtml($s, $cfg) {
    $pw = [Net.WebUtility]::HtmlEncode("$($s.secret)")
    $script:EmailExtraVars = @{ password = '<span style="font-size:20px;font-family:Consolas,monospace;background:#f1f5f9;border:1px solid #cbd5e1;border-radius:8px;padding:10px 14px;display:inline-block;letter-spacing:1px;color:#0f172a">' + $pw + '</span>'; password_text = $pw }
    try { Format-EmailLayout 'newuser' (New-NewUserMailHtmlRaw $s $cfg) } finally { $script:EmailExtraVars = $null }
}
# The built-in design: greeting, intro, a box with username and password, the one-time / normal note, closing, security notice, signature; Arabic copy below.
function New-NewUserMailHtmlRaw($s, $cfg) {
    $h = { [Net.WebUtility]::HtmlEncode("$args") }
    $nm = Get-EmailNames 'newuser' $s.given $s.sn $s.name
    $v = @{ first = $nm.first; last = $nm.last; full = $nm.full; greet = $nm.greet; name = "$($s.name)"; username = "$($s.sam)"; upn = "$($s.upn)"; signature = "$(Get-EmailSigFirst $cfg.signature)" }
    # Links that can be used as {change_link} / {mfa_link} in the texts.
    $lnk = { param($u) "<a href=""$(& $h $u)"" style=""color:#2563eb;font-weight:600"" dir=""ltr"">$(& $h ($u -replace '^https://', ''))</a>" }
    $raw = @{ change_link = (& $lnk "$($cfg.changeUrl)"); mfa_link = (& $lnk "$($cfg.mfaUrl)") }
    $T = { param($k, $l) Get-EmailPart 'newuser' $k $l $v $raw }
    $box = 'font-size:18px;font-family:Consolas,monospace;background:#f1f5f9;border:1px solid #cbd5e1;border-radius:8px;padding:8px 14px;display:inline-block;letter-spacing:1px;color:#0f172a'
    $pYel = 'background:#fef3c7;border:1px solid #fcd34d;border-radius:8px;padding:10px 14px'
    $pFoot = 'color:#64748b;font-size:12px'
    $nk = if ($s.pwOnce) { 'once' } else { 'normal' }
    $pwH = [Net.WebUtility]::HtmlEncode("$($s.secret)"); $umH = & $h $s.sam
    # Table with the two boxes. $pad = which side the label spacing goes (right-to-left text swaps it).
    $tbl = { param($l, $pad) '<table role="presentation" style="margin:12px 0;border-collapse:collapse"><tr><td style="padding:6px ' + $(if ($pad -eq 'r') { '0 6px 14px' } else { '14px 6px 0' }) + ';color:#475569">' + (& $T 'userLabel' $l) + '</td><td><span style="' + $box + '">' + $umH + '</span></td></tr><tr><td style="padding:6px ' + $(if ($pad -eq 'r') { '0 6px 14px' } else { '14px 6px 0' }) + ';color:#475569">' + (& $T 'pwLabel' $l) + '</td><td><span style="' + $box + '">' + $pwH + '</span></td></tr></table>' }
    $html = '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937;line-height:1.55">' +
        "<p>$(& $T 'hello' 'en')</p><p>$(& $T 'intro' 'en')</p>" + (& $tbl 'en' 'l') +
        "<p style=""$pYel"">$(& $T $nk 'en')</p><p>$(& $T 'closing' 'en')</p><p style=""$pFoot"">$(& $T 'footer' 'en')</p>" + (Get-EmailSigHtml $cfg.signature)
    if ((Get-EmailText 'newuser' 'intro' 'ar').Trim()) {
        $html += '<div dir="rtl" lang="ar" style="font-family:Segoe UI,Tahoma,Arial,sans-serif;font-size:15px;color:#1f2937;line-height:1.7;text-align:right;border-top:2px solid #e5e7eb;margin-top:22px;padding-top:14px">' +
            "<p>$(& $T 'hello' 'ar')</p><p>$(& $T 'intro' 'ar')</p>" + (& $tbl 'ar' 'r') +
            "<p style=""$pYel"">$(& $T $nk 'ar')</p><p>$(& $T 'closing' 'ar')</p><p style=""$pFoot"">$(& $T 'footer' 'ar')</p>" + (Get-EmailSigHtml $cfg.signature -Rtl) + '</div>'
    }
    $html + '</div>'
}
# Sends the 'New user account' e-mail for one created user. Returns a short sentence for the result row. Never throws (a mail problem must not hide that the account was created).
# The password is never written to a log; the mail log gets only the result.
function Send-NewUserMail($o, $pw, $to, $pwOnce) {
    try {
        if (-not $script:Who) { return 'E-mail NOT sent: sign in to Microsoft 365 first (Settings > Connections).' }
        if (-not $to) { return 'E-mail NOT sent: no e-mail address for this person.' }
        $c = Get-MailCfg
        $s = @{ name = $o.displayName; given = $o.givenName; sn = $o.sn; upn = $o.upn; sam = $o.sam; secret = $pw; pwOnce = $pwOnce }
        $body = @{ message = @{ subject = (Get-EmailSubject 'newuser'); body = @{ contentType = 'HTML'; content = (New-NewUserMailHtml $s $c) }; toRecipients = @(@{ emailAddress = @{ address = $to } }); importance = 'normal' }; saveToSentItems = [bool]$c.saveCopy }
        $att = @(Get-EmailAttach 'newuser'); if ($att.Count) { $body.message.attachments = $att }
        $snd = Send-ToolMail "$($c.sender)" $body
        Write-MailLog $o.upn $snd $to 'Sent (new user account e-mail)'
        "E-mail with the username and password sent to $to."
    } catch {
        $m = Get-MailErr $_.Exception.Message
        try { Write-MailLog $o.upn "$((Get-MailCfg).sender)" $to "Failed (new user account e-mail): $m" } catch {}
        "E-mail NOT sent: $m"
    }
}
# POST /api/adc-create - THE ONLY endpoint that writes. Input: $d.rows, $d.confirm (must be exactly CREATE, case-sensitive), $d.pwMode ('custom' or random),
# $d.password (custom mode), $d.pwLength (random length, kept between 10 and 32), $d.mustChange (force change at next logon, default yes), $d.enable (default yes).
# Sends back one result row per user (Created / Created (partly) / Failed / Not created) including the password, so the operator can hand it over.
$ScreenHandlers['/api/adc-create'] = {
    Test-AdcReady
    if ("$($d.confirm)" -cne 'CREATE') { throw 'Type CREATE to confirm.' }
    $rows = @($d.rows); if (-not $rows.Count) { throw 'No users to create.' }; if ($rows.Count -gt 500) { throw 'Up to 500 users at a time.' }
    $pwMode = "$($d.pwMode)"; $pwLen = [Math]::Max(10, [Math]::Min(32, [int]$(if ($d.pwLength) { $d.pwLength } else { 14 })))
    if ($pwMode -eq 'custom' -and -not (Test-AdPwRule "$($d.password)")) { throw 'The password must be at least 8 characters and cannot start or end with a special character.' }
    $mustChange = $true; if ($null -ne $d.mustChange) { $mustChange = [bool]$d.mustChange }
    $enable = $true; if ($null -ne $d.enable) { $enable = [bool]$d.enable }
    # v2.9.0: optional e-mail with the username and password. $d.sendMail = send it; $d.sendTo = one address for everybody (empty = each person's own E-mail address).
    $sendMail = [bool]$d.sendMail; $sendTo = "$($d.sendTo)".Trim()
    if ($sendMail -and $sendTo -and -not (Test-MailAddr $sendTo)) { throw 'The address to send the username and password to is not a valid e-mail address.' }
    $sfx = @(Get-AdcSuffixes); $set = Get-AdcOuSet
    # Monthly audit file; the header line is written once when the file is new.
    $res = @(); $f = Join-Path $LogDir ('ad-create-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,PortalUser,Username,UPN,DisplayName,OU,Groups,Result,Message' | Out-File $f -Encoding utf8 }
    foreach ($r in $rows) {
        $o = Test-AdcRow $r $sfx $set   # checked again right before creating - nothing is created when anything is wrong
        $x = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); sam = $o.sam; upn = $o.upn; name = $o.displayName; ou = $o.ouPath; result = ''; message = ''; password = ''; groups = '' }
        if (-not $o.ok) { $x.result = 'Not created'; $x.message = ($o.errors -join ' ') }
        else {
            $pw = $(if ($pwMode -eq 'custom') { "$($d.password)" } else { New-AdPassword $pwLen })
            $ue = $null; $created = $false
            try {
                $ouE = New-AdEntry $o.ou
                if ("$($ouE.SchemaClassName)" -ne 'organizationalUnit') { throw 'The target is not an OU.' }
                # Creates the new user object inside the chosen OU (not saved to AD until CommitChanges). First check the target really is an OU.
                $ue = $ouE.Children.Add("CN=$(ConvertTo-AdcCn $o.displayName)", 'user')
                $ue.Properties['sAMAccountName'].Value = $o.sam
                $ue.Properties['userPrincipalName'].Value = $o.upn
                $ue.Properties['displayName'].Value = $o.displayName
                $ue.Properties['description'].Value = $o.description
                if ($o.givenName) { $ue.Properties['givenName'].Value = $o.givenName }
                if ($o.sn) { $ue.Properties['sn'].Value = $o.sn }
                foreach ($k in 'title', 'department', 'company') { if ($o[$k]) { $ue.Properties[$k].Value = $o[$k] } }
                if ($o.mail) { $ue.Properties['mail'].Value = $o.mail }
                # First save creates the account (AD makes it disabled). The password and the enabled state can only be set after this.
                $ue.CommitChanges(); $created = $true
                # Set the password, then userAccountControl: 512 = normal enabled account, 514 = disabled account.
                # pwdLastSet = 0 forces a password change at the next logon. accountExpires is a FILETIME; +1 day so the account is valid through the chosen date.
                $ue.Invoke('SetPassword', $pw)
                $ue.Properties['userAccountControl'].Value = $(if ($enable) { 512 } else { 514 })
                if ($mustChange) { $ue.Properties['pwdLastSet'].Value = 0 }
                if ($o.expires) { $ue.Properties['accountExpires'].Value = "$(([datetime]$o.expires).AddDays(1).ToFileTime())" }
                $ue.CommitChanges()
                $x.result = 'Created'; $x.password = $pw
                $msgs = @("Created in $($o.ouPath)$(if (-not $enable) { ' (disabled)' }).")
                # Add the new user to each chosen group. A failing group does not undo the user; it is reported as 'Created (partly)'.
                $udn = "$($ue.Properties['distinguishedName'].Value)"
                $okG = @()
                for ($gi = 0; $gi -lt $o.groupDns.Count; $gi++) {
                    try { $ge = New-AdEntry $o.groupDns[$gi]; $ge.Invoke('Add', "$(Get-LdapPrefix)$udn"); $okG += $o.groups[$gi] } catch { $msgs += "Not added to $($o.groups[$gi]): $(Get-ErrMsg $_)"; $x.result = 'Created (partly)' }
                }
                $x.groups = ($okG -join '; ')
                $x.message = ($msgs -join ' ')
                # v2.9.0: e-mail the username and password (the password goes only into the e-mail, never into a log).
                if ($sendMail) { $x.message = ($x.message + ' ' + (Send-NewUserMail $o $pw $(if ($sendTo) { $sendTo } else { "$($o.mail)" }) $mustChange)).Trim() }
            } catch {
                # If the account was already saved but a later step failed, it stays disabled with no finished setup - tell the operator. Otherwise translate common AD errors.
                $em = Get-ErrMsg $_
                if ($created) { $x.result = 'Created (partly)'; $x.message = "The account was created but not finished: $em - it stays DISABLED. Finish it on the On-premises AD screen (set a password, enable)."; $x.password = '' }
                else { $x.result = 'Failed'; $x.message = $(if ($em -match 'already exists|0x80071392') { "An object named '$($o.displayName)' already exists in this OU - use a different full name." } elseif ($em -match 'password|0x800708C5') { "$em (the password does not meet the domain password policy)" } else { $em }) }
            }
        }
        # Write the audit CSV line (each value quoted safely) and the portal activity log row. The activity log must never break the request.
        (@($x.time, $script:SessUser.name, $x.sam, $x.upn, $x.name, $x.ou, $x.groups, $x.result, $x.message) | ForEach-Object { ConvertTo-CsvCell $_ }) -join ',' | Add-Content $f
        try { Write-ActRow 'Create AD users' 'Create user' "$($x.sam)" "$($x.result)" "$($x.message)" } catch {}
        $res += $x
    }
    # Tells the log copier that there are new log lines to copy to SharePoint (the audit CSV above changed).
    $script:SpDirty = $true
    Send $ctx @{ ok = $true; rows = $res; mustChange = $mustChange }
}

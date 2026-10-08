# Screen-Users.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Users & roles (Settings)
# Screen version: 2.10.0   (changes ONLY when this screen changes - not with every release)

# permissions you tick. The built-in owner login (Change-Login.bat) is never listed here and can never be locked out.
# Only salted PBKDF2 hashes are kept, in tool-users.json next to the tool. Every rule is enforced HERE, on the server - hiding
# a button in the page is only a convenience.
# v2.0.0: many people can be signed in at the same time, each with their own Microsoft and AD sign-in.

# Screen: Users & roles (Settings). Endpoints: /api/users-list, /api/users-save, /api/users-delete, /api/users-adcheck, /api/me-password,
# /api/adlogin-get, /api/adlogin-save, /api/me-prefs, /api/home-info. Data files in the tool folder: tool-users.json (encrypted),
# login-lock.json, ad-login.json, ui-prefs.json. Calls Active Directory (LDAP / DirectoryServices); no Microsoft Graph calls here.
# This file is also the permission gate for the whole tool: Get-ApiNeed / Get-ApiDenied decide who may call each /api/ path.
# Managing users needs the 'users' permission (administrators); /api/me-password and /api/me-prefs / /api/home-info are open to any signed-in person.
#
# tool-users.json = list of portal accounts (username, PBKDF2 password hash, role, permissions, expiry, AD / Microsoft links).
$script:UsersFile = Join-Path $Root 'tool-users.json'
# All permissions you can tick for a user: key (used in code), label and hint (shown on the screen). Adding a line here adds a tick box.
$script:PermDefs = @(
    [ordered]@{ key = 'reset';    label = 'Reset passwords';             hint = 'Cloud password reset and on-premises AD password reset (nothing else on the AD screen).' }
    [ordered]@{ key = 'email';    label = 'Send the password e-mail';    hint = 'E-mail the new password to the user from the sender mailbox.' }
    [ordered]@{ key = 'accounts'; label = 'Enable / disable / unlock';   hint = 'Enable or disable cloud accounts, unlock or enable/disable AD accounts.' }
    [ordered]@{ key = 'mfa';      label = 'MFA methods';                 hint = 'View and revoke sign-in methods, temporary access pass.' }
    [ordered]@{ key = 'onprem';   label = 'On-premises AD changes';      hint = 'Names, UPN, groups, expiry, enable account - everything beyond a password reset.' }
    [ordered]@{ key = 'bulk';     label = 'Bulk CSV and reports';        hint = 'Bulk apply from a file and AD reports.' }
    [ordered]@{ key = 'teams';    label = 'Teams members';               hint = 'Add people to Microsoft Teams.' }
    [ordered]@{ key = 'dg';       label = 'Distribution groups';         hint = 'Distribution group tools.' }
    [ordered]@{ key = 'mbx';      label = 'Shared mailboxes';            hint = 'Shared mailbox access changes and notifications.' }
    [ordered]@{ key = 'guests';   label = 'Guest invitations';           hint = 'Invite outside guests.' }
    [ordered]@{ key = 'audit';    label = 'Audit and sign-in reports';   hint = 'Cloud and AD audit logs.' }
    [ordered]@{ key = 'intune';   label = 'Devices (Intune)';            hint = 'See the Intune devices, how they are joined (Hybrid / Entra) and their compliance, and export them. Read only.' }
    [ordered]@{ key = 'intunedel'; label = 'Remove devices (Intune)';    hint = 'Delete or retire Intune devices (one, many, or all devices of a domain) and their Microsoft Entra device. Give this to very few people.' }
    [ordered]@{ key = 'licenses'; label = 'Licenses (view)';             hint = 'See the Microsoft 365 licenses: bought, used, left, and who got them directly or from a group. Read only.' }
    [ordered]@{ key = 'licassign'; label = 'Assign / remove licenses';   hint = 'Assign or remove licenses in bulk, and add / remove people to licensing groups.' }
    [ordered]@{ key = 'adcreate'; label = 'Create AD users';             hint = 'Create new on-premises AD users (one or from a CSV) in an existing OU. Creation only - nothing is deleted, moved or changed.' }
    [ordered]@{ key = 'onedrive'; label = 'OneDrive and storage';        hint = 'Tenant storage report (OneDrive, SharePoint, mailboxes) and look up OneDrives. Read only.' }
    [ordered]@{ key = 'oddelete'; label = 'Delete OneDrive';             hint = 'Move OneDrives to the recycle bin or delete them permanently. Give this to very few people.' }
    [ordered]@{ key = 'mbxdelete'; label = 'Delete mailbox data';        hint = 'Delete the mail in user mailboxes (all, chosen folders, or older than a date). Give this to very few people.' }
    [ordered]@{ key = 'logs';     label = 'See all logs';                hint = 'Everyone''s activity and every sign-in with IP address and PC. Without this, a person sees only their own actions.' }
    [ordered]@{ key = 'settings'; label = 'Change tool settings';        hint = 'E-mail wording, defaults, mail sender, log settings.' }
    [ordered]@{ key = 'server';   label = 'Restart / shut down the server'; hint = 'Restart or shut down the whole tool from the Session menu. Everyone who is using it is signed out. Leave it off for normal users.' }
    [ordered]@{ key = 'users';    label = 'Manage tool users';           hint = 'Create and edit these accounts. Give this to administrators only.' }
)
# Just the list of permission keys.
$script:PermKeys = @($script:PermDefs | ForEach-Object { $_.key })
# Ready-made roles and the permissions each one gives. Administrator gets every permission; Custom starts empty (you tick).
$script:RoleDefs = [ordered]@{
    admin    = @{ label = 'Administrator'; perms = $script:PermKeys }
    helpdesk = @{ label = 'Helpdesk';      perms = @('reset', 'email', 'accounts') }
    readonly = @{ label = 'View only';     perms = @('audit') }
    logviewer = @{ label = 'Log viewer';   perms = @('logs') }
    custom   = @{ label = 'Custom';        perms = @() }
}
# Who is signed in for the current request (set by Set-SessUser). $null = nobody.
$script:SessUser = $null

# Reads all tool users from tool-users.json (decrypts it). Returns an array; empty if the file is missing or broken.
function Read-ToolUsers {
    $o = @()
    try { if (Test-Path $script:UsersFile) { $o = @((Read-SecureText $script:UsersFile) | ConvertFrom-Json) } } catch { $o = @() }
    @($o | Where-Object { $_ -and $_.username })
}
# Finds one tool user by username (case-insensitive). Returns the record or $null.
function Get-ToolUserRec($name) { foreach ($u in (Read-ToolUsers)) { if ("$($u.username)" -ieq "$name") { return $u } }; $null }
# Saves the full user list (encrypted). An empty list is written as [] because ConvertTo-Json would otherwise write nothing useful.
function Save-ToolUsers($list) {
    $json = if (@($list).Count) { ConvertTo-Json -InputObject @($list) -Depth 5 } else { '[]' }
    Write-SecureText $script:UsersFile $json   # v2.4.0: encrypted (DPAPI, this server only)
}
# Makes a password hash: random 16-byte salt + PBKDF2 with 100000 rounds. Returns salt, hash and rounds (it). The password itself is never stored.
function New-UserHash($pass) {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $s = New-Object byte[] 16; $rng.GetBytes($s)
    @{ salt = [Convert]::ToBase64String($s); hash = [Convert]::ToBase64String((Get-PwHash $pass $s 100000)); it = 100000 }
}
# Checks a typed password against a user record. Constant-time compare (Test-Bytes). Returns $false on any error.
function Test-UserHash($u, $pass) {
    try { Test-Bytes (Get-PwHash $pass ([Convert]::FromBase64String("$($u.salt)")) ([int]$u.it)) ([Convert]::FromBase64String("$($u.hash)")) } catch { $false }
}
# Is this name the built-in owner's username? (The owner login is stored hashed in $script:Auth, not in tool-users.json.)
# Used so nobody can create a tool user with the owner's name.
function Test-OwnerName($name) {
    $a = $script:Auth; if (-not $a) { return $false }
    try { Test-Bytes (Get-PwHash $name ([Convert]::FromBase64String($a.us)) ([int]$a.it)) ([Convert]::FromBase64String($a.uh)) } catch { $false }
}
# Permissions of a user record: administrators always get all; others get only their ticked keys that still exist.
function Get-UserPerms($u) {
    if ("$($u.role)" -eq 'admin') { return @($script:PermKeys) }
    @(@($u.perms) | ForEach-Object { "$_" } | Where-Object { $_ -in $script:PermKeys })
}
# Returns the tool user for a correct username + password (enabled accounts only), or $null
# Portal sign-in check. Returns the user record for a correct username + password, $null for a wrong one, or @{ denied = 'reason' } when the
# password is right but the account may not sign in (SSO only, expired, AD account expired/disabled).
function Test-ToolUserLogin($name, $pass) {
    $hit = $null
    foreach ($u in (Read-ToolUsers)) { if ("$($u.username)" -ieq "$name") { $hit = $u; break } }
    # Unknown name: still do a password hash so the answer takes the same time (stops guessing which usernames exist).
    if (-not $hit) { [void](Get-PwHash "$pass" (New-Object byte[] 16) 100000); return $null }   # same time whether or not the name exists
    if (-not (Test-UserHash $hit $pass)) { return $null }
    if ($hit.enabled -eq $false) { return $null }
    if ($hit.ssoOnly -eq $true) { return @{ denied = 'This portal account signs in with Microsoft single sign-on only - use the Sign in with Microsoft button.'; username = "$($hit.username)" } }   # v2.5.2
    $why = Get-ToolUserBlock $hit -Login; if ($why) { return @{ denied = $why; username = "$($hit.username)" } }   # v1.98.9: expired here or in AD
    $hit
}

# v1.98.9: a tool login can have an expiry date, and can be linked to an AD account. The person cannot sign in to the portal when
# EITHER the date here has passed OR the linked AD account is expired (or disabled). The built-in owner login is never blocked.
# True if the account's expiry date (yyyy-MM-dd) is over. A broken date counts as expired (safer). The account works until the end of that day.
function Test-ToolUserExpired($u) {
    $e = "$($u.expires)".Trim(); if (-not $e) { return $false }
    $dt = [datetime]::MinValue; if (-not [datetime]::TryParseExact($e, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) { return $true }   # a broken date counts as expired
    (Get-Now) -ge $dt.AddDays(1)   # works until the end of that day
}
# Looks the AD account up (LDAP, by sAMAccountName) and returns 'ok', 'disabled', 'expired <date>', 'notfound' or 'error: ...'.
# useraccountcontrol bit 2 = disabled. accountexpires is a Windows file time; 0 or the maximum value means 'never expires'.
function Get-AdLoginState($sam) {
    # 'ok' / 'expired <date>' / 'disabled' / 'notfound' / 'error: ...'. Uses the AD sign-in of the tool if there is one, otherwise this PC's own Windows account.
    try {
        Add-Type -AssemblyName System.DirectoryServices
        $root = if ($script:AdCred) { New-AdEntry } else { Get-AdDefaultRoot }   # v2.8.1: chosen DC
        $ds = New-Object DirectoryServices.DirectorySearcher($root); $ds.SizeLimit = 1
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $sam)))"
        foreach ($p in 'accountexpires', 'useraccountcontrol') { [void]$ds.PropertiesToLoad.Add($p) }
        $r = $ds.FindOne(); if (-not $r) { return 'notfound' }
        $uac = if ($r.Properties['useraccountcontrol'].Count) { [int]$r.Properties['useraccountcontrol'][0] } else { 0 }
        if ($uac -band 2) { return 'disabled' }
        $ae = if ($r.Properties['accountexpires'].Count) { [int64]$r.Properties['accountexpires'][0] } else { 0 }
        if ($ae -gt 0 -and $ae -lt 9223372036854775807) { $when = [datetime]::FromFileTimeUtc($ae); if ([datetime]::UtcNow -ge $when) { return ('expired ' + $when.ToLocalTime().ToString('yyyy-MM-dd')) } }
        'ok'
    } catch { 'error: ' + $_.Exception.Message }
}
# Reason a person may not use the portal (own expiry date, or linked AD account expired / disabled / missing), or $null if allowed.
# The AD answer is cached for 10 minutes ($script:AdLoginCache); at sign-in (-Login) it is always checked fresh. If AD cannot be checked, access is refused.
function Get-ToolUserBlock($u, [switch]$Login) {
    # the reason this person may not use the portal, or $null
    if (Test-ToolUserExpired $u) { return "This account expired on $($u.expires). Ask an administrator to extend it." }
    $sam = "$($u.adSam)".Trim(); if (-not $sam) { return $null }
    $k = $sam.ToLower(); if (-not $script:AdLoginCache) { $script:AdLoginCache = @{} }
    $c = $script:AdLoginCache[$k]
    if ($Login -or -not $c -or ((Get-Date) - $c.at).TotalMinutes -ge 10) { $c = @{ at = Get-Date; st = (Get-AdLoginState $sam) }; $script:AdLoginCache[$k] = $c }
    switch -Regex ($c.st) {
        '^ok$' { return $null }
        '^expired (.*)$' { return "Your AD account ($sam) expired on $($Matches[1]), so you cannot sign in to the portal." }
        '^disabled$' { return "Your AD account ($sam) is disabled, so you cannot sign in to the portal." }
        '^notfound$' { return "The AD account linked to this login ($sam) was not found, so you cannot sign in. Ask an administrator." }
        default { return "The portal could not check your AD account ($sam) - sign-in is not allowed until it can. Ask an administrator. ($($c.st -replace '^error: ',''))" }
    }
}

# Stores the time of the last successful sign-in in the user's record (shown in the Users list). Errors are ignored.
function Set-UserLastLogin($name) {
    try { $all = @(Read-ToolUsers); foreach ($u in $all) { if ("$($u.username)" -ieq $name) { $u | Add-Member -NotePropertyName lastLogin -NotePropertyValue ('{0:yyyy-MM-dd HH:mm}' -f (Get-Now)) -Force } }; Save-ToolUsers $all } catch {}
}
# Sets the current session user: 'owner' = the built-in owner (all permissions), otherwise a tool-user record (name, role, permissions, mustChange).
function Set-SessUser($u) {
    if ($u -eq 'owner') { $script:SessUser = @{ name = 'Owner'; owner = $true; role = 'admin'; perms = @($script:PermKeys) } }
    else { $script:SessUser = @{ name = "$($u.username)"; owner = $false; role = "$($u.role)"; perms = @(Get-UserPerms $u); mustChange = ($u.mustChange -eq $true) } }
}

# Pages and calls that need no permission (signing in, looking things up, the activity view, own password)
# API paths that need NO permission (sign-in, status, own password, logs overview, searches). Everything else is checked in Get-ApiNeed.
$script:ApiOpen = @('/api/sso-ms-offer', '/api/sso-ms-choice', '/api/sso-ms-mine', '/api/status', '/api/connect', '/api/ms-login-start', '/api/ad-connect', '/api/ad-disconnect', '/api/known-accounts', '/api/tab-closed',
    '/api/logout', '/api/signout', '/api/signout-all', '/api/autologout', '/api/ad-autologout', '/api/session-timeout', '/api/log-event', '/api/export-save',
    '/api/logs-config', '/api/logs-recent', '/api/logs-search', '/api/me-prefs', '/api/home-info', '/api/logs-status', '/api/logs-open', '/api/logs-sync', '/api/email-tpl-list', '/api/email-tpl-preview',
    '/api/search', '/api/usersearch', '/api/groupsearch', '/api/onprem-search', '/api/onprem-suffixes', '/api/me-password')
# API path -> the permission key it needs. Paths not listed here are handled by the patterns in Get-ApiNeed below.
$script:ApiNeed = @{
    '/api/reset' = 'reset'; '/api/reset-mail' = 'email'; '/api/reset-mail-preview' = 'email'; '/api/reset-mail-info' = 'email'
    '/api/enable' = 'accounts'; '/api/disable' = 'accounts'; '/api/onprem-account' = 'accounts'
    '/api/mfa-list' = 'mfa'; '/api/mfa-list-many' = 'mfa'; '/api/mfa-mail' = 'mfa'; '/api/mfa-revoke' = 'mfa'; '/api/mfa-log' = 'mfa'
    '/api/onprem-report' = 'bulk'; '/api/ourep-ous' = 'bulk'; '/api/ourep-run' = 'bulk'; '/api/guest-invite' = 'guests'
    '/api/email-tpl-save' = 'settings'; '/api/email-custom-save' = 'settings'; '/api/email-tpl-reset' = 'settings'; '/api/email-img-save' = 'settings'; '/api/email-img-remove' = 'settings'
    '/api/logs-config-save' = 'settings'; '/api/logs-settings' = 'settings'; '/api/logs-autocopy' = 'settings'; '/api/shutdown' = 'server'; '/api/restart' = 'server'
    '/api/users-list' = 'users'; '/api/users-save' = 'users'; '/api/users-delete' = 'users'; '/api/users-adcheck' = 'users'; '/api/adlogin-get' = 'users'; '/api/adlogin-save' = 'users'; '/api/logs-logins' = 'logs'
}
# Returns the permission needed for an API path: '' = any signed-in person, 'admin' = administrators only, or a key from PermDefs.
# Inputs: $path (URL path), $d (request data, only used where the same path is read-only or changes things). Unknown paths default to 'admin'.
function Get-ApiNeed($path, $d) {
    if ($path -in $script:ApiOpen) { return '' }
    if ($script:ApiNeed.ContainsKey($path)) { return $script:ApiNeed[$path] }
    if ($path -like '/api/bulk-*') { return 'bulk' }
    if ($path -like '/api/teams-*') { return 'teams' }
    if ($path -like '/api/dg-*') { return 'dg' }
    if ($path -like '/api/mbx-*') { return 'mbx' }
    if ($path -like '/api/audit-*') { return 'audit' }
    if ($path -like '/api/sess-*') { return 'admin' }
    if ($path -in '/api/gjob', '/api/gjob-cancel') { return '' }   # v2.1.0: a background job - only the session that started it can read it
    if ($path -eq '/api/intune-run') { return 'intune' }
    if ($path -eq '/api/intune-action') { return 'intunedel' }
    if ($path -in '/api/lic-read', '/api/lic-groups') { return 'licenses' }   # v2.5.0
    if ($path -eq '/api/lic-change') { return 'licassign' }
    if ($path -like '/api/adc-*') { return 'adcreate' }
    if ($path -in '/api/od-usage', '/api/od-lookup', '/api/spo-status', '/api/spo-code-start', '/api/spo-code-poll', '/api/spo-forget') { return 'onedrive' }
    if ($path -in '/api/od-delete', '/api/od-restore') { return 'oddelete' }
    if ($path -like '/api/mp-*') { return 'mbxdelete' }   # v2.2.0: Mailbox cleanup
    if ($path -like '/api/msapp-*') { return 'admin' }
    if ($path -like '/api/sec-*') { return 'admin' }   # v2.4.0: Access and security
    if ($path -like '/api/update-*') { return 'admin' }   # v2.4.0: Settings > Updates - administrators only
    if ($path -like '/api/appsetup-*') { return 'admin' }   # v2.4.0: create the Microsoft app   # v2.4.0: Microsoft app registration - administrators only
    if ($path -in '/api/ms-device-start', '/api/ms-device-poll') { return '' }   # Who is signed in - administrators only
    if ($path -like '/api/people-*') { return 'admin' }
    if ($path -like '/api/ssl-*') { return 'admin' }
    if ($path -like '/api/sso-*') { return 'admin' }   # single sign-on settings - administrators only   # HTTPS / SSL certificate - administrators only
    if ($path -eq '/api/gal-check') { return '' }   # read only
    if ($path -eq '/api/gal-ad') { return 'onprem' }
    if ($path -eq '/api/gal-cloud') { return 'mbx' }   # v1.98.27: People database - administrators only
    if ($path -eq '/api/mail-test') { return 'settings' }
    if ($path -like '/api/mailacct-*') { return 'settings' }
    if ($path -eq '/api/suggest') { return '' }   # suggestions while typing: read only, any signed-in tool user
    if ($path -eq '/api/onprem-userinfo') { return 'onprem' }
    if ($path -eq '/api/ad-server') { if ($d -and ($d.save -or $d.test -or $d.discover)) { return 'settings' } else { return '' } }   # v2.8.1: which AD server the tool uses
    if ($path -in '/api/mail-settings', '/api/app-defaults') { if ($d -and $d.save) { return 'settings' } else { return '' } }
    # /api/onprem does several things: a request that ONLY resets passwords needs 'reset'; any other AD change needs 'onprem'.
    if ($path -eq '/api/onprem') {
        # a request that only resets passwords counts as "reset"; anything else on this screen is an AD change
        $grp = (@($d.addGroups).Count -gt 0 -and "$(@($d.addGroups)[0])") -or (@($d.removeGroups).Count -gt 0 -and "$(@($d.removeGroups)[0])")
        $mode = "$($d.expiryMode)"; $upn = "$($d.upnMode)"
        $nameOn = "$($d.nameFirst)$($d.nameLast)$($d.nameDisplay)$($d.nameFull)".Trim(); if ($null -ne $d.nameDesc -or $null -ne $d.nameMail) { $nameOn = $true }
        $pw = "$($d.pwMode)"
        if (-not $grp -and ($mode -eq '' -or $mode -eq 'none') -and -not $d.enableAccount -and -not $d.clearPwNever -and -not $nameOn -and ($upn -eq '' -or $upn -eq 'none') -and $pw -ne '' -and $pw -ne 'none') { return 'reset' }
        return 'onprem'
    }
    # Safe default: a path nobody listed is for administrators only.
    return 'admin'   # anything not listed above: administrators only
}
# $null = allowed, otherwise the message to show
# Called by server.ps1 for each /api/ request. Returns $null if the current user may call $path, or the message to show.
# The owner may do everything. A user who must change the password first can only use status, me-password and logout.
function Get-ApiDenied($path, $d) {
    $u = $script:SessUser
    if (-not $u) { return 'Your sign-in is not recognised. Sign in again.' }
    if ($u.owner) { return $null }
    if ($u.mustChange -and $path -notin '/api/status', '/api/me-password', '/api/logout') { return 'Change your password first (a window is open in the page).' }
    $need = Get-ApiNeed $path $d
    if ($need -eq '') { return $null }
    if ($need -eq 'admin') { if ("$($u.role)" -eq 'admin') { return $null } else { return 'This action is for administrators only.' } }
    if (@($u.perms) -contains $need) { return $null }
    $lbl = ($script:PermDefs | Where-Object { $_.key -eq $need } | Select-Object -First 1).label
    "You do not have permission for this ($lbl). Ask an administrator to allow it."
}
# May this user restart or shut down the server? Owner, administrators, or users with the 'server' permission.
function Test-CanServer { $u = $script:SessUser; [bool]($u -and ($u.owner -or "$($u.role)" -eq 'admin' -or @($u.perms) -contains 'server')) }
# Stores on a user record the Microsoft account (msUpn) and AD account (adUser) the person uses inside the portal, and whether they are locked.
# The AD password is stored encrypted with DPAPI (Protect-MailSecret). adClear removes it.
function Set-UserSignIns($u, $msUpn, $msLock, $adUser, $adPass, $adLock, $adClear) {
    foreach ($kv in @(@('msUpn', $msUpn), @('msLock', [bool]$msLock), @('adUser', $adUser), @('adLock', [bool]$adLock))) { $u | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force }
    if ($adClear -or -not $adUser) { $u | Add-Member -NotePropertyName adPassEnc -NotePropertyValue '' -Force }
    elseif ($adPass) { $u | Add-Member -NotePropertyName adPassEnc -NotePropertyValue (Protect-MailSecret $adPass) -Force }   # Windows DPAPI - only this server can read it
}
# Builds the safe version of a user record that is sent to the page (never includes the password hash or the AD password).
function Get-UserView($u) {
    [ordered]@{ username = "$($u.username)"; role = "$($u.role)"; perms = @(Get-UserPerms $u); enabled = ($u.enabled -ne $false); note = "$($u.note)"; expires = "$($u.expires)"; adSam = "$($u.adSam)"; expired = [bool](Test-ToolUserExpired $u)
                created = "$($u.created)"; createdBy = "$($u.createdBy)"; lastLogin = "$($u.lastLogin)"
                msUpn = "$($u.msUpn)"; msLock = ($u.msLock -ne $false); adUser = "$($u.adUser)"; adHasPass = [bool]"$($u.adPassEnc)"; adLock = ($u.adLock -ne $false); ssoUpn = "$($u.ssoUpn)"; ssoOnly = ($u.ssoOnly -eq $true) }
}

# Handler /api/users-list. No input. Sends { users, perms, roles, me } for the Users screen.
$ScreenHandlers['/api/users-list'] = {
    $roles = @(); foreach ($k in $script:RoleDefs.Keys) { $roles += [ordered]@{ key = $k; label = $script:RoleDefs[$k].label; perms = @($script:RoleDefs[$k].perms) } }
    Send $ctx @{ ok = $true; users = @(Read-ToolUsers | ForEach-Object { Get-UserView $_ }); perms = @($script:PermDefs); roles = $roles; me = "$($script:SessUser.name)" }
}
# Handler /api/users-save. Creates (isNew:true) or edits a user. Input $d: username, role, perms[], note, password, expires, adSam, msUpn, msLock,
# adUser, adPass, adLock, adClear, ssoUpn, ssoOnly, enabled, mustChange. Every field is checked here; errors are thrown as readable messages.
# Sends { ok, message, users }.
$ScreenHandlers['/api/users-save'] = {
    $name = "$($d.username)".Trim()
    # Username: 3-64 characters, only letters, numbers and . _ @ -
    if ($name -notmatch '^[A-Za-z0-9._@-]{3,64}$') { throw 'The username must be 3 to 64 characters: letters, numbers and . _ @ - only.' }
    if ((Test-OwnerName $name) -or $name -ieq 'owner') { throw 'That username is used by the built-in owner login. Choose another.' }
    $role = "$($d.role)"; if (-not $script:RoleDefs.Contains($role)) { throw 'Choose a role.' }
    $perms = @(@($d.perms) | ForEach-Object { "$_" } | Where-Object { $_ -in $script:PermKeys } | Select-Object -Unique)
    # Fixed roles (helpdesk, view only, log viewer) always get exactly their role's permissions; only Custom uses the ticked ones.
    if ($role -ne 'admin' -and $role -ne 'custom') { $perms = @($script:RoleDefs[$role].perms) }
    if ($role -eq 'custom' -and -not $perms.Count) { throw 'Tick at least one permission, or choose a role.' }
    $note = "$($d.note)".Trim(); if ($note.Length -gt 200) { throw 'The note is too long (200 characters).' }
    $pw = "$($d.password)"
    # Expiry date must look like 2026-12-31 (or be empty = never).
    $exp = "$($d.expires)".Trim(); if ($exp -and $exp -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'The expiry date must be a date (yyyy-mm-dd), or empty for never.' }
    # AD username: no spaces and none of the characters AD does not allow in sAMAccountName.
    $adSam = "$($d.adSam)".Trim(); if ($adSam -and $adSam -notmatch '^[^\s"/\\\[\]:;|=,+*?<>]{1,64}$') { throw 'The AD username (sAMAccountName) is not valid.' }
    # v2.0.0: the Microsoft and AD accounts this person signs in with inside the portal (optional, set by an administrator)
    # Simple e-mail shape check: something@something.something
    $msUpn = "$($d.msUpn)".Trim(); if ($msUpn -and $msUpn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'The Microsoft account must be an e-mail address (user@contoso.com).' }
    # DOMAIN\user or user@domain form; up to 104 characters.
    $adUser = "$($d.adUser)".Trim(); if ($adUser -and $adUser -notmatch '^[^\s"/\[\]:;|=,+*?<>]{1,104}$') { throw 'The AD account is not valid (DOMAIN\username or username@domain).' }
    $adPass = "$($d.adPass)"
    # v2.5.2: single sign-on link - the Microsoft account (e-mail) this portal user signs in with through SSO
    $ssoUpn = "$($d.ssoUpn)".Trim(); if ($ssoUpn -and $ssoUpn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'The single sign-on account must be an e-mail address (user@contoso.com).' }
    # 'SSO only' makes sense only when an SSO account is linked. One Microsoft account can be linked to just one portal user (checked next).
    $ssoOnly = [bool]($ssoUpn -and $d.ssoOnly)
    $all = @(Read-ToolUsers); $cur = $null
    if ($ssoUpn) { foreach ($u in $all) { if ("$($u.ssoUpn)" -ieq $ssoUpn -and "$($u.username)" -ine $name) { throw "$ssoUpn is already linked to the portal user $($u.username)." } } }
    foreach ($u in $all) { if ("$($u.username)" -ieq $name) { $cur = $u } }
    $enabled = if ($null -eq $d.enabled) { $true } else { [bool]$d.enabled }
    $me = "$($script:SessUser.name)"
    # Existing user: edit. Safety rules stop an administrator from locking themselves out (cannot lower, disable or expire their own account).
    if ($cur) {
        if ("$($cur.username)" -ieq $me -and ($role -ne 'admin' -or -not $enabled)) { throw 'You cannot lower or disable your own account. Ask another administrator.' }
        # (A new password was typed: store its new hash.)
        if ($pw) { if ($pw.Length -lt 8) { throw 'The password must be at least 8 characters.' }; $h = New-UserHash $pw; $cur.salt = $h.salt; $cur.hash = $h.hash; $cur.it = $h.it }
        if ("$($cur.username)" -ieq $me -and $exp -and [datetime]::ParseExact($exp, 'yyyy-MM-dd', $null) -lt (Get-Now).Date) { throw 'You cannot set a past expiry date on your own account.' }
        $cur.role = $role; $cur.perms = @($perms); $cur.enabled = $enabled; $cur.note = $note
        $cur | Add-Member -NotePropertyName expires -NotePropertyValue $exp -Force; $cur | Add-Member -NotePropertyName adSam -NotePropertyValue $adSam -Force
        $cur | Add-Member -NotePropertyName ssoUpn -NotePropertyValue $ssoUpn -Force; $cur | Add-Member -NotePropertyName ssoOnly -NotePropertyValue $ssoOnly -Force
        Set-UserSignIns $cur $msUpn ([bool]$d.msLock) $adUser $adPass ([bool]$d.adLock) ([bool]$d.adClear)
        # Forget cached AD checks, since the linked AD account may have changed.
        if ($script:AdLoginCache) { $script:AdLoginCache.Clear() }
        if ($pw) { $cur | Add-Member -NotePropertyName mustChange -NotePropertyValue ([bool]$d.mustChange) -Force }
        $msg = 'Saved'
    } else {
        # New user: only when the page says isNew, so a typo in an existing name cannot silently create an account.
        if ($d.isNew -ne $true) { throw 'That user does not exist.' }
        if ($ssoOnly -and -not $pw) { $pw = [guid]::NewGuid().ToString('N') + 'Aa1!' }   # SSO only: an unknown random password (the password sign-in is refused anyway)
        if ($pw.Length -lt 8) { throw 'Type a password of at least 8 characters (or link the user to single sign-on only).' }
        # Maximum of 50 tool users.
        if ($all.Count -ge 50) { throw 'Up to 50 users.' }
        $h = New-UserHash $pw
        $all += [pscustomobject]@{ username = $name; salt = $h.salt; hash = $h.hash; it = $h.it; role = $role; perms = @($perms); enabled = $enabled; note = $note
                                   created = ('{0:yyyy-MM-dd HH:mm}' -f (Get-Now)); createdBy = $me; lastLogin = ''; mustChange = [bool]$d.mustChange; expires = $exp; adSam = $adSam; ssoUpn = $ssoUpn; ssoOnly = $ssoOnly }
        Set-UserSignIns $all[-1] $msUpn ([bool]$d.msLock) $adUser $adPass ([bool]$d.adLock) $false
        $msg = 'Created'
    }
    Save-ToolUsers $all
    Send $ctx @{ ok = $true; message = "$msg $name"; users = @($all | ForEach-Object { Get-UserView $_ }) }
}
# Handler /api/users-delete. Input $d.username. Removes the user. You cannot remove yourself. Sends { ok, message, users }.
$ScreenHandlers['/api/users-delete'] = {
    $name = "$($d.username)".Trim(); $me = "$($script:SessUser.name)"
    if ($name -ieq $me) { throw 'You cannot remove your own account.' }
    $all = @(Read-ToolUsers); $keep = @($all | Where-Object { "$($_.username)" -ine $name })
    if ($keep.Count -eq $all.Count) { throw 'That user does not exist.' }
    Save-ToolUsers $keep
    if ($script:SessUser -and $script:Session -and "$($script:SessUser.name)" -ieq $name) { $script:Session = $null }
    Send $ctx @{ ok = $true; message = "Removed $name"; users = @($keep | ForEach-Object { Get-UserView $_ }) }
}
# Handler /api/me-password. Any signed-in tool user changes their OWN password. Input $d.oldPassword, $d.newPassword (min 8 characters).
# Not for the owner (Change-Login.bat), SSO or AD sign-ins - their password lives elsewhere. Clears the 'must change password' flag.
$ScreenHandlers['/api/me-password'] = {
    if ($script:SessUser.owner) { throw 'The owner login is changed with Change-Login.bat (it is stored inside the tool, not here).' }
    if ($script:SessUser.sso) { throw 'You signed in with Microsoft single sign-on - change your password in Microsoft 365.' }
    if ($script:SessUser.ad) { throw 'You signed in with your AD account - change that password in Windows (Ctrl+Alt+Del > Change a password).' }
    $all = @(Read-ToolUsers); $cur = $null
    foreach ($u in $all) { if ("$($u.username)" -ieq "$($script:SessUser.name)") { $cur = $u } }
    if (-not $cur) { throw 'Your account no longer exists.' }
    if (-not (Test-UserHash $cur "$($d.oldPassword)")) { throw 'The current password is not correct.' }
    $np = "$($d.newPassword)"; if ($np.Length -lt 8) { throw 'The new password must be at least 8 characters.' }
    if ($np -ceq "$($d.oldPassword)") { throw 'Choose a different password.' }
    $h = New-UserHash $np; $cur.salt = $h.salt; $cur.hash = $h.hash; $cur.it = $h.it
    $cur | Add-Member -NotePropertyName mustChange -NotePropertyValue $false -Force
    Save-ToolUsers $all; $script:SessUser.mustChange = $false
    Send $ctx @{ ok = $true; message = 'Your password was changed.' }
}

# May this user see everybody's logs? Owner or the 'logs' permission.
function Test-CanLogs { $u = $script:SessUser; [bool]($u -and ($u.owner -or @($u.perms) -contains 'logs')) }

# Handler /api/users-adcheck. Input $d.adSam. Checks that AD account now (exists, enabled, not expired). Sends { ok, state, message }.
$ScreenHandlers['/api/users-adcheck'] = {
    # v1.98.9: { adSam } - test the AD account of a tool login now (exists, enabled, not expired)
    $sam = "$($d.adSam)".Trim(); if (-not $sam) { throw 'Type the AD username first.' }
    $st = Get-AdLoginState $sam
    $msg = switch -Regex ($st) { '^ok$' { "$sam is enabled and not expired - this person can sign in." } '^expired (.*)$' { "$sam expired on $($Matches[1]) - this person cannot sign in." } '^disabled$' { "$sam is disabled - this person cannot sign in." } '^notfound$' { "No AD user $sam." } default { "Could not check AD: $($st -replace '^error: ','')" } }
    Send $ctx @{ ok = $true; state = ($st -replace ' .*$', ''); message = $msg }
}

# --- Per-username lock (section below): counts wrong passwords per username (not per IP; the IP block is in Screen-Security.ps1). ---
# ---- v1.98.11: lock per username - 5 wrong passwords lock ONLY that username for 15 minutes ----
# Kept in login-lock.json, so a restart does not undo it. To unlock someone early: stop the tool and delete login-lock.json.
# Load the saved locks at start-up so a restart does not release a locked username.
$script:LoginLockFile = Join-Path $Root 'login-lock.json'; $script:LoginLocks = @{}
if (Test-Path $script:LoginLockFile) {
    try { $j = Get-Content $script:LoginLockFile -Raw | ConvertFrom-Json; foreach ($p in @($j.users.PSObject.Properties)) { $script:LoginLocks[$p.Name] = @{ fails = [int]$p.Value.fails; until = $(if ($p.Value.until) { ([datetime]::Parse("$($p.Value.until)", $null, 'RoundtripKind')).ToLocalTime() } else { $null }) } } } catch {}
}
# Turns what was typed (DOMAIN\user, user@domain or user) into one lower-case key, so all spellings share one counter.
function Get-LoginKey($user, $mode) { $u = (("$user".Trim() -replace '^.*\\', '') -replace '@.*$', '').ToLower(); if (-not $u) { $u = '(empty)' }; $u }
# Writes the lock table to login-lock.json. Only entries with failures or an active lock are kept. Errors are ignored.
function Save-LoginLocks {
    $o = [ordered]@{}; foreach ($k in $script:LoginLocks.Keys) { $v = $script:LoginLocks[$k]; if ($v.fails -gt 0 -or ($v.until -and $v.until -gt (Get-Date))) { $o[$k] = @{ fails = $v.fails; until = $(if ($v.until) { $v.until.ToUniversalTime().ToString('o') } else { '' }) } } }
    try { (@{ users = $o } | ConvertTo-Json -Depth 4) | Out-File $script:LoginLockFile -Encoding utf8 } catch {}
}
# Returns the time until which this username is locked, or $null. An old lock is cleaned up here.
function Get-LoginLock($key) { $v = $script:LoginLocks[$key]; if ($v -and $v.until -and $v.until -gt (Get-Date)) { return $v.until }; if ($v -and $v.until) { $script:LoginLocks.Remove($key); Save-LoginLocks }; $null }
# Counts one wrong password. At LoginMaxFails the username is locked for LoginLockMins minutes. Returns @{ fails; locked; until }.
function Add-LoginFail($key) {
    if (-not $script:LoginLocks.ContainsKey($key)) { $script:LoginLocks[$key] = @{ fails = 0; until = $null } }
    $v = $script:LoginLocks[$key]; $v.fails++
    $r = @{ fails = $v.fails; locked = $false; until = $null }
    if ($v.fails -ge $script:LoginMaxFails) { $v.fails = 0; $v.until = (Get-Date).AddMinutes($script:LoginLockMins); $r.locked = $true; $r.until = $v.until }
    Save-LoginLocks; $r
}
# Forget the failures of a username (after a correct sign-in).
function Clear-LoginFails($key) { if ($script:LoginLocks.ContainsKey($key)) { $script:LoginLocks.Remove($key); Save-LoginLocks } }

# ---- v1.98.11: sign in to the portal with an AD account - only members of the AD groups you choose (each group gives a role) ----
# Saved in ad-login.json. Nothing is written to AD. Nested groups count (a member of a group inside the group is allowed).
# AD sign-in settings: on/off and which AD groups may sign in, each with a role. Handlers: /api/adlogin-get and /api/adlogin-save.
$script:AdLoginFile = Join-Path $Root 'ad-login.json'
# Reads ad-login.json. Returns @{ enabled; groups } where each group has name, dn (distinguished name) and role.
function Get-AdLoginCfg {
    $c = [ordered]@{ enabled = $false; groups = @() }
    if (Test-Path $script:AdLoginFile) { try { $j = Get-Content $script:AdLoginFile -Raw -Encoding UTF8 | ConvertFrom-Json; $c.enabled = [bool]$j.enabled; $c.groups = @($j.groups | Where-Object { $_ -and $_.dn } | ForEach-Object { [ordered]@{ name = "$($_.name)"; dn = "$($_.dn)"; role = "$($_.role)" } }) } catch {} }
    $c
}
# When a person is in several AD groups, the group with the highest rank decides the role.
$script:RoleRank = @{ admin = 4; helpdesk = 3; readonly = 2; logviewer = 1 }
# Signs a person in with their AD username + password (LDAP bind) and checks the account is enabled, not expired and in an allowed AD group.
# Returns @{ ok ... } on success, @{ denied } (right password, not allowed) or @{ error } (counts as wrong password).
function Test-AdPortalLogin($user, $pass) {
    # @{ ok; name; user; sam; role; perms; group; dnc }  or @{ denied = 'why' } (right password, not allowed)  or @{ error = 'why' } (counts as a wrong password)
    $c = Get-AdLoginCfg
    if (-not $c.enabled -or -not @($c.groups).Count) { return @{ denied = 'Sign-in with AD is not turned on. Choose "Portal account", or ask an administrator.' } }
    if (-not $script:AdAvail) { return @{ denied = 'This PC is not joined to an Active Directory domain, so AD sign-in is unavailable.' } }
    # No domain typed: assume this PC's domain.
    $u = "$user".Trim(); if ($u -notmatch '[\\@]') { $u = "$env:USERDOMAIN\$u" }
    try {
        Add-Type -AssemblyName System.DirectoryServices
        $dnc = "$((Get-RootDse).Properties['defaultNamingContext'].Value)"   # v2.8.1: chosen DC
        # Connect to AD with the typed credentials; RefreshCache forces the real password check. Secure/Sealing/Signing = encrypted, signed LDAP.
        $e = New-Object DirectoryServices.DirectoryEntry("$(Get-LdapPrefix)$dnc", $u, "$pass", [DirectoryServices.AuthenticationTypes]'Secure, Sealing, Signing')
        $e.RefreshCache()
    } catch { return @{ error = 'Incorrect AD username or password (or the AD account is disabled, expired or locked).' } }
    $sam = Get-BoundSam $e $u; if (-not $sam) { return @{ denied = 'Your AD account could not be read.' } }
    $ds = New-Object DirectoryServices.DirectorySearcher($e); $ds.SizeLimit = 1
    foreach ($p in 'accountexpires', 'useraccountcontrol', 'displayname') { [void]$ds.PropertiesToLoad.Add($p) }
    $ds.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $sam)))"
    $r = $ds.FindOne()
    if ($r) {
        if ($r.Properties['useraccountcontrol'].Count -and ([int]$r.Properties['useraccountcontrol'][0] -band 2)) { return @{ denied = "Your AD account ($sam) is disabled." } }
        $ae = if ($r.Properties['accountexpires'].Count) { [int64]$r.Properties['accountexpires'][0] } else { 0 }
        if ($ae -gt 0 -and $ae -lt 9223372036854775807 -and [datetime]::UtcNow -ge [datetime]::FromFileTimeUtc($ae)) { return @{ denied = "Your AD account ($sam) expired on $([datetime]::FromFileTimeUtc($ae).ToLocalTime().ToString('yyyy-MM-dd')), so you cannot sign in to the portal." } }
    }
    $best = $null
    # For each allowed group test membership. The long OID 1.2.840.113556.1.4.1941 is the AD 'in chain' rule, so nested groups count.
    foreach ($g in @($c.groups)) {
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $sam))(memberOf:1.2.840.113556.1.4.1941:=$(ConvertTo-LdapValue $g.dn)))"
        try { if ($ds.FindOne() -and (-not $best -or $script:RoleRank["$($g.role)"] -gt $script:RoleRank["$($best.role)"])) { $best = $g } } catch {}
    }
    if (-not $best) { return @{ denied = "Your AD account ($sam) is not in a group that may use this portal. Ask an administrator to add you to one of: $((@($c.groups) | ForEach-Object { $_.name }) -join ', ')." } }
    # Fallback to the safest role if the group's role is unknown.
    $role = "$($best.role)"; if (-not $script:RoleDefs.Contains($role) -or $role -eq 'custom') { $role = 'readonly' }
    @{ ok = $true; name = "$env:USERDOMAIN\$sam"; user = $u; sam = $sam; role = $role; perms = @($script:RoleDefs[$role].perms); group = "$($best.name)"; dnc = $dnc }
}
# Looks an AD group up by name (sAMAccountName, cn or name). Returns @{ dn; name } or $null.
function Find-AdGroupDn($name) {
    Add-Type -AssemblyName System.DirectoryServices
    $root = if ($script:AdCred) { New-AdEntry } else { Get-AdDefaultRoot }   # v2.8.1: chosen DC
    $ds = New-Object DirectoryServices.DirectorySearcher($root); $ds.SizeLimit = 2
    $n = ConvertTo-LdapValue "$name".Trim()
    $ds.Filter = "(&(objectCategory=group)(|(sAMAccountName=$n)(cn=$n)(name=$n)))"
    foreach ($p in 'distinguishedname', 'samaccountname') { [void]$ds.PropertiesToLoad.Add($p) }
    $r = @($ds.FindAll()); if (-not $r.Count) { return $null }
    @{ dn = "$($r[0].Properties['distinguishedname'][0])"; name = "$($r[0].Properties['samaccountname'][0])" }
}
# Handler /api/adlogin-get. No input. Sends the AD sign-in settings, the roles to choose from and whether this PC is in a domain.
$ScreenHandlers['/api/adlogin-get'] = {
    $c = Get-AdLoginCfg
    $roles = @($script:RoleDefs.Keys | Where-Object { $_ -ne 'custom' } | ForEach-Object { [ordered]@{ key = $_; label = $script:RoleDefs[$_].label } })
    Send $ctx @{ ok = $true; enabled = [bool]$c.enabled; groups = @($c.groups); roles = $roles; adAvail = [bool]$script:AdAvail; domain = "$env:USERDOMAIN" }
}
# Handler /api/adlogin-save. Input $d: enabled, groups[{ name, role }]. Every group is looked up in AD now and must exist; if AD cannot be reached,
# a group that was already saved keeps its old distinguished name. Saves ad-login.json. Sends { ok, enabled, groups, message }.
$ScreenHandlers['/api/adlogin-save'] = {
    # { enabled, groups:[{ name, role }] } - each group name is looked up in AD now (it must exist)
    $c = Get-AdLoginCfg; $old = @{}; foreach ($g in $c.groups) { $old[$g.name.ToLower()] = $g }
    $list = @(); $miss = @()
    foreach ($g in @($d.groups)) {
        $nm = "$($g.name)".Trim(); if (-not $nm) { continue }
        $role = "$($g.role)"; if (-not $script:RoleDefs.Contains($role) -or $role -eq 'custom') { throw "Choose a role for the group $nm." }
        $hit = $null
        try { $hit = Find-AdGroupDn $nm } catch { if ($old[$nm.ToLower()]) { $hit = @{ dn = $old[$nm.ToLower()].dn; name = $nm } } else { throw "Could not look up the group $nm in AD: $($_.Exception.Message). Sign in to AD in Settings > Connections first." } }
        if (-not $hit) { $miss += $nm; continue }
        if ($list | Where-Object { $_.dn -eq $hit.dn }) { continue }
        $list += [ordered]@{ name = $hit.name; dn = $hit.dn; role = $role }
    }
    if ($miss.Count) { throw "Not found in AD: $($miss -join ', '). Type the group name (pre-Windows 2000 name or the name shown in AD)." }
    if ([bool]$d.enabled -and -not $list.Count) { throw 'Add at least one AD group, or turn AD sign-in off.' }
    $c.enabled = [bool]$d.enabled; $c.groups = $list
    ($c | ConvertTo-Json -Depth 4) | Out-File $script:AdLoginFile -Encoding utf8
    Send $ctx @{ ok = $true; enabled = $c.enabled; groups = @($c.groups); message = $(if ($c.enabled) { "AD sign-in is on for $($list.Count) group$(if ($list.Count -ne 1) { 's' })." } else { 'AD sign-in is off.' }) }
}

# ---- v1.98.19: personal colours - each person's own choice, saved per user in ui-prefs.json; nobody else is affected ----
# Personal look and feel (colours, layout, home screen choices) per person in ui-prefs.json. Handler /api/me-prefs.
$script:UiPrefFile = Join-Path $Root 'ui-prefs.json'
# Handler /api/me-prefs. Input $d: nothing = read; save:true + prefs{accent, sidebar, screen, bg, home}; reset:true = back to default.
# Each value is checked against an allowed list or a #rrggbb colour pattern. Sends { ok, prefs, user }. Only affects the current person.
$ScreenHandlers['/api/me-prefs'] = {
    # read: {}  /  save: { save:true, prefs:{ accent, sidebar } }  /  reset: { reset:true }
    # The settings are stored under the person's lower-case username ('owner' for the built-in owner).
    $me = if ($script:SessUser.owner) { 'owner' } else { "$($script:SessUser.name)".ToLower() }
    $all = @{}; if (Test-Path $script:UiPrefFile) { try { $j = Get-Content $script:UiPrefFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in @($j.PSObject.Properties)) { $all[$p.Name] = $p.Value } } catch {} }
    if ($d.save -or $d.reset) {
        if ($d.reset) { $all.Remove($me) }
        else {
            $o = [ordered]@{}; $x = $all[$me]; if ($x -is [Collections.IDictionary]) { foreach ($k in $x.Keys) { $o[$k] = $x[$k] } } elseif ($x) { foreach ($p in @($x.PSObject.Properties)) { $o[$p.Name] = $p.Value } }
            if ($null -ne $d.prefs.accent -or $null -ne $d.prefs.sidebar) {
                # Colours must be #rrggbb; an empty value removes the choice.
                foreach ($k in 'accent', 'sidebar') { $o.Remove($k); $v = "$($d.prefs.$k)".Trim(); if ($v) { if ($v -notmatch '^#[0-9a-fA-F]{6}$') { throw "Not a valid colour: $v" }; $o[$k] = $v.ToLower() } }
            }
            if ($null -ne $d.prefs.screen) {   # v1.98.42: Screen layout
                # Allowed values for each layout option (zoom, density, corners, ...). Anything else is refused.
                $sc = $d.prefs.screen; $okS = @{ zoom = '90', '100', '110', '125'; density = 'compact', 'normal', 'comfy'; corners = 'square', 'normal', 'round'; width = 'full', 'center'; menuw = 'narrow', 'normal', 'wide'; icons = 'on', 'off' }
                $sn = [ordered]@{}; foreach ($k in $okS.Keys) { $v = "$($sc.$k)"; if ($v) { if ($v -notin $okS[$k]) { throw "Not a valid choice for ${k}: $v" }; $sn[$k] = $v } }
                $o['screen'] = $sn
            }
            if ($null -ne $d.prefs.bg) {   # v2.4.0: Screen background
                $bg = $d.prefs.bg; $bn = [ordered]@{}
                $c = "$($bg.color)".Trim(); if ($c) { if ($c -notmatch '^#[0-9a-fA-F]{6}$') { throw "Not a valid colour: $c" }; $bn.color = $c.ToLower() }
                $c2 = "$($bg.color2)".Trim(); if ($c2) { if ($c2 -notmatch '^#[0-9a-fA-F]{6}$') { throw "Not a valid colour: $c2" }; $bn.color2 = $c2.ToLower() }
                foreach ($ck in 'hero1', 'hero2') { $hv = "$($bg.$ck)".Trim(); if ($hv) { if ($hv -notmatch '^#[0-9a-fA-F]{6}$') { throw "Not a valid colour: $hv" }; $bn[$ck] = $hv.ToLower() } }
                # Allowed values for the background options (style, cards, font, size, ...).
                $okB = @{ style = 'plain', 'gradient', 'dots', 'grid'; cards = 'solid', 'glass'; font = 'segoe', 'calibri', 'arial', 'verdana', 'tahoma', 'trebuchet', 'georgia', 'cambria', 'mono'; fsize = '13', '14', '15', '16', '17'; look = 'normal', 'glossy' }
                foreach ($k in $okB.Keys) { $v = "$($bg.$k)"; if ($v) { if ($v -notin $okB[$k]) { throw "Not a valid choice for ${k}: $v" }; $bn[$k] = $v } }
                if ($bn.Count) { $o['bg'] = $bn } else { $o.Remove('bg') }
            }
            if ($null -ne $d.prefs.home) {   # v1.98.23: Home screen choices
                # Home screen options: allowed values per option (how the greeting and the Microsoft / AD names are shown).
                $h = $d.prefs.home; $ok = @{ greet = 'on', 'off'; greetName = 'none', 'first', 'full', 'display'; msShow = 'email', 'display', 'full', 'first', 'email+display', 'hide'; adShow = 'user', 'email', 'display', 'full', 'first', 'user+display', 'hide'; meTile = 'on', 'off'; verTile = 'on', 'off'; dateLine = 'on', 'off' }
                $hn = [ordered]@{}; foreach ($k in $ok.Keys) { $v = "$($h.$k)"; if ($v) { if ($v -notin $ok[$k]) { throw "Not a valid choice for ${k}: $v" }; $hn[$k] = $v } }
                # Own greeting text, at most 60 characters.
                $gt = "$($h.greetText)".Trim(); if ($gt.Length -gt 60) { throw 'The greeting can be at most 60 characters.' }; if ($gt) { $hn.greetText = $gt }
                $o.home = $hn
            }
            $all[$me] = $o
        }
        $out = [ordered]@{}; foreach ($k in $all.Keys) { $out[$k] = $all[$k] }
        ($out | ConvertTo-Json -Depth 4) | Out-File $script:UiPrefFile -Encoding utf8
    }
    Send $ctx @{ ok = $true; prefs = $(if ($all[$me]) { $all[$me] } else { @{} }); user = $me }
}

# v1.98.23: Home screen - who you are signed in as (Microsoft Entra and on-premises AD): e-mail, display name, first and last name. Read only.
# Home screen: looks up the signed-in AD account (mail, UPN, display name, first/last name) in AD. Cached in $script:AdInfo until the AD user changes.
# Returns $null when not signed in to AD. Read only.
function Get-AdSelfInfo {
    if (-not $script:AdCred) { $script:AdInfo = $null; return $null }
    if ($script:AdInfo -and $script:AdInfo.key -eq "$($script:AdCred.User)") { return $script:AdInfo }
    $i = [ordered]@{ key = "$($script:AdCred.User)"; user = "$($script:AdCred.User)"; sam = "$($script:AdCred.Sam)"; email = ''; upn = ''; display = ''; first = ''; last = '' }
    try {
        $sam = if ($i.sam) { $i.sam } else { ("$($i.user)" -replace '^.*\\', '') -replace '@.*$', '' }
        $ds = New-Object DirectoryServices.DirectorySearcher; $ds.SearchRoot = (New-AdEntry); $ds.SizeLimit = 1
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LdapValue $sam)))"
        foreach ($p in 'mail', 'userprincipalname', 'displayname', 'givenname', 'sn', 'samaccountname') { [void]$ds.PropertiesToLoad.Add($p) }
        $r = $ds.FindOne()
        if ($r) { $g = { param($k) if ($r.Properties[$k].Count) { "$($r.Properties[$k][0])" } else { '' } }
            $i.sam = & $g 'samaccountname'; $i.email = & $g 'mail'; $i.upn = & $g 'userprincipalname'; $i.display = & $g 'displayname'; $i.first = & $g 'givenname'; $i.last = & $g 'sn' }
    } catch {}
    $script:AdInfo = $i; $i
}
# Handler /api/home-info. No input. Sends the names of the Microsoft and AD accounts the person is signed in with (ms{...}, ad{...}) for the Home greeting.
$ScreenHandlers['/api/home-info'] = {
    $ad = Get-AdSelfInfo
    Send $ctx @{ ok = $true
        ms = @{ on = [bool]$script:Who; email = "$(if ($script:WhoUpn) { $script:WhoUpn } else { $script:Who })"; display = "$(if ($script:WhoDisp) { $script:WhoDisp } else { $script:WhoName })"; first = "$($script:WhoFirst)"; last = "$($script:WhoLast)" }
        ad = $(if ($ad) { @{ on = $true; user = $ad.user; sam = $ad.sam; email = $(if ($ad.email) { $ad.email } else { $ad.upn }); display = $ad.display; first = $ad.first; last = $ad.last } } else { @{ on = $false } }) }
}

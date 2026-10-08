# Screen-MsLogin.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Microsoft sign-in (Connections)
# Screen version: 2.5.2   (changes ONLY when this screen changes - not with every release)

# WHAT IT DOES: signs a person in to Microsoft 365 (Graph) in three ways - browser sign-in (authorization code + PKCE), 'sign in with a code'
# (device code flow) and a settings page for the company's own app registration. Also renews the access token and fills the 'who am I' info.
# ENDPOINTS: POST /api/ms-login-start (field origin, back, tenant, hint, autoMins -> reply url to open), POST /api/ms-device-start and
# /api/ms-device-poll (device code), POST /api/msapp-get and /api/msapp-save (tenant, clientId, secret, exo, clearSecret).
# Complete-MsLogin is not an /api route: server.ps1 calls it when Microsoft sends the browser back with ?code=&state=.
# LOGIN CALLS: https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize, /token and /devicecode; then Connect-MgGraph with the access token.
# DATA: ms-app.json (the app registration; the secret is stored encrypted with Protect-MailSecret). Tokens live only in memory.
# PERMISSION: anyone who can open the tool may sign in; saving the app registration is for administrators.
#
# (the original description follows)
# Microsoft sign-in through YOUR browser (v1.80.0): Connect sends the browser you are already using to Microsoft's own
# "Pick an account" page. Microsoft lists the accounts that are signed in in that browser (it reads its own cookies there -
# the tool never reads, copies or stores browser cookies). After you pick one, Microsoft sends the browser back to
# http://localhost:8080/ and the tool finishes the sign-in (authorization code + PKCE, the same public app as Connect-MgGraph).
# The tokens stay in memory only (never on disk, never logged) and are renewed by themselves until you sign out.

# Default sign-in app. It is a PUBLIC client, so it needs no secret.
$script:MsClientId = '14d82eec-204b-4c2b-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools (the app Connect-MgGraph uses)
# Pending browser sign-ins. Key = random 'state' value, value = PKCE verifier, origin, tenant and so on. Entries older than 15 minutes are removed.
$script:MsAuth = @{}          # state -> pending browser sign-in
# Sign-in state kept in memory: refresh token, expiry time, granted scopes, last error/note, last renew failure time, and the tenant to use.
$script:MsRefresh = $null; $script:MsExp = $null; $script:MsScopes = $null; $script:MsErr = $null; $script:MsNote = $null; $script:MsTokFail = $null; $script:MsTenant = 'organizations'

# Base64 'URL safe' text (+ becomes -, / becomes _, no = padding). Needed for the PKCE challenge and the random state.
function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
# Returns the permissions (scopes) of the current Microsoft sign-in: our saved list, else what the Graph module reports, else an empty list.
function Get-MsScopes { if ($script:MsScopes) { @($script:MsScopes) } else { try { @((Get-MgContext).Scopes) } catch { @() } } }
# Reads the claims (name, preferred_username, upn ...) inside a JWT token. A JWT has 3 parts split by dots; the middle one is base64url JSON.
# The signature is NOT checked - this is only used to read who signed in, after Microsoft itself returned the token over HTTPS. Returns $null on error.
function Get-IdClaims($jwt) {
    try {
        $p = "$jwt".Split('.')[1].Replace('-', '+').Replace('_', '/'); while ($p.Length % 4) { $p += '=' }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    } catch { $null }
}
# Calls Microsoft's token endpoint with $form (code exchange or refresh) for $tenant and returns the reply. Forces TLS 1.2 (old PowerShell 5.1).
# Errors are turned into Microsoft's own readable message.
function Invoke-MsToken($form, $tenant = 'organizations') {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    try { Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body $form -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch {
        $m = $_.Exception.Message
        try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.error_description) { $m = ("$($j.error_description)" -split "`r?`n")[0] } } catch {}
        # v2.4.7: the app is a PUBLIC client ("Mobile and desktop") - its secret is only for app-only work (Mailbox cleanup), never for a person's sign-in
        # AADSTS700025 = 'public client must not send a secret'. Retry once without the secret and remember that for later calls.
        if ($m -match 'AADSTS700025' -and $form.client_secret -and "$($form.grant_type)" -ne 'client_credentials') {
            $f2 = @{}; foreach ($k in $form.Keys) { if ($k -ne 'client_secret') { $f2[$k] = $form[$k] } }
            $script:MsPublicOnly = $true
            return (Invoke-MsToken $f2 $tenant)
        }
        throw $m
    }
}
# Connects the Microsoft Graph PowerShell module with an access token we already have. Newer module versions want a SecureString, older ones text -
# so the parameter type is checked first.
function Connect-MsToken($tok) {
    $script:GraphSid = $script:Session   # v2.0.0: the Graph connection now belongs to this session
    $t = (Get-Command Connect-MgGraph).Parameters['AccessToken'].ParameterType
    if ($t -eq [securestring]) { Connect-MgGraph -AccessToken (ConvertTo-SecureString "$tok" -AsPlainText -Force) -NoWelcome }
    else { Connect-MgGraph -AccessToken "$tok" -NoWelcome }
}
# Stores what Microsoft returned: refresh token, access token, expiry time and the granted scopes (the Graph address prefix and the standard
# openid / profile / email / offline_access entries are removed so only real permissions remain).
function Save-MsTokens($r) {
    if ($r.refresh_token) { $script:MsRefresh = "$($r.refresh_token)" }
    if ($r.access_token) { $script:MsAccess = "$($r.access_token)" }   # v2.0.0: kept per session, to switch Graph back to this person
    $script:MsExp = (Get-Date).AddSeconds([int]$r.expires_in)
    if ($r.scope) { $script:MsScopes = @("$($r.scope)" -split '\s+' | Where-Object { $_ } | ForEach-Object { $_ -replace '^https://graph\.microsoft\.com/', '' } | Where-Object { $_ -notin 'openid', 'profile', 'email', 'offline_access', '.default' }) }
}
# called from the main loop every second: renew the access token about 5 minutes before it ends
# Renews the access token with the refresh token. Skips if the token still has more than 5 minutes left, or if the last renew failed less than
# 60 seconds ago (so a broken sign-in is not retried every second). -Force renews now and throws on failure.
function Update-MsToken([switch]$Force) {
    if (-not $script:MsRefresh -or -not $script:Who -or -not $script:MsExp) { if ($Force) { throw 'no refresh token' }; return }
    if (-not $Force -and (Get-Date) -lt $script:MsExp.AddMinutes(-5)) { return }
    if (-not $Force -and $script:MsTokFail -and ((Get-Date) - $script:MsTokFail).TotalSeconds -lt 60) { return }
    try {
        $r = Invoke-MsToken (Get-MsTokenForm @{ grant_type = 'refresh_token'; refresh_token = $script:MsRefresh; scope = 'https://graph.microsoft.com/.default offline_access' }) $script:MsTenant
        # v2.0.0: only switch the Graph connection when it is this person's (or when asked) - otherwise just keep the new token
        if ($Force -or ($script:GraphSid -and $script:GraphSid -eq $script:Session)) { Connect-MsToken $r.access_token }
        $keep = $script:MsScopes; Save-MsTokens $r; if ($keep -and -not $r.scope) { $script:MsScopes = $keep }
        $script:MsTokFail = $null
    } catch { $script:MsTokFail = Get-Date; Write-Host "Microsoft sign-in could not be renewed: $_" -ForegroundColor Yellow; if ($Force) { throw } }
}
# v2.0.0: the token request for the app this session signed in with (the Microsoft Graph PowerShell app, or your own app registration)
# Adds client_id (own app or default) and, if used, the decrypted secret to a token request. $f = hashtable of form fields; returns it.
function Get-MsTokenForm($f) { $f.client_id = $(if ($script:MsClient) { $script:MsClient } else { $script:MsClientId }); if ($script:MsSecret -and -not $script:MsPublicOnly) { $f.client_secret = (Unprotect-MailSecret $script:MsSecret) }; $f }

# v1.98.13: bring the Microsoft Graph session back by itself (renew the token, or reconnect the certificate) instead of failing with
# 'Authentication needed. Please call Connect-MgGraph'. Returns `$true when Graph works again. -Force renews even if a context exists.
# Brings the Graph connection back without asking the person to sign in again: renew by refresh token, or reconnect with a certificate (app-only).
# Runs at most once every 20 seconds. Returns $true when Graph works afterwards.
function Repair-MsGraph([switch]$Force) {
    if (-not $script:Who) { return $false }
    if (-not $Force) { $c = $null; try { $c = Get-MgContext } catch {}; if ($c) { return $true } }
    if ($script:MsRepairAt -and ((Get-Date) - $script:MsRepairAt).TotalSeconds -lt 20) { return [bool](Get-MgContext) }   # not more than once every 20 s
    $script:MsRepairAt = Get-Date
    try {
        if ($script:MsRefresh) {
            $r = Invoke-MsToken (Get-MsTokenForm @{ grant_type = 'refresh_token'; refresh_token = $script:MsRefresh; scope = 'https://graph.microsoft.com/.default offline_access' }) $script:MsTenant
            Connect-MsToken $r.access_token; $keep = $script:MsScopes; Save-MsTokens $r; if ($keep -and -not $r.scope) { $script:MsScopes = $keep }
        } elseif ($script:CertInfo -and $script:CertInfo.Thumb -and $script:CertInfo.Tenant) {
            Connect-MgGraph -TenantId $script:CertInfo.Tenant -ClientId $script:CertInfo.AppId -CertificateThumbprint $script:CertInfo.Thumb -NoWelcome; $script:GraphSid = $script:Session
        } else { return $false }
        Write-Host 'Microsoft Graph session renewed.' -ForegroundColor Green
        return [bool](Get-MgContext)
    } catch { Write-Host "Microsoft Graph session could not be renewed: $_" -ForegroundColor Yellow; return $false }
}
# v2.0.0: your OWN app registration (Settings > Connections) lets people sign in from other PCs (IIS, https://portal...).
# Without it, the Microsoft Graph PowerShell app is used: browser sign-in only on this PC (localhost), "sign in with a code" anywhere.
# File with the company's own app registration (tenant, clientId, encrypted secret, exo flag).
$script:MsAppFile = Join-Path $Root 'ms-app.json'
# Reads ms-app.json over a set of default values; missing file or fields give empty defaults.
function Get-MsAppCfg {
    $c = [ordered]@{ tenant = ''; clientId = ''; secretEnc = ''; exo = $false }
    if (Test-Path $script:MsAppFile) { try { $j = Get-Content $script:MsAppFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } } } catch {} }
    $c
}
# Permissions requested when the default Microsoft Graph PowerShell app is used. With an own app registration '.default' is used instead
# (the permissions the administrator granted on the app).
$script:MsGraphScopes = @('LicenseAssignment.ReadWrite.All', 'User.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'Device.ReadWrite.All', 'Reports.Read.All', 'User.Read.All', 'Domain.Read.All', 'User.EnableDisableAccount.All', 'User-PasswordProfile.ReadWrite.All', 'UserAuthenticationMethod.ReadWrite.All', 'Group.ReadWrite.All', 'Mail.Send', 'Mail.Send.Shared', 'Sites.ReadWrite.All', 'User.Invite.All', 'AuditLog.Read.All', 'Directory.Read.All')
# the Microsoft account this tool user must use (Settings > Users), or ''
# If an administrator tied this tool user to one Microsoft account (Settings > Users) returns @{ upn; lock }, else $null. Owners, SSO and AD users are never tied.
function Get-AssignedMs { $u = $script:SessUser; if (-not $u -or $u.owner -or ($u.sso -and -not $u.toolUser) -or $u.ad) { return $null }; $t = Get-ToolUserRec "$($u.name)"; if ($t -and "$($t.msUpn)") { return @{ upn = "$($t.msUpn)"; lock = ($t.msLock -ne $false) } }; $null }
# Handler: builds the Microsoft 'pick an account' address for the browser. Request: origin (address of this portal), back (page to return to),
# tenant, hint (e-mail to pre-select), autoMins (auto sign-out time). Reply: { ok, url } or { needCode } when only the code method is possible.
$ScreenHandlers['/api/ms-login-start'] = {
    $origin = "$($d.origin)".TrimEnd('/')
    # The origin must look like http(s)://host[:port]; it is later used for the redirect, so nothing else is accepted.
    if ($origin -notmatch '^https?://[A-Za-z0-9.-]+(:\d+)?$') { throw 'Not a valid address of this portal.' }
    # True when the portal is opened on this PC itself (localhost, 127.0.0.1 or the PC name on our port).
    $isLocal = $origin -match ('^http://(localhost|127\.0\.0\.1|[A-Za-z0-9-]+):' + $Port + '$')
    $app = Get-MsAppCfg
    # Pick the app: own registration (works from any PC) or the default app, which is only allowed to return to http://localhost.
    if ($app.clientId) { $client = "$($app.clientId)"; $redirect = $(if ($isLocal) { "http://localhost:$Port/" } else { "$origin/" }); $secret = "$($app.secretEnc)" }   # v2.4.0: http on a PC name is not allowed by Microsoft - use localhost
    elseif ($isLocal) { $client = $script:MsClientId; $redirect = "http://localhost:$Port"; $secret = '' }
    else { Send $ctx @{ ok = $false; needCode = $true; error = 'Sign-in through the browser from another PC needs your own app registration (Settings > Connections > Microsoft app). Use "Sign in with a code" instead.' }; return }
    # 'back' is the page marker to return to; only letters, digits and # _ - are kept, max 40 characters.
    $back = ("$($d.back)" -replace '[^A-Za-z0-9#_-]', ''); if ($back.Length -gt 40) { $back = '' }
    # Tenant: the app registration's tenant wins; else what was typed; default 'organizations'. Must be a domain name or a directory id.
    $tenant = "$($d.tenant)".Trim(); if ($app.tenant) { $tenant = "$($app.tenant)" }; if (-not $tenant) { $tenant = 'organizations' } elseif ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'The organization must be a domain (for example contoso.onmicrosoft.com) or a directory ID.' }
    # Account hint: only an e-mail-like value is accepted; an account assigned to this tool user overrides it.
    $hint = "$($d.hint)".Trim(); if ($hint -notmatch '^[^@\s]+@[^@\s]+$') { $hint = '' }
    $as = Get-AssignedMs; if ($as) { $hint = $as.upn }
    # PKCE: a random secret 'verifier' stays on the server; Microsoft gets only its SHA-256 'challenge'. 'state' is a random id that ties the
    # browser's return to this request and protects against forged returns.
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rb = New-Object byte[] 48; $rng.GetBytes($rb); $verifier = ConvertTo-B64Url $rb
    $sb = New-Object byte[] 24; $rng.GetBytes($sb); $state = ConvertTo-B64Url $sb
    $challenge = ConvertTo-B64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    # Forget sign-ins that were started more than 15 minutes ago.
    foreach ($k in @($script:MsAuth.Keys)) { if (((Get-Date) - $script:MsAuth[$k].time).TotalMinutes -gt 15) { $script:MsAuth.Remove($k) } }
    $script:MsAuth[$state] = @{ verifier = $verifier; origin = $origin; back = $back; hint = $hint; tenant = $tenant; autoMins = [int]$d.autoMins; time = (Get-Date); sid = $script:Session; client = $client; redirect = $redirect; secret = $secret }
    $scope = $(if ($app.clientId) { 'https://graph.microsoft.com/.default openid profile offline_access' } else { (($script:MsGraphScopes | ForEach-Object { "https://graph.microsoft.com/$_" }) + 'openid' + 'profile' + 'offline_access') -join ' ' })
    # Query string for Microsoft's authorize page. prompt=select_account forces the 'Pick an account' list.
    $q = [ordered]@{ client_id = $client; response_type = 'code'; redirect_uri = $redirect; response_mode = 'query'; scope = $scope; state = $state; code_challenge = $challenge; code_challenge_method = 'S256'; prompt = 'select_account' }
    if ($hint) { $q.login_hint = $hint }
    $url = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize?" + (($q.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString("$($_.Value)"))" }) -join '&')
    Send $ctx @{ ok = $true; url = $url }
}
# v2.0.0: the end of every Microsoft sign-in (browser or code): who it is, the rules for this tool user, the Graph connection
# Final step of every sign-in. $r = token reply, plus tenant / client / secret / hint / autoMins and $how ('browser' or 'code').
# Reads the account from the id token, applies the 'locked to one account' rule, connects Graph, loads the person's name and on-premises
# (AD) link from Entra, sets the auto sign-out time (0, or 5 to 1440 minutes) and writes the activity log.
function Complete-MsSignIn($r, $tenant, $client, $secret, $hint, $autoMins, $how) {
    $claims = Get-IdClaims $r.id_token
    $acct = if ($claims.preferred_username) { "$($claims.preferred_username)" } elseif ($claims.upn) { "$($claims.upn)" } else { '' }
    if (-not $acct -and $r.access_token) { $ac = Get-IdClaims $r.access_token; $acct = if ($ac.upn) { "$($ac.upn)" } elseif ($ac.unique_name) { "$($ac.unique_name)" } else { '' } }
    if (-not $acct) { throw 'Microsoft did not say which account signed in.' }
    $as = Get-AssignedMs
    if ($as -and $as.lock -and $acct -ine $as.upn) { throw "Your administrator set this portal account to use $($as.upn) - you signed in as $acct. Sign in again with $($as.upn)." }
    # Remember which app this session signed in with (only when it is not the default), so renewing uses the same one.
    $script:MsClient = $(if ($client -and $client -ne $script:MsClientId) { $client } else { $null }); $script:MsSecret = $(if ($secret -and -not $script:MsPublicOnly) { $secret } else { $null })
    Connect-MsToken $r.access_token
    Save-MsTokens $r; $script:MsTenant = $tenant
    $script:Who = $acct
    try {
        # Read the person's own profile (needs only basic read rights). If that fails the id-token name is used instead.
        $me = Get-MgUser -UserId $acct -Property GivenName, Surname, DisplayName, UserPrincipalName, OnPremisesSamAccountName, OnPremisesSyncEnabled, OnPremisesDomainName -ErrorAction Stop
        $script:WhoUpn = "$($me.UserPrincipalName)"; $script:WhoSam = "$($me.OnPremisesSamAccountName)"
        $script:WhoSynced = [bool]$me.OnPremisesSyncEnabled; $script:WhoDom = "$($me.OnPremisesDomainName)"
        $script:WhoName = ("$($me.GivenName) $($me.Surname)").Trim(); if (-not $script:WhoName) { $script:WhoName = "$($me.DisplayName)" }; $script:WhoFirst = "$($me.GivenName)"; $script:WhoLast = "$($me.Surname)"; $script:WhoDisp = "$($me.DisplayName)"
    } catch { $script:WhoUpn = $acct; $script:WhoName = "$($claims.name)"; $script:WhoDisp = "$($claims.name)" }
    if (Get-Command Set-DgPaths -ErrorAction SilentlyContinue) { Set-DgPaths }
    # Auto sign-out: a value outside 5-1440 minutes is treated as 'never'.
    $script:AutoMins = [int]$autoMins
    if ($script:AutoMins -ne 0 -and ($script:AutoMins -lt 5 -or $script:AutoMins -gt 1440)) { $script:AutoMins = 0 }
    $script:LogoutAt = if ($script:AutoMins -gt 0) { (Get-Date).AddMinutes($script:AutoMins) } else { $null }
    if (Get-Command Save-RecentAccount -ErrorAction SilentlyContinue) { Save-RecentAccount $acct $script:WhoName }
    if ($hint -and $hint -ine $acct) { $script:MsNote = "You chose $hint but Microsoft signed you in as $acct." }
    try { Write-ActRow 'Sign-in' "Microsoft sign-in ($how)" $acct 'Done' '' } catch {}
}

# Microsoft sends the browser back to the portal with ?code=...&state=... - finish the sign-in and send the browser on to the tool
# Called by server.ps1 when the browser returns from Microsoft with ?code=...&state=... . Checks the state, swaps the code for tokens,
# finishes the sign-in and answers with a small page that sends the browser on to the tool. Errors are stored in $script:MsErr for the page.
function Complete-MsLogin($ctx) {
    $qs = $ctx.Request.QueryString
    $st = $script:MsAuth["$($qs['state'])"]
    # Unknown or expired state (older than 15 min): show a friendly page instead of signing anyone in.
    if (-not $st -or ((Get-Date) - $st.time).TotalMinutes -gt 15) {
        $b = [Text.Encoding]::UTF8.GetBytes('<html><body style="font-family:sans-serif;padding:30px"><h3>This sign-in link is not valid any more.</h3><p>Go back to the Admin Console and press Connect again.</p></body></html>')
        $ctx.Response.StatusCode = 400; $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close(); return
    }
    $script:MsAuth.Remove("$($qs['state'])")
    # v2.0.0: the sign-in belongs to the portal session that started it (the browser may come back on another host name, e.g. localhost)
    # The browser may come back under a different host name (so a different session). Switch to the session that started the sign-in,
    # or tell the person if that session no longer exists.
    if ($script:Session -ne $st.sid) {
        if (-not $st.sid -or -not $script:Sessions.ContainsKey($st.sid)) {
            $b = [Text.Encoding]::UTF8.GetBytes('<html><body style="font-family:sans-serif;padding:30px"><h3>Your portal session ended.</h3><p>Sign in to the Admin Console again, then connect to Microsoft.</p></body></html>')
            $ctx.Response.StatusCode = 400; $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close(); return
        }
        Use-Sess $st.sid
    }
    $script:MsErr = $null; $script:MsNote = $null
    try {
        # Microsoft returned an error (for example the person cancelled): '+' in its text is a space.
        if ($qs['error']) { throw "Microsoft: $($qs['error_description'])" -replace '\+', ' ' }
        if (-not $qs['code']) { throw 'Microsoft did not send a sign-in code.' }
        Exit-StGraph 'Microsoft sign-out (new sign-in)'; Clear-Who
        # Swap the one-time code for tokens; code_verifier proves we are the app that started the sign-in (PKCE).
        $f = @{ client_id = $st.client; grant_type = 'authorization_code'; code = "$($qs['code'])"; redirect_uri = $st.redirect; code_verifier = $st.verifier; scope = 'https://graph.microsoft.com/.default offline_access' }
        if ($st.secret) { $f.client_secret = (Unprotect-MailSecret $st.secret) }
        $r = Invoke-MsToken $f $st.tenant
        Complete-MsSignIn $r $st.tenant $st.client $st.secret $st.hint $st.autoMins 'browser'
    } catch {
        $script:MsErr = "Microsoft sign-in failed: $($_.Exception.Message)"
        Exit-StGraph; Clear-Who
        try { Write-ActRow 'Sign-in' 'Microsoft sign-in (browser)' '' "Failed: $($_.Exception.Message)" '' } catch {}
    }
    # v2.0.0: a small page that moves on by itself - a plain redirect straight after Microsoft's page would not carry the portal cookie (SameSite)
    # Where to send the browser next (the page it came from, or #home).
    $to = $st.origin + '/' + $(if ($st.back) { $st.back } else { '#home' })
    $b = [Text.Encoding]::UTF8.GetBytes('<!doctype html><html><head><meta charset="utf-8"><title>Signing in...</title></head><body style="font-family:Segoe UI,Arial,sans-serif;padding:30px;color:#334155">Signing in... <script>location.replace(' + ($to | ConvertTo-Json) + ')</script></body></html>')
    # Send the small redirect page; no-store so it is never cached.
    $ctx.Response.StatusCode = 200; $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.Headers.Add('Cache-Control', 'no-store'); $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
}
# DEVICE CODE FLOW (two handlers): ms-device-start asks Microsoft for a short code and the page shows it; ms-device-poll is called by the page every few seconds.
# v2.0.0: "Sign in with a code" - works from any PC (also through IIS) without an app registration: the person opens
# microsoft.com/devicelogin on their own PC or phone, types the code and signs in there.
# Handler: request a device code. Request: tenant, autoMins. Reply: userCode to type at the address 'url', polling 'interval' and 'expires' (seconds).
$ScreenHandlers['/api/ms-device-start'] = {
    $app = Get-MsAppCfg
    $client = $(if ($app.clientId) { "$($app.clientId)" } else { $script:MsClientId })
    $tenant = "$($d.tenant)".Trim(); if ($app.tenant) { $tenant = "$($app.tenant)" }; if (-not $tenant) { $tenant = 'organizations' } elseif ($tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'The organization must be a domain or a directory ID.' }
    $scope = $(if ($app.clientId) { 'https://graph.microsoft.com/.default openid profile offline_access' } else { (($script:MsGraphScopes | ForEach-Object { "https://graph.microsoft.com/$_" }) + 'openid' + 'profile' + 'offline_access') -join ' ' })
    try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode" -Body @{ client_id = $client; scope = $scope } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch { throw "Microsoft did not give a sign-in code: $($_.Exception.Message)" }
    $as = Get-AssignedMs
    # Remember the pending device sign-in (one at a time) until it succeeds or the code expires.
    $script:MsDev = @{ code = "$($r.device_code)"; client = $client; secret = $(if ($app.clientId) { "$($app.secretEnc)" } else { '' }); tenant = $tenant; until = (Get-Date).AddSeconds([int]$r.expires_in); autoMins = [int]$d.autoMins; hint = $(if ($as) { $as.upn } else { '' }) }
    Send $ctx @{ ok = $true; userCode = "$($r.user_code)"; url = "$($r.verification_uri)"; interval = [int]$r.interval; expires = [int]$r.expires_in; account = $(if ($as) { $as.upn } else { '' }) }
}
# Handler: asks Microsoft whether the person has typed the code yet. Reply { pending = true } while waiting; when done, finishes the sign-in and
# returns who signed in, scopes, auto sign-out time, linked AD info and any note.
$ScreenHandlers['/api/ms-device-poll'] = {
    $dv = $script:MsDev
    if (-not $dv) { throw 'Start "Sign in with a code" again.' }
    if ((Get-Date) -gt $dv.until) { $script:MsDev = $null; throw 'The code has expired. Start again.' }
    $f = @{ client_id = $dv.client; grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = $dv.code }
    if ($dv.secret -and -not $dv.noSecret) { $f.client_secret = (Unprotect-MailSecret $dv.secret) }
    try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($dv.tenant)/oauth2/v2.0/token" -Body $f -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch {
        $m = $_.Exception.Message; $code = ''
        try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; $code = "$($j.error)"; if ($j.error_description) { $m = ("$($j.error_description)" -split "`r?`n")[0] } } catch {}
        if (-not $code -and $m -match '\(400\)') { $code = 'authorization_pending' }   # v2.4.3: the answer could not be read - while waiting Microsoft answers 400, so keep waiting (the code expiry still ends it)
        # Normal waiting answers - not errors. Anything else ends the attempt with a message.
        if ($code -in 'authorization_pending', 'slow_down') { Send $ctx @{ ok = $true; pending = $true }; return }
        if ($m -match 'AADSTS700025' -and -not $dv.noSecret) { $dv.noSecret = $true; $script:MsDev = $dv; $script:MsPublicOnly = $true; Send $ctx @{ ok = $true; pending = $true }; return }   # v2.4.7: public app - ask again without the secret
        $script:MsDev = $null; throw "Microsoft sign-in failed: $m"
    }
    $script:MsDev = $null
    # Drop any older sign-in first, then complete the new one; on failure leave no half signed-in state.
    Exit-StGraph 'Microsoft sign-out (new sign-in)'; Clear-Who
    try { Complete-MsSignIn $r $dv.tenant $dv.client $dv.secret $dv.hint $dv.autoMins 'code' }
    catch { Exit-StGraph; Clear-Who; throw }
    Send $ctx @{ ok = $true; who = $script:Who; name = $script:WhoName; scopes = @(Get-MsScopes); logoutAt = (Get-LogoutIso); linked = (Get-Linked); adUser = $(if ($script:AdCred) { $script:AdCred.User } else { $null }); note = $script:MsNote }
}
# Settings > Connections > Microsoft app (administrators): your own app registration for sign-in from other PCs and for Exchange Online
# Handler: returns the saved app registration for the settings page (the secret is never sent back - only hasSecret true/false).
$ScreenHandlers['/api/msapp-get'] = {
    $c = Get-MsAppCfg
    Send $ctx @{ ok = $true; tenant = "$($c.tenant)"; clientId = "$($c.clientId)"; hasSecret = [bool]"$($c.secretEnc)"; exo = [bool]$c.exo; redirectHint = 'The address people open (for example https://admin.contoso.com/) - add it as a redirect URI.' }
}
# Handler: saves the app registration. Request: clientId (GUID), tenant, exo (use for Exchange Online), secret (new secret) or clearSecret.
$ScreenHandlers['/api/msapp-save'] = {
    $c = Get-MsAppCfg
    $cid = "$($d.clientId)".Trim(); $ten = "$($d.tenant)".Trim()
    # Checks: the client id must be a GUID; a tenant is required with it; the tenant must be a directory id or domain name.
    if ($cid -and $cid -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw 'The application (client) ID is a GUID, for example 1b2c3d4e-....' }
    if ($cid -and -not $ten) { throw 'Type the tenant (directory) ID or your onmicrosoft.com domain too.' }
    if ($ten -and $ten -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'The tenant must be a directory ID or a domain.' }
    $c.clientId = $cid; $c.tenant = $ten; $c.exo = [bool]$d.exo
    # Secret handling: clear it, or encrypt a newly typed one (Protect-MailSecret); if neither, the old one stays.
    if ($d.clearSecret) { $c.secretEnc = '' } elseif ("$($d.secret)") { $c.secretEnc = Protect-MailSecret "$($d.secret)" }
    ($c | ConvertTo-Json) | Out-File $script:MsAppFile -Encoding utf8
    try { Write-ActRow 'Settings' 'Microsoft app saved' $cid 'Done' '' } catch {}
    Send $ctx @{ ok = $true }
}

# Screen-Sso.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Single sign-on (SSO)
# Screen version: 2.8.1   (changes ONLY when this screen changes - not with every release)

# Settings > Single sign-on (administrators only): sign in to the portal with Microsoft Entra ID - OpenID Connect (OIDC) or SAML 2.0.
# The role in the portal comes from the user's Entra app roles or groups (mapping below). Nothing is changed in Entra by the tool.
#  OIDC : authorization code flow with a client secret. The ID token is taken straight from Microsoft's token endpoint (TLS)
#         and checked: audience, issuer / tenant, nonce, expiry.
#  SAML : SP-initiated, HTTP-Redirect AuthnRequest, HTTP-POST response. The XML signature is checked with the certificate from
#         the Entra federation metadata you upload; audience, time, destination and the request ID are checked too.

# Screen: Single sign-on (SSO). Admin endpoints: /api/sso-get, /api/sso-save, /api/sso-metadata, /api/sso-logo (administrators only, see Screen-Users.ps1).
# Sign-in routes /sso/oidc/start, /sso/oidc/callback, /sso/saml/start, /sso/saml/acs, /sso/saml/metadata are run by Invoke-SsoRoute (called from server.ps1,
# open to everybody because this is how people sign in). After sign-in: /api/sso-ms-offer, /api/sso-ms-choice, /api/sso-ms-mine (any signed-in person).
# Data files: sso-settings.json, sso-logo.svg/png, sso-ms-choice.json. Microsoft calls: login.microsoftonline.com (token endpoint),
# and Microsoft Graph PATCH /applications/{id} to add the redirect address (needs Application.ReadWrite.All or being an owner of the app).
try { Add-Type -AssemblyName System.Web, System.Security -ErrorAction Stop } catch {}   # HttpUtility (form posts) and SignedXml (SAML signatures)
# SsoPending = sign-in attempts in progress (state / nonce / SAML request id), kept in memory for 10 minutes.
$script:SsoFile = Join-Path $Root 'sso-settings.json'
$script:SsoPending = @{}
# Loads sso-settings.json over safe defaults. Returns the settings (mode off/oidc/saml, portal address, OIDC values, SAML values, role mapping).
# The OIDC client secret is kept encrypted (oidcSecretEnc). Fills in default portal address and SAML entity id when empty.
function Get-SsoCfg {
    $c = [ordered]@{ mode = 'off'; ssoOnly = $false; baseUrl = ''; button = 'Sign in with Microsoft'; defaultRole = ''
        oidcTenant = ''; oidcClientId = ''; oidcSecretEnc = ''; oidcUseMsApp = $false
        samlEntityId = ''; samlIdpEntityId = ''; samlIdpSsoUrl = ''; samlIdpCerts = @(); samlMetaName = ''
        mapAdmin = ''; mapHelpdesk = ''; mapReadonly = ''; mapLogviewer = ''; msOffer = 'admins' }
    if (Test-Path $script:SsoFile) { try { $j = Get-Content $script:SsoFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } } } catch {} }
    $c.samlIdpCerts = @($c.samlIdpCerts | Where-Object { $_ })
    if (-not $c.baseUrl) { $c.baseUrl = Get-SsoDefaultBase }
    if (-not $c.samlEntityId) { $c.samlEntityId = "$($c.baseUrl.TrimEnd('/'))/sso/saml" }
    $c
}
# v2.6.1: "Use the Microsoft app from Connections" - OIDC takes tenant, client ID and secret from Settings > Connections > Microsoft app
# (read live, so a renewed secret there is used here too). Your own OIDC values stay saved and come back when the box is unticked.
# Returns the Microsoft app saved under Settings > Connections (if it has tenant, client id and secret), else $null.
function Get-SsoMsApp { try { $a = Get-MsAppCfg; if ("$($a.clientId)" -and "$($a.tenant)" -and "$($a.secretEnc)") { return $a } } catch {}; $null }
# If 'use the Microsoft app' is ticked, replaces the OIDC tenant / client id / secret by the Connections app's values (read live).
function Resolve-SsoOidc($c) {
    if (-not $c.oidcUseMsApp) { return $c }
    $a = Get-SsoMsApp; if (-not $a) { throw 'Single sign-on uses the Microsoft app from Settings > Connections, but that app has no tenant, client ID or secret saved.' }
    $c.oidcTenant = "$($a.tenant)"; $c.oidcClientId = "$($a.clientId)"; $c.oidcSecretEnc = "$($a.secretEnc)"; $c
}
# adds https://<portal>/sso/oidc/callback as a Web redirect URI of the Microsoft app (uses the Microsoft 365 sign-in; needs Application.ReadWrite.All or app owner)
# Adds the portal's /sso/oidc/callback address to the Microsoft app as a Web redirect URI, using the admin's Microsoft 365 sign-in (Graph).
# Returns a message for the page (success, already there, or what to do by hand). Never throws.
function Add-SsoRedirectToMsApp($clientId, $uri) {
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue) -or -not $script:Who) { return "Sign in to Microsoft 365 (Settings > Connections) so the sign-in address can be added to the app automatically - or add $uri as a Web redirect URI of the app yourself." }
    try {
        $r = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$clientId'&`$select=id,web" -ErrorAction Stop
        $app = @($r.value)[0]; if (-not $app) { return "The app $clientId was not found in this tenant - add $uri as a Web redirect URI yourself." }
        $have = @($app.web.redirectUris | Where-Object { $_ })
        if ($have -contains $uri) { return 'The sign-in address is already in the Microsoft app.' }
        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" -Body (@{ web = @{ redirectUris = @($have + $uri) } } | ConvertTo-Json -Depth 5) -ContentType 'application/json' -ErrorAction Stop | Out-Null
        "The sign-in address $uri was added to the Microsoft app (Web platform)."
    } catch { "Could not add the sign-in address to the app automatically ($($_.Exception.Message)). In Entra ID > App registrations > the app > Authentication, add $uri under Web." }
}
# Default portal address: the HTTPS host + port from the HTTPS settings if enabled, otherwise http://localhost:<port>.
function Get-SsoDefaultBase { try { $h = Get-HttpsCfg; if ($h.enabled) { return "https://$(if ($h.host) { $h.host } else { $env:COMPUTERNAME }):$($h.port)" } } catch {}; "http://localhost:$Port" }
# Settings for the page: everything except the secret and certificates, plus ready-made addresses to copy into Entra (redirect, ACS, metadata)
# and a readable list of the uploaded SAML certificates.
function Get-SsoView($c) {
    $o = [ordered]@{}; foreach ($k in $c.Keys) { if ($k -ne 'oidcSecretEnc' -and $k -ne 'samlIdpCerts') { $o[$k] = $c[$k] } }
    $o.hasSecret = [bool]$c.oidcSecretEnc; $ma = Get-SsoMsApp; $o.msApp = $(if ($ma) { @{ tenant = "$($ma.tenant)"; clientId = "$($ma.clientId)" } } else { $null }); $o.logo = [bool](Get-SsoLogo); $b = "$($c.baseUrl)".TrimEnd('/')
    $o.oidcRedirect = "$b/sso/oidc/callback"; $o.samlAcs = "$b/sso/saml/acs"; $o.samlMetaUrl = "$b/sso/saml/metadata"; $o.signOnUrl = "$b/"
    $o.samlCerts = @($c.samlIdpCerts | ForEach-Object { try { $x = New-Object Security.Cryptography.X509Certificates.X509Certificate2(, [Convert]::FromBase64String("$_")); "$($x.Subject) - until $($x.NotAfter.ToString('yyyy-MM-dd')) - $($x.Thumbprint)" } catch { 'unreadable certificate' } })
    $o
}
# Random text (24 random bytes, base64 without + / =) used for the OIDC state and nonce.
function New-SsoRandom { $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ([Convert]::ToBase64String($b) -replace '[+/=]', '') }
# Handler /api/sso-get. No input. Sends the current SSO settings (without secrets).
$ScreenHandlers['/api/sso-get'] = { Send $ctx @{ ok = $true; settings = (Get-SsoView (Get-SsoCfg)) } }
# Handler /api/sso-save. Input $d: mode (off/oidc/saml), baseUrl, button,
# oidcTenant, oidcClientId, oidcSecret, oidcUseMsApp, samlEntityId, msOffer, ssoOnly. Validates, saves sso-settings.json. Sends { ok, note, settings }.
$ScreenHandlers['/api/sso-save'] = {
    $c = Get-SsoCfg
    $m = "$($d.mode)"; if ($m -notin 'off', 'oidc', 'saml') { throw 'Choose Off, OpenID Connect or SAML.' }
    # Portal address: http(s)://host[:port] with no path; a trailing slash is removed.
    $b = "$($d.baseUrl)".Trim().TrimEnd('/'); if ($b -notmatch '^https?://[A-Za-z0-9.-]+(:\d+)?$') { throw 'The portal address must look like https://admin.contoso.com or https://admin.contoso.com:8443 (no path).' }
    # Button text is cut to 40 characters.
    $c.baseUrl = $b; $c.button = $(if ("$($d.button)".Trim()) { "$($d.button)".Trim().Substring(0, [Math]::Min(40, "$($d.button)".Trim().Length)) } else { 'Sign in with Microsoft' })
    # v2.8.1: the old role mapping / "everyone else" role are switched off for good (people are added in Settings > Users).
    $c.defaultRole = ''; foreach ($k in 'mapAdmin', 'mapHelpdesk', 'mapReadonly', 'mapLogviewer') { $c[$k] = '' }
    $c.oidcTenant = "$($d.oidcTenant)".Trim(); $c.oidcClientId = "$($d.oidcClientId)".Trim()
    # A new secret is stored encrypted with DPAPI; an empty box keeps the saved one.
    if ("$($d.oidcSecret)") { $c.oidcSecretEnc = Protect-MailSecret "$($d.oidcSecret)" }
    if ("$($d.samlEntityId)".Trim()) { $c.samlEntityId = "$($d.samlEntityId)".Trim() }
    $c.oidcUseMsApp = [bool]$d.oidcUseMsApp; $note = ''
    # OIDC checks: with the Connections app, also add the redirect address to it; with own values, tenant must be a name/GUID and the client id a GUID.
    if ($m -eq 'oidc' -and $c.oidcUseMsApp) {
        $ma = Get-SsoMsApp; if (-not $ma) { throw 'The Microsoft app in Settings > Connections is not complete (tenant, client ID and secret). Fill it in there first, or untick "Use the Microsoft app".' }
        $note = Add-SsoRedirectToMsApp "$($ma.clientId)" "$b/sso/oidc/callback"
    } elseif ($m -eq 'oidc') {
        if ($c.oidcTenant -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{1,100}$') { throw 'Type the Directory (tenant) ID.' }
        if ($c.oidcClientId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Type the Application (client) ID - a GUID.' }
        if (-not $c.oidcSecretEnc) { throw 'Type the client secret (its Value).' }
    }
    # SAML needs the Entra metadata first (sign-on address and signing certificate).
    if ($m -eq 'saml' -and (-not $c.samlIdpSsoUrl -or -not @($c.samlIdpCerts).Count)) { throw 'Upload the Federation Metadata XML of the Entra enterprise app first.' }
    # v2.8.1: when SSO is on but no portal user has a single sign-on account yet, tell the administrator (the owner login still works).
    if ($m -ne 'off' -and -not @(Read-ToolUsers | Where-Object { "$($_.ssoUpn)" }).Count) { $note = 'Nobody can sign in with single sign-on yet: add a user with a single sign-on account in Settings > Users.' }
    if ("$($d.msOffer)" -in 'admins', 'all', 'off') { $c.msOffer = "$($d.msOffer)" }
    $c.mode = $m; $c.ssoOnly = [bool]($d.ssoOnly -and $m -ne 'off')   # v1.98.33: only single sign-on on the sign-in page
    ($c | ConvertTo-Json -Depth 4) | Out-File $script:SsoFile -Encoding utf8
    if (Get-Command Write-ActRow -ErrorAction SilentlyContinue) { Write-ActRow 'Settings' 'Single sign-on' $m 'Saved' '' }
    Send $ctx @{ ok = $true; note = $note; settings = (Get-SsoView $c) }
}
# Handler /api/sso-metadata. Input $d.xml = the Federation Metadata XML of the Entra enterprise app, $d.name = file name.
# Reads the IdP entity id, the HTTP-Redirect sign-on address and the signing certificate(s) and saves them. Sends { ok, settings, message }.
$ScreenHandlers['/api/sso-metadata'] = {
    # { xml } - the Federation Metadata XML of the Entra enterprise application (SAML)
    $t = "$($d.xml)"; if ($t.Length -lt 50 -or $t.Length -gt 2MB) { throw 'That does not look like a metadata XML file.' }
    # XmlResolver = $null switches off external entities / DTDs (protects against XML attacks). Same in the SAML answer below.
    $x = New-Object Xml.XmlDocument; $x.XmlResolver = $null
    try { $x.LoadXml($t) } catch { throw "The XML could not be read: $($_.Exception.Message)" }
    $ns = New-Object Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace('md', 'urn:oasis:names:tc:SAML:2.0:metadata'); $ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')
    $ed = $x.SelectSingleNode('//md:EntityDescriptor', $ns); if (-not $ed) { throw 'No EntityDescriptor in the file - download "Federation Metadata XML" from the enterprise app > Single sign-on > SAML Certificates.' }
    $idp = $ed.SelectSingleNode('md:IDPSSODescriptor', $ns); if (-not $idp) { throw 'No IDPSSODescriptor in the file.' }
    $sso = $idp.SelectSingleNode("md:SingleSignOnService[@Binding='urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect']", $ns); if (-not $sso) { throw 'No HTTP-Redirect sign-on address in the file.' }
    $certs = @($idp.SelectNodes("md:KeyDescriptor[not(@use) or @use='signing']//ds:X509Certificate", $ns) | ForEach-Object { ($_.InnerText -replace '\s', '') } | Select-Object -Unique)
    if (-not $certs.Count) { throw 'No signing certificate in the file.' }
    $c = Get-SsoCfg; $c.samlIdpEntityId = "$($ed.GetAttribute('entityID'))"; $c.samlIdpSsoUrl = "$($sso.GetAttribute('Location'))"; $c.samlIdpCerts = $certs; $c.samlMetaName = "$($d.name)"
    ($c | ConvertTo-Json -Depth 4) | Out-File $script:SsoFile -Encoding utf8
    Send $ctx @{ ok = $true; settings = (Get-SsoView $c); message = "Read: $($certs.Count) signing certificate(s), sign-on address $($c.samlIdpSsoUrl)" }
}

# ---- the sign-in itself (called from server.ps1 for /sso/...) ----
# Sends a small result page after SSO: on success it jumps to the tool ('/'), otherwise it shows the message with a link back. The message is HTML-encoded.
function Send-SsoPage($ctx, [string]$title, [string]$msg, [bool]$ok) {
    $go = if ($ok) { '<script>location.replace("/")</script>' } else { '<p><a href="/">Back to the sign-in page</a></p>' }
    $h = "<!doctype html><html><head><meta charset='utf-8'><title>Admin Console</title></head><body style='font-family:Segoe UI,Arial;text-align:center;margin-top:18vh;background:#0b1120;color:#e5e9f0'><h2>$([Net.WebUtility]::HtmlEncode($title))</h2><p style='color:#94a3b8'>$([Net.WebUtility]::HtmlEncode($msg))</p>$go</body></html>"
    $b = [Text.Encoding]::UTF8.GetBytes($h); $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.Headers.Add('Cache-Control', 'no-store'); $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
}
# Answers with an HTTP 302 redirect to $url (never cached).
function Send-SsoRedirect($ctx, [string]$url) { $ctx.Response.StatusCode = 302; $ctx.Response.Headers.Add('Location', $url); $ctx.Response.Headers.Add('Cache-Control', 'no-store'); $ctx.Response.Close() }
# Is this Microsoft account linked to a portal user (Settings > Users)? Such a person may sign in even without a role mapping.
function Test-SsoLinked($name) { foreach ($x in (Read-ToolUsers)) { if ("$($x.ssoUpn)".Trim() -and "$($x.ssoUpn)".Trim() -ieq "$name".Trim()) { return $true } }; $false }   # v2.5.2
# v2.8.1: there is no role mapping any more. Who may sign in with SAML / OIDC is decided ONLY by the users created in Settings > Users
# (their "single sign-on account"); the role and permissions come from that user. This always returns '' (kept so older calls still work).
function Get-SsoRole($c, $roles, $groups) { '' }
# Creates the portal session after a successful Microsoft sign-in. Inputs: $name (account), $role, $how ('OIDC' or 'SAML').
# Returns $null on success or a message why the person may not sign in (linked portal user disabled / expired / AD problem).
function Start-SsoSession($ctx, $name, $role, $how) {
    # v2.0.0: many people can be signed in at the same time - a new, empty session of their own
    if ($script:Session) { try { Exit-StGraph 'Microsoft sign-out (new portal sign-in in this browser)'; Clear-Who; Clear-Ad } catch {} }
    # v2.5.2: a portal user (Settings > Users) LINKED to this Microsoft account: the person gets that user's role, permissions,
    # expiry and Microsoft / AD accounts. A disabled or expired linked user cannot sign in.
    $tool = $null; foreach ($x in (Read-ToolUsers)) { if ("$($x.ssoUpn)".Trim() -and "$($x.ssoUpn)".Trim() -ieq "$name".Trim()) { $tool = $x; break } }
    if ($tool) {
        if ($tool.enabled -eq $false) { Write-LoginLog $name "Refused ($how): linked portal user $($tool.username) is disabled"; return "Your portal account ($($tool.username)) is disabled. Ask an administrator." }
        $blk = Get-ToolUserBlock $tool -Login; if ($blk) { Write-LoginLog $name "Refused ($how): $blk"; return $blk }
    } else { Write-LoginLog $name "Refused ($how): not linked to a portal user"; return "$name is not linked to a portal user. Ask an administrator to add you in Settings > Users." }   # v2.8.1: linked users only
    Reset-SessVars
    # New session: random token, start time, and the client's IP / PC / browser. The cookie below is HttpOnly (not readable by scripts) and SameSite=Lax.
    $script:Session = New-SessToken; $script:SessStart = Get-Date; $script:SessLast = $script:SessStart; $script:SessIp = $script:ClientIp; $script:SessPc = $script:ClientPc; $script:SessUa = "$($ctx.Request.UserAgent)"
    # Linked portal user: the person gets that user's role and permissions and last-login is updated. Otherwise the role comes from the mapping.
    if ($tool) { Set-SessUser $tool; $script:SessUser.sso = $how; $script:SessUser.toolUser = $true; $script:SessUser.mustChange = $false; $role = "$($tool.role)"; try { Set-UserLastLogin "$($tool.username)" } catch {}; $name = "$($tool.username) ($name)" }
    else { $script:SessUser = @{ name = $name; owner = $false; role = $role; perms = @($script:RoleDefs[$role].perms); mustChange = $false; sso = $how } }
    $sec = Get-CookieSecure $ctx   # v2.4.0: X-Forwarded-Proto trusted only from IIS on this server
    $ctx.Response.Headers.Add('Set-Cookie', "sid=$($script:Session); Path=/; HttpOnly; SameSite=Lax$sec")
    Write-LoginLog $name "Success ($how, role $role)"
    # If the portal user has an AD account assigned, connect to AD for them now.
    if ($tool) { try { Connect-AssignedAd $tool } catch {} }
    $null
}
# Router for all /sso/... pages (called from server.ps1 before sign-in). Inputs: $ctx, $path. Always answers with a page or a redirect.
function Invoke-SsoRoute($ctx, $path) {
    $c = Get-SsoCfg; $qs = $ctx.Request.QueryString; $b = "$($c.baseUrl)".TrimEnd('/')
    # Forget sign-in attempts older than 10 minutes.
    foreach ($k in @($script:SsoPending.Keys)) { if (((Get-Date) - $script:SsoPending[$k].at).TotalMinutes -gt 10) { $script:SsoPending.Remove($k) } }
    switch ($path) {
        # OIDC step 1: remember a random state + nonce, then send the browser to Microsoft's authorize page (authorization code flow).
        '/sso/oidc/start' {
            try { $c = Resolve-SsoOidc $c } catch { Send-SsoPage $ctx 'Single sign-on is not ready' "$($_.Exception.Message)" $false; return }
            if ($c.mode -ne 'oidc') { Send-SsoPage $ctx 'Single sign-on is off' 'OpenID Connect is not turned on in Settings > Single sign-on.' $false; return }
            $st = New-SsoRandom; $nonce = New-SsoRandom; $script:SsoPending[$st] = @{ nonce = $nonce; at = Get-Date }
            $q = "client_id=$([uri]::EscapeDataString($c.oidcClientId))&response_type=code&response_mode=query&scope=$([uri]::EscapeDataString('openid profile email'))&redirect_uri=$([uri]::EscapeDataString("$b/sso/oidc/callback"))&state=$st&nonce=$nonce&prompt=select_account"
            Send-SsoRedirect $ctx "https://login.microsoftonline.com/$($c.oidcTenant)/oauth2/v2.0/authorize?$q"; return
        }
        # OIDC step 2: Microsoft sends the browser back here with a code. The code is exchanged for tokens at the token endpoint (TLS),
        # then the ID token is checked: audience, nonce, issuer, tenant and expiry. Any problem shows 'Sign-in failed'.
        '/sso/oidc/callback' {
            try {
                $c = Resolve-SsoOidc $c
                if ($qs['error']) { throw "$($qs['error']): $($qs['error_description'])" }
                $st = "$($qs['state'])"; $p = $script:SsoPending[$st]; if (-not $st -or -not $p) { throw 'The sign-in expired or did not start here - try again.' }; $script:SsoPending.Remove($st)
                # Exchange the code for an ID token (needs the client secret, decrypted only here).
                $r = Invoke-MsToken @{ client_id = $c.oidcClientId; client_secret = (Unprotect-MailSecret $c.oidcSecretEnc); grant_type = 'authorization_code'; code = "$($qs['code'])"; redirect_uri = "$b/sso/oidc/callback"; scope = 'openid profile email' } $c.oidcTenant
                # Read the ID token's middle part (the claims): base64url -> base64 (fix - _ and add = padding) -> JSON. The signature is not checked
                # because the token came directly from Microsoft over TLS.
                $pl = ("$($r.id_token)" -split '\.')[1]; $pl = $pl.Replace('-', '+').Replace('_', '/'); while ($pl.Length % 4) { $pl += '=' }
                $cl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pl)) | ConvertFrom-Json
                if ("$($cl.aud)" -ne $c.oidcClientId) { throw 'The token is not for this application.' }
                if ("$($cl.nonce)" -ne $p.nonce) { throw 'The sign-in answer does not match (nonce).' }
                # Issuer must be Microsoft's v2.0 endpoint of a tenant GUID.
                if ("$($cl.iss)" -notmatch '^https://login\.microsoftonline\.com/[0-9a-f-]{36}/v2\.0$') { throw 'The token comes from an unknown issuer.' }
                if ($c.oidcTenant -match '^[0-9a-fA-F-]{36}$' -and "$($cl.tid)" -ne $c.oidcTenant) { throw 'The account is from another tenant.' }
                if ([DateTimeOffset]::FromUnixTimeSeconds([int64]$cl.exp).UtcDateTime -lt [datetime]::UtcNow) { throw 'The token has expired.' }
                # Account name = sign-in name, else e-mail, else the object id. Role comes from the token's roles and groups claims.
                $name = "$(if ($cl.preferred_username) { $cl.preferred_username } elseif ($cl.email) { $cl.email } else { $cl.oid })"
                $role = Get-SsoRole $c @($cl.roles) @($cl.groups)
                if (-not (Test-SsoLinked $name)) { Write-LoginLog $name 'Refused (OIDC - not a portal user)'; throw "$name is not a portal user. An administrator must add you in Settings > Users with this Microsoft account as your single sign-on account." }
                $why = Start-SsoSession $ctx $name $role 'OIDC'; if ($why) { throw $why }
                # Remember the Entra admin role ids (wids claim) for the 'connect Microsoft 365?' offer.
                Set-SsoMsInfo $name @($cl.wids)
                Send-SsoPage $ctx 'Signed in' "Welcome, $name." $true
            } catch { Send-SsoPage $ctx 'Sign-in failed' "$($_.Exception.Message)" $false }
            return
        }
        # SP metadata XML: the file you give to Entra to set up the enterprise app (entity id and reply address).
        '/sso/saml/metadata' {
            $x = "<?xml version=`"1.0`"?><md:EntityDescriptor xmlns:md=`"urn:oasis:names:tc:SAML:2.0:metadata`" entityID=`"$([Security.SecurityElement]::Escape($c.samlEntityId))`"><md:SPSSODescriptor AuthnRequestsSigned=`"false`" WantAssertionsSigned=`"true`" protocolSupportEnumeration=`"urn:oasis:names:tc:SAML:2.0:protocol`"><md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</md:NameIDFormat><md:AssertionConsumerService Binding=`"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST`" Location=`"$([Security.SecurityElement]::Escape("$b/sso/saml/acs"))`" index=`"0`" isDefault=`"true`"/></md:SPSSODescriptor></md:EntityDescriptor>"
            $by = [Text.Encoding]::UTF8.GetBytes($x); $ctx.Response.ContentType = 'application/samlmetadata+xml'; $ctx.Response.OutputStream.Write($by, 0, $by.Length); $ctx.Response.Close(); return
        }
        # SAML step 1: build an AuthnRequest with a new ID, compress it (Deflate), base64 + URL-encode it and redirect to Entra (HTTP-Redirect binding).
        '/sso/saml/start' {
            if ($c.mode -ne 'saml') { Send-SsoPage $ctx 'Single sign-on is off' 'SAML is not turned on in Settings > Single sign-on.' $false; return }
            $id = '_' + [guid]::NewGuid().ToString('N'); $script:SsoPending[$id] = @{ at = Get-Date }
            $req = "<samlp:AuthnRequest xmlns:samlp=`"urn:oasis:names:tc:SAML:2.0:protocol`" xmlns:saml=`"urn:oasis:names:tc:SAML:2.0:assertion`" ID=`"$id`" Version=`"2.0`" IssueInstant=`"$([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`" Destination=`"$([Security.SecurityElement]::Escape($c.samlIdpSsoUrl))`" AssertionConsumerServiceURL=`"$([Security.SecurityElement]::Escape("$b/sso/saml/acs"))`" ProtocolBinding=`"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST`"><saml:Issuer>$([Security.SecurityElement]::Escape($c.samlEntityId))</saml:Issuer></samlp:AuthnRequest>"
            $ms = New-Object IO.MemoryStream; $df = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Compress); $rb = [Text.Encoding]::UTF8.GetBytes($req); $df.Write($rb, 0, $rb.Length); $df.Close()
            $sep = if ($c.samlIdpSsoUrl -match '\?') { '&' } else { '?' }
            Send-SsoRedirect $ctx "$($c.samlIdpSsoUrl)$($sep)SAMLRequest=$([uri]::EscapeDataString([Convert]::ToBase64String($ms.ToArray())))"; return
        }
        # SAML step 2 (Assertion Consumer Service): Entra POSTs the answer here. Checks, in order: status success, exactly one assertion,
        # XML signature, time window (5 minutes tolerance), audience, no replay, request id, destination. Then reads name and roles.
        '/sso/saml/acs' {
            try {
                if ($c.mode -ne 'saml') { throw 'SAML is not turned on.' }
                # The POST body (saved by server.ps1) holds SAMLResponse; decode and load it as XML (external entities off).
                $form = [Web.HttpUtility]::ParseQueryString("$($script:SsoRawBody)"); $sr = "$($form['SAMLResponse'])"; if (-not $sr) { throw 'No SAML answer was received.' }
                $x = New-Object Xml.XmlDocument; $x.PreserveWhitespace = $true; $x.XmlResolver = $null; $x.LoadXml([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sr)))
                $ns = New-Object Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace('p', 'urn:oasis:names:tc:SAML:2.0:protocol'); $ns.AddNamespace('a', 'urn:oasis:names:tc:SAML:2.0:assertion'); $ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')
                $resp = $x.DocumentElement; if ($resp.LocalName -ne 'Response') { throw 'Not a SAML response.' }
                $stc = $resp.SelectSingleNode('p:Status/p:StatusCode', $ns); if ("$($stc.GetAttribute('Value'))" -notmatch ':Success$') { throw "Microsoft answered: $($stc.GetAttribute('Value')) $($resp.SelectSingleNode('p:Status/p:StatusMessage', $ns).InnerText)" }
                $as = @($resp.SelectNodes('a:Assertion', $ns)); if ($as.Count -ne 1 -or $x.SelectNodes('//a:Assertion', $ns).Count -ne 1) { throw 'The answer must contain exactly one assertion.' }
                $a = $as[0]
                # (Signature check, in the next lines.) Each candidate signature must have exactly one reference pointing to its own element's ID.
                # signature: on the assertion, or on the whole response - and it must cover exactly that element (no XML wrapping)
                $certs = @($c.samlIdpCerts | ForEach-Object { New-Object Security.Cryptography.X509Certificates.X509Certificate2(, [Convert]::FromBase64String("$_")) })
                $okSig = $false
                foreach ($pair in @(@($a, $a.SelectSingleNode('ds:Signature', $ns)), @($resp, $resp.SelectSingleNode('ds:Signature', $ns)))) {
                    $el = $pair[0]; $sg = $pair[1]; if (-not $sg) { continue }
                    $refs = @($sg.SelectNodes('ds:SignedInfo/ds:Reference', $ns)); if ($refs.Count -ne 1 -or "$($refs[0].GetAttribute('URI'))" -ne ('#' + $el.GetAttribute('ID'))) { continue }
                    if ($x.SelectNodes("//*[@ID='$($el.GetAttribute('ID'))']").Count -ne 1) { throw 'Duplicate IDs in the SAML answer.' }
                    # Verify with the certificates from the uploaded metadata. The second argument ($true) only checks the signature, not certificate trust,
                    # because the certificate is the one we pinned from the metadata.
                    $sx = New-Object Security.Cryptography.Xml.SignedXml($el); $sx.LoadXml([Xml.XmlElement]$sg)
                    foreach ($ce in $certs) { if ($sx.CheckSignature($ce, $true)) { $okSig = $true; break } }
                    if ($okSig) { break }
                }
                if (-not $okSig) { throw 'The SAML signature is not valid for the certificate in the uploaded metadata (did the Entra certificate change? Upload the metadata again).' }
                # Time checks allow 5 minutes difference between the clocks of Entra and this server.
                $now = [datetime]::UtcNow; $skew = [TimeSpan]::FromMinutes(5)
                $cd = $a.SelectSingleNode('a:Conditions', $ns)
                if ($cd) { if ($cd.GetAttribute('NotBefore') -and [datetime]::Parse($cd.GetAttribute('NotBefore')).ToUniversalTime() -gt $now + $skew) { throw 'The SAML answer is not valid yet (check the clock of this server).' }
                    if ($cd.GetAttribute('NotOnOrAfter') -and [datetime]::Parse($cd.GetAttribute('NotOnOrAfter')).ToUniversalTime() -lt $now - $skew) { throw 'The SAML answer has expired - try again.' }
                    $aud = @($cd.SelectNodes('a:AudienceRestriction/a:Audience', $ns) | ForEach-Object { $_.InnerText.Trim() }); if ($aud.Count -and $aud -notcontains $c.samlEntityId) { throw "The answer is for another application ($($aud -join ', ')) - the Identifier (Entity ID) in Entra must be $($c.samlEntityId)." } }
                $na = [datetime]::UtcNow; try { if ($cd -and $cd.GetAttribute('NotOnOrAfter')) { $na = [datetime]::Parse($cd.GetAttribute('NotOnOrAfter')).ToUniversalTime() } } catch {}
                # Each assertion may be used once only.
                if (Test-SamlReplay "$($a.GetAttribute('ID'))" $na) { throw 'This SAML answer was already used - sign in again.' }   # v2.4.0: no replay
                # InResponseTo must be an ID we created in /sso/saml/start (stops answers meant for other sign-ins).
                $irt = "$($resp.GetAttribute('InResponseTo'))"; if ($irt) { if (-not $script:SsoPending[$irt]) { throw 'The sign-in expired or did not start here - try again.' }; $script:SsoPending.Remove($irt) }
                $dst = "$($resp.GetAttribute('Destination'))"; if ($dst -and $dst -ne "$b/sso/saml/acs") { throw "The answer was sent to $dst - the Reply URL in Entra must be $b/sso/saml/acs." }
                # Helper: all values of one SAML attribute (claim) by name.
                $attr = { param($n) @($a.SelectNodes("a:AttributeStatement/a:Attribute[@Name='$n']/a:AttributeValue", $ns) | ForEach-Object { $_.InnerText.Trim() }) }
                # Account name = the 'name' claim (UPN) if present, otherwise the NameID. Roles / groups claims decide the portal role.
                $name = "$($a.SelectSingleNode('a:Subject/a:NameID', $ns).InnerText)".Trim(); $upn = @(& $attr 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'); if ($upn.Count) { $name = $upn[0] }
                $role = Get-SsoRole $c (& $attr 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role') (& $attr 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups')
                if (-not (Test-SsoLinked $name)) { Write-LoginLog $name 'Refused (SAML - not a portal user)'; throw "$name is not a portal user. An administrator must add you in Settings > Users with this Microsoft account as your single sign-on account." }
                $why = Start-SsoSession $ctx $name $role 'SAML'; if ($why) { throw $why } ; Set-SsoMsInfo $name @()
                Send-SsoPage $ctx 'Signed in' "Welcome, $name." $true
            } catch { Send-SsoPage $ctx 'Sign-in failed' "$($_.Exception.Message)" $false }
            return
        }
    }
    Send-SsoPage $ctx 'Not found' '' $false
}

# Returns the uploaded sign-in button picture (sso-logo.svg or .png) or $null.
function Get-SsoLogo { foreach ($n in 'sso-logo.svg', 'sso-logo.png') { $f = Join-Path $Root $n; if (Test-Path $f) { return (Get-Item $f) } }; $null }
# Handler /api/sso-logo. Input $d.name + $d.data (base64) to upload, or $d.remove. Old picture is always removed first. Max 200 KB, SVG or PNG.
$ScreenHandlers['/api/sso-logo'] = {
    # { name, data (base64) } upload, or { remove:true } - the picture on the sign-in button (SVG or PNG, max 200 KB)
    foreach ($n in 'sso-logo.svg', 'sso-logo.png') { $f = Join-Path $Root $n; if (Test-Path $f) { Remove-Item $f -Force } }
    if ($d.remove) { Send $ctx @{ ok = $true; logo = $false }; return }
    $ext = [IO.Path]::GetExtension("$($d.name)").ToLower(); if ($ext -notin '.svg', '.png') { throw 'Use an SVG or PNG picture.' }
    $bytes = [Convert]::FromBase64String("$($d.data)"); if ($bytes.Length -gt 200KB) { throw 'The picture is too big (max 200 KB).' }
    # An SVG can contain scripts; refuse any with script, event handlers (onload=...), javascript: or foreignObject.
    if ($ext -eq '.svg') { $t = [Text.Encoding]::UTF8.GetString($bytes); if ($t -match '(?i)<script|on[a-z]+\s*=|javascript:|<foreignObject') { throw 'This SVG contains scripts - use a plain SVG or a PNG.' } }
    [IO.File]::WriteAllBytes((Join-Path $Root "sso-logo$ext"), $bytes)
    Send $ctx @{ ok = $true; logo = $true }
}

# v2.6.2: after a single sign-on, offer to connect Microsoft 365 with the SAME Microsoft account - never automatically.
# The person answers Yes / No; "Remember my choice" is kept for that one account only (sso-ms-choice.json), not for everyone.
# Who is asked (Settings > Single sign-on): 'admins' = Entra Global Administrator (or another Entra admin role) or portal administrator, 'all', 'off'.
# Per-account answer 'connect Microsoft 365 after SSO: yes / no' in sso-ms-choice.json.
$script:SsoChoiceFile = Join-Path $Root 'sso-ms-choice.json'
# Entra directory role ids (GUIDs) that count as 'admin roles' for the offer; the value is the role name shown to the person.
$script:EntraAdminRoles = @{ '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'; '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'; 'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'; '729827e3-9c14-49f7-bb1b-9608f156bbb8' = 'Helpdesk Administrator'; '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'; '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator'; '966707d0-3269-4727-9be2-8c3a10f19b9d' = 'Password Administrator'; 'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator' }
# Stores on the session which Entra admin roles the person has (from the wids claim) and that they were not asked yet.
function Set-SsoMsInfo($upn, $wids) {
    $r = @($wids | ForEach-Object { $script:EntraAdminRoles["$_"] } | Where-Object { $_ })
    if ($script:SessUser) { $script:SessUser.ssoUpn = "$upn"; $script:SessUser.entraRoles = $r; $script:SessUser.msAsked = $false }
}
# Reads the remembered yes / no answers (account name in lower case -> choice).
function Read-SsoChoices { $h = @{}; if (Test-Path $script:SsoChoiceFile) { try { $j = Get-Content $script:SsoChoiceFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $h[$p.Name.ToLower()] = "$($p.Value)" } } catch {} }; $h }
# Saves the remembered answers.
function Write-SsoChoices($h) { ($h | ConvertTo-Json) | Out-File $script:SsoChoiceFile -Encoding utf8 }
# Handler /api/sso-ms-offer. No input. Tells the page whether to ask 'Connect Microsoft 365 with the same account?' after an SSO sign-in.
# Asks only once per session, only for SSO sign-ins not yet connected, and only if the setting msOffer fits (all / admins / off). Sends { ask, upn, roles, remembered }.
$ScreenHandlers['/api/sso-ms-offer'] = {
    $u = $script:SessUser; $o = @{ ok = $true; ask = $false }
    if (-not $u -or -not $u.sso -or -not "$($u.ssoUpn)" -or $script:Who -or $u.msAsked) { Send $ctx $o; return }
    $c = Get-SsoCfg; $roles = @($u.entraRoles)
    $fits = switch ("$($c.msOffer)") { 'all' { $true } 'off' { $false } default { $roles.Count -gt 0 -or "$($u.role)" -eq 'admin' } }
    if (-not $fits) { Send $ctx $o; return }
    $u.msAsked = $true
    $o.upn = "$($u.ssoUpn)"; $o.roles = $roles; $o.remembered = "$((Read-SsoChoices)["$($u.ssoUpn)".ToLower()])"; $o.ask = $true
    Send $ctx $o
}
# Handler /api/sso-ms-choice. Input $d.choice (yes / no / forget), $d.remember. Saves or forgets the answer for this one account. Sends { ok, upn }.
$ScreenHandlers['/api/sso-ms-choice'] = {
    $u = $script:SessUser; if (-not $u -or -not "$($u.ssoUpn)") { throw 'You did not sign in with single sign-on.' }
    $ch = "$($d.choice)"; if ($ch -notin 'yes', 'no', 'forget') { throw 'Unknown choice.' }
    $h = Read-SsoChoices; $k = "$($u.ssoUpn)".ToLower()
    if ($ch -eq 'forget') { $h.Remove($k) } elseif ($d.remember) { $h[$k] = $ch }
    Write-SsoChoices $h
    if ($ch -ne 'forget' -and $d.remember) { try { Write-ActRow 'Settings' 'Microsoft 365 after single sign-on' "$($u.ssoUpn)" "Remembered: $ch" '' } catch {} }
    Send $ctx @{ ok = $true; upn = "$($u.ssoUpn)" }
}
# Handler /api/sso-ms-mine. No input. Sends the person's own SSO account and the answer remembered for it (empty if none).
$ScreenHandlers['/api/sso-ms-mine'] = { $u = $script:SessUser; $k = "$($u.ssoUpn)"; Send $ctx @{ ok = $true; upn = $k; remembered = $(if ($k) { "$((Read-SsoChoices)[$k.ToLower()])" } else { '' }) } }

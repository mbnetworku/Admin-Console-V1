# Screen-Https.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: HTTPS / SSL (Settings)
# Screen version: 2.8.0   (changes ONLY when this screen changes - not with every release)

# Settings > HTTPS / SSL certificate (administrators only)
#  * Upload a .pfx certificate (with its private key) - it is imported into the Windows certificate store of this computer
#    (Local Computer > Personal), where IIS can use it too. Or pick a certificate that is already there.
#  * Option A - the tool itself answers on https://<name>:<port>/ with that certificate (HTTP.sys binding, at the next start).
#  * Option B - IIS on a Windows Server in front of the tool (reverse proxy): download a ready web.config for the IIS site;
#    IIS holds the certificate, the tool stays on http://localhost:8080 behind it.

# WHAT THIS SCREEN DOES: Settings > HTTPS / SSL. Lets an administrator import a .pfx certificate, bind it to a port, or get an IIS web.config.
# ENDPOINTS: /api/ssl-info (read state), /api/ssl-upload (import .pfx), /api/ssl-save (save + bind), /api/ssl-iis (download web.config text).
# DATA: https-settings.json in the tool folder ($Root); Windows certificate store Cert:\LocalMachine\My; netsh http (HTTP.sys); Windows Firewall.
# PERMISSION: administrators only; import and binding also need the tool to be started 'as administrator' ($IsAdmin). No Graph/AD/Exchange calls.
#
# File that stores the HTTPS settings (enabled, port, host name, certificate thumbprint, redirect).
$script:HttpsFile = Join-Path $Root 'https-settings.json'
# Fixed GUID that identifies this tool to HTTP.sys when a certificate is bound to a port (netsh 'appid').
$script:HttpsAppId = '{6b8f0d3e-1d2c-4f0e-9a51-3c1a5d2e7a10}'
# Reads https-settings.json and returns the settings as an ordered hashtable. Defaults are used when the file is missing or damaged.
# Only keys that already exist in the defaults are copied, so unknown entries in the file are ignored.
function Get-HttpsCfg {
    $c = [ordered]@{ enabled = $false; port = 8443; host = ''; thumb = ''; redirect = $false }
    if (Test-Path $script:HttpsFile) { try { $j = Get-Content $script:HttpsFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } } } catch {} }
    $c.port = [int]$c.port; $c
}
# Turns a certificate object into a small summary for the web page (thumbprint, subject, dates, days left, SAN, self-signed flag).
# Returns $null when no certificate is given. 2.5.29.17 is the OID of the 'Subject Alternative Name' extension (the host names in the certificate).
function Get-CertView($x) {
    if (-not $x) { return $null }
    # Read the SAN list as readable text; a certificate without this extension just gives an empty text.
    $san = ''; try { $e = $x.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }; if ($e) { $san = $e.Format($false) } } catch {}
    [ordered]@{ thumb = "$($x.Thumbprint)"; subject = "$($x.Subject)"; issuer = "$($x.Issuer)"; friendly = "$($x.FriendlyName)"; from = $x.NotBefore.ToString('yyyy-MM-dd'); until = $x.NotAfter.ToString('yyyy-MM-dd')
        # daysLeft is negative once the certificate has expired; selfSigned means subject and issuer are identical.
        daysLeft = [int][math]::Floor(($x.NotAfter - (Get-Date)).TotalDays); hasKey = [bool]$x.HasPrivateKey; san = $san; selfSigned = ("$($x.Subject)" -eq "$($x.Issuer)") }
}
# Lists the certificates in Local Computer > Personal that have a private key (only those can be used for HTTPS), newest expiry first.
function Get-StoreCerts { @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.HasPrivateKey } | Sort-Object NotAfter -Descending) }
# Asks HTTP.sys (netsh) which certificate is bound to the given port on all addresses (0.0.0.0).
# Returns the thumbprint in upper case, or '' when nothing is bound or netsh fails.
function Get-SslBinding([int]$port) {
    try { $o = (& netsh http show sslcert ipport=0.0.0.0:$port 2>$null) -join "`n"; $m = [regex]::Match($o, 'Certificate Hash\s*:\s*([0-9a-fA-F]+)'); if ($m.Success) { return $m.Groups[1].Value.ToUpper() } } catch {}
    ''
}
# Binds a certificate (by thumbprint) to a port in HTTP.sys. Needs administrator rights. Throws with the netsh output if it fails.
function Set-SslBinding([int]$port, [string]$thumb) {
    # bind the certificate to the port in HTTP.sys (needs administrator) - replaces an older binding of the same port
    # Remove an older binding first, otherwise 'add' fails because the port is already bound. Errors are ignored on purpose (there may be none).
    & netsh http delete sslcert ipport=0.0.0.0:$port 2>&1 | Out-Null
    $o = (& netsh http add sslcert ipport=0.0.0.0:$port certhash=$thumb appid=$($script:HttpsAppId) certstorename=MY 2>&1) -join ' '
    # netsh does not always set a failing exit code, so the text is also checked for 'error' / 'fail'.
    if ($LASTEXITCODE -ne 0 -or $o -match 'error|fail') { throw "Binding the certificate to port $port failed: $o" }
}
# Endpoint: /api/ssl-info - no input. Sends the saved settings, the certificate currently selected, all usable store certificates,
# whether the tool runs as admin, the computer name / FQDN, the certificate really bound to the port (binding), and whether HTTPS is running now.
$ScreenHandlers['/api/ssl-info'] = {
    $c = Get-HttpsCfg; $cur = $null
    if ($c.thumb) { $cur = Get-CertView (Get-Item "Cert:\LocalMachine\My\$($c.thumb)" -ErrorAction SilentlyContinue) }
    Send $ctx @{ ok = $true; settings = $c; current = $cur; certs = @(Get-StoreCerts | ForEach-Object { Get-CertView $_ }); admin = [bool]$IsAdmin; computer = "$env:COMPUTERNAME"
        # FQDN lookup can fail (no DNS); then the plain computer name is used. 'binding' is only checked when HTTPS is switched on.
        fqdn = $(try { [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { "$env:COMPUTERNAME" }); binding = $(if ($c.enabled) { Get-SslBinding $c.port } else { '' }); running = [bool]$script:HttpsOn; httpPort = $Port }
}
# Endpoint: /api/ssl-upload - body { name, data (base64 of the .pfx), password, friendly }. Imports the certificate into the computer store.
# Sends { ok, cert, message }. Throws a readable error for wrong file type, empty/too big file, wrong password, no private key or expired certificate.
$ScreenHandlers['/api/ssl-upload'] = {
    # { name, data (base64 of the .pfx), password } - import into Local Computer > Personal (where IIS can use it too)
    if (-not $IsAdmin) { throw 'Start the tool as administrator to import a certificate into the computer store.' }
    # Only .pfx / .p12 files are accepted: a .cer / .crt has no private key, so it cannot be used for HTTPS.
    $name = "$($d.name)"; if ($name -notmatch '\.(pfx|p12)$') { throw 'Upload a .pfx (or .p12) file - it must contain the private key. A .cer / .crt file has no key and cannot be used for HTTPS.' }
    # Safety limit: 2 MB of base64 is far more than any real certificate file.
    $b64 = "$($d.data)"; if (-not $b64) { throw 'The file is empty.' }; if ($b64.Length -gt 2MB) { throw 'The file is too big for a certificate.' }
    $bytes = [Convert]::FromBase64String($b64)
    # MachineKeySet = keep the key in the computer store (not a user profile); PersistKeySet = keep the key after the import so IIS can use it.
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]'MachineKeySet, PersistKeySet'
    # Open the pfx with the given password. A failure here almost always means a wrong password.
    try { $x = New-Object Security.Cryptography.X509Certificates.X509Certificate2(, $bytes); $x.Import($bytes, "$($d.password)", $flags) } catch { throw "The certificate could not be opened - check the password. ($($_.Exception.Message))" }
    if (-not $x.HasPrivateKey) { throw 'This file has no private key - export the certificate WITH its private key (.pfx).' }
    # Refuse certificates that have already expired.
    if ($x.NotAfter -lt (Get-Date)) { throw "This certificate expired on $($x.NotAfter.ToString('yyyy-MM-dd'))." }
    if ("$($d.friendly)".Trim()) { $x.FriendlyName = "$($d.friendly)".Trim() }
    # Add the certificate to Local Computer > Personal; the store is always closed again, even on error.
    $st = New-Object Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine'); $st.Open('ReadWrite'); try { $st.Add($x) } finally { $st.Close() }
    # Write an entry in the activity log (only if the logging function is loaded).
    if (Get-Command Write-ActRow -ErrorAction SilentlyContinue) { Write-ActRow 'Settings' 'SSL certificate imported' "$($x.Subject)" "Done - thumbprint $($x.Thumbprint), valid until $($x.NotAfter.ToString('yyyy-MM-dd'))" '' }
    Send $ctx @{ ok = $true; cert = (Get-CertView $x); message = "Imported into Local Computer > Personal: $($x.Subject) (valid until $($x.NotAfter.ToString('yyyy-MM-dd')))." }
}
# Endpoint: /api/ssl-save - body { enabled, port, host, thumb, redirect }. Validates, binds the certificate (when enabled), opens the firewall
# and saves https-settings.json. The tool uses the settings at its NEXT start. Sends { ok, settings, message }.
$ScreenHandlers['/api/ssl-save'] = {
    # { enabled, port, host, thumb, redirect } - used at the next start of the tool
    $c = Get-HttpsCfg
    # Port must be a valid TCP port and must not be the tool's own http port.
    $p = [int]$d.port; if ($p -lt 1 -or $p -gt 65535) { throw 'Choose a port between 1 and 65535 (443 is the normal HTTPS port; 8443 if IIS already uses 443).' }
    if ($p -eq $Port) { throw "Port $Port is the tool's own http port - choose another (for example 8443 or 443)." }
    # Optional host name: letters, digits, dots and hyphens, starting and ending with a letter or digit (for example admin.contoso.com).
    $h = "$($d.host)".Trim(); if ($h -and $h -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,250}[A-Za-z0-9])?$') { throw 'The name must be a host name like admin.contoso.com.' }
    # Clean the thumbprint: remove spaces and hidden characters (often copied from the certificate dialog) and use upper case.
    $t = ("$($d.thumb)" -replace '[^0-9a-fA-F]', '').ToUpper()
    # Switching HTTPS ON: needs admin, a certificate with private key that is not expired; then bind it and open the firewall port.
    if ([bool]$d.enabled) {
        if (-not $IsAdmin) { throw 'Start the tool as administrator - binding a certificate to a port needs it.' }
        $x = Get-Item "Cert:\LocalMachine\My\$t" -ErrorAction SilentlyContinue; if (-not $x) { throw 'Choose a certificate (upload one, or pick one from the list).' }
        if (-not $x.HasPrivateKey) { throw 'That certificate has no private key.' }
        if ($x.NotAfter -lt (Get-Date)) { throw 'That certificate has expired.' }
        Set-SslBinding $p $t
        # Create an inbound firewall rule for the port once (skipped if the rule exists or the firewall cmdlets are missing; failures are ignored).
        try { if (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue) { $fn = "Admin Console HTTPS $p"; if (-not (Get-NetFirewallRule -DisplayName $fn -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName $fn -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow -Profile Domain, Private | Out-Null } } } catch {}   # other PCs can reach the port (domain / private networks)
    # Switching HTTPS OFF: remove the old binding of the previously saved port so it does not stay open.
    } elseif ($c.enabled -and $c.port) { try { & netsh http delete sslcert ipport=0.0.0.0:$($c.port) 2>&1 | Out-Null } catch {} }
    # Store the new values and write the settings file (UTF-8).
    $c.enabled = [bool]$d.enabled; $c.port = $p; $c.host = $h; $c.thumb = $t; $c.redirect = [bool]$d.redirect
    ($c | ConvertTo-Json) | Out-File $script:HttpsFile -Encoding utf8
    if (Get-Command Write-ActRow -ErrorAction SilentlyContinue) { Write-ActRow 'Settings' 'HTTPS settings' "port $p" $(if ($c.enabled) { "On - certificate $t" } else { 'Off' }) '' }
    Send $ctx @{ ok = $true; settings = $c; message = $(if ($c.enabled) { "Saved. The certificate is bound to port $p. Restart the tool (Session > Shut down, then Start.bat) - it then also answers on https://$(if ($h) { $h } else { $env:COMPUTERNAME }):$p/" } else { 'Saved - HTTPS is off.' }) }
}
# Endpoint: /api/ssl-iis - no input. Sends { ok, text } where text is a ready web.config for an IIS site that forwards to this tool
# (reverse proxy). $Port is filled into the text so the rewrite points to the right local port.
$ScreenHandlers['/api/ssl-iis'] = {
    # web.config for an IIS site in front of the tool (needs the IIS modules URL Rewrite and Application Request Routing, proxy enabled)
    $x = @"
<?xml version="1.0" encoding="UTF-8"?>
<!-- Admin Console behind IIS (reverse proxy). Needs: IIS URL Rewrite + Application Request Routing (ARR) with
     "Enable proxy" ticked (IIS Manager > server > Application Request Routing Cache > Server Proxy Settings).
     Bind the IIS site to https with your certificate (Site > Bindings > https). The tool keeps running on this server at http://localhost:$Port
     ARR Server Proxy Settings: keep "Preserve client IP in the following header: X-Forwarded-For" ticked (the IP allow-list needs it). -->
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="Force HTTPS" stopProcessing="true">
          <match url="(.*)" />
          <conditions><add input="{HTTPS}" pattern="off" /></conditions>
          <action type="Redirect" url="https://{HTTP_HOST}/{R:1}" redirectType="Permanent" />
        </rule>
        <rule name="Admin Console" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="http://localhost:$Port/{R:1}" />
        </rule>
      </rules>
    </rewrite>
    <security><requestFiltering><requestLimits maxAllowedContentLength="104857600" /></requestFiltering></security>
    <httpProtocol><customHeaders><remove name="X-Powered-By" /></customHeaders></httpProtocol>
  </system.webServer>
</configuration>
"@
    Send $ctx @{ ok = $true; text = $x }
}

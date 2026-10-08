# Admin Console - publish on IIS (Windows Server)

Architecture: browser -> IIS (https, port 443, your certificate) -> reverse proxy (URL Rewrite + ARR) -> Admin Console on the same server at http://localhost:8080 (runs as a scheduled task under a service account).

1. Server prep: Windows Server 2019/2022 joined to the domain; RSAT AD PowerShell; PowerShell modules Microsoft.Graph.Authentication + ExchangeOnlineManagement installed for the service account; DNS name (e.g. adminconsole.contoso.com) pointing to the server; certificate (.pfx) for that name.
2. Service account (e.g. CONTOSO\svc-adminconsole): local admin of the server (needed for the task) + delegated AD rights only on the OUs it manages (reset password, unlock, enable/disable, group membership). Not Domain Admin.
3. Copy the zip to C:\AdminConsole (unblock the zip first). Sign in as the service account once, run `Start-Visible.bat`, finish first setup (owner login), then Shut down.
4. `Install-Service.bat` (as admin) -> service account -> starts with Windows.
5. IIS: install the Web Server role; install URL Rewrite 2.1 and Application Request Routing 3.0; IIS Manager > server > Application Request Routing Cache > Server Proxy Settings > Enable proxy (keep X-Forwarded-For preserve ticked).
6. Import the certificate (Local Computer > Personal) - or use Settings > HTTPS / SSL in the portal.
7. Create the site: folder C:\inetpub\AdminConsole (empty), binding https 443 with the certificate + host name; optional http 80 (redirects).
8. Settings > HTTPS / SSL > Option B > download web.config -> put it into C:\inetpub\AdminConsole. (No IIS server variable is needed - the tool detects https from ARR's own X-ARR-SSL header.)
9. Firewall: allow 443 (and 80); block 8080 from other PCs.
10. Portal settings: Connections > Microsoft app (create automatically, redirect https://adminconsole.contoso.com/), Access and security (IP list, 2-step for admins), SSO (SAML reply URL https://adminconsole.contoso.com/sso/saml/acs, OIDC redirect https://adminconsole.contoso.com/sso/oidc/callback), users and roles, Lock the folder.
11. Test from another PC; check that "Who is signed in" shows the real PC IP.

Troubleshooting: 502.3 = tool not running; 500.19 = URL Rewrite not installed or bad web.config; 500 with an old web.config = replace it with the new one (no serverVariables); 404.13 = upload too big (maxAllowedContentLength); wrong IP in logs = X-Forwarded-For not preserved.

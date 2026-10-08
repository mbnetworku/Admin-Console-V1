# Admin Console - Technical Documents

Current package version: **2.11.11** (2026-10-08). Each screen has its own version (section 12). Version history: `docs/CHANGELOG.md` and Settings > Server > version history.

## 1. What it is

A PowerShell back end (`server.ps1`, built on `System.Net.HttpListener`) that serves one Web UI (`frontend/index.html`) on a local address. It is started by a `.bat` file that runs as a local administrator, because some configuration (HTTPS binding, service install, URL reservation, DPAPI machine key) needs local admin rights.

Everything runs on the support PC / server. The browser only talks to the local back end; the back end talks to Microsoft Graph, Exchange Online, SharePoint and Active Directory.

## 2. Requirements

| Item | Needed for |
|---|---|
| Windows 10/11 or Windows Server, Windows PowerShell 5.1 (PowerShell 7 is not required) | Everything |
| Local administrator | Start.bat, HTTPS, service, DPAPI |
| Microsoft Graph PowerShell module (installed on first start if missing) | Microsoft 365 screens |
| ExchangeOnlineManagement module | Exchange Online screens (only when used) |
| RSAT / domain-joined PC or server | On-premises AD screens (System.DirectoryServices is used) |
| A Microsoft Entra app registration (optional but recommended) | Sign-in from other PCs, single sign-on, Exchange, mailbox cleanup |

## 2b. Technology stack and versions

| Part | What is used | Version / note |
|---|---|---|
| This package | Admin Console | **2.11.11** (`$AppVersion` in server.ps1, `VERSION.txt`); every screen file has its own version |
| Back end language | Windows PowerShell | **5.1** (PowerShell 7 not required) |
| Web server | `System.Net.HttpListener` inside server.ps1 | .NET Framework of Windows (4.x); default port 8080; no IIS needed (IIS optional as reverse proxy) |
| Front end | **Plain JavaScript, no framework** (no React / Vue / Angular / jQuery) | One file `frontend/index.html` (HTML + CSS + JS, about 6,600 lines). Modern browser JavaScript (ECMAScript 2017+: `async/await`, arrow functions, template strings, `fetch`) - current Edge, Chrome or Firefox |
| Front end libraries | Only one: **qrcodejs 1.0.0** (cdnjs.cloudflare.com) | Used on `login.html` to draw the 2-step QR code. Everything else is hand-written, no npm / build step |
| Calls browser to server | `fetch` POST of JSON to `/api/...` | Session cookie `sid` |
| Microsoft 365 | Microsoft Graph PowerShell SDK: Authentication, Users, Identity.SignIns, Identity.DirectoryManagement | No fixed number: the tool finds the installed version (or the newest from PowerShell Gallery) and keeps ALL four modules on the SAME version |
| Exchange Online | ExchangeOnlineManagement module | Installed on demand |
| Active Directory | `System.DirectoryServices` (LDAP, ADSI) | Needs a domain-joined host; DC choice in Settings > Connections |
| Secrets | DPAPI LocalMachine | Same server only |
| Dev / test tools (not shipped) | `node --check`, Playwright with mocked APIs, pwsh on Linux with stubs, `Tools/release_check.py` (Python 3) | Real Windows behaviour must be tested on the server |

## 3. Folder layout

The package is split so that front end and back end are easy to tell apart:

```
PasswordReset/
  server.ps1                 THE SERVER (entry point): start-up, HTTP listener, sessions, routing, shared helpers
  Start.bat / Start-Visible.bat   start (admin) - the second keeps a window for troubleshooting
  Install-Service.bat        install as a Windows service (Tools\Install-Service.ps1)
  Allow-Tool.bat             firewall / URL reservation helper (Tools\Allow-Tool.ps1)
  Change-Login.bat           change the owner login (asks for the old one; runs as administrator)
  Reset-Password.bat         forgot the owner password: new login without the old one (runs as administrator)
  Revert-Update.bat          go back to an earlier version (Tools\Revert-Update.ps1)
  VERSION.txt

  frontend/                  FRONT END - what the browser shows
    index.html               the whole UI (one file: HTML + CSS + JS); the VERSIONS list = "What's new"
    login.html               sign-in page (password, 2-step code, Microsoft button)

  backend/                   BACK END - PowerShell, one Screen-*.ps1 file per screen
    Portal/                  settings, users, security, SSO, HTTPS, updates, activity log, email templates, app setup
    Microsoft365/            Cloud password, Account status, Revoke MFA, Licenses, Guests, Teams, Intune, OneDrive, Audit, Microsoft sign-in
    ExchangeOnline/          Distribution groups (+ worker), Shared mailbox, Address list, Mailbox cleanup
    ActiveDirectory/         On-premises AD, Create AD users, Accounts, Bulk CSV, Export report

  docs/                      ALL .md documents (README.md = index, this file, CHANGELOG.md, IIS guide, design notes)
  Tools/                     helper scripts used by the .bat files

  logs/ backups/ updates/ email-images/ DistributionGroups/   created at run time
  *.json  sso-logo.*                                        your settings (never overwritten by an update)
```

`Get-CodePath` in `server.ps1` maps every file to its folder; to add a screen, create `backend/<group>/Screen-<Name>.ps1` and add `<Name>` to `$ScreenFiles` and `$script:CodeDir`.

## 4. Start-up and request flow

1. `Start.bat` re-launches itself elevated, unblocks the files and runs `server.ps1`. Unless `Start-Visible.bat` is used the server restarts itself hidden and opens the page. Stop it with *Shut down* in the page (writes `shutdown.signal`).
2. `server.ps1` dot-sources every `Portal\`, `Microsoft365\`, `ExchangeOnline\` and `ActiveDirectory\` `Screen-*.ps1` file. Each screen registers its endpoints in the hash table `$ScreenHandlers['/api/...'] = { ... }`.
3. For every request: `Invoke-SecGate` (IP allow-list, HTTPS-only, size limits, security headers) > session cookie lookup (`Use-Sess`) > `Get-ApiNeed` permission check > handler > `Save-Sess`.
4. A new endpoint must be added to three places: the handler, `$AllowedApi` (server.ps1), and - when it is only a lookup or internal call - `$script:ActSkip` (backend/Portal/ActivityLog.ps1). Permissions: `Get-ApiNeed` / `$script:ApiOpen` in backend/Portal/Screen-Users.ps1.

Handlers run in script scope, so local variables must not use the names of per-session variables (`$script:PerSess`).

## 5. Sessions

- Each browser sign-in has its own session (`$script:Sessions`), holding the tool user, the Microsoft Graph connection, the AD credential, timeouts and the session-bound IP. `Use-Sess` loads it into script variables, `Save-Sess` stores it back.
- Cookie: `sid`, HttpOnly, `SameSite=Lax`, `Secure` when served over HTTPS (or behind IIS: `X-ARR-SSL` / `X-Forwarded-Proto` trusted only from the local IIS).
- The session can be tied to the client IP, expires after the portal timeout, and can be ended from *Who is signed in*.

## 6. Sign-in methods

| Method | Where | Notes |
|---|---|---|
| Local tool users | Settings > Users | Roles: owner, admin, helpdesk, readonly, logviewer + per-screen permissions. Passwords hashed. Optional 2-step (TOTP, RFC 6238). |
| AD users | Settings > Users | Signs in with the domain account. |
| Microsoft single sign-on, OIDC | Settings > Single sign-on | Authorization-code flow; ID token checked for audience, issuer, tenant, nonce, expiry. Can reuse the Microsoft app of Connections (same tenant / client ID / secret). |
| Microsoft single sign-on, SAML 2.0 | same | Signature checked with the uploaded federation metadata certificate; audience, time, destination and request ID checked; replay protection. |
| Linked users (the only way to use SSO since 2.8.1) | Settings > Users | A tool user gets a *Single sign-on account* (`ssoUpn`), optionally *SSO only*. Only linked people may sign in with OIDC/SAML; role and permissions come from the user. There is no role mapping in Settings > Single sign-on any more. |

After SSO the portal can ask (never automatically) whether to connect Microsoft 365 with the same account; the answer can be remembered per account (`sso-ms-choice.json`). Who is asked is set in Settings > Single sign-on.

## 6b. Which AD server (since 2.8.1)

Settings > Connections > *Domain controller (AD server)* saves `ad-server.json`. Every LDAP path is built with `Get-LdapPrefix` (`LDAP://` or `LDAP://dc01.contoso.com/`), RootDSE reads use `Get-RootDse`, and the domain root without typed AD sign-in uses `Get-AdDefaultRoot`. Never write `LDAP://RootDSE` or `LDAP://<dn>` directly in new code. Endpoint `/api/ad-server` (read for everyone; discover / test / save need the Settings permission).

## 7. Microsoft 365 connection

- **Sign-in options** (Settings > Connections): Microsoft page (authorization code + PKCE), Microsoft window (`Connect-MgGraph`), sign in with a code (device code). A certificate / app-only mode is also available.
- **Your own app** (`ms-app.json`): created or updated from *App setup* (existing app is updated, permissions are merged, never removed). The secret is validated and a new one is created if it is invalid. A public client never sends a secret (AADSTS700025).
- **Graph calls in the background**: `Start-GJob` runs long work in a job with `$global:GJobPrelude` (`Invoke-G` with retry on 429/503 using Retry-After, `Get-GAll` paging). The UI polls `/api/gjob`. Completion hooks are named `Complete-GJob_<kind>`.
- PowerShell 5.1 note: HTTP error bodies are read from `ErrorDetails.Message`.

## 8. Screens (what each does)

File names below are inside `backend/<group>/` (see section 3).

| Screen | File | Summary |
|---|---|---|
| Cloud password | Screen-CloudPassword.ps1 | Temporary password or TAP, or a new password in cloud + on-premises AD; e-mail to the user. |
| Account status | Screen-AccountStatus.ps1 | Exists / enabled / locked / expired, cloud and AD. |
| Revoke MFA | Screen-RevokeMfa.ps1 | Deletes MFA methods (default method last, with re-checks), signs the user out, optional e-mail with Authenticator set-up steps; "must register again" is verified. |
| On-premises AD | Screen-OnPremAd.ps1 | Unlock, reset, enable/disable, etc. |
| Create AD users | Screen-AdCreate.ps1 | Create only (single or CSV). Optional e-mail with the username and password (template `newuser`, edited in Settings > Email messages; own HTML and logo supported; recipient = the Email of each user or one typed address; password never logged). Username rules, OU picked from existing OUs (tree), groups. No delete, no OU creation, no move, no edit of existing accounts. |
| Bulk & report, Export | Screen-BulkCsv.ps1, Screen-ExportReport.ps1 | CSV bulk actions and reports. |
| Users report (was "OU report") | Screen-OuReport.ps1 | Browse and tick one or many existing OUs (with or without sub-OUs) and list its users: e-mail, UPN, account name, display name, first / last name, account expiry, status, description, last modified, password never expires, OU; table + CSV. Read only; permission `bulk`; no row limit (since 2.11.11). |
| Teams, Distribution groups, Shared mailbox, Address list | Screen-TeamsMembers.ps1, Screen-DistGroups.ps1 (+ DistGroups-Worker.ps1), Screen-SharedMailbox.ps1, Screen-AddressList.ps1 | Exchange Online / Graph. Distribution group folder is checked to be a safe folder. |
| Mailbox cleanup | Screen-MailboxCleanup.ps1 | Uses the signed-in user's own token; folder size from PR_MESSAGE_SIZE_EXTENDED. |
| Guest users report | Screen-GuestReport.ps1 | NEW 2.11.11. Read only. Every Entra ID guest: created, last sign-in, invitation Accepted / Not accepted (+ date), status, and ALL its groups in one cell with the kind in brackets (M365 group, Teams group, Security group...). Table + CSV. Endpoint /api/guestrep-run (Graph /users filter userType Guest with signInActivity, memberOf by $batch). |
| Guests | Screen-GuestUsers.ps1 | Invite one or many, e-mail (English/Arabic). |
| Licenses | Screen-Licenses.ps1 | Totals, direct vs group assignment, bulk assign/remove, group add/remove. |
| Devices (Intune) | Screen-Intune.ps1 | `managedDeviceOwnerType`, throttling retry. |
| OneDrive & storage | Screen-OneDrive.ps1 | SharePoint admin sign-in remembered (`spo-signins.json`). |
| Log viewer, Audit | ActivityLog.ps1, Screen-AuditLogs.ps1 | Activity log (actions only), copies kept in SharePoint and searchable. |

## 9. Portal and settings files

All settings are saved only when the person clicks **Save** (nothing is saved automatically). Leaving with unsaved changes asks Save / Don't save / Stay. Pop-ups close with the X at the top right.

| File (in the app folder) | Contents |
|---|---|
| `tool-users.json`, `two-step.json`, `login-lock.json` | users, TOTP secrets (encrypted), sign-in lockouts |
| `access-security.json` | IP allow-list, HTTPS-only, session rules, folder lock |
| `https-settings.json` | certificate / port |
| `ad-server.json` | which AD/DC to use: `{mode: auto|manual, server}` (Settings > Sign-in and session) |
| `sso-settings.json`, `sso-ms-choice.json` | SSO and remembered Microsoft 365 choices |
| `ms-app.json`, `mail-settings.json`, `sharepoint-settings.json`, `spo-signins.json`, `ad-login.json` | connections |
| `email-templates.json`, `email-images/` | e-mail texts, own HTML, logo |
| `app-defaults.json`, `ui-prefs.json`, `log-settings.json` | defaults, appearance, log options |
| `people-db.json` (+ `.bak`) | People database |
| `logs/`, `backups/`, `updates/` | logs and exports, backups, uploaded versions |

**Encryption**: secrets are protected with DPAPI (LocalMachine) through `Read-SecureText` / `Write-SecureText`; encrypted files start with `ACENC1:`. They can be decrypted only on the same server.

## 10. Security summary

- IP allow-list, HTTPS-only option, request-size limits and security headers in `Invoke-SecGate`.
- 2-step sign-in (TOTP), session tied to IP, sign-in lockout, SameSite=Lax cookie.
- SAML replay protection; SVG logos are sandboxed; safe-folder check for Distribution groups.
- Permissions per role and per screen; owner login kept as an emergency way in even when "SSO only" is on.
- The Create AD users screen is restricted to account creation only.
- Phone numbers and passwords are never written to logs.

## 11. Publishing behind IIS

The tool can sit behind IIS (reverse proxy / ARR) so people open `https://admin.contoso.com`. The provided `web.config` needs no server variable (`X-ARR-SSL` is used). Add the portal address as a redirect URI of the Microsoft app (Web for SSO, and the sign-in redirect). See the project document *admin-console-iis-publish-guide*.

## 12. Updates and versions

**Two kinds of version**

- **Package version** (`$AppVersion` in `server.ps1`, shown in the page, `VERSION.txt`, name of the zip): goes up with every delivery.
- **Screen version**: every code file has its own, in its first lines: `# Screen: <name>` and `# Screen version: x.y.z` (HTML: `<!-- Screen: ... | Screen version: ... -->`). It goes up ONLY when that screen's code really changes. Files from different releases can sit side by side - there is no "mixed versions" error.

**What the Updates screen does** (Settings > Updates, `backend/Portal/Screen-Updates.ps1`)

1. Upload the zip. It is checked and kept as `updates\pending.zip`. For every screen in the zip the version in its header is compared with the installed one: **New screen**, **Updated (old > new)**, **Same**, or **Removed**. The unchanged screens are folded away.
2. Type UPDATE: the running code is saved to `backups\`, the new files are copied (data files are never touched), the server restarts.
3. "What's new" is shown once per person: the notes of the new versions, which screens were updated / new, and that all other screens are the same.
4. *Saved versions - go back* restores an earlier package; `Revert-Update.bat` does the same when the page does not start.

**Release procedure (for whoever prepares the next zip)**

1. Change only the files of the screens you are changing.
2. Raise `Screen version:` in the header of each file that really changed (new package version number). Leave every other header alone. New screen file = new header with the new version.
3. Raise `$AppVersion` / `$AppDate` in `server.ps1` (the pages, `.bat` files and tools no longer contain the number).
4. In `frontend/index.html` add a new TOP entry to `VERSIONS`: `{"v","d","t","s":[["Screen name","updated"|"new"],...],"n":[notes]}` - keep the older entries. Add the same to `docs/CHANGELOG.md`.
5. Check the list: `python3 Tools/release_check.py <previous zip>` (compares every screen with the previous release, ignoring comments) - it reports a changed screen whose header was not raised.
6. Zip `PasswordReset` without `DistributionGroups`, `logs`, `*.json`, `email-images`, `sso-logo*`, `_old*`, `backups`, `updates` and name it `AdminConsole-<version>.zip`.

## 13. Development notes

- Every code file starts with a comment block that explains the screen, then a comment before each function / endpoint. Keep that when you edit: new code gets comments too.
- Check that a comment-only edit changed no code: compare the non-comment tokens before and after (PowerShell: `[Parser]::ParseFile` tokens without `Comment`; JavaScript: compare the syntax trees).

- Parse-check every script: `[System.Management.Automation.Language.Parser]::ParseFile(...)`.
- Check each `<script>` block of `frontend/index.html` with `node --check`.
- UI behaviour can be tested headless with Playwright and mocked `/api/*` routes.
- Files mix CRLF and LF and some have a BOM - preserve them when editing.
- Avoid element-ID clashes in `index.html` (use a screen prefix, e.g. `ax*`, `ac*`, `sso*`).

## 14. Known limits

- Tested with stand-ins and mocks; real Windows, AD, Graph, Exchange and IIS behaviour should be verified in your environment after each upgrade.
- The Entra admin-role check after SSO reads the `wids` claim (OIDC only); with SAML only portal administrators are asked.
- AD operations need a domain-joined host and a domain account with the right delegated rights.

## Progress pop-up and Cancel (v2.11.11)

The **Progress** button in the top bar opens a small pop-up in the middle of the page (not full screen, no dark background, the page behind stays usable). **Minimize** (-) shrinks it to a small card at the bottom right; click the card to open it again. **Close** (x) or Escape hides it. A click on a task goes to its screen and minimizes the pop-up.

**Cancel** is shown only where it really works: (1) background jobs (`/api/gjob`): sends `/api/gjob-cancel`, the server stops the job; (2) step-by-step runs (Revoke MFA, Create AD users): the remaining steps are not started (`acProg.cancelled(id)` is checked before each step; steps already done stay done); (3) read-only lookups (list in `SAFE` in index.html): the answer is no longer waited for. A single request that changes something has no Cancel button, because it cannot be taken back. Code: `acProg.canCancel(id, fn)`, `acProg.cancelled(id)`, `acProg.reset(id)` in the Progress block of index.html (page only).

## Forgot the owner password (v2.11.9)

`Reset-Password.bat` (package root) starts itself as local administrator and runs `server.ps1 -ResetLogin`: it asks for a new owner username and password (min 8 characters) without asking for the old one, because local administrator rights are the proof. The reset is written to the sign-in log. `Change-Login.bat` (also runs as administrator) changes the login but asks for the old one. Other people are reset in Settings > Users. The sign-in page does not show this; it is documented only in README, this file and the AI memory file.

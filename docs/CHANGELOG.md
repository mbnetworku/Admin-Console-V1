# Password Reset and Account Status Check - version history

Current version: **1.98.37** (2026-10-02)

_Versions 1.0.0 to 1.14.0 are reconstructed from our conversation; the files at that time were not numbered._

## 2.11.12 - 2026-10-08
- **Sidebar shows the real version.** The version text at the bottom of the sidebar was a fixed old text (v1.22.0) that was replaced only after the status answer arrived, so the old number could stay on screen. The server now writes the real version into the page (`__APPVER__`), so it is right from the first moment (index.html).

## 2.11.11 - 2026-10-08
- **Fix: Settings > About page error.** The version history failed with "Cannot read properties of undefined (reading 'map')" because the newest version entries have no detail list (`n`); `verHtml` now accepts entries without one (index.html only). Rule: every VERSIONS entry may omit `n` and `s`.

## 2.11.10 - 2026-10-08
- **Progress is a small pop-up with Minimize, Close and Cancel.** It opens in the middle (not full screen), can be minimized to a small card at the bottom right, and closed. Running tasks get a **Cancel** button where cancelling really works: background jobs (stopped on the server), step-by-step runs such as Revoke MFA and Create AD users (remaining steps are not started) and read-only lookups. Changes already sent to the server cannot be taken back, so those have no Cancel. Also: the "Cannot sign in?" message was removed from the sign-in page - the Reset-Password.bat information stays in README, TECHNICAL-DOCUMENTS and the AI memory file only.

## 2.11.9 - 2026-10-08
- **Forgot the owner password: Reset-Password.bat.** New launcher that runs as administrator by itself and sets a NEW owner login without asking for the old password (being local administrator is the proof; `server.ps1 -ResetLogin`). The reset is written to the sign-in log. `Change-Login.bat` now also runs as administrator (it still asks for the old login). The sign-in page shows a short "Cannot sign in?" message; README has a new section.

## 2.11.8 - 2026-10-08
- **Short lists with Show more.** Settings > Updates: the table *Installed screens and their versions* and the *Saved versions* table, and the version history (Settings > About and the version pop-up), now show only the first 5 rows. Buttons: *Show 5 more*, *Show all*, *Show fewer*; a line says "Showing N of M". Helpers `fewTable` / `fewApply` / `verRender` in index.html (page only).

## 2.11.7 - 2026-10-08
- **Copyright notice removed** (owner has no copyright yet): sidebar, Settings > About, sign-in page, `LICENSE.txt` and the README lines are gone. Nothing else changed.

## 2.11.6 - 2026-10-08
- **One README.** The project README and the docs index were combined into `README.md` in the package root (current version, all screens including Users report and Guest users report, requirements, quick start, folder map, document list, copyright). `docs/README.md` is now a short pointer to it. The README is updated in every release.

## 2.11.5 - 2026-10-08
- **Connections opens faster, no blank card.** Opening Settings > Connections sent the same requests several times at once (the server answers one at a time, so they queued, as the Progress list showed). Now the domain controller card and the Microsoft app card each load once at a time; the DC name is asked after the screen is shown (`/api/ad-server {current:true}`, kept 5 minutes); the Microsoft app card shows "Loading..." instead of an empty box (Screen-Settings 2.11.5, index.html).

## 2.11.4 - 2026-10-08
- **No DC search on a PC that is not in a domain.** The server first checks that the PC is domain joined; if not, `/api/ad-server` answers at once (`joined:false`) without any network search, and Settings > Connections switches the Domain controller card off with a short note (Screen-Settings 2.11.4, index.html).

## 2.11.3 - 2026-10-08
- **Copyright: MB Network.** Notice "(c) 2026 MB Network. All rights reserved." in the sidebar, Settings > About and the sign-in page; new `LICENSE.txt` (all rights reserved, third-party components keep their own licenses); footer line in docs/README.md.

## 2.11.2 - 2026-10-08
- **Confirmation words accept capital or small letters.** DELETE (Intune devices, Mailbox cleanup, OneDrive permanent delete), APPLY (Licenses), UPDATE and REVERT (updates) can now be typed as `delete`, `Delete`, `DELETE`, ... The page changes the typed text to capital letters before sending, and the back end no longer compares case-sensitively (Intune 2.5.6, Mailbox cleanup, OneDrive, Licenses 2.5.1, Create AD users, index.html).

## 2.11.1 - 2026-10-08
- **Settings opens faster.** Opening Settings > Connections used to search for domain controllers on its own; on a slow network this froze the server (it answers one request at a time) and made every Settings section feel slow. It now searches only when you press *Find DCs*, and the list is kept for 10 minutes (Screen-Settings 2.11.1, index.html).

## 2.11.0 - 2026-10-08
- **New screen: Guest users report** (Microsoft 365, `backend/Microsoft365/Screen-GuestReport.ps1`, endpoint `/api/guestrep-run`, permission *guests*, needs the Microsoft sign-in). Lists every guest: display name, e-mail, UPN, created, last sign-in, invitation Accepted / Not accepted (and accepted-on date), enabled or disabled, number of groups and ALL group names in one cell with the kind in brackets - M365 group, Teams group, Security group, Distribution list, Mail-enabled security. Filter box + invitation drop-down, sortable columns, CSV with BOM. Last sign-in needs AuditLog.Read.All (+ Entra ID P1/P2); if refused, the report still works and a note says why. Read only; no limit on the number of guests.

## 2.10.3 - 2026-10-08
- **Users report: no user limit.** The 20,000-user cap was removed; every user of the chosen OUs is reported (Screen-OuReport 2.10.3, index.html text only).

## 2.10.2 - 2026-10-08
- **Users report: choose several OUs.** The OU list was replaced by a *Browse OUs* button with the OU tree (tick boxes, search) like Create AD users; one report for one or many OUs (up to 50), duplicates removed, chips show the choice. `/api/ourep-run` now takes `ous` (array; `ou` still works). CSV is named after the OU or `Multiple_OUs`. Screens changed: Users report, Server core, Web page (shared UI).

## 2.10.1 - 2026-10-08
- The *OU report* screen is renamed **Users report** (menu, Home tile, screen title, documents). Same function. Screens changed: Users report, Server core, Web page (shared UI).

## 2.10.0 - 2026-10-08
- **New screen: OU report** (On-premises AD, `backend/ActiveDirectory/Screen-OuReport.ps1`, endpoints `/api/ourep-ous`, `/api/ourep-run`). Pick an OU from the list of existing OUs (filter box), with or without sub-OUs; the table shows e-mail, UPN, account name, display name, first name, last name, account expiry, status (Enabled / Disabled / Locked out / Expired), description, last modified, password never expires and the user's OU; sortable, filterable, CSV download. Read only; permission *Bulk & report*; needs the AD sign-in; at most 20,000 users per report.
- Screens changed: OU report (new), Users & roles (permission), Server core, Web page (shared UI).

## 2.9.1 - 2026-10-08
- **Search while typing** (Cloud password, On-premises AD; single user): about 0.8 s after typing stops (3+ characters) the Search runs by itself, the accounts show under the box and a single match is ticked automatically. On-premises AD searches only when signed in to AD. Enter / the suggestion list work as before. Screens changed: Server core, Web page (shared UI).

## 2.9.0 - 2026-10-08
- **New e-mail: "New user account - username and password"** (Settings > Email messages, id `newuser`): greeting, intro, boxes with the username and password, one-time / normal note, closing, security notice, signature; English + Arabic; subject, layout, logo and **own HTML** (`{password}` required; `{username}`, `{upn}`, `{name}`, `{first}`, `{greet}`, `{signature}`, `{logo}` ...).
- **Create AD users**: option *E-mail the username and password to the new user* (single form and CSV). Recipient = the Email of each user, or one address typed for everybody. Sent through the configured e-mail sender (Settings > Email sender); the result row says *sent* or *NOT sent (why)*; the account is created either way. The password is never written to a log (mail log has the result only).
- **Logo everywhere**: button *Use in all e-mails* copies the picture, place, alignment and width to every e-mail (`/api/email-img-all`). In own HTML use `{logo}`.
- Screens changed: Create AD users, Email messages, Server core, Web page (shared UI).

## 2.8.5 - 2026-10-08
- Fix: the Domain controller list in Settings > Connections is a real drop-down (the old suggestion list did not open in some browsers). It fills itself with the domain's DCs; *Type a name or IP address...* allows a manual entry. Screens changed: Server core, Web page (shared UI).

## 2.8.4 - 2026-10-08
- Documentation only: new section *Technology stack and versions* (PowerShell 5.1, plain JavaScript without a framework, qrcodejs 1.0.0, Graph SDK, ...) in TECHNICAL-DOCUMENTS.md, README.md and the design notes. No screen changed; only the package number (Server core header) was raised.

## 2.8.3 - 2026-10-08
- Settings > Connections no longer shows the *Portal session* box (the timeout stays in Sign-in and session). Screens changed: Server core, Web page (shared UI).

## 2.8.2 - 2026-10-08
- The *Domain controller (AD server)* card moved to **Settings > Connections** (it was under Sign-in and session).
- An IP address can be typed as the DC; it must be a valid IPv4 address (four numbers 0-255), and Test / Save confirm that the DC answers. Test shows the host name behind an IP.
- Screens changed: Settings, Server core, Web page (shared UI).

## 2.8.1 - 2026-10-08
- **Settings > Sign-in and session > Domain controller (AD server).** Choose Automatic (Windows picks the DC) or one specific DC. *Find DCs* lists the domain's controllers, *Test* checks one, *Save* applies it to every AD call (On-premises AD, Create AD users, Bulk, sign-in with AD, AD audit, Users AD check). Saved in `ad-server.json`. Endpoint `/api/ad-server`; helpers `Get-AdServerCfg`, `Get-LdapPrefix`, `Get-RootDse`, `Get-AdDefaultRoot` (Screen-Settings.ps1).
- **Single sign-on (SAML / OIDC): users are added only in Settings > Users.** The role-mapping boxes and the "everyone else" role were removed from Settings > Single sign-on. A person can sign in with SSO only if a portal user has their Microsoft e-mail as *Single sign-on account*; the role and permissions come from that user. Old mappings in `sso-settings.json` are ignored. Saving SSO with nobody linked shows a note (the owner login still works).
- Screens changed: Settings, Server core, Single sign-on, Users, Activity log, On-premises AD, Create AD users, Audit logs, Address list, Web page (shared UI). All others keep their version.

## 2.8.0 - 2026-10-08
- **Every screen has its own version.** Written in the first lines of its file ("# Screen version: x.y.z"). It changes ONLY when that screen changes. A release no longer rewrites the version in every file.
- Settings > Updates: an uploaded zip is compared screen by screen - **New screen / Updated (old > new) / Same / Removed** - and the installed screens are listed with their versions. "What's new" shows which screens were updated or new and that all others are the same.
- The "Mixed file versions" warning and check were removed (files of different releases are normal now); only missing files are reported.
- login.html / index.html / server.ps1 read the package version from `server.ps1` (placeholder `__APPVER__`), so they no longer need editing for a number.
- All code (PowerShell and JavaScript) now has comments: a header per file, a comment before every function and endpoint, and notes on regexes, workarounds and magic numbers. HTML screens have a SCREEN marker comment.
- Fix (HTTPS / SSL 2.8.0): the certificate Subject Alternative Name is read again (a wrong OID `2.7.19.17` had been left by an old blanket version replace; the right one is `2.5.29.17`).
- Version tags in code comments (`v2.x.y: ...`) were restored to the version in which each change was really made.
- Screens changed in this release: Updates, HTTPS / SSL, Server core, Web page (shared UI), Sign-in page. All other screens keep their old version.

## 2.7.1 - 2026-10-08
- Fix: Updates screen of 2.6.5 and older rejected the 2.7.0 zip ("web/index.html is missing"). The zip now carries a small bridge file web\index.html (moved aside at first start). The Updates screen accepts frontend/index.html (and web/index.html for old zips).

## 2.7.0 - 2026-10-08
- Package layout: frontend\ (pages), backend\ (Portal, Microsoft365, ActiveDirectory, ExchangeOnline), docs\ (all .md files). server.ps1, .bat files, Tools and settings unchanged. Old code folders are moved aside at first start.

## 2.6.5 - 2026-10-08
- Added TECHNICAL-DOCUMENTS.md to the package.

## 2.6.4 - 2026-10-08
- Create AD users: Browse OU is a tree (domain > OUs, expand/collapse, search, double-click) like Active Directory Users and Computers.

## 2.6.3 - 2026-10-07
- Progress: bottom-right cards removed (they blocked clicks); one Progress button at the top bar with task, mini bar and percent.

## 2.6.2 - 2026-10-07
- After SSO: ask (Yes/No, remember per account) to connect Microsoft 365 with the same account; setting for who is asked (admins / all / off).
- Revoke MFA: re-check and re-delete remaining methods (default Authenticator) automatically for up to ~30 s.

## 2.6.1 - 2026-10-07
- Single sign-on (OIDC) can use the Microsoft app from Connections (same tenant, client ID, secret); redirect URI added automatically. Untick to use another app/secret.

## 2.6.0 - 2026-10-07
- Progress view: click a task to open the screen it was started from.

## 2.5.9 - 2026-10-07
- Progress button opens a full-screen view of all running and recent tasks (bar, percent, count, times, time left).

## 2.5.8 (2026-10-07) - E-mail logo anywhere
- imgPos afterHello / beforeSig, imgAlign left/center/right, {logo} placeholder (built-in texts and own HTML), paste image from clipboard.

## 2.5.7 (2026-10-07) - E-mail messages: your own HTML, Arabic everywhere
- custom.<id> in email-templates.json; Format-EmailLayout uses it with the placeholder values seen while building ({password} for password e-mails); /api/email-custom-save; live preview; Arabic defaults for mfa and guest.

## 2.5.6 (2026-10-07) - Progress bar for bulk actions
- window.acProg (set / busy / done) bottom-right; api wrapper: /api/gjob percent, other calls > 2 s indeterminate; MFA loop and AD-create (chunks of 10) report percent.

## 2.5.5 (2026-10-07) - Activity log: actions only
- Write-Activity logs only mapped action calls (unmapped = not logged); read/look-up entries removed from ActMap; read jobs (Intune read, storage report, audit reads) no longer write rows; new mappings for people, SSO, AD login, test mail, GAL cloud, prefs.

## 2.5.4 (2026-10-07) - Revoke MFA: one button for revoke + re-register
- btnMfaOne: removeMfa + removeTap + signOut in one confirmation; Apply renamed Apply ticked.

## 2.5.3 (2026-10-07) - Revoke MFA: require re-register MFA
- removeMfa forces revokeSignInSessions; 3 deletion rounds; verification of remaining MFA methods (reregister flag, leftMfa); hardwareOath methods included; UI column Must register MFA again.

## 2.5.2 (2026-10-07) - Link portal users to single sign-on
- tool user fields ssoUpn / ssoOnly; Start-SsoSession uses the linked user (role, perms, expiry, assigned accounts); password login refused for SSO-only users; SSO setup no longer requires a role mapping when users are linked.

## 2.5.1 (2026-10-07) - Cloud password: new password in cloud + on-premises AD
- /api/reset method "both": SetPassword in AD (pwdLastSet -1, unlock) + Update-MgUser (ForceChange false; falls back to password hash sync note); e-mail uses the AD template, normal password wording.

## 2.5.0 (2026-10-07) - New screens: Licenses and Create AD users
- Microsoft365/Screen-Licenses.ps1: subscribedSkus + licenseAssignmentStates (direct / group / both), bulk assign / remove (assignLicense), group add / remove; permissions licenses, licassign; log license-audit-yyyy-MM.csv.
- ActiveDirectory/Screen-AdCreate.ps1: create-only AD users (single + CSV), OU picker (existing OUs only), duplicate checks, username suggestion rules; permission adcreate; log ad-create-audit-yyyy-MM.csv.
- Mailbox cleanup: folder size from PR_MESSAGE_SIZE_EXTENDED (0x0E08) instead of sizeInBytes.
- Scopes: LicenseAssignment.ReadWrite.All, User.ReadWrite.All.

## 2.4.8 (2026-10-04) - Fix: Mailbox cleanup look-up - Insufficient privileges
- mp-lookup resolves users with the delegated session (Find-CloudUser) and passes id/UPN to the job; the app token is used only for mailFolders. Mailbox feature adds User.Read.All (application).

## 2.4.7 (2026-10-04) - Fix: AADSTS700025 Client is public
- Invoke-MsToken / ms-device-poll / Exchange worker: on AADSTS700025 retry without client_secret; MsPublicOnly per session stops sending it for refresh, SPO and EXO.

## 2.4.6 (2026-10-04) - Fix: Microsoft page sign-in went back to the portal login
- sid cookie SameSite=Strict -> Lax (localhost redirect hop back to http://PC-name:8080 dropped the cookie). API calls still need the X-Token header.

## 2.4.5 (2026-10-04) - Fix: invalid client secret (AADSTS7000215)
- AppSetup tests the saved secret (client_credentials) and makes a new one if Microsoft rejects it.
- Mailbox cleanup status: plain message + Fix it now (new secret) button.

## 2.4.4 (2026-10-04) - The Microsoft app is updated, not created again
- AppSetup: find the saved app (or same display name) and PATCH requiredResourceAccess / redirect URIs (merge), extend the AllPrincipals grant, add only missing app role assignments, keep the saved secret.

## 2.4.3 (2026-10-04) - Fix: device-code sign-in stopped with (400) Bad Request
- PS 5.1 Invoke-RestMethod puts the error body in ErrorDetails.Message (the response stream is already read): all error readers use it first, so authorization_pending is recognised (AppSetup, ms-device-poll, spo-code-poll) and real Microsoft errors are shown.

## 2.4.2 (2026-10-04) - Fixes: SharePoint sign-in remembered, Mailbox cleanup set-up
- OneDrive: SharePoint admin sign-in remembered per portal user + Microsoft account (spo-signins.json, DPAPI); Forget button.
- Updates: What is new of the uploaded zip parsed correctly (VERSIONS regex).
- Mailbox cleanup: Set it up now button (automatic app creation with Mail.ReadWrite + secret preselected).

## 2.4.1 (2026-10-04) - Fixes: Devices (Intune) and OneDrive storage
- Intune: $select used ownerType (not in Graph v1.0) - now managedDeviceOwnerType.
- Background Graph jobs: 429/503/504 wait for Retry-After (up to 7 retries, max 120 s each), progress shows the wait; friendly throttling message instead of raw JSON.

## 2.4.0 (2026-10-04) - Create the Microsoft app automatically
- 2-step sign-in (TOTP authenticator app), session tied to IP, SVG logo sandboxed, DG output folder restricted.
- Settings > Access and security: allowed IPs, HTTPS only, per-PC password-guessing block, folder lock; tool-users.json and people-db.json encrypted (DPAPI); security headers; request size limits; SAML replay protection; Secure cookie trusts X-Forwarded-Proto only from IIS on this server.
- Settings > Updates (administrators): upload a new version, install it, go back to a saved version; Revert-Update.bat; What is new pop-up after an update.
- Log viewer: This server / SharePoint - all computers (read only search of the log copies in SharePoint, with the computer of each row).
- Settings > Appearance > Screen background: colour, gradient, dots or grid, see-through cards (only for you, Save to keep).
- Asks first: "Create the Microsoft app?" Yes / No, then the permissions, then a final "Create it now?" confirmation. Admins with no app are asked once when the portal opens.
- Old sign-in is back: Connect > "Old sign-in (window)" opens the classic Connect-MgGraph window (only at the server itself; about 1 hour, then connect again).
- Settings > Connections: a Global Administrator signs in once with a code; the app is created with only the ticked permissions, admin consent is granted and it is saved.

## 2.3.0 (2026-10-04) - Devices (Intune): remove devices
- Domain filter, tick devices / Tick all shown, Delete from Intune (+ Entra device) or Retire, background job, logs\device-removal-audit-yyyy-MM.csv. Scopes: DeviceManagementManagedDevices.ReadWrite.All, ...PrivilegedOperations.All, Device.ReadWrite.All. Permission intunedel.

## 2.2.1 (2026-10-04) - Mobile numbers
- On-premises AD search: mobile + telephoneNumber. Account status: Entra mobilePhone/businessPhones and AD mobile/telephoneNumber, also in the CSV.

## 2.2.0 (2026-10-04) - New screen: Mailbox cleanup
- ExchangeOnline\Screen-MailboxCleanup.ps1: look up mailboxes (folders, items, size) and delete mail (all / chosen folders / older than a date) with Graph app-only (Mail.ReadWrite application permission, client secret), permanentDelete in $batch, user folders removed in one step, background job, logs\mailbox-cleanup-audit-yyyy-MM.csv. Permission mbxdelete.

## 2.1.1 (2026-10-04) - Storage: used, left and by account status
- Used / given / left per SharePoint (tenant quota, needs SharePoint admin), OneDrive and mailboxes; GB and counts per Enabled / Disabled / Not found account; Account column + filter.

## 2.1.0 (2026-10-04) - Devices (Intune) and OneDrive & storage
- Microsoft365\Screen-Intune.ps1: Intune devices + Entra join type (from Intune.ps1), background job; generic background jobs (/api/gjob) with the person's own token.
- Microsoft365\Screen-OneDrive.ps1: tenant storage usage (OneDrive, SharePoint, mailboxes - Graph usage reports); look up / delete OneDrives (from the two OneDrive deletion scripts) via the SharePoint admin API (RemoveSite / RemoveDeletedSite / RestoreDeletedSite), recycle bin or permanent, only personal sites, logs\onedrive-audit-yyyy-MM.csv.
- SharePoint admin token from the Microsoft sign-in or "Connect SharePoint admin" (code).
- New Graph scopes: DeviceManagementManagedDevices.Read.All, Device.Read.All, Reports.Read.All. New permissions: intune, onedrive, oddelete.

## 2.0.2 (2026-10-04) - Admins: sign other people out of AD or Microsoft
- Who is signed in: Sign out of AD / Sign out of Microsoft per session (/api/sess-signout, administrators).

## 2.0.1 (2026-10-04) - Sign out of AD button
- Session menu: Sign out of on-premises AD. On-premises AD and Bulk & report screens: Sign out of AD button while signed in.

## 2.0.0 (2026-10-04) - Many people at the same time (multi-user, IIS)
- Per-person sessions: Microsoft (Graph), on-premises AD, Exchange Online worker (DistributionGroups\Users\<account>), timers, reset passwords for e-mail. The Graph connection is switched to the right person for each request; background audit searches use their own token.
- Settings > Users: Microsoft account (+ only this account) and AD account + encrypted password (+ only this account) per person; automatic AD sign-in.
- Microsoft sign-in: Sign in with a code (device code) from any PC; own app registration (Settings > Connections > Microsoft app; redirect = portal address) incl. Exchange Online by token (Exchange.Manage). The server-side sign-in window is no longer used.
- Settings > Server: Restart / Shut down (permission "Restart / shut down the server") + IIS hosting steps. Who is signed in: all sessions, End session.
- Install-Service.bat / Tools\Install-Service.ps1: start with Windows as a service account (scheduled task). X-Forwarded-For from IIS on this server.
- Limits: requests are handled one after another (a long bulk run makes others wait); keep big bulk jobs reasonable.

## 1.98.52 (2026-10-04) - E-mail addresses on the same row as the user
- "user, mail1, mail2" (comma or ;) in single and bulk boxes; only the user is searched; all addresses get that user's password.
- The button shows the format and a live who-gets-what list instead of a separate box.

## 1.98.51 (2026-10-04) - Button: send the password to e-mail addresses I type
- Cloud password and On-premises AD: optional box (opened by a button) for the users' e-mail addresses, line by line; used in the e-mail window together with the suggested address.

## 1.98.50 (2026-10-04) - Email the password: personal e-mail + preview
- Rows "user, personal e-mail" fill BOTH the personal and the suggested address for that user in the email window (also for description searches on On-premises AD).
- Preview button per user: password, kind, recipients, subject and the real e-mail (new /api/reset-mail-preview, permission 'email').

## 1.98.49 (2026-10-04) - On-premises AD: email the new password
- Password reset panel: Email the password option + sender + Email settings; after the reset the tool offers to email it (same window as cloud resets).

## 1.98.48 (2026-10-04) - Fix: change name uses the ticked account
- The name boxes are filled from the ticked search result's username instead of the typed search text (e.g. a description).

## 1.98.47 (2026-10-04) - Search boxes: suggestions and Enter
- Enter without picking a suggestion runs the full search; pending suggestions are cancelled.
- AD suggestions: names and descriptions queried separately with time limits; errors are shown.

## 1.98.46 (2026-10-04) - On-premises AD: search shows everyone who matches
- Every typed term is also searched in usernames, UPN, email, names and descriptions; all matches are listed (exact match pre-ticked). Lists of more than 5 entries widen only the entries without an exact match.

## 1.98.45 (2026-10-04) - Fix: On-premises AD search by description
- Users found by description or name were dropped in the second look-up (an empty 'fields' was read as 'description only'). Fixed on the server and the page.
- Suggestions follow the ticked Search in boxes.
- The search icon no longer overlaps the text in the search boxes.

## 1.98.44 (2026-10-04) - No .exe files
- Removed SupportTool.exe, SupportTool-Stop.exe and Tools\exe-source. Start with Start.bat; stop with Session > Shut down.
- Old .exe files are moved to '_old files (can be deleted)' on start.
- Allow-Tool.bat only unblocks files (no certificate), and again covers the whole folder.

## 1.98.43 (2026-10-03) - Home: search box
- Search any screen, Settings section or action from Home and go straight there (arrow keys, Enter, / to focus). Respects permissions.

## 1.98.42 (2026-10-03) - Settings redesigned, Appearance never saves by itself
- Settings menu grouped by topic with icons, Admin tags, search and Version and about at the bottom; path line above each section.
- Appearance (theme and colours) is a preview until Save; leaving asks Save / Don't save / Stay.
- New Appearance > Screen layout: size, spacing, corners, page width, side menu width, menu icons (saved per person).

## 1.98.41 (2026-10-03) - Permission: restart / shut down the server
- Settings > Users: new permission Restart / shut down the server (off by default; admins and the owner always have it).
- Session menu: Restart the server. Restart and Shut down are hidden and refused for people without the permission (also the 'shut down when I close the tab' choice).
- Change tool settings no longer allows shutting down.

## 1.98.40 (2026-10-03) - Who is signed in moved to Settings
- Who is signed in is now Settings > Who is signed in (administrators only).
- Settings > Version and about is always the last button.

## 1.98.39 (2026-10-03) - New screen: Who is signed in
- Side menu > Who is signed in (administrators only, read only; code in `Portal\Screen-Sessions.ps1`).
- Signed in now: user, method (Normal / Owner / AD account / SSO OIDC or SAML), role, IP address, PC name, start, last active, Microsoft and AD accounts.
- PCs with the page open now, and seen earlier (kept in memory until restart).
- Sign-in history from the sign-in log with method/result filters, totals and CSV download.
- The tool still allows one signed-in person at a time; others are refused and shown as Refused.

## 1.98.38 (2026-10-03) - Menu icons and tidy code folders
- Every screen in the side menu has its own icon.
- Code is now in folders (data files stay in the main folder):
  - `Start.bat`, `Start-Visible.bat`, `Change-Login.bat`, `Allow-Tool.bat`, `server.ps1` - main folder
  - `web\` - index.html, login.html (the pages)
  - `Microsoft365\` - Cloud password, Account status, Revoke MFA, Teams members, Guest users, Microsoft sign-in, Audit logs
  - `ActiveDirectory\` - On-premises AD, Bulk CSV, Export report, Accounts
  - `ExchangeOnline\` - Distribution groups, Shared mailbox, Address list, DistGroups-Worker.ps1
  - `Portal\` - Settings, Tool users & sign-in, People database, HTTPS, SSO, Email templates, ActivityLog.ps1
  - `Tools\` - Allow-Tool.ps1, exe-source
- Old loose code files left from an update are moved to `_old files (can be deleted)` on start.

## 1.98.37 - Email sender: simpler, sign in another account with Microsoft
- **Settings > Email sender** redesigned. "Send the e-mails from" now has three clear tiles: **A shared or other mailbox** (your Microsoft sign-in + Send As - as before), **My own mailbox**, **Another account**. The app registration (client ID + secret) moved under **Advanced**.
- **Another account:** click **Sign in with Microsoft** - the normal Microsoft sign-in page opens in a window, you sign in with the account that should send the e-mails (it only gets permission to send mail), the window closes by itself and the screen shows **who is signed in** with **Use another account** and **Sign out**. "Send from" is optional: empty = from that account's own mailbox, or a shared mailbox it has Send As on. The code sign-in is still there under "More options" (for when no window can be opened). Then click **Save**.
- **My own mailbox** shows the mailbox the e-mails will come from; the Sender field is hidden for it.
- Signing in the mail account no longer switches the sending method by itself - the choice is saved only with Save.

## 1.98.36 - Settings: nothing is saved without Save
- Fixed: some settings were saved the moment you changed them (Microsoft and AD auto sign-out, portal timeout, "copy the logs to SharePoint automatically"). Now **nothing in Settings is saved until you click Save**.
- As soon as something is changed, a bar at the bottom says **"You have unsaved changes in Settings"** with **Save** and **Don't save**.
- If you go to another Settings section or another screen (sidebar, Home, top buttons, back button) with unsaved changes, the tool asks: **Save** (saves the changed parts), **Don't save** (everything goes back to how it was - nothing is changed) or **Stay**. Closing or reloading the tab also warns.

## 1.98.35 - Fix: no error after Shut down
- Fixed (for good): after **Session > Shut down**, the "Server stopped" page still showed the red "Cannot read properties of null (reading 'classList')". Cause: the click on "Yes, shut down" (and later clicks / keys) still reached the handlers of the screens that had just been removed from the page. Now, once the tool is shut down, the page stops every timer and ignores every click, key, scroll and address change, and never shows a page error. Tested: shutting down from Home, Log viewer, Audit, Settings, Address list and Cloud password - no errors.

## 1.98.34 - Sign-in page: Microsoft button first
- With **single sign-on on**, the sign-in page shows the **Sign in with Microsoft** button at the top, then a line "or sign in with a username and password", then the normal sign-in - all on one screen. With SSO **off** the page is exactly as before. With "single sign-on only" just the button (and the emergency owner link) is shown.
- The button has the white Microsoft sign-in style (dark in dark mode).
- **Button picture:** Settings > Single sign-on > "Picture on the button" - upload an SVG or PNG (max 200 KB; SVGs with scripts are refused), e.g. the official logo from Microsoft's "Sign in with Microsoft" branding guidelines. Saved as sso-logo.svg / .png next to the tool; "Remove picture" goes back to the key icon.

## 1.98.33 - Single sign-on only
- **Settings > Single sign-on > Use single sign-on only** (with OIDC or SAML on): the sign-in page shows **only** the "Sign in with Microsoft" button - no username / password fields and no "Sign in with AD". The server refuses tool-user and AD password sign-ins too.
- The **owner login** (Change-Login.bat) stays as an emergency way in: "Emergency owner sign-in" link under the button, in case Entra or the SSO setup has a problem.

## 1.98.32 - Single sign-on with Microsoft Entra ID (OIDC or SAML)
- New **Settings > Single sign-on (SSO)** (administrators only; new file Screen-Sso.ps1). Choose **Off**, **OpenID Connect (OIDC)** or **SAML 2.0 (XML)**, the portal address (https) and the button text.
- **OIDC:** step-by-step for Entra (App registration, Web redirect URI to copy, client secret, app roles Admin / Helpdesk / ReadOnly / LogViewer or a groups claim, assign users, Assignment required). Fill in Directory (tenant) ID, Application (client) ID and Client secret (stored encrypted). Sign-in uses the authorization code flow; the ID token is taken from Microsoft's token endpoint and checked (application, issuer / tenant, nonce, expiry).
- **SAML:** step-by-step for Entra (Enterprise application, non-gallery; Identifier, Reply URL and Sign on URL to copy - or the tool's SP metadata URL; claims; assign users) and **upload the Federation Metadata XML**. The tool checks the XML signature with the certificate from that file (only the signed element is used - no XML wrapping), plus audience, reply address, time and request ID.
- **Roles:** map Entra app role values or group object IDs to Administrator, Helpdesk, View only and Log viewer (highest wins), and choose what everyone else gets (default: not allowed).
- The **sign-in page** shows a "Sign in with Microsoft" button when SSO is on; owner, tool users and AD sign-in keep working. SSO sign-ins are in the sign-in log.

## 1.98.31 - HTTPS / SSL certificate
- New **Settings > HTTPS / SSL certificate** (administrators only; new file Screen-Https.ps1).
- **1. Certificate:** upload a **.pfx / .p12** (certificate with private key + its password, optional friendly name). It is imported into the Windows store **Local Computer > Personal**, where IIS on the same server can use it too. All certificates with a private key on the computer are listed with subject, names (SAN), issuer, validity and days left (warns when expiring / expired / self-signed); pick the one to use.
- **2. Option A - the tool itself on HTTPS:** tick "Use HTTPS", type the name people will use and the port (443, or 8443 if IIS uses 443), Save. The certificate is bound to the port in HTTP.sys (netsh http add sslcert), an inbound Windows Firewall rule is added (domain + private networks), and from the next start the tool also answers on https://name:port/ (http://localhost:8080 keeps working on the server). If HTTPS cannot start (port taken), the tool starts on http and says why. The session cookie is marked Secure over https.
- **3. Option B - IIS on Windows Server in front of the tool:** step-by-step (URL Rewrite + Application Request Routing, Enable proxy, https binding with your certificate) and **Download web.config for IIS** - a reverse proxy to http://localhost:8080 with an http->https redirect and HSTS.
- Microsoft 365 browser sign-in must still be done at http://localhost on the server (Microsoft allows only that address for this sign-in).

## 1.98.30 - Email sender: four ways to send
- **Settings > Email sender > How e-mails are sent** - choose one (the old way stays the default):
  1. **With my Microsoft sign-in, from the sender mailbox** - as before (Send As / Send on behalf on a shared or another mailbox).
  2. **From my own mailbox** - e-mails go out from the mailbox of the person signed in to Microsoft 365 (normal or shared mailbox not needed).
  3. **With an app registration** - Tenant ID, Application (client) ID and Client secret. Sends from any mailbox, even when nobody is signed in to Microsoft. The app needs the Microsoft Graph **Mail.Send application** permission with admin consent. The secret is stored encrypted on this PC (Windows DPAPI) and never shown or sent to the page again.
  4. **With a separate mail account (sign in once)** - no secret needed: click "Sign in the mail account", open the link and type the code, sign in with the account that should send. It is used only to send e-mails (permission Mail.Send only) - from its own mailbox or a mailbox it has Send As on. Stays signed in (encrypted on this PC) until you click "Sign out this account".
- Every e-mail of the tool uses the chosen way: password / Temporary Access Pass e-mails, guest invitations, shared mailbox e-mails and Send test e-mail.

## 1.98.29 - "How this screen works" on every screen
- Every screen now has an **(i) How this screen works** button under its title, next to Copy link (the How it works button at the top does the same). Each explains what that screen does in the background: Home, Cloud password, Account status, Revoke MFA, On-premises AD, Bulk & report, Teams members, Distribution groups, Shared mailbox, Address list, Guest users, Log viewer, Audit & event logs.
- **Settings:** every section has its own explanation - Connections, Sign-in and session, My account, Email sender, Email messages, Logs and cloud copy, Defaults, Users, Appearance, Version and about, People database.

## 1.98.28 - Hide / Unhide, and a How it works button
- **Address list:** the buttons are now **Hide** and **Unhide** next to each other in step 2 - tick the people, then choose one.
- **How it works** button at the top (before Home): opens a window that explains what the screen you are on does in the background - for example on Address list: the check in Entra and AD, msExchHideFromAddressLists in AD + Entra Connect sync for synced accounts, Set-Mailbox -HiddenFromAddressListsEnabled in Exchange Online for cloud-only, and how long Outlook / Teams take. Every screen has its own explanation.

## 1.98.27 - New screen: Address list (hide from the address book)
- **Address list** (sidebar and Home > Exchange Online and Teams; new file Screen-AddressList.ps1): hide people from the address book (Global Address List) that others search in Outlook and Teams - or show them again. One person or many (one per line).
- **1. Check** finds each person in Microsoft 365 and AD and shows: synced from AD or cloud only, hidden or shown now (AD), and where the change will be made.
- **Synced from on-premises AD** -> the tool sets **msExchHideFromAddressLists** in AD (needs your AD sign-in and the Exchange attributes in the AD schema - the screen tells you if they are missing). **Entra Connect** copies it to Exchange Online at the next sync (usually within 30 minutes).
- **Cloud-only mailboxes** (and mail users / contacts) -> changed in **Exchange Online** (HiddenFromAddressListsEnabled) through the same Exchange Online connection as the Shared mailbox screen.
- **2. Hide from address list / Show in address list again** for the ticked people, with the result per person. Outlook and Teams show the change within a few hours (Outlook offline address book up to 24 hours). Every change is in the activity log. Permissions: AD changes need "On-premises AD changes", Exchange Online changes need "Shared mailboxes".

## 1.98.26 - Fix: page error after Shut down
- Fixed: after **Session > Shut down**, the "Server stopped" page showed a red "Page error ... Cannot read properties of null (reading 'classList')". The screens had been removed from the page but their timers (status checks, Home, Log viewer ...) were still running. The page now stops every timer when the tool is shut down, and no error message is shown after that.

## 1.98.25 - New password in its own window
- After a reset (Cloud password and On-premises AD), **Reveal passwords** and the new **View** button on every row open a window with: **username**, name, AD username / UPN, **where it was set**, and the **password** (Show / Copy). For several users: Show all and Copy all (username, password, kind).
- The window says **what kind of password** it is: **One-time password** (must change at next sign-in), **Permanent password** (no change asked), or **Temporary Access Pass** (how long it is valid, one-time or not).
- A short **note** when it matters: a cloud reset of an account **synced from on-premises AD** warns that AD keeps the old password unless password writeback is on (reset it on the On-premises AD screen to change it everywhere); an AD reset says whether **Microsoft Entra** got the same password too, or gets it at the next sync.
- Viewing is written to the activity log (who and which users - never the password).

## 1.98.24 - Log viewer: your columns, column widths, where the logs come from
- **Columns** button: tick the columns you want - every column in the log is offered (activity log: Time, Tool user, Screen, Action, Target, Result, IP, PC, Computer, Windows user, Microsoft account, AD account, Details, Time zone, Log file; sign-in log: Time, Username, Result, IP, PC, Windows user, Log file). **Show all** and **Default** buttons. **Download CSV** now saves the columns you see.
- **Resize:** drag the right edge of a column title to make it wider or narrower (double-click the edge to fit it again); drag the bottom-right corner of the table to make it taller or shorter. Your columns and widths are remembered in this browser for your sign-in, separately for the activity and sign-in logs.
- **Where the logs come from:** under the search the screen says which PC and folder the rows are read from, how many files (with "Show the files" - each file name and its row count) and where the SharePoint copy goes. Every row also has a **Log file** column.

## 1.98.23 - Home screen: your name, e-mail and greeting, your way
- **Home now shows who you are signed in as:** the Microsoft 365 box shows your Entra display name and e-mail; the On-premises AD box shows your AD display name and username (read from AD); the greeting uses your first name ("Good afternoon, Mohammed").
- **Settings > Appearance > Home screen** (saved only for you, like the colours): Greeting show / hide, your own greeting text (or automatic morning / afternoon / evening), the name in the greeting (first name, first and last name, display name, or no name), the date line, the **Microsoft 365 box** (display name and e-mail, e-mail only, display name, first and last name, first name, or hide), the **AD box** (display name and username, username, e-mail, display name, first and last name, first name, or hide), and the "Signed in to the tool" and Version boxes. A live preview shows the result before you save. "Back to default" undoes it.
- The colours "Back to default" now only resets the colours (not the Home screen choices).

## 1.98.22 - Hover help on the buttons
- Hold the mouse on a button for about half a second and a short explanation appears. **Sidebar buttons** and **Home cards** say what the screen does (shown next to the sidebar); the **top buttons** (Home, M365 / AD, theme, Settings, Session) and the **common buttons** on every screen (Search, Look up, Reset now, Revoke MFA, Enable, Disable, Unlock, Download CSV, Save, Copy link, Sync now ...) explain what they do. A locked button says why it is locked. Works in light and dark.

## 1.98.21 - Bcc in the password e-mails
- The e-mail window for passwords and Temporary Access Passes (Cloud password and On-premises AD) has a new **Bcc (optional)** box under Cc. Every e-mail is also sent as a hidden copy to these addresses - the receivers do not see them. Up to 5 addresses, checked like Cc, people of your organization are suggested, and the Bcc addresses are shown in the confirmation before sending and in the results. Bcc is not remembered for next time (Cc still is).

## 1.98.20 - E-mail boxes suggest people of your organization
- In the e-mail window (password / Temporary Access Pass e-mails - Cloud password and On-premises AD), each user's row shows the address(es) for that user first (their alternate e-mail, manager, own mailbox - click to choose), and under it the box **"Another e-mail - type it, then press Enter"**.
- While you type there (and in Cc), **people of your organization are suggested** (from Microsoft 365). An outside address (gmail, hotmail ...) gets no suggestions - just type it and press Enter.
- After Enter adds an address, the box says **"Added - you can write another e-mail"** and shows how many addresses there are (up to 5).

## 1.98.19 - Personal colours, user + e-mail rows, e-mail clean-up
- **Personal colours** (Settings > Appearance > Colours): 8 colour sets (Blue, Teal, Purple, Green, Orange, Red, Pink, Graphite) or your own colour for buttons/highlights and for the sidebar, with a live preview. Saved per sign-in in ui-prefs.json - only the person who saves it sees it; everyone else keeps their own. "Back to default" removes it.
- **Bulk password reset - user and personal e-mail on one row** (Cloud password and On-premises AD, Several users): write `username, personal e-mail` per row - separated by a comma, semicolon, tab (pasted from Excel) or spaces - or load a CSV whose first column is the user and second the e-mail (a header row such as "Username,Email" is skipped). The first column is reset; the e-mail is remembered and filled in automatically for that user when you e-mail the passwords. Rows with only a username / ID / UPN work as before. A note under the box shows how many e-mails were recognised.
- **Each user gets a different random password** when "Generate a random password" is chosen (cloud and AD) - unchanged, now stated here.
- **Guest users and Teams members - e-mail clean-up:** spaces around @ and dots, invisible characters, non-breaking spaces, "mailto:" and a trailing dot or comma are removed automatically (`ali @ partner . com` becomes `ali@partner.com`); several addresses on one row separated by spaces are split. The cleaned list is shown when you leave the box.

## 1.98.18 - People database in Settings (administrators only), Home button at the top
- **People database** moved from the sidebar and Home into **Settings > People database**. Only the owner and the **Administrator** role can see or use it - Helpdesk, View only, Log viewer and Custom users do not see it, and the server refuses its requests for them. (The separate "People database" permission was removed.) Old #people links open it in Settings.
- **Home button** at the top right, before the M365 / AD button - no need to open the sidebar to go Home.

## 1.98.17 - Other screens offer the user, never fill it in
- Changed: a user you typed or searched on one screen is **no longer filled in by itself** on the next screen. Instead a message at the top of that screen says "You searched on <screen>: <user>. Search this user here too?" with **Use it here** (fills it in) and **x** (hide). Works on Cloud password, Account status, Revoke MFA, On-premises AD, Bulk & report and Audit & event logs.

## 1.98.16 - Audit & event logs: find the user first
- **Find the user, then show the logs:** type part of the user and press **Enter** (or click **Find user**). A list of matching users appears (name, UPN or username, email, employee ID, description / job title, enabled or disabled). Click **Select** on the right one - the box is filled in - then click **Show the logs**. Suggestions also appear while you type.
- **Search the user by** (changes with the source):
  - Microsoft 365 (audit and sign-in logs): Anything, User principal name (UPN), Email, Employee ID, Object ID, Display / first / last name.
  - On-premises AD (event logs): Anything, Username (sAMAccountName), UPN / email, Employee ID (employeeID or employeeNumber), Description, Display / first / last name.
- Fixed: pressing Enter in the user box started the log search straight away and locked the form, so the user list / suggestions never appeared. If a lookup fails (for example not signed in), the reason is now shown instead of an empty list.

## 1.98.15 - Audit & event logs: readable table, user suggestions
- Fixed: long texts in the results (Why it failed, Details, Changes) ran over the next columns (IP address, Location). They now wrap inside their own column, at most 3 lines; hover for the full text, or click the row for every detail.
- New: the "User or word to look for" box suggests users while you type. With **Microsoft 365 (cloud)** it lists **Microsoft Entra** users (for the audit and sign-in logs); with **On-premises AD** it lists **AD** users (for the event logs). Each suggestion shows its source (M365 / AD).
- New: **Suggest users by** - Username and description (default), Username / name only, or Description only. AD searches the description field; Entra has no description, so it looks in employee ID, job title and department.
- Picking a suggestion fills in the user (email/UPN for Entra, username for AD) without starting the search, so you can still change the other options.

## 1.98.14 - Log viewer screen
- **New screen: Log viewer** (sidebar and Home > Reports and administration). Two tabs: **Activity log** (everything done in the tool) and **Sign-in log** (every portal sign-in, with IP and PC).
- **Search** any word - a user, email, username, action, IP address, PC - all words must match; matches are highlighted. **Filters:** From / To dates (Today, 7, 30, 90 days, or any range up to a year), Tool user, Screen, Result (success / failed or refused). Click a row to see all its columns. **Download CSV** downloads exactly what is shown.
- **Read only:** the screen only reads the log files; nothing can be changed, moved or deleted. The server enforces it.
- **Who sees what:** with "See all logs" (Log viewer role, administrators, owner) everyone's actions and the sign-in log; without it, only your own actions.
- A person with only the Log viewer role lands on the Log viewer and sees only Home, Log viewer and Settings (Account status is now hidden from log-only users too).

## 1.98.13 - Cloud password: Microsoft session renews itself
- Fixed: on Cloud password, Enter (search) did nothing after the Microsoft 365 session had expired - Graph answered "Authentication needed. Please call Connect-MgGraph" and the screen locked itself. The tool now renews the session by itself (browser sign-in: with the saved refresh token; certificate: reconnects with the certificate) and the page repeats the request once automatically. Only if renewing fails is Microsoft 365 shown as signed out, with the Sign in button.

## 1.98.12 - Fixes: Home cards, names with spaces
- Fixed: the screen cards on Home did not open their screen. They now always work (a second click handler is a safety net if another part of the page fails). The Home greeting no longer throws "Cannot access 'ME' before initialization".
- New: if anything on the page fails, a red message at the bottom says what and on which line (click to close) - send a screenshot of it.
- Fixed: in Single user (Cloud password, Account status, Revoke MFA, On-premises AD), typing a space - for example a display name "Ali Khalid" - switched to Several users. Typing never switches now; only pasting a list (one per line, or separated by , or ;) does.

## 1.98.11 - Sign in with AD groups, lock per user
- **Sign in with AD** (Settings > Users, new card): turn it on and add the AD group names whose members may sign in to the portal with their own AD (Windows) username and password, and the role each group gives (Administrator, Helpdesk, View only, Log viewer). Groups are checked in AD when you save. Members of nested groups count. Someone in several groups gets the highest role. A disabled or expired AD account cannot sign in, and is signed out within 10 minutes if it expires while signed in. Saved in ad-login.json.
- **Sign-in page:** when AD sign-in is on, a "Sign in with" drop-down: **Portal account** or **AD account**. Signing in with AD also signs you in to on-premises AD for the AD screens (one sign-in for both).
- **Lock per user:** 5 wrong passwords lock **only that username** for 15 minutes. Only that person sees the lock message; everyone else signs in normally. Kept in login-lock.json (delete it with the tool stopped to unlock early).

## 1.98.10 - Enable / disable people, sign-in lock 15 minutes
- **People database:** every person is Active or Disabled. Enable / Disable on each row, Enable and Disable for all selected rows, an Active tick box in Edit, a Status column (who disabled them and when, on hover), a filter All / Active only / Disabled only, and Status in the CSV export. Disabled people show as Disabled in the search suggestions. AD and Microsoft 365 are not touched.
- **Sign-in lock:** after **5 wrong passwords** in a row the sign-in page is locked for **15 minutes** (was 60 seconds). The page shows how many attempts are left, then a countdown; after 15 minutes you can sign in again. The lock is kept in login-lock.json, so restarting the tool does not undo it. To unlock early on this PC: stop the tool and delete login-lock.json.

## 1.98.9 - Login expiry date and AD check
- Settings > Users: every tool login can have an **expiry date** (optional). It works until the end of that day; after that the person cannot sign in to the portal, and anyone already signed in is signed out.
- Optional **linked AD account** (sAMAccountName): the person cannot sign in when that AD account is **expired or disabled** - so either the portal date OR AD expiry blocks the sign-in. "Check now" tests the AD account. AD is checked at every sign-in and every 10 minutes during a session. If AD cannot be checked, sign-in is refused (safe side). AD is read with the tool's AD sign-in if there is one, otherwise with this PC's own Windows account.
- The sign-in page says why (expired here, expired in AD, disabled, not found). The owner login (Change-Login.bat) is never blocked.

## 1.98.8 - People database, custom signature, search suggestions
- **People database** (new screen): first name, last name, username, email, department, phone, note. Add, edit, remove, import and export CSV. Saved in people-db.json (previous version kept as people-db.bak.json). New permission "People database".
- **Link with Active Directory is optional**: a switch on the screen. When on (and signed in to AD) you can import people from AD, link a record to an AD account, and refresh linked records from AD. Nothing is written to AD.
- **Custom e-mail signature**: Settings > Email sender > Signature: Standard (as before) or Custom (designer with name, job title, department, phone, email, website, logo, colour - or your own HTML). Live preview and Send test e-mail. Used by every e-mail the tool sends.
- **Suggestions while typing** in the user search boxes (Cloud password, Account status, Revoke MFA, On-premises AD): username, UPN, email, display / first / last name and description, from AD, Microsoft 365 and the People database. Arrow keys + Enter or click to pick.
- **Change name on On-premises AD** now fills in the current first, last, display and full name, plus description and email (new). Changed boxes are highlighted with the old value under them; only changed values are saved.
- **Password e-mails in order**: for several users, paste one address per line - line 1 goes to user 1, line 2 to user 2, and so on.
- Fixed: Microsoft 365 showed as signed in although the Microsoft Graph session had ended ("Authentication needed. Please call Connect-MgGraph"), so the screens were not locked. The tool now checks the real session and locks the Microsoft 365 screens until you sign in again.
- Fixed: Settings > Connections stayed dark navy in the light theme.

## 1.98.7 - Menu moved to the sidebar (rebuilt from 1.98.6)
- All screen buttons (Home, Cloud password, Account status ... Settings) are now a list in the left sidebar instead of the row at the top.
- New "Hide menu" button in the sidebar. When hidden, move the mouse to the left edge and the sidebar slides in; move away and it hides again. "Keep menu open" (or the menu button at top left) brings it back for good. The choice is remembered.

## 1.98.6 - First-run question
- First run: on the first start, the tool asks whether you want to run in the background (minimized) or with a visible window
- Saves your choice in app-defaults.json and uses it for all future starts
- You can change this choice in Settings later

## 1.98.5
- The tool is now called **Admin Console** everywhere (page titles, header, sign-in page, start-up messages, worker windows, .bat files).
- On a screen that needs a sign-in you have not done yet, every button and field is now really locked (disabled, grey, with a tooltip) - not only greyed out. They unlock by themselves as soon as you sign in.

## v1.98.4 - Every screen shows a sign-in banner when it needs one  (2026-10-02)

- Every screen that needs Microsoft 365 or on-premises AD now works like the On-premises AD screen: it is always shown, but greyed out with a banner 'You have to sign in to ...' and a Sign in button (or click anywhere) that opens Settings > Connections; after signing in you come straight back. Microsoft 365: Cloud password, Revoke MFA, Teams members, Distribution groups, Shared mailbox, Guest users. On-premises AD: Bulk & report. Account status and Audit & event logs work with either one: locked only when you are signed in to neither, otherwise a blue note says which part is skipped.

## v1.98.3 - On-premises AD screen always visible, sign-in required  (2026-10-02)

- On-premises AD screen: everything is now always shown. Until you sign in to AD it is greyed out with a banner 'You have to sign in to on-premises AD' and a Sign in to AD button; clicking anywhere on the screen also opens Settings > Connections with the AD username box ready. After you sign in you are taken straight back to the On-premises AD screen.

## v1.98.2 - E-mails follow light/dark, new signature, sign-in moved to Settings  (2026-10-02)

- Every e-mail the tool sends (password, Temporary Access Pass, guest invitation, shared mailbox) now follows the reader's device: normal in light mode, proper dark colours in dark mode (Apple Mail, Outlook for Mac, iPhone, Android and Outlook on the web; Outlook for Windows darkens e-mails by itself).
- New e-mail signature: a short blue line, the first line in bold and the other lines (department, phone, email) smaller and grey; on the right side under the Arabic part. The signature box in Settings > Email sender now has several lines.
- Microsoft 365 and on-premises AD sign-in (and the portal timeout) moved from the sidebar to the new Settings > Connections. The new M365 / AD button at the top right shows both (green = signed in) and opens it.

## v1.98.1 - Guest users screen redesigned  (2026-10-02)

- Guest users redesigned: a step strip at the top shows what is done and what is next (guests, invitation, Teams, invite); numbered cards; the four ways to send are shown as tiles (Both is marked Recommended); every guest you type appears as a name chip; the results start with totals (invited, re-sent, already in your organization, failed). Works in light and dark mode.

## v1.98.0 - Dark mode and a new look for Home, Settings and Audit logs  (2026-10-02)

- Dark mode for the whole portal, the login page included. Choose Auto (follow this device: Windows light or dark, and it changes by itself when Windows changes), Light or Dark - with the button at the top right or in Settings > Appearance. Each browser remembers its own choice.
- Home redesigned: a welcome banner with today's date and live status (Microsoft 365, on-premises AD, who is signed in to the tool, version), and the screens grouped by Microsoft 365 accounts, Exchange Online and Teams, On-premises AD, and Reports and administration.
- Settings redesigned: a menu on the left with an icon for every section and the chosen section on the right; new Appearance section.
- Audit & event logs redesigned: one-click quick reports (failed sign-ins, sign-ins of one user, password resets and user changes, group changes, AD accounts and lockouts, AD group changes), bigger source choice, and a results table whose header stays visible while you scroll.

## v1.97.4 - Port 8080; guest invitations can be sent again  (2026-10-02)

- The tool now runs on port 8080: the page is http://supporttool:8080 (or http://localhost:8080). An older copy still running on 8765 is stopped when the new one starts.
- Guest users: new option 'Already a guest? Send the invitation again' (on by default). People who are already guests get the invitation again - from Microsoft, from the sender mailbox, or both, whichever you chose. Accounts of your own organization (members) are never invited.
- Guest users: new way to send - 'Both: Microsoft and the sender mailbox' - so the guest gets Microsoft's invitation and your own email with the same link. Also available as the default in Settings > Defaults.
- Guest users: the results now say exactly what Microsoft did. Microsoft's email comes from invites@microsoft.com (often in Junk); when Microsoft reports the invitation as already accepted it may send nothing, and the results say so.

## v1.97.3 - Settings always visible; old running version replaced  (2026-10-02)

- New Settings button at the top right of every screen (next to Session), so Settings - including Users - is always one click away.
- The row of screen tabs now wraps onto a second line instead of hiding Distribution groups, Shared mailbox, Guest users, Audit & event logs and Settings off the right edge.
- Starting the tool while an older version is still running in the background (from this or another folder) now stops the old one and starts this version, instead of opening the old page.
- The page is never kept in the browser cache, so a new version shows at once; the version number is shown under the Admin Console name.

## v1.97.2 - Log viewer role and sign-in log window  (2026-10-02)

- New permission 'See all logs' and a new role 'Log viewer' (can only read the logs, nothing else). Owner and administrators always see everything.
- Sign-ins window (Activity log > Sign-ins): every sign-in, failed attempt, refusal, logout and timeout with username, IP address, PC name and the Windows user on the server; filter by period and text, download CSV.
- Everyone else now sees only their own actions in the Activity log window (checked on the server); the activity log shows what each tool user did, with their name, IP and PC.

## v1.97.1 - Logs show which PC every user signed in from  (2026-10-02)

- Every tool sign-in (successful, failed, refused, logout, expired) now records the IP address and, when the network can name it, the PC name the person signed in from. A sign-in from the PC the tool runs on shows as 'this PC'.
- These two columns (ClientIP, ClientPC) are in the login audit log and in the activity log, so every action also shows which PC it came from. Both logs are saved on the PC running the tool and copied to SharePoint with the other logs; older files get the new columns added to their header.
- The Activity log window shows 'From <IP> (<PC name>)' under who did it, and the CSV download includes both columns.

## v1.97.0 - Settings: accounts for other users (Helpdesk) with their own permissions  (2026-10-02)

- Settings > Users (new): create sign-in accounts for other people - for example a Helpdesk - with a username and password, a role (Administrator, Helpdesk, View only or Custom) and tick-box permissions such as reset passwords, send the password e-mail, enable/disable/unlock, MFA, AD changes, bulk, Teams, distribution groups, shared mailboxes, guests, audit logs, tool settings.
- The rules are enforced on the server, not only by hiding buttons: a user without permission gets a clear message, and any action not listed for a permission is administrators-only. On the AD screen a request that only resets passwords counts as 'reset passwords'; groups, expiry, names, UPN and enable need 'On-premises AD changes'.
- Passwords are stored only as salted hashes in tool-users.json. You can set or generate a password, ask the person to choose their own at first sign-in, disable an account without deleting it, or remove it. The owner login (Change-Login.bat) is unchanged and always works; nobody can lower, disable or remove their own account.
- Only one person can be signed in at a time, because the Microsoft and AD sign-in belong to the whole tool. A Helpdesk user is refused while someone else is signed in; the owner or an administrator signing in takes over.
- Menus, Home cards and Settings sections a person may not use are hidden. Settings has a My account section where they change their own password. The activity log has a new ToolUser column, and the Activity log window shows the tool user.

## v1.96.0 - New screen: Settings - every setting in one place  (2026-10-02)

- Settings: one screen with six sections - Sign-in and session, Email sender, Email messages, Logs and cloud copy, Defaults, and Version and about. The old Email messages and Log settings tabs now live inside it (the old links #email and #logs and the sidebar 'Log settings' link open the right section).
- Sign-in and session shows the sidebar information (who is signed in to Microsoft and AD, auto sign-out, portal timeout, Graph permissions) with the same controls - changing one changes the other. The sidebar itself is unchanged.
- Email sender is the old Email settings window as a normal section. Defaults is new: how guest invitations are sent, the page guests land on, and whether the shared mailbox 'email each person' option is ticked by default - saved in app-defaults.json (new file Screen-Settings.ps1).
- Version and about shows the version, release date, address and the full version history inside Settings; the sidebar version line still works as before.

## v1.95.0 - Names in e-mails: first name, last name or both, from your tenant  (2026-10-02)

- Email messages: new placeholders {first}, {last}, {full} and {greet}. A new box 'Name in the greeting' on each e-mail chooses what {greet} shows: first name, last name, or first and last name together. The standard greetings now use {greet} (first name by default, so nothing changes until you choose).
- The name is read from the person's own account in your tenant (Microsoft Entra first name and last name; for AD-only accounts from Active Directory) - not from the address the e-mail is sent to (Gmail, Yahoo ...) and not from a name typed by hand. Password, Temporary Access Pass and temporary password e-mails use the owner of the reset account. Shared mailbox e-mails use each recipient's own account, not the mailbox that was converted.
- If no first and last name is stored, the display name is split into first word and the rest. Guest invitations use the name you typed for the guest (whole name by default).

## v1.94.0 - Email messages: language order and a picture  (2026-10-02)

- Email messages: choose for each e-mail which language is on top - English on top with Arabic below, Arabic on top with English below, English only, or Arabic only.
- Email messages: add one picture (logo or banner, PNG/JPG/GIF up to 500 KB) to each e-mail, at the top or the bottom, with the width you choose. The picture is sent inside the e-mail as an inline attachment and shows in the live preview.
- The big buttons at the top of the screen now open one e-mail each; an Edited tag shows which ones you changed. Reset to default also removes the picture and puts the language order back.

## v1.93.0 - New screen: Email messages  (2026-10-02)

- Email messages: a new screen to edit the wording of every e-mail the tool sends - password reset (on-premises AD), Temporary Access Pass, temporary password (cloud), guest invitation, shared mailbox instructions and the 'your mailbox is a normal mailbox again' notice. English and Arabic side by side, plus the subject.
- A live preview shows the real e-mail with sample data (pick variants such as one-time password, single-use pass or the access rights), one click inserts names like {first} or {upn}, there are Bold and Link buttons, and every text - or a whole e-mail - can be reset to the original wording.
- Your changes are saved in email-templates.json next to the tool and used from the next e-mail, with no restart. The original wording stays built into the tool. The Guest users and Shared mailbox screens start from the saved subject. Guest invitations can also get an Arabic part (empty by default). Every save is written in the activity log.

## v1.92.0 - Shared mailbox: email the people, convert back to a normal mailbox  (2026-10-02)

- Shared mailbox: new 'Tell the people by email' option. When you convert a user mailbox to a shared mailbox (or just give people access) the tool can email EACH person, one by one, how the shared mailbox works: what access they have, how to open it in Outlook on the computer and in Outlook on the web (and on a phone), how to send as the shared mailbox, and that there is no separate password. English with Arabic below. You can also include the people who already have access, add more addresses, and write your own message.
- The emails are sent after the changes succeed, from a sender mailbox you choose - never from your own account - and only to people whose access was really given. Every email is written in the activity log and the mail log.
- Shared mailbox: converting a shared mailbox back to a normal (user) mailbox is now a clear option ('Convert to a normal (user) mailbox'). It warns when the account has no license (without one Microsoft removes the mailbox after 30 days), can allow sign-in again in the same step, and can email the person that it is a normal mailbox again with sign-in and password-reset links.

## v1.91.0 - Sign-in details: MFA, method, location, Conditional Access  (2026-10-02)

- Sign-in logs now answer the questions in plain words: success or failure, why it failed (the error code translated: wrong password, account locked, MFA denied, ...), the IP address, the location (city and country), whether MFA was required or not and whether it was completed, which sign-in method was used (password, Authenticator ...), every authentication step, and which Conditional Access policy blocked the sign-in. The device state, browser, risk, user Id and correlation Id are included too.
- Click any row to see every detail of that sign-in or change; the CSV / JSON export has all columns. A new box 'Include MFA and Conditional Access details' (on by default) can be unticked for a faster, shorter read.
- On-premises AD sign-in events (4624 success, 4625 failed, Kerberos and NTLM) now show Success / Failure, the IP address, the computer name, the sign-in type (for example Remote Desktop) and the reason (wrong password, account locked, disabled, expired ...).

## v1.90.0 - Logs are copied to the cloud automatically  (2026-10-02)

- Logs are copied to the cloud (SharePoint) automatically: the moment you sign in to Microsoft (or switch to another account) the logs that were waiting are copied by themselves - no need to open a screen, tick a box or press Sync. It is on by default, also for settings saved by older versions.
- Log settings has one switch, 'Copy the logs to the cloud (SharePoint) automatically'. Untick it to keep the logs on this computer only; it is saved at once, no Save button needed.

## v1.89.0 - Log searches run in the background, with Stop  (2026-10-02)

- Audit & event logs now run in the background: a log search no longer blocks the tool. While it reads you can open any other screen (reset passwords, MFA, AD changes ...) and work as usual; an orange dot on the Audit & event logs tab shows it is still reading and a green tick shows the logs are ready.
- New 'Stop searching' button: stops the search at once (cloud and AD) and nothing is kept. The search settings are locked while it runs so the result always matches what you chose. Each search and each stop is written in the activity log.

## v1.88.1 - Faster Microsoft 365 logs  (2026-10-02)

- Audit & event logs: much faster Microsoft 365 logs. Pages of up to 999 rows instead of 100 (about ten times fewer round trips to Microsoft), only the sign-in fields that are shown are downloaded (the full sign-in record is large), and lighter processing on this PC.
- The screen now starts with the last 24 hours and 200 rows (change them when you need more), counts the seconds while it reads, tells you how long it took, and says when Microsoft itself is slow. A user's email makes sign-ins faster because Microsoft filters it on its side.

## v1.88.0 - Users carry over between screens  (2026-10-02)

- Users carry over between screens: the users you typed or searched on one screen (Cloud password, Account status, Revoke MFA, On-premises AD, Bulk & report, Audit logs) are filled in on the next of those screens when it is empty, with a blue bar that says where they came from and an Undo button. When the next screen already has something typed, the bar offers 'Use them here' instead. Nothing you typed on a screen is replaced when you come back to it.

## v1.87.0 - On-premises AD: choose what to search in  (2026-10-02)

- On-premises AD: new 'Search in' tick boxes above the search box - All, Username, User principal name, Email, Name and Description. Leave All ticked to find a user when anything matches, or tick only one (for example only the User principal name, or only the Description) so nothing else is searched. Works for one user and for several users. The choice is remembered on this device.

## v1.86.0 - Audit and sign-in logs together  (2026-10-02)

- Audit & event logs: the new choice 'Both together' (now the default for Microsoft 365) shows the audit log (changes) and the sign-ins in ONE list for the same period, sorted by time, with a Log column (Audit or Sign-in). Type a user's email to see everything about that person in both logs.
- Download CSV or JSON exports both together. If only one of the two logs can be read (for example sign-ins need Entra ID P1) the other one is still shown, with a note.

## v1.85.0 - New screen: Audit & event logs  (2026-10-02)

- New screen Audit & event logs (address #audit, also on Home and in the menu). It only reads - nothing is changed.
- Microsoft 365: the audit log (who created, changed, reset or deleted users, groups, roles and apps, with what changed) and the sign-in log (who signed in, from where, success or failure). Choose the period (up to 30 days), the category and 'only failures'.
- On-premises AD: the event logs of a domain controller - user accounts created, changed, enabled, disabled, deleted, locked out, unlocked, password resets; group members added or removed; successful and failed sign-ins; plus the Directory Service, System and Application logs. Read with the AD account you signed in with.
- Filter by a name, email, group or IP address, search inside the result, and download everything as CSV (device time and UTC) or JSON. Times are shown in the time zone of this device. Every export is also kept in the logs folder like the other exports.
- New Microsoft permission AuditLog.Read.All (and Directory.Read.All): sign out of Microsoft and sign in again; an administrator may need to approve it once.

## v1.84.0 - New screen: Guest users  (2026-10-02)

- New screen Guest users (address #guests, also on Home and in the menu): invite outside people as guests (Microsoft Entra B2B) - one guest (name optional and email) or several (a typed or pasted list, one per line: email, Name <email> or Name, email - or a CSV / text file). Duplicates and invalid addresses are shown and ignored.
- The invitation: Send it from a sender mailbox (default) - the tool creates the guest without Microsoft's own email and then emails the personal invitation link from the sender you type (it is remembered and offered next time), never from your own account (your own address is refused), with your custom message and the Accept invitation button; Let Microsoft send it - Microsoft's standard invitation with your message in it; or Do not send anything - only create the guests and show the links. Your account needs Send As (or Send on behalf) on the sender mailbox, like the password emails.
- Teams: the screen asks whether to add the guests to a Microsoft Teams group (No / Yes). With Yes, search and choose one or more teams; the guests are added as members as soon as they are created (a guest who is already in your organization is not invited again but is still added to the team). If you press Invite without answering, the tool asks first. Before anything is sent a Yes / No confirmation says exactly what will happen.
- The results show each guest as Invited / Already a user / Failed, how the email went, the Teams result and a Copy link button, with Download CSV. Everything is written to the activity log, the mail audit and the Teams audit (never the message text). The Microsoft sign-in now also asks for User.Invite.All - sign out and in again once (an administrator may have to approve it). New file in the zip: Screen-GuestUsers.ps1.

## v1.83.0 - Start and stop run as administrator by themselves  (2026-10-02)

- SupportTool.exe, SupportTool-Stop.exe and Start.bat elevate by themselves (UAC); /normal (Start.bat normal) starts without administrator rights.
- supporttool no longer refused because of a cached unknown name (flushdns; only a real hosts-file failure falls back to localhost).

## v1.82.4 - Stop button in the start-up window  (2026-10-02)

- SupportTool.exe start-up window: Stop (Yes / No) ends the start-up and closes the tool; Try again starts it again. EXE rebuilt.

## v1.82.3 - Restart as administrator closes a tool that does not stop  (2026-10-02)

- After 12 s without a clean stop, the old tool PowerShell is closed by its port (administrator only; only powershell / pwsh), then the tool starts as administrator. EXE rebuilt.

## v1.82.2 - Run as administrator really gives http://supporttool  (2026-10-02)

- A tool already running without administrator rights is restarted when you start as administrator, so the page is http://supporttool. The start-up window says why when supporttool cannot be used. SupportTool.exe rebuilt.

## v1.82.1 - Start normally = localhost, as administrator = supporttool  (2026-10-02)

- No automatic administrator prompt: normal start = http://localhost:8765, Run as administrator = http://supporttool:8765. SupportTool.exe rebuilt (/admin to elevate on request).

## v1.82.0 - Session menu and closing the tab  (2026-10-02)

- Session button at the top right: Sign out of Microsoft and AD, Log out of the portal, Shut down the server - each with Yes / No. The sidebar buttons are removed.
- When I close the tab: keep running (default), sign out, or shut down (server waits 12 s and cancels if a page comes back). Ask me first = the browser Leave / Stay confirmation.

## v1.81.1 - Log folder: Modify and Default  (2026-10-02)

- Logs on this PC: the default folder is shown locked; Modify lets you type another folder (Save folder / Cancel); Default goes back to the default folder.

## v1.81.0 - Log settings screen  (2026-10-02)

- New screen Log settings (#logs; Home card; Log settings link in the Logs card): time zone of the logs (device or fixed), the folder of the logs on this PC, and the SharePoint copy (on/off, site, library, folder, status, Sync now).
- Saved in log-settings.json and sharepoint-settings.json.

## v1.80.5 - Logs use the time zone of your device  (2026-10-02)

- All logs are stamped with the clock and time zone of the device the page is open on (sent by the browser with every request). New TimeZone column in the activity log. SharePoint status time no longer depends on the PC time zone.

## v1.80.4 - Sign in with the window is the main button again  (2026-10-02)

- The sign-in window (worked before) is the main button; the browser account list is the second choice (AADSTS700016 in some tenants).

## v1.80.3 - Organization box for the browser sign-in  (2026-10-02)

- Optional Organization box in the account pop-up: the browser sign-in goes to that organization (domain or directory ID) - for AADSTS700016.

## v1.80.2 - No more Windows protected your PC message  (2026-10-02)

- New Allow-Tool.bat / Allow-Tool.ps1: run once (administrator) to remove the downloaded-from-the-internet mark from all files and to sign the two EXE files with a certificate made on the PC. Start.bat also unblocks the files at every start.

## v1.80.1 - Microsoft sign-in with the accounts of your browser  (2026-10-02)

- Connect takes the browser to Microsoft's own account page, which lists the accounts signed in in that browser; after you pick one the browser returns to the tool, signed in. Browser cookies are never read by the tool; tokens stay in memory only and are renewed automatically.
- New file: Screen-MsLogin.ps1. Sign-in window instead (the old way) is still in the pop-up.

## v1.80.0 - Home screen  (2026-10-02)

- New Home screen (#home), the first screen: a card for every screen with what it does and what it needs. Click a card to open it; Home in the menu comes back. The tool opens on Home.

## v1.79.0 - Choose a Microsoft account when connecting  (2026-10-02)

- Connect (Microsoft sign-in) opens a pop-up, Choose a Microsoft account, listing accounts found on this PC: used before in this tool, the work/school account of this Windows sign-in, and the accounts signed in to Edge, Chrome and Brave profiles. Click one, or Use another account.
- The tool reads only the email addresses and names the browsers keep in their profile folders (never passwords, cookies or tokens). Microsoft's window still asks for password / MFA; if it signs in as a different account than chosen, the tool says so. Used accounts are remembered in accounts.json (last 10).
- New file: Screen-Accounts.ps1.

## v1.78.0 - Email the password from On-premises AD  (2026-10-01)

- On-premises AD: after a password reset the tool asks 'Send the new password by email?' (and an Email passwords button is in the results). It uses the same email window as Reset cloud passwords - your sender mailbox, several To addresses and Cc, the suggestions (alternate email, manager, their own mailbox, and the email address stored in AD for accounts that are only in AD) - and the results table shows Emailed to ... for each user.
- The email (English, with Arabic below) says, for a one-time password: 'This is a one-time password. You must change it the first time you sign in'; for a normal password: 'This is your password. If you want to change it, go to (website)'. Both recommend Microsoft Authenticator: set it up at aka.ms/mysecurityinfo, and then in the future reset the password yourself at aka.ms/sspr without contacting IT support.
- The three websites can be changed in Email settings (change password website - by default mysignins.microsoft.com/security-info/password/change - self-service password reset, and security info). As before, the password is never sent back from the browser, never saved on disk and never logged.

## v1.77.0 - Temporary Access Pass: 1 to 8 hours  (2026-10-01)

- Reset cloud passwords: the Temporary Access Pass lifetime is now 1 to 8 hours only - Valid for 1, 2, 3, 4, 5, 6, 7 or 8 hours (1 hour is the default). The shorter (10 to 30 minutes), longer (10 hours to 30 days) and Custom choices are gone, and the tool refuses any other lifetime.

## v1.76.0 - Password emails in English and Arabic  (2026-10-01)

- Password emails are now in English and Arabic: the Arabic version follows below the English one in the same email, right to left - the same greeting, the pass or password in its box, the deadline (for a Temporary Access Pass, for example: within one hour - before Thursday 1 October 2026 9:57 PM, with Arabic day and month names), the steps to sign in at aka.ms/mysecurityinfo and change the password, and the safety note. Only the email changed; the screens of the tool are the same.

## v1.75.0 - Temporary Access Pass email: steps, deadline and subject  (2026-10-01)

- Temporary Access Pass emails now tell the user exactly what to do: sign in at aka.ms/mysecurityinfo (a link) with their university account and the pass, then change their password (and set up Microsoft Authenticator if asked). The email says it is mandatory within the lifetime you chose for the pass (for example within 1 hour) and gives the exact deadline (for example before 9:51 PM on Thursday 1 October 2026), and that the pass stops working after that (and works only once, when one-time use was ticked).
- Temporary Access Pass emails have their own subject - by default 'Your university account password'. It can be changed in the send window (it is remembered) and in Email settings, where there are now two subjects: one for temporary passwords and one for Temporary Access Passes. Temporary password emails are unchanged.

## v1.74.0 - Start-up window in SupportTool.exe; Microsoft sign-in fix  (2026-10-01)

- Fix: Connect (Microsoft sign-in) failed with 'InteractiveBrowserCredential authentication failed: A window handle must be configured' after starting the tool with SupportTool.exe. Newer Microsoft Graph modules sign in through the Windows sign-in broker (WAM), which needs a window to attach to, and SupportTool.exe started PowerShell with no window at all. It now starts it with a hidden window (never shown), the server makes sure that hidden window exists before signing in, and if the Windows sign-in still refuses, Connect tries again through the web browser; if that is not possible either, the message says exactly what to do instead of the raw error.
- SupportTool.exe now shows a start-up window (not PowerShell) with every step while the tool starts: the Admin Console files, the port, the tool login, each Microsoft Graph module - installed (with version), installing (and which version), waiting, or failed - loading Microsoft Graph, the Exchange Online module (installed or not), the screens and the web page. When everything is ready it says Ready, opens the page and closes by itself after a few seconds; the tool keeps running in the background with no window. Continue in background closes the window early.
- If something fails, the start-up window stays open with the reason in red, Open logs folder and Try again. Missing Graph modules are installed in the background with their progress shown here (no PowerShell window). Only the very first login setup still opens a window, because the username and password have to be typed there - the start-up window says so and carries on afterwards.

## v1.73.0 - People search on Shared mailbox; start and stop with EXE files  (2026-10-01)

- Shared mailbox: you can now search people. In Give access to, start typing a name, email or username and pick the person from the list (arrow keys and Enter, or click) - add as many as you need; disabled accounts and guests are marked. A full email typed by hand still works, and pasting a list too. Find the mailbox searches the same way: pick a person and the mailbox is looked up straight away. The search uses your Microsoft sign-in, so it is instant and does not wait for Exchange Online.
- New: SupportTool.exe starts the tool with no window (it asks for administrator rights, like Start.bat, so http://supporttool works). If the tool is already running it just opens the page. The first time (login setup, or installing Microsoft Graph) a window still appears once, because questions have to be answered there.
- New: SupportTool-Stop.exe shuts the tool down - the same as the Shut down button: it signs out of Microsoft, on-premises AD and Exchange Online, writes the shut-down in the activity log and copies the logs to SharePoint first. If the tool does not answer within 20 seconds it closes the tool's PowerShell processes (asking for administrator rights if needed). It tells you when it is done, or that the tool was not running.
- Tip: right-click SupportTool.exe and SupportTool-Stop.exe > Send to > Desktop (create shortcut). Windows may show 'Windows protected your PC' the first time, because the files are not signed - choose More info > Run anyway. The source code and Build-Exe.bat are in the exe-source folder, so your IT can check them and build the two files themselves with the compiler that is part of Windows. Start.bat and Start-Visible.bat still work.

## v1.72.0 - No PowerShell windows  (2026-10-01)

- No PowerShell windows any more. Start.bat checks everything (and asks the first-time login questions if needed) and then restarts the tool in the background with no window; the page opens by itself. Stop the tool with Shut down in the page. Starting it again while it is already running just opens the page. If it cannot start (for example the port is used by another program), a normal Windows message box says why, and the reason is saved in logs\server-errors.txt. Start-Visible.bat (new) runs it with the PowerShell window like before - only for troubleshooting.
- The Exchange Online connection (Distribution groups and Shared mailbox) runs with no window again, and now signs in through your web browser: a Microsoft sign-in page opens there (or it signs in by itself if you are already signed in) - this is what failed from a hidden window before. If the installed ExchangeOnlineManagement module can only sign in through a window, the screen asks you to update it. 'Open sign-in window' is replaced by Sign in again, which also restarts a sign-in that is stuck.
- Installing or updating the Exchange Online module no longer opens a PowerShell window: it runs in the background and the screen shows Installing..., then Installed (with the version) or the reason it failed. The button is on Distribution groups and Shared mailbox.
- With no window, the Microsoft (Graph) sign-in in the sidebar also uses the web browser when your Microsoft Graph module supports it, for the same reason.

## v1.71.0 - Fix: Exchange Online sign-in window  (2026-10-01)

- Fix: the Exchange Online connection (Distribution groups and Shared mailbox) did not connect. Since v1.62 it ran in a hidden PowerShell window, and the Microsoft sign-in needs a real window to show itself - from a hidden window it can fail or never appear. It now runs in a minimized window (it shows in the taskbar as 'Admin Console - Exchange Online worker'), like the old Distribution Group Manager worker that ran in a normal window.
- New button Open sign-in window (on both screens, when not connected): starts the Exchange Online connection in a normal PowerShell window, so you see the Microsoft sign-in and every message. If it fails, that window stays open with the error until you press Enter, and the same text is shown in the tool. A sign-in that is stuck is closed first, so there are never two connections.
- While the sign-in waits for more than 40 seconds, the screen says so and where to look (behind other windows or in the taskbar), instead of looking frozen.

## v1.70.0 - Fix: Exchange Online not connecting  (2026-10-01)

- Fix: Exchange Online (Distribution groups and Shared mailbox) could stay Not connected after updating. Three causes are now handled: (1) the hidden Exchange Online connection of the previous version kept running in the background after the files were replaced - the tool now sees which version the connection belongs to and restarts it with the new one by itself; (2) newer ExchangeOnlineManagement modules sign in through the Windows broker (WAM), which fails in the hidden background window ('A window handle must be configured') - the tool now tries again with the normal Microsoft sign-in window; (3) while the Microsoft sign-in window waited for your password or MFA, the connection was shown as not answering after 30 seconds - it now waits up to 5 minutes.
- When Exchange Online cannot connect, the screen now shows the real reason under the status ('Details from the Exchange Online connection'): the sign-in error, the PowerShell and module versions, or - if DistGroups-Worker.ps1 is damaged or from another zip - the exact line Windows PowerShell cannot read. The worker also keeps these in DistributionGroups\WebUI_Jobs\worker-errors.txt.

## v1.69.0 - New screen: Shared mailbox  (2026-10-01)

- New screen: Shared mailbox (address #shared). Type a user's mailbox and press Look up to see its type (user or shared mailbox), size, number of items, archive and litigation hold, whether sign-in is allowed, its licenses, and everyone who already has Full Access, Send As or Send on behalf.
- Convert to a shared mailbox (or back to a user mailbox) and, in the same step, give one or more people access: Full Access (with 'Show it in their Outlook automatically' - auto-mapping), Send As and / or Send on behalf. Type people by email or username and press Enter to add more. Tick Remove next to a person to take an access away. 'Block sign-in for this account' is ticked for you when you convert (recommended - the people with access still open the mailbox; cloud accounts only).
- Warnings before you convert: over 50 GB, archive on or litigation hold on (keep the license), forwarding, and after converting a reminder that the licenses can be removed in the Microsoft 365 admin center when they are no longer needed. Nothing is deleted - the account and all mail stay.
- It uses the same Exchange Online connection as Distribution groups (your Microsoft sign-in, connects by itself when you open the screen). The result shows every step as Done or Failed with the reason, the Exchange log, and a Download CSV; the mailbox details are read again afterwards. Every step (convert, each person's Full Access / Send As / Send on behalf, removals, block sign-in) is written in the activity log and copied to SharePoint. New file in the zip: Screen-SharedMailbox.ps1 (DistGroups-Worker.ps1 is updated too). Your account needs an Exchange admin role (Exchange Administrator or Recipient Management).

## v1.68.0 - Email the password to several people  (2026-10-01)

- Email the new password: you can now send it to two or more people per user. 'Send to' is an address list: each address is shown as a chip with an x to remove it. Click several suggestions (Alternate email, Manager, Their own mailbox - a tick shows which are added; click again to remove), or type an address and press Enter, ; or , to add another; pasting a list also works. Up to 5 addresses per user. An address that is not valid stays in the box in red and is not sent.
- Cc works the same way, so several people can get a copy of every email. The confirmation and the activity log show every recipient and Cc.

## v1.67.1 - Fix: Microsoft sign-in error  (2026-10-01)

- Fix: Connect (and sign-out) failed with 'A positional parameter cannot be found that accepts argument Microsoft sign-out (new sign-in)'. The sign-out helper added in 1.66.0 was called Disconnect-Graph, but the Microsoft Graph module already has an alias with that name, and PowerShell runs an alias before a function - so Microsoft's Disconnect-MgGraph was called with text it does not accept. The helper is now called Exit-StGraph; signing in, signing out, auto sign-out and shut-down work again, and the sign-out is written in the activity log and the logs are copied to SharePoint first, as intended.

## v1.67.0 - Exports, password copies and emails in the synced logs  (2026-10-01)

- Exports are now kept and synced too: every CSV you download on any screen (account status, reset results, MFA results and logs, On-premises AD changes, Bulk & report and user reports, Teams members and results, Distribution groups run files, the activity log) is also saved on this computer in logs\exports\<yyyy-MM>\<date_time>_<file name>, copied to SharePoint in Admin Console / <yyyy-MM> / <computer> / Exports /, and written in the activity log (who exported which file, from which screen, how many rows). Only the empty bulk template is not kept.
- Passwords in the audit: the activity log now says whether a reset was a one-time password (must change at next sign-in) or a normal password, and whether a Temporary Access Pass was one-time use. Revealing or hiding the passwords and copying a password or pass (Reset cloud passwords and On-premises AD) are logged with the user - the password itself is never logged.
- Emailed passwords: the activity row now shows the sender, the recipient and the Cc (for example Done - Sent from ali@contoso.com (to: khalid@contoso.com; cc: salman@contoso.com)).
- Faster sync: changed logs and exports are copied to SharePoint about 1 second after each action (was a few seconds), and the Logs card refreshes sooner.

## v1.66.0 - Activity log for every screen, copied to SharePoint  (2026-10-01)

- New: one activity log for every screen. Every action is written down with the time, the computer, the Windows user, the Microsoft account and the AD account used, the screen, what was done, to which user (one row per user), the result (Done / Failed with the reason) and the options used. This covers password resets, Temporary Access Passes, password emails, enable/disable, Revoke MFA, every On-premises AD change, Bulk & report, Teams members, Distribution groups jobs, look-ups, tool login/logout, Microsoft and AD sign-in/sign-out (also automatic sign-outs) and setting changes. Passwords, passes, certificate thumbprints and tokens are never written.
- Saved on this computer in logs\activity\<yyyy-MM>\activity-<yyyy-MM-dd>.csv (a new file every day, a folder per month). The older per-screen logs (reset-audit, mfa-audit, onprem-audit, teams-audit, dg-audit, mail-audit, login-audit) are still written as before.
- Copied to SharePoint: https://stuuobedu.sharepoint.com/sites/Logs, library Documents, folder Admin Console / <yyyy-MM> / <computer name> / - the folders are created automatically, and each helpdesk PC has its own folder so they never overwrite each other. A few seconds after your last action (while the tool is idle) every log file that changed is uploaded again, so SharePoint stays up to date; on sign-out and shut-down the logs are copied first. If you are not signed in to Microsoft or SharePoint cannot be reached, nothing is lost: the files wait on this computer and are copied at the next sign-in (failed uploads are retried every 2 minutes).
- Logs card in the sidebar: shows whether SharePoint is up to date or how many files are waiting (and why), with Activity log (view and filter today, 7 or 31 days by screen or text, Download CSV), Sync now, Settings (switch the copy on/off, site, library, folder), Local folder (opens the logs folder in Explorer) and Open in SharePoint.
- The Microsoft sign-in now also asks for Sites.ReadWrite.All so it can write to the site (your account must be able to edit the site - as an owner you can). Sign out and in again once after updating. With a certificate sign-in the app registration needs the Sites.ReadWrite.All application permission. New file in the zip: ActivityLog.ps1.

## v1.65.0 - Reset cloud passwords: email the new password to the user  (2026-10-01)

- In the send window you can type the sender yourself (From - for example ali@contoso.com), change the recipient for each user (To - for example khalid@contoso.com, or several separated by ;) and add Cc for anyone who should get a copy of every email (for example salman@contoso.com). The From box lists the senders used before, and the last sender and Cc are remembered for next time. Your own address is never accepted as the sender.
- Reset cloud passwords: after a reset, the tool asks 'Send the new password by email to the user?'. Yes opens a list of the users that were reset, with a tick box per user, Select all, and the address to send to. The user cannot open their own mailbox before they sign in, so their alternate (personal) email from Entra is suggested first, then their manager; their own mailbox can still be picked (with a warning) or any address typed (several separated by ;). Each row shows Sent or Failed with the reason, and the results table shows Emailed to ...
- The email is sent from a separate sender mailbox that you set once in Email settings (on the Email the password panel, or Change in the send window) - for example a shared mailbox like it-noreply@contoso.com. Your own address is refused as the sender. Your account needs Send As (or Send on behalf) on that mailbox (Exchange admin center > Mailboxes > the mailbox > Delegation); with a certificate sign-in the app needs the Mail.Send application permission. Subject and signature can be changed, and a copy in the sender's Sent Items is off by default. The setting is saved in mail-settings.json in the tool folder.
- Security: the browser never sends the password back - the server keeps each new password in memory only for 60 minutes (dropped on sign-out or restart) and puts it in the email itself. Who emailed which user to which address, from which sender, is saved in logs/mail-audit-YYYY-MM.csv - without the password. Untick Ask me after the reset to skip the question; Email passwords in the results bar sends later.
- The Microsoft sign-in now also asks for Mail.Send and Mail.Send.Shared, so the first sign-in after the update may show a consent screen. If you were already signed in, sign out and in again before emailing.

## v1.64.0 - On-premises AD: pick the accounts from the search  (2026-10-01)

- On-premises AD: the search box now finds users by username, UPN, email, name or part of the description - one search or a list - and every account found is listed in the Accounts card with a tick box, Select all, All and None (clicking a row ticks it too). Apply and the quick actions (Unlock, Enable, Disable) change only the ticked accounts, and the bottom bar and the confirmation say which ones.
- A search term that finds exactly one account is ticked for you; a description or name that matches several accounts is listed with 'matches "..." (1 of N)' on each row and left for you to choose. More than 50 matches: the first 50 are listed and the screen says so.
- This replaces the old way: a description no longer picks a user by itself, shows a separate list with Use buttons, or replaces what you typed and searches again - and the separate 'Don't know the exact username?' finder is gone, because the main search box does it all. A name change needs exactly one ticked account. If you change what you typed after searching, the list is greyed out until you search again.

## v1.63.0 - Reset cloud passwords: pick the users from the search; several names switch to Several users  (2026-10-01)

- Reset cloud passwords: search no longer needs a Use button. When the search finds one account, it is selected automatically. When it finds several - a list of names, a username that matches more than one account, or all users of a domain - every account has a tick box, with Select all, All and None (clicking a row ticks it too). Reset only resets the ticked users, and the bottom bar says how many are selected (for example Reset 2 selected users).
- For a typed list, every name that found exactly one account is ticked for you; a name that matches several accounts is left for you to choose. If you change the names after searching, the results are greyed out and Reset uses what you typed again (search again to pick from the list).
- Typing or pasting several names into the single-user box (separated by commas, semicolons, spaces or new lines) switches to Several users by itself, with one name per line. This works the same on Reset cloud passwords, Account status, Revoke MFA and On-premises AD (there spaces do not split, because that box also takes descriptions). Pasting a list into the single box used to join the names together.

## v1.62.0 - Distribution groups use the Microsoft sign-in; any AD account can be used  (2026-10-01)

- Distribution groups no longer has its own login, worker window or Start / Sign out buttons. It uses the Microsoft sign-in in the sidebar: when you are signed in there and open the screen, Exchange Online connects by itself in the background with the same account (with a certificate sign-in, the same app and certificate). It signs out together with Microsoft, and if you sign in to Microsoft as someone else, Exchange Online switches to that account. Microsoft keeps Exchange Online separate from the Graph sign-in, so the first time a Microsoft window may open - choose the same account; on Windows it usually signs in without asking again.
- If Exchange Online cannot connect (for example MFA was cancelled, or the account has no Exchange admin role), the screen says why and shows Try again - it never keeps opening sign-in windows by itself. If the Microsoft window is used to sign in with a different account than the sidebar, that connection is refused, so changes are always made with the account you signed in with.
- Fix: after signing in with your Microsoft account you could not sign in to on-premises AD with another AD account (for example a separate admin account) - only the AD account linked to the Microsoft account was accepted. Any AD account you have the password for can now be used; AD itself still checks the password and the rights. The login log records both identities, and the sidebar shows when the AD account is a separate one. An AD sign-in is also no longer closed when you sign in to Microsoft.

## v1.61.0 - Distribution groups: built-in Exchange Online worker  (2026-10-01)

- The Distribution groups screen no longer needs the old Distribution Group Manager files (Start-Worker.ps1, DistributionGroupCore.ps1, Manage-DistributionGroupMembers_v14.ps1) - the Missing files message is gone. The Admin Console now has its own worker, DistGroups-Worker.ps1, which is in the zip: press Start worker & sign in, sign in once in the Microsoft window, and run.
- New choice With several groups: Every user into every group (a group that reaches the max stops taking people and is reported as Group full), or Fill the groups in order (the first group is filled up to the max, then the next one, and so on). Users who do not fit are saved in Overflow_<run>.csv - load it as Users to add with another group. Users who are already in one of the groups are skipped.
- Groups can be typed by name, alias or email; the log and the reports show each group's current name and email (and what you typed, when it differs). The same person typed twice (for example ali and ALI@contoso.com) is added once. Unknown users or groups are reported and the run carries on.
- Each run saves FullRunLog (the log), Results (one line per user and group: Added, Already a member, Group full, No room, Removed, Not a member, Failed...), FinalGroupMembership (who is in each changed group now, and who was added in this run), AllGroupsMembers for exports, and Overflow when users did not fit. All can be downloaded from the run.
- When Exchange Online is busy (throttling), the worker waits and tries again. If your admin role cannot use the switch that lets admins change groups they do not own, it tries again without it. Stop (Sign out) during a run stops after the current user. Nothing is ever deleted - only the members you asked for are removed.

## v1.60.0 - Reset cloud passwords and Check account status redesigned, and fixes  (2026-10-01)

- Reset cloud passwords has the same look as the other screens: a three-step bar, the username, optional domain and Search on one line (Enter searches), Temporary password or Temporary Access Pass as two cards, and the Reset button in a bar at the bottom that says exactly what will happen (for example: Reset 3 users: a random 12-character password, must change at next sign-in). Search results show the display name, status, sync and password expiry with days left, and a Use button that puts the user in the box. Results have clickable tiles (Done, Failed, Disabled accounts, Not in Entra).
- Check account status has the same look: one search line, Entra ID and On-premises AD as toggles, clickable tiles (Found, Not found, Enabled, Disabled, Locked out, Expired, Password expired), and one row per account with the display name, Entra status and password expiry, AD status, lock-out and account expiry (with days left), and the Enable / Disable and Revoke MFA buttons.
- Fix: the same user typed twice (for example john.smith and john.smith@contoso.com) was reset twice, so the first password shown no longer worked. Each account is now reset once, and the second line says which line above has the working password.
- Fix: Reset cloud passwords could reset the account you are signed in with, which can lock you out mid-session. It is now refused, like on Revoke MFA.
- Fix: Check account status ignored a domain typed on its own (Search did nothing). A domain alone now lists the users of that domain, like Reset cloud passwords. Duplicate names no longer give duplicate rows, results show the display name, and the CSV downloads open correctly in Excel with Arabic or accented names.

## v1.59.0 - New Distribution groups screen (Exchange Online)  (2026-10-01)

- New Distribution groups tab (address #dg): add or remove members of Exchange Online distribution groups, do both in one run, or export who is in them (one combined CSV or one per group). Lists can be typed or loaded from a CSV (column Group for groups, Email for users), with a maximum number of members per group, a default domain and an optional output folder. It replaces the separate Distribution Group Manager web page (WebUI-Server.ps1).
- It uses the same Exchange Online worker as before: copy Start-Worker.ps1, DistributionGroupCore.ps1 and Manage-DistributionGroupMembers_v14.ps1 into the new DistributionGroups folder. Press Start worker & sign in once; every run reuses that sign-in. The screen shows the worker status, a live log of each run (it stops refreshing when the run has finished) and buttons to download the report and log files. Each run is also saved in logs/dg-audit-YYYY-MM.csv.
- Fixed from the old web page: it had no login and could download ANY file on the PC (downloadfile?path=...) and read any folder - now it is behind the Admin Console login and only files of a run it queued can be opened. It no longer changes the PowerShell execution policy for every user on the PC. The admin UPN can no longer inject extra commands into the worker window. Arabic or accented names are no longer garbled.
- Also fixed: the default domain was added to group NAMES too (Sales Team became Sales Team@contoso.com) - now only plain aliases get it. A blank cell in an uploaded CSV crashed the run. The worker showed as not running on PCs with some regional date formats. A wrong Max members value crashed the run. Run could be clicked twice. The page polled the server all the time - now only while the tab is open.

## v1.58.0 - Revoke MFA screen redesigned, and fixes  (2026-10-01)

- The Revoke MFA screen has the same look as the other screens: a three-step bar, the search at the top (username, optional domain and Look up on one line), the user with their methods, the three actions as cards, and Apply in a bar at the bottom that stays visible while you scroll and says exactly what will happen.
- Each method has a small badge (TEL, APP, 123, KEY, TAP, @, WIN) and a note saying whether the options remove it. Each action card shows what it will affect, for example 3 methods will be removed or 2 users have a pass. Results have clickable tiles (Done, Partly done, Failed, Not done).
- Fix: Remove the MFA methods could leave the user's default method behind with an error, because Microsoft refuses to delete the default method (usually the Authenticator app or the mobile phone) while other methods remain. The tool now deletes the default-type methods last and retries anything that failed once the others are gone.
- Fix: pressing Enter while a lookup was still running started a second lookup, so users could be listed (and changed) twice. A new lookup now waits for the first one to finish.

## v1.57.0 - Sidebar tidied up  (2026-10-01)

- The sidebar is grouped into three cards: Microsoft 365 (sign-in, auto sign-out, Graph details), On-premises AD (sign-in, auto sign-out) and Session (portal login timeout, sign out of both, log out, shut down). Each auto sign-out timer now sits with the sign-in it belongs to.
- Fix: on screens 1280 to 1440 pixels wide, the Sign in to on-premises AD and Sign out of Microsoft and AD buttons were cut off, My account wrapped onto two lines and the version line wrapped. Buttons now wrap neatly and the labels are shorter (Sign in to AD, Sign out of both, Log out, Shut down). Each timer is one line, for example Auto sign-out [30 min].
- The sidebar is about 200 pixels shorter, so on most screens the sign-out buttons are reached with little or no scrolling. On narrow windows the cards sit side by side above the page instead of one long column. Nothing changes in how sign-in, sign-out or the timers work.

## v1.56.0 - On-premises AD screen redesigned, and fixes  (2026-10-01)

- The On-premises AD screen has the same look as the other screens: a three-step bar (find, choose the changes, apply), the search at the top, an Accounts card, the changes as panels side by side, and Search / Apply in a bar at the bottom that stays visible while you scroll.
- The bottom bar says what Apply will do (for example: Apply to 3 users: reset the password, change groups, set the expiry), and each panel that will change shows a blue label with the choice (Random password, one-time + cloud / add to 1 / End of 2026-11-01 ...).
- Accounts card: one row per account with name, username, email and UPN, description, status badges (Enabled / Disabled, Locked out, Password never expires), account expiry with days left or days since it expired, password last set, and membership of the groups you chose. Unlock, Enable and Disable are now quick actions on this card.
- After Apply or a quick action, the Accounts card is read again automatically, so it shows the accounts as they are now. Account expiry also has In 6 months.
- Fix: the Copy button for new passwords (and Copy secret on Cloud password, Copy emails on Bulk & report) did not work at http://supporttool:8765, because browsers only allow the clipboard on https or localhost. Copy now works on both addresses.
- Fix: account expiry is now shown as the last day the account works (end of that day, as in AD Users and Computers) on every screen - On-premises AD, Account status and the sidebar showed the next day before. Setting the expiry was always correct; only the display changes.
- Fix: the On-premises AD changes CSV now opens correctly in Excel with Arabic or accented names (UTF-8), and includes the Password never expires and Name results. The duplicate Security groups heading is gone.

## v1.55.0 - Export report and Bulk from CSV combined into Bulk & report  (2026-10-01)

- Export report and Bulk from CSV are now one screen, Bulk & report (address #bulk; old #report links open it too). Add users once - a CSV file, a typed list, or both - and press Look up users. Then choose Report only to filter and download, or an action (Enable, Unlock, Add to a group, Set expiry date, Disable) to change the same accounts, without looking them up twice.
- Report only is the default and changes nothing: no tick boxes, just the report with Download CSV and Copy emails. Choosing an action adds tick boxes and the Apply button. You can switch between them at any time after the lookup.
- The results table has everything from both screens: choose the columns (Columns button - now also Mobile, UPN, Locked and Password last set), filter with the tiles (Found, Not found, Several / conflict, Enabled, Disabled, Locked out, Expired, Expire in 30 days, Never expire, Need this action, Changed now, Failed), search, switch between all matches / by username or email / by description, and sort by clicking a column heading. The CSV has the rows shown and the columns chosen, plus the action results.
- A description that matches several accounts now lists every one of them (up to 50), like Export report did. To keep you safe, those accounts cannot be changed until you press Allow changes to them and confirm; you can lock them again at any time. A username, UPN or email still has to match exactly one account.
- A typed email that is not found as an email or UPN is also tried as a username (the part before @), as Export report did. Up to 500 lines at a time. Nothing else changes in the back end: the same AD sign-in, confirmations, never-your-own-account rule, protected-group warning and on-premises log apply.

## v1.54.0 - Export report redesigned  (2026-10-01)

- The Export report screen has the same look as the other screens: a three-step bar, the list of users and the report columns side by side, and a bar at the bottom with Download CSV and Copy emails that stays visible while you scroll.
- Users can be typed or pasted, or you can drag and drop a CSV or text file (a file made for Bulk from CSV works too). Counters show how many usernames, emails and descriptions you entered, and duplicates are ignored. Up to 1000 lines at a time.
- Choose the columns: Searched for, Matched by, Full name, Username, User principal name, Email, Mobile, Description, Account status, Locked, Account expiry, Password last set and Last modified. The table and the CSV use the same columns, and your choice is remembered on this PC. User principal name, Locked and Password last set are new.
- Clickable tiles filter the report: Enabled, Disabled, Locked out, Expired, Expire in 30 days, Never expire and Not found. There is also a search box, an All / by username or email / by description switch, and every column can be sorted by clicking its heading. Account expiry shows how many days are left or how long ago it expired.
- Copy emails puts the email addresses of the rows shown on the clipboard, ready to paste into an email. The CSV downloads only the rows shown.
- Fix: Account expiry in the report is now the last day the account works, the same as AD Users and Computers and Bulk from CSV. Before, it showed the next day (the raw value stored in AD). Nothing is ever changed on this screen.

## v1.53.0 - Bulk from CSV: add to a group, set the expiry date, last modified  (2026-10-01)

- Bulk from CSV has two new actions next to Enable, Unlock and Disable: Add to a group and Set expiry date.
- Add to a group: search on-premises AD for the group by name or email. Security, mail-enabled security and distribution groups are all found, each shown with its type and scope. After you choose a group, the review shows who is already a member, and only the people not yet in the group are ticked. Protected administrative groups (such as Domain Admins) are marked in red and ask for an extra confirmation.
- Set expiry date: choose In 1, 2 or 3 weeks, In 1, 2, 3 or 6 months, In 1 year, a date, or Never expires. The review shows each account's current expiry crossed out next to the new date, and only the accounts whose expiry would change are ticked. The date is the last day the account works (end of that day), the same as AD Users and Computers.
- The review now shows the account expiry, the last modified date and time (whenChanged in AD) and a Locked badge for every matched user, and they are in the results CSV. Unlock now ticks only the accounts that are locked out. A new Need this action tile filters the list to the accounts that will change.
- You can run several actions on the same file one after another (for example Enable, then Add to a group, then Set expiry date); the results of each are kept separately. Every change is saved in the on-premises log with the group or the old and new expiry. The server allows two new read-only lookups for this (group search and group membership check); nothing can be removed from a group or deleted.

## v1.52.0 - Bulk from CSV screen redesigned  (2026-10-01)

- The Bulk from CSV screen has the same new look as the Teams members screen: a three-step bar (upload, check, apply), the upload and the action side by side, and the Apply button in a bar that stays at the bottom of the screen while you scroll.
- Upload: drag and drop the CSV file (or click to browse). The file name and the number of users read are shown, with how each row will be looked up (username, UPN, email or description) and a preview of the rows before anything is checked. Remove the file with the x to start again.
- Enable, Unlock or Disable is now chosen with three buttons that explain each action. Disable is shown in red, and its Apply button turns red too.
- Review: the results show each matched user with their full name, username, UPN and email together, how the row was matched and the account status. Clickable tiles (Rows, Matched, Not found, Several / conflict, and after applying Changed now and Failed) filter the table, and a filter box searches it. Click a user's name to open them on the On-premises AD screen.
- After Check users, only the accounts that need the chosen action are ticked (for example only disabled accounts for Enable). Quick links tick only those that need it, all matched or none, and switching the action re-ticks the right accounts. No change to the back end: the same AD sign-in, 500-user limit, confirmation, never-your-own-account rule and on-premises log apply. The results CSV now also protects against spreadsheet formulas, like the other downloads.

## v1.51.0 - Teams members screen redesigned  (2026-10-01)

- The Teams members screen has a new layout: a three-step bar at the top shows what is done (teams chosen, addresses ready, run finished), and the team search and the people list now sit side by side on wide screens.
- Teams found and chosen teams show with a coloured badge, the group email and how they were found. Each chosen team has a Members button that shows its current owners and members on screen, with a filter box, Owners/Members tabs and a CSV download.
- People: drag and drop a CSV or text file (or click to browse); a file is added to the list instead of replacing it. Counters show valid, fixed, invalid and duplicate addresses, and anyone already in a chosen team (once its members are loaded) is marked.
- Member or Owner is now chosen with two clear buttons that explain the difference. The Add button and a summary of the number of changes stay visible at the bottom of the screen while you scroll, with a progress bar during a run.
- Results show clickable tiles (Total, Added, Already there, Failed, Invalid) that filter the table. No change to the back end: the same permissions, limits, confirmation, backup export, Stop button and audit log apply.

## v1.50.0 - Teams members screen; version check fixed  (2026-10-01)

- New Teams members screen (tab at the top, address #teams): find Microsoft Teams by name, object ID or group email (one team or several), then add many people as members or owners from a pasted list or a CSV file. Addresses are cleaned (spaces removed, duplicates dropped) and checked before anything is added. It uses the Microsoft sign-in from the sidebar, so there is no separate Teams login.
- Current members can be exported to CSV first as a backup (ticked by default), or at any time with Export members. A confirmation is asked before people are added, a Stop button ends a long run after the current batch, and the results (added, already there, failed, invalid) can be downloaded as CSV.
- Every attempt is saved in logs/teams-audit-YYYY-MM.csv, with a Download Teams log button. Only groups that really are Microsoft Teams can be changed, and people are never removed from a team on this screen.
- The Microsoft sign-in now also asks for the Group.ReadWrite.All permission. An administrator may have to approve it once for your organization. If you were already signed in, use Sign out and Connect again so Microsoft can ask for it. Certificate (app) sign-ins need the same permission added to the app.
- Fix: in version 1.49.0 the Screen files still carried version 1.48.2, which made the red 'Mixed file versions' warning appear on every page. All files are now on the same version.

## v1.49.0 - Separate auto sign-out for AD, portal login timeout, sign out of both  (2026-10-01)

- The on-premises AD sign-in now has its own Auto sign-out of AD timer in the sidebar (Never, 10, 15, 20, 30 minutes, 1 hour and more). It runs separately from the Microsoft timer, and a countdown shows in the sidebar. The existing 30-minute inactivity sign-out of AD still applies as well.
- The Auto sign-out of Microsoft timer now also offers 10 and 20 minutes.
- New Portal login timeout setting: choose how long the tool login page stays valid without use (10 minutes to 8 hours; default 30 minutes). It is separate from the Microsoft and AD timers. The 8-hour maximum still applies.
- New Sign out of Microsoft and AD button: signs out of both at once and keeps you on the page (no return to the login screen). The old Log out button is now called Log out of portal and still closes everything and returns to the login page.

## v1.48.2 - On-premises AD sidebar login: safer element name  (2026-10-01)

- The on-premises AD login box in the sidebar now uses a neutral element name, because some browser ad blockers hide page elements whose name starts with "ad". No other change.

## v1.48.1 - On-premises AD login moved up in the sidebar  (2026-10-01)

- The on-premises AD login box is now right under the Microsoft Connect button, so it is visible without scrolling the sidebar.

## v1.48.0 - On-premises AD sign-in in the sidebar  (2026-10-01)

- The on-premises AD username and password are now entered in the sidebar, under the Microsoft connection. Sign in once and the same sign-in is used on every screen (On-premises AD, Bulk from CSV, Export report, Account status). The signed-in account and its status show in the sidebar with a Sign out of AD button; the On-premises AD tab no longer has its own sign-in box.

## v1.47.1 - Fix: Bulk from CSV screen blank; every screen has its own address  (2026-10-01)

- Fixed the Bulk from CSV screen showing blank: it was placed outside the page area. It now opens with the template, upload and check steps.
- Every screen now has its own address (#cloud, #status, #mfa, #onprem, #bulk, #report), for example http://supporttool:8765/#bulk. The address is shown under the title with a Copy link button, the browser Back button moves between screens, and opening a link goes straight to that screen.

## v1.47.0 - Tool renamed to Admin Console  (2026-10-01)

- The tool is now called Admin Console (browser tab, sidebar, login page and start window) and its friendly address is http://supporttool:8765. Run Start.bat as Administrator once so Windows can add the address; otherwise the tool still opens at http://localhost:8765.

## v1.46.0 - Bulk from CSV  (2026-10-01)

- New Bulk from CSV screen: download a CSV template, fill in any one of username, user principal name, email or description for each user, upload it, check how every row matches an on-premises AD account, then enable (or unlock / disable) the matched accounts in one click. Rows that match no account or several accounts are never changed. A results CSV can be downloaded.

## v1.45.1 - Fix: Use button text split in two lines  (2026-10-01)

- Fixed the Use button in the search results showing as "Us / e" on two lines. Buttons and the first column now never wrap.

## v1.45.0 - Screen width adjusts  (2026-10-01)

- The page now uses the whole screen width instead of stopping at a fixed width, so every screen size works. The sidebar fields and the search results stretch to fit, long text in the search results wraps instead of forcing a sideways scroll, and the two-column forms drop to one column on narrower windows.

## v1.44.1 - Fix: On-premises AD search error  (2026-10-01)

- Fixed the error "Cannot read properties of null (reading classList)" when searching on the On-premises AD page. The box that lists users found by description was missing after the layout change in 1.43.0 and is back.

## v1.44.0 - Click a user on any screen to open it in On-premises AD  (2026-10-01)

- On Cloud password, Account status (including the domain list) and Revoke MFA, the username is now a link. Click it and the On-premises AD screen opens on Single user with that user searched, ready for Enable / Disable and the expiry date. If you are not signed in to AD yet, the search runs right after you sign in.

## v1.43.0 - On-premises AD: same look as the other screens, expiry in months  (2026-10-01)

- On-premises AD page: back to one white card with two columns like the other screens (left: search, Name, Account actions; right: Password reset, Security groups, Account expiry, Account status, UPN). The collapsing panels are gone.
- Account expiry list now has In 1 month, In 2 months and In 3 months (the same date, that many months from today).

## v1.42.0 - One back-end file per screen, clickable users in Export report  (2026-10-01)

- The back end is now split: server.ps1 keeps the sign-in, port, security and shared code, and each screen has its own file (Screen-CloudPassword.ps1, Screen-AccountStatus.ps1, Screen-RevokeMfa.ps1, Screen-OnPremAd.ps1, Screen-ExportReport.ps1). Nothing changes in how the screens work. Copy all files from the zip together; the tool warns if a screen file is from another version.
- Export report: click a username in the report and the On-premises AD screen opens on Single user with that user searched.

## v1.41.0 - On-premises AD: flexible layout  (2026-10-01)

- On-premises AD page: every option (Account actions, Password reset, Security groups, Account expiry, Account status, UPN) is now its own panel that opens and closes on its own click. Panels sit side by side and wrap to the next row only when the window is too narrow, so opening one no longer pushes everything down. Open all / Close all links added. The Name option now sits directly below the search.

## v1.40.0 - On-premises AD: change first, last, display and full name  (2026-10-01)

- On-premises AD, Single user page: new Name section to change the first name, last name, display name and full name (the Name in AD). Type the display name and the tool asks if the full name should be the same, and the other way round. Boxes left empty are not changed. One user at a time. The audit log has a new NameChange column.

## v1.39.0 - On-premises AD: the search box finds users by description  (2026-10-01)

- On-premises AD page: the main search box now also finds users by description. Type a username, a UPN, or any part of a description, name or email. If what you typed is not an exact username or UPN, the tool looks it up in descriptions, names, emails and usernames. In Single user mode one match is selected for you and checked at once, several matches are listed with a Use button. In Bulk mode the matches are listed with tick boxes, and adding them replaces the text you typed in the list, so you can see exactly which users will be changed before you press Apply. Nothing is changed by the lookup itself.

## v1.38.0 - On-premises AD: Single user and Bulk pages  (2026-10-01)

- On-premises AD page now has two pages inside it: Single user and Bulk (switch at the top, your last choice is remembered). Single user: one box for a username or UPN, press Enter or Search to check the account; the Find users results have a Use button that fills the box and checks the account. Bulk: the list of usernames (one per line or comma separated) with a live count, and Find users results with tick boxes. All the actions (unlock, enable, disable, password reset, groups, expiry, UPN) work the same in both. Switching to Single keeps your bulk list, and it comes back when you switch to Bulk.

## v1.37.0 - On-premises AD: find users by description, username, UPN, email or name  (2026-10-01)

- On-premises AD page: the Find users box now searches by Anything (default: description, username, user principal name, email and display name together), Description, Username (SAM account name), User principal name, or Display name. A part of the text is enough. The results list now shows the user principal name in its own column, and the users you tick are added to the usernames list as before.

## v1.36.0 - Revoke MFA: username only, account status, activity log  (2026-10-01)

- Revoke MFA page: (1) A username alone now works. Leave the Domain box empty and the tool finds the official sign-in name (UPN) in Entra by itself; if the name matches several accounts it lists them and asks for the full UPN. (2) The account status of the user (Enabled or Disabled), the display name and a synced flag are shown at the top of the result and in the bulk table. (3) A small Activity log under the lookup shows, line by line, what is looked up, removed, done or failed, with failures in red. Phone numbers are never shown in it.

## v1.35.1 - Sidebar and layout fix  (2026-10-01)

- The sidebar stayed fixed to one window height while the page was taller, so when you scrolled it moved up with the page and its dark background ended halfway (grey below it). The page can now grow with its content, so the sidebar stays pinned at the full window height on wide screens, and scrolls inside itself when it is taller than the window.
- On narrow screens the page was wider than the window because the top tab bar (now five tabs) did not fit. The tab bar now scrolls sideways inside itself and the page keeps the window width.

## v1.35.0 - Revoke MFA: one method at a time, Temporary Access Pass  (2026-10-01)

- **Single user:** every registered method (phone, Microsoft Authenticator, authenticator code, security key, Temporary Access Pass, recovery email, Windows Hello for Business) is listed with its own **Remove** button, so you can remove only the mobile number or any single method.
- New option **Also delete the Temporary Access Pass** (single and bulk, off by default). "Remove the MFA methods" still leaves the password, recovery email, Windows Hello and Temporary Access Pass alone.
- The Results table keeps everything done on the page until you press **Clear**, with one **Download results (CSV)** for all of it.
- The MFA log records `remove-method`, `mfa-revoke`, `tap-delete` and `sign-out` (joined with +) and the method names removed. Phone numbers and email addresses are never logged.

## v1.34.0 - Revoke MFA: bulk and logs  (2026-10-01)

- Revoke MFA now has **Single user** and **Bulk** modes. In bulk, paste up to 200 usernames or emails (one per line or comma separated; add a domain for names without @domain). Lookups and changes run one user at a time with progress, and one failing user does not stop the rest. If the Microsoft connection is lost, the remaining users are marked "Not done".
- A **Results** table shows the outcome for each user, with **Download this run (CSV)**.
- New log file `logs/mfa-audit-YYYY-MM.csv` with one row per user: time, Windows user, admin, target, action, methods removed, failures, signed out, result. Failed attempts are logged too. Phone numbers and passwords are never written.
- **Download MFA log** joins all monthly MFA log files into one CSV.

## v1.33.0 - Revoke MFA screen  (2026-10-01)

- New **Revoke MFA** tab in the page menu. Type a username or email (plus a domain if you typed only a username), press Look up, and the user's MFA methods are listed. Then choose what to do:
  - **Remove the MFA methods** (phone, Microsoft Authenticator, authenticator code, security keys).
  - **Also sign the user out everywhere**, so they have to log in again on every device and app. This is its own checkbox, off by default, and can be used on its own.
- The Revoke MFA button in the account status results now opens this screen with the user filled in.
- You cannot use it on the account you are signed in with.
- The audit log records `mfa-revoke`, `sign-out` or `mfa-revoke+sign-out`. If Graph refuses the sign-out (missing permission), the screen shows Graph's message.

## v1.32.0 - Revoke MFA  (2026-09-30)

- New **Revoke MFA** button in the account status results (also for synced accounts, because MFA lives in Entra). It lists the user's registered phone, Microsoft Authenticator, authenticator-code (OATH) and security-key (FIDO2) methods, asks for confirmation, removes them, and signs the user out everywhere. The password, recovery email, Temporary Access Passes and Windows Hello for Business are not touched.
- You cannot revoke the MFA of the account you are signed in with.
- Each use is written to `logs/reset-audit-*.csv` (method `mfa-revoke`, with the number removed; phone numbers are never logged).
- Signing the user out everywhere needs a Graph permission your sign-in may not have. If it is missing, the MFA methods are still removed and the tool tells you the sessions were not revoked.

## v1.31.1 - Sidebar fix  (2026-09-30)

- The sidebar stays the full height of the window and scrolls inside itself. Before, its dark background stopped at the bottom of the window when the Graph details were open, so Server, Version, Log out and Shut down appeared on the white page.

## v1.31.0 - Security fixes  (2026-09-30)

- On-premises AD sign-in now enforces the linked-account rule from v1.7: after a Microsoft sign-in only the matching on-premises account is accepted. An on-premises sign-in made earlier that does not match is closed when you sign in to Microsoft.
- A failed or cancelled Microsoft sign-in no longer leaves the previous identity behind (the signed-in name, linked account and auto sign-out timer are cleared before and after every attempt).
- Failed tool and on-premises sign-ins no longer write the typed username to `logs/login-audit-*.csv`, because people sometimes type their password into the username box. Successful sign-ins are still logged with the username. Delete or review older login-audit files.
- The tool login ends after 30 minutes without use, or 8 hours after signing in. Ending it also closes the Microsoft and on-premises sign-ins. Change `SessIdleMins` / `SessMaxHours` near the top of server.ps1 to adjust.
- CSV downloads and the audit logs put an apostrophe in front of any cell that starts with = + - or @, so a spreadsheet cannot run it as a formula.
- The password rule (at least 8 characters, not starting or ending with a special character) now uses \z, so a trailing line break is no longer accepted.

## v1.30.0 - Cloud password options same as on-premises  (2026-09-30)

- The Cloud password page now has the same password options as on-premises AD: generate a random password with a length of 8 to 32 (letters, numbers and ! @ # $ %, never starting or ending with a special character), or enter your own with the same rule, plus a One-time password tick box (user must change it at next sign-in).

## v1.29.0 - Search by domain  (2026-09-30)

- The Search button on the Cloud password page works with a domain: a username with a domain finds that exact account, and a domain alone lists the users in that domain (first 100).

## v1.28.0 - Search button on Cloud password  (2026-09-30)

- The Cloud password page has a Search button next to Reset now. It looks up the user(s) in Entra ID (exists, enabled or disabled, password expiry, type and sync) without changing anything, so you can check before you reset.

## v1.27.0 - Remember password removed  (2026-09-30)

- The Remember password option on the on-premises AD sign-in is removed. Only the front-page tool login lets the browser save the username and password; the on-premises sign-in is never offered for saving.

## v1.26.0 - Remember password  (2026-09-30)

- On-premises AD sign-in has a Remember password option. It uses your browser password manager (offered to save on sign-in and filled in next time); the tool itself never stores the password. Untick it to stop the browser offering to save.

## v1.25.0 - Mobile number in report  (2026-09-30)

- Export report now includes the mobile number (from the AD mobile field) in the table, the CSV and the text filter.

## v1.24.0 - Export report filters  (2026-09-30)

- Export report has filters: search box, account status (Enabled / Disabled / Not found), expiry (Never / Has expiry date / Expired) and Matched by. The table and the CSV download show only the filtered rows; Clear filters resets them.

## v1.23.0 - Report by description, email or username, with full name  (2026-09-30)

- New Export report input: type a description, an email or a username (one per line). A description can match several users and each gets its own row. The report and CSV now include the full name (display name) and a Matched by column.

## v1.22.0 - Export report  (2026-09-30)

- New Export report tab: paste a list of usernames or emails and download a CSV with email, SamAccountName, description, account status, expiry date and last modified date from on-premises AD. Read-only.

## v1.21.0 - Original design back, fixed port  (2026-09-30)

- Back to the original look (the v1.20.0 redesign is removed).
- The tool now always uses port 8765 instead of a random port, so the address is always http://onetimepasswordreset:8765/ (or http://localhost:8765/). This also lets the browser keep the saved password. If the port is busy it says so instead of picking another.

## v1.20.0 - New design  (2026-09-30)

- Fresh look: teal colour scheme, page names as underlined tabs, plainer table headings, coloured tops on the status tiles, clearer focus outlines and a redesigned sign-in page. No change to how anything works.

## v1.19.0 - Clearer name for the first page  (2026-09-30)

- The first page is now called Cloud password (heading: Reset cloud passwords) so it is clear it is for Microsoft 365 / Entra ID accounts, next to On-premises AD.

## v1.18.0 - Password never expires  (2026-09-30)

- The on-premises search shows whether "Password never expires" is set on each account.
- New option to remove "Password never expires" when you apply changes; it runs before a password reset so a one-time password can be forced. The audit log has a new PasswordNeverExpires column.

## v1.17.0 - Save the login  (2026-09-30)

- The sign-in page now lets your browser save the username and password (no more autocomplete off), plus a Remember my username tick box. Nothing is stored by the tool itself.

## v1.16.0 - Confirmations in the middle of the screen  (2026-09-30)

- Every confirmation and message now opens as a dialog in the centre of the page instead of the browser box at the top. Enter confirms, Esc cancels.

## v1.15.0 - Version tracking and Disable restored  (2026-09-30)

- Every file carries its version, the page shows the version with this history, and the zip name includes the version.
- The tool warns you if index.html or login.html come from a different version than server.ps1 (mixed files).
- Disable account restored: on-premises and Entra ID, with a confirmation. Never your own account. Deleting stays blocked.

## v1.14.0 - Search by display name, email and clearer columns  (2026-09-30)

- Find users by Display name as well as Description; results show username, full name, email and description.
- The on-premises search table shows Username, Full name, Email and Description.

## v1.13.0 - Find users by description  (2026-09-30)

- Type part of a description, tick the users you want and add them to the usernames list.

## v1.12.0 - Cloud password reset at the same time  (2026-09-30)

- On-premises password reset can also reset the Entra ID (cloud) password with the same password, with a Cloud password result column.

## v1.11.0 - Changes found in your uploaded copy (made outside this chat)  (2026-09-30)

- Group search pick-list with partial names, Unlock / Enable / Disable account buttons, optional domain when searching, and a safety allow-list of tool actions.

## v1.10.0 - Add and remove several groups  (2026-09-30)

- Choose add or remove and enter several security groups at once; each group gets its own result.

## v1.9.0 - UPN domain option  (2026-09-30)

- Optionally change the domain part of the on-premises UPN (same as typed, a forest suffix, or another domain). Search shows the real UPN.

## v1.8.0 - Login stored inside the script  (2026-09-30)

- The tool login is kept as salted hashes inside server.ps1; nothing is saved on the PC. Change-Login.bat changes it.

## v1.7.0 - Microsoft account linked to on-premises account, Log out  (2026-09-30)

- After Microsoft sign-in the matching on-premises account is required. New Log out button returns to the login page.

## v1.6.0 - On-premises sign-in with your own credentials  (2026-09-30)

- The On-premises AD tab stays locked until you sign in with your AD account; every change is made with it.

## v1.5.0 - Search first, then apply  (2026-09-30)

- On-premises changes unlock only after you search the usernames.

## v1.4.0 - On-premises password reset  (2026-09-30)

- One-time or normal password; random (8-32) or typed; no special character at the start or end.

## v1.3.0 - Tool login page  (2026-09-30)

- The tool asks for a username and password before anything loads.

## v1.2.0 - Enable disabled account (on-premises)  (2026-09-30)

- Checkbox to enable the account if it is disabled.

## v1.1.0 - On-premises groups and expiry  (2026-09-30)

- Add users to a security group and set account expiry: 1, 2 or 3 weeks, a custom date, or never.

## v1.0.0 - Original tool

- Entra ID password reset / Temporary Access Pass, account status check, on-premises status.


# Admin Console 2.x - multi-user design and working rules (current v2.7.1)

**Stack (2.11.7):** Windows PowerShell 5.1 back end, plain JavaScript front end (no framework), Microsoft Graph PowerShell SDK, System.DirectoryServices. See TECHNICAL-DOCUMENTS.md section 2b.

## Working rules (user preference)
- **Versions are per screen (since 2.8.0).** Raise the `Screen version:` header ONLY in the files that really changed; every other screen keeps its number. Never replace the version number in all files. Updates screen / What's new then say: this screen updated, new screen, all others same.
- EVERY delivery with fixes or features gets a NEW version number (2.7.1 -> 2.7.1 -> 2.7.1 ...). Never re-ship changes under an existing number.
- Release: raise `$AppVersion` in server.ps1, raise the header of each changed screen file, add a new top entry to `VERSIONS` in `frontend/index.html` (with the `s` list of updated / new screens; keep older entries) and to `docs/CHANGELOG.md`. Zip as AdminConsole-X.Y.Z.zip. See TECHNICAL-DOCUMENTS.md section 12.
- All code must have comments (header per file, comment before each function / endpoint). New code gets comments too.
- Users install through Settings > Updates (upload zip, type UPDATE); the "What's new" pop-up shows the VERSIONS notes once per person.
- Pop-ups close with the X top right (no Cancel buttons).
- Settings are never saved automatically - only when the person clicks Save.

## How sessions work
- `server.ps1` keeps `$script:Sessions` (sid -> state). Each request loads the browser's session (cookie `sid`) into the `$script:` variables (`Use-Sess`) and saves it back (`Save-Sess`). Per-person variables: `$script:PerSess`.
- Microsoft Graph has one process-wide connection: `Use-SessGraph` reconnects with the person's token (`MsAccess`).
- IMPORTANT pitfall: handlers run in SCRIPT scope - a local variable named like a per-session variable overwrites it.

## Sign-in to Microsoft (3 ways)
- Microsoft page (browser, PKCE), Microsoft window (Connect-MgGraph on the server only), Sign in with a code (device code).
- Settings > Connections > Create the app automatically (`backend/Portal/Screen-AppSetup.ps1`): creates or updates the app with only the ticked permissions; `window.acCreateApp(['mailbox'])` opens it preselected (used by Mailbox cleanup).
- SharePoint admin token: remembered per portal user + Microsoft account in `spo-signins.json` (DPAPI).

## Security (Settings > Access and security, `backend/Portal/Screen-Security.ps1`)
- IP allow-list (localhost always allowed), HTTPS only, per-IP login block, 2-step sign-in (TOTP), session tied to IP, folder lock, security headers, request size limits, SAML replay cache.
- `tool-users.json`, `people-db.json`, `two-step.json`, `spo-signins.json` encrypted with DPAPI LocalMachine (`Read-SecureText` / `Write-SecureText`).

## Known limits
- Requests are handled one at a time. AD, DPAPI, EXO token, IIS and real Graph need Windows testing; development tests use pwsh on Linux with stubs and Playwright with mocked APIs.

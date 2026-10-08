# Admin Console - documents

All documentation lives in this folder.

| File | What it is |
|---|---|
| [TECHNICAL-DOCUMENTS.md](TECHNICAL-DOCUMENTS.md) | How the tool is built: folders, request flow, sessions, sign-in, screens, settings files, security |
| [admin-console-v2-multiuser.md](admin-console-v2-multiuser.md) | Working rules (versioning) and the session / security design notes |
| [admin-console-iis-publish-guide.md](admin-console-iis-publish-guide.md) | Step-by-step: publish the tool on IIS behind https |
| [CHANGELOG.md](CHANGELOG.md) | What changed in every version |

**Stack in one line (package 2.10.2):** Windows PowerShell 5.1 back end (HttpListener, port 8080) + one plain-JavaScript page (no framework; only qrcodejs 1.0.0 on the sign-in page) + Microsoft Graph PowerShell SDK (one common version) + System.DirectoryServices for AD. Details: TECHNICAL-DOCUMENTS.md section 2b.

Folder map of the whole package:

```
PasswordReset/
  frontend/   what the browser shows (index.html, login.html)
  backend/    the PowerShell code behind each screen
    Portal/ Microsoft365/ ActiveDirectory/ ExchangeOnline/
  docs/       all .md documents (this folder)
  Tools/      helper scripts used by the .bat files
  server.ps1  the server itself (entry point) + the .bat launchers
```

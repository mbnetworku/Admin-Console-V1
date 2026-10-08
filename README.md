# Admin Console

A web console for IT support teams to manage **on-premises Active Directory**, **Microsoft 365 (Entra ID)** and **Exchange Online** from one place, with roles and permissions, single sign-on and an activity log.

It runs as a small local web server written in **Windows PowerShell 5.1** and serves one plain-JavaScript page. There is no build step and no database: copy the files, start the `.bat`, open `http://localhost:8080`.

> **Current version: 2.11.12** (2026-10-08)

## What it does

**Microsoft 365 accounts**
- Cloud password reset (with e-mail templates), account status check, revoke MFA / sign out everywhere
- **Guest users**: invite one or many guests (your own message, from a sender mailbox you choose)
- **Guest users report**: every guest with created date, last sign-in, invitation accepted or not, and all groups in one cell with the kind (M365 group, Teams group, Security group...). Screen and CSV
- Licenses (bought, used, left; assign or remove in bulk), Intune devices, OneDrive

**Exchange Online and Teams**
- Teams members, distribution groups, shared mailboxes, address list, mailbox cleanup

**On-premises Active Directory**
- Password reset and account status, create AD users (one, or many from a CSV) with a "new user" e-mail (username and password, HTML and logo)
- **Users report**: browse and tick one or many OUs and get every user (e-mail, UPN, names, expiry, status, description, last changed, password never expires) on screen and as CSV, no row limit
- Bulk changes from CSV

**Administration**
- Roles and per-screen permissions; sign-in with local accounts, on-premises AD, or SAML / OIDC single sign-on (linked users only)
- Settings > Connections: Microsoft 365 and AD sign-in, choose the domain controller (only on a domain-joined PC), Microsoft app registration
- **Progress** (button in the top bar): a small pop-up in the middle of the screen with *Minimize* and *Close*. Each running task has a **Cancel** button
- Activity log, audit and event logs, e-mail template editor with logo, HTTPS setup, update and revert tools

## Requirements

- Windows with **PowerShell 5.1**; the launchers ask for local administrator rights
- Microsoft Graph PowerShell SDK (Microsoft 365 screens)
- A domain-joined PC for the Active Directory screens
- Optional: IIS in front of the tool for HTTPS (see `docs/admin-console-iis-publish-guide.md`)

## Quick start

1. Extract the package.
2. Run `Start.bat` (or `Start-Visible.bat` to see the console window). It elevates itself to local administrator.
3. Open `http://localhost:8080` and sign in.
4. In **Settings > Connections**, sign in to Microsoft 365 and Active Directory.

Other launchers: `Install-Service.bat` (run as a Windows service), `Allow-Tool.bat`, `Change-Login.bat` (change the owner login), `Reset-Password.bat`, `Revert-Update.bat`.

## Cannot sign in? Reset the password

- **Owner login (the first login of the tool):** on the server PC double-click **`Reset-Password.bat`**. Windows asks once for administrator rights (the file runs as administrator by itself). Type a new username and a new password (at least 8 characters, typed twice). You do **not** need the old password: being administrator of the server PC is the proof. Then open the tool and sign in with the new login.
- **Any other person:** an administrator resets the password in **Settings > Users** (set a new password or generate one and e-mail it).
- To simply change a password you still know, use `Change-Login.bat` (it asks for the old one first).
- Every reset is written to the sign-in log. (The sign-in page itself shows no such message; this information is only here, in the technical documents and in the AI memory file.)


## How it is built

| Part | Technology |
|---|---|
| Back end | Windows PowerShell 5.1, `System.Net.HttpListener` on port 8080 (one request at a time), one `Screen-<Name>.ps1` file per screen |
| Front end | One HTML file with plain JavaScript (ES2017+, **no framework**; only qrcodejs 1.0.0 on the sign-in page) |
| Microsoft 365 | Microsoft Graph PowerShell SDK (one common version) |
| Active Directory | `System.DirectoryServices` (LDAP / ADSI) |

Each screen has its own version number and the package has its own. Every change is recorded in `docs/CHANGELOG.md`.

## Folder map

```
PasswordReset/
  README.md   this file
  VERSION.txt package version
  server.ps1  the server itself (entry point)
  *.bat       launchers
  frontend/   what the browser shows (index.html, login.html)
  backend/    the PowerShell code behind each screen
    Portal/ Microsoft365/ ActiveDirectory/ ExchangeOnline/
  docs/       all other documents
  Tools/      helper scripts used by the .bat files
```

## Documents (in `docs/`)

| File | What it is |
|---|---|
| [TECHNICAL-DOCUMENTS.md](docs/TECHNICAL-DOCUMENTS.md) | How the tool is built: folders, request flow, sessions, sign-in, screens, settings files, security |
| [admin-console-v2-multiuser.md](docs/admin-console-v2-multiuser.md) | Working rules (versioning) and the session / security design notes |
| [admin-console-iis-publish-guide.md](docs/admin-console-iis-publish-guide.md) | Step-by-step: publish the tool on IIS behind https |
| [CHANGELOG.md](docs/CHANGELOG.md) | What changed in every version |

## Status

Developed and maintained by MB (Bahrain). Used by support staff for day-to-day account management. New features are added screen by screen and tested on the author's own environment.

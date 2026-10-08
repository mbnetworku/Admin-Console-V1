# AdminConsole

A web console for IT support teams to manage **on-premises Active Directory**, **Microsoft 365 (Entra ID)** and **Exchange Online** from one place, with permissions, sign-in options and an activity log.

It runs as a small local web server written in **Windows PowerShell 5.1** and serves one plain-JavaScript page. There is no build step and no database: copy the files, start the `.bat`, open `http://localhost:8080`.

> Current version: **2.11.0**

## What it does

**Microsoft 365 accounts**
- Cloud password reset (with e-mail templates), account status, revoke MFA / sign out everywhere
- Guest users: invite one or many guests, and a **Guest users report** (created, last sign-in, invitation accepted or not, and all groups with the group kind)
- License overview and bulk assign / remove, Intune devices, OneDrive

**Exchange Online and Teams**
- Teams members, distribution groups, shared mailboxes, address list, mailbox cleanup

**On-premises Active Directory**
- Password reset and account status, create AD users (one or from CSV) with a "new user" e-mail, bulk CSV changes
- **Users report**: browse and tick one or many OUs and export every user (e-mail, UPN, names, expiry, status, description, last changed, password never expires) to screen and CSV

**Administration**
- Role-based permissions for support staff, sign-in with local accounts or SAML / OIDC SSO (linked users only)
- Activity log, audit and event logs, e-mail template editor with logo, HTTPS setup, update and revert tools

## Requirements

- Windows with **PowerShell 5.1** and local administrator rights (the launcher asks for elevation)
- Microsoft Graph PowerShell SDK (for the Microsoft 365 screens)
- A domain-joined PC for the Active Directory screens
- Optional: IIS in front of the tool for HTTPS (see `docs/admin-console-iis-publish-guide.md`)

## Quick start

1. Extract the package.
2. Run `Start.bat` (or `Start-Visible.bat` to see the console window). It elevates itself to local administrator.
3. Open `http://localhost:8080` and sign in.
4. In **Settings > Connections**, sign in to Microsoft 365 and Active Directory (and optionally choose a domain controller).

To run it as a Windows service, use `Install-Service.bat`.

## How it is built

| Part | Technology |
|---|---|
| Back end | Windows PowerShell 5.1, `System.Net.HttpListener` on port 8080, one `Screen-<Name>.ps1` file per screen |
| Front end | One HTML file with plain JavaScript (ES2017+, **no framework**) |
| Microsoft 365 | Microsoft Graph PowerShell SDK |
| Active Directory | `System.DirectoryServices` (LDAP / ADSI) |

Each screen has its own version number; the package has its own too. Every change is recorded in `docs/CHANGELOG.md`.

## Folder map

```
PasswordReset/
  frontend/   what the browser shows (index.html, login.html)
  backend/    the PowerShell code behind each screen (Portal, Microsoft365, ActiveDirectory, ExchangeOnline)
  docs/       technical documents, change log, IIS guide
  Tools/      helper scripts used by the .bat files
  server.ps1  the server (entry point)
```

## Documentation

- `docs/TECHNICAL-DOCUMENTS.md` - how the tool works
- `docs/admin-console-iis-publish-guide.md` - publish behind IIS with HTTPS
- `docs/CHANGELOG.md` - what changed in every version

## Status

Actively developed by MB (Bahrain). Used by support staff for day-to-day account management. New features are added screen by screen and tested on the author's own environment.

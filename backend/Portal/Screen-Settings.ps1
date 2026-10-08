# Screen-Settings.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Settings (defaults, appearance, session)
# Screen version: 2.11.1   (changes ONLY when this screen changes - not with every release)

# The other sections of the Settings screen use their own back ends: Email sender (Screen-CloudPassword.ps1 /api/mail-settings),
# Email messages (Screen-EmailTemplates.ps1), Logs (ActivityLog.ps1), sign-in and session (server.ps1).
# Saved in app-defaults.json next to the tool.

# Screen: Settings > defaults. Endpoint: /api/app-defaults (read and save). Data file: app-defaults.json next to the tool.
# Settings kept: guestMode (who sends guest invitations), guestRedirect (page guests land on), mbxTell, minimizeOnStart.
# No Microsoft Graph / AD calls here. Permission: whatever server.ps1 requires for /api/* (signed-in tool users).
$script:AppDefFile = Join-Path $Root 'app-defaults.json'
# Reads app-defaults.json and returns the settings. Starts from safe defaults and only accepts valid values from the file,
# so a missing, old or hand-edited file can never break the screen. Returns an ordered hashtable.
function Get-AppDefaults {
    $c = [ordered]@{ guestMode = 'sender'; guestRedirect = ''; mbxTell = $false; minimizeOnStart = $false }
    if (Test-Path $script:AppDefFile) {
        try {
            $j = Get-Content $script:AppDefFile -Raw -Encoding UTF8 | ConvertFrom-Json
            # Only these four invitation modes are known; anything else keeps the default 'sender'.
            if ("$($j.guestMode)" -in 'sender', 'microsoft', 'both', 'none') { $c.guestMode = "$($j.guestMode)" }
            # Redirect page must be an https address with no spaces, quotes or angle brackets (keeps bad text out of invitations).
            if ("$($j.guestRedirect)" -match '^https://[^\s"<>]+$') { $c.guestRedirect = "$($j.guestRedirect)" }
            $c.mbxTell = [bool]$j.mbxTell
            $c.minimizeOnStart = [bool]$j.minimizeOnStart
        # Unreadable / broken JSON file: ignore it and use the defaults.
        } catch {}
    }
    $c
}

# Handler for /api/app-defaults. Input $d: empty = just read; save:true plus guestMode, guestRedirect, mbxTell, minimizeOnStart = save.
# Sends { ok, defaults } with the current (or newly saved) settings. Throws a readable message if a value is invalid.
$ScreenHandlers['/api/app-defaults'] = {
    # read: {}  /  save: { save:true, guestMode, guestRedirect, mbxTell }
    $c = Get-AppDefaults
    if ($d.save) {
        $gm = "$($d.guestMode)"; if ($gm -notin 'sender', 'microsoft', 'both', 'none') { throw 'Choose how guest invitations are sent.' }
        # Trim spaces so a pasted address with blanks still passes; an empty value is allowed (means: use the default page).
        $gr = "$($d.guestRedirect)".Trim()
        if ($gr -and $gr -notmatch '^https://[^\s"<>]+$') { throw 'The page the guest lands on must be an https address (or leave it empty for the default).' }
        $c.guestMode = $gm; $c.guestRedirect = $gr; $c.mbxTell = [bool]$d.mbxTell; $c.minimizeOnStart = [bool]$d.minimizeOnStart
        # Write the settings file as UTF-8 JSON (replaces the old file).
        ($c | ConvertTo-Json) | Out-File $script:AppDefFile -Encoding utf8
    }
    Send $ctx @{ ok = $true; defaults = $c }
}

# ---------------------------------------------------------------------------------------------------------------------------
# v2.8.1: Settings > Sign-in and session > "Domain controller (AD server)": which AD/DC the tool talks to.
# Saved in ad-server.json next to the tool: { mode: 'auto' | 'manual', server: 'dc01.corp.contoso.com' }.
#   auto   = Windows picks a domain controller by itself (the old behaviour; LDAP://... without a server name)
#   manual = every LDAP call (AD screens, Create AD users, AD sign-in, audit) goes to the chosen DC: LDAP://<server>/<DN>
# The helpers below are used by server.ps1 and many screens (Get-RootDse, Get-LdapPrefix, Get-AdDefaultRoot).
# ---------------------------------------------------------------------------------------------------------------------------
$script:AdServerFile = Join-Path $Root 'ad-server.json'
# A DC name or IP: letters, digits, dot, underscore, dash only (nothing that could change the LDAP path).
function Test-AdServerName($x) {
    if ("$x" -notmatch '^[A-Za-z0-9._-]{1,255}$') { return $false }
    # v2.8.2: something that looks like an IPv4 address (digits and dots only) must be a REAL one: four numbers, each 0-255.
    if ("$x" -match '^[0-9.]+$') { if ("$x" -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }; foreach ($o in ($Matches[1], $Matches[2], $Matches[3], $Matches[4])) { if ([int]$o -gt 255) { return $false } } }
    $true
}
# Reads ad-server.json. Returns @{ mode; server }. A missing / broken file or a bad name means 'auto'.
function Get-AdServerCfg {
    $c = [ordered]@{ mode = 'auto'; server = '' }
    if (Test-Path $script:AdServerFile) {
        try { $j = Get-Content $script:AdServerFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ("$($j.mode)" -eq 'manual' -and (Test-AdServerName $j.server)) { $c.mode = 'manual'; $c.server = "$($j.server)" } } catch {}
    }
    $c
}
# The start of every LDAP path: 'LDAP://' (automatic) or 'LDAP://dc01.corp.com/' (chosen DC). Add a distinguished name after it.
function Get-LdapPrefix { $c = Get-AdServerCfg; if ($c.mode -eq 'manual' -and $c.server) { "LDAP://$($c.server)/" } else { 'LDAP://' } }
# The RootDSE of the chosen DC (or of the DC Windows picks): naming contexts, dnsHostName, ...
function Get-RootDse { [ADSI]((Get-LdapPrefix) + 'RootDSE') }
# The domain root as a DirectoryEntry using the Windows account of this tool (no typed AD sign-in). Automatic mode = the old parameterless entry.
function Get-AdDefaultRoot {
    Add-Type -AssemblyName System.DirectoryServices
    $c = Get-AdServerCfg
    if ($c.mode -eq 'manual' -and $c.server) { New-Object DirectoryServices.DirectoryEntry("$(Get-LdapPrefix)$((Get-RootDse).Properties['defaultNamingContext'].Value)") } else { New-Object DirectoryServices.DirectoryEntry }
}
# Handler /api/ad-server. Input $d:
#   {}                       read: { ok, cfg, current }   (current = the DC Windows is talking to now)
#   { discover:true }        list the domain controllers of this PC's domain
#   { test:true, server }    try to reach one DC: { ok, host, domain }
#   { save:true, mode, server }  save the choice (a manual DC is tested first)
# Changing it needs the Settings permission (Get-ApiNeed). Nothing else is changed; the AD sign-in stays as it is.
$ScreenHandlers['/api/ad-server'] = {
    # Tries one DC with a RootDSE read. Throws a readable message if it does not answer.
    $probe = {
        param($srv)
        if (-not (Test-AdServerName $srv)) { throw 'That is not a valid domain controller. Type a host name (dc01.contoso.com) or a correct IPv4 address (for example 10.0.0.5: four numbers from 0 to 255).' }
        try { $r = [ADSI]"LDAP://$srv/RootDSE"; $h = "$($r.Properties['dnsHostName'].Value)"; $n = "$($r.Properties['defaultNamingContext'].Value)"; if (-not $n) { throw 'no answer' } }
        catch { throw "Could not reach the domain controller '$srv' over LDAP. Check the name, the network and that this PC / account may read it." }
        @{ host = $h; domain = (("$n" -split ',' | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.') }
    }
    if ($d.discover) {
        # v2.11.1: finding the DCs can take many seconds and the server answers one request at a time, so the list is kept for 10 minutes.
        if ($script:DcCache -and ((Get-Date) - $script:DcCacheAt).TotalMinutes -lt 10 -and -not $d.refresh) { Send $ctx @{ ok = $true; dcs = $script:DcCache }; return }
        $list = @(); try { Add-Type -AssemblyName System.DirectoryServices; $dom = [DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain(); $list = @($dom.DomainControllers | ForEach-Object { @{ name = "$($_.Name)"; site = "$($_.SiteName)"; ip = "$($_.IPAddress)" } }) } catch { throw 'Could not list the domain controllers. This PC may not be joined to a domain; type the DC name instead.' }
        $script:DcCache = $list; $script:DcCacheAt = Get-Date
        Send $ctx @{ ok = $true; dcs = $list }; return
    }
    if ($d.test) { $r = & $probe "$($d.server)".Trim(); Send $ctx @{ ok = $true; host = $r.host; domain = $r.domain }; return }
    if ($d.save) {
        $m = "$($d.mode)"; if ($m -notin 'auto', 'manual') { throw 'Choose Automatic or a specific domain controller.' }
        $srv = "$($d.server)".Trim()
        if ($m -eq 'manual') { if (-not $srv) { throw 'Choose or type the domain controller.' }; [void](& $probe $srv) } else { $srv = '' }
        ([ordered]@{ mode = $m; server = $srv } | ConvertTo-Json) | Out-File $script:AdServerFile -Encoding utf8
    }
    $cur = ''; try { $cur = "$((([ADSI]((Get-LdapPrefix) + 'RootDSE')).Properties['dnsHostName'].Value))" } catch {}
    Send $ctx @{ ok = $true; cfg = (Get-AdServerCfg); current = $cur }
}

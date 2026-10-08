# Screen-ExportReport.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Export report
# Screen version: 2.0.0   (changes ONLY when this screen changes - not with every release)

# WHAT IT DOES: builds the on-premises Active Directory report. The user pastes a list of names / usernames / descriptions and gets one
# table row per matching AD account (status, locked, password dates, mail, mobile ...).
# ENDPOINT: POST /api/onprem-report  (request field: usernames = array of text lines). Replies { ok, results = rows }.
# DATA: reads AD only (through Find-AdReportUsers and Get-BkInfo); nothing is written. Needs this PC joined to a domain and an AD sign-in
# (permission = whoever is signed in to the tool and has an on-premises AD credential). No Graph or Exchange calls.
# Uses Find-AdReportUsers (Screen-OnPremAd.ps1) and Get-BkInfo (Screen-BulkCsv.ps1).

# Makes one empty report row. $name = the text the user typed, $found = 'Yes'/'No', $via = how it was matched, $note = message for the row.
# All other columns start as '-' so the table never shows blanks. Status says 'Not found' when nothing matched.
function New-ReportRow($name, $found, $via, $note) {
    [ordered]@{ user = $name; found = $found; name = '-'; mail = '-'; mobile = '-'; sam = '-'; upn = '-'; desc = '-'; status = $(if ($found -eq 'Yes') { '-' } else { 'Not found' }); locked = '-'; expires = '-'; expired = $false; pwdSet = '-'; modified = '-'; matched = $via; note = $note }
}

# Handler: for every typed line, search AD and add one row per account found. $d = request body, $ctx = reply context (used by Send).
$ScreenHandlers['/api/onprem-report'] = {
        # Stop early with a clear message when the PC is not on a domain or nobody has signed in to AD yet.
        if (-not $script:AdAvail) { throw 'This PC is not joined to an Active Directory domain, so the on-premises lookup is unavailable.' }
        if (-not $script:AdCred) { throw 'Sign in to on-premises AD first (Settings > Connections, or the M365 / AD button at the top right).' }
        # Clean the list: trim each line, drop empty lines and duplicates. The 1000 limit keeps one request from running too long.
        $names = @($d.usernames | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($names.Count -gt 1000) { throw 'Up to 1000 lines at a time. Split the list and run the report again.' }
        # $cap = most accounts shown for one line (a short description like 'John' can match hundreds of users).
        $rows = @(); $cap = 50
        foreach ($name in $names) {
            # Look the line up in AD. $via tells which attribute matched (set by Find-AdReportUsers). A search error becomes the row note, not a crash.
            $found = @(); $via = ''; $err = ''
            try {
                $found = @(Find-AdReportUsers $name $cap); $via = $script:ReportVia
            } catch { $err = Get-ErrMsg $_ }
            # Nothing found (or error): add a 'No' row and go on with the next line.
            if (-not $found.Count) { $rows += [pscustomobject](New-ReportRow $name 'No' '-' $err); continue }
            # Too many matches: keep the first $cap and remember to add a warning row after them.
            $more = $found.Count -gt $cap
            if ($more) { $found = @($found | Select-Object -First $cap) }
            foreach ($ures in $found) {
                # One row per account. Get-BkInfo reads the account state (enabled, locked, password expiry/last set, last modified) by sAMAccountName.
                $r = New-ReportRow $name 'Yes' $via ''
                try {
                    $sam = "$($ures.Properties['samaccountname'][0])"
                    $i = Get-BkInfo $sam
                    $r.sam = $sam; $r.status = $i.enabled; $r.locked = $i.locked; $r.expires = $i.expires; $r.expired = $i.expired; $r.pwdSet = $i.pwdSet; $r.modified = $i.modified
                    if ($i.upn) { $r.upn = $i.upn }
                    # Open the full AD object to read display name, mail, mobile and description (multi-valued, so joined with spaces). Empty values keep '-'.
                    $ue = $ures.GetDirectoryEntry()
                    $dn = "$($ue.Properties['displayName'].Value)"; if ($dn) { $r.name = $dn }
                    $ml = "$($ue.Properties['mail'].Value)"; if ($ml) { $r.mail = $ml }
                    $mb = "$($ue.Properties['mobile'].Value)"; if ($mb) { $r.mobile = $mb }
                    $dsc = @($ue.Properties['description'] | ForEach-Object { "$_" }) -join ' '; if ($dsc) { $r.desc = $dsc }
                # If reading this one account fails, keep the row and show the error in its note.
                } catch { $r.note = Get-ErrMsg $_ }
                $rows += [pscustomobject]$r
            }
            # Warning row telling the user the list was cut at $cap.
            if ($more) { $rows += [pscustomobject](New-ReportRow $name 'Yes' $via "More than $cap users match this description - only the first $cap are shown. Type more of the description to narrow it.") }
        }
        # Send all rows to the web page.
        Send $ctx @{ ok = $true; results = $rows }
}

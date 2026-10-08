# Screen-Accounts.ps1 - back end for one screen of the tool. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Accounts (AD helper)
# Screen version: 2.0.0   (changes ONLY when this screen changes - not with every release)

# ENDPOINT: POST /api/known-accounts (no request fields). Replies { ok, accounts = up to 20 of { upn, name, src } }.
# DATA: accounts.json in the tool folder (read and written), 'whoami /upn', and the browsers' own profile files on disk. No Graph/AD/Exchange
# calls. Usable by anyone who can open the tool. Save-RecentAccount is called by other screens after a successful sign-in.
# Connect: the accounts that can be offered in the "Choose a Microsoft account" pop-up.
# Sources (names / email addresses only - never passwords or tokens):
#   1. accounts used before in this tool (accounts.json in the tool folder, last 10)
#   2. the work or school account of this Windows sign-in (whoami /upn)
#   3. the accounts signed in to the browser profiles of Microsoft Edge, Google Chrome and Brave on this PC
# A web page cannot see the browser's accounts, so the server reads the profile list the browser keeps on disk.

# File that remembers the accounts used before (only e-mail and display name, never passwords).
$script:AccFile = Join-Path $Root 'accounts.json'

# Returns the saved list from accounts.json (empty list if the file is missing or damaged).
function Get-RecentAccounts {
    $o = @()
    try { if (Test-Path $script:AccFile) { $o = @(Get-Content $script:AccFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch {}
    $o
}
# Remembers an account: $upn = e-mail / UPN, $name = display name. Ignores values that do not look like an e-mail (regex: text@text, no spaces).
# Puts the account first, removes an older entry for the same UPN, keeps only the 10 newest. Errors are ignored on purpose (not critical).
function Save-RecentAccount($upn, $name) {
    $upn = "$upn".Trim(); if ($upn -notmatch '^[^@\s]+@[^@\s]+$') { return }
    try {
        $list = @(Get-RecentAccounts | Where-Object { "$($_.upn)" -ine $upn })
        $list = @([pscustomobject]@{ upn = $upn; name = "$name"; last = (Get-Date).ToString('yyyy-MM-dd HH:mm') }) + $list
        ($list | Select-Object -First 10 | ConvertTo-Json -Depth 3 ) | Set-Content -Path $script:AccFile -Encoding UTF8
    } catch {}
}

# Reads the signed-in accounts of Edge, Chrome and Brave from their profile folders. Returns objects { upn, name, src (browser - profile) }.
function Get-BrowserAccounts {
    $out = @()
    # Where each browser keeps its data for the current Windows user.
    $roots = @(
        @{ n = 'Microsoft Edge'; p = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' },
        @{ n = 'Google Chrome';  p = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' },
        @{ n = 'Brave';          p = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data' })
    foreach ($b in $roots) {
        if (-not $b.p -or -not (Test-Path $b.p)) { continue }
        # Source 1: 'Local State' JSON has profile.info_cache with the e-mail of every profile.
        $ls = Join-Path $b.p 'Local State'
        try {
            if (Test-Path $ls) {
                $st = Get-Content $ls -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($st.profile -and $st.profile.info_cache) {
                    foreach ($p in $st.profile.info_cache.PSObject.Properties) {
                        $e = "$($p.Value.user_name)".Trim()
                        if ($e -match '^[^@\s]+@[^@\s]+$') { $out += [pscustomobject]@{ upn = $e; name = "$($p.Value.gaia_name)"; src = "$($b.n) - $($p.Value.name)" } }
                    }
                }
            }
        } catch {}
        try {
            # Source 2: each profile folder (Default, Profile 1, ...) has a Preferences file with account_info (extra accounts). Errors are ignored.
            foreach ($pd in @(Get-ChildItem $b.p -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                $pf = Join-Path $pd.FullName 'Preferences'
                if (-not (Test-Path $pf)) { continue }
                $pr = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($a in @($pr.account_info)) {
                    $e = "$($a.email)".Trim()
                    if ($e -match '^[^@\s]+@[^@\s]+$') { $out += [pscustomobject]@{ upn = $e; name = "$($a.full_name)"; src = "$($b.n) - $($pd.Name)" } }
                }
            }
        } catch {}
    }
    $out
}

# Handler: merges the three sources into one list without duplicates (matched by e-mail, ignoring case).
$ScreenHandlers['/api/known-accounts'] = {
    $script:__acc = @()
    # Source 1: accounts used before in this tool.
    foreach ($r in @(Get-RecentAccounts)) { $script:__acc += [pscustomobject]@{ upn = "$($r.upn)"; name = "$($r.name)"; src = "Used before ($($r.last))" } }
    try {
        # Source 2: the work/school account of this Windows sign-in. whoami fails on PCs that are not domain/Entra joined - then it is skipped.
        $w = (& whoami.exe /upn 2>$null | Select-Object -First 1)
        if ("$w" -match '^[^@\s]+@[^@\s]+$') {
            $ex = $script:__acc | Where-Object { $_.upn -ieq "$w" } | Select-Object -First 1
            if ($ex) { $ex.src += '; This Windows sign-in' } else { $script:__acc += [pscustomobject]@{ upn = "$w"; name = ''; src = 'This Windows sign-in' } }
        }
    } catch {}
    # Source 3: browser accounts. If the e-mail is already listed, only add the source name (and the name if it was empty).
    foreach ($b in @(Get-BrowserAccounts)) {
        $ex = $script:__acc | Where-Object { $_.upn -ieq $b.upn } | Select-Object -First 1
        if ($ex) { if ($ex.src -notlike "*$($b.src)*") { $ex.src += "; $($b.src)" }; if (-not $ex.name -and $b.name) { $ex.name = $b.name } }
        else { $script:__acc += $b }
    }
    # Return at most 20 accounts to the pop-up.
    Send $ctx @{ ok = $true; accounts = @($script:__acc | Select-Object -First 20) }
}

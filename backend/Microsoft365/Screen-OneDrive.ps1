# Screen-OneDrive.ps1 - back end for the OneDrive & storage screen.
# Screen: OneDrive & storage
# Screen version: 2.5.5   (changes ONLY when this screen changes - not with every release)
# Loaded by server.ps1 at start-up; do not run it on its own.
#
#  * Storage usage (read only): how much is used in the tenant - every OneDrive, every SharePoint site and every mailbox, with
#    totals in GB - from the Microsoft 365 usage reports (Microsoft Graph, Reports.Read.All; your role must be allowed to read reports).
#  * Delete OneDrive: look up OneDrives by user (UPN / e-mail) or by OneDrive URL, check them (owner, account state, size, last change),
#    then move them to the SharePoint recycle bin (they can be restored for 93 days) or delete them permanently. Uses the SharePoint
#    admin API with the person's own sign-in (SharePoint Administrator or Global Administrator). Only OneDrive (personal) sites can be
#    deleted here - never a SharePoint team site. Every run is logged (activity log + logs\onedrive-audit-yyyy-MM.csv).
#    Permission: "Delete OneDrive" (separate from "OneDrive and storage", off by default).

# ENDPOINTS: /api/spo-status, /api/spo-forget, /api/spo-code-start, /api/spo-code-poll (connect the SharePoint admin sign-in), /api/od-usage (tenant
# storage report job), /api/od-lookup (check OneDrives), /api/od-delete (recycle bin or permanent delete job), /api/od-restore (restore from the recycle bin).
# Long work runs as background jobs (Start-GJob in Screen-Intune.ps1); the page follows them with /api/gjob. APIs used: Graph reports (beta/reports/...),
# Graph users, and the SharePoint admin REST API <tenant>-admin.sharepoint.com/_api/SPO.Tenant (RemoveSite, RemoveDeletedSite, RestoreDeletedSite,
# GetSitePropertiesByUrl). Data files: spo-signins.json (encrypted SharePoint refresh tokens), Logs\onedrive-audit-yyyy-MM.csv.
#
# SharePoint Online Management Shell = Microsoft's own public app; the SharePoint admin token is a separate sign-in from the Graph one.
$script:SpoClientId = '9bc3ab49-b65d-410a-85ad-de819febfddc'   # SharePoint Online Management Shell (Microsoft's own app)
# the SharePoint addresses of this tenant (from Microsoft Graph), e.g. https://contoso-admin.sharepoint.com
# Works out the SharePoint admin address of the tenant (https://<name>-admin.sharepoint.com) from the root site's host name, then caches it.
# Handles the sharepoint.com / .us / .de / .cn clouds.
function Get-SpoAdminUrl {
    if ($script:SpoAdmin) { return $script:SpoAdmin }
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $r = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/sites/root?$select=webUrl' -ErrorAction Stop
    $h = ([uri]"$($r.webUrl)").Host   # contoso.sharepoint.com
    if ($h -notmatch '^([A-Za-z0-9-]+)\.sharepoint\.(com|us|de|cn)$') { throw "Could not work out the SharePoint address of the tenant ($h)." }
    $script:SpoAdmin = "https://$($Matches[1])-admin.sharepoint.$($Matches[2])"
    $script:SpoAdmin
}
# The host where personal OneDrives live: the admin host with '-admin' replaced by '-my' (contoso-my.sharepoint.com).
function Get-SpoMyHost { ([uri](Get-SpoAdminUrl)).Host -replace '-admin\.', '-my.' }
# A SharePoint admin token: from the Microsoft sign-in (when its app may use SharePoint), or from "Connect SharePoint admin"
# v2.4.2: the SharePoint admin sign-in is remembered (encrypted, this server only) for the same portal user + the same Microsoft account,
# so "Connect SharePoint admin" is needed only once - not after every Microsoft sign-in or restart.
# The remembered SharePoint sign-ins are kept in this file, encrypted by Read-/Write-SecureText (Windows DPAPI - only this server can read it).
$script:SpoStoreFile = Join-Path $Root 'spo-signins.json'
# Key for the saved sign-in: 'portal user|microsoft account' in lower case. Returns $null when nobody is signed in to Microsoft.
function Get-SpoStoreKey { $pu = if ($script:SessUser.owner) { 'owner' } else { "$($script:SessUser.name)" }; $mu = if ($script:WhoUpn) { "$($script:WhoUpn)" } else { "$($script:Who)" }; if (-not $mu) { return $null }; ("$pu|$mu").ToLower() }
# Loads all saved SharePoint sign-ins as a hashtable (empty if the file is missing or cannot be decrypted).
function Read-SpoStore { $h = @{}; if (Test-Path $script:SpoStoreFile) { try { $j = (Read-SecureText $script:SpoStoreFile) | ConvertFrom-Json; foreach ($x in @($j.PSObject.Properties)) { $h[$x.Name] = $x.Value } } catch {} }; $h }
# Writes the hashtable back, encrypted. A failure only prints a warning.
function Save-SpoStore($h) { try { $o = [ordered]@{}; foreach ($k in $h.Keys) { $o[$k] = $h[$k] }; Write-SecureText $script:SpoStoreFile ($o | ConvertTo-Json -Depth 4) } catch { Write-Host "SharePoint sign-in could not be saved: $($_.Exception.Message)" -ForegroundColor Yellow } }
# Saves the current SharePoint refresh token for this portal user + Microsoft account (so 'Connect SharePoint admin' is needed only once).
function Save-SpoSignIn { $k = Get-SpoStoreKey; if (-not $k -or -not $script:SpoRefresh) { return }; $h = Read-SpoStore; $h[$k] = @{ client = "$($script:SpoClient)"; rt = "$($script:SpoRefresh)"; at = (Get-Date).ToString('yyyy-MM-dd HH:mm') }; Save-SpoStore $h }
# Deletes the saved SharePoint sign-in for this portal user + Microsoft account.
function Remove-SpoSignIn { $k = Get-SpoStoreKey; if (-not $k) { return }; $h = Read-SpoStore; if ($h.ContainsKey($k)) { $h.Remove($k); Save-SpoStore $h } }
# Returns a SharePoint admin access token, or throws 'NEED_SPO' (which the screen turns into 'Connect SharePoint admin') - or $null with -Quiet.
# Order: cached token (still valid for 5+ minutes); refresh token from this session; the saved one; the Microsoft sign-in's refresh token
# (works when its app is allowed to use SharePoint). A saved token that no longer works is removed.
function Get-SpoToken([switch]$Quiet) {
    $admin = Get-SpoAdminUrl
    if ($script:SpoTok -and $script:SpoExp -and (Get-Date) -lt $script:SpoExp.AddMinutes(-5)) { return $script:SpoTok }
    $tries = @()
    if ($script:SpoRefresh) { $tries += @{ c = $script:SpoClient; rt = $script:SpoRefresh; s = $null } }
    else { $k = Get-SpoStoreKey; if ($k) { $sv = (Read-SpoStore)[$k]; if ($sv -and $sv.rt) { $tries += @{ c = "$($sv.client)"; rt = "$($sv.rt)"; s = $null; saved = $true } } } }
    if ($script:MsRefresh) { $tries += @{ c = $(if ($script:MsClient) { $script:MsClient } else { $script:MsClientId }); rt = $script:MsRefresh; s = $script:MsSecret } }
    foreach ($t in $tries) {
        try {
            $f = @{ client_id = $t.c; grant_type = 'refresh_token'; refresh_token = $t.rt; scope = "$admin/.default offline_access" }
            if ($t.s) { $f.client_secret = (Unprotect-MailSecret $t.s) }
            $r = Invoke-MsToken $f $script:MsTenant
            $script:SpoTok = "$($r.access_token)"; $script:SpoExp = (Get-Date).AddSeconds([int]$r.expires_in); $script:SpoClient = $t.c; if ($r.refresh_token) { $script:SpoRefresh = "$($r.refresh_token)" }
            Save-SpoSignIn   # keep the newest refresh token (remembered for this portal user + Microsoft account)
            return $script:SpoTok
        } catch { if ($t.saved) { Remove-SpoSignIn } }
    }
    if ($Quiet) { return $null }
    throw 'NEED_SPO'
}
# Handler: 'Disconnect SharePoint admin' - forgets the saved and in-memory SharePoint sign-in.
$ScreenHandlers['/api/spo-forget'] = {
    Remove-SpoSignIn; $script:SpoTok = $null; $script:SpoExp = $null; $script:SpoRefresh = $null; $script:SpoClient = $null
    Send $ctx @{ ok = $true }
}
# Handler: tells the page whether a SharePoint admin token is available (connected) and the admin address. Errors are returned as text.
$ScreenHandlers['/api/spo-status'] = {
    $ok = $false; $admin = ''; $err = ''
    try { $admin = Get-SpoAdminUrl; $ok = [bool](Get-SpoToken -Quiet) } catch { $err = "$($_.Exception.Message)" }
    Send $ctx @{ ok = $true; connected = $ok; admin = $admin; error = $err }
}
# Handler (spo-code-start): device-code sign-in for SharePoint. Request: useApp (use the company's own app registration instead of the default).
# Reply: userCode, url, interval, expires. The page then calls /api/spo-code-poll.
# "Connect SharePoint admin" - sign in with a code (works from any PC)
$ScreenHandlers['/api/spo-code-start'] = {
    $admin = Get-SpoAdminUrl
    $app = Get-MsAppCfg; $client = $(if ($d.useApp -and $app.clientId) { "$($app.clientId)" } else { $script:SpoClientId })
    $ten = $(if ($app.tenant) { "$($app.tenant)" } elseif ($script:MsTenant) { $script:MsTenant } else { 'organizations' })
    try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$ten/oauth2/v2.0/devicecode" -Body @{ client_id = $client; scope = "$admin/.default offline_access" } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch { $m = $_.Exception.Message; try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.error_description) { $m = ("$($j.error_description)" -split "`r?`n")[0] } } catch {}; throw "Microsoft did not give a sign-in code: $m" }
    $script:SpoDev = @{ code = "$($r.device_code)"; client = $client; tenant = $ten; until = (Get-Date).AddSeconds([int]$r.expires_in) }
    Send $ctx @{ ok = $true; userCode = "$($r.user_code)"; url = "$($r.verification_uri)"; interval = [int]$r.interval; expires = [int]$r.expires_in }
}
# Handler: checks if the code was entered. Reply { pending = true } while waiting; on success stores the tokens, remembers them and logs 'Connect SharePoint admin'.
$ScreenHandlers['/api/spo-code-poll'] = {
    $dv = $script:SpoDev; if (-not $dv) { throw 'Start "Connect SharePoint admin" again.' }
    if ((Get-Date) -gt $dv.until) { $script:SpoDev = $null; throw 'The code has expired. Start again.' }
    try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($dv.tenant)/oauth2/v2.0/token" -Body @{ client_id = $dv.client; grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = $dv.code } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch {
        $m = $_.Exception.Message; $code = ''
        try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; $code = "$($j.error)"; if ($j.error_description) { $m = ("$($j.error_description)" -split "`r?`n")[0] } } catch {}
        if (-not $code -and $m -match '\(400\)') { $code = 'authorization_pending' }   # v2.4.3: the answer could not be read - while waiting Microsoft answers 400, so keep waiting (the code expiry still ends it)
        if ($code -in 'authorization_pending', 'slow_down') { Send $ctx @{ ok = $true; pending = $true }; return }
        $script:SpoDev = $null; throw "SharePoint sign-in failed: $m"
    }
    $script:SpoDev = $null
    $script:SpoTok = "$($r.access_token)"; $script:SpoExp = (Get-Date).AddSeconds([int]$r.expires_in); $script:SpoRefresh = "$($r.refresh_token)"; $script:SpoClient = $dv.client
    Save-SpoSignIn   # v2.4.2: remembered - not asked again
    try { Write-ActRow 'OneDrive & storage' 'Connect SharePoint admin' (Get-SpoAdminUrl) 'Done' '' } catch {}
    Send $ctx @{ ok = $true; connected = $true }
}

# Job script (here-string, runs in the background thread): reads the Microsoft 365 usage reports for $p.Period (D7/D30/D90/D180 days) - OneDrive accounts,
# SharePoint sites and (if $p.Mail) mailboxes - from Graph beta/reports (needs Reports.Read.All). Optionally looks up whether each owner's account is
# Enabled / Disabled / Not found (Graph users), and the tenant storage quota from SharePoint. Sizes are converted from bytes to GB (2 decimals).
# 'concealed' = true when the report hides user names (Microsoft setting 'conceal names'): owners then look like 32-character ids.
# Result: totals, per-account-state sums, quotas and the three row lists.
# ---------------- Storage usage (Microsoft 365 usage reports) ----------------
$script:OdUsageWork = @'
$per = $p.Period
$get = { param($r, $what) $p.Sync.step = "Reading $what..."; $p.Sync.done = 0; Get-GAll ("beta/reports/$r(period='$per')?`$format=application/json") 500000 }
$od = & $get 'getOneDriveUsageAccountDetail' 'OneDrive accounts'
$sp = & $get 'getSharePointSiteUsageDetail' 'SharePoint sites'
$mb = @(); $mbErr = ''
if ($p.Mail) { try { $mb = & $get 'getMailboxUsageDetail' 'mailboxes' } catch { $mbErr = "$_" } }
$gb = { param($b) [math]::Round(([double]$b) / 1GB, 2) }
# v2.1.1: is the account of each OneDrive / mailbox enabled, disabled or gone?
$acc = @{}; $accErr = ''
if ($p.Accounts) { try { $p.Sync.step = 'Reading which accounts are enabled or disabled...'; foreach ($u in (Get-GAll 'v1.0/users?$select=userPrincipalName,accountEnabled&$top=999' 500000)) { $acc["$($u.userPrincipalName)".ToLower()] = [bool]$u.accountEnabled } } catch { $accErr = "$_" } }
$st = { param($upn) if (-not $p.Accounts -or $accErr) { return '' }; $k = "$upn".ToLower(); if (-not $k) { return '' }; if ($acc.ContainsKey($k)) { if ($acc[$k]) { 'Enabled' } else { 'Disabled' } } else { 'Not found' } }
$odRows = @($od | Where-Object { -not $_.isDeleted } | ForEach-Object { [ordered]@{ owner = "$($_.ownerPrincipalName)"; account = (& $st $_.ownerPrincipalName); name = "$($_.ownerDisplayName)"; url = "$($_.siteUrl)"; usedGB = (& $gb $_.storageUsedInBytes); quotaGB = (& $gb $_.storageAllocatedInBytes); files = [int64]$_.fileCount; activeFiles = [int64]$_.activeFileCount; lastActivity = "$($_.lastActivityDate)" } })
$spRows = @($sp | Where-Object { -not $_.isDeleted } | ForEach-Object { [ordered]@{ url = "$($_.siteUrl)"; owner = "$($_.ownerDisplayName)"; ownerUpn = "$($_.ownerPrincipalName)"; template = "$($_.rootWebTemplate)"; usedGB = (& $gb $_.storageUsedInBytes); quotaGB = (& $gb $_.storageAllocatedInBytes); files = [int64]$_.fileCount; lastActivity = "$($_.lastActivityDate)" } })
$mbRows = @($mb | Where-Object { -not $_.isDeleted } | ForEach-Object { [ordered]@{ upn = "$($_.userPrincipalName)"; account = (& $st $_.userPrincipalName); name = "$($_.displayName)"; usedGB = (& $gb $_.storageUsedInBytes); quotaGB = (& $gb $_.prohibitSendReceiveQuotaInBytes); items = [int64]$_.itemCount; archive = "$($_.hasArchive)"; lastActivity = "$($_.lastActivityDate)" } })
$sum = { param($rows) $t = 0.0; foreach ($x in $rows) { $t += [double]$x.usedGB }; [math]::Round($t, 2) }
$tq = $null
if ($p.Spo) { try { $p.Sync.step = 'Reading the tenant storage quota...'; $t = Invoke-Spo '/_api/SPO.Tenant?$select=StorageQuota,StorageQuotaAllocated' $null 'GET'; $tq = @{ quotaGB = [math]::Round([double]$t.StorageQuota / 1024, 1); allocatedGB = [math]::Round([double]$t.StorageQuotaAllocated / 1024, 1) } } catch {} }
$concealed = (@($odRows | Select-Object -First 20 | Where-Object { $_.owner -match '^[0-9A-F]{32}$' }).Count -gt 5)
$by = { param($rows) $o = [ordered]@{}; foreach ($x in $rows) { $k = $(if ($x.account) { $x.account } else { 'Unknown' }); if (-not $o.Contains($k)) { $o[$k] = @{ count = 0; gb = 0.0 } }; $o[$k].count++; $o[$k].gb += [double]$x.usedGB }; foreach ($k in @($o.Keys)) { $o[$k].gb = [math]::Round($o[$k].gb, 2) }; $o }
$quota = { param($rows) $t = 0.0; foreach ($x in $rows) { $t += [double]$x.quotaGB }; [math]::Round($t, 2) }
@{ period = $per; accountsError = $accErr; byAccount = @{ onedrive = (& $by $odRows); mailboxes = (& $by $mbRows) }; quotas = @{ onedriveGB = (& $quota $odRows); mailGB = (& $quota $mbRows) }; at = (Get-Date).ToString('yyyy-MM-dd HH:mm'); concealed = $concealed; tenantQuota = $tq; mailError = $mbErr
   totals = @{ onedriveGB = (& $sum $odRows); onedriveCount = $odRows.Count; sharepointGB = (& $sum $spRows); sharepointCount = $spRows.Count; mailGB = (& $sum $mbRows); mailCount = $mbRows.Count }
   onedrive = $odRows; sharepoint = $spRows; mailboxes = $mbRows }
'@
# Handler: start the storage report job. Request: period (D7|D30|D90|D180, default D7), mail (include mailboxes), accounts (false = skip the account-state lookup).
# SharePoint token is optional here (only used for the tenant quota). Reply: { ok, id }.
$ScreenHandlers['/api/od-usage'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $per = "$($d.period)"; if ($per -notin 'D7', 'D30', 'D90', 'D180') { $per = 'D7' }
    $tok = Get-SessGraphToken; if (-not $tok) { throw 'The Microsoft sign-in could not give a token. Sign out of Microsoft and connect again.' }
    $spo = $null; try { $spo = Get-SpoToken -Quiet } catch {}
    $id = Start-GJob 'odusage' $script:OdUsageWork @{ Token = $tok; Period = $per; Mail = [bool]$d.mail; Accounts = ($d.accounts -ne $false); Spo = $spo; Admin = $(if ($spo) { $script:SpoAdmin } else { '' }) } 'Tenant storage usage'
    # v2.5.5: reading a report is not an action - not logged
    Send $ctx @{ ok = $true; id = $id }
}

# Job script: for each typed user (e-mail) or OneDrive address find the OneDrive URL, owner, account state, size (GB), last change and status.
# An https address must be on this tenant's -my host under /personal/<name>. For an e-mail the user's mySite is read from Graph; if missing the
# address is guessed from the e-mail (every character that is not a-z or 0-9 becomes '_') and a note asks the person to check it.
# Size and status come from SharePoint GetSitePropertiesByUrl (StorageUsage is in MB). Without a SharePoint token only the address is shown.
# ---------------- Look up OneDrives ----------------
$script:OdLookWork = @'
$rows = New-Object Collections.Generic.List[object]; $p.Sync.total = @($p.Items).Count; $i = 0
foreach ($it in @($p.Items)) {
    if ($p.Sync.cancel) { throw 'Stopped.' }
    $i++; $p.Sync.done = $i; $p.Sync.step = "Checking $it"
    $r = [ordered]@{ input = "$it"; url = ''; owner = ''; ownerName = ''; account = ''; usedGB = $null; lastChange = ''; status = ''; ok = $false; note = '' }
    try {
        if ("$it" -match '^https://') {
            $u = ([uri]"$it"); if ($u.Host -ine $p.MyHost -or $u.AbsolutePath -notmatch '^/personal/([^/]+)') { throw "Not a OneDrive address of this tenant (it must start with https://$($p.MyHost)/personal/)." }
            $r.url = "https://$($u.Host)/personal/$($Matches[1])"
        } else {
            $usr = $null; try { $usr = Invoke-G ("v1.0/users/$([uri]::EscapeDataString("$it"))?`$select=userPrincipalName,displayName,accountEnabled,mySite") } catch { if ("$_" -notmatch 'does not exist|not found|Request_ResourceNotFound') { throw } }
            if ($usr) {
                $r.owner = "$($usr.userPrincipalName)"; $r.ownerName = "$($usr.displayName)"; $r.account = $(if ($usr.accountEnabled) { 'Enabled' } else { 'Disabled' })
                if ($usr.mySite) { $r.url = "$($usr.mySite)".TrimEnd('/') }
            } else { $r.account = 'Not found (deleted?)' }
            if (-not $r.url) { $r.url = "https://$($p.MyHost)/personal/" + (("$it".ToLower()) -replace '[^a-z0-9]', '_'); $r.note = 'Address worked out from the e-mail - check it.' }
        }
        if ($p.Spo) {
            try {
                $sp = Invoke-Spo '/_api/SPO.Tenant/GetSitePropertiesByUrl' @{ url = $r.url; includeDetail = $false }
                if (-not $r.owner) { $r.owner = "$($sp.Owner)" }
                $r.usedGB = [math]::Round(([double]$sp.StorageUsage) / 1024, 2)
                if ($sp.LastContentModifiedDate) { try { $r.lastChange = ([datetime]$sp.LastContentModifiedDate).ToString('yyyy-MM-dd') } catch { $r.lastChange = "$($sp.LastContentModifiedDate)" } }
                $r.status = "$($sp.Status)"; if ($sp.LockState -and "$($sp.LockState)" -ne 'Unlock') { $r.status += " (locked: $($sp.LockState))" }
                $r.ok = $true
            } catch { $m = "$_"; if ($m -match 'Cannot get site|does not exist|not found|404') { $r.status = 'Not found'; $r.note = 'No OneDrive at this address (already deleted, or never created).' } else { throw } }
        } else { $r.ok = [bool]$r.url; $r.status = '(size unknown - connect SharePoint admin)' }
        if ($r.owner -and -not $r.account) {
            try { $o = Invoke-G ("v1.0/users/$([uri]::EscapeDataString($r.owner))?`$select=accountEnabled,displayName"); $r.account = $(if ($o.accountEnabled) { 'Enabled' } else { 'Disabled' }); if (-not $r.ownerName) { $r.ownerName = "$($o.displayName)" } } catch { $r.account = 'Not found (deleted?)' }
        }
    } catch { $r.ok = $false; $r.status = 'Error'; $r.note = "$_" }
    $rows.Add($r)
}
@{ rows = $rows.ToArray() }
'@
# Handler: start the look-up job. Request: items = list of e-mails / OneDrive addresses (max 500, duplicates removed). Reply: { ok, id, spo }.
$ScreenHandlers['/api/od-lookup'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $items = @(@($d.items) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $items.Count) { throw 'Type at least one user (e-mail) or OneDrive address.' }
    if ($items.Count -gt 500) { throw 'Up to 500 at a time.' }
    $tok = Get-SessGraphToken; if (-not $tok) { throw 'The Microsoft sign-in could not give a token. Sign out of Microsoft and connect again.' }
    $spo = $null; try { $spo = Get-SpoToken -Quiet } catch {}
    $id = Start-GJob 'odlook' $script:OdLookWork @{ Token = $tok; Spo = $spo; Admin = (Get-SpoAdminUrl); MyHost = (Get-SpoMyHost); Items = $items } 'Look up OneDrives'
    Send $ctx @{ ok = $true; id = $id; spo = [bool]$spo }
}

# Job script: deletes each OneDrive in $p.Urls. Step 1 always moves the site to the SharePoint recycle bin (RemoveSite - restorable for 93 days).
# Step 2, only in 'permanent' mode, empties it from the recycle bin (RemoveDeletedSite). The first step finishes in the background at Microsoft,
# so step 2 is retried up to 12 times, 5 seconds apart. A failure on one URL does not stop the others; Stop marks the rest as Skipped.
# ---------------- Delete OneDrives ----------------
$script:OdDelWork = @'
$rows = New-Object Collections.Generic.List[object]; $p.Sync.total = @($p.Urls).Count; $i = 0
foreach ($url in @($p.Urls)) {
    if ($p.Sync.cancel) { $rows.Add([ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); url = $url; result = 'Skipped'; message = 'Stopped by the user' }); continue }
    $i++; $p.Sync.done = $i - 1; $p.Sync.step = "Deleting $url"
    $r = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); url = $url; result = ''; message = '' }
    try {
        [void](Invoke-Spo '/_api/SPO.Tenant/RemoveSite' @{ siteUrl = $url })
        $r.result = 'In recycle bin'; $r.message = 'Moved to the SharePoint recycle bin - can be restored for 93 days.'
        if ($p.Mode -eq 'permanent') {
            $p.Sync.step = "Deleting permanently $url"
            $last = ''
            for ($t = 1; $t -le 12; $t++) {   # the removal finishes in the background - wait for it, then empty it from the recycle bin
                try { [void](Invoke-Spo '/_api/SPO.Tenant/RemoveDeletedSite' @{ siteUrl = $url }); $last = ''; break } catch { $last = "$_"; Start-Sleep -Seconds 5 }
            }
            if ($last) { $r.result = 'In recycle bin'; $r.message = "Moved to the recycle bin, but the permanent delete failed: $last" }
            else { $r.result = 'Deleted permanently'; $r.message = 'Deleted permanently (cannot be restored).' }
        }
    } catch { $r.result = 'Failed'; $r.message = "$_" }
    $rows.Add($r); $p.Sync.done = $i
}
@{ rows = $rows.ToArray(); mode = $p.Mode }
'@
# Called when the delete job ends: writes every result to Logs\onedrive-audit-yyyy-MM.csv and to the activity log (who, mode, URL, result).
function Complete-GJob_oddel($j, $res, $err) {
    $f = Join-Path $LogDir ('onedrive-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,PortalUser,MicrosoftAccount,Mode,OneDriveUrl,Result,Message' | Out-File $f -Encoding utf8 }
    foreach ($r in @($res.rows)) {
        $vals = @($r.time, $j.user, $j.arg.By, $j.arg.Mode, $r.url, $r.result, $r.message) | ForEach-Object { ConvertTo-CsvCell $_ }
        ($vals -join ',') | Add-Content $f
        Write-ActRow 'OneDrive & storage' $(if ($j.arg.Mode -eq 'permanent') { 'Delete OneDrive permanently' } else { 'Delete OneDrive (recycle bin)' }) $r.url $r.result $r.message
    }
    if ($err) { Write-ActRow 'OneDrive & storage' 'Delete OneDrive' '' "Failed: $err" '' }
    $script:SpDirty = $true
}
# Handler: start the delete job. Request: mode ('recycle' or 'permanent'), confirm (must be exactly DELETE for permanent), urls (max 200).
# Safety: only https addresses on THIS tenant's -my host of the form /personal/<name> are accepted - never SharePoint team sites.
# Needs the SharePoint admin sign-in; if missing the reply is { needSpo = true } so the page can ask for it.
$ScreenHandlers['/api/od-delete'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $mode = "$($d.mode)"; if ($mode -notin 'recycle', 'permanent') { throw 'Choose recycle bin or permanent.' }
    if ($mode -eq 'permanent' -and "$($d.confirm)" -cne 'DELETE') { throw 'Type DELETE to confirm a permanent delete.' }
    $my = Get-SpoMyHost
    $urls = @(@($d.urls) | ForEach-Object { "$_".Trim().TrimEnd('/') } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $urls.Count) { throw 'Choose at least one OneDrive.' }
    if ($urls.Count -gt 200) { throw 'Up to 200 OneDrives at a time.' }
    foreach ($u in $urls) { $x = $null; try { $x = [uri]$u } catch {}; if (-not $x -or $x.Scheme -ne 'https' -or $x.Host -ine $my -or $x.AbsolutePath -notmatch '^/personal/[^/]+$') { throw "Only OneDrive addresses of this tenant can be deleted here (https://$my/personal/...): $u" } }
    try { $spo = Get-SpoToken } catch { if ("$($_.Exception.Message)" -eq 'NEED_SPO') { Send $ctx @{ ok = $false; needSpo = $true; error = 'Connect SharePoint admin first (button on this screen).' }; return }; throw }
    $id = Start-GJob 'oddel' $script:OdDelWork @{ Spo = $spo; Admin = (Get-SpoAdminUrl); Urls = $urls; Mode = $mode; By = "$($script:Who)" } "Delete $($urls.Count) OneDrive(s) - $mode"
    Write-ActRow 'OneDrive & storage' 'Delete OneDrive' "$($urls.Count) OneDrive(s)" 'Started' "mode=$mode"
    Send $ctx @{ ok = $true; id = $id }
}
# Restore OneDrives from the SharePoint recycle bin (only what was moved there, not permanently deleted)
# Handler: brings OneDrives back from the SharePoint recycle bin (RestoreDeletedSite). Request: urls (max 50, same tenant -my host rule).
# Runs directly (not as a job). Reply: results = one { ok, message } per address; each is written to the activity log.
$ScreenHandlers['/api/od-restore'] = {
    $my = Get-SpoMyHost
    $urls = @(@($d.urls) | ForEach-Object { "$_".Trim().TrimEnd('/') } | Where-Object { $_ -match ('^https://' + [regex]::Escape($my) + '/personal/[^/]+$') } | Select-Object -Unique)
    if (-not $urls.Count) { throw 'Choose at least one OneDrive address of this tenant.' }
    if ($urls.Count -gt 50) { throw 'Up to 50 at a time.' }
    try { $spo = Get-SpoToken } catch { if ("$($_.Exception.Message)" -eq 'NEED_SPO') { Send $ctx @{ ok = $false; needSpo = $true; error = 'Connect SharePoint admin first.' }; return }; throw }
    $admin = Get-SpoAdminUrl; $out = @()
    foreach ($u in $urls) {
        try { [void](Invoke-RestMethod -Method Post -Uri "$admin/_api/SPO.Tenant/RestoreDeletedSite" -Headers @{ Authorization = "Bearer $spo"; Accept = 'application/json;odata=nometadata' } -Body (@{ siteUrl = $u } | ConvertTo-Json) -ContentType 'application/json;odata=nometadata' -ErrorAction Stop); $out += @{ url = $u; ok = $true; message = 'Restored' } }
        catch { $m = Get-ErrMsg $_; try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.'odata.error'.message.value) { $m = "$($j.'odata.error'.message.value)" } } catch {}; $out += @{ url = $u; ok = $false; message = $m } }
        Write-ActRow 'OneDrive & storage' 'Restore OneDrive' $u $(if ($out[-1].ok) { 'Restored' } else { 'Failed' }) $out[-1].message
    }
    Send $ctx @{ ok = $true; results = $out }
}

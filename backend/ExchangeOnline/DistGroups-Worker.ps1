# DistGroups-Worker.ps1 - Exchange Online worker for the Distribution groups screen of the Admin Console.
# Screen: Distribution groups - Exchange Online worker
# Screen version: 2.4.7   (changes ONLY when this screen changes - not with every release)
#
# Started by the Admin Console in a hidden background process when you open the Distribution groups screen while signed in to
# Microsoft, with the same account (or the same app and certificate). It stops when you sign out of Microsoft. Do not dot-source it.
# It signs in to Exchange Online ONCE, then waits for job files in <JobsRoot>\Pending and runs them one by one:
#   Add     - add users to distribution groups (every user into every group, or fill the groups in order up to a maximum)
#   Remove  - remove users from distribution groups
#   Both    - add and remove in one run
#   Export  - export the members of groups (one combined CSV, or one CSV per group)
#   MbxInfo / MbxChange - Shared mailbox screen: read a mailbox, convert it to shared, give or remove Full Access / Send As / Send on behalf
# It writes <JobsRoot>\heartbeat.txt ("Status|yyyy-MM-dd HH:mm:ss") every second, even during a long run, and stops
# (disconnects and closes) when <JobsRoot>\stop.signal appears. Every step is written to FullRunLog_<job>.log in the run's
# log folder, with a results CSV and a final membership report. Nothing is ever deleted - only the members you asked for are removed.

param(
    # WHAT THIS FILE IS: the background worker behind the Distribution groups, Shared mailbox and Address list screens (it is not a screen with
    # its own endpoints). Exchange Online cannot be changed through Microsoft Graph, so this process stays connected to Exchange Online
    # (ExchangeOnlineManagement module) and runs the job files that Screen-DistGroups.ps1 / Screen-SharedMailbox.ps1 queue.
    # Job actions: Add, Remove, Both, Export, MbxInfo, MbxChange, MbxHide. Output: FullRunLog_<id>.log, Results_<id>.csv, Result_<id>.json, reports.
    # Who may use it: only the Admin Console starts it, under the Windows account that runs the tool; it signs in as the Microsoft admin account.
    #
    # Parameters (given by Screen-DistGroups.ps1 > Start-DgWorker on the command line):
    #   JobsRoot  - folder with Pending / Running / Done / Failed, heartbeat.txt and stop.signal (one per Microsoft account)
    #   AdminUPN / AppId + CertificateThumbprint + Organization / TokenFile - the three ways to sign in to Exchange Online (see the main section)
    [Parameter(Mandatory = $true)][string]$JobsRoot,
    [string]$AdminUPN,                # the account signed in to Microsoft in the Admin Console (pre-fills the sign-in)
    [string]$AppId,                   # certificate sign-in: same app, certificate and tenant as the Admin Console
    [string]$CertificateThumbprint,
    [string]$Organization,
    [string]$TokenFile,               # v2.0.0: sign in with the person's own Microsoft sign-in from the portal (no window - works for people on other PCs)
    [switch]$Visible                  # opened with 'Open sign-in window': stay open after an error so it can be read
)

# Folders and files shared with the Admin Console: a job file moves Pending -> Running -> Done (or Failed). The Admin Console reads the heartbeat
# file to show the status, and writes stop.signal to ask the worker to close.
$ErrorActionPreference = 'Stop'
$Pending = Join-Path $JobsRoot 'Pending'
$RunDir  = Join-Path $JobsRoot 'Running'
$DoneDir = Join-Path $JobsRoot 'Done'
$FailDir = Join-Path $JobsRoot 'Failed'
$Beat    = Join-Path $JobsRoot 'heartbeat.txt'
$StopSig = Join-Path $JobsRoot 'stop.signal'
foreach ($dir in @($JobsRoot, $Pending, $RunDir, $DoneDir, $FailDir)) { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null } }

# Current status text (written to the heartbeat), time of the last heartbeat, and the log file of the job that is running now.
$script:Status = 'Starting'
$script:LastBeat = [datetime]::MinValue
$script:LogFile = $null

# Version reported in the heartbeat (the third value).
$script:WorkerVersion = '1.98.5'
# Writes the heartbeat file 'Status|time|version' (at most once per second unless -Force). The Admin Console shows 'Stale' if it stops changing.
# Pass a new $status text to change the status.
function Set-Beat([string]$status, [switch]$Force) {
    if ($status) { $script:Status = $status }
    if ($Force -or ((Get-Date) - $script:LastBeat).TotalSeconds -ge 1) {
        try { "$($script:Status)|$('{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))|$($script:WorkerVersion)" | Set-Content -Path $Beat -Encoding UTF8 } catch {}
        $script:LastBeat = Get-Date
    }
}
# Writes a line with time to the window and, if a job is running, to its FullRunLog file. Also refreshes the heartbeat so a long job stays 'alive'.
function Write-Log([string]$msg, [string]$color = 'Gray') {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {} }
    Set-Beat
}
# True when the Admin Console has asked the worker to close (stop.signal exists). Checked in all loops so a run can be stopped.
function Test-Stop { Test-Path $StopSig }
# Token handling for the portal sign-in (TokenFile):
# v2.0.0: Exchange Online access token from the portal sign-in (your own app registration with the Exchange.Manage permission).
# The file is protected with Windows DPAPI (only this Windows account on this server can read it) and is removed when the worker stops.
# Time of the last token sign-in. Tokens last about an hour, so the main loop renews them after 40 minutes.
$script:TokAt = [datetime]::MinValue
# Reads the DPAPI-protected token file, then asks Microsoft for a new Exchange Online access token with the saved refresh token.
# If the app secret is wrong for a public client (error AADSTS700025) it retries without the secret. The new refresh token is saved back
# to the file (refresh tokens rotate). Returns @{ token; upn }. A failure explains that the app needs the Exchange.Manage permission with admin consent.
function Get-ExoToken {
    $raw = Get-Content -Path $TokenFile -Raw -ErrorAction Stop
    # Decrypt (DPAPI) and free the plain text from memory as soon as it is parsed.
    $ss = ConvertTo-SecureString $raw.Trim(); $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { $t = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) | ConvertFrom-Json } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    $f = @{ client_id = $t.client; grant_type = 'refresh_token'; refresh_token = $t.refresh; scope = 'https://outlook.office365.com/.default offline_access' }
    if ($t.secret) { $f.client_secret = $t.secret }
    try { try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($t.tenant)/oauth2/v2.0/token" -Body $f -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
          catch { if ($f.client_secret -and "$($_.ErrorDetails.Message) $($_.Exception.Message)" -match 'AADSTS700025') { $f.Remove('client_secret'); $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($t.tenant)/oauth2/v2.0/token" -Body $f -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop } else { throw } } }
    catch {
        $m = $_.Exception.Message; try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.error_description) { $m = ("$($j.error_description)" -split "`r?`n")[0] } } catch {}
        throw "Exchange Online token: $m (the app registration needs the Office 365 Exchange Online permission Exchange.Manage, with admin consent)"
    }
    if ($r.refresh_token) { $t.refresh = "$($r.refresh_token)"; (ConvertTo-SecureString ($t | ConvertTo-Json -Compress) -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -Path $TokenFile -Encoding ASCII }
    @{ token = "$($r.access_token)"; upn = "$($t.upn)" }
}
# Connects Exchange Online with the access token (needs ExchangeOnlineManagement 3.1+). Returns the UPN of the signed-in person.
function Connect-ExoToken {
    $k = Get-ExoToken
    Connect-ExchangeOnline -AccessToken $k.token -UserPrincipalName $k.upn -ShowBanner:$false -ErrorAction Stop
    $script:TokAt = Get-Date
    $k.upn
}

# Runs a script block that calls Exchange Online. Up to 3 retries (waiting between them) when the error says Exchange is busy / throttling
# (throttl, Server Busy, timeouts, HTTP 503 / 429). Any other error, or the 4th failure, is thrown to the caller.
# Run an Exchange Online call, retrying when Exchange says it is busy or throttling
function Invoke-Exo([scriptblock]$call) {
    for ($try = 1; ; $try++) {
        try { return (& $call) }
        catch {
            $m = $_.Exception.Message
            if ($try -lt 4 -and $m -match 'throttl|Server Busy|try again|temporar|timed out|503|429') { Write-Log "  Exchange is busy - waiting and trying again ($try of 3)..." 'DarkYellow'; Start-Sleep -Seconds (5 * $try); continue }
            throw
        }
    }
}

# Looks up one group. Throws if more than one group matches. Returns Typed (what was entered), Identity (the Guid, safest for later calls), Name, Email, Type.
# Find a distribution group by name, alias or email. Dynamic groups are refused (their members come from a filter).
function Get-Dg([string]$id) {
    $g = Invoke-Exo { Get-DistributionGroup -Identity $id -ErrorAction Stop }
    if (@($g).Count -gt 1) { throw "'$id' matches more than one group - use the group's email address." }
    $g = @($g)[0]
    [pscustomobject]@{ Typed = $id; Identity = "$($g.Guid)"; Name = "$($g.DisplayName)"; Email = "$($g.PrimarySmtpAddress)"; Type = "$($g.RecipientTypeDetails)" }
}
# Returns every member (ResultSize Unlimited) of a group as Key (Guid) / Name / Email / Type.
function Get-DgMembers($grp) {
    @(Invoke-Exo { Get-DistributionGroupMember -Identity $grp.Identity -ResultSize Unlimited -ErrorAction Stop }) | ForEach-Object {
        [pscustomobject]@{ Key = "$($_.Guid)"; Name = "$($_.DisplayName)"; Email = "$($_.PrimarySmtpAddress)"; Type = "$($_.RecipientType)" }
    }
}
# Looks up a recipient by address. The Guid (Key) is used to compare memberships exactly, even if the user typed an alias.
# Find the person (mailbox, mail user, contact...) behind an address so membership can be compared exactly
function Get-Person([string]$addr) {
    $r = @(Invoke-Exo { Get-Recipient -Identity $addr -ErrorAction Stop })
    if ($r.Count -gt 1) { throw "'$addr' matches more than one recipient - use the full email address." }
    [pscustomobject]@{ Typed = $addr; Key = "$($r[0].Guid)"; Name = "$($r[0].DisplayName)"; Email = "$($r[0].PrimarySmtpAddress)" }
}
# Adds or removes one member. $verb = 'Add' or 'Remove'.
# Add / remove one member. -BypassSecurityGroupManagerCheck lets an Exchange admin change groups they do not own;
# if the admin's role does not include that switch, try again without it.
function Invoke-Member([string]$verb, $grp, $person) {
    $p = @{ Identity = $grp.Identity; Member = $person.Key; Confirm = $false; ErrorAction = 'Stop' }
    try {
        if ($verb -eq 'Add') { Invoke-Exo { Add-DistributionGroupMember @p -BypassSecurityGroupManagerCheck } | Out-Null }
        else { Invoke-Exo { Remove-DistributionGroupMember @p -BypassSecurityGroupManagerCheck } | Out-Null }
    } catch {
        if ($_.Exception.Message -match 'BypassSecurityGroupManagerCheck|parameter cannot be found') {
            if ($verb -eq 'Add') { Invoke-Exo { Add-DistributionGroupMember @p } | Out-Null } else { Invoke-Exo { Remove-DistributionGroupMember @p } | Out-Null }
        } else { throw }
    }
}
# Makes a text usable as a file name: replaces \ / : * ? " < > | with _ and squeezes spaces.
function Get-SafeName([string]$s) { (($s -replace '[\\/:*?"<>|]', '_').Trim()) -replace '\s+', ' ' }

# Reads the 'Email' column of the CSV the Admin Console wrote; trims, drops blanks and duplicates (case-insensitive).
function Read-Users([string]$path) {
    $seen = @{}
    @(Import-Csv -Path $path | ForEach-Object { "$($_.Email)".Trim() } | Where-Object { $_ -and -not $seen[$_.ToLower()] } | ForEach-Object { $seen[$_.ToLower()] = 1; $_ })
}
# Looks up all groups of a job. A group that is not found is logged and put in $results as 'Group not found' (the run goes on). Returns the found groups.
function Resolve-Groups($ids, $results, $action) {
    $out = @()
    foreach ($id in @($ids)) {
        if (Test-Stop) { break }
        try { $g = Get-Dg $id; $out += $g; Write-Log ("Group found: {0} <{1}>{2}" -f $g.Name, $g.Email, $(if ($g.Typed -ine $g.Email) { " (typed: $($g.Typed))" } else { '' })) 'Cyan' }
        catch { Write-Log "Group NOT found: $id - $($_.Exception.Message)" 'Red'; [void]$results.Add([pscustomobject]@{ Action = $action; Group = $id; GroupEmail = ''; User = ''; UserEmail = ''; Result = 'Group not found'; Details = $_.Exception.Message }) }
    }
    $out
}
# Looks up all users of a job. Not-found users are recorded in $results; two typed addresses that are the same person are used once.
# Progress is logged every 50 users because the lists can be very long.
function Resolve-People($addrs, $results, $action) {
    $out = @(); $i = 0; $seen = @{}
    foreach ($a in @($addrs)) {
        $i++; if (Test-Stop) { break }
        if ($i % 50 -eq 0) { Write-Log "  checked $i of $(@($addrs).Count) users..." }
        try {
            $p = Get-Person $a
            if ($seen[$p.Key]) { Write-Log "  $a is the same person as $($seen[$p.Key]) - skipped" 'DarkYellow'; continue }
            $seen[$p.Key] = $a; $out += $p
        } catch { Write-Log "User NOT found: $a - $($_.Exception.Message)" 'Red'; [void]$results.Add([pscustomobject]@{ Action = $action; Group = ''; GroupEmail = ''; User = $a; UserEmail = ''; Result = 'User not found'; Details = $_.Exception.Message }) }
        Set-Beat
    }
    $out
}

# Everything from here to Invoke-MbxJob belongs to the Shared mailbox screen (jobs MbxInfo and MbxChange).
# ---------------- Shared mailbox screen ----------------
# MbxInfo   - read one mailbox: type, size, archive / hold, and who has Full Access, Send As and Send on behalf
# MbxChange - convert to a shared mailbox (or back to a user mailbox) and give / take away access. Result_<id>.json has every step.
# Takes the byte count out of Exchange's size text like '1.2 GB (1,288,490,188 bytes)'. Returns 0 if not found.
function Get-SizeBytes($s) { $m = [regex]::Match("$s", '\(([\d,.\s]+) bytes\)'); if ($m.Success) { [int64](($m.Groups[1].Value) -replace '[^\d]', '') } else { [int64]0 } }
# True for built-in / system accounts (NT AUTHORITY, SIDs S-1-5-, Exchange role groups) that must not be shown as 'people with access'.
function Test-SystemTrustee([string]$u) { $u -match '^(NT AUTHORITY\\|S-1-5-|.*\\Discovery Management|.*\\Organization Management|.*\\Exchange )' }
# Reads one mailbox: type, size, item count, archive, litigation hold, forwarding, hidden flag and who has Full Access, Send As and Send on behalf.
# Throws if the name matches more than one mailbox. Returns an ordered hashtable (also saved as 'info' in Result_<id>.json).
function Get-MbxInfo([string]$identity) {
    $mb = @(Invoke-Exo { Get-Mailbox -Identity $identity -ErrorAction Stop })
    if ($mb.Count -gt 1) { throw "'$identity' matches more than one mailbox - use the full email address." }
    $mb = $mb[0]
    $size = ''; $bytes = [int64]0; $items = 0
    try { $st = Invoke-Exo { Get-MailboxStatistics -Identity "$($mb.Guid)" -ErrorAction Stop }; $bytes = Get-SizeBytes $st.TotalItemSize; $size = "$($st.TotalItemSize)" -replace '\s*\(.*$', ''; $items = [int]$st.ItemCount } catch {}
    # $add records a right for a person; $resolve turns a trustee name into Guid / display name / address (falls back to the typed text).
    $who = @{}   # person -> rights
    $add = { param($key, $name, $email, $right, $extra)
        if (-not $who[$key]) { $who[$key] = [ordered]@{ user = $email; name = $name; fullAccess = $false; sendAs = $false; sendOnBehalf = $false; autoMap = $null } }
        $who[$key][$right] = $true; if ($extra) { foreach ($k in $extra.Keys) { $who[$key][$k] = $extra[$k] } } }
    $resolve = { param($t) try { $r = @(Invoke-Exo { Get-Recipient -Identity "$t" -ErrorAction Stop })[0]; @("$($r.Guid)", "$($r.DisplayName)", "$($r.PrimarySmtpAddress)") } catch { @("$t", "$t", "$t") } }
    # Full Access: skip inherited, denied and system entries.
    foreach ($p in @(Invoke-Exo { Get-MailboxPermission -Identity "$($mb.Guid)" -ErrorAction Stop })) {
        if ($p.IsInherited -or $p.Deny -or ("$($p.AccessRights)" -notmatch 'FullAccess') -or (Test-SystemTrustee "$($p.User)")) { continue }
        $r = & $resolve $p.User; & $add $r[0] $r[1] $r[2] 'fullAccess' $null
    }
    # Send As.
    foreach ($p in @(Invoke-Exo { Get-RecipientPermission -Identity "$($mb.Guid)" -ErrorAction Stop })) {
        if ($p.IsInherited -or ("$($p.AccessRights)" -notmatch 'SendAs') -or (Test-SystemTrustee "$($p.Trustee)")) { continue }
        $r = & $resolve $p.Trustee; & $add $r[0] $r[1] $r[2] 'sendAs' $null
    }
    # Send on behalf (stored on the mailbox itself).
    foreach ($t in @($mb.GrantSendOnBehalfTo)) { if ("$t") { $r = & $resolve $t; & $add $r[0] $r[1] $r[2] 'sendOnBehalf' $null } }
    [ordered]@{
        id = "$($mb.Guid)"; name = "$($mb.DisplayName)"; email = "$($mb.PrimarySmtpAddress)"; upn = "$($mb.UserPrincipalName)"; entraId = "$($mb.ExternalDirectoryObjectId)"
        type = "$($mb.RecipientTypeDetails)"; size = $size; sizeBytes = $bytes; items = $items
        archive = "$($mb.ArchiveStatus)"; litigationHold = [bool]$mb.LitigationHoldEnabled; forwarding = "$(if ($mb.ForwardingSmtpAddress) { $mb.ForwardingSmtpAddress } elseif ($mb.ForwardingAddress) { $mb.ForwardingAddress })"
        hidden = [bool]$mb.HiddenFromAddressListsEnabled
        access = @($who.Values | Sort-Object { $_.name })
    }
}
# Runs a Shared mailbox job (MbxInfo = read only; MbxChange = also change). $job = the job file, $id = job id, $logDir = log folder.
# Each action is recorded as a 'step' (what, target, ok, message). Order for MbxChange: 1 convert, 2 give access, 3 remove access, then re-read.
# Writes Result_<id>.json (read by /api/mbx-result) and Results_<id>.csv. Returns the number of failed steps.
function Invoke-MbxJob($job, $id, $logDir) {
    $res = [ordered]@{ ok = $false; action = "$($job.Action)"; steps = @(); info = $null; error = '' }
    $steps = New-Object System.Collections.ArrayList
    # Helper: record one step and write it to the log (green OK / red FAIL).
    $step = { param($what, $target, $ok, $msg) [void]$steps.Add([ordered]@{ step = $what; target = $target; ok = $ok; message = $msg })
        Write-Log ("  {0} {1} {2}{3}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $what, $target, $(if ($msg) { " - $msg" } else { '' })) $(if ($ok) { 'Green' } else { 'Red' }) }
    try {
        Write-Log "Mailbox: $($job.Mailbox)" 'White'
        $info = Get-MbxInfo "$($job.Mailbox)"
        Write-Log "  $($info.name) <$($info.email)> - $($info.type), $($info.size), $(@($info.access).Count) person(s) with access"
        if ($job.Action -eq 'MbxChange') {
            $mb = $info.id
            # Skip the change if the mailbox is already of the wanted type. Set-Mailbox -Type Shared / Regular does the conversion.
            # 1. convert
            if ($job.Convert -eq 'Shared') {
                if ($info.type -eq 'SharedMailbox') { & $step 'Convert to shared mailbox' $info.email $true 'Already a shared mailbox' }
                else { try { Invoke-Exo { Set-Mailbox -Identity $mb -Type Shared -ErrorAction Stop } | Out-Null; & $step 'Convert to shared mailbox' $info.email $true '' } catch { & $step 'Convert to shared mailbox' $info.email $false $_.Exception.Message } }
            } elseif ($job.Convert -eq 'Regular') {
                if ($info.type -eq 'UserMailbox') { & $step 'Convert to user mailbox' $info.email $true 'Already a user mailbox' }
                else { try { Invoke-Exo { Set-Mailbox -Identity $mb -Type Regular -ErrorAction Stop } | Out-Null; & $step 'Convert to user mailbox' $info.email $true 'The account needs an Exchange Online license' } catch { & $step 'Convert to user mailbox' $info.email $false $_.Exception.Message } }
            }
            # Current rights by address, so 'Already had it' can be reported instead of adding twice.
            $cur = @{}; foreach ($a in @($info.access)) { $cur["$($a.user)".ToLower()] = $a }
            # For each person: Full Access (optionally with auto-mapping in Outlook), Send As (Add-RecipientPermission), Send on behalf (Set-Mailbox -GrantSendOnBehalfTo).
            # 2. give access
            foreach ($g in @($job.Grant)) {
                try { $p = Get-Person "$($g.user)" } catch { & $step 'Give access' "$($g.user)" $false "Person not found: $($_.Exception.Message)"; continue }
                if ($p.Email -ieq $info.email) { & $step 'Give access' $p.Email $false 'That is the mailbox itself'; continue }
                $have = $cur[$p.Email.ToLower()]
                if ($g.fullAccess) {
                    if ($have -and $have.fullAccess) { & $step 'Full Access' $p.Email $true 'Already had it' }
                    else { try { Invoke-Exo { Add-MailboxPermission -Identity $mb -User $p.Key -AccessRights FullAccess -InheritanceType All -AutoMapping ([bool]$g.autoMap) -Confirm:$false -ErrorAction Stop } | Out-Null
                            & $step 'Full Access' $p.Email $true $(if ($g.autoMap) { 'appears in their Outlook by itself' } else { 'no auto-mapping - they add it in Outlook' }) } catch { & $step 'Full Access' $p.Email $false $_.Exception.Message } }
                }
                if ($g.sendAs) {
                    if ($have -and $have.sendAs) { & $step 'Send As' $p.Email $true 'Already had it' }
                    else { try { Invoke-Exo { Add-RecipientPermission -Identity $mb -Trustee $p.Key -AccessRights SendAs -Confirm:$false -ErrorAction Stop } | Out-Null; & $step 'Send As' $p.Email $true '' } catch { & $step 'Send As' $p.Email $false $_.Exception.Message } }
                }
                if ($g.sendOnBehalf) {
                    if ($have -and $have.sendOnBehalf) { & $step 'Send on behalf' $p.Email $true 'Already had it' }
                    else { try { Invoke-Exo { Set-Mailbox -Identity $mb -GrantSendOnBehalfTo @{ Add = $p.Key } -ErrorAction Stop } | Out-Null; & $step 'Send on behalf' $p.Email $true '' } catch { & $step 'Send on behalf' $p.Email $false $_.Exception.Message } }
                }
            }
            # Only the rights that were ticked are removed. Nothing else is deleted.
            # 3. take access away (only what was ticked)
            foreach ($r in @($job.Remove)) {
                $u = "$($r.user)"
                if ($r.fullAccess) { try { Invoke-Exo { Remove-MailboxPermission -Identity $mb -User $u -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop } | Out-Null; & $step 'Remove Full Access' $u $true '' } catch { & $step 'Remove Full Access' $u $false $_.Exception.Message } }
                if ($r.sendAs) { try { Invoke-Exo { Remove-RecipientPermission -Identity $mb -Trustee $u -AccessRights SendAs -Confirm:$false -ErrorAction Stop } | Out-Null; & $step 'Remove Send As' $u $true '' } catch { & $step 'Remove Send As' $u $false $_.Exception.Message } }
                if ($r.sendOnBehalf) { try { Invoke-Exo { Set-Mailbox -Identity $mb -GrantSendOnBehalfTo @{ Remove = $u } -ErrorAction Stop } | Out-Null; & $step 'Remove Send on behalf' $u $true '' } catch { & $step 'Remove Send on behalf' $u $false $_.Exception.Message } }
            }
            Write-Log 'Reading the mailbox again...'
            try { $info = Get-MbxInfo "$($info.id)" } catch {}
        }
        $res.info = $info; $res.ok = -not @($steps | Where-Object { -not $_.ok }).Count
    } catch { $res.error = $_.Exception.Message; Write-Log "FAILED: $($res.error)" 'Red' }
    $res.steps = @($steps)
    ($res | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $logDir "Result_$id.json") -Encoding UTF8
    if ($steps.Count) { @($steps | ForEach-Object { [pscustomobject]$_ }) | Export-Csv -Path (Join-Path $logDir "Results_$id.csv") -NoTypeInformation -Encoding UTF8 }
    Write-Log "Run finished: $(if ($res.error) { 'failed' } else { "$(@($steps | Where-Object { $_.ok }).Count) done, $(@($steps | Where-Object { -not $_.ok }).Count) failed" })." 'White'
    $script:LogFile = $null
    @($steps | Where-Object { -not $_.ok }).Count + $(if ($res.error) { 1 } else { 0 })
}


# Runs an 'MbxHide' job: for each recipient, hide or show it in the address book. Uses the right Set- command for the recipient type.
# Recipients that are synced from on-premises AD cannot be changed here (the change must be made in AD). Returns the number of failed steps.
# v1.98.27: Address list screen - hide / show cloud mailboxes in the address book (Global Address List) of Exchange Online
function Invoke-MbxHideJob($job, $id, $logDir) {
    $res = [ordered]@{ ok = $false; action = 'MbxHide'; steps = @(); info = $null; error = '' }
    $steps = New-Object System.Collections.ArrayList; $hide = [bool]$job.Hide
    try {
        foreach ($m in @($job.Mailboxes)) {
            $m = "$m"; if (-not $m) { continue }
            $what = $(if ($hide) { 'Hide from address list' } else { 'Show in address list' })
            try {
                $r = @(Invoke-Exo { Get-Recipient -Identity $m -ErrorAction Stop })[0]
                $t = "$($r.RecipientTypeDetails)"
                # Nothing to do when it already has the wanted value; synced objects are refused; then Set-Mailbox / Set-MailUser / Set-MailContact by type.
                if ([bool]$r.HiddenFromAddressListsEnabled -eq $hide) { [void]$steps.Add([ordered]@{ step = $what; target = "$($r.PrimarySmtpAddress)"; ok = $true; message = $(if ($hide) { 'Already hidden' } else { 'Already shown' }) }); continue }
                if ($r.IsDirSynced) { throw 'This mailbox is synced from on-premises AD - Exchange Online cannot change it. Use "On-premises AD" on this screen (it sets msExchHideFromAddressLists, then Entra Connect syncs it).' }
                if ($t -like '*Mailbox') { Invoke-Exo { Set-Mailbox -Identity "$($r.Guid)" -HiddenFromAddressListsEnabled $hide -ErrorAction Stop } | Out-Null }
                elseif ($t -like 'MailUser*' -or $t -like 'GuestMailUser*') { Invoke-Exo { Set-MailUser -Identity "$($r.Guid)" -HiddenFromAddressListsEnabled $hide -ErrorAction Stop } | Out-Null }
                elseif ($t -like 'MailContact*') { Invoke-Exo { Set-MailContact -Identity "$($r.Guid)" -HiddenFromAddressListsEnabled $hide -ErrorAction Stop } | Out-Null }
                else { throw "This recipient type ($t) is not changed here." }
                [void]$steps.Add([ordered]@{ step = $what; target = "$($r.PrimarySmtpAddress)"; ok = $true; message = "Done ($t). The address book updates within a few hours (Outlook offline address book up to 24 h)." })
                Write-Log "  OK   $what $($r.PrimarySmtpAddress)" 'Green'
            } catch { [void]$steps.Add([ordered]@{ step = $what; target = $m; ok = $false; message = $_.Exception.Message }); Write-Log "  FAIL $what $m - $($_.Exception.Message)" 'Red' }
        }
        $res.ok = -not @($steps | Where-Object { -not $_.ok }).Count
    } catch { $res.error = $_.Exception.Message }
    $res.steps = @($steps)
    ($res | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $logDir "Result_$id.json") -Encoding UTF8
    $script:LogFile = $null
    @($steps | Where-Object { -not $_.ok }).Count
}
# Runs one job file. Reads it, creates the log file and dispatches by Action: Shared mailbox / Address list jobs are handled by their own
# functions; Add, Remove and Export are handled below. Returns the number of problems (used for the final message).
function Invoke-Job($jobPath) {
    $job = Get-Content -Path $jobPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $id = [IO.Path]::GetFileNameWithoutExtension($jobPath) -replace '^job_', ''
    $logDir = "$($job.LogFolder)"; if (-not $logDir) { $logDir = Join-Path (Split-Path $jobPath) "Logs_$id" }
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $script:LogFile = Join-Path $logDir "FullRunLog_$id.log"
    $results = New-Object System.Collections.ArrayList
    # $max = most members per group (0 = no limit). $added remembers who was added in THIS run, for the final report. $touched = groups changed.
    $max = 0; if ($job.MaxMembersPerGroup) { $max = [int]$job.MaxMembersPerGroup }
    $added = @{}   # group identity -> set of member keys added in this run (for the final report)
    $touched = @()
    Write-Log "===== Run $id - $($job.Action) =====" 'White'
    Write-Log "Signed in as $($script:Who). Log folder: $logDir"
    if ("$($job.Action)" -in 'MbxInfo', 'MbxChange') { return (Invoke-MbxJob $job $id $logDir) }   # Shared mailbox screen
    if ("$($job.Action)" -eq 'MbxHide') { return (Invoke-MbxHideJob $job $id $logDir) }   # Address list screen

    # ADD: 'All' = every user into every group. 'Fill' = fill the first group up to the maximum, then the next one, and so on.
    if ($job.Action -in 'Add', 'Both') {
        $mode = "$($job.SpreadMode)"; if ($mode -ne 'Fill') { $mode = 'All' }
        Write-Log ("ADD - " + $(if ($mode -eq 'Fill') { "fill the groups in order, max $max per group (overflow to the next group)" } elseif ($max) { "every user into every group, max $max per group" } else { 'every user into every group, no limit' })) 'White'
        $groups = @(Resolve-Groups $job.AddGroupIdentities $results 'Add')
        $people = @(Resolve-People (Read-Users $job.AddUsersCsvPath) $results 'Add')
        Write-Log "$($people.Count) user(s) found, $($groups.Count) group(s) found."
        # Read the current members of each group first (so existing members are skipped) and count them against the maximum.
        $mem = @{}; $cnt = @{}
        foreach ($g in $groups) {
            $m = @(Get-DgMembers $g); $mem[$g.Identity] = @{}; foreach ($x in $m) { $mem[$g.Identity][$x.Key] = 1 }
            $cnt[$g.Identity] = $m.Count; $added[$g.Identity] = @{}; $touched += $g
            Write-Log ("  {0}: {1} member(s) now{2}" -f $g.Name, $m.Count, $(if ($max) { ", room for $([math]::Max(0, $max - $m.Count))" } else { '' }))
        }
        $overflow = @()
        # Helper: add one person to one group and record the outcome (Added / Failed) in $results and in the log.
        $addOne = {
            param($g, $p)
            try { Invoke-Member 'Add' $g $p; $mem[$g.Identity][$p.Key] = 1; $cnt[$g.Identity]++; $added[$g.Identity][$p.Key] = 1
                Write-Log "  Added $($p.Email) to $($g.Name)" 'Green'
                [void]$results.Add([pscustomobject]@{ Action = 'Add'; Group = $g.Name; GroupEmail = $g.Email; User = $p.Name; UserEmail = $p.Email; Result = 'Added'; Details = '' }) }
            catch { Write-Log "  FAILED to add $($p.Email) to $($g.Name): $($_.Exception.Message)" 'Red'
                [void]$results.Add([pscustomobject]@{ Action = 'Add'; Group = $g.Name; GroupEmail = $g.Email; User = $p.Name; UserEmail = $p.Email; Result = 'Failed'; Details = $_.Exception.Message }) }
        }
        # Fill mode: for every user take the first group that still has room. Users who fit nowhere go to the overflow list.
        if ($mode -eq 'Fill' -and $groups.Count) {
            foreach ($p in $people) {
                if (Test-Stop) { Write-Log 'Stop requested - the rest of the users were not added.' 'DarkYellow'; break }
                $in = @($groups | Where-Object { $mem[$_.Identity][$p.Key] })
                if ($in.Count) { [void]$results.Add([pscustomobject]@{ Action = 'Add'; Group = $in[0].Name; GroupEmail = $in[0].Email; User = $p.Name; UserEmail = $p.Email; Result = 'Already a member'; Details = '' }); Write-Log "  $($p.Email) is already in $($in[0].Name)"; continue }
                $g = @($groups | Where-Object { -not $max -or $cnt[$_.Identity] -lt $max } | Select-Object -First 1)
                if (-not $g.Count) { $overflow += $p; [void]$results.Add([pscustomobject]@{ Action = 'Add'; Group = ''; GroupEmail = ''; User = $p.Name; UserEmail = $p.Email; Result = 'No room'; Details = "Every group has $max members - add another group and run the overflow file again" }); continue }
                & $addOne $g[0] $p
            }
        } else {
            foreach ($g in $groups) {
                foreach ($p in $people) {
                    if (Test-Stop) { break }
                    if ($mem[$g.Identity][$p.Key]) { [void]$results.Add([pscustomobject]@{ Action = 'Add'; Group = $g.Name; GroupEmail = $g.Email; User = $p.Name; UserEmail = $p.Email; Result = 'Already a member'; Details = '' }); continue }
                    if ($max -and $cnt[$g.Identity] -ge $max) { $overflow += $p; [void]$results.Add([pscustomobject]@{ Action = 'Add'; Group = $g.Name; GroupEmail = $g.Email; User = $p.Name; UserEmail = $p.Email; Result = 'Group full'; Details = "The group already has $max members" }); continue }
                    & $addOne $g $p
                }
            }
        }
        # Users who did not fit are saved in Overflow_<id>.csv so they can be loaded again with another group.
        if ($overflow.Count) {
            $of = Join-Path $logDir "Overflow_$id.csv"
            $seenO = @{}; @($overflow | Where-Object { -not $seenO[$_.Key] } | ForEach-Object { $seenO[$_.Key] = 1; [pscustomobject]@{ Email = $_.Email; Name = $_.Name } }) | Export-Csv -Path $of -NoTypeInformation -Encoding UTF8
            Write-Log "$($seenO.Count) user(s) did not fit (limit $max per group) - saved in Overflow_$id.csv. Load it as 'Users to add' with another group." 'DarkYellow'
        }
    }

    # REMOVE: for each group read its members once, then remove each listed person who is really a member.
    if ($job.Action -in 'Remove', 'Both') {
        Write-Log 'REMOVE' 'White'
        $groups = @(Resolve-Groups $job.RemoveGroupIdentities $results 'Remove')
        $people = @(Resolve-People (Read-Users $job.RemoveUsersCsvPath) $results 'Remove')
        foreach ($g in $groups) {
            if (Test-Stop) { break }
            $mm = @{}; foreach ($x in @(Get-DgMembers $g)) { $mm[$x.Key] = 1 }
            if (-not ($touched | Where-Object { $_.Identity -eq $g.Identity })) { $touched += $g; $added[$g.Identity] = @{} }
            foreach ($p in $people) {
                if (Test-Stop) { break }
                if (-not $mm[$p.Key]) { [void]$results.Add([pscustomobject]@{ Action = 'Remove'; Group = $g.Name; GroupEmail = $g.Email; User = $p.Name; UserEmail = $p.Email; Result = 'Not a member'; Details = '' }); continue }
                try { Invoke-Member 'Remove' $g $p; Write-Log "  Removed $($p.Email) from $($g.Name)" 'Green'
                    [void]$results.Add([pscustomobject]@{ Action = 'Remove'; Group = $g.Name; GroupEmail = $g.Email; User = $p.Name; UserEmail = $p.Email; Result = 'Removed'; Details = '' }) }
                catch { Write-Log "  FAILED to remove $($p.Email) from $($g.Name): $($_.Exception.Message)" 'Red'
                    [void]$results.Add([pscustomobject]@{ Action = 'Remove'; Group = $g.Name; GroupEmail = $g.Email; User = $p.Name; UserEmail = $p.Email; Result = 'Failed'; Details = $_.Exception.Message }) }
            }
        }
    }

    # EXPORT: write the members of the groups. 'PerGroup' = one CSV per group (plus the combined file); otherwise one combined CSV.
    if ($job.Action -eq 'Export') {
        $per = ("$($job.ExportMode)" -eq 'PerGroup')
        Write-Log ("EXPORT - " + $(if ($per) { 'one CSV per group' } else { 'one combined CSV' })) 'White'
        $groups = @(Resolve-Groups $job.ExportGroupIdentities $results 'Export')
        $all = New-Object System.Collections.ArrayList
        if ($per) { $pd = Join-Path $logDir 'PerGroup'; New-Item -ItemType Directory -Force $pd | Out-Null }
        foreach ($g in $groups) {
            if (Test-Stop) { break }
            $m = @(Get-DgMembers $g)
            $rows = @($m | ForEach-Object { [pscustomobject]@{ Group = $g.Name; GroupEmail = $g.Email; MemberName = $_.Name; MemberEmail = $_.Email; MemberType = $_.Type } })
            Write-Log "  $($g.Name): $($m.Count) member(s)" 'Green'
            if ($per) { $rows | Export-Csv -Path (Join-Path $pd ((Get-SafeName $g.Name) + '.csv')) -NoTypeInformation -Encoding UTF8 }
            foreach ($r in $rows) { [void]$all.Add($r) }
            [void]$results.Add([pscustomobject]@{ Action = 'Export'; Group = $g.Name; GroupEmail = $g.Email; User = ''; UserEmail = ''; Result = 'Exported'; Details = "$($m.Count) member(s)" })
        }
        if (-not $per) { $all | Export-Csv -Path (Join-Path $logDir "AllGroupsMembers_$id.csv") -NoTypeInformation -Encoding UTF8; Write-Log "Saved AllGroupsMembers_$id.csv ($($all.Count) rows)." 'Green' }
        else { $all | Export-Csv -Path (Join-Path $logDir "AllGroupsMembers_$id.csv") -NoTypeInformation -Encoding UTF8; Write-Log "Saved one CSV per group in PerGroup, plus AllGroupsMembers_$id.csv with everything." 'Green' }
    }

    # Writes FinalGroupMembership_<id>.csv (everyone in the changed groups, marking who was added in this run). Skipped if a stop was requested.
    # Final membership of every group this run changed: who is in it now, and who was added in this run
    if ($touched.Count -and -not (Test-Stop)) {
        Write-Log 'Reading the final membership of the groups...'
        $fin = New-Object System.Collections.ArrayList
        foreach ($g in $touched) {
            foreach ($x in @(Get-DgMembers $g)) { [void]$fin.Add([pscustomobject]@{ Group = $g.Name; GroupEmail = $g.Email; MemberName = $x.Name; MemberEmail = $x.Email; MemberType = $x.Type; AddedThisRun = $(if ($added[$g.Identity][$x.Key]) { 'Yes' } else { 'No - already a member' }) }) }
            Write-Log "  $($g.Name): $(@($fin | Where-Object { $_.GroupEmail -eq $g.Email }).Count) member(s) now"
        }
        $fin | Export-Csv -Path (Join-Path $logDir "FinalGroupMembership_$id.csv") -NoTypeInformation -Encoding UTF8
    }
    # Results file with one row per action, and the summary line (counts per result).
    $results | Export-Csv -Path (Join-Path $logDir "Results_$id.csv") -NoTypeInformation -Encoding UTF8
    $sum = ($results | Group-Object Result | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    Write-Log "Run finished: $(if ($sum) { $sum } else { 'nothing to do' })." 'White'
    # Return the number of failures to the main loop.
    $failed = @($results | Where-Object { $_.Result -in 'Failed', 'Group not found' }).Count
    $script:LogFile = $null
    $failed
}

# Test hook: with this environment variable set, the file only defines the functions and stops here.
if ($env:DGWORKER_TEST) { return }   # lets a test load the functions above without signing in

# MAIN: sign in to Exchange Online once, then loop and run the job files until stop.signal appears.
# ---------------- main ----------------
$Host.UI.RawUI.WindowTitle = 'Admin Console - Exchange Online worker (close = sign out)'
Write-Host 'Admin Console - Exchange Online worker' -ForegroundColor Cyan
Write-Host 'Leave this window open. Use Sign out on the Distribution groups screen to close it.' -ForegroundColor DarkGray
if (Test-Path $StopSig) { Remove-Item $StopSig -Force -ErrorAction SilentlyContinue }
Set-Beat 'Starting' -Force
$ErrFile = Join-Path $JobsRoot 'worker-errors.txt'
# Appends a sign-in / run error (with the script line and versions) to worker-errors.txt, which the Admin Console shows on screen.
function Write-WorkerErr([string]$what, $err) {   # the Admin Console shows this file on the screen when the connection fails
    try { ("{0:yyyy-MM-dd HH:mm:ss}  {1}: {2}" -f (Get-Date), $what, $err.Exception.Message) | Add-Content -Path $ErrFile -Encoding UTF8
          if ($err.InvocationInfo) { "    at line $($err.InvocationInfo.ScriptLineNumber): $($err.InvocationInfo.Line.Trim())" | Add-Content -Path $ErrFile -Encoding UTF8 }
          "    PowerShell $($PSVersionTable.PSVersion), ExchangeOnlineManagement $(@(Get-Module ExchangeOnlineManagement -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version)" | Add-Content -Path $ErrFile -Encoding UTF8 } catch {}
}
try {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) { throw 'The ExchangeOnlineManagement module is not installed - use Install it on the Distribution groups screen.' }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Set-Beat 'Signing in' -Force
    Write-Host 'Signing in to Exchange Online - a Microsoft sign-in window opens (it can be behind other windows)...' -ForegroundColor Yellow
    Write-Host ("PowerShell {0}, ExchangeOnlineManagement {1}" -f $PSVersionTable.PSVersion, (Get-Module ExchangeOnlineManagement).Version) -ForegroundColor DarkGray
    $cp = @{ ShowBanner = $false; ErrorAction = 'Stop' }
    # Sign-in method 1: the admin's own portal sign-in (access token from the token file). No window, works for other PCs.
    if ($TokenFile) {
        if (-not (Get-Command Connect-ExchangeOnline).Parameters.ContainsKey('AccessToken')) { throw 'Update the ExchangeOnlineManagement module (3.1 or newer is needed to sign in with the portal sign-in) - Install it / update on the Distribution groups screen.' }
        $script:Who = Connect-ExoToken
        Set-Beat "Connected as $($script:Who)" -Force
        Write-Host "Connected as $($script:Who) (portal sign-in). Waiting for runs..." -ForegroundColor Green
    } else {
    # Sign-in method 2: app + certificate (no user). Method 3: the admin's UPN with an interactive sign-in.
    if ($AppId) { $cp.AppId = $AppId; $cp.CertificateThumbprint = $CertificateThumbprint; $cp.Organization = $Organization }
    elseif ($AdminUPN) { $cp.UserPrincipalName = $AdminUPN }
    # (Why the browser sign-in is used: see the explanation in the existing comment below.)
    # This worker runs with NO visible window. The Windows sign-in broker (WAM, the default since ExchangeOnlineManagement 3.7)
    # needs a visible parent window, so from here it can fail or never show. Signing in through the web browser has no such need:
    # a Microsoft sign-in page opens in your default browser (or signs in by itself if you are already signed in there).
    $exo = @(Get-Module ExchangeOnlineManagement)[0]
    $canNoWam = (Get-Command Connect-ExchangeOnline).Parameters.ContainsKey('DisableWAM')
    # DisableWAM makes the module sign in through the web browser. Module 3.7+ without that switch cannot work in the background, so stop with advice.
    if (-not $AppId -and $canNoWam) { $cp.DisableWAM = $true; Set-Beat 'Signing in (web browser)' -Force }
    elseif (-not $AppId -and $exo -and $exo.Version -ge [version]'3.7.0') {
        throw "ExchangeOnlineManagement $($exo.Version) signs in through a window that cannot be shown in the background. Update the module: press Install it / update on the Distribution groups screen (3.7.2 or newer signs in through the web browser)."
    }
    Connect-ExchangeOnline @cp
    $ci = @(Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' }) | Select-Object -First 1
    $script:Who = if ($AppId) { "app:$AppId" } elseif ($ci -and $ci.UserPrincipalName) { "$($ci.UserPrincipalName)" } else { $AdminUPN }
    # Safety: the Exchange sign-in must be the same person as the Admin Console sign-in, otherwise disconnect and report an error.
    if ($AdminUPN -and -not $AppId -and $script:Who -and $script:Who -ine $AdminUPN) {   # signed in with another account in the Microsoft window
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        throw "Exchange Online was signed in as $($script:Who), but the Admin Console is signed in as $AdminUPN. Use the same account."
    }
    Set-Beat "Connected as $($script:Who)" -Force
    Write-Host "Connected as $($script:Who). Waiting for runs..." -ForegroundColor Green
    }
} catch {
    # Sign-in failed: store the error for the screen and set the status to 'Error: ...' (| and line breaks removed because | separates heartbeat fields).
    # In a visible window wait so the text can be read, otherwise wait 20 s and exit.
    Write-WorkerErr 'Exchange Online sign-in failed' $_
    Set-Beat ("Error: " + ($_.Exception.Message -replace '[\r\n|]+', ' ')) -Force
    Write-Host "Could not sign in: $($_.Exception.Message)" -ForegroundColor Red
    if ($Visible) {
        Write-Host ''; Write-Host 'The details are also shown in the Admin Console. Fix the problem, then press Try again there.' -ForegroundColor Yellow
        try { Read-Host 'Press Enter to close this window' | Out-Null } catch { Start-Sleep -Seconds 600 }
    } else { Start-Sleep -Seconds 20 }
    exit 1
}
# MAIN LOOP: about every 0.8 s look for the oldest job file in Pending and run it; otherwise keep the heartbeat alive.
$lastCheck = Get-Date
while ($true) {
    if (Test-Stop) { break }
    $next = @(Get-ChildItem -Path $Pending -Filter 'job_*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1)
    if ($next.Count) {
        # Renew the sign-in before a run if the token is older than 40 minutes; if that fails, stop the worker with an error status.
        # v2.0.0: an access token lasts about an hour - sign in again with a fresh one before a run when it is older than 40 minutes
        if ($TokenFile -and ((Get-Date) - $script:TokAt).TotalMinutes -ge 40) {
            try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; [void](Connect-ExoToken) }
            catch { Write-WorkerErr 'Exchange Online sign-in could not be renewed' $_; Set-Beat ('Error: ' + ($_.Exception.Message -replace '[\r\n|]+', ' ')) -Force; break }
        }
        # Move the job to Running first so it is never started twice, run it, then move it to Done (or Failed on an error).
        $runPath = Join-Path $RunDir $next[0].Name
        Move-Item -Path $next[0].FullName -Destination $runPath -Force
        Set-Beat "Connected as $($script:Who) - running a job" -Force
        try { $f = Invoke-Job $runPath; Move-Item $runPath (Join-Path $DoneDir (Split-Path $runPath -Leaf)) -Force; if ($f) { Write-Host "Run finished with $f problem(s) - see the log." -ForegroundColor DarkYellow } }
        catch {
            Write-Log "RUN FAILED: $($_.Exception.Message)" 'Red'; $script:LogFile = $null
            Write-WorkerErr "Run $($next[0].Name) failed" $_
            Move-Item $runPath (Join-Path $FailDir (Split-Path $runPath -Leaf)) -Force -ErrorAction SilentlyContinue
        }
        Set-Beat "Connected as $($script:Who)" -Force
        continue
    }
    # Every 10 minutes check that the Exchange Online session is still connected; if not, set an Error status.
    if (((Get-Date) - $lastCheck).TotalMinutes -ge 10) {   # is the Exchange Online session still alive?
        $lastCheck = Get-Date
        if (-not @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' }).Count) { Set-Beat 'Error: the Exchange Online session ended - sign in again' -Force; break }
    }
    Set-Beat; Start-Sleep -Milliseconds 800
}
# CLEAN UP after stop.signal: disconnect, delete the token file (it holds the sign-in) and the stop signal, and report 'Stopped'.
try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
if ($TokenFile -and (Test-Path $TokenFile)) { Remove-Item $TokenFile -Force -ErrorAction SilentlyContinue }
if (Test-Path $StopSig) { Remove-Item $StopSig -Force -ErrorAction SilentlyContinue }
if ($script:Status -notmatch '^Error') { Set-Beat 'Stopped' -Force }
Write-Host 'Signed out. This window closes now.' -ForegroundColor Cyan
Start-Sleep -Seconds 2

# Screen-Intune.ps1 - back end for the Devices (Intune) screen, and the background jobs used by the Intune and OneDrive screens.
# Screen: Devices (Intune)
# Screen version: 2.5.5   (changes ONLY when this screen changes - not with every release)
# Loaded by server.ps1 at start-up; do not run it on its own.
#
# Devices (Intune) - read only: every Intune managed device with its user, operating system, serial number, enrolment and last
# check-in, compliance, and how it is joined (Hybrid AD joined, Microsoft Entra joined, registered) from Microsoft Entra.
# Needs the Microsoft Graph permissions DeviceManagementManagedDevices.Read.All and Device.Read.All (sign out of Microsoft
# and connect again once, to approve them).
#
# Background jobs: a long read (thousands of devices, a tenant storage report, deleting many OneDrives) runs in its own
# PowerShell thread with the person's OWN access token, so the portal stays free for everybody else. The page asks for the state
# every second (/api/gjob). Only the session that started a job can read or stop it.

# ENDPOINTS: POST /api/intune-run (start reading devices), POST /api/intune-action (delete / retire devices), POST /api/gjob (ask the state of a
# job, request field id), POST /api/gjob-cancel (stop a job, field id). Intune read/delete use Microsoft Graph v1.0 /deviceManagement/managedDevices
# and /devices; the OneDrive screen reuses Start-GJob and the job prelude below. A delete audit CSV is written to the Logs folder.
# Permission: any signed-in Microsoft user for reading; removing devices needs the portal permission 'Remove devices' plus the Graph rights below.
#
# $global:GJobs = all running / finished jobs in memory, key = job id (a GUID without dashes). Lost when the server restarts.
$global:GJobs = @{}
# functions every job can use (Invoke-RestMethod with the job's own token - never the shared Graph connection)
# The text below (up to the closing '@) is NOT run here. It is pasted in front of every job script and runs inside the job's own thread.
# It gives the job three helpers: Invoke-G (call Microsoft Graph with the job's token, with retries when Microsoft says 'busy' - 429/503/504,
# waiting for the Retry-After time, max 8 tries), Get-GAll (follow @odata.nextLink paging and collect all rows) and Invoke-Spo (call the SharePoint
# admin REST API with the SharePoint token). $p is the argument hashtable given to the job (Token, Spo, Admin, Sync ...); $p.Sync is the shared
# progress object the page reads (step text, done / total counters, cancel flag). Comments cannot go inside this text without changing it.
$global:GJobPrelude = @'
function Invoke-G([string]$uri, [string]$method = 'GET', $body = $null) {
    if ($uri -notmatch '^https://') { $uri = 'https://graph.microsoft.com/' + $uri.TrimStart('/') }
    $h = @{ Authorization = "Bearer $($p.Token)"; ConsistencyLevel = 'eventual' }
    for ($try = 1; ; $try++) {
        try {
            if ($null -ne $body) { return Invoke-RestMethod -Method $method -Uri $uri -Headers $h -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop }
            return Invoke-RestMethod -Method $method -Uri $uri -Headers $h -ErrorAction Stop
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            # v2.4.2: Microsoft is busy / limiting (429, 503, 504): wait as long as it asks (Retry-After), up to 8 tries
            if ($try -lt 8 -and ($code -in 429, 503, 504 -or "$($_.Exception.Message)" -match 'Throttl|TooManyRequests|retry later')) {
                $wait = 0; try { $wait = [int]"$($_.Exception.Response.Headers['Retry-After'])" } catch {}; if ($wait -le 0) { $wait = [Math]::Min(60, 5 * $try * $try) }; $wait = [Math]::Min(120, $wait)
                if ($p.Sync) { $p.Sync.step = "Microsoft is busy - waiting $wait seconds, then trying again ($try of 7)..." }
                for ($w = 0; $w -lt $wait; $w++) { if ($p.Sync -and $p.Sync.cancel) { throw 'Stopped.' }; Start-Sleep -Seconds 1 }
                continue
            }
            $m = $_.Exception.Message; try { $j = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) | ConvertFrom-Json; if ($j.error.message) { $m = "$($j.error.message)" } } catch {}
            if ($m -match '^\s*\{' ) { try { $jj = $m | ConvertFrom-Json; if ($jj.error.message) { $m = "$($jj.error.code): $($jj.error.message)" } } catch {} }
            if ($code -eq 429 -or $m -match 'Throttl|TooManyRequests|retry later') { $m = 'Microsoft is limiting requests right now (too many requests in your tenant - this often happens with usage reports). The tool waited and tried again 7 times. Wait 5-10 minutes and try again.' }
            if ($code -eq 403) { $m = "No permission ($m). Sign out of Microsoft and connect again to approve the new permissions, and check your admin role." }
            throw $m
        }
    }
}
function Get-GAll([string]$uri, [int]$max = 100000) {
    $out = New-Object Collections.Generic.List[object]
    while ($uri -and $out.Count -lt $max) {
        if ($p.Sync.cancel) { throw 'Stopped.' }
        $r = Invoke-G $uri
        foreach ($x in @($r.value)) { $out.Add($x) }
        $uri = $r.'@odata.nextLink'; $p.Sync.done = $out.Count
    }
    , $out.ToArray()
}
function Invoke-Spo([string]$path, $body = $null, [string]$method = 'POST') {
    $h = @{ Authorization = "Bearer $($p.Spo)"; Accept = 'application/json;odata=nometadata' }
    $uri = $p.Admin.TrimEnd('/') + $path
    try {
        if ($method -eq 'GET') { return Invoke-RestMethod -Method GET -Uri $uri -Headers $h -ErrorAction Stop }
        return Invoke-RestMethod -Method $method -Uri $uri -Headers $h -Body ($(if ($null -ne $body) { $body } else { @{} }) | ConvertTo-Json -Depth 5) -ContentType 'application/json;odata=nometadata' -ErrorAction Stop
    } catch {
        $m = $_.Exception.Message; try { $t = $(if ($_.ErrorDetails -and $_.ErrorDetails.Message) { "$($_.ErrorDetails.Message)" } else { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }); $j = $t | ConvertFrom-Json; if ($j.'odata.error'.message.value) { $m = "$($j.'odata.error'.message.value)" } elseif ($j.error.message) { $m = "$($j.error.message)" } elseif ($t) { $m = $t.Substring(0, [Math]::Min(300, $t.Length)) } } catch {}
        throw $m
    }
}
'@
# Starts a background job in its own PowerShell thread and returns the job id.
# $kind = short job type (decides which Complete-GJob_<kind> runs at the end), $code = job script text, $arg = hashtable given to the job as $p,
# $label = text for logs. Rules: old jobs are cleaned up (finished and older than 60 min, or any older than 12 hours); one person may run at most 3 at once.
function Start-GJob($kind, [string]$code, $arg, $label) {
    $now = Get-Date; $me = Get-SessId $script:Session
    foreach ($k in @($global:GJobs.Keys)) { $o = $global:GJobs[$k]; $age = ($now - $o.started).TotalMinutes; if (($o.handle.IsCompleted -and $age -gt 60) -or $age -gt 720) { try { [void]$o.ps.BeginStop($null, $null) } catch {}; $global:GJobs.Remove($k) } }
    if (@($global:GJobs.Values | Where-Object { $_.owner -eq $me -and -not $_.handle.IsCompleted }).Count -ge 3) { throw 'You already have 3 jobs running. Wait for one to finish or stop it.' }
    # Shared progress object (thread safe): the job writes step/done/total, the page reads them, and cancel=$true asks the job to stop.
    $sync = [hashtable]::Synchronized(@{ step = 'Starting...'; done = 0; total = 0; cancel = $false })
    $arg.Sync = $sync
    $ps = [powershell]::Create()
    # Job script = set $p, stop on errors, force TLS 1.2 (needed on old Windows PowerShell 5.1), then the helpers, then the job code.
    [void]$ps.AddScript("param(`$p)`n`$ErrorActionPreference = 'Stop'`n[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12`n$($global:GJobPrelude)`n$code").AddArgument($arg)
    $h = $ps.BeginInvoke()
    $id = [guid]::NewGuid().ToString('N')
    # Remember the job. 'owner' is the session that started it - only that session may read or stop it.
    $global:GJobs[$id] = @{ ps = $ps; handle = $h; started = $now; sync = $sync; owner = $me; kind = $kind; label = $label; user = "$($script:SessUser.name)"; arg = $arg }
    $id
}
# Handler: the page calls this every second. Request: id. Reply: state 'running' (step, done, total, secs), 'done' (result) or 'failed' (error).
$ScreenHandlers['/api/gjob'] = {
    $j = $global:GJobs["$($d.id)"]
    # Unknown job id, or the job belongs to another person: refuse.
    if (-not $j -or $j.owner -ne (Get-SessId $script:Session)) { throw 'This job is no longer available. Start it again.' }
    if (-not $j.handle.IsCompleted) { Send $ctx @{ ok = $true; state = 'running'; step = "$($j.sync.step)"; done = [int]$j.sync.done; total = [int]$j.sync.total; secs = [int]((Get-Date) - $j.started).TotalSeconds }; return }
    # The job has finished: collect its output. The last object it returned is the result and must be a hashtable.
    $res = $null; $err = ''
    try { $out = @($j.ps.EndInvoke($j.handle)); if ($out.Count) { $res = $out[$out.Count - 1] } } catch { $err = Get-ErrMsg $_ }
    if (-not $err -and $j.ps.Streams.Error.Count) { $err = "$($j.ps.Streams.Error[0])" }
    try { $j.ps.Dispose() } catch {}
    $global:GJobs.Remove("$($d.id)")
    if (-not $err -and -not ($res -is [hashtable])) { $err = 'The job returned nothing.' }
    # Optional hook: if a function Complete-GJob_<kind> exists (for example the Intune audit log below) call it once. Its errors are only printed.
    if (Get-Command "Complete-GJob_$($j.kind)" -ErrorAction SilentlyContinue) { try { & "Complete-GJob_$($j.kind)" $j $res $err } catch { Write-Host "Job log: $($_.Exception.Message)" -ForegroundColor Yellow } }
    if ($err) { Send $ctx @{ ok = $false; state = 'failed'; error = $err }; return }
    Send $ctx @{ ok = $true; state = 'done'; result = $res; secs = [int]((Get-Date) - $j.started).TotalSeconds }
}
# Handler: asks the job to stop (the job checks the cancel flag between items). Action-type jobs are also written to the activity log.
$ScreenHandlers['/api/gjob-cancel'] = {
    $j = $global:GJobs["$($d.id)"]
    if ($j -and $j.owner -eq (Get-SessId $script:Session)) { $j.sync.cancel = $true; if ($j.kind -in 'intuneact', 'oddel', 'mprun', 'licchg') { Write-ActRow 'Background job' 'Stopped by the user' $j.label 'Stopped' '' } }
    Send $ctx @{ ok = $true }
}

# The text below is the job script for reading devices (kept as a here-string; it runs inside the job thread with $p.Token and $p.Max).
# Steps: 1) read managed devices from Intune (Graph: deviceManagement/managedDevices, 999 per page, needs DeviceManagementManagedDevices.Read.All),
# 2) read Entra devices (Graph: devices, needs Device.Read.All) to learn how each device is joined, 3) match them by azureADDeviceId.
# trustType meaning: ServerAd = Hybrid AD joined, AzureAd = Entra joined, Workplace = Entra registered. An all-zero device id means 'no Entra device'.
# 'daysSince' = days since the last Intune check-in. The result is { rows, total, capped (true if the max was reached), at }.
# ---------------- Devices (Intune) ----------------
$script:IntuneWork = @'
$p.Sync.step = 'Reading the Intune devices...'
$sel = 'id,deviceName,userPrincipalName,userDisplayName,operatingSystem,osVersion,serialNumber,enrolledDateTime,lastSyncDateTime,complianceState,managementState,azureADDeviceId,azureADRegistered,manufacturer,model,managedDeviceOwnerType'
$devs = Get-GAll ("v1.0/deviceManagement/managedDevices?`$select=$sel&`$top=999") $p.Max
$p.Sync.step = "Reading Microsoft Entra devices (to see how they are joined)..."; $p.Sync.done = 0
$aad = Get-GAll ('v1.0/devices?$select=deviceId,trustType,profileType,onPremisesSyncEnabled,onPremisesLastSyncDateTime,displayName,accountEnabled&$top=999') 200000
$look = @{}; foreach ($a in $aad) { if ($a.deviceId -and -not $look.ContainsKey("$($a.deviceId)")) { $look["$($a.deviceId)"] = $a } }
$p.Sync.step = 'Putting it together...'
$fmt = { param($v) if ($v) { try { ([datetime]$v).ToString('yyyy-MM-dd HH:mm') } catch { "$v" } } else { '' } }
$rows = foreach ($x in $devs) {
    $m = if ($x.azureADDeviceId -and $x.azureADDeviceId -ne '00000000-0000-0000-0000-000000000000') { $look["$($x.azureADDeviceId)"] } else { $null }
    $tt = if ($m) { "$($m.trustType)" } else { '' }
    $join = switch ($tt) { 'ServerAd' { 'Hybrid AD joined' } 'AzureAd' { 'Microsoft Entra joined' } 'Workplace' { 'Microsoft Entra registered' } default { 'Unknown' } }
    $sync = if ($m -and $m.onPremisesSyncEnabled -eq $true) { 'Yes' } elseif ($m -and $m.onPremisesSyncEnabled -eq $false) { 'No' } else { 'Unknown' }
    $days = ''; if ($x.lastSyncDateTime) { try { $days = [int]((Get-Date) - [datetime]$x.lastSyncDateTime).TotalDays } catch {} }
    [ordered]@{ device = "$($x.deviceName)"; user = "$($x.userPrincipalName)"; userName = "$($x.userDisplayName)"; os = "$($x.operatingSystem)"; osVersion = "$($x.osVersion)"
        serial = "$($x.serialNumber)"; make = ("$($x.manufacturer) $($x.model)").Trim(); owner = "$($x.managedDeviceOwnerType)"; enrolled = (& $fmt $x.enrolledDateTime); lastSync = (& $fmt $x.lastSyncDateTime); daysSince = $days
        compliance = "$($x.complianceState)"; join = $join; synced = $sync; adLastSync = $(if ($m) { & $fmt $m.onPremisesLastSyncDateTime } else { '' }); entraEnabled = $(if ($m) { [string]$m.accountEnabled } else { '' })
        entraId = "$($x.azureADDeviceId)"; intuneId = "$($x.id)" }
}
@{ rows = @($rows); total = @($devs).Count; capped = (@($devs).Count -ge $p.Max); at = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
'@
# Handler: start the read job. Request: max (optional, number of devices to read; kept between 100 and 100000, default 50000).
# Reply: { ok, id } - the page then polls /api/gjob with that id.
$ScreenHandlers['/api/intune-run'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    # The job uses the person's OWN Graph token, so Microsoft applies their rights and the shared connection is not blocked.
    $tok = Get-SessGraphToken; if (-not $tok) { throw 'The Microsoft sign-in could not give a token. Sign out of Microsoft and connect again.' }
    $max = [Math]::Max(100, [Math]::Min(100000, [int]$(if ($d.max) { $d.max } else { 50000 })))
    $id = Start-GJob 'intune' $script:IntuneWork @{ Token = $tok; Max = $max } 'Read Intune devices'
    # v2.5.5: reading is not an action - not logged
    Send $ctx @{ ok = $true; id = $id }
}

# ---------------- v2.3.0: remove devices (Delete from Intune / Retire, and optionally the Microsoft Entra device) ----------------
# Needs DeviceManagementManagedDevices.ReadWrite.All (delete), DeviceManagementManagedDevices.PrivilegedOperations.All (retire)
# and Device.ReadWrite.All (Entra device) - sign out of Microsoft and connect again once to approve them. Permission: "Remove devices".
# Job script for removing devices (here-string, runs inside the job thread). $p.Items = devices, $p.Action = 'delete' or 'retire',
# $p.Entra = also delete the Entra device. Per device: Graph POST managedDevices/{id}/retire, or DELETE managedDevices/{id}; then, if asked and
# the delete worked, find the Entra device by deviceId and DELETE devices/{id}. A failure on one device does not stop the others.
# If the user cancels, the remaining devices are listed as 'Skipped'. Result: { rows } with one result row per device.
$script:IntuneActWork = @'
$rows = New-Object Collections.Generic.List[object]; $p.Sync.total = @($p.Items).Count; $i = 0
foreach ($it in @($p.Items)) {
    $r = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); device = "$($it.device)"; user = "$($it.user)"; action = $p.Action; intune = ''; entra = ''; message = '' }
    if ($p.Sync.cancel) { $r.intune = 'Skipped'; $r.message = 'Stopped by the user'; $rows.Add($r); continue }
    $i++; $p.Sync.done = $i - 1; $p.Sync.step = "$($p.Action): $($it.device)"
    try {
        if ($p.Action -eq 'retire') { [void](Invoke-G "v1.0/deviceManagement/managedDevices/$($it.intuneId)/retire" 'POST' @{}); $r.intune = 'Retire sent' }
        else { [void](Invoke-G "v1.0/deviceManagement/managedDevices/$($it.intuneId)" 'DELETE'); $r.intune = 'Deleted' }
    } catch { $r.intune = 'Failed'; $r.message = "Intune: $_" }
    if ($p.Entra -and $r.intune -ne 'Failed') {
        if ("$($it.entraId)" -match '^[0-9a-fA-F-]{36}$' -and "$($it.entraId)" -ne '00000000-0000-0000-0000-000000000000') {
            try {
                $dv = @((Invoke-G ("v1.0/devices?`$filter=deviceId eq '$($it.entraId)'&`$select=id,displayName")).value)
                if (-not $dv.Count) { $r.entra = 'Not found' } else { foreach ($x in $dv) { [void](Invoke-G "v1.0/devices/$($x.id)" 'DELETE') }; $r.entra = 'Deleted' }
            } catch { $r.entra = 'Failed'; $r.message = (($r.message + " Entra: $_").Trim()) }
        } else { $r.entra = 'No Entra device' }
    }
    $rows.Add($r); $p.Sync.done = $i
}
@{ rows = $rows.ToArray() }
'@
# Called by /api/gjob when the removal job ends. Writes every result row to the monthly audit CSV (Logs\device-removal-audit-yyyy-MM.csv) and to
# the activity log, so there is a record of who removed what. ConvertTo-CsvCell protects commas and quotes. SpDirty tells the app the data changed.
function Complete-GJob_intuneact($j, $res, $err) {
    $f = Join-Path $LogDir ('device-removal-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    if (-not (Test-Path $f)) { 'Time,PortalUser,MicrosoftAccount,Action,Device,User,Intune,Entra,Message' | Out-File $f -Encoding utf8 }
    foreach ($r in @($res.rows)) {
        $vals = @($r.time, $j.user, $j.arg.By, $r.action, $r.device, $r.user, $r.intune, $r.entra, $r.message) | ForEach-Object { ConvertTo-CsvCell $_ }
        ($vals -join ',') | Add-Content $f
        Write-ActRow 'Devices (Intune)' $(if ($r.action -eq 'retire') { 'Retire device' } else { 'Delete device' }) "$($r.device) ($($r.user))" "$($r.intune)$(if ($r.entra) { ' / Entra: ' + $r.entra })" $r.message
    }
    if ($err) { Write-ActRow 'Devices (Intune)' 'Remove devices' '' "Failed: $err" '' }
    $script:SpDirty = $true
}
# Handler: delete or retire the ticked devices. Request: action ('delete' or 'retire'), confirm (must be exactly DELETE, case sensitive),
# items (list of { intuneId, entraId, device, user }), entra (true = also remove the Entra device; only used for delete).
$ScreenHandlers['/api/intune-action'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $act = "$($d.action)"; if ($act -notin 'delete', 'retire') { throw 'Choose Delete or Retire.' }
    if ("$($d.confirm)" -cne 'DELETE') { throw 'Type DELETE to confirm.' }
    # Keep only items with a valid Intune id (a GUID: 36 characters of hex and dashes) and copy just the fields we need - nothing else is trusted.
    $items = @(@($d.items) | Where-Object { "$($_.intuneId)" -match '^[0-9a-fA-F-]{36}$' } | ForEach-Object { @{ intuneId = "$($_.intuneId)"; entraId = "$($_.entraId)"; device = "$($_.device)"; user = "$($_.user)" } })
    if (-not $items.Count) { throw 'Tick at least one device.' }
    if ($items.Count -gt 1000) { throw 'Up to 1000 devices at a time.' }
    $tok = Get-SessGraphToken; if (-not $tok) { throw 'The Microsoft sign-in could not give a token. Sign out of Microsoft and connect again.' }
    # Start the job, then log that it started (the end result is logged by Complete-GJob_intuneact).
    $id = Start-GJob 'intuneact' $script:IntuneActWork @{ Token = $tok; Items = $items; Action = $act; Entra = ([bool]$d.entra -and $act -eq 'delete'); By = "$($script:Who)" } "$act $($items.Count) device(s)"
    Write-ActRow 'Devices (Intune)' 'Remove devices' "$($items.Count) device(s)" 'Started' "action=$act; entra=$([bool]$d.entra)"
    Send $ctx @{ ok = $true; id = $id }
}

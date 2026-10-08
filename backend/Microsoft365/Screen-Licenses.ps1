# Screen-Licenses.ps1 - back end for the Licenses screen. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Licenses
# Screen version: 2.5.1   (changes ONLY when this screen changes - not with every release)
#
# Licenses (Microsoft 365):
#  * Every license (subscribed SKU): total bought, assigned / used, remaining - and how the people got it: directly, or from a group.
#  * Every licensed person with the way each license was given (Direct / Group name) - filter, export.
#  * Bulk: assign or remove a license directly, or add / remove people to a licensing group (group-based licensing).
#    A license that comes from a group cannot be removed directly - remove the person from that group instead (the tool says so).
# Uses the signed-in person's Microsoft sign-in (background job with their token). Needs Directory.Read.All (read) and
# LicenseAssignment.ReadWrite.All / User.ReadWrite.All + GroupMember.ReadWrite.All (changes).

# friendly names of common licenses (the rest show their part number)
# Table: Microsoft part number (SKU) -> friendly license name. Passed to the background job.
$script:LicNames = @{
    'ENTERPRISEPACK' = 'Office 365 E3'; 'ENTERPRISEPREMIUM' = 'Office 365 E5'; 'STANDARDPACK' = 'Office 365 E1'; 'SPE_E3' = 'Microsoft 365 E3'; 'SPE_E5' = 'Microsoft 365 E5'
    'SPE_F1' = 'Microsoft 365 F3'; 'DESKLESSPACK' = 'Office 365 F3'; 'O365_BUSINESS_ESSENTIALS' = 'Microsoft 365 Business Basic'; 'O365_BUSINESS_PREMIUM' = 'Microsoft 365 Business Standard'
    'SPB' = 'Microsoft 365 Business Premium'; 'EXCHANGESTANDARD' = 'Exchange Online (Plan 1)'; 'EXCHANGEENTERPRISE' = 'Exchange Online (Plan 2)'; 'EMS' = 'Enterprise Mobility + Security E3'
    'EMSPREMIUM' = 'Enterprise Mobility + Security E5'; 'AAD_PREMIUM' = 'Microsoft Entra ID P1'; 'AAD_PREMIUM_P2' = 'Microsoft Entra ID P2'; 'INTUNE_A' = 'Microsoft Intune Plan 1'
    'POWER_BI_PRO' = 'Power BI Pro'; 'POWER_BI_STANDARD' = 'Power BI (free)'; 'FLOW_FREE' = 'Power Automate (free)'; 'TEAMS_EXPLORATORY' = 'Teams Exploratory'; 'PROJECTPROFESSIONAL' = 'Project Plan 3'
    'VISIOCLIENT' = 'Visio Plan 2'; 'STANDARDWOFFPACK_FACULTY' = 'Office 365 A1 for faculty'; 'STANDARDWOFFPACK_STUDENT' = 'Office 365 A1 for students'
    'M365EDU_A3_FACULTY' = 'Microsoft 365 A3 for faculty'; 'M365EDU_A3_STUDENT' = 'Microsoft 365 A3 for students'; 'M365EDU_A5_FACULTY' = 'Microsoft 365 A5 for faculty'; 'M365EDU_A5_STUDENT' = 'Microsoft 365 A5 for students'
    'ENTERPRISEPACK_FACULTY' = 'Office 365 A3 for faculty'; 'ENTERPRISEPACK_STUDENT' = 'Office 365 A3 for students'; 'ENTERPRISEPREMIUM_FACULTY' = 'Office 365 A5 for faculty'; 'ENTERPRISEPREMIUM_STUDENT' = 'Office 365 A5 for students'
    'STANDARDWOFFPACK_IW_FACULTY' = 'Office 365 A1 Plus for faculty'; 'STANDARDWOFFPACK_IW_STUDENT' = 'Office 365 A1 Plus for students'; 'WINDOWS_STORE' = 'Windows Store for Business'
    'MCOEV' = 'Teams Phone Standard'; 'MCOMEETADV' = 'Microsoft 365 Audio Conferencing'; 'PHONESYSTEM_VIRTUALUSER' = 'Teams Phone Resource Account'; 'Microsoft_Teams_Rooms_Pro' = 'Teams Rooms Pro'
    'DEVELOPERPACK_E5' = 'Microsoft 365 E5 Developer'; 'RIGHTSMANAGEMENT_ADHOC' = 'Rights Management Adhoc'; 'STREAM' = 'Microsoft Stream'; 'POWERAPPS_VIRAL' = 'Power Apps Plan 2 Trial'
}

# ---------------- read everything (background job) ----------------
# Licenses screen - endpoints: /api/lic-read (read all licenses + licensed users), /api/lic-groups (search licensing groups),
# /api/lic-change (bulk assign/remove). Graph calls: subscribedSkus, users (licenseAssignmentStates), directoryObjects/getByIds,
# assignLicense, groups members. Data file written: license-audit-YYYY-MM.csv in $LogDir. Needs a Microsoft sign-in ($script:Who).
#
# Script text of the READ background job (text between @' and '@ runs later in the job, so no comments inside it).
# Steps: 1) read the tenant SKUs, 2) read every licensed user, 3) look up names of the licensing groups (1000 ids per call, the Graph limit),
# 4) count per SKU how many have it Direct / via Group / both / with errors, 5) return { skus, rows (one per person+license), people, at }.
$script:LicReadWork = @'
$p.Sync.step = 'Reading the licenses of the tenant...'
$skus = @((Invoke-G 'v1.0/subscribedSkus').value)
$names = $p.Names
$p.Sync.step = 'Reading every licensed person (this can take a minute in a big tenant)...'
$users = Get-GAll ('v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled,department,usageLocation,licenseAssignmentStates&$filter=assignedLicenses/$count ne 0&$count=true&$top=999') 500000
$p.Sync.step = 'Reading the names of the licensing groups...'; $p.Sync.done = 0
$gids = New-Object Collections.Generic.HashSet[string]
foreach ($u in $users) { foreach ($s in @($u.licenseAssignmentStates)) { if ($s.assignedByGroup) { [void]$gids.Add("$($s.assignedByGroup)") } } }
$gname = @{}; $all = @($gids)
for ($i = 0; $i -lt $all.Count; $i += 1000) {
    $chunk = @($all[$i..([Math]::Min($i + 999, $all.Count - 1))])
    try { foreach ($o in @((Invoke-G 'v1.0/directoryObjects/getByIds' 'POST' @{ ids = $chunk; types = @('group') }).value)) { $gname["$($o.id)"] = "$($o.displayName)" } } catch {}
}
$p.Sync.step = 'Putting it together...'
$skuName = @{}; foreach ($s in $skus) { $pn = "$($s.skuPartNumber)"; $skuName["$($s.skuId)"] = $(if ($names[$pn]) { $names[$pn] } else { $pn }) }
$cnt = @{}; foreach ($s in $skus) { $cnt["$($s.skuId)"] = @{ direct = 0; group = 0; both = 0; errors = 0; groups = @{} } }
$rows = New-Object Collections.Generic.List[object]
foreach ($u in $users) {
    $per = [ordered]@{}
    foreach ($s in @($u.licenseAssignmentStates)) {
        $k = "$($s.skuId)"; if (-not $per.Contains($k)) { $per[$k] = @{ direct = $false; groups = New-Object Collections.Generic.List[string]; gids = New-Object Collections.Generic.List[string]; err = '' } }
        if ($s.assignedByGroup) { $gn = $(if ($gname["$($s.assignedByGroup)"]) { $gname["$($s.assignedByGroup)"] } else { "$($s.assignedByGroup)" }); $per[$k].groups.Add($gn); $per[$k].gids.Add("$($s.assignedByGroup)") } else { $per[$k].direct = $true }
        if ("$($s.state)" -eq 'Error' -or "$($s.error)" -notin '', 'None') { $per[$k].err = "$($s.error)" }
    }
    foreach ($k in $per.Keys) {
        $x = $per[$k]; $c = $cnt[$k]
        if ($c) {
            if ($x.direct -and $x.groups.Count) { $c.both++ } elseif ($x.direct) { $c.direct++ } else { $c.group++ }
            if ($x.err) { $c.errors++ }
            foreach ($g in $x.groups) { if (-not $c.groups.ContainsKey($g)) { $c.groups[$g] = 0 }; $c.groups[$g]++ }
        }
        $via = $(if ($x.direct -and $x.groups.Count) { 'Direct + Group' } elseif ($x.direct) { 'Direct' } else { 'Group' })
        $rows.Add([ordered]@{ id = "$($u.id)"; upn = "$($u.userPrincipalName)"; name = "$($u.displayName)"; enabled = $(if ($u.accountEnabled) { 'Enabled' } else { 'Disabled' }); dept = "$($u.department)"; usage = "$($u.usageLocation)"
            skuId = $k; sku = $(if ($skuName[$k]) { $skuName[$k] } else { $k }); via = $via; groups = ($x.groups -join '; '); gids = ($x.gids -join ';'); error = $x.err })
    }
}
$out = foreach ($s in $skus) {
    $k = "$($s.skuId)"; $c = $cnt[$k]; $en = [int]$s.prepaidUnits.enabled
    [ordered]@{ skuId = $k; part = "$($s.skuPartNumber)"; name = $skuName[$k]; total = $en; used = [int]$s.consumedUnits; left = ($en - [int]$s.consumedUnits)
        suspended = [int]$s.prepaidUnits.suspended; warning = [int]$s.prepaidUnits.warning; status = "$($s.capabilityStatus)"; appliesTo = "$($s.appliesTo)"
        direct = $c.direct; group = $c.group; both = $c.both; errors = $c.errors
        groups = (@($c.groups.Keys | Sort-Object { -$c.groups[$_] } | ForEach-Object { "$_ ($($c.groups[$_]))" }) -join '; ') }
}
@{ skus = @($out | Sort-Object { -$_.used }); rows = $rows.ToArray(); people = $users.Count; at = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
'@
# /api/lic-read - no request fields. Gets a Graph token for the signed-in person and starts the read job; returns { ok, id } (job id to poll).
$ScreenHandlers['/api/lic-read'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $tok = Get-SessGraphToken; if (-not $tok) { throw 'The Microsoft sign-in could not give a token. Sign out of Microsoft and connect again.' }
    $id = Start-GJob 'licread' $script:LicReadWork @{ Token = $tok; Names = $script:LicNames } 'Read licenses'
    Send $ctx @{ ok = $true; id = $id }
}

# ---------------- groups for group-based licensing (search) ----------------
# /api/lic-groups - request: $d.q (text). Returns up to the matching groups (name starts with q) so one can be chosen for group licensing.
# Fewer than 2 characters returns an empty list. A single quote is doubled because OData filters use '...' strings.
$ScreenHandlers['/api/lic-groups'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $q = "$($d.q)".Trim().Replace("'", "''"); if ($q.Length -lt 2) { Send $ctx @{ ok = $true; groups = @() }; return }
    $r = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/groups?`$filter=" + [uri]::EscapeDataString("startswith(displayName,'$q')") + '&$select=id,displayName,assignedLicenses,securityEnabled,groupTypes,onPremisesSyncEnabled&$top=25') -ErrorAction Stop
    Send $ctx @{ ok = $true; groups = @(@($r.value) | ForEach-Object { @{ id = "$($_.id)"; name = "$($_.displayName)"; licensed = (@($_.assignedLicenses).Count -gt 0); synced = [bool]$_.onPremisesSyncEnabled; dynamic = (@($_.groupTypes) -contains 'DynamicMembership') } }) }
}

# ---------------- bulk changes (background job) ----------------
# Action: assign | remove (direct license)   groupadd | groupremove (licensing group)
# Script text of the CHANGE background job. For every person in $p.Users it does the action in $p.Action:
# assign / remove = direct license (needs a usage location, country, on the user); groupadd / groupremove = member of a licensing group.
# 'Skipped' = nothing to do, 'Done' = changed, 'Failed' = error (known Graph errors are turned into plain text in the catch block).
# Returns { rows } with one result row per person. Comments cannot go inside the text because it is a here-string.
$script:LicChangeWork = @'
$res = New-Object Collections.Generic.List[object]; $p.Sync.total = @($p.Users).Count; $i = 0
foreach ($who in @($p.Users)) {
    if ($p.Sync.cancel) { break }
    $i++; $p.Sync.done = $i; $p.Sync.step = "Working on $who"
    $r = [ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); user = "$who"; action = $p.Label; result = ''; message = '' }
    try {
        $u = Invoke-G ("v1.0/users/$([uri]::EscapeDataString("$who"))?`$select=id,userPrincipalName,usageLocation,licenseAssignmentStates")
        $r.user = "$($u.userPrincipalName)"
        $st = @($u.licenseAssignmentStates | Where-Object { "$($_.skuId)" -eq $p.SkuId })
        $hasDirect = [bool]($st | Where-Object { -not $_.assignedByGroup }); $fromGroups = @($st | Where-Object { $_.assignedByGroup })
        switch ($p.Action) {
            'assign' {
                if ($hasDirect) { $r.result = 'Skipped'; $r.message = 'Already has this license directly.'; break }
                if (-not $u.usageLocation) {
                    if ($p.Usage) { [void](Invoke-G "v1.0/users/$($u.id)" 'PATCH' @{ usageLocation = $p.Usage }); $r.message = "Usage location set to $($p.Usage). " }
                    else { throw 'The person has no usage location (country) - choose one under "Usage location if empty" and run again.' }
                }
                [void](Invoke-G "v1.0/users/$($u.id)/assignLicense" 'POST' @{ addLicenses = @(@{ skuId = $p.SkuId; disabledPlans = @() }); removeLicenses = @() })
                $r.result = 'Done'; $r.message += $(if ($fromGroups.Count) { 'Assigned directly (also has it from a group).' } else { 'License assigned.' })
            }
            'remove' {
                if (-not $hasDirect) {
                    if ($fromGroups.Count) { $r.result = 'Skipped'; $r.message = 'The license comes from a group - remove the person from that group instead (action "Remove from licensing group").' } else { $r.result = 'Skipped'; $r.message = 'Does not have this license.' }
                    break
                }
                [void](Invoke-G "v1.0/users/$($u.id)/assignLicense" 'POST' @{ addLicenses = @(); removeLicenses = @($p.SkuId) })
                $r.result = 'Done'; $r.message = $(if ($fromGroups.Count) { 'Direct license removed - the person still has it from a group.' } else { 'License removed.' })
            }
            'groupadd' {
                try { [void](Invoke-G "v1.0/groups/$($p.GroupId)/members/`$ref" 'POST' @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($u.id)" }); $r.result = 'Done'; $r.message = "Added to $($p.GroupName) - the group gives the license within a few minutes." }
                catch { if ("$_" -match 'already exist') { $r.result = 'Skipped'; $r.message = "Already a member of $($p.GroupName)." } else { throw } }
            }
            'groupremove' {
                try { [void](Invoke-G "v1.0/groups/$($p.GroupId)/members/$($u.id)/`$ref" 'DELETE'); $r.result = 'Done'; $r.message = "Removed from $($p.GroupName) - the group license is taken away within a few minutes." }
                catch { if ("$_" -match 'does not exist|not found|Request_ResourceNotFound') { $r.result = 'Skipped'; $r.message = "Not a member of $($p.GroupName)." } else { throw } }
            }
        }
    } catch {
        $m = "$_"
        if ($m -match 'CountViolation|not enough|LicenseLimitExceeded|exceeded') { $m = 'No free licenses left for this product.' }
        elseif ($m -match 'MutuallyExclusiveViolation') { $m = 'This license cannot be combined with a license the person already has.' }
        elseif ($m -match 'synchroni[sz]ed|on-premises|DirSync') { $m = "$m (the group is synced from on-premises AD - change its members there)" }
        $r.result = 'Failed'; $r.message = $m
    }
    $res.Add($r)
}
@{ rows = $res.ToArray() }
'@
# /api/lic-change - request: $d.action (assign|remove|groupadd|groupremove), $d.confirm (must be exactly APPLY), $d.users (list),
# $d.skuId + $d.skuName (for assign/remove), $d.groupId + $d.groupName (for group actions), $d.usage (2-letter country, optional).
# Checks everything first, then starts the background job; returns { ok, id }.
$ScreenHandlers['/api/lic-change'] = {
    if (-not $script:Who) { throw 'Sign in to Microsoft first (Settings > Connections).' }
    $act = "$($d.action)"; if ($act -notin 'assign', 'remove', 'groupadd', 'groupremove') { throw 'Choose what to do.' }
    if ("$($d.confirm)" -ne 'APPLY') { throw 'Type APPLY to confirm.' }
    $users = @(@($d.users) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $users.Count) { throw 'Choose at least one person.' }
    # Safety limit per run. The characters \ / ? # are refused in names because they would change the Graph URL.
    if ($users.Count -gt 2000) { throw 'Up to 2000 people at a time.' }
    foreach ($x in $users) { if ($x -match '[\\/?#]') { throw "Not a valid user: $x" } }
    $sku = "$($d.skuId)"; $gid = "$($d.groupId)"; $gnm = "$($d.groupName)"
    # Regex: a GUID (36 hex characters and dashes) - the format of license and group ids.
    if ($act -in 'assign', 'remove' -and $sku -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Choose the license.' }
    if ($act -in 'groupadd', 'groupremove' -and $gid -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Choose the licensing group.' }
    # Usage location must be a 2-letter ISO country code (Graph requires it before a license can be assigned).
    $usage = "$($d.usage)".Trim().ToUpper(); if ($usage -and $usage -notmatch '^[A-Z]{2}$') { throw 'The usage location is a 2-letter country code, for example AE.' }
    $tok = Get-SessGraphToken; if (-not $tok) { throw 'The Microsoft sign-in could not give a token. Sign out of Microsoft and connect again.' }
    # Text shown in the job list and written to the audit files.
    $label = switch ($act) { 'assign' { "Assign $($d.skuName)" } 'remove' { "Remove $($d.skuName)" } 'groupadd' { "Add to group $gnm" } 'groupremove' { "Remove from group $gnm" } }
    $id = Start-GJob 'licchg' $script:LicChangeWork @{ Token = $tok; Action = $act; SkuId = $sku; GroupId = $gid; GroupName = $gnm; Users = $users; Usage = $usage; Label = $label } $label
    Send $ctx @{ ok = $true; id = $id }
}
# Called by the job system when the change job ends. Inputs: $j (job: user = operator), $res (job result rows), $err (error text or empty).
# Writes each result to the monthly license-audit CSV and to the activity log, then marks the license cache as out of date.
function Complete-GJob_licchg($j, $res, $err) {
    $f = Join-Path $LogDir ('license-audit-{0:yyyy-MM}.csv' -f (Get-Date))
    # New month = new file, so write the header line first.
    if (-not (Test-Path $f)) { 'Time,PortalUser,User,Action,Result,Message' | Out-File $f -Encoding utf8 }
    foreach ($r in @($res.rows)) {
        # One CSV line per person (each value is quoted safely by ConvertTo-CsvCell).
        (@($r.time, $j.user, $r.user, $r.action, $r.result, $r.message) | ForEach-Object { ConvertTo-CsvCell $_ }) -join ',' | Add-Content $f
        Write-ActRow 'Licenses' "$($r.action)" "$($r.user)" "$($r.result)" "$($r.message)"
    }
    if ($err) { Write-ActRow 'Licenses' "$($j.arg.Label)" '' "Failed: $err" '' }
    # Tells the other screens that cached data is old and must be reloaded.
    $script:SpDirty = $true
}

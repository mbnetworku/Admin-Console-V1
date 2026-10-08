# Screen-Updates.ps1 - back end for Settings > Updates. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Updates (Settings > Server)
# Screen version: 2.8.0   (changes ONLY when this screen changes - not with every release)
# Administrators only.
#  * Upload a new version (the AdminConsole-x.y.z.zip you were given) -> it is checked, then installed when you confirm.
#  * Before every install the version that runs now is saved in backups\ (code only) -> "Go back to this version" restores it.
#  * Your data is never touched: settings (*.json), logs, DistributionGroups, email-images, sso-logo, backups, updates.
#  * If the page does not start after an update: run Revert-Update.bat (as administrator) - it puts back the newest backup.

# WHAT THIS SCREEN DOES: Settings > Updates. Upload a new version zip, check it, install it (with an automatic backup), go back to an older
# backup, and delete old backups. After an install or revert the server restarts itself.
# ENDPOINTS: /api/update-info, /api/update-upload, /api/update-discard, /api/update-install, /api/update-revert, /api/update-delete.
# DATA: folders 'updates' (pending.zip + the last installed zips) and 'backups' (code-only zips with a .txt note) under the tool folder ($Root).
# NO Microsoft Graph / AD / Exchange calls. Every action is written to the activity log (Write-ActRow).
# PERMISSION: administrators only (see the header above).
#
# Folder for the uploaded zip waiting to be installed.
$script:UpdDir = Join-Path $Root 'updates'
# Folder for the backups of the code that was running before each install.
$script:BakDir = Join-Path $Root 'backups'
# Loads the .NET zip classes (needed in Windows PowerShell 5.1; errors are ignored if they are already loaded).
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# files and folders that belong to the people using the tool - never replaced, never backed up as code
# Input: a path inside the tool folder. Returns $true when the file belongs to the data of the people using the tool
# (logs, saved settings *.json in the main folder, SSO logo, certificates/keys, backups...) and so must never be replaced or backed up as code.
# '_old...' folders are also kept. Slashes are made uniform first so the same rules work for zip paths and Windows paths.
function Test-UpdKeep([string]$rel) {
    $r = $rel -replace '\\', '/'
    if ($r -match '^(logs|DistributionGroups|email-images|backups|updates|_old[^/]*)(/|$)') { return $true }
    if ($r -notmatch '/' -and $r -match '\.json$') { return $true }
    if ($r -match '^sso-logo') { return $true }
    if ($r -match '\.(pfx|p12|key)$') { return $true }
    $false
}
# the entries of a version zip, without the top folder (PasswordReset/...) when every entry has it
# Input: an opened zip. Returns one record per FILE { entry, rel } where rel is the path without the top folder.
function Get-UpdEntries($zip) {
    $e = @($zip.Entries | Where-Object { $_.Name })   # files only
    $top = $null
    # If all files sit inside one top folder (and nothing sits at the root), that folder name is cut off, so 'PasswordReset/server.ps1' becomes 'server.ps1'.
    $first = @($e | ForEach-Object { ($_.FullName -replace '\\', '/').Split('/')[0] } | Sort-Object -Unique)
    if ($first.Count -eq 1 -and @($e | Where-Object { ($_.FullName -replace '\\', '/') -notmatch '/' }).Count -eq 0) { $top = $first[0] + '/' }
    foreach ($x in $e) { $n = $x.FullName -replace '\\', '/'; if ($top) { $n = $n.Substring($top.Length) }; [pscustomobject]@{ entry = $x; rel = $n } }
}
# v2.8.0: compare the screens in a version zip with the screens installed now. Every screen has its own version in its header
# ("Screen version: x.y.z"), so the answer is per screen: updated (version differs), new (not installed yet), same, or removed.
# A zip made before v2.8.0 has no screen versions - then nothing is listed per screen.
# Input: the entries of a version zip. Returns one record per screen file { file, name, old, version, status } sorted new, updated, removed, same.
function Get-UpdUnits($all) {
    $installed = @{}; foreach ($u in @(Get-InstalledUnits)) { $installed[$u.file] = $u }
    $out = @(); $seen = @{}
    foreach ($x in $all) {
        # Only look at the program files (server.ps1, backend/<group>/*.ps1, frontend/*.html); skip Tools and docs folders.
        if ($x.rel -notmatch '^(backend/[^/]+/|frontend/)?[^/]+\.(ps1|html)$' -or $x.rel -match '^(Tools|docs)/') { continue }
        $f = ($x.rel -split '/')[-1]
        # Only files that are real screens/units with a version stamp in their first lines.
        if ($f -notmatch '^(Screen-.+\.ps1|ActivityLog\.ps1|DistGroups-Worker\.ps1|index\.html|login\.html|server\.ps1)$') { continue }
        $m = @{ name = ''; version = '' }
        # Read just the first 12 lines of the file inside the zip and let Get-UnitMeta pick out the screen name and version.
        try { $sr = New-Object IO.StreamReader($x.entry.Open()); $head = @(); for ($i = 0; $i -lt 12 -and -not $sr.EndOfStream; $i++) { $head += $sr.ReadLine() }; $sr.Close(); $m = Get-UnitMeta ($head -join "`n") } catch {}
        if (-not $m.version) { continue }
        $seen[$f] = $true; $have = $installed[$f]
        # Status: 'new' = not installed yet, 'same' = same version, 'updated' = version differs.
        $st = if (-not $have -or -not $have.present) { 'new' } elseif ("$($have.version)" -eq $m.version) { 'same' } else { 'updated' }
        $out += [pscustomobject]@{ file = $f; name = $(if ($m.name) { $m.name } else { $f }); old = $(if ($have -and $have.present) { "$($have.version)" } else { '' }); version = $m.version; status = $st }
    }
    # Screens installed now but missing in the zip are reported as 'removed' (only when the zip has screen versions at all; server.ps1 is never reported).
    if ($out.Count) { foreach ($u in $installed.Values) { if ($u.present -and -not $seen.ContainsKey($u.file) -and $u.file -ne 'server.ps1') { $out += [pscustomobject]@{ file = $u.file; name = $u.name; old = "$($u.version)"; version = ''; status = 'removed' } } } }
    # Sort order for the page: new first, then updated, removed, same; then by name.
    @($out | Sort-Object @{ e = { @{ new = 0; updated = 1; removed = 2; same = 3 }[$_.status] } }, name)
}
# Input: path of a version zip. Checks that it is a real Admin Console version and returns { version, date, files, notes, units }.
# Throws a readable error for unsafe paths, a missing server.ps1 / index.html or a missing version number.
function Read-UpdZip([string]$path) {
    $z = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $all = @(Get-UpdEntries $z)
        # Security check: refuse '..' parts, drive letters (C:) and absolute paths, so the zip cannot write outside the tool folder (zip-slip).
        foreach ($x in $all) { if ($x.rel -match '(^|/)\.\.(/|$)' -or $x.rel -match '^[A-Za-z]:' -or $x.rel.StartsWith('/')) { throw "The zip has an unsafe path: $($x.rel)" } }
        $srv = $all | Where-Object { $_.rel -eq 'server.ps1' } | Select-Object -First 1
        if (-not $srv) { throw 'This is not an Admin Console version: server.ps1 is missing in the zip.' }
        if (-not ($all | Where-Object { $_.rel -in 'frontend/index.html', 'web/index.html' })) { throw 'This is not an Admin Console version: frontend/index.html is missing in the zip.' }
        $sr = New-Object IO.StreamReader($srv.entry.Open()); $txt = $sr.ReadToEnd(); $sr.Close()
        # Read $AppVersion and $AppDate out of the server.ps1 text inside the zip (the backtick keeps the $ from being expanded).
        $ver = if ($txt -match "\`$AppVersion\s*=\s*'([^']+)'") { $Matches[1] } else { '' }
        $dt = if ($txt -match "\`$AppDate\s*=\s*'([^']+)'") { $Matches[1] } else { '' }
        if (-not $ver) { throw 'The version number was not found in server.ps1 of the zip.' }
        # what is new (the VERSIONS list in index.html), only the entries newer than the running version
        $notes = @()
        try {
            # Read the VERSIONS list from index.html of the zip; notes are collected only for versions newer than the running one, in list order.
            $ix = @($all | Where-Object { $_.rel -eq 'frontend/index.html' } | Select-Object -First 1)[0]; if (-not $ix) { $ix = $all | Where-Object { $_.rel -eq 'web/index.html' } | Select-Object -First 1 }; $sr = New-Object IO.StreamReader($ix.entry.Open()); $h = $sr.ReadToEnd(); $sr.Close()
            # The regex captures the JSON array after 'const VERSIONS=' up to the next declaration.
            if ($h -match 'const VERSIONS=(\[.*?\])\s*[,;]\s*(?:const\s+|let\s+|var\s+)?[A-Za-z_]+\s*=') { $vl = $Matches[1] | ConvertFrom-Json; foreach ($v in $vl) { if ((Compare-UpdVer "$($v.v)" $AppVersion) -le 0) { break }; $notes += [pscustomobject]@{ v = "$($v.v)"; t = "$($v.t)"; n = @($v.n) } } }
        } catch {}
        # Per-screen comparison; if it fails the update can still be shown without it.
        $units = @(); try { $units = @(Get-UpdUnits $all) } catch {}
        [pscustomobject]@{ version = $ver; date = $dt; files = @($all | Where-Object { -not (Test-UpdKeep $_.rel) }).Count; notes = @($notes | Select-Object -First 15); units = $units }
    } finally { $z.Dispose() }
}
# Compares two version texts like 2.5.1 and 2.10.0. Returns -1, 0 or 1 (negative: a is older). Non-number characters are removed first;
# if the text is not a valid version a plain text compare is used.
function Compare-UpdVer($a, $b) { try { ([version]("$a" -replace '[^0-9.]', '')).CompareTo([version]("$b" -replace '[^0-9.]', '')) } catch { [string]::Compare("$a", "$b") } }
# zip the code that runs now (not the data) -> backups\AdminConsole-<version>-<time>.zip
# Input: $why = a note stored next to the backup. Returns the backup file name. Old backups beyond the newest 10 are deleted.
function New-UpdBackup([string]$why) {
    if (-not (Test-Path $script:BakDir)) { New-Item -ItemType Directory -Path $script:BakDir -Force | Out-Null }
    $name = 'AdminConsole-{0}-{1:yyyyMMdd-HHmmss}.zip' -f $AppVersion, (Get-Date)
    $dest = Join-Path $script:BakDir $name
    $z = [IO.Compression.ZipFile]::Open($dest, 'Create')
    try {
        # Add every code file to the zip (relative path inside), skipping user data (Test-UpdKeep).
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            if (Test-UpdKeep $rel) { continue }
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $rel)
        }
    } finally { $z.Dispose() }
    Set-Content -LiteralPath ($dest + '.txt') -Value "$why`r`nVersion $AppVersion`r`nSaved $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $($script:SessUser.name)" -Encoding UTF8
    # keep the newest 10 backups
    @(Get-ChildItem -LiteralPath $script:BakDir -Filter 'AdminConsole-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10) | ForEach-Object { Remove-Item -LiteralPath $_.FullName, ($_.FullName + '.txt') -Force -ErrorAction SilentlyContinue }
    $name
}
# copy the code of a version zip over this folder (data is skipped), then restart
# Input: path of a version zip. Copies its code files over the tool folder (data is skipped, existing files are overwritten) and returns the number of files.
function Install-UpdZip([string]$path) {
    $z = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $n = 0
        foreach ($x in @(Get-UpdEntries $z)) {
            if (Test-UpdKeep $x.rel) { continue }
            $to = Join-Path $Root ($x.rel -replace '/', [IO.Path]::DirectorySeparatorChar)
            $dir = Split-Path $to -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($x.entry, $to, $true); $n++
        }
        $n
    } finally { $z.Dispose() }
    # Files extracted from a downloaded zip can carry the 'blocked' mark of Windows, which stops scripts; remove it.
    try { Get-ChildItem -LiteralPath $Root -Recurse -File | Unblock-File -ErrorAction SilentlyContinue } catch {}
}
# Input: $why = text for logs. Signs everybody out, stops the web listener and starts a new hidden copy of server.ps1 after 4 seconds
# (the delay lets this process release the port first).
function Restart-UpdServer($why) {
    try { Write-LoginLog "$($script:SessUser.name)" $why } catch {}
    Stop-AllSessions "Microsoft sign-out ($why)"
    $listener.Stop(); Write-Host "$why - restarting..."
    $cmd = "Start-Sleep -Seconds 4; & '" + ((Join-Path $Root 'server.ps1') -replace "'", "''") + "' -Background -NoBrowser"
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`"" -WindowStyle Hidden -WorkingDirectory $Root
}
# Returns the list of saved versions (newest first): file name, version from the name, time saved, size in KB and the first line of its .txt note.
function Get-UpdBackups {
    if (-not (Test-Path $script:BakDir)) { return @() }
    @(Get-ChildItem -LiteralPath $script:BakDir -Filter 'AdminConsole-*.zip' | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $v = if ($_.Name -match '^AdminConsole-(.+?)-(\d{8}-\d{6})\.zip$') { $Matches[1] } else { '?' }
        $why = ''; try { $why = @(Get-Content -LiteralPath ($_.FullName + '.txt') -Encoding UTF8)[0] } catch {}
        [pscustomobject]@{ name = $_.Name; version = $v; saved = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); size = [math]::Round($_.Length / 1KB); why = "$why" }
    })
}

# Endpoint: /api/update-info - no input. Sends running version/date, the tool folder, the waiting upload (if any, re-checked; a broken one is deleted),
# the backups and the list of installed parts.
$ScreenHandlers['/api/update-info'] = {
    $pend = $null; $pf = Join-Path $script:UpdDir 'pending.zip'
    if (Test-Path $pf) { try { $pend = Read-UpdZip $pf } catch { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue } }
    Send $ctx @{ ok = $true; version = $AppVersion; date = $AppDate; folder = "$Root"; pending = $pend; backups = @(Get-UpdBackups); parts = @(Get-InstalledUnits | ForEach-Object { @{ file = $_.file; name = $_.name; version = $_.version } }) }
}
# Endpoint: /api/update-upload - body { name, data }. Saves and checks the zip; sends { pending, older, same } so the page can warn about
# an older or identical version. Nothing is installed yet.
$ScreenHandlers['/api/update-upload'] = {
    # { name, data (base64 of the zip) } -> checked, kept as updates\pending.zip until you click Install
    $b64 = "$($d.data)"; if (-not $b64) { throw 'Choose the zip file of the new version.' }
    if ("$($d.name)" -notmatch '\.zip$') { throw 'Upload the .zip file of the new version (for example AdminConsole-2.5.0.zip).' }
    # Size limit 60 MB.
    $bytes = [Convert]::FromBase64String($b64); if ($bytes.Length -gt 60MB) { throw 'The file is too big (more than 60 MB).' }
    if (-not (Test-Path $script:UpdDir)) { New-Item -ItemType Directory -Path $script:UpdDir -Force | Out-Null }
    # Write to a temporary file first and only rename it to pending.zip after it passed the check (a bad zip is deleted).
    $tmp = Join-Path $script:UpdDir ('upload-' + [guid]::NewGuid().ToString('N') + '.zip'); [IO.File]::WriteAllBytes($tmp, $bytes)
    try { $info = Read-UpdZip $tmp } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw "$($_.Exception.Message)" }
    Move-Item -LiteralPath $tmp -Destination (Join-Path $script:UpdDir 'pending.zip') -Force
    Write-ActRow 'Settings' 'Update uploaded' "$($d.name)" 'Done' "Version $($info.version) (running $AppVersion)"
    Send $ctx @{ ok = $true; pending = $info; older = ((Compare-UpdVer $info.version $AppVersion) -lt 0); same = ((Compare-UpdVer $info.version $AppVersion) -eq 0) }
}
# Endpoint: /api/update-discard - deletes the waiting upload.
$ScreenHandlers['/api/update-discard'] = {
    Remove-Item -LiteralPath (Join-Path $script:UpdDir 'pending.zip') -Force -ErrorAction SilentlyContinue
    Send $ctx @{ ok = $true }
}
# Endpoint: /api/update-install - body { confirm:'UPDATE' }. Order: check zip, back up the running code, copy new files, keep the zip as
# installed-*.zip (newest 5 kept), answer the page, THEN restart. The answer is sent before the restart because the server stops listening.
$ScreenHandlers['/api/update-install'] = {
    $pf = Join-Path $script:UpdDir 'pending.zip'; if (-not (Test-Path $pf)) { throw 'Upload the new version first.' }
    if ("$($d.confirm)" -ne 'UPDATE') { throw 'Type UPDATE to confirm.' }
    $info = Read-UpdZip $pf
    $bak = New-UpdBackup "Before the update to $($info.version)"
    $n = Install-UpdZip $pf
    Move-Item -LiteralPath $pf -Destination (Join-Path $script:UpdDir ('installed-{0}-{1:yyyyMMdd-HHmmss}.zip' -f $info.version, (Get-Date))) -Force -ErrorAction SilentlyContinue
    @(Get-ChildItem -LiteralPath $script:UpdDir -Filter 'installed-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5) | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-ActRow 'Settings' 'Update installed' "$AppVersion -> $($info.version)" 'Done' "$n files; backup $bak"
    Send $ctx @{ ok = $true; version = $info.version; backup = $bak; files = $n }
    Restart-UpdServer "Updated from $AppVersion to $($info.version)"
}
# Endpoint: /api/update-revert - body { name, confirm:'REVERT' }. The name must look like a backup file name (this also blocks path tricks).
$ScreenHandlers['/api/update-revert'] = {
    # { name } of a backup -> the code that runs now is saved too, then the backup is put back and the server restarts
    $nm = "$($d.name)"; if ($nm -notmatch '^AdminConsole-[A-Za-z0-9.]+-\d{8}-\d{6}\.zip$') { throw 'Choose a saved version.' }
    $p = Join-Path $script:BakDir $nm; if (-not (Test-Path -LiteralPath $p)) { throw 'That saved version is not there any more.' }
    if ("$($d.confirm)" -ne 'REVERT') { throw 'Type REVERT to confirm.' }
    $ver = if ($nm -match '^AdminConsole-(.+?)-\d{8}-\d{6}\.zip$') { $Matches[1] } else { '?' }
    # The code running now is backed up too, so going back can itself be undone.
    $bak = New-UpdBackup "Before going back to $ver"
    $n = Install-UpdZip $p
    Write-ActRow 'Settings' 'Went back to an old version' "$AppVersion -> $ver" 'Done' "$n files; backup of $AppVersion $bak"
    Send $ctx @{ ok = $true; version = $ver; backup = $bak }
    Restart-UpdServer "Went back from $AppVersion to $ver"
}
# Endpoint: /api/update-delete - body { name }. Deletes one backup zip and its .txt note, then sends the new backup list.
$ScreenHandlers['/api/update-delete'] = {
    $nm = "$($d.name)"; if ($nm -notmatch '^AdminConsole-[A-Za-z0-9.]+-\d{8}-\d{6}\.zip$') { throw 'Choose a saved version.' }
    $p = Join-Path $script:BakDir $nm; Remove-Item -LiteralPath $p, ($p + '.txt') -Force -ErrorAction SilentlyContinue
    Write-ActRow 'Settings' 'Saved version deleted' $nm 'Done' ''
    Send $ctx @{ ok = $true; backups = @(Get-UpdBackups) }
}

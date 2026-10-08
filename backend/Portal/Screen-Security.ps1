# Screen-Security.ps1 - Settings > Access and security. Loaded by server.ps1 at start-up; do not run it on its own.
# Screen: Access and security (Settings)
# Screen version: 2.4.0   (changes ONLY when this screen changes - not with every release)
#  * Allowed IP addresses: only these PCs / networks can open the portal (this server itself is always allowed, so you can never lock yourself out).
#  * HTTPS only: other PCs must use https:// (plain http is refused; this server itself may still use http://localhost).
#  * Encryption at rest: tool-users.json and people-db.json are encrypted (Windows DPAPI, this server only).
#  * Request limits, password-guessing protection per IP address, browser security headers, folder lock.
# Screen: Settings > Access and security. Endpoints: /api/sec-get, /api/sec-save, /api/sec-unblock, /api/sec-lockfolder, /api/sec-tfa-reset.
# Data files in the tool folder: access-security.json (settings), two-step.json (authenticator secrets, encrypted), https-settings.json (read only),
# tool-users.json / people-db.json (encrypted by this file). Also used by server.ps1 for every request: Invoke-SecGate, Test-IpLoginBlocked,
# Add-IpLoginFail, Invoke-TfaGate, Test-SamlReplay, Test-SafeOutFolder. Calls icacls.exe to lock the folder. No Graph / AD calls.
# Settings endpoints are for signed-in administrators (the checks are done by server.ps1).
#
# System.Security is needed for ProtectedData (DPAPI). Silent if it is already loaded.
Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
$script:SecFile = Join-Path $Root 'access-security.json'
# Extra secret bytes mixed into DPAPI, so other programs on this server cannot decrypt the files just by calling DPAPI.
$script:SecEntropy = [Text.Encoding]::UTF8.GetBytes('AdminConsole-at-rest-v1')
# IpFails = wrong-password counters per IP address. SamlSeen = SAML answer ids already used. Both are in memory only.
$script:IpFails = @{}; $script:SamlSeen = @{}

# ---------- encryption at rest (DPAPI, LocalMachine scope: readable on THIS server only, also if the service account changes) ----------
# Encrypts text with Windows DPAPI (LocalMachine scope: only this server can decrypt). Returns 'ACENC1:' + base64, the marker of an encrypted file.
function Protect-AtRest([string]$text) {
    $b = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($text), $script:SecEntropy, 'LocalMachine')
    'ACENC1:' + [Convert]::ToBase64String($b)
}
# Reads a file: decrypts it if it starts with ACENC1:, otherwise returns the plain text (old unencrypted files still work).
function Read-SecureText([string]$path) {
    $t = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ($t.StartsWith('ACENC1:')) { return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($t.Substring(7).Trim()), $script:SecEntropy, 'LocalMachine')) }
    $t.TrimStart([char]0xFEFF)
}
# Encrypts and saves a file. Writes to a .tmp file first and then moves it over the real one, so a crash never leaves a half-written file.
function Write-SecureText([string]$path, [string]$text) {
    $tmp = "$path.tmp"; [IO.File]::WriteAllText($tmp, (Protect-AtRest $text), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
# encrypt the files that are still plain text (older versions) once at start-up
# Runs once at start-up: any of these files that is still plain text (older versions) gets encrypted. Errors are shown but do not stop start-up.
foreach ($fn in 'tool-users.json', 'people-db.json', 'people-db.bak.json') {
    $p = Join-Path $Root $fn
    try { if ((Test-Path $p) -and -not ([IO.File]::ReadAllText($p).StartsWith('ACENC1:'))) { Write-SecureText $p (Read-SecureText $p); Write-Host "Encrypted $fn (only this server can read it)." -ForegroundColor Green } } catch { Write-Host "Could not encrypt ${fn}: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# ---------- settings ----------
# Loads access-security.json. Starts from defaults and only overrides keys that exist in the file. Returns an ordered hashtable
# (ipOn, ips, httpsOnly, ipMaxFails, ipLockMins, tfa = off/admins/all, bindIp).
function Get-SecCfg {
    $c = [ordered]@{ ipOn = $false; ips = @(); httpsOnly = $false; ipMaxFails = 20; ipLockMins = 15; tfa = 'off'; bindIp = $true }
    if (Test-Path $script:SecFile) { try { $j = Get-Content $script:SecFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } } } catch {} }
    $c.ips = @($c.ips | ForEach-Object { "$_".Trim() } | Where-Object { $_ }); $c
}
# Settings are cached here for speed; /api/sec-save refreshes the cache.
$script:SecCfg = Get-SecCfg
# True for this server itself (127.x, ::1). The server is always allowed, so nobody can lock the admin out.
function Test-IsLoopback([string]$ip) { $ip -in '127.0.0.1', '::1', '::ffff:127.0.0.1' -or $ip -like '127.*' }
# one rule: 10.1.2.3, 10.1.2.0/24, 10.1.2.10-10.1.2.50, or 2001:db8::/32
# Checks if IP $ip matches one rule $rule. Rule forms: single IP, CIDR network (/24), or range (from-to). Works for IPv4 and IPv6.
# Returns $true/$false; any parse error means $false (no match).
function Test-IpRule([string]$ip, [string]$rule) {
    try {
        $a = [Net.IPAddress]::Parse(($ip -replace '^::ffff:', ''))
        if ($rule -match '^(.+)-(.+)$') {
            # Range rule: compare the address byte by byte with the low and high ends. The first byte that differs decides.
            $lo = [Net.IPAddress]::Parse($Matches[1].Trim()).GetAddressBytes(); $hi = [Net.IPAddress]::Parse($Matches[2].Trim()).GetAddressBytes(); $x = $a.GetAddressBytes()
            if ($x.Length -ne $lo.Length) { return $false }
            $ge = $true; $le = $true
            for ($i = 0; $i -lt $x.Length; $i++) { if ($x[$i] -ne $lo[$i]) { $ge = $x[$i] -gt $lo[$i]; break } }
            for ($i = 0; $i -lt $x.Length; $i++) { if ($x[$i] -ne $hi[$i]) { $le = $x[$i] -lt $hi[$i]; break } }
            return ($ge -and $le)
        }
        # Network rule: split off the /prefix length; no prefix means a single address (all bits must match).
        $bits = -1; $net = $rule; if ($rule -match '^(.+)/(\d{1,3})$') { $net = $Matches[1]; $bits = [int]$Matches[2] }
        $n = [Net.IPAddress]::Parse($net.Trim()).GetAddressBytes(); $x = $a.GetAddressBytes()
        if ($x.Length -ne $n.Length) { return $false }
        if ($bits -lt 0) { $bits = $n.Length * 8 }
        for ($i = 0; $i -lt $n.Length; $i++) {
            # For each byte, how many of its 8 bits belong to the network part; $mask keeps only those bits for the comparison.
            $take = [Math]::Max(0, [Math]::Min(8, $bits - $i * 8)); if ($take -eq 0) { break }
            $mask = (0xFF -shl (8 - $take)) -band 0xFF
            if (($x[$i] -band $mask) -ne ($n[$i] -band $mask)) { return $false }
        }
        $true
    } catch { $false }
}
# Checks that a typed rule is valid (single IP, network or range) before it is saved. Returns $true/$false.
function Test-IpRuleText([string]$rule) { $r = $rule.Trim(); if ($r -match '^(.+)-(.+)$') { return ([Net.IPAddress]::TryParse($Matches[1].Trim(), [ref]$null) -and [Net.IPAddress]::TryParse($Matches[2].Trim(), [ref]$null)) }; if ($r -match '^(.+)/(\d{1,3})$') { $ok = [Net.IPAddress]::TryParse($Matches[1], [ref]$null); return ($ok -and [int]$Matches[2] -le 128) }; [Net.IPAddress]::TryParse($r, [ref]$null) }
# Is this client IP allowed to use the portal? Always yes for the server itself, and yes for everybody when the IP list is off or empty.
function Test-IpAllowed([string]$ip) {
    if (Test-IsLoopback $ip) { return $true }
    $c = $script:SecCfg; if (-not $c.ipOn -or -not @($c.ips).Count) { return $true }
    foreach ($r in $c.ips) { if (Test-IpRule $ip $r) { return $true } }
    $false
}
# True when the request came in over HTTPS - directly, or through IIS on this same server (IIS tells us via X-Forwarded-Proto / X-ARR-SSL).
# Headers are trusted only when the request comes from localhost, so other PCs cannot fake them.
function Test-ReqSecure($ctx) {
    if ($ctx.Request.IsSecureConnection) { return $true }
    $rip = "$($ctx.Request.RemoteEndPoint.Address)"   # behind IIS on this server: trust its X-Forwarded-Proto only
    # IIS ARR adds X-ARR-SSL by itself for https requests (no IIS server variable needed); X-Forwarded-Proto still works too
    (Test-IsLoopback $rip) -and ("$($ctx.Request.Headers['X-Forwarded-Proto'])" -eq 'https' -or "$($ctx.Request.Headers['X-ARR-SSL'])" -ne '')
}
# Returns '; Secure' to append to a cookie when the connection is HTTPS, so the browser never sends it over plain http.
function Get-CookieSecure($ctx) { if (Test-ReqSecure $ctx) { '; Secure' } else { '' } }

# ---------- called by server.ps1 for EVERY request, before anything is read. Returns $true when the request was answered (refused). ----------
# Security check run by server.ps1 for EVERY request. Inputs: $ctx (HTTP context), $hasSess (does the request have a session).
# Adds browser security headers, then refuses the request (403 / 413) or redirects to https when needed. Returns $true if it already answered.
function Invoke-SecGate($ctx, $hasSess) {
    $h = $ctx.Response.Headers
    try {
        # Browser security headers: no framing (clickjacking), no content sniffing, no referrer to other sites, no camera/mic/location,
        # HSTS for https (max-age = 1 year), and no caching of API answers. Wrapped in try because a header may already be set.
        $h.Add('X-Frame-Options', 'DENY'); $h.Add('X-Content-Type-Options', 'nosniff'); $h.Add('Referrer-Policy', 'same-origin')
        $h.Add('Content-Security-Policy', "frame-ancestors 'none'; object-src 'none'; base-uri 'self'")
        $h.Add('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=()')
        $h.Add('Cross-Origin-Opener-Policy', 'same-origin-allow-popups')
        if (Test-ReqSecure $ctx) { $h.Add('Strict-Transport-Security', 'max-age=31536000') }
        if ("$($ctx.Request.Url.AbsolutePath)" -like '/api/*') { $h.Add('Cache-Control', 'no-store') }
    } catch {}
    $ip = "$($script:ClientIp)"; $rip = "$($ctx.Request.RemoteEndPoint.Address)"
    # Helper script block: send a plain-text error page with the given status code and close the connection.
    $deny = {
        param($code, $msg)
        try { $b = [Text.Encoding]::UTF8.GetBytes($msg); $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = 'text/plain; charset=utf-8'; $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close() } catch {}
    }
    # IP allow-list: refuse PCs that are not in the list.
    if (-not (Test-IpAllowed $ip)) { & $deny 403 "Access denied: this PC ($ip) is not allowed to use the Admin Console. Ask an administrator to add it in Settings > Access and security."; return $true }
    # HTTPS only: plain http from other PCs is refused. A normal GET page request is redirected to the https port from https-settings.json instead.
    if ($script:SecCfg.httpsOnly -and -not (Test-IsLoopback $rip) -and -not (Test-ReqSecure $ctx)) {
        $hc = $null; try { $hc = Get-Content (Join-Path $Root 'https-settings.json') -Raw | ConvertFrom-Json } catch {}
        if ($hc -and $hc.port -and $ctx.Request.HttpMethod -eq 'GET') { $hn = $ctx.Request.Url.Host; $ctx.Response.StatusCode = 301; $ctx.Response.RedirectLocation = "https://${hn}:$($hc.port)$($ctx.Request.Url.PathAndQuery)"; $ctx.Response.Close(); return $true }
        & $deny 403 'This portal accepts HTTPS only. Open it with https://'; return $true
    }
    # Size limits protect the server from huge uploads. 512KB/25MB/90MB are the limits; a missing length on a request
    # without a session is refused as well.
    # request size: before signing in only small requests (sign-in, SAML answers); signed in 25 MB, an update upload 90 MB
    $len = $ctx.Request.ContentLength64
    $max = if (-not $hasSess) { 512KB } elseif ("$($ctx.Request.Url.AbsolutePath)" -eq '/api/update-upload') { 90MB } else { 25MB }
    if ($len -gt $max -or ($len -lt 0 -and $ctx.Request.HasEntityBody -and -not $hasSess)) { & $deny 413 'The request is too big.'; return $true }
    $false
}
# ---------- password guessing from one IP address (any usernames) ----------
# Is this IP currently blocked for too many wrong passwords? Returns the unblock time, or $null if not blocked.
function Test-IpLoginBlocked([string]$ip) {
    if (Test-IsLoopback $ip) { return $null }
    $e = $script:IpFails[$ip]; if (-not $e) { return $null }
    if ($e.until -and (Get-Date) -lt $e.until) { return $e.until }
    $null
}
# Counts one wrong password from this IP. Only failures inside the last ipLockMins minutes count; at ipMaxFails the IP is blocked
# for ipLockMins minutes and the block is written to the login log. The table is cleared if it grows past 5000 IPs (memory safety).
function Add-IpLoginFail([string]$ip) {
    if (Test-IsLoopback $ip) { return }
    $now = Get-Date; $e = $script:IpFails[$ip]; if (-not $e) { $e = @{ times = New-Object Collections.Generic.List[datetime]; until = $null }; $script:IpFails[$ip] = $e }
    $win = $now.AddMinutes(-[int]$script:SecCfg.ipLockMins); [void]$e.times.RemoveAll([Predicate[datetime]] { param($t) $t -lt $win }); $e.times.Add($now)
    if ($e.times.Count -ge [int]$script:SecCfg.ipMaxFails) { $e.until = $now.AddMinutes([int]$script:SecCfg.ipLockMins); try { Write-LoginLog "(IP $ip)" "Blocked for $($script:SecCfg.ipLockMins) minutes after $($e.times.Count) wrong passwords from this PC" } catch {} }
    if ($script:IpFails.Count -gt 5000) { $script:IpFails.Clear() }
}
# ---------- a folder typed by a user must not be a system folder or the tool folder (the server runs with high rights) ----------
# Checks a folder typed by a user (for example for exports). Refuses Windows, Program Files, ProgramData, the tool folder, startup folders
# and drive roots, because the server runs with high rights. Returns $true if the folder is safe to write to.
function Test-SafeOutFolder([string]$p) {
    try { $f = [IO.Path]::GetFullPath($p).TrimEnd('\') + '\' } catch { return $false }
    $bad = @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemRoot, $Root, (Join-Path $env:SystemDrive 'Users\Default'), [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) | Where-Object { $_ }
    foreach ($b in $bad) { $bb = ([IO.Path]::GetFullPath($b)).TrimEnd('\') + '\'; if ($f.StartsWith($bb, [StringComparison]::OrdinalIgnoreCase)) { return $false } }
    if ($f -match '^[A-Za-z]:\\$') { return $false }   # not the root of a drive
    $true
}
# ---------- SAML: an answer can be used only once ----------
# A SAML sign-in answer may be used only once. Inputs: assertion id and its expiry. Returns $true if this id was already used (replay attack).
# Expired ids are removed first; a new id is remembered until its expiry + 5 minutes (or 1 hour if no valid expiry).
function Test-SamlReplay([string]$id, [datetime]$until) {
    $now = [datetime]::UtcNow
    foreach ($k in @($script:SamlSeen.Keys)) { if ($script:SamlSeen[$k] -lt $now) { $script:SamlSeen.Remove($k) } }
    if (-not $id) { return $false }
    if ($script:SamlSeen.ContainsKey($id)) { return $true }
    $script:SamlSeen[$id] = $(if ($until -gt $now) { $until.AddMinutes(5) } else { $now.AddHours(1) }); $false
}


# ---------- 2-step sign-in (authenticator app, TOTP - RFC 6238: 6 digits, 30 seconds, SHA-1; works with Microsoft / Google Authenticator) ----------
# Two-step sign-in file (encrypted) and the list of people who are in the middle of setting it up (TfaPending, in memory).
$script:TfaFile = Join-Path $Root 'two-step.json'; $script:TfaPending = @{}
# Base32 encoder (letters A-Z, digits 2-7). Authenticator apps want the secret key in this format.
function ConvertTo-B32([byte[]]$b) { $a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; $o = New-Object Text.StringBuilder; $buf = 0; $bits = 0; foreach ($x in $b) { $buf = ($buf -shl 8) -bor $x; $bits += 8; while ($bits -ge 5) { [void]$o.Append($a[($buf -shr ($bits - 5)) -band 31]); $bits -= 5 } }; if ($bits -gt 0) { [void]$o.Append($a[($buf -shl (5 - $bits)) -band 31]) }; $o.ToString() }
# Base32 decoder: ignores spaces and other characters, returns the secret as bytes.
function ConvertFrom-B32([string]$s) { $a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; $s = $s.ToUpper() -replace '[^A-Z2-7]', ''; $out = New-Object Collections.Generic.List[byte]; $buf = 0; $bits = 0; foreach ($c in $s.ToCharArray()) { $buf = (($buf -shl 5) -bor $a.IndexOf($c)) -band 0xFFFF; $bits += 5; if ($bits -ge 8) { $out.Add([byte](($buf -shr ($bits - 8)) -band 255)); $bits -= 8 } }; $out.ToArray() }
# Calculates the 6-digit code for one 30-second time step (RFC 6238 / RFC 4226): HMAC-SHA1 of the step number, then 'dynamic truncation'
# (take 4 bytes at an offset given by the last nibble) and modulo 1,000,000.
function Get-TotpCode([byte[]]$key, [long]$step) {
    $msg = [BitConverter]::GetBytes($step); if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($msg) }
    $h = New-Object Security.Cryptography.HMACSHA1(, $key); try { $hs = $h.ComputeHash($msg) } finally { $h.Dispose() }
    $o = $hs[19] -band 0x0F
    $v = (([int]($hs[$o] -band 0x7F)) -shl 24) -bor (([int]$hs[$o + 1]) -shl 16) -bor (([int]$hs[$o + 2]) -shl 8) -bor ([int]$hs[$o + 3])
    ($v % 1000000).ToString('000000')
}
# the matching time step (now, or 30 s before / after for a slow clock), or -1
# Checks a typed code. Accepts the current step and one step before/after (30 s clock difference). $notBefore blocks re-using an old code.
# Returns the matching step number, or -1 if wrong.
function Test-TotpCode([string]$secret, [string]$code, [long]$notBefore) {
    $code = "$code" -replace '\s', ''; if ($code -notmatch '^\d{6}$') { return -1 }
    $key = ConvertFrom-B32 $secret; $now = [long][Math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 30)
    foreach ($st in ($now - 1), $now, ($now + 1)) { if ($st -gt $notBefore -and (Get-TotpCode $key $st) -eq $code) { return $st } }
    -1
}
# Loads two-step.json into a hashtable: user key -> secret, last used step, set-up date. Returns an empty table if missing or broken.
function Read-Tfa { $h = @{}; if (Test-Path $script:TfaFile) { try { $j = (Read-SecureText $script:TfaFile) | ConvertFrom-Json; foreach ($p in @($j.PSObject.Properties)) { $h[$p.Name] = @{ secret = "$($p.Value.secret)"; last = [long]$p.Value.last; at = "$($p.Value.at)" } } } catch { Write-Host "two-step.json could not be read: $($_.Exception.Message)" -ForegroundColor Yellow } }; $h }
# Saves the two-step table, sorted by user, encrypted.
function Save-Tfa($h) { $o = [ordered]@{}; foreach ($k in ($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }; Write-SecureText $script:TfaFile ($o | ConvertTo-Json -Depth 4) }
# called by /login after the password was accepted. $null = go on; otherwise the answer for the sign-in page.
# Two-step check after the password was accepted. Inputs: user key, display label, isAdmin, request data $d ($d.otp = typed code).
# Returns $null = continue sign-in, or a hashtable answer for the sign-in page (needOtp = ask for code, enroll = show QR/secret to set up).
function Invoke-TfaGate([string]$key, [string]$label, [bool]$isAdmin, $d) {
    $pol = "$($script:SecCfg.tfa)"; $key = $key.ToLower()
    $all = Read-Tfa; $rec = $all[$key]
    # The person already has two-step set up: demand a valid code and remember the used step so the same code cannot be used twice.
    if ($rec) {
        if (-not "$($d.otp)".Trim()) { return @{ ok = $false; needOtp = $true; error = 'Type the 6-digit code from your authenticator app.' } }
        $st = Test-TotpCode $rec.secret "$($d.otp)" $rec.last
        if ($st -lt 0) { return @{ ok = $false; needOtp = $true; bad = $true; error = 'The code is wrong or too old - type the newest code.' } }
        $rec.last = $st; $all[$key] = $rec; Save-Tfa $all; return $null
    }
    # Policy: 'all' = everybody must use two-step, 'admins' = only administrators, 'off' = nobody (not yet set up people just continue).
    $need = ($pol -eq 'all') -or ($pol -eq 'admins' -and $isAdmin)
    if (-not $need) { return $null }
    foreach ($k in @($script:TfaPending.Keys)) { if ($script:TfaPending[$k].until -lt (Get-Date)) { $script:TfaPending.Remove($k) } }
    $p = $script:TfaPending[$key]
    # First time: create a random 20-byte secret (valid for 10 minutes) and keep it in memory until the person proves it works.
    if (-not $p) { $b = New-Object byte[] 20; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); $p = @{ secret = (ConvertTo-B32 $b); until = (Get-Date).AddMinutes(10) }; $script:TfaPending[$key] = $p }
    # otpauth:// address is what the QR code on the sign-in page contains. The secret is also shown in groups of 4 for typing by hand.
    $iss = 'Admin Console'; $uri = "otpauth://totp/$([uri]::EscapeDataString("${iss}:$label"))?secret=$($p.secret)&issuer=$([uri]::EscapeDataString($iss))&digits=6&period=30"
    $ans = @{ ok = $false; enroll = $true; secret = ($p.secret -replace '(.{4})', '$1 ').Trim(); uri = $uri; error = '' }
    if (-not "$($d.otp)".Trim()) { return $ans }
    # Set-up confirmation: the first correct code proves the phone has the secret; only then it is saved permanently.
    $st = Test-TotpCode $p.secret "$($d.otp)" 0
    if ($st -lt 0) { $ans.bad = $true; $ans.error = 'The code is wrong - check the time on your phone and type the newest code.'; return $ans }
    $all[$key] = @{ secret = $p.secret; last = $st; at = (Get-Date).ToString('yyyy-MM-dd HH:mm') }; Save-Tfa $all; $script:TfaPending.Remove($key)
    try { Write-LoginLog $label '2-step sign-in set up (authenticator app)' } catch {}
    $null
}
# Handler /api/sec-tfa-reset. Input $d.key = the person's key. Removes their two-step so they set it up again at next sign-in (lost phone). Sends { ok }.
$ScreenHandlers['/api/sec-tfa-reset'] = {
    $k = "$($d.key)".ToLower(); $all = Read-Tfa; if (-not $all.ContainsKey($k)) { throw 'This person has no 2-step sign-in.' }
    $all.Remove($k); Save-Tfa $all
    Write-ActRow 'Settings' 'Reset 2-step sign-in' $k 'Done' 'They set it up again at their next sign-in'
    Send $ctx @{ ok = $true }
}
# Handler /api/sec-get. No input. Sends the settings plus status info for the screen: your IP, is HTTPS ready, folder permissions (ACL),
# which data files are encrypted, people with two-step, and currently blocked IPs.
$ScreenHandlers['/api/sec-get'] = {
    $c = Get-SecCfg; $hc = $null; try { $hc = Get-Content (Join-Path $Root 'https-settings.json') -Raw | ConvertFrom-Json } catch {}
    $acl = ''; try { $acl = ((Get-Acl -LiteralPath $Root).Access | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" } | Select-Object -Unique) -join "`n" } catch {}
    $enc = @(foreach ($fn in 'tool-users.json', 'people-db.json') { $p = Join-Path $Root $fn; @{ file = $fn; there = (Test-Path $p); encrypted = $(try { [IO.File]::ReadAllText($p).StartsWith('ACENC1:') } catch { $false }) } })
    Send $ctx @{ ok = $true; settings = $c; yourIp = "$($script:ClientIp)"; httpsReady = [bool]($hc -and $hc.port); secureNow = (Test-ReqSecure $ctx); acl = $acl; folder = "$Root"; enc = $enc
                 tfaUsers = @((Read-Tfa).GetEnumerator() | Sort-Object Key | ForEach-Object { @{ key = $_.Key; at = $_.Value.at } }); blocked = @($script:IpFails.GetEnumerator() | Where-Object { $_.Value.until -and (Get-Date) -lt $_.Value.until } | ForEach-Object { @{ ip = $_.Key; until = $_.Value.until.ToString('HH:mm') } }) }
}
# Handler /api/sec-save. Input $d: ipOn, ips[], httpsOnly, ipMaxFails, ipLockMins, tfa, bindIp, force. Validates, saves access-security.json, sends { ok, settings }.
# Protects against self-lock-out: if your own PC is not in the list, or HTTPS is not set up, it answers needForce and saves only when force is sent.
$ScreenHandlers['/api/sec-save'] = {
    $ips = @(@($d.ips) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($r in $ips) { if (-not (Test-IpRuleText $r)) { throw "Not a valid IP address, network or range: $r (examples: 10.1.2.3, 10.1.2.0/24, 10.1.2.10-10.1.2.50)" } }
    # Upper limit for the list size.
    if ($ips.Count -gt 500) { throw 'At most 500 entries.' }
    $on = [bool]$d.ipOn
    if ($on -and -not $ips.Count) { throw 'Add at least one allowed IP address, or switch the IP list off.' }
    $me = "$($script:ClientIp)"
    if ($on -and -not (Test-IsLoopback $me)) { $hit = $false; foreach ($r in $ips) { if (Test-IpRule $me $r) { $hit = $true } }; if (-not $hit -and -not $d.force) { Send $ctx @{ ok = $false; needForce = $true; error = "Your own PC ($me) is not in the list - you would lock yourself out. Add it, or save anyway (you can still change it on the server itself, http://localhost)." }; return } }
    $hs = [bool]$d.httpsOnly
    if ($hs) { $hc = $null; try { $hc = Get-Content (Join-Path $Root 'https-settings.json') -Raw | ConvertFrom-Json } catch {}; if (-not ($hc -and $hc.port) -and -not $d.force) { Send $ctx @{ ok = $false; needForce = $true; error = 'HTTPS is not set up on this portal yet (Settings > HTTPS / SSL certificate). Other PCs could not open the portal at all - unless IIS gives them HTTPS. Save anyway?' }; return } }
    # Keep the numbers in a sane range: failures before blocking 5-1000 (default 20), block time 1-1440 minutes (default 15).
    $mf = [Math]::Max(5, [Math]::Min(1000, [int]$(if ($d.ipMaxFails) { $d.ipMaxFails } else { 20 }))); $lm = [Math]::Max(1, [Math]::Min(1440, [int]$(if ($d.ipLockMins) { $d.ipLockMins } else { 15 })))
    $tf = "$($d.tfa)"; if ($tf -notin 'off', 'admins', 'all') { $tf = 'off' }
    $c = [ordered]@{ ipOn = $on; ips = $ips; httpsOnly = $hs; ipMaxFails = $mf; ipLockMins = $lm; tfa = $tf; bindIp = [bool]$d.bindIp }
    ($c | ConvertTo-Json -Depth 4) | Out-File $script:SecFile -Encoding utf8
    $script:SecCfg = Get-SecCfg
    Write-ActRow 'Settings' 'Access and security saved' '' 'Done' ("IP list " + $(if ($on) { "on ($($ips.Count))" } else { 'off' }) + "; HTTPS only $hs; 2-step $tf; session tied to IP $([bool]$d.bindIp)")
    Send $ctx @{ ok = $true; settings = $script:SecCfg }
}
# Handler /api/sec-unblock. Input $d.ip = one IP to unblock; empty = unblock all. Sends { ok }.
$ScreenHandlers['/api/sec-unblock'] = {
    $ip = "$($d.ip)"; if ($ip) { $script:IpFails.Remove($ip) } else { $script:IpFails.Clear() }
    Write-ActRow 'Settings' 'Unblocked IP' $ip 'Done' ''; Send $ctx @{ ok = $true }
}
# Handler /api/sec-lockfolder. Input $d.confirm must be the word LOCK. Sets folder permissions with icacls: removes inherited rights and gives full control only to
# Administrators, SYSTEM and the account running the portal. Sends { ok, who }.
$ScreenHandlers['/api/sec-lockfolder'] = {
    # only Administrators, SYSTEM and the account the portal runs as can open the tool folder (settings, users, logs, backups)
    if ("$($d.confirm)" -ne 'LOCK') { throw 'Type LOCK to confirm.' }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # icacls SIDs: S-1-5-32-544 = Administrators, S-1-5-18 = SYSTEM. /T = all sub-folders, /C = continue on errors, /Q = quiet.
    $out = & icacls.exe "$Root" /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "${me}:(OI)(CI)F" /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $($out -join ' ')" }
    Write-ActRow 'Settings' 'Folder locked' "$Root" 'Done' "Administrators, SYSTEM, $me"
    Send $ctx @{ ok = $true; who = $me }
}

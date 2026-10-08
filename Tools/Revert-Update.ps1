# Revert-Update.ps1 - puts back the newest saved version (backups\) when the tool does not start after an update.
# Run Revert-Update.bat as administrator. Your settings and logs are not touched.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$bak = Get-ChildItem -LiteralPath (Join-Path $Root 'backups') -Filter 'AdminConsole-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if (-not $bak) { Write-Host 'No saved version found in the backups folder.' -ForegroundColor Yellow; exit 1 }
$i = 0; $bak | Select-Object -First 10 | ForEach-Object { $i++; Write-Host ("{0}. {1}  ({2:yyyy-MM-dd HH:mm})" -f $i, $_.Name, $_.LastWriteTime) }
$c = Read-Host 'Number of the version to put back (Enter = 1)'; if (-not $c) { $c = 1 }
$pick = @($bak)[[int]$c - 1]; if (-not $pick) { Write-Host 'Not a valid number.'; exit 1 }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'server\.ps1' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
$z = [IO.Compression.ZipFile]::OpenRead($pick.FullName); $n = 0
try {
    foreach ($e in @($z.Entries | Where-Object { $_.Name })) {
        $rel = $e.FullName -replace '\\', '/'
        if ($rel -match '^(logs|DistributionGroups|email-images|backups|updates)/' -or ($rel -notmatch '/' -and $rel -match '\.json$')) { continue }
        $to = Join-Path $Root $rel; $dir = Split-Path $to -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $to, $true); $n++
    }
} finally { $z.Dispose() }
Write-Host "Put back $n files from $($pick.Name). Start the tool again with Start.bat." -ForegroundColor Green

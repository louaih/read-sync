<#
  Install.ps1  -  run once on each PC (desktop and laptop).
  Right-click > Run with PowerShell, or:  powershell -ExecutionPolicy Bypass -File Install.ps1
  Safe to re-run: it overwrites the config and restarts the background job cleanly.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Join-Path $env:LOCALAPPDATA 'ReadingSync'
New-Item -ItemType Directory -Path $appDir -Force | Out-Null

function Ask([string]$prompt, [string]$default) {
    $v = Read-Host "$prompt`n  [$default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v.Trim('"', ' ')
}

function ConvertTo-SafeMachineName([string]$n) {
    if ([string]::IsNullOrWhiteSpace($n)) { return 'PC' }
    $safe = ($n.Trim() -replace '[^A-Za-z0-9_\-]', '_')
    if ($safe -eq '') { return 'PC' }
    return $safe
}

function Test-PathNested([string]$maybeChild, [string]$maybeParent) {
    $child = (($maybeChild.Trim() -replace '/', '\').TrimEnd('\') + '\').ToLowerInvariant()
    $parent = (($maybeParent.Trim() -replace '/', '\').TrimEnd('\') + '\').ToLowerInvariant()
    return $child.StartsWith($parent)
}

Write-Host "`n=== Reading Sync setup ===`n" -ForegroundColor Cyan

# calibre library: read calibre's own setting as the default
$libDefault = ''
$calCfg = Join-Path $env:APPDATA 'calibre\global.py.json'
if (Test-Path $calCfg) {
    try { $libDefault = (Get-Content $calCfg -Raw | ConvertFrom-Json).library_path } catch { }
}
do {
    $lib = Ask 'calibre library folder (must be inside your synced folder, e.g. OneDrive)' $libDefault
    if ([string]::IsNullOrWhiteSpace($lib) -or -not (Test-Path -LiteralPath $lib)) {
        Write-Warning "That folder doesn't exist. Enter the path to your calibre library folder."
        $lib = $null
        continue
    }
    if (-not (Test-Path (Join-Path $lib 'metadata.db'))) {
        Write-Warning "No metadata.db found in '$lib'. Make sure this is the calibre library folder, not just any folder."
    }
    $libDefault = $lib
} while (-not $lib)

# sync folder for progress files: default to a folder next to the library
$syncDefault = Join-Path (Split-Path $lib -Parent) 'ReadingSync'
do {
    $sync = Ask 'Folder for reading-progress files (also synced; keep it OUTSIDE the calibre library)' $syncDefault
    if (Test-PathNested $sync $lib) {
        Write-Warning "That folder is inside the calibre library. Pick a folder next to it instead, not inside it."
        $syncDefault = $sync
        $sync = $null
    }
} while (-not $sync)
New-Item -ItemType Directory -Path $sync -Force | Out-Null

# SumatraPDF settings: installed or portable
$sumDefault = Join-Path $env:LOCALAPPDATA 'SumatraPDF\SumatraPDF-settings.txt'
if (-not (Test-Path $sumDefault)) {
    $exe = Get-Command SumatraPDF.exe -ErrorAction SilentlyContinue
    if ($exe) {
        $p = Join-Path (Split-Path $exe.Source) 'SumatraPDF-settings.txt'
        if (Test-Path $p) { $sumDefault = $p }
    }
}
$sum = Ask 'SumatraPDF settings file (portable installs keep it next to SumatraPDF.exe)' $sumDefault
if (-not (Test-Path $sum)) { Write-Warning "Settings file not found yet. That's fine - it will be created once SumatraPDF opens a book, or the first time a position is pulled from your other PC." }

$name = ConvertTo-SafeMachineName (Ask 'Name for this PC (must differ between your PCs)' $env:COMPUTERNAME)

# Optional: show reading progress inside calibre as a custom column (e.g. "71%").
# Off by default. Writing to metadata.db carries the same conflict risk as running
# calibre on two PCs at once, so this is only set up when calibre looks closed right
# now, and the background script itself refuses to write to it whenever calibre
# looks like it might be open, on this PC or recently on the other one.
$enableProgress = (Ask 'Show reading progress inside calibre as a column? (y/N)' 'N') -match '^(y|yes)$'
$calibreDb = $null
$progressLabel = 'progress'
if ($enableProgress) {
    $cdbCmd = Get-Command calibredb.exe -ErrorAction SilentlyContinue
    $cdb = if ($cdbCmd) { $cdbCmd.Source } else { $null }
    if (-not $cdb) {
        foreach ($p in @(
            (Join-Path $env:ProgramFiles 'Calibre2\calibredb.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Calibre2\calibredb.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\calibre\calibredb.exe')
        )) { if (Test-Path $p) { $cdb = $p; break } }
    }
    if (-not $cdb) {
        Write-Warning "Could not find calibredb.exe. Skipping the progress column; re-run this installer once calibre is installed if you want it."
        $enableProgress = $false
    } elseif (Get-Process calibre -ErrorAction SilentlyContinue) {
        Write-Warning "calibre is running right now. Close it and re-run this installer to set up the progress column (the same reason this tool never writes to Sumatra's settings while Sumatra is running applies here too)."
        $enableProgress = $false
    } else {
        $calibreDb = $cdb
        $existing = & $calibreDb custom_columns --library-path $lib 2>$null
        if (-not ($existing -match "^\s*$([regex]::Escape($progressLabel))\s*\(")) {
            Write-Host "Creating the '$progressLabel' custom column in calibre..."
            & $calibreDb add_custom_column $progressLabel 'Reading Progress' text --library-path $lib | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not create the column automatically. You can add it yourself in calibre (Preferences > Add your own columns), as a Text column with lookup name '$progressLabel', or re-run this installer."
                $enableProgress = $false
            }
        }
    }
}

$cfg = [ordered]@{
    LibraryRoot          = $lib
    SyncDir              = $sync
    SumatraSettings      = $sum
    SumatraProcess       = 'SumatraPDF*'
    MachineName          = $name
    EnableProgressColumn = $enableProgress
    CalibreDb            = $calibreDb
    ProgressColumnLabel  = $progressLabel
    ProgressUpdateMinutes = 1
}
$cfg | ConvertTo-Json | Set-Content (Join-Path $appDir 'config.json') -Encoding UTF8

Copy-Item (Join-Path $here 'ReadingSync.ps1') $appDir -Force

# Prefer PowerShell 7 if it's installed, otherwise fall back to Windows PowerShell 5.1
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$psExeName = if ($pwsh) { 'pwsh.exe' } else { 'powershell.exe' }
$psExePath = if ($pwsh) { $pwsh.Source } else { (Get-Command powershell.exe).Source }

# Start hidden at logon via the Startup folder (no admin rights needed)
$vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'ReadingSync.vbs'
$script = Join-Path $appDir 'ReadingSync.ps1'
@"
CreateObject("WScript.Shell").Run "$psExePath -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$script""", 0, False
"@ | Set-Content $vbs -Encoding ASCII

# Stop any old copy (installed by this script before, under either PowerShell host), start the new one now
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -like '*ReadingSync.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process wscript.exe -ArgumentList "`"$vbs`""

Write-Host "`nInstalled (using $psExeName). Running in the background now and at every logon." -ForegroundColor Green
Write-Host "Log: $appDir\ReadingSync.log"
if ($enableProgress) { Write-Host "Progress column: on (column '$progressLabel' in calibre)." }
Write-Host "Now repeat on your other PC.`n"
Read-Host 'Press Enter to close'

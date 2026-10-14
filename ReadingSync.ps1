<#
  ReadingSync.ps1
  Syncs SumatraPDF reading positions for books in a (synced) calibre library
  between Windows machines. Each machine writes only its own progress file in
  the shared sync folder, so the sync tool never has to merge one file from
  two machines.

  Runs as a background loop (started at logon by Install.ps1), or once with -Once.
  Compatible with Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'ReadingSync\config.json'),
    [switch]$Once,
    [int]$IntervalSeconds = 15,
    [int]$RecheckMinutes = 5,
    # Dot-source with -NoAutoStart to load the functions below for testing
    # without reading a config file or starting the main loop.
    [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- utilities

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Verbose $line
    if ($script:LogPath) {
        try {
            if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 1MB) {
                Move-Item $script:LogPath "$($script:LogPath).old" -Force
            }
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        } catch { }
    }
}

function ConvertTo-Hashtable($obj) {
    # PS 5.1 has no ConvertFrom-Json -AsHashtable
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) { return $obj }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
        return @($obj | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    return $obj
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $txt = [IO.File]::ReadAllText($path)
            if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
            return ConvertTo-Hashtable ($txt | ConvertFrom-Json)
        } catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Log "Could not read JSON: $path"
    return $null
}

function Write-JsonFile([string]$path, $data) {
    $json = $data | ConvertTo-Json -Depth 6
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-NowStamp { (Get-Date).ToUniversalTime().ToString('o') }

function To-Utc($v) {
    # PS7's ConvertFrom-Json turns ISO strings into DateTime; PS5.1 leaves strings.
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    if ($null -eq $v -or "$v" -eq '') { return [datetime]::MinValue }
    return [DateTimeOffset]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function Normalize-Path([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    return ($p.Trim() -replace '/', '\').TrimEnd('\').ToLowerInvariant()
}

# ------------------------------------------------- book identity (calibre)
# calibre stores each book as  <Library>\<Author>\<Title> (<id>)\<file>.pdf
# The numeric id lives in metadata.db, which is itself synced, so it is the same
# on both machines even if the library sits at a different path on each one.

function Get-BookKey([string]$filePath, [string]$libraryRoot) {
    $f = Normalize-Path $filePath
    $root = (Normalize-Path $libraryRoot) + '\'
    if (-not $f.StartsWith($root)) { return $null }
    $rel = $f.Substring($root.Length)
    $parts = $rel.Split('\')
    if ($parts.Count -ne 3) { return $null }
    if ($parts[1] -notmatch '\((\d+)\)$') { return $null }
    $ext = [IO.Path]::GetExtension($parts[2]).TrimStart('.')
    return "calibre:$($Matches[1]):$ext"
}

function Resolve-BookPath([string]$key, [string]$libraryRoot) {
    # Find the file for a key on this machine by scanning the library folders.
    if ($key -notmatch '^calibre:(\d+):(\w+)$') { return $null }
    $id = $Matches[1]; $ext = $Matches[2]
    if (-not $script:FolderIndex -or ((Get-Date) - $script:FolderIndexTime).TotalMinutes -gt 5) {
        $script:FolderIndex = @{}
        Get-ChildItem -LiteralPath $libraryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -match '\((\d+)\)$') { $script:FolderIndex[$Matches[1]] = $_.FullName }
            }
        }
        $script:FolderIndexTime = Get-Date
    }
    $dir = $script:FolderIndex[$id]
    if (-not $dir) { return $null }
    $file = Get-ChildItem -LiteralPath $dir -File -Filter "*.$ext" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

# ------------------------------------------------- SumatraPDF settings file
# The file is a nested text format:
#   FileStates [
#   	[
#   		FilePath = C:\...\book.pdf
#   		PageNo = 57
#   		...
#   	]
#   ]
# We touch only the FileStates block and only the position fields, leaving
# every other line exactly as Sumatra wrote it.

$script:PositionFields = @('PageNo', 'ScrollPos', 'Zoom', 'Rotation', 'DisplayMode')

function Read-SumatraSettings([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($l in ($text -split "`r?`n")) { $lines.Add($l) }
    return @{ Lines = $lines; Bom = $hasBom; NewLine = $nl }
}

function Save-SumatraSettings([string]$path, $settings) {
    $text = [string]::Join($settings.NewLine, $settings.Lines)
    $enc = New-Object Text.UTF8Encoding($settings.Bom)
    Copy-Item -LiteralPath $path -Destination "$path.readingsync.bak" -Force
    [IO.File]::WriteAllText($path, $text, $enc)
}

function Find-FileStatesBlock($lines) {
    # returns @(startIndex, endIndex) of the "FileStates [" ... "]" lines, or $null
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^FileStates \[\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $depth = 0
    for ($j = $start; $j -lt $lines.Count; $j++) {
        $t = $lines[$j].Trim()
        if ($t.EndsWith('[')) { $depth++ }
        elseif ($t -eq ']') { $depth--; if ($depth -eq 0) { return @($start, $j) } }
    }
    return $null
}

function Get-FileStateEntries($lines) {
    # returns list of @{ Start; End; Fields(hashtable name->lineIndex); Values }
    $entries = @()
    $block = Find-FileStatesBlock $lines
    if (-not $block) { return $entries }
    $depth = 0; $cur = $null
    for ($i = $block[0] + 1; $i -lt $block[1]; $i++) {
        $t = $lines[$i].Trim()
        if ($t.EndsWith('[')) {
            $depth++
            if ($depth -eq 1) { $cur = @{ Start = $i; Fields = @{}; Values = @{} } }
            continue
        }
        if ($t -eq ']') {
            if ($depth -eq 1 -and $cur) { $cur.End = $i; $entries += $cur; $cur = $null }
            $depth--
            continue
        }
        if ($depth -eq 1 -and $cur -and $t -match '^(\w+) = ?(.*)$') {
            $cur.Fields[$Matches[1]] = $i
            $cur.Values[$Matches[1]] = $Matches[2]
        }
    }
    return $entries
}

function Get-SumatraPositions([string]$settingsPath, [string]$libraryRoot) {
    # key -> @{ PageNo=..; ScrollPos=..; ... }
    $result = @{}
    $s = Read-SumatraSettings $settingsPath
    foreach ($e in (Get-FileStateEntries $s.Lines)) {
        $key = Get-BookKey $e.Values['FilePath'] $libraryRoot
        if (-not $key -or $result.ContainsKey($key)) { continue }   # first entry = most recent
        if ($e.Values['UseDefaultState'] -eq 'true') { continue }
        $pos = @{}
        foreach ($f in $script:PositionFields) { if ($e.Values.ContainsKey($f)) { $pos[$f] = $e.Values[$f] } }
        if ($pos.ContainsKey('PageNo')) { $result[$key] = $pos }
    }
    return $result
}

function Set-SumatraPositions([string]$settingsPath, [string]$libraryRoot, $updates) {
    # $updates: key -> @{ Path = <local file>; Pos = @{...} }
    if ($updates.Count -eq 0) { return 0 }
    $s = Read-SumatraSettings $settingsPath
    $lines = $s.Lines
    $done = @{}
    $entries = Get-FileStateEntries $lines
    # Edit existing entries bottom-up so inserted lines don't shift later indexes.
    $sorted = $entries | Sort-Object { $_.Start } -Descending
    foreach ($e in $sorted) {
        $key = Get-BookKey $e.Values['FilePath'] $libraryRoot
        if (-not $key -or -not $updates.ContainsKey($key)) { continue }
        $pos = $updates[$key].Pos
        $indent = "`t`t"
        if ($e.Fields.Count -gt 0) {
            $first = $lines[($e.Fields.Values | Measure-Object -Minimum).Minimum]
            $indent = $first.Substring(0, $first.Length - $first.TrimStart().Length)
        }
        foreach ($f in $script:PositionFields) {
            if (-not $pos.ContainsKey($f)) { continue }
            if ($e.Fields.ContainsKey($f)) { $lines[$e.Fields[$f]] = "$indent$f = $($pos[$f])" }
            else { $lines.Insert($e.End, "$indent$f = $($pos[$f])") }
        }
        if ($e.Fields.ContainsKey('UseDefaultState')) { $lines[$e.Fields['UseDefaultState']] = "${indent}UseDefaultState = false" }
        if ($e.Fields.ContainsKey('IsMissing')) { $lines[$e.Fields['IsMissing']] = "${indent}IsMissing = false" }
        $done[$key] = $true
    }
    # Books Sumatra has never opened on this machine: add a new entry at the top.
    $new = @()
    foreach ($key in $updates.Keys) {
        if ($done.ContainsKey($key)) { continue }
        $u = $updates[$key]
        $new += "`t["
        $new += "`t`tFilePath = $($u.Path)"
        $new += "`t`tIsMissing = false"
        $new += "`t`tUseDefaultState = false"
        foreach ($f in $script:PositionFields) { if ($u.Pos.ContainsKey($f)) { $new += "`t`t$f = $($u.Pos[$f])" } }
        $new += "`t]"
        $done[$key] = $true
    }
    if ($new.Count -gt 0) {
        $block = Find-FileStatesBlock $lines
        if ($block) {
            $lines.InsertRange($block[0] + 1, [string[]]$new)
        } else {
            $lines.Add('FileStates [')
            $lines.AddRange([string[]]$new)
            $lines.Add(']')
        }
    }
    Save-SumatraSettings $settingsPath $s
    return $done.Count
}

# --------------------------------------------------------- sync logic

function Test-ProcessRunning([string]$pattern) {
    return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like $pattern })
}

function Same-Pos($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return $false }
    foreach ($f in $script:PositionFields) { if ("$($a[$f])" -ne "$($b[$f])") { return $false } }
    return $true
}

function ConvertTo-SafeMachineName([string]$n) {
    # Used as a literal filename component (progress-<name>.json), so keep it to a
    # charset every sync tool treats as a plain filename.
    if ([string]::IsNullOrWhiteSpace($n)) { return 'PC' }
    $safe = ($n.Trim() -replace '[^A-Za-z0-9_\-]', '_')
    if ($safe -eq '') { return 'PC' }
    return $safe
}

function Get-MyFile($cfg) { Join-Path $cfg.SyncDir ("progress-{0}.json" -f $cfg.MachineName) }

function Get-OtherProgressFiles($cfg) {
    # Only exact "progress-<safe-name>.json" files count. This deliberately excludes
    # sync-tool conflict copies such as "progress-DESKTOP (1).json" (OneDrive/Google
    # Drive) or "progress-DESKTOP.sync-conflict-20260101-120000-LAPTOP.json" (Syncthing),
    # which must never be read as if they were a real machine's state.
    $mine = 'progress-{0}.json' -f $cfg.MachineName
    Get-ChildItem -LiteralPath $cfg.SyncDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^progress-[A-Za-z0-9_\-]+\.json$' -and $_.Name -ne $mine }
}

function Load-MyState($cfg) {
    $d = Read-JsonFile (Get-MyFile $cfg)
    if (-not $d) { $d = @{ machine = $cfg.MachineName; books = @{} } }
    if (-not $d.books) { $d.books = @{} }
    return $d
}

function Invoke-Push($cfg) {
    # Record any position that changed in Sumatra since we last looked.
    $local = Get-SumatraPositions $cfg.SumatraSettings $cfg.LibraryRoot
    $mine = Load-MyState $cfg
    $changed = 0
    # Stamp with when Sumatra actually saved the position, not when we noticed it,
    # so an old position found on first run can't beat a newer one from another PC.
    $stamp = (Get-Item -LiteralPath $cfg.SumatraSettings).LastWriteTimeUtc.ToString('o')
    foreach ($key in $local.Keys) {
        $prev = $mine.books[$key]
        if ($prev -and (Same-Pos $prev.pos $local[$key])) { continue }
        $mine.books[$key] = @{ pos = $local[$key]; ts = $stamp; from = $cfg.MachineName }
        $changed++
    }
    if ($changed -gt 0) {
        $mine.updated = Get-NowStamp
        Write-JsonFile (Get-MyFile $cfg) $mine
        Write-Log "Pushed $changed updated position(s)"
    }
    return $changed
}

function Invoke-Pull($cfg) {
    # Apply newer positions from other machines. Only call while Sumatra is closed,
    # otherwise Sumatra overwrites the settings file when it exits.
    $mine = Load-MyState $cfg
    $updates = @{}
    $adopt = @{}
    $nowUtc = (Get-Date).ToUniversalTime()
    foreach ($f in (Get-OtherProgressFiles $cfg)) {
        $d = Read-JsonFile $f.FullName
        if (-not $d -or -not $d.books) { continue }
        foreach ($key in $d.books.Keys) {
            $theirs = $d.books[$key]
            if (-not $theirs -or -not $theirs.ts -or -not $theirs.pos) { continue }
            $theirsUtc = To-Utc $theirs.ts
            if (($theirsUtc - $nowUtc).TotalMinutes -gt 5) {
                Write-Log ("WARNING: {0} has a timestamp {1:N0} minute(s) in the future for {2} (clock skew?)" -f $f.Name, ($theirsUtc - $nowUtc).TotalMinutes, $key)
            }
            $ours = $mine.books[$key]
            $best = $adopt[$key]
            if ($best -and (To-Utc $best.ts) -ge $theirsUtc) { continue }
            if ($ours -and (To-Utc $ours.ts) -ge $theirsUtc) { continue }
            if ($ours -and (Same-Pos $ours.pos $theirs.pos)) { continue }
            $adopt[$key] = $theirs
        }
    }
    foreach ($key in $adopt.Keys) {
        $path = Resolve-BookPath $key $cfg.LibraryRoot
        if (-not $path) { continue }   # book hasn't synced to this machine yet; try later
        $updates[$key] = @{ Path = $path; Pos = $adopt[$key].pos }
    }
    if ($updates.Count -eq 0) { return 0 }
    if (-not (Test-Path -LiteralPath $cfg.SumatraSettings)) {
        # Sumatra has never run on this machine yet, so there's nothing to edit.
        # Seed a minimal settings file so the pulled position can still be written;
        # Sumatra fills in every other field with its defaults on next launch.
        New-Item -ItemType Directory -Path (Split-Path $cfg.SumatraSettings) -Force -ErrorAction SilentlyContinue | Out-Null
        [IO.File]::WriteAllText($cfg.SumatraSettings, "FileStates [`r`n]`r`n", (New-Object Text.UTF8Encoding($false)))
        Write-Log "Seeded a new SumatraPDF-settings.txt (Sumatra had never run on this machine)"
    }
    $n = Set-SumatraPositions $cfg.SumatraSettings $cfg.LibraryRoot $updates
    # Remember what we adopted (keeping its original timestamp) so the next push
    # doesn't treat it as a fresh local change.
    foreach ($key in $updates.Keys) { $mine.books[$key] = $adopt[$key] }
    $mine.updated = Get-NowStamp
    Write-JsonFile (Get-MyFile $cfg) $mine
    Write-Log "Pulled $n position(s) from other machine(s)"
    return $n
}

function Update-Heartbeat($cfg) {
    # Lets the other machine warn if calibre is open on both at once.
    $open = Test-ProcessRunning 'calibre'
    $path = Join-Path $cfg.SyncDir ("status-{0}.json" -f $cfg.MachineName)
    if ($open -ne $script:LastCalibreOpen -or ((Get-Date) - $script:LastHeartbeat).TotalSeconds -gt 60) {
        Write-JsonFile $path @{ machine = $cfg.MachineName; calibreOpen = $open; ts = (Get-NowStamp) }
        $script:LastHeartbeat = Get-Date
    }
    if ($open -and -not $script:LastCalibreOpen) {
        $other = Get-ChildItem -LiteralPath $cfg.SyncDir -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^status-[A-Za-z0-9_\-]+\.json$' -and $_.Name -ne ('status-{0}.json' -f $cfg.MachineName) } |
                 ForEach-Object { Read-JsonFile $_.FullName } |
                 Where-Object { $_ -and $_.calibreOpen -and ((Get-Date).ToUniversalTime() - (To-Utc $_.ts)).TotalMinutes -lt 3 }
        if ($other) {
            $names = ($other | ForEach-Object { $_.machine }) -join ', '
            Write-Log "WARNING: calibre also open on $names"
            try {
                Add-Type -AssemblyName System.Windows.Forms
                [void][System.Windows.Forms.MessageBox]::Show(
                    "calibre looks like it is also open on $names.`n`nClose it there before making changes here, or the library database can end up with a sync conflict.",
                    'Reading Sync', 'OK', 'Warning')
            } catch { }
        }
    }
    $script:LastCalibreOpen = $open
}

# -------------------------------------------------- optional: calibre progress column
# Off unless Install.ps1 was told to enable it (cfg.EnableProgressColumn). Writes a
# short text summary (e.g. "71%", or "p. 57" when the total page count can't be
# determined) into a custom calibre column via calibredb, so progress is visible in
# calibre's own book list. This never runs while calibre looks like it might be open
# on this PC or recently on the other one, and is throttled, to limit how often (and
# how riskily) it touches metadata.db. If it's off, fails, or calibredb is missing,
# the Sumatra position sync above is completely unaffected.

function Get-CalibreBookId([string]$key) {
    if ($key -match '^calibre:(\d+):') { return $Matches[1] }
    return $null
}

function Get-PdfPageCountBestEffort([string]$path) {
    # Best-effort only: scans for an uncompressed Pages-tree "/Count" entry. PDFs that
    # store their object/cross-reference data in compressed streams (common from many
    # modern PDF producers) won't match; we deliberately return $null rather than
    # guess, so the caller falls back to showing just the current page.
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        $text = [Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes)
        $counts = New-Object System.Collections.Generic.List[int]
        foreach ($m in [regex]::Matches($text, '/Type\s*/Pages\b[^>]{0,400}?/Count\s+(\d+)')) { $counts.Add([int]$m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($text, '/Count\s+(\d+)[^>]{0,400}?/Type\s*/Pages\b')) { $counts.Add([int]$m.Groups[1].Value) }
        if ($counts.Count -eq 0) { return $null }
        return ($counts | Measure-Object -Maximum).Maximum
    } catch { return $null }
}

function Test-CalibreSafeToWrite($cfg) {
    if (Test-ProcessRunning 'calibre') { return $false }
    $recent = Get-ChildItem -LiteralPath $cfg.SyncDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^status-[A-Za-z0-9_\-]+\.json$' -and $_.Name -ne ('status-{0}.json' -f $cfg.MachineName) } |
        ForEach-Object { Read-JsonFile $_.FullName } |
        Where-Object { $_ -and $_.calibreOpen -and ((Get-Date).ToUniversalTime() - (To-Utc $_.ts)).TotalMinutes -lt 3 }
    return -not $recent
}

function Invoke-CalibreDb($cfg, [string[]]$dbArgs) {
    try {
        $out = & $cfg.CalibreDb @dbArgs '--library-path' $cfg.LibraryRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "calibredb $($dbArgs -join ' ') failed: $out"
            return $false
        }
        return $true
    } catch {
        Write-Log "calibredb $($dbArgs -join ' ') threw: $($_.Exception.Message)"
        return $false
    }
}

function Update-CalibreProgress($cfg) {
    if (-not $cfg.EnableProgressColumn -or -not $cfg.CalibreDb) { return }
    $minutes = if ($cfg.ProgressUpdateMinutes) { $cfg.ProgressUpdateMinutes } else { 1 }
    if ($script:LastProgressUpdate -and ((Get-Date) - $script:LastProgressUpdate).TotalMinutes -lt $minutes) { return }
    $script:LastProgressUpdate = Get-Date
    if (-not (Test-CalibreSafeToWrite $cfg)) { return }

    $mine = Load-MyState $cfg
    $label = if ($cfg.ProgressColumnLabel) { $cfg.ProgressColumnLabel } else { 'progress' }
    $dirty = $false
    foreach ($key in @($mine.books.Keys)) {
        $book = $mine.books[$key]
        $id = Get-CalibreBookId $key
        if (-not $id -or -not $book.pos -or -not $book.pos.PageNo) { continue }
        $path = Resolve-BookPath $key $cfg.LibraryRoot
        if (-not $path) { continue }
        if (-not $book.pageCount) {
            $book.pageCount = Get-PdfPageCountBestEffort $path
            $dirty = $true
        }
        $page = [int]$book.pos.PageNo
        $text = if ($book.pageCount -and $book.pageCount -gt 0) {
            $pct = [math]::Round((100.0 * $page / $book.pageCount), 0)
            "$pct%"
        } else {
            "p. $page"
        }
        if ($book.progressText -eq $text) { continue }
        if (Invoke-CalibreDb $cfg @('set_custom', $label, $id, $text)) {
            $book.progressText = $text
            $dirty = $true
        }
    }
    if ($dirty) { Write-JsonFile (Get-MyFile $cfg) $mine }
}

# ------------------------------------------------------------------ main

function Start-ReadingSync {
    $cfg = Read-JsonFile $ConfigPath
    if (-not $cfg) { throw "Config not found at $ConfigPath. Run Install.ps1 first." }
    $script:LogPath = Join-Path (Split-Path $ConfigPath) 'ReadingSync.log'
    if (-not $cfg.MachineName) { $cfg.MachineName = $env:COMPUTERNAME }
    $cfg.MachineName = ConvertTo-SafeMachineName $cfg.MachineName
    if (-not (Test-Path -LiteralPath $cfg.SyncDir)) { New-Item -ItemType Directory -Path $cfg.SyncDir -Force | Out-Null }

    $script:LastHeartbeat = [datetime]::MinValue
    $script:LastCalibreOpen = $false
    $lastSettingsWrite = [datetime]::MinValue
    $lastRemoteWrite = [datetime]::MinValue
    $lastPeriodicPull = [datetime]::MinValue
    $sumatraWasRunning = $false
    Write-Log "Started (library: $($cfg.LibraryRoot); sync: $($cfg.SyncDir))"

    do {
        try {
            $sumatraRunning = Test-ProcessRunning $cfg.SumatraProcess

            if (Test-Path -LiteralPath $cfg.SumatraSettings) {
                $w = (Get-Item -LiteralPath $cfg.SumatraSettings).LastWriteTimeUtc
                if ($w -ne $lastSettingsWrite -or ($sumatraWasRunning -and -not $sumatraRunning)) {
                    Invoke-Push $cfg | Out-Null
                    $lastSettingsWrite = (Get-Item -LiteralPath $cfg.SumatraSettings).LastWriteTimeUtc
                }
            }

            if (-not $sumatraRunning) {
                $remote = Get-OtherProgressFiles $cfg | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                $rw = if ($remote) { $remote.LastWriteTimeUtc } else { [datetime]::MinValue }
                # Re-check periodically even with no new remote write, so a book whose
                # PDF arrives late (file sync lags behind the progress-file sync) still
                # gets its pulled position applied once it shows up in the library.
                $duePeriodic = ((Get-Date) - $lastPeriodicPull).TotalMinutes -ge $RecheckMinutes
                if ($rw -ne $lastRemoteWrite -or $duePeriodic) {
                    if ((Invoke-Pull $cfg) -gt 0) {
                        $lastSettingsWrite = (Get-Item -LiteralPath $cfg.SumatraSettings).LastWriteTimeUtc
                    }
                    $lastRemoteWrite = $rw
                    if ($duePeriodic) { $lastPeriodicPull = Get-Date }
                }
            }

            Update-Heartbeat $cfg
            Update-CalibreProgress $cfg
            $sumatraWasRunning = $sumatraRunning
        } catch {
            Write-Log "Error: $($_.Exception.Message)"
        }
        if (-not $Once) { Start-Sleep -Seconds $IntervalSeconds }
    } while (-not $Once)
}

if (-not $NoAutoStart) { Start-ReadingSync }

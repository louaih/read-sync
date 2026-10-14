<#
  Test-ReadingSync.ps1
  Self-contained test suite for ReadingSync.ps1. No Pester dependency.

  Builds two fake "PCs" (PC-A, PC-B) under a temp folder, each with its own
  calibre-library path, a realistic SumatraPDF-settings.txt, and its own config
  hashtable, sharing one sync folder - then drives the real push/pull functions
  from ReadingSync.ps1 (dot-sourced, not reimplemented) and asserts on the
  resulting files.

  Usage:  powershell -File tests\Test-ReadingSync.ps1
          pwsh       -File tests\Test-ReadingSync.ps1
  Exit code 0 = all passed, 1 = at least one failure.
#>
[CmdletBinding()]
param(
    [switch]$NoReexec   # internal: prevents infinite re-exec when spawning the other PS edition
)

$ErrorActionPreference = 'Stop'
$scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot -ErrorAction SilentlyContinue) 'ReadingSync.ps1'
if (-not (Test-Path $scriptUnderTest)) { $scriptUnderTest = Join-Path (Split-Path -Parent $PSCommandPath) '..\ReadingSync.ps1' }
$scriptUnderTest = (Resolve-Path $scriptUnderTest).Path

Write-Host "Testing: $scriptUnderTest"
Write-Host "Edition: $($PSVersionTable.PSEdition)  Version: $($PSVersionTable.PSVersion)`n"

. $scriptUnderTest -NoAutoStart -Once

# ----------------------------------------------------------------- framework

$script:Pass = 0
$script:Fail = 0
$script:FailMessages = New-Object System.Collections.Generic.List[string]
$script:CurrentTest = ''

function Assert($cond, [string]$msg) {
    if ($cond) { $script:Pass++ }
    else {
        $script:Fail++
        $full = "[$script:CurrentTest] $msg"
        $script:FailMessages.Add($full)
        Write-Host "  FAIL: $msg" -ForegroundColor Red
    }
}

function Assert-Equal($expected, $actual, [string]$msg) {
    Assert ($expected -eq $actual) "$msg (expected [$expected], got [$actual])"
}

function Should-NotThrow([scriptblock]$body, [string]$msg) {
    try { & $body; $script:Pass++ } catch { Assert $false "$msg threw: $($_.Exception.Message)" }
}

function Run-Test([string]$name, [scriptblock]$body) {
    $script:CurrentTest = $name
    Write-Host "-- $name" -ForegroundColor Cyan
    try {
        & $body
    } catch {
        $script:Fail++
        $msg = "[$name] threw: $($_.Exception.Message)"
        $script:FailMessages.Add($msg)
        Write-Host "  FAIL: $msg" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------ fixtures

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("rstest-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

function New-LibraryBook([string]$libraryRoot, [string]$author, [string]$title, [int]$id, [string]$ext = 'pdf') {
    $dir = Join-Path $libraryRoot "$author\$title ($id)"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir "$title.$ext"
    Set-Content -LiteralPath $file -Value 'dummy' -Encoding ASCII -NoNewline
    return $file
}

function Format-Entry([hashtable]$fields, [switch]$Full) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("`t[")
    $lines.Add("`t`tFilePath = $($fields.FilePath)")
    if ($Full) {
        $lines.Add("`t`tFavorites [")
        $lines.Add("`t`t]")
        $lines.Add("`t`tIsPinned = false")
    }
    $lines.Add("`t`tIsMissing = false")
    $lines.Add("`t`tOpenCount = 1")
    $lines.Add("`t`tUseDefaultState = $(if ($fields.UseDefaultState) { $fields.UseDefaultState } else { 'false' })")
    foreach ($f in @('DisplayMode', 'ScrollPos', 'PageNo', 'Zoom', 'Rotation')) {
        if ($fields.ContainsKey($f)) { $lines.Add("`t`t$f = $($fields[$f])") }
    }
    if ($Full) {
        $lines.Add("`t`tWindowState = 1")
        $lines.Add("`t`tShowToc = false")
        $lines.Add("`t`tReparseIdx = 0")
    }
    $lines.Add("`t]")
    return $lines
}

function New-SumatraSettingsFile {
    param(
        [string]$Path,
        [switch]$Bom,
        [string]$NewLine = "`r`n",
        [hashtable[]]$Entries,
        [datetime]$WriteTimeUtc
    )
    $top = New-Object System.Collections.Generic.List[string]
    $top.Add('# For documentation, see https://www.sumatrapdfreader.org/settings/settings3-5-1.html')
    $top.Add('Theme = Light')
    $top.Add('RememberOpenedFiles = true')
    $top.Add('RestoreSession = true')
    $top.Add('ShowToolbar = true')
    $top.Add('')
    $top.Add('FileStates [')
    foreach ($e in $Entries) { foreach ($l in (Format-Entry $e -Full)) { $top.Add($l) } }
    $top.Add(']')
    $top.Add('TimeOfLastUpdateCheck = 0 0')
    $text = [string]::Join($NewLine, $top) + $NewLine
    $enc = New-Object Text.UTF8Encoding($Bom.IsPresent)
    [IO.File]::WriteAllText($Path, $text, $enc)
    if ($PSBoundParameters.ContainsKey('WriteTimeUtc')) { [IO.File]::SetLastWriteTimeUtc($Path, $WriteTimeUtc) }
}

function Get-RawFieldValue([string]$settingsPath, [string]$filePath, [string]$field) {
    $s = Read-SumatraSettings $settingsPath
    foreach ($e in (Get-FileStateEntries $s.Lines)) {
        if ($e.Values['FilePath'] -eq $filePath) { return $e.Values[$field] }
    }
    return $null
}

function Get-EntryOrder([string]$settingsPath) {
    $s = Read-SumatraSettings $settingsPath
    return @((Get-FileStateEntries $s.Lines) | ForEach-Object { $_.Values['FilePath'] })
}

function Reset-BookPathCache {
    # Resolve-BookPath caches its folder scan in $script:FolderIndex for 5 minutes,
    # which is correct in production (one process = one fixed LibraryRoot for its
    # whole lifetime) but wrong here: this test harness simulates two separate PCs,
    # each with a different LibraryRoot, inside a single process. Reset before every
    # pull so each "machine" rebuilds against its own library, as it would in reality.
    $script:FolderIndex = $null
    $script:FolderIndexTime = $null
}

function Invoke-PullIsolated($cfg) {
    Reset-BookPathCache
    return Invoke-Pull $cfg
}

function New-Fixture([string]$name) {
    $root = Join-Path $TestRoot $name
    $libA = Join-Path $root 'PCA\Library'
    $libB = Join-Path $root 'PCB\Library'
    $sync = Join-Path $root 'Sync'
    New-Item -ItemType Directory -Path $libA, $libB, $sync -Force | Out-Null
    $sumA = Join-Path $root 'PCA\SumatraPDF-settings.txt'
    $sumB = Join-Path $root 'PCB\SumatraPDF-settings.txt'
    New-Item -ItemType Directory -Path (Split-Path $sumA), (Split-Path $sumB) -Force | Out-Null
    return [pscustomobject]@{
        Root = $root
        LibA = $libA
        LibB = $libB
        Sync = $sync
        SumA = $sumA
        SumB = $sumB
        CfgA = @{ LibraryRoot = $libA; SyncDir = $sync; SumatraSettings = $sumA; SumatraProcess = 'NoSuchProcess*'; MachineName = 'PCA' }
        CfgB = @{ LibraryRoot = $libB; SyncDir = $sync; SumatraSettings = $sumB; SumatraProcess = 'NoSuchProcess*'; MachineName = 'PCB' }
    }
}

$NonLibraryPdf = 'C:\Users\Someone\Downloads\unrelated-not-a-library-book.pdf'

# =========================================================================== T1
Run-Test 'round trip both directions, newest wins' {
    $fx = New-Fixture 't1'
    $bookA = New-LibraryBook $fx.LibA 'Author One' 'Book One' 101
    $bookB = New-LibraryBook $fx.LibB 'Author One' 'Book One' 101

    $t1 = (Get-Date).ToUniversalTime().AddHours(-2)
    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc $t1 -Entries @(
        @{ FilePath = $bookA; PageNo = 10; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
        @{ FilePath = $NonLibraryPdf; PageNo = 3; ScrollPos = '-1 -1'; Zoom = 'fit page'; Rotation = 0; DisplayMode = 'continuous' }
    )
    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-30) -Entries @(
        @{ FilePath = $bookB; PageNo = 1; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )

    Invoke-Push $fx.CfgA | Out-Null
    Assert (Test-Path (Get-MyFile $fx.CfgA)) 'A pushed a progress-PCA.json'

    Invoke-PullIsolated $fx.CfgB | Out-Null
    Assert-Equal '10' (Get-RawFieldValue $fx.SumB $bookB 'PageNo') 'B picked up A''s page 10'

    # B reads further, later in time
    $t2 = (Get-Date).ToUniversalTime()
    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc $t2 -Entries @(
        @{ FilePath = $bookB; PageNo = 50; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgB | Out-Null
    Invoke-PullIsolated $fx.CfgA | Out-Null
    Assert-Equal '50' (Get-RawFieldValue $fx.SumA $bookA 'PageNo') 'A picked up B''s newer page 50'

    # The non-library entry must never be touched
    Assert-Equal '3' (Get-RawFieldValue $fx.SumA $NonLibraryPdf 'PageNo') 'non-library entry on A untouched'
}

# =========================================================================== T2
Run-Test 'stale local position on first run does not beat a newer remote one' {
    $fx = New-Fixture 't2'
    $bookA = New-LibraryBook $fx.LibA 'Author Two' 'Book Two' 202
    $bookB = New-LibraryBook $fx.LibB 'Author Two' 'Book Two' 202

    # A has a stale position, written (mtime) 10 days ago, never pushed before
    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-10) -Entries @(
        @{ FilePath = $bookA; PageNo = 99; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    # B already pushed a newer (now) position
    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookB; PageNo = 5; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgB | Out-Null

    # A's first ever push records the stale position, stamped with the OLD mtime
    Invoke-Push $fx.CfgA | Out-Null
    $mineA = Read-JsonFile (Get-MyFile $fx.CfgA)
    $key = (Get-BookKey $bookA $fx.LibA)
    Assert ((To-Utc $mineA.books[$key].ts) -lt (Get-Date).ToUniversalTime().AddDays(-9)) 'A''s pushed timestamp reflects the old file mtime, not now'

    # Now A pulls: B's newer position must win, not A's stale 99
    Invoke-PullIsolated $fx.CfgA | Out-Null
    Assert-Equal '5' (Get-RawFieldValue $fx.SumA $bookA 'PageNo') 'stale local PageNo=99 was overwritten by newer remote PageNo=5'
}

# =========================================================================== T3
Run-Test 'book never opened on PC B gets a new FileStates entry with correct local path' {
    $fx = New-Fixture 't3'
    $bookA = New-LibraryBook $fx.LibA 'Author Three' 'Book Three' 303
    $bookB = New-LibraryBook $fx.LibB 'Author Three' 'Book Three' 303

    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookA; PageNo = 42; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    # B has never opened this book: no entry for it at all
    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-1) -Entries @(
        @{ FilePath = $NonLibraryPdf; PageNo = 1; ScrollPos = '-1 -1'; Zoom = 'fit page'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgA | Out-Null
    Invoke-PullIsolated $fx.CfgB | Out-Null

    $order = Get-EntryOrder $fx.SumB
    Assert-Equal $bookB $order[0] 'new entry for book Three was inserted at the top of FileStates on B'
    Assert-Equal '42' (Get-RawFieldValue $fx.SumB $bookB 'PageNo') 'new entry has the pulled PageNo'
    Assert-Equal 'false' (Get-RawFieldValue $fx.SumB $bookB 'UseDefaultState') 'new entry has UseDefaultState = false so Sumatra honors it'
    Assert-Equal '1' (Get-RawFieldValue $fx.SumB $NonLibraryPdf 'PageNo') 'pre-existing non-library entry on B untouched'
}

# =========================================================================== T4 (also covered by T1/T3; dedicated check of byte preservation)
Run-Test 'unrelated settings lines, CRLF and BOM preserved byte-for-byte' {
    $fx = New-Fixture 't4'
    $bookA = New-LibraryBook $fx.LibA 'Author Four' 'Book Four' 404
    $bookB = New-LibraryBook $fx.LibB 'Author Four' 'Book Four' 404

    # B: BOM + CRLF
    New-SumatraSettingsFile -Path $fx.SumB -Bom -NewLine "`r`n" -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-1) -Entries @(
        @{ FilePath = $bookB; PageNo = 1; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    # A: no BOM + LF only, pushes a newer position
    New-SumatraSettingsFile -Path $fx.SumA -NewLine "`n" -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookA; PageNo = 77; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    $beforeBytes = [IO.File]::ReadAllBytes($fx.SumB)

    Invoke-Push $fx.CfgA | Out-Null
    Invoke-PullIsolated $fx.CfgB | Out-Null

    $afterBytes = [IO.File]::ReadAllBytes($fx.SumB)
    Assert ($afterBytes.Length -ge 3 -and $afterBytes[0] -eq 0xEF -and $afterBytes[1] -eq 0xBB -and $afterBytes[2] -eq 0xBF) 'BOM preserved on B after pull'

    $afterText = [Text.Encoding]::UTF8.GetString($afterBytes).TrimStart([char]0xFEFF)
    $crlfCount = ([regex]::Matches($afterText, "`r`n")).Count
    $lfCount = ([regex]::Matches($afterText, "(?<!`r)`n")).Count
    Assert-Equal 0 $lfCount 'every newline on B is still part of CRLF (no bare LF introduced)'
    Assert ($afterText -match 'Theme = Light') 'unrelated "Theme = Light" line preserved'
    Assert ($afterText -match 'RestoreSession = true') 'unrelated "RestoreSession = true" line preserved'
    Assert (Test-Path "$($fx.SumB).readingsync.bak") 'a .readingsync.bak backup was created before writing'

    $backupBytes = [IO.File]::ReadAllBytes("$($fx.SumB).readingsync.bak")
    Assert ([System.BitConverter]::ToString($beforeBytes) -eq [System.BitConverter]::ToString($backupBytes)) 'backup file matches B''s pre-pull content exactly'
}

# =========================================================================== T5
Run-Test 'second run is a no-op: no file writes, no return value' {
    $fx = New-Fixture 't5'
    $bookA = New-LibraryBook $fx.LibA 'Author Five' 'Book Five' 505
    $bookB = New-LibraryBook $fx.LibB 'Author Five' 'Book Five' 505

    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookA; PageNo = 8; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-1) -Entries @(
        @{ FilePath = $bookB; PageNo = 1; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgA | Out-Null
    Invoke-PullIsolated $fx.CfgB | Out-Null

    $sumBHashBefore = (Get-FileHash $fx.SumB -Algorithm SHA256).Hash
    $progressBHashBefore = (Get-FileHash (Get-MyFile $fx.CfgB) -Algorithm SHA256).Hash
    $progressBWriteBefore = (Get-Item (Get-MyFile $fx.CfgB)).LastWriteTimeUtc

    $pushResult = Invoke-Push $fx.CfgB   # settings file unchanged since last push -> no-op
    $pullResult = Invoke-PullIsolated $fx.CfgB   # already has the newest known position -> no-op

    Assert-Equal 0 $pushResult 'second Invoke-Push on B returns 0 changed'
    Assert-Equal 0 $pullResult 'second Invoke-Pull on B returns 0 pulled'
    Assert-Equal $sumBHashBefore (Get-FileHash $fx.SumB -Algorithm SHA256).Hash 'B''s settings file bytes unchanged'
    Assert-Equal $progressBHashBefore (Get-FileHash (Get-MyFile $fx.CfgB) -Algorithm SHA256).Hash 'B''s own progress file bytes unchanged'
    Assert-Equal $progressBWriteBefore (Get-Item (Get-MyFile $fx.CfgB)).LastWriteTimeUtc 'B''s own progress file was not rewritten'
}

# =========================================================================== T6
Run-Test 'pull is skipped while Sumatra process is reported running' {
    $fx = New-Fixture 't6'
    $bookA = New-LibraryBook $fx.LibA 'Author Six' 'Book Six' 606
    $bookB = New-LibraryBook $fx.LibB 'Author Six' 'Book Six' 606

    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookA; PageNo = 15; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-1) -Entries @(
        @{ FilePath = $bookB; PageNo = 1; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgA | Out-Null

    $cfgPathB = Join-Path $fx.Root 'config-b.json'
    ($fx.CfgB | ConvertTo-Json) | Set-Content $cfgPathB -Encoding UTF8
    $beforeHash = (Get-FileHash $fx.SumB -Algorithm SHA256).Hash

    # Mock the process check at script scope: Start-ReadingSync and Invoke-Pull were
    # dot-sourced at script scope, so they resolve calls against script-scope functions
    # regardless of which nested scriptblock is doing the overriding here.
    function script:Test-ProcessRunning([string]$pattern) { return $true }
    try {
        $script:ConfigPath = $cfgPathB
        Reset-BookPathCache
        Start-ReadingSync
    } finally {
        # restore the real implementation for later tests
        function script:Test-ProcessRunning([string]$pattern) {
            return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like $pattern })
        }
    }
    Assert-Equal $beforeHash (Get-FileHash $fx.SumB -Algorithm SHA256).Hash 'B''s settings file untouched while Sumatra "running"'

    # Sanity: with the real (non-running) check restored, the same pass now pulls
    $script:ConfigPath = $cfgPathB
    Reset-BookPathCache
    Start-ReadingSync
    Assert-Equal '15' (Get-RawFieldValue $fx.SumB $bookB 'PageNo') 'pull applied once Sumatra is reported not running'
}

# =========================================================================== T7
Run-Test 'book whose folder has not synced yet is retried later, not dropped' {
    $fx = New-Fixture 't7'
    $bookA = New-LibraryBook $fx.LibA 'Author Seven' 'Book Seven' 707
    # Deliberately do NOT create the matching folder in B's library yet.

    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookA; PageNo = 23; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-1) -Entries @(
        @{ FilePath = $NonLibraryPdf; PageNo = 1; ScrollPos = '-1 -1'; Zoom = 'fit page'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgA | Out-Null

    $n1 = Invoke-PullIsolated $fx.CfgB
    Assert-Equal 0 $n1 'pull applies nothing while the book''s folder has not synced to B yet'
    $mineB = Read-JsonFile (Get-MyFile $fx.CfgB)
    $key = Get-BookKey $bookA $fx.LibA
    Assert (-not ($mineB -and $mineB.books -and $mineB.books.ContainsKey($key))) 'the pending book is not recorded as already-applied on B'

    # Now the library folder "finishes syncing"
    $bookB = New-LibraryBook $fx.LibB 'Author Seven' 'Book Seven' 707
    $n2 = Invoke-PullIsolated $fx.CfgB
    Assert ($n2 -gt 0) 'retrying after the folder appears applies the pending update'
    Assert-Equal '23' (Get-RawFieldValue $fx.SumB $bookB 'PageNo') 'late-synced book got its pulled position'
}

# =========================================================================== T8
Run-Test 'corrupt JSON and sync-conflict copies cannot crash the loop or win' {
    $fx = New-Fixture 't8'
    $bookA = New-LibraryBook $fx.LibA 'Author Eight' 'Book Eight' 808
    $bookB = New-LibraryBook $fx.LibB 'Author Eight' 'Book Eight' 808

    New-SumatraSettingsFile -Path $fx.SumB -WriteTimeUtc (Get-Date).ToUniversalTime().AddDays(-1) -Entries @(
        @{ FilePath = $bookB; PageNo = 1; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookA; PageNo = 9; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgA | Out-Null

    # Half-synced / corrupt file
    Set-Content (Join-Path $fx.Sync 'progress-PCC.json') '{ this is not valid json' -Encoding UTF8
    # OneDrive/Google-Drive-style conflict copy with a bogus far-future timestamp
    $key = Get-BookKey $bookA $fx.LibA
    $bogus = @{ machine = 'PCA'; books = @{ $key = @{ pos = @{ PageNo = '9999' }; ts = (Get-Date).ToUniversalTime().AddYears(1).ToString('o'); from = 'PCA' } } }
    ($bogus | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $fx.Sync 'progress-PCA (1).json') -Encoding UTF8
    # Syncthing-style conflict copy
    ($bogus | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $fx.Sync 'progress-PCA.sync-conflict-20260101-120000-PCB.json') -Encoding UTF8

    $n = Invoke-PullIsolated $fx.CfgB
    Assert ($n -gt 0) 'pull still applies the legitimate update despite junk files present'
    Assert-Equal '9' (Get-RawFieldValue $fx.SumB $bookB 'PageNo') 'conflict-copy bogus PageNo=9999 was never adopted'
}

# =========================================================================== T9
Run-Test 'calibre progress column: id extraction, best-effort page count, safe default-off' {
    Assert-Equal '123' (Get-CalibreBookId 'calibre:123:pdf') 'book id extracted from key'
    Assert-Equal $null (Get-CalibreBookId 'not-a-calibre-key') 'non-calibre key yields no id'

    $withCount = Join-Path $TestRoot 't9-withcount.pdf'
    Set-Content -LiteralPath $withCount -Value "%PDF-1.4`n1 0 obj << /Type /Pages /Kids [2 0 R] /Count 42 >> endobj`n" -Encoding ASCII -NoNewline
    Assert-Equal 42 (Get-PdfPageCountBestEffort $withCount) 'page count parsed from an uncompressed Pages object'

    $noCount = Join-Path $TestRoot 't9-nocount.pdf'
    Set-Content -LiteralPath $noCount -Value "%PDF-1.4`nthis file has no Pages/Count marker at all`n" -Encoding ASCII -NoNewline
    Assert-Equal $null (Get-PdfPageCountBestEffort $noCount) 'no fabricated page count when the marker is absent'

    $missing = Join-Path $TestRoot 't9-does-not-exist.pdf'
    Assert-Equal $null (Get-PdfPageCountBestEffort $missing) 'missing file does not throw, just returns null'

    # Default installs leave EnableProgressColumn unset; this must be a complete no-op.
    $fx = New-Fixture 't9'
    $bookA = New-LibraryBook $fx.LibA 'Author Nine' 'Book Nine' 909
    New-SumatraSettingsFile -Path $fx.SumA -WriteTimeUtc (Get-Date).ToUniversalTime() -Entries @(
        @{ FilePath = $bookA; PageNo = 12; ScrollPos = '-1 -1'; Zoom = '100'; Rotation = 0; DisplayMode = 'continuous' }
    )
    Invoke-Push $fx.CfgA | Out-Null
    Should-NotThrow { Update-CalibreProgress $fx.CfgA } 'Update-CalibreProgress with no EnableProgressColumn set'
}

# ------------------------------------------------------------------- summary

Write-Host ""
Write-Host "Passed: $script:Pass   Failed: $script:Fail" -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:FailMessages | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

# ------------------------------------------------------- cross-edition run

if (-not $NoReexec -and $PSVersionTable.PSEdition -eq 'Desktop') {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) {
        Write-Host "`n=== Re-running under PowerShell 7 (pwsh) ===" -ForegroundColor Cyan
        & $pwsh.Source -NoProfile -File $PSCommandPath -NoReexec
        $pwshExit = $LASTEXITCODE
        if ($pwshExit -ne 0) { $script:Fail++; Write-Host "pwsh run reported failures (exit $pwshExit)" -ForegroundColor Red }
    } else {
        Write-Host "`npwsh (PowerShell 7) not found on this machine - skipped cross-edition run." -ForegroundColor Yellow
    }
}

if ($script:Fail -eq 0) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
} else {
    Write-Host "`nFixtures left on disk for inspection: $TestRoot" -ForegroundColor Yellow
    exit 1
}

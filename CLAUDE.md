# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A dependency-free Windows PowerShell tool that keeps SumatraPDF reading positions ("page 57 of 412") in sync for a calibre PDF library shared between two PCs via a regular file-sync folder (OneDrive, Google Drive, Dropbox, Syncthing). calibre remains the library manager and SumatraPDF the viewer; this tool only syncs reading progress and optionally mirrors it into a calibre custom column. Must run on stock Windows PowerShell 5.1 with no admin rights, and also works under PowerShell 7 (`pwsh`).

See `README.md` for full end-user setup/usage docs and `CLAUDE_CODE_PROMPT.md` for the original project brief/handoff doc (architecture rationale, what was/wasn't verified, ground rules).

## Commands

Run the test suite (self-contained, no Pester):

```
powershell -File tests\Test-ReadingSync.ps1
```

It auto re-execs itself under `pwsh` as well if PowerShell 7 is installed, so a single invocation covers both editions. There is no separate build or lint step — these are plain `.ps1` scripts.

To run the sync loop manually for debugging (single pass instead of the normal infinite loop):

```
powershell -File ReadingSync.ps1 -Once -Verbose -ConfigPath <path to config.json>
```

`ReadingSync.ps1` can also be dot-sourced with `-NoAutoStart` to load its functions without starting the loop or requiring a config file — this is exactly how the test suite loads it (`. $scriptUnderTest -NoAutoStart -Once`), and is the way to experiment with individual functions interactively.

## Architecture

Three independent scripts, no shared modules:

- **`ReadingSync.ps1`** — the sync engine. Runs as a hidden background loop (started at logon), polling every `-IntervalSeconds` (default 15).
- **`Install.ps1`** — interactive per-PC setup: writes `%LOCALAPPDATA%\ReadingSync\config.json`, copies `ReadingSync.ps1` there, and registers a `.vbs` launcher in the Startup folder (no admin rights needed). Safe to re-run — it kills any already-running copy and starts fresh.
- **`Uninstall.ps1`** — stops the background process, removes the Startup shortcut and the `%LOCALAPPDATA%\ReadingSync` folder. Never touches the library, PDFs, or progress JSON files.

### Book identity

Books are identified as `calibre:<id>:<ext>`, where `<id>` is parsed out of calibre's own folder naming convention `<Library>\<Author>\<Title> (<id>)\file.ext` (see `Get-BookKey` / `Resolve-BookPath`). This works even though the library lives at a different absolute path on each PC, because the id comes from the folder name, not the path. Never key anything off absolute file paths.

### Sync model (push/pull, not merge)

- Each PC writes **only its own** `progress-<MachineName>.json` into a synced folder that is outside the calibre library (`Get-MyFile`). No file is ever written by two machines, so there's nothing for the sync tool to merge or conflict on.
- **Push** (`Invoke-Push`): reads SumatraPDF's `FileStates` block, and for any book position that changed, stamps it with the *settings file's* `LastWriteTimeUtc` — not "now" — so a stale position found on first run can't out-rank a genuinely newer remote one.
- **Pull** (`Invoke-Pull`): only runs while SumatraPDF is **not** running (Sumatra rewrites its whole settings file from memory on exit, clobbering any external edit made while it was open). Newest timestamp wins across all other machines' progress files. Known-locally books are edited in place; books never opened on this machine get a new `FileStates` entry inserted at the top. A missing settings file (Sumatra never run on this PC) gets seeded with an empty `FileStates [` `]` block first.
- `Get-OtherProgressFiles` matches progress files by strict regex (`^progress-[A-Za-z0-9_\-]+\.json$`) specifically to exclude sync-tool conflict copies (`progress-DESKTOP (1).json`, `*.sync-conflict-*`) from ever being read as real machine state.
- A book whose PDF hasn't synced to this machine yet (`Resolve-BookPath` returns `$null`) is skipped, not dropped — the main loop's periodic re-pull (`-RecheckMinutes`, default 5) retries it once the file shows up.

### SumatraPDF settings file handling

`SumatraPDF-settings.txt` is a bracket-nested custom text format, not JSON (see `Read-SumatraSettings`, `Find-FileStatesBlock`, `Get-FileStateEntries`, `Set-SumatraPositions`). The parser/writer is deliberately surgical:

- Only the `FileStates` block is touched, and within it only position fields (`PageNo`, `ScrollPos`, `Zoom`, `Rotation`, `DisplayMode`) plus `UseDefaultState`/`IsMissing` flags.
- BOM, line-ending style (CRLF vs LF), and every unrelated line are preserved byte-for-byte on write.
- Existing entries are edited bottom-up (`Sort-Object Start -Descending`) so inserting new lines never shifts the index of an entry not yet processed.
- A backup (`*.readingsync.bak`) is written before every save.
- This file is never written while Sumatra is running — the whole pull side of the sync depends on that invariant.

### calibre progress column (optional, off by default)

`Update-CalibreProgress` mirrors reading position into a calibre custom column via `calibredb set_custom`, batched (default once a minute, see `cfg.ProgressUpdateMinutes`) rather than per page turn. `Test-CalibreSafeToWrite` refuses to write if calibre looks open locally or was reported open on another machine within the last 3 minutes (via the heartbeat files below), since `metadata.db` is a second, separate write path into the same database the library file-sync already has to protect. Page counts are best-effort only (`Get-PdfPageCountBestEffort` — a dependency-free scan for an uncompressed `/Pages`/`/Count` entry; PDFs with compressed cross-reference streams won't match and fall back to showing the current page number instead of a percentage).

### Heartbeat / conflict warning

`Update-Heartbeat` writes `status-<MachineName>.json` each loop iteration and pops a `MessageBox` warning if calibre is detected open on this PC while another PC's heartbeat (within the last 3 minutes) also shows calibre open — a safety net against two calibre instances corrupting the shared `metadata.db`, not a lock.

### Testing approach

`tests\Test-ReadingSync.ps1` dot-sources `ReadingSync.ps1` (not a reimplementation) and drives the real functions against two fake "PCs" built under a temp folder, each with its own library root, its own `SumatraPDF-settings.txt`, and a shared sync folder — covering round trips in both directions, newest-wins, stale-first-run-doesn't-win, new-book insertion, non-library files left alone, byte-for-byte preservation of unrelated content, idempotent re-runs, pull-skipped-while-Sumatra-running, late-arriving library folders, and corrupt/conflict-copy progress files. `Resolve-BookPath`'s 5-minute folder-index cache is global per-process, so tests that simulate multiple "PCs" in one process must call `Reset-BookPathCache` between PCs or the cache leaks a stale library root across them.

## Hard invariants (do not relax without strong justification)

- Never modify, move, or delete PDFs or calibre's `metadata.db` directly; only `calibredb` touches the database, and only for the opt-in progress column.
- Never write Sumatra's settings file while Sumatra is running.
- Keep this dependency-free — no Python, no external modules, nothing beyond PowerShell 5.1 built-ins (e.g. `ConvertTo-Hashtable` exists solely because PS 5.1 lacks `ConvertFrom-Json -AsHashtable`; `To-Utc` exists because PS7's `ConvertFrom-Json`, unlike PS5.1's, parses ISO date strings into local-kind `DateTime` and would otherwise skew timestamp comparisons).

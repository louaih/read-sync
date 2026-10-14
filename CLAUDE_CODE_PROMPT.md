# Handoff: calibre + SumatraPDF reading-progress sync (Windows, 2 PCs)

You are taking over a half-finished project. Own it end to end: review the existing code, fix what's wrong, finish the missing pieces, test it, and leave me with something I can install on both PCs.

## What I want

- I have a calibre library of PDFs. I read them in **SumatraPDF**. I use two Windows PCs (desktop + laptop).
- I want both PCs to have the **same library** and the **same reading position** for every book, automatically.
- **No new reading app.** calibre stays the library manager, SumatraPDF stays the viewer. Small background helpers are fine.
- Must work on stock Windows PowerShell 5.1 (also fine on PowerShell 7). No admin rights needed to install.

## Architecture (already decided, keep unless you find a real problem)

1. **Library sync:** the calibre library folder lives inside a file-sync folder (OneDrive, Google Drive, Dropbox or Syncthing). The sync tool handles the PDFs and `metadata.db`. Our code does not copy books.
   - Risk: `metadata.db` conflicts if calibre is open on both PCs at once. Mitigation already in code: each PC writes a heartbeat (`status-<PC>.json`) and shows a warning popup if calibre is opened while it's open on the other PC.
2. **Progress sync:** `ReadingSync.ps1` runs hidden in the background on each PC (started at logon from a `.vbs` in the Startup folder).
   - It parses `SumatraPDF-settings.txt` (`%LOCALAPPDATA%\SumatraPDF\` or next to the exe if portable), reads the `FileStates [...]` block, and picks out entries whose `FilePath` is inside the calibre library.
   - **Book identity** = calibre book id taken from the folder name `<Library>\<Author>\<Title> (<id>)\file.pdf`, so key = `calibre:<id>:pdf`. This works even if the library is at a different path on each PC.
   - Each PC writes **only its own** `progress-<PC>.json` in a separate synced folder (outside the library), so the sync tool never has to merge one file written by two machines.
   - **Push:** when Sumatra's settings file changes, record changed positions (`PageNo`, `ScrollPos`, `Zoom`, `Rotation`, `DisplayMode`) with timestamp = the settings file's LastWriteTimeUtc (not "now", so stale positions found on first run don't win).
   - **Pull:** only while SumatraPDF is **not running** (Sumatra rewrites the whole settings file on exit and would clobber edits). Newest timestamp wins across all PCs. Edit existing entries in place; insert new entries at the top of `FileStates` for books never opened on this PC. Backs up to `SumatraPDF-settings.txt.readingsync.bak` before each write. Preserves BOM, line endings and every unrelated line.

## Files in this folder

- `ReadingSync.ps1`: the sync loop (`-Once` for a single pass, `-ConfigPath` to point at a config, `-Verbose`).
- `Install.ps1`: interactive per-PC setup. Reads calibre's library path from `%APPDATA%\calibre\global.py.json`, asks for the progress folder, Sumatra settings path, PC name; writes `%LOCALAPPDATA%\ReadingSync\config.json`; copies the script there; creates the Startup `.vbs`; starts it.
- `Uninstall.ps1`: stops it and removes the Startup entry and app folder. Never touches books or progress files.

## State when handed off

Done and tested in a Linux pwsh sandbox with fake paths:
- Parsing Sumatra settings, book keys, push to JSON.

Fixed but **not yet re-tested**:
- Push timestamp now uses the settings file's mtime (bug: a stale local position on first run beat a newer remote one).
- `To-Utc` helper added because PS7's `ConvertFrom-Json` turns ISO strings into local-kind DateTime, which skews comparisons.

Never tested:
- Full round trip (A reads -> B pulls -> B reads further -> A pulls), new-entry insertion, idempotency (re-running changes nothing), anything on real Windows or with a real SumatraPDF.

## Your tasks, in order

1. **Read all three scripts fully** and review them critically. Fix bugs you find, and tell me what they were.
2. **Build an automated test** (`tests\Test-ReadingSync.ps1`, plain PowerShell or Pester) that creates two fake "PCs" in a temp folder (each with its own library path, identical book folders, own Sumatra settings file and config, shared sync folder) and checks:
   - round trip in both directions; newest wins
   - stale local position on first run does NOT overwrite a newer remote one
   - book never opened on PC B gets a new FileStates entry with the right local path
   - non-library PDFs in Sumatra history are never touched
   - unrelated settings lines, CRLF and BOM are preserved byte-for-byte
   - second run is a no-op (no file writes, no log lines)
   - pull is skipped while the Sumatra process is "running" (make the process check mockable)
   - book whose folder hasn't synced yet is retried later, not dropped
   - works under both Windows PowerShell 5.1 and pwsh 7 if both are available
3. **Verify against real SumatraPDF** on this machine (back up the real settings file first and restore it after):
   - Confirm the current Sumatra version's `FileStates` field names and format match what the parser expects.
   - Confirm Sumatra actually honours an externally edited `PageNo`/`ScrollPos` and an inserted new entry when it next opens the book.
   - Find out whether Sumatra reloads its settings file while running. If it does, we may be able to pull while it's open; if not, keep the "only when closed" rule.
   - Confirm process name for both installed and portable builds (pattern is currently `SumatraPDF*`).
4. **Clean up rough edges** I already know about:
   - The periodic re-pull condition in the main loop (`minute % 5` check) is hacky. Replace it with a simple "re-check every N minutes" timer so books whose PDFs arrive late get their position applied.
   - Handle clock skew sensibly (at least log a warning if a remote timestamp is in the future by more than a few minutes).
   - Make sure a corrupt or half-synced JSON file (or a sync-tool conflict copy like `progress-X (1).json` / `*.sync-conflict-*`) can't crash the loop or win incorrectly.
   - Install.ps1: if pwsh 7 is installed it can use it, otherwise powershell.exe; re-running the installer should cleanly upgrade.
5. **Write `README.md`** for me: one-time setup on each PC (moving the calibre library into the synced folder via calibre's own "Switch/create library > move" so ids stay intact, OneDrive "Always keep on this device" for the library folder, setting SumatraPDF as calibre's PDF viewer via "Open with", making sure Sumatra's "Remember opened files" / per-document state is on), daily rules (close Sumatra and calibre before switching PCs; don't run calibre on both at once), how to check the log, and how to uninstall.
6. **Optional, ask me first:** show progress inside calibre (e.g. a `#progress` custom column with "p. 57 / 412") via `calibredb`. Only if it can be done without fighting the running calibre GUI or causing `metadata.db` conflicts. Tell me the trade-offs before building it.

## Ground rules

- Never modify, move or delete PDFs or `metadata.db`.
- Never write Sumatra's settings while Sumatra is running (unless step 3 proves that's safe).
- Keep it dependency-free (no Python, no modules to install) unless you make a strong case.
- No em dashes in the README.
- When done, give me: what you changed and why, test results, anything you couldn't verify, and the exact steps to install on each PC.

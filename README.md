# read-sync

Keeps a calibre library and SumatraPDF reading positions in sync between two Windows PCs, without a new reading app. calibre stays the library manager. SumatraPDF stays the viewer. A small background script keeps "page 57 of 412" the same on both machines.

## How it works, in one paragraph

Your calibre library folder lives inside a regular file-sync folder (OneDrive, Google Drive, Dropbox, or Syncthing), so the sync tool moves the PDFs and `metadata.db` for you. A separate script, `ReadingSync.ps1`, runs quietly in the background on each PC. It watches SumatraPDF's own settings file, notices when you've moved to a new page, and writes that position to a small JSON file in a second synced folder. Each PC reads the other PC's JSON file and, whenever SumatraPDF is closed, patches the right entry in its own Sumatra settings so the next time you open that book, it opens where you left off.

## One-time setup, on each PC

Do all of this on PC 1, then repeat steps 2 to 5 on PC 2 once PC 1's library has finished syncing to it.

### 1. Put the calibre library inside a synced folder

In calibre: **File > Switch/create library > Move/copy the current library**, and pick a folder inside OneDrive (or your sync tool of choice), for example `OneDrive\Books`. Using calibre's own move keeps every book's internal id intact, which matters because this tool identifies books by that id, not by file path. Let it finish syncing to your sync provider before touching the second PC.

Whatever sync tool you use, make sure that folder is kept as real local files, not cloud-only placeholders, since SumatraPDF and this script both need the actual bytes on disk:

- **OneDrive**: right-click the `Books` folder and choose **Always keep on this device**.
- **Google Drive for desktop**: the folder needs to be under a location set to **Mirror files**, not **Stream files** (that's a global setting in the Google Drive app's preferences, not a per-folder one). Stream mode leaves placeholders that download on demand, which is exactly what you don't want here.
- **Dropbox**: right-click the folder and choose **Make available offline** (older clients) or make sure **Local** is selected rather than **Online-only** under Smart Sync.
- **Syncthing**: files are always local by default, nothing to change.

### 2. Point calibre at the synced library (second PC only)

On the second PC, install calibre, then **File > Switch/create library > Use library at specified location** and point it at the same synced folder (it will have a different drive letter or path than on PC 1, and that's fine). Do not create a brand-new library here; it must be the one that synced over.

### 3. Set SumatraPDF as calibre's PDF viewer

Install SumatraPDF on this PC (winget: `winget install SumatraPDF.SumatraPDF`, or download from sumatrapdfreader.org; portable builds work too). In calibre, right-click a PDF, choose **Open with > Other application**, pick SumatraPDF, and if offered, set it as the default for PDFs.

### 4. Turn on Sumatra's per-document memory

Open SumatraPDF once, go to **Settings > Options**, and make sure **"Remember the opened files"** is checked. This is `RememberOpenedFiles` in its settings file, and it has to be on for Sumatra to keep a per-book page/zoom/scroll record at all. You don't need to change anything about session restore; testing showed Sumatra re-reads each book's saved position fresh even when it restores previously open tabs, so a position synced in from the other PC is not overridden by a stale open-tabs snapshot.

### 5. Install ReadingSync

Download or copy this folder to the PC, then run:

```
powershell -ExecutionPolicy Bypass -File Install.ps1
```

It will ask four questions:

- **calibre library folder**: it pre-fills this from calibre's own settings; just confirm it.
- **Folder for reading-progress files**: pick any synced folder that is *outside* the calibre library folder (the installer suggests one next to it and will refuse a folder nested inside the library).
- **SumatraPDF settings file**: it finds this automatically in the common cases.
- **Name for this PC**: anything, as long as it's different on your two PCs (for example `DESKTOP` and `LAPTOP`).

It writes a config file, copies the script to `%LOCALAPPDATA%\ReadingSync`, and adds a shortcut to your Startup folder so it starts quietly, with no visible window, every time you log in. It also starts it immediately, so you don't need to log out and back in. If PowerShell 7 (`pwsh`) is installed, it's used; otherwise it falls back to Windows PowerShell 5.1, which is included in every copy of Windows 10 and 11. No administrator rights are needed.

Re-running `Install.ps1` later (for example after moving the library folder) is safe: it stops the old background copy and starts a fresh one with the new settings.

## Daily rules

- **Close SumatraPDF before you switch PCs.** Sumatra only writes its own settings file when it exits, and it rewrites the whole file with whatever it currently has in memory. If it's still open, your sync script will not touch that file (it is designed not to), and anything the other PC pulled in will just sit there until you close Sumatra.
- **Close calibre before you switch PCs, and never run it on both PCs at the same time.** calibre's `metadata.db` is a single shared database file; two copies of calibre writing to it at once (even through a sync tool) can corrupt it or create an unresolvable sync conflict. Each PC's ReadingSync also writes a small heartbeat file and will pop up a warning if it notices calibre open on both machines within the last few minutes, but that warning is a safety net, not a substitute for the habit.
- Everything else is automatic. Read on PC 1, close Sumatra and calibre, let the sync folders catch up (usually seconds, occasionally longer for OneDrive), open on PC 2.

## Checking the log

Each PC keeps its own log at:

```
%LOCALAPPDATA%\ReadingSync\ReadingSync.log
```

It records when positions are pushed or pulled, and any warnings (for example, a clock that's noticeably out of sync between your two PCs, or a book whose folder hasn't finished syncing yet).

## Uninstall

Run `Uninstall.ps1` from this folder (or from wherever you copied it). It stops the background process and removes the Startup shortcut and the `%LOCALAPPDATA%\ReadingSync` folder. It never touches your calibre library, your PDFs, or the reading-progress JSON files, so you can reinstall later and pick up where you left off.

## Optional: progress column inside calibre

`Install.ps1` can ask calibre to add a `progress` custom column (for example "71%") so you can see roughly how far along a book is without opening it. It is off by default; say yes to the prompt during setup to turn it on.

Trade-offs worth knowing before you turn it on:

- It writes to `metadata.db` through `calibredb`, which is a second write path into the same database the library sync already has to protect. The background script refuses to write whenever calibre looks like it might be open, on this PC or recently on the other one, and writes are batched (about once a minute) rather than on every page turn, but the underlying risk is the same kind the heartbeat warning exists for.
- SumatraPDF's settings file only records the *current* page, not a book's total page count, so an exact percentage needs that total from somewhere else. This tool gets it with a lightweight, dependency-free scan of the PDF itself, which works for many PDFs but not all (PDFs that store their internal structure in compressed streams, which is common from some PDF producers, won't match). When the total can't be determined, the column shows the current page only (for example "p. 57") instead of guessing at a percentage.
- Unlike the SumatraPDF side of this tool, the `calibredb` commands here were written to calibre's documented command-line conventions but not verified against a real calibre install (calibre wasn't available on the machine this was built on). Check `ReadingSync.log` after setup; if calibredb's exact flags have changed in your calibre version, that log will show the failing command.

## Running the test suite

`tests\Test-ReadingSync.ps1` is a self-contained test suite (no Pester needed) that builds two fake PCs in a temp folder and exercises the real push/pull logic: round trips in both directions, newest-wins, a stale first-run position not beating a newer remote one, new-book insertion, non-library files being left alone, byte-for-byte preservation of everything else in the settings file, idempotent re-runs, the "don't pull while Sumatra is open" rule, late-arriving library folders, and corrupt or sync-conflict progress files. Run it with:

```
powershell -File tests\Test-ReadingSync.ps1
```

It also re-runs itself under PowerShell 7 automatically if `pwsh` is installed.

## What was verified against the real app

This was checked directly against SumatraPDF 3.5.2 on a real Windows machine, not just inferred from documentation:

- The `FileStates` field names and layout (`FilePath`, `PageNo`, `ScrollPos`, `Zoom`, `Rotation`, `DisplayMode`, `UseDefaultState`, the nested `Favorites [ ]` block) match what the parser expects.
- An externally edited `PageNo`/`ScrollPos` is honored the next time Sumatra opens that file.
- A brand-new, minimal, hand-written `FileStates` entry (missing most of the fields Sumatra normally writes) is fully honored, including at an unusual page number; Sumatra fills in the rest with defaults.
- Sumatra does not reload its settings file while it's running. Editing it while Sumatra is open gets silently discarded when Sumatra next closes and rewrites the whole file from memory, which is exactly why this tool never writes while Sumatra is running.
- `RestoreSession` (reopening your last tabs on launch) does not override a synced position; Sumatra re-resolves each reopened tab's position from `FileStates`, not from its own saved tab snapshot.
- The running process is named `SumatraPDF` for both the installed and portable builds, matching the `SumatraPDF*` pattern this tool looks for.

## Known limitations

- This was built and tested without a real two-PC OneDrive setup end to end; the push/pull logic itself is covered by the automated test suite and live verification above, but the full loop (actually reading on one PC, walking to a second PC, and confirming the position shows up) has not been observed firsthand.
- If a sync-conflict copy of your calibre library ever gets created (two copies of `metadata.db`), this tool will not detect or fix that; the calibre-open heartbeat warning exists specifically to make that scenario rare.
- Very large OneDrive sync delays (minutes, not seconds) mean the position on the second PC may briefly be out of date right after you switch; the script rechecks periodically, so it catches up on its own.

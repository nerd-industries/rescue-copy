# NN Rescue Copy — Design

**Date:** 2026-08-13
**Status:** Approved design, pre-implementation
**One-liner:** `irm copy.nerdyneighbor.net | iex`

## Purpose

A GUI rescue-backup tool for Nerdy Neighbor recovery jobs. Run on a full Windows
machine (bench machine or bare rescue VM) with a customer drive slaved in, it copies
all important user data to a chosen backup drive — including OneDrive/Dropbox
cloud-reparse files that robocopy/xcopy/Explorer cannot open (ERROR 1920) — and
scans the customer drive for data stranded outside standard user folders.

Built on the raw-copy technique proven in `Copy-RawFile.ps1` (Tom Scott recovery,
2026-08-12: 244 OneDrive files robocopy couldn't touch, all recovered).

## Decisions made during brainstorming

| Question | Decision |
|----------|----------|
| Runtime environments | Full Windows only (WPF is safe). No WinPE support. |
| Hosting | GitHub repo `nerd-industries/rescue-copy` + Cloudflare Pages Function on `copy.nerdyneighbor.net`, same pattern as `openssh.nerdyneighbor.net`. |
| Default data scope | Visible profile folders only. Optional **Include key AppData** toggle that lists exactly what it adds. |
| Out-of-profile scan | Non-standard root folders + `Users\Public` + known app-data locations (QuickBooks, Sage, tax software), shown as checkable findings with sizes. |
| Destination layout | Customer/job name (prefilled from source drive's registry hostname) → `<Backup>:\NN-Rescue\<Name>\...`. Re-runs resume incrementally. |
| Copy engine | Pure PowerShell raw-copy engine. No FastCopy: it can't open cloud-reparse files without `cldflt.sys`, its v5+ license forbids rehosting/commercial free use, and aggressive parallel I/O is wrong for suspect drives. |
| Verification | Size check always; optional post-copy hash verify (re-read + compare). |

## Architecture

One self-contained PowerShell script, `NN-RescueCopy.ps1`, containing:

1. **Bootstrap/guard** — detects GUI-less or non-Windows hosts and exits with a
   clear message instead of crashing. Relaunches in STA mode if needed (WPF
   requires STA; `irm | iex` runs in whatever the console has, so the script
   re-invokes itself with `-Sta` via a temp copy when necessary).
2. **WPF GUI** — XAML defined inline, dark Nerdy Neighbor styling, single window,
   wizard-style left-to-right flow.
3. **Scanner** — enumerates volumes, user profiles, profile folder sizes, AppData
   targets, and out-of-profile extras on the source drive. Runs in a background
   runspace; results stream into the UI.
4. **Copy engine** — the `CreateFileW` raw-open technique from `Copy-RawFile.ps1`,
   run in a background runspace, posting progress to the UI via a synchronized
   queue drained by a DispatcherTimer.
5. **Reporter** — streams per-file results to `_RescueLog.csv` during the job and
   writes `_RescueReport.html` (summary + problem list) at the end.

Served by a Cloudflare Pages Function (`functions/index.js`) that proxies the
GitHub Contents API with `Accept: application/vnd.github.raw` — no CDN staleness;
push to `main` is deployment. Browser hits get a landing page; `?download=1`
returns the script as a file download.

## GUI flow

Single window, five steps shown as a progress rail:

### Step 1 — Drives
Two pickers listing all volumes: letter, label, size, free space, and a
"Windows/Users found" badge so the customer drive is obvious. Source may instead
be a browsed folder for odd mounts. Destination free space is checked against the
selection total before copy starts (warn, don't block — the selection can shrink).

### Step 2 — Job name
Text box prefilled with the source machine's hostname, read by loading the slaved
drive's `SYSTEM` hive read-only (`reg load` →
`ControlSet###\Control\ComputerName\ComputerName` → `reg unload`). Falls back to
blank if the hive is missing/locked/corrupt. The name becomes the job folder;
re-using a name resumes that job.

### Step 3 — Selection
A checkbox tree, populated live as the background scan finishes each branch:

- **Per user profile** (from `<Source>\Users\*`, excluding `Default`,
  `Default User`, `Public`, `All Users`): Desktop, Documents, Pictures,
  Downloads, Videos, Music, Favorites, plus every folder matching `OneDrive*`.
  Each node shows computed size. All checked by default.
- **Include key AppData** (toggle, default OFF). When on, adds per-user nodes and
  displays exactly what it brings:
  - Chrome: `AppData\Local\Google\Chrome\User Data` (bookmarks, passwords DB, profiles)
  - Edge: `AppData\Local\Microsoft\Edge\User Data`
  - Firefox: `AppData\Roaming\Mozilla\Firefox\Profiles`
  - Outlook data files: `*.pst`/`*.ost` under `AppData\Local\Microsoft\Outlook`
    and `Documents\Outlook Files`
  - Sticky Notes: `AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_*\LocalState`
  - Windows Mail: `AppData\Local\Comms`
- **Extras found on drive**: every root-level folder not in the OS exclude list
  (`Windows`, `Program Files`, `Program Files (x86)`, `ProgramData`, `PerfLogs`,
  `Recovery`, `System Volume Information`, `$Recycle.Bin`, `$WinREAgent`,
  `Users`, `OneDriveTemp`, `Config.Msi`, `Intel`, `AMD`, `NVIDIA`, `Drivers`,
  `MSOCache`, `inetpub`), `Users\Public` content folders, and known app-data
  spots when present: QuickBooks (`Users\Public\Documents\Intuit`,
  `ProgramData\Intuit`), Sage (`ProgramData\Sage`), TurboTax
  (`<user>\Documents\TurboTax`), H&R Block (`<user>\Documents\HR Block`).
  Each with size, checked OFF by default except `Users\Public`
  documents/desktop (ON).

Footer shows running total of selected bytes vs. destination free space.

### Step 4 — Copy
Overall bytes-based progress bar, current file path, elapsed/ETA, live counters
per result code (`OK`, `SKIP-EXISTS`, `CLOUD-ONLY`, `OPEN-FAIL`, `READ-FAIL`,
`SIZE-MISMATCH`), scrolling problem list, Pause and Cancel buttons. Optional
"Verify after copy" checkbox (set on step 3) triggers the hash pass.

### Step 5 — Done
Totals, cloud-only count with plain-language explanation ("these files live only
in the customer's cloud account — sign into OneDrive on the new machine to get
them"), buttons: Open destination folder, Open HTML report.

## Destination layout

```
<Backup>:\NN-Rescue\<JobName>\
  Users\<username>\Desktop\...          (mirrors profile structure)
  Users\<username>\AppData-Rescue\...   (AppData items, clearly separated)
  Extras\<RootFolderName>\...
  Public\...
  _RescueLog.csv                        (streamed per-file results)
  _RescueReport.html                    (end-of-job summary)
```

Re-running with the same job name skips same-size existing destination files
(incremental resume). A `-Force`-equivalent GUI checkbox re-copies everything.

## Copy engine

From `Copy-RawFile.ps1`, with additions:

- `CreateFileW` with `FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS`,
  `GENERIC_READ`, full sharing; raw handle wrapped in a .NET `FileStream`.
- Cloud-only placeholder detection (`OFFLINE` | `RECALL_ON_DATA_ACCESS`
  attributes) → `CLOUD-ONLY`, skipped, reported.
- **Long paths**: all source and destination paths normalized to `\\?\` form so
  >260-char paths copy instead of failing.
- **Small-file throughput**: one reused 1 MB buffer per worker; destination
  directories created once per directory, not per file. Single copy stream
  (sequential reads are deliberate — suspect drives get gentle I/O).
- Size verification on every file; timestamps preserved; source never written.
- **Optional verify pass**: after copy completes, re-read source and destination
  (source via raw open) computing xxHash-style streaming hash (SHA-256 via
  `IncrementalHash` — built in, fast enough) and compare; mismatches reported.
- Every failure is non-fatal: logged to CSV, counted, shown in the problem list,
  job continues.

Progress protocol: engine posts `{file, bytesDone, totalBytes, result}` records
to a `ConcurrentQueue`; a 250 ms `DispatcherTimer` on the UI thread drains it.
Cancel sets a flag the engine checks between files; Pause blocks the engine loop.

## Error handling

| Failure | Behavior |
|---------|----------|
| Per-file open/read/size errors | Logged, counted, listed; job continues. |
| Registry hive unreadable | Job name field left blank; tooltip explains. |
| Scan errors (access denied dirs) | Branch marked "partial — some folders unreadable"; continues. |
| Destination fills up | Copy halts with clear message; CSV log intact; resume works after freeing space. |
| No GUI stack / non-Windows | Plain console message, exit 1. |
| GitHub/Cloudflare outage | Pages Function returns a PowerShell snippet that prints the error (same as openssh pattern). |

## Testing

- **Headless (Pester, runs anywhere PowerShell Core runs):** path normalization
  (`\\?\`, long paths), destination path mapping, profile/extras enumeration
  logic against a synthetic directory tree, exclude lists, result-code
  aggregation, CSV/HTML report generation.
- **Manual bench pass (required before first customer use):** real Windows
  machine — GUI walkthrough, slaved-drive hive read, raw copy of genuine
  OneDrive reparse files, cancel/pause/resume, verify pass, report output.
  This Linux dev box cannot execute WPF; the bench pass is the acceptance gate.

## Deployment

- Repo: `github.com/nerd-industries/rescue-copy` — `NN-RescueCopy.ps1`,
  `README.md`, `pages/` (Cloudflare Pages project: `functions/index.js`,
  `public/index.html`, `wrangler.toml`).
- Cloudflare Pages project `nerdyneighbor-rescue-copy`, custom domain
  `copy.nerdyneighbor.net`, optional `GITHUB_TOKEN` secret for rate limit.
- Update flow: commit + push to `main` → next `irm` serves the new version.

## Out of scope (YAGNI)

- WinPE/console fallback UI
- FastCopy or any external binary integration
- Disk imaging, SMART checks, BitLocker unlock (separate tools/jobs)
- Restore tooling — the destination tree is plain files, restore is drag-and-drop
- Scheduling, multi-job queuing, network destinations (UNC paths work if
  Windows can see them, but nothing special is built for them)

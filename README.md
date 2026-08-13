# NN Rescue Copy

GUI rescue-backup tool for Nerdy Neighbor recovery jobs.

    irm copy.nerdyneighbor.net | iex

Run on **full Windows** (bench machine or rescue VM) with the customer drive
slaved in. Pick the customer drive and the backup drive, name the job, tick
what to copy, go. Read-only on the source drive.

## What it does

- Copies every user's visible profile folders (Desktop, Documents, Pictures,
  Downloads, Videos, Music, Favorites, OneDrive*) **plus any custom folders
  the user created at their profile root** (legacy junctions and AppData
  excluded) to `<Backup>:\NN-Rescue\<JobName>\Users\<user>\...`
- **Copies OneDrive/Dropbox cloud-reparse files** that robocopy/xcopy/Explorer
  fail on with ERROR 1920 (raw `CreateFileW` open with
  `FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS` — the
  Copy-RawFile technique from the 2026-08-12 Tom Scott recovery)
- Cloud-only placeholders are **downloaded through OneDrive when the machine
  is live and signed in** (normal open lets `cldflt.sys` hydrate them); only
  when that's impossible (slaved drive) are they skipped and reported
- Optional **Include key AppData**: Chrome/Edge/Firefox profiles, Outlook
  PST/OST, Sticky Notes, Windows Mail → `Users\<user>\AppData-Rescue\...`
- Scans the drive root for stranded data (non-OS root folders, Public
  folders, QuickBooks/Sage ProgramData) and offers it as checkboxes
- Size-verifies every copy, preserves timestamps, streams `_RescueLog.csv`,
  writes `_RescueReport.html`; optional SHA-256 verify pass
- Re-running the same job name resumes (same-size files skipped)

## Result codes

| Code | Meaning |
|------|---------|
| `OK` | Copied and size-verified |
| `SKIP-EXISTS` | Same-size copy already at destination (resume) |
| `CLOUD-ONLY` | No local data — lives only in the cloud account |
| `OPEN-FAIL(err=N)` | Could not open source (1392 = corrupt on disk) |
| `READ-FAIL` / `SIZE-MISMATCH` | Read error mid-file — check drive health |
| `HASH-MISMATCH` / `VERIFY-FAIL` | Verify pass found a bad copy |

## Development

Pure functions are tested with Pester on any OS:

    pwsh -NoProfile -Command "Invoke-Pester -Path tests"

GUI behavior is bench-tested on real Windows: see
`docs/bench-test-checklist.md`. Hosting: Cloudflare Pages
(`pages/`) proxying this repo's `NN-RescueCopy.ps1` via the GitHub
Contents API — push to `main` is deployment.

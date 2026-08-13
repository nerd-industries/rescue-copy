# Bench test checklist — run on real Windows before first customer job

Machine: full Windows 10/11 with a spare drive or USB disk as "backup",
ideally a second drive with a Windows install + OneDrive data as "customer".

## Launch
- [ ] `irm copy.nerdyneighbor.net | iex` from Windows PowerShell 5.1 opens the GUI
- [ ] Same from PowerShell 7 (pwsh) opens the GUI
- [ ] Window renders dark-themed, no binding errors in the console

## Step 1 — Drives
- [ ] All ready volumes listed with letter, label, size, free, Windows/Users badges
- [ ] "Browse folder as source" picks an arbitrary folder
- [ ] Next blocked until both source and destination chosen; same-drive blocked

## Step 2 — Job name
- [ ] Name prefilled from a slaved drive's registry (SYSTEM hive)
- [ ] Hint shown and field editable when hive unreadable
- [ ] Destination preview updates as you type; invalid chars stripped
- [ ] Note: hostname read loads the SYSTEM hive via reg.exe (harmless dirty-flag replay possible; degrades to blank name on write-protected drives)

## Step 3 — Selection
- [ ] Tree populates per user with sizes; all profile folders checked
- [ ] AppData toggle rescans and adds only present items, labeled clearly
- [ ] Extras section lists non-OS root folders unchecked; Public Docs/Desktop checked
- [ ] Totals row compares selection vs. free space, turns red when too big

## Step 4 — Copy
- [ ] Progress bar, current file, and counters update live
- [ ] Pause/Resume works; Cancel stops within a file or two
- [ ] OneDrive reparse files copy OK on a machine WITHOUT cldflt running
      (slave the drive, or test in a VM — this is the core feature)
- [ ] Cloud-only placeholders counted as CLOUD-ONLY, not errors
- [ ] `_RescueLog.csv` grows during the copy

## Step 5 — Done
- [ ] Summary counts match the CSV; cloud-only note shown when relevant
- [ ] Open backup folder / Open report buttons work
- [ ] `_RescueReport.html` renders with counts + problem list

## Resume & verify
- [ ] Existing-backup dialog appears when the job folder already has data
- [ ] Dialog "Keep both" switches to the suffixed name (e.g. "Tom Scott (2)") and updates the name field
- [ ] Dialog "Start over" ticks Re-copy everything; "Go back" returns to the name step
- [ ] Re-running the same job name skips everything (SKIP-EXISTS)
- [ ] "Re-copy everything" forces a full recopy
- [ ] Verify checkbox runs the SHA-256 pass and reports 0 mismatches
- [ ] Long path (>260 chars) file copies successfully
- [ ] Long path (>260 chars) copies under Windows PowerShell 5.1 specifically (not just pwsh 7)
- [ ] Disk-full run: fill destination, confirm copy halts with FATAL message and report still writes
- [ ] Open _RescueLog.csv in Excel, re-run the job: copy completes, problems list shows LOG-NOTE, timestamped fallback log appears
- [ ] Toggle AppData checkbox mid-scan: tree rebuilds without duplicate users

Sign-off: __________  Date: __________

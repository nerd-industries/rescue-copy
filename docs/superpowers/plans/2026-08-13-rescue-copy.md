# NN Rescue Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single-file PowerShell WPF GUI rescue tool served at `irm copy.nerdyneighbor.net | iex` that copies user data (including OneDrive cloud-reparse files) from a slaved customer drive to a backup drive.

**Architecture:** One self-contained script `NN-RescueCopy.ps1` — pure functions (paths, scanner, engine, reporter) + inline XAML WPF GUI + entry bootstrap. Pure functions are developed TDD with Pester on this Linux box (`$env:NN_RESCUE_NOGUI='1'` + dot-source = load functions without launching GUI; raw Win32 open falls back to `File.OpenRead` off-Windows as a test seam). Hosting is a Cloudflare Pages Function proxying the GitHub Contents API, cloned from the proven `openssh.nerdyneighbor.net` pattern.

**Tech Stack:** PowerShell 5.1/7 (script), WPF via inline XAML, Win32 `CreateFileW` P/Invoke, Pester 6 on pwsh 7.4.6 (Linux dev box), Cloudflare Pages + Functions, GitHub repo `nerd-industries/rescue-copy`.

**Spec:** `docs/superpowers/specs/2026-08-13-rescue-copy-design.md`

## Global Constraints

- `NN-RescueCopy.ps1` must run on Windows PowerShell 5.1 **and** PowerShell 7: no `??`, no ternary `? :`, no `-in`-on-null tricks, no PS7-only APIs.
- Single deployable file. No modules, no external binaries, no second fetch at runtime.
- Source drive is never written to. Ever.
- All work happens in `/root/rescue-copy`. Commit at the end of every task.
- Tests: `pwsh -NoProfile -Command "Invoke-Pester -Path tests"` (pwsh 7.4.6 + Pester 6.1.0, already installed at `/usr/local/bin/pwsh`).
- Tests set `$env:NN_RESCUE_NOGUI = '1'` then dot-source the script. The script's last line only launches the GUI when that var is not `'1'`.
- Off-Windows, `Open-NNSourceStream` uses `[IO.File]::OpenRead` instead of raw `CreateFileW`. That fallback exists ONLY so engine logic is testable on Linux; production is Windows-only.
- Constants are defined at script top level **unqualified** (`$NNProfileExclude = ...`, not `$script:`) so dot-sourcing tests, the main script, and injected background runspaces all resolve them by dynamic scoping.
- Result codes are exactly: `OK`, `SKIP-EXISTS`, `CLOUD-ONLY`, `OPEN-FAIL(err=N)`, `READ-FAIL(msg)`, `SIZE-MISMATCH(actual/expected)`, `HASH-MISMATCH`, `VERIFY-FAIL(msg)`.
- Paths are built with `Join-NNParts` (segment join) so tests work on Linux (`/`) and production on Windows (`\`). Never hard-code `\` into a path the tests touch.
- Dark theme tokens: window `#0F172A`, panel `#1E293B`, border `#334155`, text `#E2E8F0`, muted `#94A3B8`, accent `#38BDF8`, green `#4ADE80`, red `#F87171`, amber `#FBBF24`.
- GUI code (XAML string, `Start-NNRescueGui`, `Start-NNRescue`) cannot execute on this box. Its automated gate is: XAML parses as XML with all expected `x:Name`s, and the whole script parses cleanly via the PowerShell language parser. Behavior is verified by the bench checklist (Task 13).

---

### Task 1: Repo scaffold, test harness, script skeleton

**Files:**
- Create: `NN-RescueCopy.ps1`
- Create: `tests/Skeleton.Tests.ps1`
- Create: `.gitignore`

**Interfaces:**
- Produces: the dot-source-under-test pattern every later test file copies; `$NNIsWindows` (bool); `Start-NNRescue` (stub, replaced in Task 10); the `NN_RESCUE_NOGUI` entry guard.

- [ ] **Step 1: Write the failing test**

`tests/Skeleton.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
}

Describe 'script skeleton' {
    It 'defines the entry function without launching it' {
        Get-Command Start-NNRescue -CommandType Function | Should -Not -BeNullOrEmpty
    }
    It 'detects this box is not Windows' {
        $NNIsWindows | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: FAIL (script file does not exist).

- [ ] **Step 3: Write minimal implementation**

`NN-RescueCopy.ps1`:

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    NN Rescue Copy - Nerdy Neighbor GUI rescue-backup tool.
    Run:  irm copy.nerdyneighbor.net | iex
.DESCRIPTION
    Copies user data from a slaved customer drive to a backup drive, including
    OneDrive/Dropbox cloud-reparse files that robocopy/xcopy/Explorer cannot open
    (ERROR 1920) when cldflt.sys is not running. Read-only on the source drive.
    Full Windows only (WPF). See github.com/nerd-industries/rescue-copy.
#>

$NNIsWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'

# Captured at top level so the STA relauncher can persist the running script to disk.
$NNScriptPath = $PSCommandPath

#region Entry stub (replaced in Task 10)
function Start-NNRescue {
    Write-Host 'NN Rescue Copy: GUI not implemented yet.' -ForegroundColor Yellow
}
#endregion

if ($env:NN_RESCUE_NOGUI -ne '1') { Start-NNRescue }
```

`.gitignore`:

```
testresults*.xml
*.tmp
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: 2 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: script skeleton with test-mode entry guard"
```

---

### Task 2: Constants and path/naming utilities

**Files:**
- Modify: `NN-RescueCopy.ps1` (insert a `#region Constants` and `#region Path utilities` between the header and the Entry region)
- Create: `tests/Paths.Tests.ps1`

**Interfaces:**
- Produces:
  - `$NNOsExcludeRoot`, `$NNProfileExclude`, `$NNVisibleFolders`, `$NNAppDataDefs` (constants; exact contents below)
  - `Join-NNParts([string[]]$Parts) -> [string]` — joins segments with the platform separator
  - `ConvertTo-NNLongPath([string]$Path) -> [string]` — `\\?\` / `\\?\UNC\` form
  - `Get-NNSafeName([string]$Name) -> [string]` — strips invalid filename chars, trims, collapses whitespace
  - `Get-NNJobRoot([string]$BackupRoot, [string]$JobName) -> [string]` — `<BackupRoot>/NN-Rescue/<SafeName>`
  - `Format-NNBytes([long]$Bytes) -> [string]` — `1.5 GB` style
  - `New-NNTarget($Category,$User,$Label,$SourcePath,$DestRel,$Selected) -> [pscustomobject]` with properties `Category, User, Label, SourcePath, DestRel, SizeBytes, Selected`

- [ ] **Step 1: Write the failing test**

`tests/Paths.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
}

Describe 'ConvertTo-NNLongPath' {
    It 'prefixes a drive path' { ConvertTo-NNLongPath 'C:\Users\bob' | Should -Be '\\?\C:\Users\bob' }
    It 'leaves an already-long path alone' { ConvertTo-NNLongPath '\\?\C:\x' | Should -Be '\\?\C:\x' }
    It 'converts UNC paths' { ConvertTo-NNLongPath '\\srv\share\f' | Should -Be '\\?\UNC\srv\share\f' }
}

Describe 'Join-NNParts' {
    It 'joins with the platform separator' {
        Join-NNParts @('Users','bob','Desktop') |
            Should -Be ('Users' + [IO.Path]::DirectorySeparatorChar + 'bob' + [IO.Path]::DirectorySeparatorChar + 'Desktop')
    }
}

Describe 'Get-NNSafeName' {
    It 'strips invalid filename characters' { Get-NNSafeName 'Bob: PC / Home?' | Should -Be 'Bob PC Home' }
    It 'trims and collapses spaces' { Get-NNSafeName '  Tom   Scott  ' | Should -Be 'Tom Scott' }
}

Describe 'Get-NNJobRoot' {
    It 'builds the NN-Rescue layout' {
        Get-NNJobRoot '/backup' 'Tom Scott' | Should -Be (Join-NNParts @('/backup','NN-Rescue','Tom Scott'))
    }
}

Describe 'Format-NNBytes' {
    It 'formats GB' { Format-NNBytes 1610612736 | Should -Be '1.5 GB' }
    It 'formats MB' { Format-NNBytes 5242880 | Should -Be '5.0 MB' }
    It 'formats small numbers' { Format-NNBytes 512 | Should -Be '512 B' }
}

Describe 'constants' {
    It 'excludes OS root folders per spec' {
        foreach ($n in @('Windows','Program Files','Program Files (x86)','ProgramData','PerfLogs','Recovery',
                         'System Volume Information','$Recycle.Bin','$WinREAgent','Users','OneDriveTemp',
                         'Config.Msi','Intel','AMD','NVIDIA','Drivers','MSOCache','inetpub')) {
            $NNOsExcludeRoot | Should -Contain $n
        }
    }
    It 'excludes system profiles' {
        foreach ($n in @('Default','Default User','Public','All Users','defaultuser0','WDAGUtilityAccount')) {
            $NNProfileExclude | Should -Contain $n
        }
    }
}

Describe 'New-NNTarget' {
    It 'builds the target shape' {
        $t = New-NNTarget 'Profile' 'bob' 'Desktop' '/src/Users/bob/Desktop' (Join-NNParts @('Users','bob','Desktop')) $true
        $t.Category | Should -Be 'Profile'
        $t.User | Should -Be 'bob'
        $t.Selected | Should -BeTrue
        $t.SizeBytes | Should -Be $null
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Paths.Tests failures (functions not defined); Skeleton tests still pass.

- [ ] **Step 3: Write minimal implementation**

Insert into `NN-RescueCopy.ps1` after the `$NNScriptPath` line:

```powershell
#region Constants
$NNOsExcludeRoot = @('Windows','Program Files','Program Files (x86)','ProgramData','PerfLogs','Recovery',
    'System Volume Information','$Recycle.Bin','$WinREAgent','Users','OneDriveTemp','Config.Msi',
    'Intel','AMD','NVIDIA','Drivers','MSOCache','inetpub','Documents and Settings')
$NNProfileExclude = @('Default','Default User','Public','All Users','defaultuser0','WDAGUtilityAccount')
$NNVisibleFolders = @('Desktop','Documents','Pictures','Downloads','Videos','Music','Favorites')
# Each def: Label shown in GUI, Folder = destination folder name under AppData-Rescue, Segs = path under the profile dir
$NNAppDataDefs = @(
    @{ Label = 'Chrome (bookmarks, passwords, profiles)'; Folder = 'Chrome';        Segs = @('AppData','Local','Google','Chrome','User Data') }
    @{ Label = 'Edge (bookmarks, passwords, profiles)';   Folder = 'Edge';          Segs = @('AppData','Local','Microsoft','Edge','User Data') }
    @{ Label = 'Firefox profiles';                        Folder = 'Firefox';       Segs = @('AppData','Roaming','Mozilla','Firefox','Profiles') }
    @{ Label = 'Outlook data files (PST/OST)';            Folder = 'Outlook';       Segs = @('AppData','Local','Microsoft','Outlook') }
    @{ Label = 'Outlook Files (Documents)';               Folder = 'Outlook Files'; Segs = @('Documents','Outlook Files') }
    @{ Label = 'Windows Mail';                            Folder = 'WindowsMail';   Segs = @('AppData','Local','Comms') }
)
#endregion

#region Path utilities
function Join-NNParts {
    param([string[]]$Parts)
    $p = $Parts[0]
    for ($i = 1; $i -lt $Parts.Count; $i++) { $p = Join-Path $p $Parts[$i] }
    return $p
}

function ConvertTo-NNLongPath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\'))   { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Get-NNSafeName {
    param([string]$Name)
    # Fixed Windows-invalid set (NOT [IO.Path]::GetInvalidFileNameChars(): on the
    # Linux test box that set lacks ':' '?' etc., but job folders land on NTFS/exFAT).
    $invalid = [char[]]@('<', '>', ':', '"', '/', '\', '|', '?', '*')
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ([int]$ch -ge 32 -and $invalid -notcontains $ch) { $null = $sb.Append($ch) }
    }
    return (($sb.ToString() -replace '\s+', ' ').Trim())
}

function Get-NNJobRoot {
    param([string]$BackupRoot, [string]$JobName)
    return Join-NNParts @($BackupRoot, 'NN-Rescue', (Get-NNSafeName $JobName))
}

function Format-NNBytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function New-NNTarget {
    param([string]$Category, [string]$User, [string]$Label, [string]$SourcePath, [string]$DestRel, [bool]$Selected)
    [pscustomobject]@{
        Category   = $Category
        User       = $User
        Label      = $Label
        SourcePath = $SourcePath
        DestRel    = $DestRel
        SizeBytes  = $null
        Selected   = $Selected
    }
}
#endregion
```

Note `Get-NNSafeName 'Bob: PC / Home?'`: strip `:`,`/`,`?` → `'Bob PC  Home'` → collapse → `'Bob PC Home'`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all pass (2 + 13).

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: constants and path/naming utilities"
```

---

### Task 3: Source scanner

**Files:**
- Modify: `NN-RescueCopy.ps1` (new `#region Scanner` after Path utilities)
- Create: `tests/Scanner.Tests.ps1`

**Interfaces:**
- Consumes: `New-NNTarget`, `Join-NNParts`, constants (Task 2)
- Produces:
  - `Get-NNUserProfileDirs([string]$SourceRoot) -> [IO.DirectoryInfo[]]`
  - `Get-NNProfileTargets([IO.DirectoryInfo]$ProfileDir) -> target[]` (visible folders + `OneDrive*`, all `Selected=$true`, `DestRel=Users/<user>/<folder>`)
  - `Get-NNAppDataTargets([IO.DirectoryInfo]$ProfileDir) -> target[]` (`DestRel=Users/<user>/AppData-Rescue/<Folder>`, includes Sticky Notes package glob)
  - `Get-NNExtraTargets([string]$SourceRoot) -> target[]` (root extras `Selected=$false`; Public Documents/Desktop `Selected=$true`, other Public folders `$false`; ProgramData Intuit/Sage `$false`)
  - `Get-NNFolderSize([string]$Path) -> [long]`

- [ ] **Step 1: Write the failing test**

`tests/Scanner.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')

    # Synthetic customer drive
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("nnscan-" + [guid]::NewGuid().ToString('N'))
    foreach ($p in @(
        @('Users','bob','Desktop'), @('Users','bob','Documents'), @('Users','bob','OneDrive - Contoso','Tax'),
        @('Users','bob','AppData','Local','Google','Chrome','User Data','Default'),
        @('Users','bob','AppData','Local','Packages','Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe','LocalState'),
        @('Users','alice','Pictures'),
        @('Users','Default','Desktop'), @('Users','Public','Documents'), @('Users','Public','Music'),
        @('Windows','System32'), @('Program Files','App'), @('ProgramData','Intuit','QB'),
        @('Scans'), @('QuickBooksBackups')
    )) { $null = New-Item -ItemType Directory -Force -Path (Join-NNParts (@($script:Root) + $p)) }
    Set-Content -Path (Join-NNParts @($script:Root,'Users','bob','Desktop','a.txt')) -Value ('x' * 100)
    Set-Content -Path (Join-NNParts @($script:Root,'Users','bob','Desktop','b.txt')) -Value ('y' * 50)
}

AfterAll { Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue }

Describe 'Get-NNUserProfileDirs' {
    It 'lists real profiles only' {
        $names = (Get-NNUserProfileDirs $script:Root).Name | Sort-Object
        $names | Should -Be @('alice','bob')
    }
}

Describe 'Get-NNProfileTargets' {
    BeforeAll { $script:BobT = Get-NNProfileTargets (Get-Item (Join-NNParts @($script:Root,'Users','bob'))) }
    It 'finds existing visible folders and OneDrive dirs' {
        ($script:BobT | ForEach-Object Label | Sort-Object) | Should -Be @('Desktop','Documents','OneDrive - Contoso')
    }
    It 'is selected by default with the right DestRel' {
        $d = $script:BobT | Where-Object Label -eq 'Desktop'
        $d.Selected | Should -BeTrue
        $d.DestRel | Should -Be (Join-NNParts @('Users','bob','Desktop'))
    }
}

Describe 'Get-NNAppDataTargets' {
    BeforeAll { $script:BobA = Get-NNAppDataTargets (Get-Item (Join-NNParts @($script:Root,'Users','bob'))) }
    It 'finds Chrome and Sticky Notes only' {
        ($script:BobA | ForEach-Object Label | Sort-Object) |
            Should -Be @('Chrome (bookmarks, passwords, profiles)','Sticky Notes')
    }
    It 'routes into AppData-Rescue' {
        ($script:BobA | Where-Object Label -like 'Chrome*').DestRel |
            Should -Be (Join-NNParts @('Users','bob','AppData-Rescue','Chrome'))
    }
}

Describe 'Get-NNExtraTargets' {
    BeforeAll { $script:Extras = Get-NNExtraTargets $script:Root }
    It 'flags non-OS root folders, unselected' {
        $s = $script:Extras | Where-Object Label -eq 'Scans'
        $s | Should -Not -BeNullOrEmpty
        $s.Selected | Should -BeFalse
        ($script:Extras | ForEach-Object Label) | Should -Not -Contain 'Windows'
    }
    It 'selects Public Documents but not Public Music' {
        ($script:Extras | Where-Object { $_.Category -eq 'Public' -and $_.Label -eq 'Documents' }).Selected | Should -BeTrue
        ($script:Extras | Where-Object { $_.Category -eq 'Public' -and $_.Label -eq 'Music' }).Selected | Should -BeFalse
    }
    It 'finds QuickBooks ProgramData' {
        ($script:Extras | Where-Object Label -eq 'ProgramData Intuit') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-NNFolderSize' {
    It 'sums file bytes recursively' {
        Get-NNFolderSize (Join-NNParts @($script:Root,'Users','bob','Desktop')) | Should -BeGreaterOrEqual 150
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Scanner.Tests fail (functions not defined); earlier suites pass.

- [ ] **Step 3: Write minimal implementation**

Insert `#region Scanner` after Path utilities:

```powershell
#region Scanner
function Get-NNUserProfileDirs {
    param([string]$SourceRoot)
    $users = Join-Path $SourceRoot 'Users'
    if (-not (Test-Path -LiteralPath $users)) { return @() }
    @(Get-ChildItem -LiteralPath $users -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $NNProfileExclude -notcontains $_.Name })
}

function Get-NNProfileTargets {
    param([IO.DirectoryInfo]$ProfileDir)
    $u = $ProfileDir.Name
    $out = @()
    foreach ($n in $NNVisibleFolders) {
        $p = Join-Path $ProfileDir.FullName $n
        if (Test-Path -LiteralPath $p) {
            $out += New-NNTarget 'Profile' $u $n $p (Join-NNParts @('Users', $u, $n)) $true
        }
    }
    foreach ($od in @(Get-ChildItem -LiteralPath $ProfileDir.FullName -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
        $out += New-NNTarget 'Profile' $u $od.Name $od.FullName (Join-NNParts @('Users', $u, $od.Name)) $true
    }
    $out
}

function Get-NNAppDataTargets {
    param([IO.DirectoryInfo]$ProfileDir)
    $u = $ProfileDir.Name
    $out = @()
    foreach ($d in $NNAppDataDefs) {
        $p = Join-NNParts (@($ProfileDir.FullName) + $d.Segs)
        if (Test-Path -LiteralPath $p) {
            $out += New-NNTarget 'AppData' $u $d.Label $p (Join-NNParts @('Users', $u, 'AppData-Rescue', $d.Folder)) $true
        }
    }
    $pk = Join-NNParts @($ProfileDir.FullName, 'AppData', 'Local', 'Packages')
    if (Test-Path -LiteralPath $pk) {
        foreach ($sn in @(Get-ChildItem -LiteralPath $pk -Directory -Filter 'Microsoft.MicrosoftStickyNotes_*' -ErrorAction SilentlyContinue)) {
            $ls = Join-Path $sn.FullName 'LocalState'
            if (Test-Path -LiteralPath $ls) {
                $out += New-NNTarget 'AppData' $u 'Sticky Notes' $ls (Join-NNParts @('Users', $u, 'AppData-Rescue', 'StickyNotes')) $true
            }
        }
    }
    $out
}

function Get-NNExtraTargets {
    param([string]$SourceRoot)
    $out = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $SourceRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($NNOsExcludeRoot -notcontains $d.Name) {
            $out += New-NNTarget 'Extra' $null $d.Name $d.FullName (Join-NNParts @('Extras', $d.Name)) $false
        }
    }
    $pub = Join-NNParts @($SourceRoot, 'Users', 'Public')
    foreach ($n in @('Documents', 'Desktop', 'Pictures', 'Videos', 'Music', 'Downloads')) {
        $p = Join-Path $pub $n
        if (Test-Path -LiteralPath $p) {
            $sel = ($n -eq 'Documents') -or ($n -eq 'Desktop')
            $out += New-NNTarget 'Public' 'Public' $n $p (Join-NNParts @('Public', $n)) $sel
        }
    }
    foreach ($k in @(@('ProgramData', 'Intuit'), @('ProgramData', 'Sage'))) {
        $p = Join-NNParts (@($SourceRoot) + $k)
        if (Test-Path -LiteralPath $p) {
            $out += New-NNTarget 'Extra' $null ($k -join ' ') $p (Join-NNParts @('Extras', ($k -join '-'))) $false
        }
    }
    $out
}

function Get-NNFolderSize {
    param([string]$Path)
    $sum = [long]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        $sum += $f.Length
    }
    return $sum
}
#endregion
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: source scanner (profiles, appdata, extras, sizes)"
```

---

### Task 4: Registry hostname reader

**Files:**
- Modify: `NN-RescueCopy.ps1` (new `#region Hostname` after Scanner)
- Create: `tests/Hostname.Tests.ps1`

**Interfaces:**
- Produces:
  - `ConvertFrom-NNRegQuery([string[]]$Lines, [string]$ValueName) -> [string]|$null` — parses `reg.exe query` output
  - `Get-NNSourceHostname([string]$SourceRoot) -> [string]|$null` — Windows-only; loads the slaved SYSTEM hive read-then-unload; returns `$null` on any failure (GUI leaves the name blank)

- [ ] **Step 1: Write the failing test**

`tests/Hostname.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
}

Describe 'ConvertFrom-NNRegQuery' {
    It 'parses a REG_SZ value' {
        $lines = @(
            ''
            'HKEY_LOCAL_MACHINE\NN-RESCUE-SYS\ControlSet001\Control\ComputerName\ComputerName'
            '    ComputerName    REG_SZ    DESKTOP-TOM01'
            ''
        )
        ConvertFrom-NNRegQuery $lines 'ComputerName' | Should -Be 'DESKTOP-TOM01'
    }
    It 'parses a REG_DWORD value' {
        ConvertFrom-NNRegQuery @('    Current    REG_DWORD    0x1') 'Current' | Should -Be '0x1'
    }
    It 'returns null when absent' {
        ConvertFrom-NNRegQuery @('nothing here') 'ComputerName' | Should -Be $null
    }
}

Describe 'Get-NNSourceHostname' {
    It 'returns null off-Windows / when hive is missing' {
        Get-NNSourceHostname ([IO.Path]::GetTempPath()) | Should -Be $null
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Hostname.Tests fail (functions not defined).

- [ ] **Step 3: Write minimal implementation**

Insert `#region Hostname`:

```powershell
#region Hostname
function ConvertFrom-NNRegQuery {
    param([string[]]$Lines, [string]$ValueName)
    foreach ($l in $Lines) {
        if ($l -match ('^\s*' + [regex]::Escape($ValueName) + '\s+REG_\w+\s+(.+?)\s*$')) {
            return $Matches[1]
        }
    }
    return $null
}

function Get-NNSourceHostname {
    param([string]$SourceRoot)
    if (-not $NNIsWindows) { return $null }
    $hive = Join-NNParts @($SourceRoot, 'Windows', 'System32', 'config', 'SYSTEM')
    if (-not (Test-Path -LiteralPath $hive)) { return $null }
    $mount = 'HKLM\NN-RESCUE-SYS'
    & reg.exe load $mount $hive > $null 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    try {
        $sel = & reg.exe query "$mount\Select" /v Current 2>$null
        $cur = ConvertFrom-NNRegQuery $sel 'Current'
        if (-not $cur) { return $null }
        $n = [Convert]::ToInt32($cur, 16)
        $key = ('{0}\ControlSet{1:D3}\Control\ComputerName\ComputerName' -f $mount, $n)
        $q = & reg.exe query $key /v ComputerName 2>$null
        return (ConvertFrom-NNRegQuery $q 'ComputerName')
    } catch {
        return $null
    } finally {
        & reg.exe unload $mount > $null 2>&1
    }
}
#endregion
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: slaved-drive hostname reader via SYSTEM hive"
```

---

### Task 5: Raw-copy primitives

**Files:**
- Modify: `NN-RescueCopy.ps1` (new `#region Raw copy engine` after Hostname)
- Create: `tests/Engine.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-NNLongPath` (Task 2)
- Produces:
  - `[RawFileNative]::CreateFileW(...)` (Add-Type; compiles on Linux, callable only on Windows)
  - `Open-NNSourceStream([string]$Path) -> [IO.Stream]` — raw `CreateFileW` open on Windows (`FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS`), `File.OpenRead` elsewhere; throws `Win32Exception` on invalid handle
  - `Test-NNCloudOnly([IO.FileInfo]$File) -> [bool]`
  - `Copy-NNFile([IO.FileInfo]$Src, [string]$DestPath, [bool]$Force, [byte[]]$Buffer) -> [string]` result code

- [ ] **Step 1: Write the failing test**

`tests/Engine.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
    $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("nneng-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $script:Dir
    $script:SrcFile = Join-Path $script:Dir 'src.bin'
    $bytes = New-Object byte[] 300000
    (New-Object Random 42).NextBytes($bytes)
    [IO.File]::WriteAllBytes($script:SrcFile, $bytes)
}

AfterAll { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue }

Describe 'Open-NNSourceStream' {
    It 'opens and reads a file' {
        $s = Open-NNSourceStream $script:SrcFile
        try { $s.Length | Should -Be 300000 } finally { $s.Dispose() }
    }
}

Describe 'Copy-NNFile' {
    BeforeAll { $script:Buf = New-Object byte[] 1048576 }

    It 'copies, verifies size, preserves timestamps' {
        $dst = Join-Path $script:Dir 'out1.bin'
        $src = Get-Item $script:SrcFile
        $src.LastWriteTimeUtc = [datetime]'2020-05-05T10:00:00Z'
        Copy-NNFile -Src $src -DestPath $dst -Force $false -Buffer $script:Buf | Should -Be 'OK'
        (Get-Item $dst).Length | Should -Be 300000
        (Get-Item $dst).LastWriteTimeUtc | Should -Be ([datetime]'2020-05-05T10:00:00Z')
    }
    It 'skips an existing same-size destination' {
        $dst = Join-Path $script:Dir 'out1.bin'
        Copy-NNFile -Src (Get-Item $script:SrcFile) -DestPath $dst -Force $false -Buffer $script:Buf | Should -Be 'SKIP-EXISTS'
    }
    It 'recopies with Force' {
        $dst = Join-Path $script:Dir 'out1.bin'
        Copy-NNFile -Src (Get-Item $script:SrcFile) -DestPath $dst -Force $true -Buffer $script:Buf | Should -Be 'OK'
    }
    It 'reports OPEN-FAIL for an unreadable source' {
        $gone = Join-Path $script:Dir 'gone.bin'
        Set-Content -Path $gone -Value 'x'
        $info = Get-Item $gone
        Remove-Item $gone
        $r = Copy-NNFile -Src $info -DestPath (Join-Path $script:Dir 'out2.bin') -Force $false -Buffer $script:Buf
        $r | Should -Match '^OPEN-FAIL'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Engine.Tests fail (functions not defined).

- [ ] **Step 3: Write minimal implementation**

Insert `#region Raw copy engine`:

```powershell
#region Raw copy engine
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RawFileNative {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr sec, uint disposition, uint flags, IntPtr template);
}
'@ -ErrorAction SilentlyContinue

# Decimal constants: PS5.1 parses large hex literals as negative int32
$NNGenericRead    = [uint32]2147483648   # 0x80000000
$NNShareAll       = [uint32]7            # READ | WRITE | DELETE
$NNOpenExisting   = [uint32]3
$NNRawFlags       = [uint32]35651584     # FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT
$NNCloudOnlyAttrs = 4198400              # FILE_ATTRIBUTE_OFFLINE (0x1000) | RECALL_ON_DATA_ACCESS (0x400000)

function Open-NNSourceStream {
    param([string]$Path)
    if (-not $NNIsWindows) { return [IO.File]::OpenRead($Path) }   # test seam: prod is Windows-only
    $h = [RawFileNative]::CreateFileW((ConvertTo-NNLongPath $Path), $NNGenericRead, $NNShareAll,
        [IntPtr]::Zero, $NNOpenExisting, $NNRawFlags, [IntPtr]::Zero)
    if ($h.IsInvalid) {
        throw (New-Object ComponentModel.Win32Exception ([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
    return (New-Object IO.FileStream ($h, [IO.FileAccess]::Read))
}

function Test-NNCloudOnly {
    param([IO.FileInfo]$File)
    return ((([int]$File.Attributes) -band $NNCloudOnlyAttrs) -ne 0)
}

function Copy-NNFile {
    param([IO.FileInfo]$Src, [string]$DestPath, [bool]$Force, [byte[]]$Buffer)
    if (Test-NNCloudOnly $Src) { return 'CLOUD-ONLY' }
    # Long-path-safe destination (>260 chars); no-op off Windows (test seam)
    if ($NNIsWindows) { $DestPath = ConvertTo-NNLongPath $DestPath }
    $dstInfo = New-Object IO.FileInfo ($DestPath)
    if (-not $Force -and $dstInfo.Exists -and $dstInfo.Length -eq $Src.Length) { return 'SKIP-EXISTS' }

    $in = $null
    try { $in = Open-NNSourceStream $Src.FullName }
    catch {
        $code = $_.Exception.Message
        if ($_.Exception -is [ComponentModel.Win32Exception]) { $code = 'err=' + $_.Exception.NativeErrorCode }
        if ($_.Exception.InnerException -is [ComponentModel.Win32Exception]) { $code = 'err=' + $_.Exception.InnerException.NativeErrorCode }
        if ($_.Exception -is [IO.FileNotFoundException] -or $_.Exception -is [IO.DirectoryNotFoundException]) { $code = 'err=2' }
        return "OPEN-FAIL($code)"
    }
    $out = $null
    try {
        $out = [IO.File]::Create($DestPath)
        while (($n = $in.Read($Buffer, 0, $Buffer.Length)) -gt 0) { $out.Write($Buffer, 0, $n) }
    } catch {
        return "READ-FAIL($($_.Exception.Message))"
    } finally {
        if ($in)  { $in.Dispose() }
        if ($out) { $out.Dispose() }
    }
    $dstInfo.Refresh()
    if ($dstInfo.Length -ne $Src.Length) { return "SIZE-MISMATCH($($dstInfo.Length)/$($Src.Length))" }
    try {
        $dstInfo.CreationTimeUtc  = $Src.CreationTimeUtc
        $dstInfo.LastWriteTimeUtc = $Src.LastWriteTimeUtc
    } catch { }
    return 'OK'
}
#endregion
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: raw-copy primitives with cloud-only detection"
```

---

### Task 6: Job runner with progress queue and CSV log

**Files:**
- Modify: `NN-RescueCopy.ps1` (extend `#region Raw copy engine`)
- Create: `tests/Job.Tests.ps1`

**Interfaces:**
- Consumes: `Copy-NNFile`, targets (Task 3 shape), `ConvertTo-NNLongPath`
- Produces:
  - `Invoke-NNCopyJob($Targets, [string]$JobRoot, $Control, $Queue, [bool]$Force)` — `$Control` is `[hashtable]::Synchronized(@{Cancel=$false;Pause=$false})`; `$Queue` is `ConcurrentQueue[object]`. Posts messages:
    - `@{Type='plan'; Count; Bytes}` once, before copying
    - `@{Type='file'; Result; Path; BytesDone; Index}` per file
    - `@{Type='done'; Summary=[hashtable code->count]; Problems=[List[string]]; Pairs=[List[@{Src;Dst}]]; Cancelled=[bool]; BytesDone=[long]}` once
  - Appends `_RescueLog.csv` in `$JobRoot` (streamed; header `Time,Result,Bytes,Source,Destination`)

- [ ] **Step 1: Write the failing test**

`tests/Job.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')

    $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("nnjob-" + [guid]::NewGuid().ToString('N'))
    $src = Join-NNParts @($script:Dir, 'drive', 'Users', 'bob', 'Desktop')
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $src 'inner')
    Set-Content -Path (Join-Path $src 'one.txt') -Value 'hello'
    Set-Content -Path (Join-NNParts @($src, 'inner', 'two.txt')) -Value 'world!'
    $script:JobRoot = Join-Path $script:Dir 'backup'
    $script:Target = New-NNTarget 'Profile' 'bob' 'Desktop' $src (Join-NNParts @('Users','bob','Desktop')) $true
}

AfterAll { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue }

Describe 'Invoke-NNCopyJob' {
    BeforeAll {
        $script:Q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:Ctl = [hashtable]::Synchronized(@{ Cancel = $false; Pause = $false })
        Invoke-NNCopyJob -Targets @($script:Target) -JobRoot $script:JobRoot -Control $script:Ctl -Queue $script:Q -Force $false
        $script:Msgs = @(); $m = $null
        while ($script:Q.TryDequeue([ref]$m)) { $script:Msgs += $m }
    }
    It 'posts plan, per-file, and done messages' {
        $script:Msgs[0].Type | Should -Be 'plan'
        $script:Msgs[0].Count | Should -Be 2
        ($script:Msgs | Where-Object Type -eq 'file').Count | Should -Be 2
        ($script:Msgs | Where-Object Type -eq 'done').Count | Should -Be 1
    }
    It 'copies the tree preserving structure' {
        Test-Path (Join-NNParts @($script:JobRoot, 'Users', 'bob', 'Desktop', 'inner', 'two.txt')) | Should -BeTrue
    }
    It 'reports OK counts and collects verify pairs' {
        $done = $script:Msgs | Where-Object Type -eq 'done'
        $done.Summary['OK'] | Should -Be 2
        $done.Pairs.Count | Should -Be 2
        $done.Cancelled | Should -BeFalse
    }
    It 'streams a CSV log with header' {
        $csv = Get-Content (Join-Path $script:JobRoot '_RescueLog.csv')
        $csv[0] | Should -Be 'Time,Result,Bytes,Source,Destination'
        $csv.Count | Should -Be 3
    }
    It 'is incremental on re-run' {
        $q2 = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Invoke-NNCopyJob -Targets @($script:Target) -JobRoot $script:JobRoot -Control $script:Ctl -Queue $q2 -Force $false
        $m = $null; $msgs = @()
        while ($q2.TryDequeue([ref]$m)) { $msgs += $m }
        ($msgs | Where-Object Type -eq 'done').Summary['SKIP-EXISTS'] | Should -Be 2
    }
    It 'honors cancel' {
        $q3 = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $ctl3 = [hashtable]::Synchronized(@{ Cancel = $true; Pause = $false })
        Invoke-NNCopyJob -Targets @($script:Target) -JobRoot $script:JobRoot -Control $ctl3 -Queue $q3 -Force $true
        $m = $null; $msgs = @()
        while ($q3.TryDequeue([ref]$m)) { $msgs += $m }
        ($msgs | Where-Object Type -eq 'done').Cancelled | Should -BeTrue
        ($msgs | Where-Object Type -eq 'file').Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Job.Tests fail (`Invoke-NNCopyJob` not defined).

- [ ] **Step 3: Write minimal implementation**

Append inside `#region Raw copy engine`, after `Copy-NNFile`:

```powershell
function Invoke-NNCopyJob {
    param($Targets, [string]$JobRoot, $Control, $Queue, [bool]$Force)

    # Pass 1: enumerate work
    $files = New-Object System.Collections.Generic.List[object]
    $totalBytes = [long]0
    foreach ($t in $Targets) {
        $src = Get-Item -Force -LiteralPath $t.SourcePath -ErrorAction SilentlyContinue
        if (-not $src) { continue }
        if ($src.PSIsContainer) {
            foreach ($f in @(Get-ChildItem -LiteralPath $src.FullName -Recurse -Force -File -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName.Substring($src.FullName.Length).TrimStart('\', '/')
                $files.Add(@{ File = $f; Dest = (Join-Path (Join-Path $JobRoot $t.DestRel) $rel) })
                $totalBytes += $f.Length
            }
        } else {
            $files.Add(@{ File = $src; Dest = (Join-Path $JobRoot $t.DestRel) })
            $totalBytes += $src.Length
        }
    }
    $Queue.Enqueue(@{ Type = 'plan'; Count = $files.Count; Bytes = $totalBytes })

    $null = [IO.Directory]::CreateDirectory($JobRoot)
    $csvPath = Join-Path $JobRoot '_RescueLog.csv'
    $newCsv = -not (Test-Path -LiteralPath $csvPath)
    $csv = New-Object IO.StreamWriter ($csvPath, $true, [Text.Encoding]::UTF8)
    if ($newCsv) { $csv.WriteLine('Time,Result,Bytes,Source,Destination') }

    $buffer   = New-Object byte[] 1048576
    $summary  = @{}
    $problems = New-Object System.Collections.Generic.List[string]
    $pairs    = New-Object System.Collections.Generic.List[object]
    $done = [long]0
    $i = 0
    $lastDir = ''
    try {
        foreach ($item in $files) {
            while ($Control.Pause -and -not $Control.Cancel) { Start-Sleep -Milliseconds 200 }
            if ($Control.Cancel) { break }

            $destDir = Split-Path $item.Dest
            if ($destDir -ne $lastDir) {
                $mkDir = $destDir
                if ($NNIsWindows) { $mkDir = ConvertTo-NNLongPath $mkDir }
                $null = [IO.Directory]::CreateDirectory($mkDir)
                $lastDir = $destDir
            }

            $r = Copy-NNFile -Src $item.File -DestPath $item.Dest -Force $Force -Buffer $buffer
            if ($summary.ContainsKey($r)) { $summary[$r]++ } else { $summary[$r] = 1 }
            if ($r -eq 'OK') { $pairs.Add(@{ Src = $item.File.FullName; Dst = $item.Dest }) }
            if ($r -ne 'OK' -and $r -ne 'SKIP-EXISTS') { $problems.Add("$r  $($item.File.FullName)") }
            $done += $item.File.Length
            $i++
            $csv.WriteLine(('{0:o},{1},{2},"{3}","{4}"' -f [DateTime]::UtcNow, $r, $item.File.Length,
                $item.File.FullName.Replace('"', '""'), $item.Dest.Replace('"', '""')))
            $Queue.Enqueue(@{ Type = 'file'; Result = $r; Path = $item.File.FullName; BytesDone = $done; Index = $i })
        }
    } finally {
        $csv.Dispose()
    }
    $Queue.Enqueue(@{ Type = 'done'; Summary = $summary; Problems = $problems; Pairs = $pairs
                      Cancelled = [bool]$Control.Cancel; BytesDone = $done })
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: copy job runner with progress queue, CSV log, pause/cancel"
```

---

### Task 7: Verify pass

**Files:**
- Modify: `NN-RescueCopy.ps1` (new `#region Verify` after the engine region)
- Create: `tests/Verify.Tests.ps1`

**Interfaces:**
- Consumes: `Open-NNSourceStream` (Task 5)
- Produces:
  - `Get-NNFileHash([string]$Path) -> [string]` — uppercase SHA-256 hex, source opened raw on Windows
  - `Invoke-NNVerifyPass($Pairs, $Control, $Queue) -> [List[string]]` — `$Pairs` from the job's `done` message. Posts `@{Type='verify'; Index; Total}` per pair and `@{Type='verifydone'; Mismatches}` at the end; returns the mismatch list (entries `HASH-MISMATCH  <src>` or `VERIFY-FAIL(msg)  <src>`)

- [ ] **Step 1: Write the failing test**

`tests/Verify.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
    $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("nnver-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $script:Dir
    Set-Content -NoNewline -Path (Join-Path $script:Dir 'a.txt') -Value 'same content'
    Set-Content -NoNewline -Path (Join-Path $script:Dir 'b.txt') -Value 'same content'
    Set-Content -NoNewline -Path (Join-Path $script:Dir 'c.txt') -Value 'DIFFERENT!!!'
}

AfterAll { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue }

Describe 'Get-NNFileHash' {
    It 'matches Get-FileHash SHA256' {
        $expected = (Get-FileHash -Algorithm SHA256 (Join-Path $script:Dir 'a.txt')).Hash
        Get-NNFileHash (Join-Path $script:Dir 'a.txt') | Should -Be $expected
    }
}

Describe 'Invoke-NNVerifyPass' {
    It 'passes identical pairs and flags different ones' {
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $ctl = [hashtable]::Synchronized(@{ Cancel = $false; Pause = $false })
        $pairs = @(
            @{ Src = (Join-Path $script:Dir 'a.txt'); Dst = (Join-Path $script:Dir 'b.txt') }
            @{ Src = (Join-Path $script:Dir 'a.txt'); Dst = (Join-Path $script:Dir 'c.txt') }
            @{ Src = (Join-Path $script:Dir 'a.txt'); Dst = (Join-Path $script:Dir 'missing.txt') }
        )
        $mm = Invoke-NNVerifyPass -Pairs $pairs -Control $ctl -Queue $q
        $mm.Count | Should -Be 2
        $mm[0] | Should -Match '^HASH-MISMATCH'
        $mm[1] | Should -Match '^VERIFY-FAIL'
        $m = $null; $msgs = @()
        while ($q.TryDequeue([ref]$m)) { $msgs += $m }
        ($msgs | Where-Object Type -eq 'verify').Count | Should -Be 3
        ($msgs | Where-Object Type -eq 'verifydone').Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Verify.Tests fail (functions not defined).

- [ ] **Step 3: Write minimal implementation**

Insert `#region Verify`:

```powershell
#region Verify
function Get-NNFileHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $s = Open-NNSourceStream $Path
    try {
        $buf = New-Object byte[] 1048576
        while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) {
            $null = $sha.TransformBlock($buf, 0, $n, $null, 0)
        }
        $null = $sha.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
    } finally {
        $s.Dispose()
        $sha.Dispose()
    }
}

function Invoke-NNVerifyPass {
    param($Pairs, $Control, $Queue)
    $mismatch = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($p in $Pairs) {
        if ($Control.Cancel) { break }
        try {
            $a = Get-NNFileHash $p.Src
            $b = Get-NNFileHash $p.Dst
            if ($a -ne $b) { $mismatch.Add("HASH-MISMATCH  $($p.Src)") }
        } catch {
            $mismatch.Add("VERIFY-FAIL($($_.Exception.Message))  $($p.Src)")
        }
        $i++
        $Queue.Enqueue(@{ Type = 'verify'; Index = $i; Total = @($Pairs).Count })
    }
    $Queue.Enqueue(@{ Type = 'verifydone'; Mismatches = $mismatch })
    return $mismatch
}
#endregion
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: optional SHA-256 verify pass"
```

---

### Task 8: HTML report

**Files:**
- Modify: `NN-RescueCopy.ps1` (new `#region Report` after Verify)
- Create: `tests/Report.Tests.ps1`

**Interfaces:**
- Consumes: `Format-NNBytes` (Task 2)
- Produces: `New-NNHtmlReport([hashtable]$Summary, [string[]]$Problems, [string]$JobName, [long]$Bytes, [string]$OutPath)` — writes a self-contained dark-themed HTML file; returns `$OutPath`

- [ ] **Step 1: Write the failing test**

`tests/Report.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
    $script:Out = Join-Path ([IO.Path]::GetTempPath()) ("nnrep-" + [guid]::NewGuid().ToString('N') + '.html')
}

AfterAll { Remove-Item -Force $script:Out -ErrorAction SilentlyContinue }

Describe 'New-NNHtmlReport' {
    It 'writes a report containing counts, problems, and cloud-only guidance' {
        $summary = @{ 'OK' = 240; 'CLOUD-ONLY' = 4; 'OPEN-FAIL(err=1392)' = 1 }
        $problems = @('OPEN-FAIL(err=1392)  C:\Users\bob\Desktop\bad.docx')
        $path = New-NNHtmlReport -Summary $summary -Problems $problems -JobName 'Tom Scott' -Bytes 1739461755 -OutPath $script:Out
        $path | Should -Be $script:Out
        $html = Get-Content -Raw $script:Out
        $html | Should -Match 'Tom Scott'
        $html | Should -Match '240'
        $html | Should -Match 'CLOUD-ONLY'
        $html | Should -Match 'bad\.docx'
        $html | Should -Match 'sign'   # cloud-only sign-in guidance present
        $html | Should -Match '1\.6 GB'
    }
    It 'HTML-encodes problem paths' {
        $path = New-NNHtmlReport -Summary @{ OK = 1 } -Problems @('READ-FAIL(x<y&z)  C:\f.txt') -JobName 'j' -Bytes 10 -OutPath $script:Out
        (Get-Content -Raw $script:Out) | Should -Match 'x&lt;y&amp;z'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Report.Tests fail (function not defined).

- [ ] **Step 3: Write minimal implementation**

Insert `#region Report`:

```powershell
#region Report
function New-NNHtmlReport {
    param([hashtable]$Summary, [string[]]$Problems, [string]$JobName, [long]$Bytes, [string]$OutPath)

    function Encode-NNHtml { param([string]$s)
        return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    }

    $rows = ''
    foreach ($k in ($Summary.Keys | Sort-Object)) {
        $color = '#e2e8f0'
        if ($k -eq 'OK') { $color = '#4ade80' }
        elseif ($k -eq 'SKIP-EXISTS') { $color = '#94a3b8' }
        elseif ($k -eq 'CLOUD-ONLY') { $color = '#fbbf24' }
        else { $color = '#f87171' }
        $rows += ('<tr><td style="color:{0}">{1}</td><td style="text-align:right">{2}</td></tr>' -f $color, (Encode-NNHtml $k), $Summary[$k])
    }

    $probHtml = ''
    if (@($Problems).Count -gt 0) {
        $items = ''
        foreach ($p in $Problems) { $items += ('<li><code>{0}</code></li>' -f (Encode-NNHtml $p)) }
        $probHtml = ('<h2>Files needing attention</h2><ul>{0}</ul>' -f $items)
    }

    $cloudHtml = ''
    $cloudCount = 0
    foreach ($k in $Summary.Keys) { if ($k -eq 'CLOUD-ONLY') { $cloudCount = $Summary[$k] } }
    if ($cloudCount -gt 0) {
        $cloudHtml = ('<div class="note"><strong>{0} cloud-only file(s) were skipped.</strong> ' +
            'These files live only in the customer''s cloud account (OneDrive/Dropbox) - there is no local data on the drive. ' +
            'To recover them, sign into the account on a working machine and let them download.</div>') -f $cloudCount
    }

    $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>NN Rescue Report - $(Encode-NNHtml $JobName)</title>
<style>
body{font-family:'Segoe UI',Arial,sans-serif;background:#0f172a;color:#e2e8f0;max-width:860px;margin:40px auto;padding:0 20px;line-height:1.5}
h1{color:#38bdf8;margin-bottom:2px} .sub{color:#94a3b8;margin-top:0}
table{border-collapse:collapse;min-width:340px} td{padding:6px 14px;border-bottom:1px solid #334155}
.note{background:#1e293b;border-left:4px solid #fbbf24;padding:12px 16px;border-radius:6px;margin:18px 0}
code{color:#f87171;word-break:break-all} ul{padding-left:18px} li{margin:4px 0}
</style></head><body>
<h1>NN Rescue Copy</h1>
<p class="sub">Job: $(Encode-NNHtml $JobName) &middot; $(Format-NNBytes $Bytes) processed &middot; $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm'))</p>
<h2>Results</h2><table>$rows</table>
$cloudHtml
$probHtml
<p class="sub">Nerdy Neighbor &middot; copy.nerdyneighbor.net</p>
</body></html>
"@
    [IO.File]::WriteAllText($OutPath, $html, [Text.Encoding]::UTF8)
    return $OutPath
}
#endregion
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: HTML rescue report"
```

---

### Task 9: Selection model and XAML layout

**Files:**
- Modify: `NN-RescueCopy.ps1` (new `#region Selection model` and `#region XAML` after Report)
- Create: `tests/Gui.Tests.ps1`

**Interfaces:**
- Consumes: scanner functions (Task 3), `Format-NNBytes`
- Produces:
  - `Build-NNSelectionModel([string]$SourceRoot, [bool]$IncludeAppData) -> List[@{Header; Items=target[]}]` — one group per user (profile + optional AppData targets) plus an `'Extras found on drive'` group
  - `Get-NNSelectedBytes($Model) -> [long]` — sum of `Selected` items' non-null `SizeBytes`
  - `$NNXaml` — the full window XAML string. Named controls (`x:Name`) that Task 10 wires: `RailStep1..RailStep5`, `PanelStep1..PanelStep5`, `LvSource`, `LvDest`, `BtnBrowseSource`, `BtnRescan`, `TxtSrcPick`, `TxtJobName`, `TxtDestPreview`, `TxtJobHint`, `ChkAppData`, `ChkVerify`, `ChkForce`, `TreeSel`, `TxtTotals`, `TxtScanStatus`, `PbOverall`, `TxtPhase`, `TxtCurrentFile`, `TxtCounters`, `LbProblems`, `BtnPause`, `BtnCancelCopy`, `TxtSummary`, `TxtCloudNote`, `LbFinalProblems`, `BtnOpenDest`, `BtnOpenReport`, `BtnBack`, `BtnNext`

- [ ] **Step 1: Write the failing test**

`tests/Gui.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')

    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("nngui-" + [guid]::NewGuid().ToString('N'))
    foreach ($p in @(
        @('Users','bob','Desktop'),
        @('Users','bob','AppData','Local','Google','Chrome','User Data'),
        @('Windows'), @('Scans')
    )) { $null = New-Item -ItemType Directory -Force -Path (Join-NNParts (@($script:Root) + $p)) }
    Set-Content -Path (Join-NNParts @($script:Root,'Users','bob','Desktop','f.txt')) -Value 'data'
}

AfterAll { Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue }

Describe 'Build-NNSelectionModel' {
    It 'groups per user without appdata by default' {
        $m = Build-NNSelectionModel $script:Root $false
        @($m).Count | Should -Be 2
        $m[0].Header | Should -Be 'User: bob'
        ($m[0].Items | ForEach-Object Category) | Should -Not -Contain 'AppData'
        $m[1].Header | Should -Be 'Extras found on drive'
    }
    It 'adds appdata targets when requested' {
        $m = Build-NNSelectionModel $script:Root $true
        ($m[0].Items | Where-Object Category -eq 'AppData').Count | Should -Be 1
    }
}

Describe 'Get-NNSelectedBytes' {
    It 'sums only selected, sized items' {
        $m = Build-NNSelectionModel $script:Root $false
        foreach ($g in $m) { foreach ($i in $g.Items) { $i.SizeBytes = 100 } }
        $m[1].Items[0].Selected = $false
        $total = Get-NNSelectedBytes $m
        $total | Should -Be 100   # bob/Desktop selected; the single extra (Scans) deselected
    }
}

Describe 'XAML' {
    BeforeAll { $script:Doc = [xml]$NNXaml }
    It 'is valid XML' { $script:Doc.Window | Should -Not -BeNullOrEmpty }
    It 'contains every control Task 10 wires' {
        $names = $script:Doc.SelectNodes('//*/@*') |
            Where-Object { $_.LocalName -eq 'Name' } | ForEach-Object Value
        foreach ($n in @('RailStep1','RailStep2','RailStep3','RailStep4','RailStep5',
                         'PanelStep1','PanelStep2','PanelStep3','PanelStep4','PanelStep5',
                         'LvSource','LvDest','BtnBrowseSource','BtnRescan','TxtSrcPick',
                         'TxtJobName','TxtDestPreview','TxtJobHint',
                         'ChkAppData','ChkVerify','ChkForce','TreeSel','TxtTotals','TxtScanStatus',
                         'PbOverall','TxtPhase','TxtCurrentFile','TxtCounters','LbProblems','BtnPause','BtnCancelCopy',
                         'TxtSummary','TxtCloudNote','LbFinalProblems','BtnOpenDest','BtnOpenReport',
                         'BtnBack','BtnNext')) {
            $names | Should -Contain $n
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Gui.Tests fail (`Build-NNSelectionModel`/`$NNXaml` missing).

- [ ] **Step 3: Write minimal implementation**

Insert `#region Selection model`:

```powershell
#region Selection model
function Build-NNSelectionModel {
    param([string]$SourceRoot, [bool]$IncludeAppData)
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($pd in @(Get-NNUserProfileDirs $SourceRoot)) {
        $items = @(Get-NNProfileTargets $pd)
        if ($IncludeAppData) { $items += @(Get-NNAppDataTargets $pd) }
        if ($items.Count -gt 0) { $groups.Add(@{ Header = "User: $($pd.Name)"; Items = $items }) }
    }
    $extras = @(Get-NNExtraTargets $SourceRoot)
    if ($extras.Count -gt 0) { $groups.Add(@{ Header = 'Extras found on drive'; Items = $extras }) }
    return ,$groups
}

function Get-NNSelectedBytes {
    param($Model)
    $s = [long]0
    foreach ($g in $Model) {
        foreach ($i in $g.Items) {
            if ($i.Selected -and $null -ne $i.SizeBytes) { $s += [long]$i.SizeBytes }
        }
    }
    return $s
}
#endregion
```

Insert `#region XAML` (the full string; single-quoted here-string so `$` needs no escaping):

```powershell
#region XAML
$NNXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NN Rescue Copy" Height="700" Width="1040" WindowStartupLocation="CenterScreen"
        Background="#0F172A" Foreground="#E2E8F0" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#1E3A5F"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="BorderBrush" Value="#334155"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="ListView">
      <Setter Property="Background" Value="#1E293B"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="BorderBrush" Value="#334155"/>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="#1E293B"/>
      <Setter Property="Foreground" Value="#F87171"/>
      <Setter Property="BorderBrush" Value="#334155"/>
    </Style>
    <Style TargetType="TreeView">
      <Setter Property="Background" Value="#1E293B"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="BorderBrush" Value="#334155"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1E293B"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="BorderBrush" Value="#334155"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="15"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Margin" Value="0,4"/>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="#334155"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Padding" Value="8,4"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <!-- Left step rail -->
    <StackPanel DockPanel.Dock="Left" Width="190" Background="#1E293B">
      <TextBlock Text="NN Rescue Copy" FontSize="17" FontWeight="Bold" Foreground="#38BDF8" Margin="18,20,10,4"/>
      <TextBlock Text="Nerdy Neighbor" Foreground="#94A3B8" Margin="18,0,10,24"/>
      <TextBlock x:Name="RailStep1" Text="1  Drives"      Margin="18,6" FontWeight="Bold" Foreground="#38BDF8"/>
      <TextBlock x:Name="RailStep2" Text="2  Job name"    Margin="18,6" Foreground="#94A3B8"/>
      <TextBlock x:Name="RailStep3" Text="3  Selection"   Margin="18,6" Foreground="#94A3B8"/>
      <TextBlock x:Name="RailStep4" Text="4  Copy"        Margin="18,6" Foreground="#94A3B8"/>
      <TextBlock x:Name="RailStep5" Text="5  Done"        Margin="18,6" Foreground="#94A3B8"/>
    </StackPanel>
    <!-- Bottom nav -->
    <Border DockPanel.Dock="Bottom" Background="#1E293B" Padding="16,10">
      <DockPanel>
        <Button x:Name="BtnBack" Content="Back" DockPanel.Dock="Left" Width="110" Visibility="Hidden"/>
        <Button x:Name="BtnNext" Content="Next" DockPanel.Dock="Right" Width="150" HorizontalAlignment="Right" Background="#0369A1"/>
        <TextBlock/>
      </DockPanel>
    </Border>
    <!-- Content -->
    <Grid Margin="20">
      <!-- Step 1: Drives -->
      <Grid x:Name="PanelStep1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Customer drive (source) - read-only" FontSize="15" FontWeight="Bold" Margin="0,0,0,6"/>
        <ListView Grid.Row="1" x:Name="LvSource">
          <ListView.View><GridView>
            <GridViewColumn Header="Drive" Width="70" DisplayMemberBinding="{Binding Drive}"/>
            <GridViewColumn Header="Label" Width="180" DisplayMemberBinding="{Binding Label}"/>
            <GridViewColumn Header="Size" Width="100" DisplayMemberBinding="{Binding Size}"/>
            <GridViewColumn Header="Free" Width="100" DisplayMemberBinding="{Binding Free}"/>
            <GridViewColumn Header="Contents" Width="220" DisplayMemberBinding="{Binding Contents}"/>
          </GridView></ListView.View>
        </ListView>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,8">
          <TextBlock Text="Backup drive (destination)" FontSize="15" FontWeight="Bold" VerticalAlignment="Center"/>
          <Button x:Name="BtnBrowseSource" Content="Browse folder as source..." Margin="20,0,8,0" Padding="10,4"/>
          <Button x:Name="BtnRescan" Content="Rescan drives" Padding="10,4"/>
          <TextBlock x:Name="TxtSrcPick" Foreground="#4ADE80" Margin="14,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <ListView Grid.Row="3" x:Name="LvDest">
          <ListView.View><GridView>
            <GridViewColumn Header="Drive" Width="70" DisplayMemberBinding="{Binding Drive}"/>
            <GridViewColumn Header="Label" Width="180" DisplayMemberBinding="{Binding Label}"/>
            <GridViewColumn Header="Size" Width="100" DisplayMemberBinding="{Binding Size}"/>
            <GridViewColumn Header="Free" Width="100" DisplayMemberBinding="{Binding Free}"/>
            <GridViewColumn Header="Contents" Width="220" DisplayMemberBinding="{Binding Contents}"/>
          </GridView></ListView.View>
        </ListView>
        <TextBlock Grid.Row="4" Foreground="#94A3B8" Margin="0,8,0,0"
                   Text="The source drive is only ever read. Pick the slaved customer drive on top, your rescue disk below."/>
      </Grid>
      <!-- Step 2: Job name -->
      <StackPanel x:Name="PanelStep2" Visibility="Collapsed" MaxWidth="560" VerticalAlignment="Center">
        <TextBlock Text="Customer / job name" FontSize="15" FontWeight="Bold" Margin="0,0,0,6"/>
        <TextBox x:Name="TxtJobName"/>
        <TextBlock x:Name="TxtJobHint" Foreground="#94A3B8" Margin="0,6,0,0" Text="Prefilled from the customer drive's registry when readable."/>
        <TextBlock Text="Backup will be written to:" Foreground="#94A3B8" Margin="0,22,0,2"/>
        <TextBlock x:Name="TxtDestPreview" Foreground="#4ADE80" FontFamily="Consolas" TextWrapping="Wrap"/>
        <TextBlock Foreground="#94A3B8" Margin="0,14,0,0" TextWrapping="Wrap"
                   Text="Re-using an existing job name resumes it: files already copied with matching sizes are skipped."/>
      </StackPanel>
      <!-- Step 3: Selection -->
      <Grid x:Name="PanelStep3" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
          <CheckBox x:Name="ChkAppData" Content="Include key AppData (browsers, Outlook PST/OST, Sticky Notes, Windows Mail)"/>
          <CheckBox x:Name="ChkVerify" Content="Verify after copy (SHA-256)" Margin="24,4,0,4"/>
          <CheckBox x:Name="ChkForce" Content="Re-copy everything (ignore resume)" Margin="24,4,0,4"/>
        </StackPanel>
        <TreeView Grid.Row="1" x:Name="TreeSel"/>
        <DockPanel Grid.Row="2" Margin="0,8,0,0">
          <TextBlock x:Name="TxtScanStatus" Foreground="#94A3B8" DockPanel.Dock="Left" Text="Scanning..."/>
          <TextBlock x:Name="TxtTotals" DockPanel.Dock="Right" HorizontalAlignment="Right" FontWeight="Bold"/>
        </DockPanel>
      </Grid>
      <!-- Step 4: Copy -->
      <Grid x:Name="PanelStep4" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="TxtPhase" Text="Copying..." FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
        <ProgressBar Grid.Row="1" x:Name="PbOverall" Height="22" Background="#1E293B" Foreground="#38BDF8"/>
        <TextBlock Grid.Row="2" x:Name="TxtCurrentFile" Foreground="#94A3B8" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
        <TextBlock Grid.Row="3" x:Name="TxtCounters" Margin="0,8,0,8" FontFamily="Consolas"/>
        <ListBox Grid.Row="4" x:Name="LbProblems" FontFamily="Consolas" FontSize="12"/>
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
          <Button x:Name="BtnPause" Content="Pause" Width="110" Margin="0,0,10,0"/>
          <Button x:Name="BtnCancelCopy" Content="Cancel" Width="110" Background="#7F1D1D"/>
        </StackPanel>
      </Grid>
      <!-- Step 5: Done -->
      <StackPanel x:Name="PanelStep5" Visibility="Collapsed" MaxWidth="640" VerticalAlignment="Center">
        <TextBlock Text="Rescue complete" FontSize="20" FontWeight="Bold" Foreground="#4ADE80"/>
        <TextBlock x:Name="TxtSummary" Margin="0,12,0,0" FontFamily="Consolas" TextWrapping="Wrap"/>
        <TextBlock x:Name="TxtCloudNote" Margin="0,12,0,0" Foreground="#FBBF24" TextWrapping="Wrap"/>
        <ListBox x:Name="LbFinalProblems" MaxHeight="180" Margin="0,12,0,0" FontFamily="Consolas" FontSize="12"/>
        <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
          <Button x:Name="BtnOpenDest" Content="Open backup folder" Margin="0,0,12,0"/>
          <Button x:Name="BtnOpenReport" Content="Open report"/>
        </StackPanel>
      </StackPanel>
    </Grid>
  </DockPanel>
</Window>
'@
#endregion
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: selection model and WPF XAML layout"
```

---

### Task 10: Background runspaces, GUI wiring, STA bootstrap

**Files:**
- Modify: `NN-RescueCopy.ps1` (new `#region Background`, `#region GUI`, replace the Entry stub region)
- Create: `tests/Wiring.Tests.ps1`

**Interfaces:**
- Consumes: everything produced by Tasks 2–9
- Produces:
  - `Start-NNBackground([string]$FunctionName, [object[]]$Arguments) -> @{PS; Handle}` — runs an `*-NN*` function in a fresh runspace with all NN functions + constants injected
  - `Get-NNVolumes -> [pscustomobject[]]` with `Drive, Label, Size, Free, Contents, Root, FreeBytes`
  - `Start-NNRescueGui` — full window logic (not autotestable; bench checklist)
  - `Start-NNRescue` — final entry: Windows check, WPF check, STA relaunch, then GUI

- [ ] **Step 1: Write the failing test**

`tests/Wiring.Tests.ps1`:

```powershell
BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    $script:ScriptFile = Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1'
    . $script:ScriptFile
}

Describe 'whole script' {
    It 'parses with zero errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptFile, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
    It 'contains no PS7-only null-coalescing or ternary operators' {
        $src = Get-Content -Raw $script:ScriptFile
        $src | Should -Not -Match '\?\?'
    }
}

Describe 'Get-NNVolumes' {
    It 'returns drive rows with the GUI-bound properties' {
        $v = @(Get-NNVolumes)
        $v.Count | Should -BeGreaterThan 0
        foreach ($p in @('Drive','Label','Size','Free','Contents','Root','FreeBytes')) {
            $v[0].PSObject.Properties.Name | Should -Contain $p
        }
    }
}

Describe 'Start-NNBackground' {
    It 'runs a copy job in a background runspace with injected functions' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("nnbg-" + [guid]::NewGuid().ToString('N'))
        $src = Join-Path $dir 'src'
        $null = New-Item -ItemType Directory -Force -Path $src
        Set-Content -Path (Join-Path $src 'f.txt') -Value 'bg test'
        $t = New-NNTarget 'Extra' $null 'src' $src (Join-NNParts @('Extras','src')) $true
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $ctl = [hashtable]::Synchronized(@{ Cancel = $false; Pause = $false })
        $job = Start-NNBackground 'Invoke-NNCopyJob' @(@($t), (Join-Path $dir 'out'), $ctl, $q, $false)
        $null = $job.PS.EndInvoke($job.Handle)
        $job.PS.Dispose()
        Test-Path (Join-NNParts @($dir, 'out', 'Extras', 'src', 'f.txt')) | Should -BeTrue
        $m = $null; $types = @()
        while ($q.TryDequeue([ref]$m)) { $types += $m.Type }
        $types | Should -Contain 'done'
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: Wiring.Tests fail (`Get-NNVolumes`, `Start-NNBackground` not defined).

- [ ] **Step 3: Write the implementation**

Insert `#region Background` after the XAML region:

```powershell
#region Background
function Start-NNBackground {
    param([string]$FunctionName, [object[]]$Arguments)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in @(Get-ChildItem function: | Where-Object { $_.Name -like '*-NN*' })) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry ($fn.Name, $fn.Definition)))
    }
    foreach ($vn in @('NNIsWindows','NNOsExcludeRoot','NNProfileExclude','NNVisibleFolders','NNAppDataDefs',
                      'NNGenericRead','NNShareAll','NNOpenExisting','NNRawFlags','NNCloudOnlyAttrs')) {
        $v = Get-Variable -Name $vn -ErrorAction SilentlyContinue
        if ($v) {
            $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry ($vn, $v.Value, $null)))
        }
    }
    $ps = [powershell]::Create($iss)
    $null = $ps.AddCommand($FunctionName)
    foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
    return @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Get-NNVolumes {
    $out = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $root = $d.RootDirectory.FullName
        $badge = @()
        if (Test-Path -LiteralPath (Join-Path $root 'Windows')) { $badge += 'Windows' }
        if (Test-Path -LiteralPath (Join-Path $root 'Users'))   { $badge += 'Users' }
        $out += [pscustomobject]@{
            Drive     = $d.Name.TrimEnd('\', '/')
            Label     = $d.VolumeLabel
            Size      = Format-NNBytes $d.TotalSize
            Free      = Format-NNBytes $d.AvailableFreeSpace
            FreeBytes = [long]$d.AvailableFreeSpace
            Contents  = ($badge -join ', ')
            Root      = $root
        }
    }
    return $out
}
#endregion
```

Insert `#region GUI` after Background. This block is not unit-testable on Linux (WPF); it must still parse cleanly — the whole-script parser test is its gate. Scan-runspace note: the scan scriptblock below dot-sources nothing; it only calls injected `*-NN*` functions, which is exactly what `Start-NNBackground` provides. Because `Build-NNSelectionModel`+sizing runs per group, the scan posts `scangroup` messages so the tree populates live.

```powershell
#region GUI
# All GUI helpers are top-level functions operating on $script:NNCtx - WPF event
# handler scriptblocks execute against the session scope chain and would NOT see
# functions nested inside Start-NNRescueGui.

function Show-NNStep {
    param([int]$n)
    $script:NNCtx.Step = $n
    $ui = $script:NNCtx.UI
    for ($i = 1; $i -le 5; $i++) {
        $ui["PanelStep$i"].Visibility = 'Collapsed'
        $ui["RailStep$i"].Foreground = '#94A3B8'
        $ui["RailStep$i"].FontWeight = 'Normal'
    }
    $ui["PanelStep$n"].Visibility = 'Visible'
    $ui["RailStep$n"].Foreground = '#38BDF8'
    $ui["RailStep$n"].FontWeight = 'Bold'
    $ui.BtnBack.Visibility = 'Hidden'
    if ($n -eq 2 -or $n -eq 3) { $ui.BtnBack.Visibility = 'Visible' }
    $ui.BtnNext.Visibility = 'Visible'
    if ($n -eq 1 -or $n -eq 2) { $ui.BtnNext.Content = 'Next' }
    if ($n -eq 3) { $ui.BtnNext.Content = 'Start Copy' }
    if ($n -ge 4) { $ui.BtnNext.Visibility = 'Hidden' }
}

function Update-NNVolumeLists {
    $vols = @(Get-NNVolumes)
    $script:NNCtx.UI.LvSource.ItemsSource = $vols
    $script:NNCtx.UI.LvDest.ItemsSource = $vols
}

function Update-NNTotals {
    $c = $script:NNCtx
    if (-not $c.Model) { return }
    $sel = Get-NNSelectedBytes $c.Model
    $c.UI.TxtTotals.Text = ('Selected: {0}   Destination free: {1}' -f (Format-NNBytes $sel), (Format-NNBytes $c.DestFreeBytes))
    if ($sel -gt $c.DestFreeBytes) { $c.UI.TxtTotals.Foreground = '#F87171' }
    else { $c.UI.TxtTotals.Foreground = '#4ADE80' }
}

function Add-NNTreeGroup {
    param($Group)
    $c = $script:NNCtx
    $node = New-Object System.Windows.Controls.TreeViewItem
    $node.IsExpanded = $true
    $head = New-Object System.Windows.Controls.CheckBox
    $head.Content = $Group.Header
    $head.FontWeight = 'Bold'
    $head.Foreground = '#38BDF8'
    $node.Header = $head
    $childBoxes = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Group.Items) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $sz = ''
        if ($null -ne $item.SizeBytes) { $sz = '  (' + (Format-NNBytes $item.SizeBytes) + ')' }
        $cb.Content = $item.Label + $sz
        $cb.IsChecked = $item.Selected
        $cb.Tag = $item
        $cb.Add_Checked({ param($s, $e) $s.Tag.Selected = $true;  Update-NNTotals })
        $cb.Add_Unchecked({ param($s, $e) $s.Tag.Selected = $false; Update-NNTotals })
        $leaf = New-Object System.Windows.Controls.TreeViewItem
        $leaf.Header = $cb
        $null = $node.Items.Add($leaf)
        $childBoxes.Add($cb)
    }
    $head.Tag = $childBoxes
    $allOn = $true
    foreach ($b in $childBoxes) { if (-not $b.IsChecked) { $allOn = $false } }
    $head.IsChecked = $allOn
    $head.Add_Checked({ param($s, $e) foreach ($b in $s.Tag) { $b.IsChecked = $true } })
    $head.Add_Unchecked({ param($s, $e) foreach ($b in $s.Tag) { $b.IsChecked = $false } })
    $null = $c.UI.TreeSel.Items.Add($node)
}

function Start-NNScan {
    $c = $script:NNCtx
    if ($c.ScanJob) { try { $c.ScanJob.PS.Stop(); $c.ScanJob.PS.Dispose() } catch { } }
    $c.UI.TreeSel.Items.Clear()
    $c.Model = New-Object System.Collections.Generic.List[object]
    $c.UI.TxtScanStatus.Text = 'Scanning...'
    $c.ScanJob = Start-NNBackground 'Invoke-NNScanJob' @($c.SourceRoot, [bool]$c.UI.ChkAppData.IsChecked, $c.Queue)
}

function Read-NNQueue {
    $c = $script:NNCtx
    $m = $null
    while ($c.Queue.TryDequeue([ref]$m)) {
        if ($m.Type -eq 'scangroup') {
            $c.Model.Add($m.Group)
            Add-NNTreeGroup $m.Group
            Update-NNTotals
        }
        elseif ($m.Type -eq 'scandone') {
            $c.UI.TxtScanStatus.Text = 'Scan complete.'
        }
        elseif ($m.Type -eq 'plan') {
            $c.PlanBytes = [long]$m.Bytes; $c.PlanCount = [int]$m.Count
            $c.UI.PbOverall.Maximum = [double]([math]::Max(1, $m.Bytes / 1MB))
            $c.UI.TxtPhase.Text = ('Copying {0} files ({1})...' -f $m.Count, (Format-NNBytes $m.Bytes))
        }
        elseif ($m.Type -eq 'file') {
            $c.BytesDone = [long]$m.BytesDone
            $c.UI.PbOverall.Value = [double]($m.BytesDone / 1MB)
            $c.UI.TxtCurrentFile.Text = $m.Path
            if ($c.Tally.ContainsKey($m.Result)) { $c.Tally[$m.Result]++ } else { $c.Tally[$m.Result] = 1 }
            $parts = @()
            foreach ($k in ($c.Tally.Keys | Sort-Object)) { $parts += ('{0}: {1}' -f $k, $c.Tally[$k]) }
            $c.UI.TxtCounters.Text = ($parts -join '    ')
            if ($m.Result -ne 'OK' -and $m.Result -ne 'SKIP-EXISTS') {
                $null = $c.UI.LbProblems.Items.Add(('{0}  {1}' -f $m.Result, $m.Path))
            }
        }
        elseif ($m.Type -eq 'done') {
            $c.Summary = $m.Summary; $c.Pairs = $m.Pairs
            foreach ($p in $m.Problems) { $c.Problems.Add($p) }
            if ($c.UI.ChkVerify.IsChecked -and @($m.Pairs).Count -gt 0 -and -not $m.Cancelled) {
                $c.UI.TxtPhase.Text = ('Verifying {0} copied files (SHA-256)...' -f @($m.Pairs).Count)
                $c.UI.PbOverall.Value = 0
                $c.UI.PbOverall.Maximum = [double]@($m.Pairs).Count
                $c.VerifyJob = Start-NNBackground 'Invoke-NNVerifyPass' @($m.Pairs, $c.Control, $c.Queue)
            } else {
                Complete-NNJob
            }
        }
        elseif ($m.Type -eq 'verify') {
            $c.UI.PbOverall.Value = [double]$m.Index
            $c.UI.TxtCurrentFile.Text = ('Verified {0} / {1}' -f $m.Index, $m.Total)
        }
        elseif ($m.Type -eq 'verifydone') {
            foreach ($mm in $m.Mismatches) { $c.Problems.Add($mm) }
            if (@($m.Mismatches).Count -gt 0) { $c.Summary['HASH-MISMATCH'] = @($m.Mismatches).Count }
            Complete-NNJob
        }
    }
}

function Complete-NNJob {
    $c = $script:NNCtx
    $c.ReportPath = Join-Path $c.JobRoot '_RescueReport.html'
    $null = New-NNHtmlReport -Summary $c.Summary -Problems $c.Problems -JobName $c.JobName -Bytes $c.BytesDone -OutPath $c.ReportPath
    $lines = @()
    foreach ($k in ($c.Summary.Keys | Sort-Object)) { $lines += ('{0,-22} {1}' -f $k, $c.Summary[$k]) }
    $c.UI.TxtSummary.Text = ($lines -join [Environment]::NewLine)
    $cloud = 0
    if ($c.Summary.ContainsKey('CLOUD-ONLY')) { $cloud = $c.Summary['CLOUD-ONLY'] }
    if ($cloud -gt 0) {
        $c.UI.TxtCloudNote.Text = ('{0} file(s) live only in the customer''s cloud account (OneDrive/Dropbox). ' +
            'Sign into the account on a working machine to download them.') -f $cloud
    } else {
        $c.UI.TxtCloudNote.Text = ''
    }
    $c.UI.LbFinalProblems.Items.Clear()
    foreach ($p in $c.Problems) { $null = $c.UI.LbFinalProblems.Items.Add($p) }
    Show-NNStep 5
}

function Start-NNRescueGui {
    $win = [Windows.Markup.XamlReader]::Parse($NNXaml)
    $ui = @{}
    foreach ($n in @('RailStep1','RailStep2','RailStep3','RailStep4','RailStep5',
                     'PanelStep1','PanelStep2','PanelStep3','PanelStep4','PanelStep5',
                     'LvSource','LvDest','BtnBrowseSource','BtnRescan','TxtSrcPick',
                     'TxtJobName','TxtDestPreview','TxtJobHint',
                     'ChkAppData','ChkVerify','ChkForce','TreeSel','TxtTotals','TxtScanStatus',
                     'PbOverall','TxtPhase','TxtCurrentFile','TxtCounters','LbProblems','BtnPause','BtnCancelCopy',
                     'TxtSummary','TxtCloudNote','LbFinalProblems','BtnOpenDest','BtnOpenReport',
                     'BtnBack','BtnNext')) {
        $ui[$n] = $win.FindName($n)
    }

    $script:NNCtx = @{
        Win = $win; UI = $ui; Step = 1
        SourceRoot = $null; BackupRoot = $null; DestFreeBytes = [long]0
        JobRoot = $null; JobName = ''
        Model = $null; ScanJob = $null; CopyJob = $null; VerifyJob = $null
        Control = [hashtable]::Synchronized(@{ Cancel = $false; Pause = $false })
        Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        Tally = @{}; Problems = (New-Object System.Collections.Generic.List[string])
        Summary = $null; Pairs = $null; PlanBytes = [long]0; PlanCount = 0
        ReportPath = $null; BytesDone = [long]0
    }

    # --- events ---
    $ui.BtnRescan.Add_Click({ Update-NNVolumeLists })

    $ui.BtnBrowseSource.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick the customer data root (e.g. a mounted image)'
        if ($dlg.ShowDialog() -eq 'OK') {
            $script:NNCtx.SourceRoot = $dlg.SelectedPath
            $script:NNCtx.UI.TxtSrcPick.Text = 'Source: ' + $dlg.SelectedPath
            $script:NNCtx.UI.LvSource.SelectedItem = $null
        }
    })

    $ui.LvSource.Add_SelectionChanged({
        if ($script:NNCtx.UI.LvSource.SelectedItem) {
            $script:NNCtx.SourceRoot = $script:NNCtx.UI.LvSource.SelectedItem.Root
            $script:NNCtx.UI.TxtSrcPick.Text = 'Source: ' + $script:NNCtx.SourceRoot
        }
    })

    $ui.TxtJobName.Add_TextChanged({
        $c = $script:NNCtx
        if ($c.BackupRoot) {
            $c.UI.TxtDestPreview.Text = Get-NNJobRoot $c.BackupRoot $c.UI.TxtJobName.Text
        }
    })

    $ui.ChkAppData.Add_Click({ if ($script:NNCtx.Step -eq 3) { Start-NNScan } })

    $ui.BtnBack.Add_Click({
        $c = $script:NNCtx
        if ($c.Step -eq 3 -and $c.ScanJob) { try { $c.ScanJob.PS.Stop() } catch { } }
        if ($c.Step -gt 1) { Show-NNStep ($c.Step - 1) }
    })

    $ui.BtnNext.Add_Click({
        $c = $script:NNCtx
        if ($c.Step -eq 1) {
            if (-not $c.SourceRoot) {
                [System.Windows.MessageBox]::Show('Pick the customer (source) drive first.', 'NN Rescue Copy') | Out-Null; return
            }
            if (-not $c.UI.LvDest.SelectedItem) {
                [System.Windows.MessageBox]::Show('Pick the backup (destination) drive.', 'NN Rescue Copy') | Out-Null; return
            }
            $c.BackupRoot = $c.UI.LvDest.SelectedItem.Root
            $c.DestFreeBytes = [long]$c.UI.LvDest.SelectedItem.FreeBytes
            if ($c.BackupRoot -eq $c.SourceRoot) {
                [System.Windows.MessageBox]::Show('Source and destination must differ.', 'NN Rescue Copy') | Out-Null; return
            }
            if (-not $c.UI.TxtJobName.Text) {
                $hn = Get-NNSourceHostname $c.SourceRoot
                if ($hn) { $c.UI.TxtJobName.Text = $hn }
                else { $c.UI.TxtJobHint.Text = 'Could not read the drive''s registry - enter a name manually.' }
            }
            Show-NNStep 2
        }
        elseif ($c.Step -eq 2) {
            $name = Get-NNSafeName $c.UI.TxtJobName.Text
            if (-not $name) {
                [System.Windows.MessageBox]::Show('Enter a customer/job name.', 'NN Rescue Copy') | Out-Null; return
            }
            $c.JobName = $name
            $c.JobRoot = Get-NNJobRoot $c.BackupRoot $name
            Show-NNStep 3
            Start-NNScan
        }
        elseif ($c.Step -eq 3) {
            $targets = @()
            foreach ($g in $c.Model) { foreach ($i in $g.Items) { if ($i.Selected) { $targets += $i } } }
            if ($targets.Count -eq 0) {
                [System.Windows.MessageBox]::Show('Nothing selected.', 'NN Rescue Copy') | Out-Null; return
            }
            $sel = Get-NNSelectedBytes $c.Model
            if ($sel -gt $c.DestFreeBytes) {
                $r = [System.Windows.MessageBox]::Show(
                    ('Selection ({0}) exceeds destination free space ({1}). Continue anyway?' -f (Format-NNBytes $sel), (Format-NNBytes $c.DestFreeBytes)),
                    'NN Rescue Copy', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return }
            }
            $c.Control.Cancel = $false; $c.Control.Pause = $false
            $c.Tally = @{}; $c.Problems.Clear(); $c.UI.LbProblems.Items.Clear()
            Show-NNStep 4
            $c.CopyJob = Start-NNBackground 'Invoke-NNCopyJob' @($targets, $c.JobRoot, $c.Control, $c.Queue, [bool]$c.UI.ChkForce.IsChecked)
        }
    })

    $ui.BtnPause.Add_Click({
        $c = $script:NNCtx
        $c.Control.Pause = -not $c.Control.Pause
        if ($c.Control.Pause) { $c.UI.BtnPause.Content = 'Resume'; $c.UI.TxtPhase.Text = 'Paused.' }
        else { $c.UI.BtnPause.Content = 'Pause'; $c.UI.TxtPhase.Text = 'Copying...' }
    })

    $ui.BtnCancelCopy.Add_Click({ $script:NNCtx.Control.Cancel = $true })

    $ui.BtnOpenDest.Add_Click({ Start-Process explorer.exe $script:NNCtx.JobRoot })
    $ui.BtnOpenReport.Add_Click({ if ($script:NNCtx.ReportPath) { Start-Process $script:NNCtx.ReportPath } })

    # UI pump
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({ Read-NNQueue })
    $timer.Start()

    Update-NNVolumeLists
    Show-NNStep 1
    $null = $win.ShowDialog()
    $timer.Stop()
    foreach ($j in @($script:NNCtx.ScanJob, $script:NNCtx.CopyJob, $script:NNCtx.VerifyJob)) {
        if ($j) { try { $j.PS.Stop(); $j.PS.Dispose() } catch { } }
    }
}

function Invoke-NNScanJob {
    param([string]$SourceRoot, [bool]$IncludeAppData, $Queue)
    $model = Build-NNSelectionModel $SourceRoot $IncludeAppData
    foreach ($g in $model) {
        foreach ($i in $g.Items) { $i.SizeBytes = Get-NNFolderSize $i.SourcePath }
        $Queue.Enqueue(@{ Type = 'scangroup'; Group = $g })
    }
    $Queue.Enqueue(@{ Type = 'scandone' })
}
#endregion
```

Replace the `#region Entry stub` block entirely with:

```powershell
#region Entry
function Start-NNRescue {
    if (-not $NNIsWindows) {
        Write-Host 'NN Rescue Copy needs full Windows (it is a WPF app). On Linux, mount with ntfs-3g and copy normally.' -ForegroundColor Red
        return
    }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms -ErrorAction Stop
    } catch {
        Write-Host 'This Windows has no GUI stack (WinPE / Server Core). Slave the drive into a full Windows machine or VM.' -ForegroundColor Red
        return
    }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        $tmp = Join-Path $env:TEMP 'NN-RescueCopy.ps1'
        $saved = $false
        if ($NNScriptPath -and (Test-Path -LiteralPath $NNScriptPath)) {
            Copy-Item -Force -LiteralPath $NNScriptPath -Destination $tmp
            $saved = $true
        } else {
            try { Invoke-RestMethod 'https://copy.nerdyneighbor.net' -OutFile $tmp; $saved = $true } catch { }
        }
        if ($saved) {
            $exe = 'powershell.exe'
            if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh.exe' }
            Write-Host 'Relaunching in STA mode for the GUI...' -ForegroundColor Cyan
            Start-Process $exe -ArgumentList '-Sta', '-ExecutionPolicy', 'Bypass', '-File', $tmp
        } else {
            Write-Host 'Not in STA mode and could not self-relaunch. Download the script and run: powershell -Sta -File NN-RescueCopy.ps1' -ForegroundColor Red
        }
        return
    }
    Start-NNRescueGui
}
#endregion

if ($env:NN_RESCUE_NOGUI -ne '1') { Start-NNRescue }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"`
Expected: all suites pass (the parser test now covers the GUI region too).

- [ ] **Step 5: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: GUI wiring, background runspaces, STA bootstrap"
```

---

### Task 11: Cloudflare Pages project

**Files:**
- Create: `pages/wrangler.toml`
- Create: `pages/functions/index.js`
- Create: `pages/public/index.html`

**Interfaces:**
- Consumes: nothing from the script tasks (independent)
- Produces: the deployable Pages project Task 12 pushes live. The function serves the raw script for `irm`, a landing page for browsers, and `?download=1` as an attachment — identical mechanics to `/root/openssh-pages/functions/index.js`.

- [ ] **Step 1: Write the files**

`pages/wrangler.toml`:

```toml
name = "nerdyneighbor-rescue-copy"
compatibility_date = "2024-11-01"
pages_build_output_dir = "public"
```

`pages/functions/index.js`:

```javascript
// Cloudflare Pages Function  -  copy.nerdyneighbor.net
// Serves the LATEST committed NN-RescueCopy.ps1 as raw text so that
//   irm copy.nerdyneighbor.net | iex
// always runs the newest version. Fetches via the GitHub Contents API
// (Accept: application/vnd.github.raw) - no CDN staleness. Same design
// as openssh.nerdyneighbor.net.
// Optional: set a GITHUB_TOKEN secret to raise the rate limit to 5,000/hr.

const REPO_API =
  'https://api.github.com/repos/nerd-industries/rescue-copy/contents/NN-RescueCopy.ps1';
const FILE_NAME = 'NN-RescueCopy.ps1';

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const wantDownload =
    url.searchParams.has('download') ||
    url.pathname.replace(/\/+$/, '').toLowerCase().endsWith('/download');
  const accept = context.request.headers.get('Accept') || '';

  if (accept.includes('text/html') && !wantDownload) {
    return new Response(LANDING_HTML, {
      headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
    });
  }

  const headers = {
    'Accept': 'application/vnd.github.raw',
    'User-Agent': 'nerdyneighbor-rescue-copy-proxy',
  };
  if (context.env && context.env.GITHUB_TOKEN) {
    headers['Authorization'] = `Bearer ${context.env.GITHUB_TOKEN}`;
  }

  let upstream;
  try {
    upstream = await fetch(REPO_API, { headers });
  } catch (e) {
    return errorScript(502, `network error reaching GitHub: ${e}`);
  }
  if (!upstream.ok) {
    return errorScript(
      502,
      `GitHub returned ${upstream.status} ${upstream.statusText}` +
        (upstream.status === 403 ? ' (rate limited - set a GITHUB_TOKEN secret)' : '')
    );
  }

  const script = await upstream.text();
  const respHeaders = {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
    'x-source': 'github-contents-api',
  };
  if (wantDownload) {
    respHeaders['content-type'] = 'application/octet-stream';
    respHeaders['content-disposition'] = `attachment; filename="${FILE_NAME}"`;
  }
  return new Response(script, { headers: respHeaders });
}

const LANDING_HTML = `<!doctype html><meta charset="utf-8">
<title>Nerdy Neighbor - Rescue Copy</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<body style="font-family:Segoe UI,Arial,sans-serif;max-width:660px;margin:56px auto;padding:0 18px;color:#e2e8f0;background:#0f172a;line-height:1.5">
<h1 style="margin-bottom:4px;color:#38bdf8">NN Rescue Copy</h1>
<p style="color:#94a3b8;margin-top:0">GUI rescue backup for slaved customer drives. Copies OneDrive cloud-reparse files robocopy can't touch. Read-only on the source.</p>

<h3 style="margin-bottom:6px">Run it (full Windows, as Administrator)</h3>
<div style="display:flex;gap:8px;align-items:stretch;flex-wrap:wrap">
  <pre id="cmd" style="flex:1;min-width:280px;background:#1e293b;color:#86efac;padding:14px 16px;border-radius:8px;overflow:auto;margin:0">irm copy.nerdyneighbor.net | iex</pre>
  <button onclick="navigator.clipboard.writeText('irm copy.nerdyneighbor.net | iex').then(()=>{this.textContent='Copied!';setTimeout(()=>this.textContent='Copy',1500)})"
          style="border:0;border-radius:8px;background:#0369a1;color:#fff;font-weight:600;padding:0 18px;cursor:pointer">Copy</button>
</div>

<h3 style="margin-bottom:6px">Or download the script</h3>
<p><a href="?download=1" download="NN-RescueCopy.ps1"
      style="display:inline-block;background:#16a34a;color:#fff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:8px">Download NN-RescueCopy.ps1</a></p>

<p style="color:#64748b;font-size:12px;margin-top:28px">Nerdy Neighbor recovery toolkit &middot; source: github.com/nerd-industries/rescue-copy</p>
</body>`;

function errorScript(status, reason) {
  const body =
    `Write-Host 'NN Rescue Copy could not be downloaded.' -ForegroundColor Red\n` +
    `Write-Host '${reason.replace(/'/g, "''")}' -ForegroundColor Yellow\n`;
  return new Response(body, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  });
}
```

`pages/public/index.html` (static placeholder; the Function handles `/`):

```html
<!doctype html><meta charset="utf-8"><title>NN Rescue Copy</title>
<p>Run: <code>irm copy.nerdyneighbor.net | iex</code></p>
```

- [ ] **Step 2: Verify the function parses**

Run: `node --check /root/rescue-copy/pages/functions/index.js && echo PARSE-OK`
Expected: `PARSE-OK`

- [ ] **Step 3: Commit**

```bash
cd /root/rescue-copy && git add -A && git commit -m "feat: Cloudflare Pages function serving latest script from GitHub"
```

---

### Task 12: Deploy — GitHub repo, Pages project, custom domain

**Files:**
- No new files; publishes the repo and Pages project.

**Interfaces:**
- Consumes: the complete repo (Tasks 1–11)
- Produces: live `https://copy.nerdyneighbor.net` endpoint

- [ ] **Step 1: Create and push the GitHub repo**

```bash
cd /root/rescue-copy
git branch -M main
gh repo create nerd-industries/rescue-copy --public --source . --push
```

Expected: repo visible at github.com/nerd-industries/rescue-copy. (`gh auth status` already shows the `nerd-industries` account. Public repo is required: the Pages function fetches the Contents API unauthenticated unless a `GITHUB_TOKEN` secret is added.)

- [ ] **Step 2: Verify the Contents API serves the script**

```bash
curl -s -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/nerd-industries/rescue-copy/contents/NN-RescueCopy.ps1 | head -3
```

Expected: first lines of the script (`#requires -Version 5.1` header).

- [ ] **Step 3: Create and deploy the Pages project**

```bash
cd /root/rescue-copy/pages
npx wrangler pages project create nerdyneighbor-rescue-copy --production-branch main
npx wrangler pages deploy
```

Expected: deployment URL like `https://<hash>.nerdyneighbor-rescue-copy.pages.dev`.

- [ ] **Step 4: Verify the pages.dev endpoint**

```bash
curl -s https://nerdyneighbor-rescue-copy.pages.dev | head -3
curl -s -H 'Accept: text/html' https://nerdyneighbor-rescue-copy.pages.dev | grep -o '<title>[^<]*'
```

Expected: raw script header from the first command; `<title>Nerdy Neighbor - Rescue Copy` from the second.

- [ ] **Step 5: Attach the custom domain**

```bash
npx wrangler pages domain add copy.nerdyneighbor.net --project-name nerdyneighbor-rescue-copy
```

If that subcommand is unavailable in the installed wrangler version, fall back to the dashboard: Cloudflare → Workers & Pages → nerdyneighbor-rescue-copy → Custom domains → Add `copy.nerdyneighbor.net` (DNS record is auto-created since nerdyneighbor.net is in this account — the openssh.nerdyneighbor.net project was set up the same way).

- [ ] **Step 6: Verify the production one-liner endpoint**

```bash
sleep 30 && curl -s https://copy.nerdyneighbor.net | head -3
```

Expected: raw script header. (Certificate provisioning can take a few minutes; retry before diagnosing.)

- [ ] **Step 7: Commit any local changes**

```bash
cd /root/rescue-copy && git add -A && git diff --cached --quiet || git commit -m "chore: deployment artifacts"
git push
```

---

### Task 13: README, bench checklist, final review

**Files:**
- Create: `README.md`
- Create: `docs/bench-test-checklist.md`

**Interfaces:**
- Consumes: everything
- Produces: operator docs; the bench checklist is the acceptance gate before first customer use

- [ ] **Step 1: Write README.md**

```markdown
# NN Rescue Copy

GUI rescue-backup tool for Nerdy Neighbor recovery jobs.

    irm copy.nerdyneighbor.net | iex

Run on **full Windows** (bench machine or rescue VM) with the customer drive
slaved in. Pick the customer drive and the backup drive, name the job, tick
what to copy, go. Read-only on the source drive.

## What it does

- Copies every user's visible profile folders (Desktop, Documents, Pictures,
  Downloads, Videos, Music, Favorites, OneDrive*) to
  `<Backup>:\NN-Rescue\<JobName>\Users\<user>\...`
- **Copies OneDrive/Dropbox cloud-reparse files** that robocopy/xcopy/Explorer
  fail on with ERROR 1920 (raw `CreateFileW` open with
  `FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS` — the
  Copy-RawFile technique from the 2026-08-12 Tom Scott recovery)
- Detects true cloud-only placeholders (no local data), skips and reports them
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
```

- [ ] **Step 2: Write docs/bench-test-checklist.md**

```markdown
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
- [ ] Re-running the same job name skips everything (SKIP-EXISTS)
- [ ] "Re-copy everything" forces a full recopy
- [ ] Verify checkbox runs the SHA-256 pass and reports 0 mismatches
- [ ] Long path (>260 chars) file copies successfully

Sign-off: __________  Date: __________
```

- [ ] **Step 3: Full test run and final review**

```bash
cd /root/rescue-copy && pwsh -NoProfile -Command "Invoke-Pester -Path tests"
```

Expected: every suite passes. Then re-read the spec's Decisions table and confirm each row is implemented (environments → Entry guard; hosting → Task 11/12; data scope → ChkAppData default off; C: scan → Get-NNExtraTargets; layout → Get-NNJobRoot; engine → Tasks 5–6; verify → Task 7).

- [ ] **Step 4: Commit and push**

```bash
cd /root/rescue-copy && git add -A && git commit -m "docs: README and bench test checklist" && git push
```

---

## Self-review notes (already applied)

- Spec coverage: every Decisions-table row maps to a task (see Task 13 step 3 cross-check list).
- The GUI helper functions (`Show-NNStep`, `Read-NNQueue`, etc.) are defined at **top level** in the GUI region, not nested inside `Start-NNRescueGui` — WPF event handlers execute in the session's scope chain, and nested function definitions would be invisible there. Task 10's code reflects this: only window construction, event registration, and the timer live inside `Start-NNRescueGui`.
- `Get-NNVolumes` feeds both lists unfiltered; the destination list intentionally includes all drives (techs sometimes back up to a second partition).
- Off-Windows test seam (`Open-NNSourceStream`) is the single point where Linux tests diverge from production; everything above it (skip logic, size check, timestamps, CSV, queue protocol, cancel/pause) is exercised for real.







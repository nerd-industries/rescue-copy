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

#region Constants
$NNOsExcludeRoot = @('Windows','Program Files','Program Files (x86)','ProgramData','PerfLogs','Recovery',
    'System Volume Information','$Recycle.Bin','$WinREAgent','Users','OneDriveTemp','Config.Msi',
    'Intel','AMD','NVIDIA','Drivers','MSOCache','inetpub','Documents and Settings')
$NNProfileExclude = @('Default','Default User','Public','All Users','defaultuser0','WDAGUtilityAccount')
$NNVisibleFolders = @('Desktop','Documents','Pictures','Downloads','Videos','Music','Favorites')
# Profile-root folders never offered as targets (AppData is opt-in via its own toggle;
# legacy junctions like 'Application Data' are excluded by their reparse attribute instead)
$NNProfileRootSkip = @('AppData')
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

function Test-NNPathOverlap {
    param([string]$PathA, [string]$PathB)
    $a = $PathA.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $b = $PathB.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
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

function Test-NNJobHasData {
    param([string]$JobRoot)
    if (-not (Test-Path -LiteralPath $JobRoot)) { return $false }
    try {
        $e = [IO.Directory]::EnumerateFiles($JobRoot, '*', [IO.SearchOption]::AllDirectories).GetEnumerator()
        return [bool]$e.MoveNext()
    } catch {
        return $false
    }
}

function Get-NNAvailableJobName {
    param([string]$BackupRoot, [string]$JobName)
    $name = Get-NNSafeName $JobName
    if (-not (Test-NNJobHasData (Get-NNJobRoot $BackupRoot $name))) { return $name }
    $i = 2
    while ($true) {
        $candidate = ('{0} ({1})' -f $name, $i)
        if (-not (Test-NNJobHasData (Get-NNJobRoot $BackupRoot $candidate))) { return $candidate }
        $i++
    }
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
    # Anything else the user created at the profile root is data too. Skip what is already
    # targeted, AppData (its own toggle), and legacy junction points (reparse attribute).
    foreach ($d in @(Get-ChildItem -LiteralPath $ProfileDir.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($NNVisibleFolders -contains $d.Name) { continue }
        if ($NNProfileRootSkip -contains $d.Name) { continue }
        if ($d.Name -like 'OneDrive*') { continue }
        if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $out += New-NNTarget 'Profile' $u $d.Name $d.FullName (Join-NNParts @('Users', $u, $d.Name)) $true
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

#region Raw copy engine
if (-not ('RawFileNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RawFileNative {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr sec, uint disposition, uint flags, IntPtr template);
}
'@
}

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

function Open-NNHydratingStream {
    param([string]$Path)
    # NORMAL open, no FILE_FLAG_OPEN_REPARSE_POINT: on a live machine the Cloud Files
    # driver hydrates the placeholder (OneDrive downloads it) as we read. On a slaved
    # drive this open fails and the caller reports CLOUD-ONLY.
    if (-not $NNIsWindows) { return [IO.File]::OpenRead($Path) }   # test seam
    $h = [RawFileNative]::CreateFileW((ConvertTo-NNLongPath $Path), $NNGenericRead, $NNShareAll,
        [IntPtr]::Zero, $NNOpenExisting, [uint32]33554432, [IntPtr]::Zero)   # FILE_FLAG_BACKUP_SEMANTICS only
    if ($h.IsInvalid) {
        throw (New-Object ComponentModel.Win32Exception ([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
    return (New-Object IO.FileStream ($h, [IO.FileAccess]::Read))
}

function Copy-NNFile {
    param([IO.FileInfo]$Src, [string]$DestPath, [bool]$Force, [byte[]]$Buffer)
    # Long-path-safe destination (>260 chars); no-op off Windows (test seam)
    if ($NNIsWindows) { $DestPath = ConvertTo-NNLongPath $DestPath }
    $dstInfo = New-Object IO.FileInfo ($DestPath)
    if (-not $Force -and $dstInfo.Exists -and $dstInfo.Length -eq $Src.Length) { return 'SKIP-EXISTS' }

    $in = $null
    if (Test-NNCloudOnly $Src) {
        # No local data: let OneDrive fetch it if this machine can; otherwise it stays cloud-only.
        try { $in = Open-NNHydratingStream $Src.FullName } catch { return 'CLOUD-ONLY' }
    } else {
        try { $in = Open-NNSourceStream $Src.FullName }
        catch {
            $code = 'err=' + ($_.Exception.HResult -band 0xFFFF)
            if ($_.Exception -is [ComponentModel.Win32Exception]) { $code = 'err=' + $_.Exception.NativeErrorCode }
            if ($_.Exception -is [IO.FileNotFoundException] -or $_.Exception -is [IO.DirectoryNotFoundException]) { $code = 'err=2' }
            if ($_.Exception.InnerException -is [IO.FileNotFoundException] -or $_.Exception.InnerException -is [IO.DirectoryNotFoundException]) { $code = 'err=2' }
            return "OPEN-FAIL($code)"
        }
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

function Invoke-NNCopyJob {
    param($Targets, [string]$JobRoot, $Control, $Queue, [bool]$Force)

    # Pass 1: enumerate work
    $files    = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]
    $totalBytes = [long]0
    $enumErrs = @()
    foreach ($t in $Targets) {
        $src = Get-Item -Force -LiteralPath $t.SourcePath -ErrorAction SilentlyContinue
        if (-not $src) { continue }
        if ($src.PSIsContainer) {
            foreach ($f in @(Get-ChildItem -LiteralPath $src.FullName -Recurse -Force -File -ErrorAction SilentlyContinue -ErrorVariable +enumErrs)) {
                $rel = $f.FullName.Substring($src.FullName.Length).TrimStart('\', '/')
                $files.Add(@{ File = $f; Dest = (Join-Path (Join-Path $JobRoot $t.DestRel) $rel); Rel = $t.DestRel })
                $totalBytes += $f.Length
            }
        } else {
            $files.Add(@{ File = $src; Dest = (Join-Path $JobRoot $t.DestRel); Rel = $t.DestRel })
            $totalBytes += $src.Length
        }
    }
    if (@($enumErrs).Count -gt 0) {
        $cap = [Math]::Min(50, @($enumErrs).Count)
        for ($ei = 0; $ei -lt $cap; $ei++) {
            $problems.Add('ENUM-FAIL(' + $enumErrs[$ei].Exception.Message + ')')
        }
    }
    $Queue.Enqueue([pscustomobject]@{ Type = 'plan'; Count = $files.Count; Bytes = $totalBytes })

    $buffer   = New-Object byte[] 1048576
    $summary  = @{}
    $pairs    = New-Object System.Collections.Generic.List[object]
    $done = [long]0
    $i = 0
    $lastDir = ''
    $csv = $null
    $fstat = [ordered]@{}
    try {
        $null = [IO.Directory]::CreateDirectory($JobRoot)
        # The CSV is a log, never the payload: a locked or unwritable log must not stop the copy.
        $csvHeader = 'Time,Result,Size,Source,Destination'
        $csvPath = Join-Path $JobRoot '_RescueLog.csv'
        if (Test-Path -LiteralPath $csvPath) {
            # A log from an older build (different header) stays untouched; this run gets its own file.
            $first = Get-Content -LiteralPath $csvPath -TotalCount 1 -ErrorAction SilentlyContinue
            if ($first -ne $csvHeader) {
                $csvPath = Join-Path $JobRoot ('_RescueLog-{0:yyyyMMdd-HHmmss}.csv' -f [DateTime]::Now)
                $problems.Add('LOG-NOTE(existing _RescueLog.csv uses an older format - this run logs to ' + (Split-Path -Leaf $csvPath) + ')')
            }
        }
        try {
            $newCsv = -not (Test-Path -LiteralPath $csvPath)
            $csv = New-Object IO.StreamWriter ($csvPath, $true, [Text.Encoding]::UTF8)
            if ($newCsv) { $csv.WriteLine('Time,Result,Size,Source,Destination') }
        } catch {
            try {
                $csvPath = Join-Path $JobRoot ('_RescueLog-{0:yyyyMMdd-HHmmss}.csv' -f [DateTime]::Now)
                $csv = New-Object IO.StreamWriter ($csvPath, $true, [Text.Encoding]::UTF8)
                $csv.WriteLine('Time,Result,Size,Source,Destination')
                $problems.Add('LOG-NOTE(_RescueLog.csv is open in another program - logging to ' + (Split-Path -Leaf $csvPath) + ' instead)')
            } catch {
                $csv = $null
                $problems.Add('LOG-FAIL(no CSV log could be opened - copying continues without one: ' + $_.Exception.Message + ')')
            }
        }
        if ($csv) { $csv.AutoFlush = $true }

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
                if ($r -eq 'OK' -or $r -eq 'SKIP-EXISTS') {
                    if (-not $fstat.Contains($item.Rel)) { $fstat[$item.Rel] = @{ Files = 0; Bytes = [long]0 } }
                    $fstat[$item.Rel].Files++
                    $fstat[$item.Rel].Bytes += $item.File.Length
                }
                if ($r -ne 'OK' -and $r -ne 'SKIP-EXISTS') { $problems.Add("$r  $($item.File.FullName)") }
                $done += $item.File.Length
                $i++
                if ($csv) {
                    try {
                        $csv.WriteLine(('{0:o},"{1}",{2},"{3}","{4}"' -f [DateTime]::UtcNow, $r.Replace('"', '""'), (Format-NNBytes $item.File.Length),
                            $item.File.FullName.Replace('"', '""'), $item.Dest.Replace('"', '""')))
                    } catch {
                        $csv = $null
                        $problems.Add('LOG-FAIL(log write failed - copying continues without a log: ' + $_.Exception.Message + ')')
                    }
                }
                $Queue.Enqueue([pscustomobject]@{ Type = 'file'; Result = $r; Path = $item.File.FullName; BytesDone = $done; Index = $i })

                if ($r -like 'READ-FAIL*') {
                    $free = -1
                    try { $free = (New-Object IO.DriveInfo([IO.Path]::GetPathRoot($JobRoot))).AvailableFreeSpace } catch { }
                    if ($free -ge 0 -and $free -lt 1048576) {
                        $problems.Add('FATAL(Destination drive is full - copy halted. Free space and re-run to resume.)')
                        break
                    }
                }
            }
        } finally {
            if ($csv) { $csv.Dispose() }
        }
    } catch {
        $problems.Add('FATAL(' + $_.Exception.Message + ')')
    }
    $folderStats = @()
    foreach ($k in $fstat.Keys) {
        $folderStats += [pscustomobject]@{ Folder = $k; Files = $fstat[$k].Files; Bytes = [long]$fstat[$k].Bytes }
    }
    $Queue.Enqueue([pscustomobject]@{ Type = 'done'; Summary = $summary; Problems = [object[]]$problems; Pairs = [object[]]$pairs;
                      FolderStats = [object[]]$folderStats; Cancelled = [bool]$Control.Cancel; BytesDone = $done })
}
#endregion

#region Verify
function Get-NNFileHash {
    param([string]$Path)
    $sha = $null
    $s = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $s = Open-NNSourceStream $Path
        $buf = New-Object byte[] 1048576
        while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) {
            $null = $sha.TransformBlock($buf, 0, $n, $null, 0)
        }
        $null = $sha.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
    } finally {
        if ($s) { $s.Dispose() }
        if ($sha) { $sha.Dispose() }
    }
}

function Invoke-NNVerifyPass {
    param($Pairs, $Control, $Queue)
    $mismatch = New-Object System.Collections.Generic.List[string]
    $i = 0
    try {
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
            $Queue.Enqueue([pscustomobject]@{ Type = 'verify'; Index = $i; Total = @($Pairs).Count })
        }
    } catch {
        $mismatch.Add('VERIFY-FATAL(' + $_.Exception.Message + ')')
    }
    $Queue.Enqueue([pscustomobject]@{ Type = 'verifydone'; Mismatches = $mismatch })
    return $mismatch
}
#endregion

#region Report
# Nerdy Neighbor logo, black on white, 840x320 PNG (16-gray palette), for the printed report
$NNLogoB64 = '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'

function New-NNHtmlReport {
    param([hashtable]$Summary, [string[]]$Problems, [string]$JobName, [long]$Bytes, [string]$OutPath, [object[]]$FolderStats = @())

    function Encode-NNHtml { param([string]$s)
        return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    }
    function Get-NNCount { param($h, [string]$k)
        if ($h.ContainsKey($k)) { return [int]$h[$k] }
        return 0
    }
    function Get-NNRowFace { param([string]$code)
        # glyph + plain-language label for the customer-facing ledger
        if ($code -eq 'OK')              { return @('&#10003;', 'Copied and verified') }
        if ($code -eq 'SKIP-EXISTS')     { return @('&#8635;',  'Already backed up from an earlier run') }
        if ($code -eq 'CLOUD-ONLY')      { return @('&#9729;',  'Stored only in your cloud account') }
        if ($code -like 'OPEN-FAIL*')    { return @('&#10007;', 'Could not be opened - damaged on the drive') }
        if ($code -like 'READ-FAIL*')    { return @('&#10007;', 'Copy failed partway - drive read error') }
        if ($code -like 'SIZE-MISMATCH*'){ return @('&#10007;', 'Copy did not match the original') }
        if ($code -like 'HASH-MISMATCH*'){ return @('&#10007;', 'Verification found a difference') }
        if ($code -like 'VERIFY-*')      { return @('&#10007;', 'Could not be verified') }
        return @('&#10007;', 'Needs attention - see technical notes')
    }

    $ok        = Get-NNCount $Summary 'OK'
    $skip      = Get-NNCount $Summary 'SKIP-EXISTS'
    $cloud     = Get-NNCount $Summary 'CLOUD-ONLY'
    $probCount = @($Problems).Count
    $total     = 0
    foreach ($k in $Summary.Keys) { $total += [int]$Summary[$k] }

    # Ledger rows: the good outcomes first, then everything else alphabetically
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('OK', 'SKIP-EXISTS', 'CLOUD-ONLY')) { if ($Summary.ContainsKey($k)) { $ordered.Add($k) } }
    foreach ($k in ($Summary.Keys | Sort-Object)) { if ($ordered -notcontains $k) { $ordered.Add($k) } }
    $rows = ''
    foreach ($k in $ordered) {
        $face = Get-NNRowFace $k
        $rows += ('<tr><td class="g">{0}</td><td>{1}<span class="code">{2}</span></td><td class="n">{3}</td></tr>' -f `
            $face[0], $face[1], (Encode-NNHtml $k), $Summary[$k])
    }
    $rows += ('<tr class="total"><td></td><td>Total files processed</td><td class="n">{0}</td></tr>' -f $total)

    $cloudHtml = ''
    if ($cloud -gt 0) {
        $cloudHtml = ('<div class="callout"><div class="ic">&#9729;</div><div>' +
            '<h3>Some files still live in your cloud account</h3>' +
            '<p>{0} file(s) are stored online-only by OneDrive or Dropbox and could not be downloaded during this rescue. ' +
            'To get them back, sign in to the cloud account on the repaired or replacement computer and they will download automatically.</p>' +
            '</div></div>') -f $cloud
    }

    $attentionHtml = '<p class="allclear">Every file was processed without issues.</p>'
    $appendixHtml = ''
    if ($probCount -gt 0) {
        $attentionHtml = ('<p class="attention">{0} item(s) need attention. The technical appendix on the last page lists each one for our records.</p>' -f $probCount)
        $items = ''
        foreach ($p in $Problems) { $items += ('<li>{0}</li>' -f (Encode-NNHtml $p)) }
        $appendixHtml = ('<section class="appendix"><h2>Technical appendix &middot; full detail for our records</h2>' +
            '<ul>{0}</ul>' +
            '<p class="apx-note">A complete per-file log was saved alongside this report as _RescueLog.csv.</p>' +
            '</section>') -f $items
    }

    $folderHtml = ''
    if (@($FolderStats).Count -gt 0) {
        $frows = ''
        foreach ($f in $FolderStats) {
            $frows += ('<tr><td class="fp">{0}</td><td class="n">{1}</td><td class="n">{2}</td></tr>' -f `
                (Encode-NNHtml ([string]$f.Folder)), $f.Files, (Format-NNBytes ([long]$f.Bytes)))
        }
        $folderHtml = ('<div class="eyebrow2">RECOVERED, FOLDER BY FOLDER</div>' +
            '<table class="folders"><tr class="fh"><td>Folder</td><td class="n">Files</td><td class="n">Size</td></tr>{0}</table>') -f $frows
    }

    $jobEnc  = Encode-NNHtml $JobName
    $dateStr = [DateTime]::Now.ToString('MMMM d, yyyy')

    $html = @"
<!doctype html><html><head><meta charset="utf-8">
<title>Data Rescue Report - $jobEnc</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#e6e5e2;font-family:Georgia,'Times New Roman',serif;color:#111;-webkit-print-color-adjust:exact;print-color-adjust:exact}
.page{max-width:8.5in;margin:28px auto;background:#fff;padding:0.85in 0.8in;box-shadow:0 2px 26px rgba(0,0,0,0.18)}
header{display:flex;justify-content:space-between;align-items:flex-end;padding-bottom:16px;border-bottom:3px solid #111}
header img{width:2.5in;display:block}
.meta{text-align:right;font-family:'Segoe UI',Arial,sans-serif;font-size:11px;color:#444;line-height:1.8}
.meta .k{font-size:9px;letter-spacing:0.14em;color:#999}
h1{font-family:'Segoe UI',Arial,sans-serif;font-weight:300;font-size:34px;letter-spacing:0.3px;margin:26px 0 2px}
.eyebrow{font-family:'Segoe UI',Arial,sans-serif;font-size:10px;font-weight:600;letter-spacing:0.22em;color:#777;margin-top:28px}
.stats{display:flex;border:1px solid #d9d9d9;margin:22px 0 24px}
.stat{flex:1;padding:15px 18px 13px;border-left:1px solid #d9d9d9}
.stat:first-child{border-left:0}
.stat .v{font-family:'Segoe UI',Arial,sans-serif;font-weight:300;font-size:30px;line-height:1.15}
.stat .l{font-family:'Segoe UI',Arial,sans-serif;font-size:9.5px;font-weight:600;letter-spacing:0.16em;color:#777;margin-top:3px}
p.lead{font-size:14px;line-height:1.7;color:#1a1a1a;max-width:6.6in}
.callout{border:1.5px solid #111;padding:15px 17px;margin:22px 0;display:flex;gap:14px}
.callout .ic{font-size:22px;line-height:1.2}
.callout h3{font-family:'Segoe UI',Arial,sans-serif;font-size:12px;letter-spacing:0.08em;text-transform:uppercase;margin-bottom:5px}
.callout p{font-size:12.5px;line-height:1.65;color:#222}
.attention,.allclear{font-size:12.5px;line-height:1.6;color:#222;margin:4px 0 18px;font-style:italic}
table.ledger{width:100%;border-collapse:collapse;margin:6px 0 0;font-family:'Segoe UI',Arial,sans-serif;font-size:13px}
.ledger td{padding:9px 6px;border-bottom:1px solid #e3e3e3;vertical-align:top}
.ledger td.g{width:26px;font-size:14px;text-align:center}
.ledger span.code{font-family:Consolas,monospace;font-size:10px;color:#9a9a9a;margin-left:9px}
.ledger td.n{text-align:right;font-weight:600;font-variant-numeric:tabular-nums;width:70px}
.ledger tr.total td{border-top:2px solid #111;border-bottom:0;font-weight:700;padding-top:11px}
.eyebrow2{font-family:'Segoe UI',Arial,sans-serif;font-size:10px;font-weight:600;letter-spacing:0.22em;color:#777;margin:26px 0 6px}
table.folders{width:100%;border-collapse:collapse;font-family:'Segoe UI',Arial,sans-serif;font-size:12.5px}
.folders td{padding:7px 6px;border-bottom:1px solid #e3e3e3;vertical-align:top}
.folders td.fp{font-family:Consolas,monospace;font-size:11px;word-break:break-all}
.folders td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;width:80px}
.folders tr.fh td{font-size:9.5px;font-weight:600;letter-spacing:0.14em;color:#999;border-bottom:1.5px solid #111;padding-bottom:5px}
footer{margin-top:36px;padding-top:12px;border-top:1px solid #ddd;font-family:'Segoe UI',Arial,sans-serif;font-size:10px;color:#999;letter-spacing:0.06em}
.appendix{page-break-before:always;padding-top:20px}
.appendix h2{font-family:'Segoe UI',Arial,sans-serif;font-size:12px;letter-spacing:0.12em;text-transform:uppercase;color:#444;margin-bottom:12px}
.appendix ul{list-style:none}
.appendix li{font-family:Consolas,monospace;font-size:10.5px;line-height:1.5;padding:4px 0;border-bottom:1px dotted #ddd;word-break:break-all}
.apx-note{font-family:'Segoe UI',Arial,sans-serif;font-size:10px;color:#999;margin-top:12px}
@media print{body{background:#fff}.page{max-width:none;margin:0;box-shadow:none;padding:0}}
@page{margin:0.7in}
</style></head><body>
<div class="page">
<header>
  <img src="data:image/png;base64,$NNLogoB64" alt="Nerdy Neighbor - Computer Repair &amp; Business Solutions">
  <div class="meta">
    <div><span class="k">JOB&nbsp;&nbsp;</span>$jobEnc</div>
    <div><span class="k">DATE&nbsp;&nbsp;</span>$dateStr</div>
  </div>
</header>
<div class="eyebrow">DATA RECOVERY SERVICE</div>
<h1>Data Rescue Report</h1>
<div class="stats">
  <div class="stat"><div class="v">$(Format-NNBytes $Bytes)</div><div class="l">DATA PROCESSED</div></div>
  <div class="stat"><div class="v">$($ok + $skip)</div><div class="l">FILES SECURED</div></div>
  <div class="stat"><div class="v">$probCount</div><div class="l">NEED ATTENTION</div></div>
</div>
<p class="lead">We copied the files listed below from your computer's drive onto a backup drive.
Every recovered file was checked to confirm the copy matches the original's size$(if ($Summary.ContainsKey('HASH-MISMATCH') -or $Summary.ContainsKey('VERIFY-FAIL')) { ' and contents' }).
Nothing on your original drive was changed or deleted.</p>
$folderHtml
$cloudHtml
<div class="eyebrow2">RESULTS AT A GLANCE</div>
<table class="ledger">$rows</table>
$attentionHtml
<footer>NERDY NEIGHBOR &middot; COMPUTER REPAIR &amp; BUSINESS SOLUTIONS &middot; $dateStr</footer>
$appendixHtml
</div>
</body></html>
"@
    [IO.File]::WriteAllText($OutPath, $html, [Text.Encoding]::UTF8)
    return $OutPath
}
#endregion

#region Selection model
function Build-NNSelectionModel {
    param([string]$SourceRoot, [bool]$IncludeAppData)
    $groups = @()
    foreach ($pd in @(Get-NNUserProfileDirs $SourceRoot)) {
        $items = @(Get-NNProfileTargets $pd)
        if ($IncludeAppData) { $items += @(Get-NNAppDataTargets $pd) }
        if ($items.Count -gt 0) { $groups += @{ Header = "User: $($pd.Name)"; Items = $items } }
    }
    $extras = @(Get-NNExtraTargets $SourceRoot)
    $public = @($extras | Where-Object { $_.Category -eq 'Public' })
    $other  = @($extras | Where-Object { $_.Category -ne 'Public' })
    if ($public.Count -gt 0) { $groups += @{ Header = 'Public folders (shared by all users)'; Items = $public } }
    if ($other.Count -gt 0)  { $groups += @{ Header = 'Extras found on drive'; Items = $other } }
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

#region XAML
$NNXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NN Rescue Copy" Height="720" Width="1100" MinHeight="520" MinWidth="740"
        WindowStartupLocation="CenterScreen"
        Background="#0F172A" Foreground="#E2E8F0" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#233752"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="#334155" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="17" Height="17" CornerRadius="4" BorderThickness="1.5"
                      BorderBrush="#475569" Background="#0F172A" VerticalAlignment="Center">
                <Path x:Name="Check" Data="M 3.2,8.6 L 7,12.2 L 13.4,4.2" Stroke="#0B1220" StrokeThickness="2.4"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#38BDF8"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#38BDF8"/>
                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="#38BDF8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Background" Value="#0F172A"/>
      <Setter Property="CaretBrush" Value="#38BDF8"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="#334155" BorderThickness="1">
              <ScrollViewer x:Name="PART_ContentHost" Margin="10,7" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#38BDF8"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#38BDF8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="#0B1220" BorderBrush="#334155" BorderThickness="1" CornerRadius="7"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="7" Margin="1">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#0284C7" Offset="0"/>
                    <GradientStop Color="#38BDF8" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListView">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="AlternationCount" Value="2"/>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Padding" Value="6,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="1"
                    CornerRadius="6" Padding="{TemplateBinding Padding}" Margin="0,1">
              <GridViewRowPresenter Content="{TemplateBinding Content}"
                                    Columns="{TemplateBinding GridView.ColumnCollection}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="ItemsControl.AlternationIndex" Value="1">
                <Setter TargetName="Bd" Property="Background" Value="#223045"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#26354E"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#14486E"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#38BDF8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="#94A3B8"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Border Background="Transparent" BorderBrush="#334155" BorderThickness="0,0,0,1" Padding="8,0,8,7">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TreeView">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="4"/>
    </Style>
    <Style TargetType="TreeViewItem">
      <Setter Property="IsExpanded" Value="True"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TreeViewItem">
            <StackPanel>
              <Border x:Name="Bd" CornerRadius="6" Padding="8,5" Background="Transparent">
                <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
              </Border>
              <ItemsPresenter Margin="26,0,0,4"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" SourceName="Bd" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1C2A42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#F87171"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <DockPanel>
    <!-- Step rail -->
    <Border DockPanel.Dock="Left" Width="188" Background="#0B1220" Padding="0,24,0,0">
      <StackPanel>
        <TextBlock Text="NERDY NEIGHBOR" FontSize="11" FontWeight="SemiBold" Foreground="#94A3B8" Margin="26,0,0,2"/>
        <TextBlock Text="Rescue Copy" FontSize="21" FontWeight="Bold" Foreground="#38BDF8" Margin="26,0,0,30"/>
        <TextBlock x:Name="RailStep1" Text="1   Drives"    Padding="18,10" Margin="8,1" FontWeight="Bold" Foreground="#38BDF8"/>
        <TextBlock x:Name="RailStep2" Text="2   Job name"  Padding="18,10" Margin="8,1" Foreground="#94A3B8"/>
        <TextBlock x:Name="RailStep3" Text="3   Selection" Padding="18,10" Margin="8,1" Foreground="#94A3B8"/>
        <TextBlock x:Name="RailStep4" Text="4   Copy"      Padding="18,10" Margin="8,1" Foreground="#94A3B8"/>
        <TextBlock x:Name="RailStep5" Text="5   Done"      Padding="18,10" Margin="8,1" Foreground="#94A3B8"/>
      </StackPanel>
    </Border>
    <!-- Bottom nav -->
    <Border DockPanel.Dock="Bottom" Background="#0B1220" BorderBrush="#1E293B" BorderThickness="0,1,0,0" Padding="22,12">
      <DockPanel>
        <Button x:Name="BtnBack" Content="Back" DockPanel.Dock="Left" Width="110" Visibility="Hidden"/>
        <Button x:Name="BtnNext" Content="Next" DockPanel.Dock="Right" Width="170" HorizontalAlignment="Right"
                Background="#0284C7" FontSize="14"/>
        <TextBlock/>
      </DockPanel>
    </Border>
    <!-- Content -->
    <Grid Margin="20,18,20,12">
      <!-- Step 1: Drives -->
      <Grid x:Name="PanelStep1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,14">
          <TextBlock Text="Pick the drives" FontSize="19" FontWeight="SemiBold"/>
          <TextBlock Text="The customer drive is only ever read. Everything lands on the backup drive." Foreground="#94A3B8" Margin="0,3,0,0"/>
        </StackPanel>
        <Border Grid.Row="1" CornerRadius="12" Background="#1E293B" BorderBrush="#334155" BorderThickness="1" Padding="14,12">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="CUSTOMER DRIVE - SOURCE, READ-ONLY" FontSize="10" FontWeight="SemiBold" Foreground="#94A3B8" Margin="4,0,0,8"/>
            <ListView x:Name="LvSource">
              <ListView.View><GridView>
                <GridViewColumn Header="Drive" Width="70" DisplayMemberBinding="{Binding Drive}"/>
                <GridViewColumn Header="Label" Width="150" DisplayMemberBinding="{Binding Label}"/>
                <GridViewColumn Header="Size" Width="80" DisplayMemberBinding="{Binding Size}"/>
                <GridViewColumn Header="Free" Width="80" DisplayMemberBinding="{Binding Free}"/>
                <GridViewColumn Header="Contents" Width="170" DisplayMemberBinding="{Binding Contents}"/>
              </GridView></ListView.View>
            </ListView>
          </DockPanel>
        </Border>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="2,10">
          <Button x:Name="BtnBrowseSource" Content="Browse folder as source..." Padding="12,6" FontSize="12" FontWeight="Normal"/>
          <Button x:Name="BtnRescan" Content="Rescan drives" Padding="12,6" FontSize="12" FontWeight="Normal" Margin="8,0,0,0"/>
          <TextBlock x:Name="TxtSrcPick" Foreground="#4ADE80" Margin="16,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <Border Grid.Row="3" CornerRadius="12" Background="#1E293B" BorderBrush="#334155" BorderThickness="1" Padding="14,12">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="BACKUP DRIVE - DESTINATION" FontSize="10" FontWeight="SemiBold" Foreground="#94A3B8" Margin="4,0,0,8"/>
            <ListView x:Name="LvDest">
              <ListView.View><GridView>
                <GridViewColumn Header="Drive" Width="70" DisplayMemberBinding="{Binding Drive}"/>
                <GridViewColumn Header="Label" Width="150" DisplayMemberBinding="{Binding Label}"/>
                <GridViewColumn Header="Size" Width="80" DisplayMemberBinding="{Binding Size}"/>
                <GridViewColumn Header="Free" Width="80" DisplayMemberBinding="{Binding Free}"/>
                <GridViewColumn Header="Contents" Width="170" DisplayMemberBinding="{Binding Contents}"/>
              </GridView></ListView.View>
            </ListView>
          </DockPanel>
        </Border>
      </Grid>
      <!-- Step 2: Job name -->
      <ScrollViewer x:Name="PanelStep2" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel MaxWidth="620" VerticalAlignment="Center">
        <TextBlock Text="Name the job" FontSize="19" FontWeight="SemiBold"/>
        <TextBlock Text="The backup folder is named after the customer. Re-using a name resumes that job." Foreground="#94A3B8" Margin="0,3,0,16"/>
        <Border CornerRadius="12" Background="#1E293B" BorderBrush="#334155" BorderThickness="1" Padding="22,20">
          <StackPanel>
            <TextBlock Text="CUSTOMER / JOB NAME" FontSize="10" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,7"/>
            <TextBox x:Name="TxtJobName"/>
            <TextBlock x:Name="TxtJobHint" Foreground="#94A3B8" FontSize="12" Margin="0,7,0,0" TextWrapping="Wrap"
                       Text="Prefilled from the customer drive's registry when readable."/>
            <TextBlock Text="BACKUP WILL BE WRITTEN TO" FontSize="10" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,20,0,4"/>
            <TextBlock x:Name="TxtDestPreview" Foreground="#4ADE80" FontFamily="Consolas" TextWrapping="Wrap"/>
            <TextBlock Foreground="#94A3B8" FontSize="12" Margin="0,16,0,0" TextWrapping="Wrap"
                       Text="Files already copied with matching sizes are skipped on a re-run, so a resumed job only copies what is missing."/>
          </StackPanel>
        </Border>
      </StackPanel>
      </ScrollViewer>
      <!-- Step 3: Selection -->
      <Grid x:Name="PanelStep3" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,12">
          <TextBlock Text="Choose what to copy" FontSize="19" FontWeight="SemiBold"/>
          <TextBlock Text="Profile folders are pre-selected. Extras found outside user folders are off until you tick them." Foreground="#94A3B8" Margin="0,3,0,0"/>
        </StackPanel>
        <Border Grid.Row="1" CornerRadius="10" Background="#1E293B" BorderBrush="#334155" BorderThickness="1" Padding="14,8" Margin="0,0,0,10">
          <WrapPanel>
            <CheckBox x:Name="ChkAppData" Content="Include key AppData (browsers, Outlook PST/OST, Sticky Notes, Windows Mail)" Margin="0,4,24,4"/>
            <CheckBox x:Name="ChkVerify" Content="Verify after copy (SHA-256)" Margin="0,4,24,4"/>
            <CheckBox x:Name="ChkForce" Content="Re-copy everything (ignore resume)" Margin="0,4,0,4"/>
          </WrapPanel>
        </Border>
        <Border Grid.Row="2" CornerRadius="12" Background="#1E293B" BorderBrush="#334155" BorderThickness="1" Padding="8">
          <TreeView x:Name="TreeSel"/>
        </Border>
        <DockPanel Grid.Row="3" Margin="2,10,2,0">
          <TextBlock x:Name="TxtScanStatus" Foreground="#94A3B8" DockPanel.Dock="Left" Text="Scanning..."/>
          <TextBlock x:Name="TxtTotals" DockPanel.Dock="Right" HorizontalAlignment="Right" FontWeight="Bold"/>
        </DockPanel>
      </Grid>
      <!-- Step 4: Copy -->
      <Grid x:Name="PanelStep4" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="TxtPhase" Text="Copying..." FontSize="17" FontWeight="SemiBold" Margin="0,0,0,12"/>
        <ProgressBar Grid.Row="1" x:Name="PbOverall"/>
        <TextBlock Grid.Row="2" x:Name="TxtCurrentFile" Foreground="#94A3B8" FontFamily="Consolas" FontSize="11"
                   Margin="2,9,2,0" TextTrimming="CharacterEllipsis"/>
        <TextBlock Grid.Row="3" x:Name="TxtCounters" Margin="2,10,2,10" FontFamily="Consolas" FontSize="12"/>
        <Border Grid.Row="4" CornerRadius="12" Background="#1E293B" BorderBrush="#334155" BorderThickness="1" Padding="12,10">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="PROBLEMS" FontSize="10" FontWeight="SemiBold" Foreground="#94A3B8" Margin="2,0,0,6"/>
            <ListBox x:Name="LbProblems" FontFamily="Consolas" FontSize="12"/>
          </DockPanel>
        </Border>
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
          <Button x:Name="BtnPause" Content="Pause" Width="110" Margin="0,0,10,0"/>
          <Button x:Name="BtnCancelCopy" Content="Cancel" Width="110" Background="#7F1D1D"/>
        </StackPanel>
      </Grid>
      <!-- Step 5: Done -->
      <ScrollViewer x:Name="PanelStep5" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel MaxWidth="680" VerticalAlignment="Center">
        <TextBlock Text="Rescue complete" FontSize="24" FontWeight="Bold" Foreground="#4ADE80"/>
        <Border CornerRadius="12" Background="#1E293B" BorderBrush="#334155" BorderThickness="1" Padding="20,16" Margin="0,14,0,0">
          <StackPanel>
            <TextBlock x:Name="TxtSummary" FontFamily="Consolas" FontSize="13" TextWrapping="Wrap"/>
            <TextBlock x:Name="TxtCloudNote" Margin="0,12,0,0" Foreground="#FBBF24" TextWrapping="Wrap"/>
            <ListBox x:Name="LbFinalProblems" MaxHeight="160" Margin="0,10,0,0" FontFamily="Consolas" FontSize="12"/>
          </StackPanel>
        </Border>
        <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
          <Button x:Name="BtnOpenDest" Content="Open backup folder" Background="#0284C7" Margin="0,0,12,0"/>
          <Button x:Name="BtnOpenReport" Content="Open report"/>
        </StackPanel>
      </StackPanel>
      </ScrollViewer>
    </Grid>
  </DockPanel>
</Window>
'@
#endregion

#region Background
function Start-NNBackground {
    param([string]$FunctionName, [object[]]$Arguments)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in @(Get-ChildItem function: | Where-Object { $_.Name -like '*-NN*' })) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry ($fn.Name, $fn.Definition)))
    }
    foreach ($vn in @('NNIsWindows','NNOsExcludeRoot','NNProfileExclude','NNVisibleFolders','NNProfileRootSkip','NNAppDataDefs',
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

#region GUI
# All GUI helpers are top-level functions operating on $script:NNCtx - WPF event
# handler scriptblocks execute against the session scope chain and would NOT see
# functions nested inside Start-NNRescueGui.

function Show-NNStep {
    param([int]$n)
    $script:NNCtx.Step = $n
    $ui = $script:NNCtx.UI
    $labels = @('Drives', 'Job name', 'Selection', 'Copy', 'Done')
    for ($i = 1; $i -le 5; $i++) {
        $tb = $ui["RailStep$i"]
        $ui["PanelStep$i"].Visibility = 'Collapsed'
        $tb.Background = 'Transparent'
        $tb.FontWeight = 'Normal'
        if ($i -lt $n) {
            # completed step: checkmark, quiet green
            $tb.Text = [string][char]0x2713 + '   ' + $labels[$i - 1]
            $tb.Foreground = '#4ADE80'
        } else {
            $tb.Text = ('{0}   {1}' -f $i, $labels[$i - 1])
            $tb.Foreground = '#94A3B8'
        }
    }
    $ui["PanelStep$n"].Visibility = 'Visible'
    $ui["RailStep$n"].Background = '#13253D'
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
        # two-line content: label + size, full source path in small mono underneath
        $stack = New-Object System.Windows.Controls.StackPanel
        $line1 = New-Object System.Windows.Controls.TextBlock
        $line1.Text = $item.Label + $sz
        $line2 = New-Object System.Windows.Controls.TextBlock
        $line2.Text = $item.SourcePath
        $line2.FontFamily = 'Consolas'
        $line2.FontSize = 10.5
        $line2.FontWeight = 'Normal'
        $line2.Foreground = '#64748B'
        $line2.Margin = '0,1,0,0'
        $null = $stack.Children.Add($line1)
        $null = $stack.Children.Add($line2)
        $cb.Content = $stack
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
    $c.ScanGen++
    $c.ScanJob = Start-NNBackground 'Invoke-NNScanJob' @($c.SourceRoot, [bool]$c.UI.ChkAppData.IsChecked, $c.Queue, $c.ScanGen)
}

function Read-NNQueue {
    $c = $script:NNCtx
    $m = $null
    while ($c.Queue.TryDequeue([ref]$m)) {
        if ($m.Type -eq 'scangroup') {
            if ($m.Gen -eq $c.ScanGen) {
                $c.Model.Add($m.Group)
                Add-NNTreeGroup $m.Group
                Update-NNTotals
            }
        }
        elseif ($m.Type -eq 'scandone') {
            if ($m.Gen -eq $c.ScanGen) {
                if ($m.Error) { $c.UI.TxtScanStatus.Text = 'Scan failed: ' + $m.Error }
                else { $c.UI.TxtScanStatus.Text = 'Scan complete.' }
            }
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
            if ($c.CopyWatch -and $c.PlanBytes -gt 0 -and $m.BytesDone -gt 0) {
                $elapsed = $c.CopyWatch.Elapsed
                $etaSec = ($elapsed.TotalSeconds / $m.BytesDone) * ($c.PlanBytes - $m.BytesDone)
                if ($etaSec -lt 0) { $etaSec = 0 }
                $c.UI.TxtPhase.Text = ('Copying... {0:hh\:mm\:ss} elapsed, ~{1:hh\:mm\:ss} left' -f $elapsed, [TimeSpan]::FromSeconds($etaSec))
            }
        }
        elseif ($m.Type -eq 'done') {
            $c.Summary = $m.Summary; $c.Pairs = $m.Pairs; $c.FolderStats = $m.FolderStats
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
            $hashCount = 0
            $failCount = 0
            foreach ($mm in $m.Mismatches) {
                if ($mm -like 'HASH-MISMATCH*') { $hashCount++ } else { $failCount++ }
            }
            if ($hashCount -gt 0) { $c.Summary['HASH-MISMATCH'] = $hashCount }
            if ($failCount -gt 0) { $c.Summary['VERIFY-FAIL'] = $failCount }
            Complete-NNJob
        }
    }
}

function Complete-NNJob {
    $c = $script:NNCtx
    try {
        $reportPath = Join-Path $c.JobRoot '_RescueReport.html'
        $null = New-NNHtmlReport -Summary $c.Summary -Problems $c.Problems -JobName $c.JobName -Bytes $c.BytesDone -OutPath $reportPath -FolderStats $c.FolderStats
        $c.ReportPath = $reportPath
    } catch {
        $c.ReportPath = $null
    }
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

$NNExistingXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Existing backup found" Width="520" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#0F172A" Foreground="#E2E8F0"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#233752"/>
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Margin" Value="0,5,0,0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="#334155" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <StackPanel Margin="22,18,22,18">
    <TextBlock Text="This job already has data on the backup drive" FontSize="16" FontWeight="SemiBold"/>
    <TextBlock x:Name="DlgPath" FontFamily="Consolas" FontSize="12" Foreground="#4ADE80" TextWrapping="Wrap" Margin="0,8,0,14"/>
    <Button x:Name="DlgResume" Background="#0284C7">
      <StackPanel>
        <TextBlock Text="Resume this job" FontWeight="Bold"/>
        <TextBlock Text="Skip files already copied - only what is missing gets copied." FontSize="11" FontWeight="Normal" Foreground="#CBD5E1"/>
      </StackPanel>
    </Button>
    <Button x:Name="DlgKeepBoth">
      <StackPanel>
        <TextBlock Text="Keep both" FontWeight="Bold"/>
        <TextBlock x:Name="DlgKeepBothHint" Text="Leave the existing backup alone and start a new folder." FontSize="11" FontWeight="Normal" Foreground="#94A3B8"/>
      </StackPanel>
    </Button>
    <Button x:Name="DlgStartOver">
      <StackPanel>
        <TextBlock Text="Start over" FontWeight="Bold"/>
        <TextBlock Text="Re-copy everything into the same folder, replacing earlier copies. Nothing is deleted first." FontSize="11" FontWeight="Normal" Foreground="#94A3B8"/>
      </StackPanel>
    </Button>
    <Button x:Name="DlgCancel" Content="Go back" HorizontalContentAlignment="Center" Background="#1E293B" Margin="0,12,0,0"/>
  </StackPanel>
</Window>
'@

function Show-NNExistingDataDialog {
    param([string]$JobRoot, [string]$NextName)
    $dlg = [Windows.Markup.XamlReader]::Parse($NNExistingXaml)
    $dlg.Owner = $script:NNCtx.Win
    $dlg.FindName('DlgPath').Text = $JobRoot
    $dlg.FindName('DlgKeepBothHint').Text = ('Leave the existing backup alone and back up into "{0}" instead.' -f $NextName)
    $script:NNDialogChoice = $null
    $dlg.FindName('DlgResume').Add_Click({ $script:NNDialogChoice = 'resume'; $script:NNDialog.Close() })
    $dlg.FindName('DlgKeepBoth').Add_Click({ $script:NNDialogChoice = 'keepboth'; $script:NNDialog.Close() })
    $dlg.FindName('DlgStartOver').Add_Click({ $script:NNDialogChoice = 'startover'; $script:NNDialog.Close() })
    $dlg.FindName('DlgCancel').Add_Click({ $script:NNDialogChoice = $null; $script:NNDialog.Close() })
    $script:NNDialog = $dlg
    $null = $dlg.ShowDialog()
    return $script:NNDialogChoice
}

function Start-NNRescueGui {
    $win = [Windows.Markup.XamlReader]::Parse($NNXaml)
    # Fit small screens (e.g. 800x600 recovery monitors): never open larger than the work area
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($win.Width -gt ($wa.Width - 8)) { $win.Width = [math]::Max($win.MinWidth, $wa.Width - 8) }
    if ($win.Height -gt ($wa.Height - 8)) { $win.Height = [math]::Max($win.MinHeight, $wa.Height - 8) }
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
        Summary = $null; Pairs = $null; FolderStats = @(); PlanBytes = [long]0; PlanCount = 0
        ReportPath = $null; BytesDone = [long]0; ScanGen = 0; CopyWatch = $null
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
            if (Test-NNPathOverlap $c.BackupRoot $c.SourceRoot) {
                [System.Windows.MessageBox]::Show('Destination overlaps the source drive. Pick a different backup drive.', 'NN Rescue Copy') | Out-Null; return
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
            if (Test-NNJobHasData $c.JobRoot) {
                $nextName = Get-NNAvailableJobName $c.BackupRoot $name
                $choice = Show-NNExistingDataDialog -JobRoot $c.JobRoot -NextName $nextName
                if (-not $choice) { return }
                if ($choice -eq 'keepboth') {
                    $c.JobName = $nextName
                    $c.JobRoot = Get-NNJobRoot $c.BackupRoot $nextName
                    $c.UI.TxtJobName.Text = $nextName
                }
                if ($choice -eq 'startover') { $c.UI.ChkForce.IsChecked = $true }
            }
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
            $c.CopyWatch = [Diagnostics.Stopwatch]::StartNew()
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
    param([string]$SourceRoot, [bool]$IncludeAppData, $Queue, [int]$Gen)
    try {
        $model = Build-NNSelectionModel $SourceRoot $IncludeAppData
        foreach ($g in $model) {
            foreach ($i in $g.Items) { $i.SizeBytes = Get-NNFolderSize $i.SourcePath }
            $Queue.Enqueue([pscustomobject]@{ Type = 'scangroup'; Group = $g; Gen = $Gen })
        }
        $Queue.Enqueue([pscustomobject]@{ Type = 'scandone'; Error = $null; Gen = $Gen })
    } catch {
        $Queue.Enqueue([pscustomobject]@{ Type = 'scandone'; Error = $_.Exception.Message; Gen = $Gen })
    }
}
#endregion

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

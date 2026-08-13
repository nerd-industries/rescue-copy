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
        $code = 'err=' + ($_.Exception.HResult -band 0xFFFF)
        if ($_.Exception -is [ComponentModel.Win32Exception]) { $code = 'err=' + $_.Exception.NativeErrorCode }
        if ($_.Exception -is [IO.FileNotFoundException] -or $_.Exception -is [IO.DirectoryNotFoundException]) { $code = 'err=2' }
        if ($_.Exception.InnerException -is [IO.FileNotFoundException] -or $_.Exception.InnerException -is [IO.DirectoryNotFoundException]) { $code = 'err=2' }
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
    $Queue.Enqueue([pscustomobject]@{ Type = 'plan'; Count = $files.Count; Bytes = $totalBytes })

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
            $Queue.Enqueue([pscustomobject]@{ Type = 'file'; Result = $r; Path = $item.File.FullName; BytesDone = $done; Index = $i })
        }
    } finally {
        $csv.Dispose()
    }
    $Queue.Enqueue([pscustomobject]@{ Type = 'done'; Summary = $summary; Problems = [object[]]$problems; Pairs = [object[]]$pairs;
                      Cancelled = [bool]$Control.Cancel; BytesDone = $done })
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
    $Queue.Enqueue([pscustomobject]@{ Type = 'verifydone'; Mismatches = $mismatch })
    return $mismatch
}
#endregion

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

#region Entry stub (replaced in Task 10)
function Start-NNRescue {
    Write-Host 'NN Rescue Copy: GUI not implemented yet.' -ForegroundColor Yellow
}
#endregion

if ($env:NN_RESCUE_NOGUI -ne '1') { Start-NNRescue }

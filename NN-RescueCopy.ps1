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
    if ($extras.Count -gt 0) { $groups += @{ Header = 'Extras found on drive'; Items = $extras } }
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

#region Entry stub (replaced in Task 10)
function Start-NNRescue {
    Write-Host 'NN Rescue Copy: GUI not implemented yet.' -ForegroundColor Yellow
}
#endregion

if ($env:NN_RESCUE_NOGUI -ne '1') { Start-NNRescue }

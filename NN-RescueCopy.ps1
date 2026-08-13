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

#region Entry stub (replaced in Task 10)
function Start-NNRescue {
    Write-Host 'NN Rescue Copy: GUI not implemented yet.' -ForegroundColor Yellow
}
#endregion

if ($env:NN_RESCUE_NOGUI -ne '1') { Start-NNRescue }

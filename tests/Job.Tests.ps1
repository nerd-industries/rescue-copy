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
    It 'reports per-folder stats for secured files' {
        $done = $script:Msgs | Where-Object Type -eq 'done'
        @($done.FolderStats).Count | Should -Be 1
        $done.FolderStats[0].Folder | Should -Be (Join-NNParts @('Users','bob','Desktop'))
        $done.FolderStats[0].Files | Should -Be 2
        $done.FolderStats[0].Bytes | Should -BeGreaterThan 0
    }
    It 'reports OK counts and collects verify pairs' {
        $done = $script:Msgs | Where-Object Type -eq 'done'
        $done.Summary['OK'] | Should -Be 2
        $done.Pairs.Count | Should -Be 2
        $done.Cancelled | Should -BeFalse
    }
    It 'streams a CSV log with header' {
        $csv = Get-Content (Join-Path $script:JobRoot '_RescueLog.csv')
        $csv[0] | Should -Be 'Time,Result,Size,Source,Destination'
        $csv.Count | Should -Be 3
    }
    It 'writes human-readable sizes in the CSV' {
        $csv = Get-Content (Join-Path $script:JobRoot '_RescueLog.csv')
        foreach ($line in $csv[1..($csv.Count - 1)]) { $line | Should -Match ',\d+(\.\d+)? (B|KB|MB|GB|TB),' }
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
    It 'quotes the Result field in the CSV log so embedded commas do not break rows' {
        $csv = Get-Content (Join-Path $script:JobRoot '_RescueLog.csv')
        foreach ($line in $csv[1..($csv.Count - 1)]) { $line | Should -Match '^\S+,"[^"]*",[^,]+,' }
    }
}

Describe 'Invoke-NNCopyJob with a locked CSV log' {
    It 'still copies every file when _RescueLog.csv is held open by another program' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("nnlock-" + [guid]::NewGuid().ToString('N'))
        $src = Join-Path $dir 'src'
        $null = New-Item -ItemType Directory -Force -Path $src
        Set-Content -Path (Join-Path $src 'a.txt') -Value 'locked-log test'
        $jobRoot = Join-Path $dir 'out'
        $null = New-Item -ItemType Directory -Force -Path $jobRoot
        $lockPath = Join-Path $jobRoot '_RescueLog.csv'
        # simulate Excel holding the log open exclusively
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $t = New-NNTarget 'Extra' $null 'src' $src (Join-NNParts @('Extras', 'src')) $true
            $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
            $ctl = [hashtable]::Synchronized(@{ Cancel = $false; Pause = $false })
            Invoke-NNCopyJob -Targets @($t) -JobRoot $jobRoot -Control $ctl -Queue $q -Force $true
            $m = $null; $msgs = @()
            while ($q.TryDequeue([ref]$m)) { $msgs += $m }
            $done = $msgs | Where-Object Type -eq 'done'
            $done.Summary['OK'] | Should -Be 1
            Test-Path (Join-NNParts @($jobRoot, 'Extras', 'src', 'a.txt')) | Should -BeTrue
            ($done.Problems -join ';') | Should -Not -Match 'FATAL\('
            ($done.Problems -join ';') | Should -Match 'LOG-'
            # the fallback log captured the copy
            $alt = @(Get-ChildItem -Path $jobRoot -Filter '_RescueLog-*.csv')
            $alt.Count | Should -Be 1
            (Get-Content $alt[0].FullName).Count | Should -Be 2
        } finally {
            $lock.Dispose()
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-NNCopyJob enumeration errors' {
    It 'surfaces ENUM-FAIL problems collected from a partially-failing enumeration pass' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("nnenum-" + [guid]::NewGuid().ToString('N'))
        $src = Join-Path $dir 'src'
        $null = New-Item -ItemType Directory -Force -Path $src
        Set-Content -Path (Join-Path $src 'ok.txt') -Value 'fine'
        $t = New-NNTarget 'Extra' $null 'src' $src (Join-NNParts @('Extras', 'src')) $true

        Mock Get-ChildItem {
            Write-Error 'Access to the path is denied' -ErrorAction Continue
            return @(Get-Item -LiteralPath (Join-Path $src 'ok.txt'))
        } -ParameterFilter { $Recurse -eq $true }

        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $ctl = [hashtable]::Synchronized(@{ Cancel = $false; Pause = $false })
        Invoke-NNCopyJob -Targets @($t) -JobRoot (Join-Path $dir 'out') -Control $ctl -Queue $q -Force $false 2>$null

        $m = $null; $msgs = @()
        while ($q.TryDequeue([ref]$m)) { $msgs += $m }
        $done = $msgs | Where-Object Type -eq 'done'
        ($done.Problems -join ';') | Should -Match 'ENUM-FAIL\('
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

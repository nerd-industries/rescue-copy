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

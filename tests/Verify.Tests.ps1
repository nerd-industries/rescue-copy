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

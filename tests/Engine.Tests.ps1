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
    It 'hydrates cloud-only files through a normal open when the cloud driver serves them' {
        Mock Test-NNCloudOnly { $true }
        Mock Open-NNHydratingStream { [IO.File]::OpenRead($script:SrcFile) }
        $dst = Join-Path $script:Dir 'cloud1.bin'
        Copy-NNFile -Src (Get-Item $script:SrcFile) -DestPath $dst -Force $false -Buffer $script:Buf | Should -Be 'OK'
        (Get-Item $dst).Length | Should -Be 300000
    }
    It 'reports CLOUD-ONLY when hydration is impossible (slaved drive, not signed in)' {
        Mock Test-NNCloudOnly { $true }
        Mock Open-NNHydratingStream { throw (New-Object IO.IOException 'no cloud filter driver') }
        Copy-NNFile -Src (Get-Item $script:SrcFile) -DestPath (Join-Path $script:Dir 'cloud2.bin') -Force $false -Buffer $script:Buf |
            Should -Be 'CLOUD-ONLY'
        Test-Path (Join-Path $script:Dir 'cloud2.bin') | Should -BeFalse
    }
    It 'reports OPEN-FAIL for an unreadable source' {
        $gone = Join-Path $script:Dir 'gone.bin'
        Set-Content -Path $gone -Value 'x'
        $info = Get-Item $gone
        Remove-Item $gone
        $r = Copy-NNFile -Src $info -DestPath (Join-Path $script:Dir 'out2.bin') -Force $false -Buffer $script:Buf
        $r | Should -Be 'OPEN-FAIL(err=2)'
    }
}

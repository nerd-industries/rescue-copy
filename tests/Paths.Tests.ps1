BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
}

Describe 'ConvertTo-NNLongPath' {
    It 'prefixes a drive path' { ConvertTo-NNLongPath 'C:\Users\bob' | Should -Be '\\?\C:\Users\bob' }
    It 'leaves an already-long path alone' { ConvertTo-NNLongPath '\\?\C:\x' | Should -Be '\\?\C:\x' }
    It 'converts UNC paths' { ConvertTo-NNLongPath '\\srv\share\f' | Should -Be '\\?\UNC\srv\share\f' }
}

Describe 'Test-NNPathOverlap' {
    # Built with Join-NNParts (platform separator) rather than hardcoded '\' so
    # these assertions hold on both the Linux test box and real Windows targets.
    It 'flags overlap when the paths are equal' {
        $p = Join-NNParts @('mnt', 'data')
        Test-NNPathOverlap $p $p | Should -BeTrue
    }
    It 'flags overlap when A contains B' {
        Test-NNPathOverlap (Join-NNParts @('mnt', 'data')) (Join-NNParts @('mnt', 'data', 'sub', 'deeper')) | Should -BeTrue
    }
    It 'flags overlap when B contains A' {
        Test-NNPathOverlap (Join-NNParts @('mnt', 'data', 'sub', 'deeper')) (Join-NNParts @('mnt', 'data')) | Should -BeTrue
    }
    It 'flags overlap case-insensitively' {
        Test-NNPathOverlap (Join-NNParts @('MNT', 'DATA')) (Join-NNParts @('mnt', 'data', 'sub')) | Should -BeTrue
    }
    It 'does not flag sibling directories' {
        Test-NNPathOverlap (Join-NNParts @('mnt', 'data')) (Join-NNParts @('mnt', 'backup')) | Should -BeFalse
    }
    It 'does not flag lookalike prefixes' {
        Test-NNPathOverlap (Join-NNParts @('mnt', 'data')) (Join-NNParts @('mnt', 'data2')) | Should -BeFalse
        Test-NNPathOverlap (Join-NNParts @('mnt', 'data2')) (Join-NNParts @('mnt', 'data')) | Should -BeFalse
    }
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

Describe 'Test-NNJobHasData' {
    BeforeAll {
        $script:JD = Join-Path ([IO.Path]::GetTempPath()) ("nnjd-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:JD 'empty')
        $null = New-Item -ItemType Directory -Force -Path (Join-NNParts @($script:JD, 'used', 'Users', 'bob'))
        Set-Content -Path (Join-NNParts @($script:JD, 'used', 'Users', 'bob', 'f.txt')) -Value 'data'
    }
    AfterAll { Remove-Item -Recurse -Force $script:JD -ErrorAction SilentlyContinue }
    It 'is false for a missing folder' { Test-NNJobHasData (Join-Path $script:JD 'nope') | Should -BeFalse }
    It 'is false for an empty folder' { Test-NNJobHasData (Join-Path $script:JD 'empty') | Should -BeFalse }
    It 'is true when any file exists beneath it' { Test-NNJobHasData (Join-Path $script:JD 'used') | Should -BeTrue }
}

Describe 'Get-NNAvailableJobName' {
    BeforeAll {
        $script:BR = Join-Path ([IO.Path]::GetTempPath()) ("nnav-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-NNParts @($script:BR, 'NN-Rescue', 'Tom Scott'))
        Set-Content -Path (Join-NNParts @($script:BR, 'NN-Rescue', 'Tom Scott', 'x.txt')) -Value 'x'
        $null = New-Item -ItemType Directory -Force -Path (Join-NNParts @($script:BR, 'NN-Rescue', 'Tom Scott (2)'))
        Set-Content -Path (Join-NNParts @($script:BR, 'NN-Rescue', 'Tom Scott (2)', 'x.txt')) -Value 'x'
    }
    AfterAll { Remove-Item -Recurse -Force $script:BR -ErrorAction SilentlyContinue }
    It 'skips names whose job folders already hold data' {
        Get-NNAvailableJobName $script:BR 'Tom Scott' | Should -Be 'Tom Scott (3)'
    }
    It 'returns the name unchanged when it is free' {
        Get-NNAvailableJobName $script:BR 'Fresh Customer' | Should -Be 'Fresh Customer'
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

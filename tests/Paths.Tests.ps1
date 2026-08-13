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

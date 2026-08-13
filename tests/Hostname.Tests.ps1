BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
}

Describe 'ConvertFrom-NNRegQuery' {
    It 'parses a REG_SZ value' {
        $lines = @(
            ''
            'HKEY_LOCAL_MACHINE\NN-RESCUE-SYS\ControlSet001\Control\ComputerName\ComputerName'
            '    ComputerName    REG_SZ    DESKTOP-TOM01'
            ''
        )
        ConvertFrom-NNRegQuery $lines 'ComputerName' | Should -Be 'DESKTOP-TOM01'
    }
    It 'parses a REG_DWORD value' {
        ConvertFrom-NNRegQuery @('    Current    REG_DWORD    0x1') 'Current' | Should -Be '0x1'
    }
    It 'returns null when absent' {
        ConvertFrom-NNRegQuery @('nothing here') 'ComputerName' | Should -Be $null
    }
}

Describe 'Get-NNSourceHostname' {
    It 'returns null off-Windows / when hive is missing' {
        Get-NNSourceHostname ([IO.Path]::GetTempPath()) | Should -Be $null
    }
}

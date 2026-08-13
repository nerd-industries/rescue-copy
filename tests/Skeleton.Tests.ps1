BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
}

Describe 'script skeleton' {
    It 'defines the entry function without launching it' {
        Get-Command Start-NNRescue -CommandType Function | Should -Not -BeNullOrEmpty
    }
    It 'detects this box is not Windows' {
        $NNIsWindows | Should -BeFalse
    }
}

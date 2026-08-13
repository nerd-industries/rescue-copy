BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    $script:ScriptFile = Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1'
    . $script:ScriptFile
}

Describe 'whole script' {
    It 'parses with zero errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptFile, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
    It 'contains no PS7-only null-coalescing or ternary operators' {
        $src = Get-Content -Raw $script:ScriptFile
        $src | Should -Not -Match '\?\?'
    }
}

Describe 'Get-NNVolumes' {
    It 'returns drive rows with the GUI-bound properties' {
        $v = @(Get-NNVolumes)
        $v.Count | Should -BeGreaterThan 0
        foreach ($p in @('Drive','Label','Size','Free','Contents','Root','FreeBytes')) {
            $v[0].PSObject.Properties.Name | Should -Contain $p
        }
    }
}

Describe 'Start-NNBackground' {
    It 'runs a copy job in a background runspace with injected functions' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("nnbg-" + [guid]::NewGuid().ToString('N'))
        $src = Join-Path $dir 'src'
        $null = New-Item -ItemType Directory -Force -Path $src
        Set-Content -Path (Join-Path $src 'f.txt') -Value 'bg test'
        $t = New-NNTarget 'Extra' $null 'src' $src (Join-NNParts @('Extras','src')) $true
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $ctl = [hashtable]::Synchronized(@{ Cancel = $false; Pause = $false })
        $job = Start-NNBackground 'Invoke-NNCopyJob' @(@($t), (Join-Path $dir 'out'), $ctl, $q, $false)
        $null = $job.PS.EndInvoke($job.Handle)
        $job.PS.Dispose()
        Test-Path (Join-NNParts @($dir, 'out', 'Extras', 'src', 'f.txt')) | Should -BeTrue
        $m = $null; $types = @()
        while ($q.TryDequeue([ref]$m)) { $types += $m.Type }
        $types | Should -Contain 'done'
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')

    # Synthetic customer drive
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("nnscan-" + [guid]::NewGuid().ToString('N'))
    foreach ($p in @(
        @('Users','bob','Desktop'), @('Users','bob','Documents'), @('Users','bob','OneDrive - Contoso','Tax'),
        @('Users','bob','AppData','Local','Google','Chrome','User Data','Default'),
        @('Users','bob','AppData','Local','Packages','Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe','LocalState'),
        @('Users','alice','Pictures'),
        @('Users','Default','Desktop'), @('Users','Public','Documents'), @('Users','Public','Music'),
        @('Windows','System32'), @('Program Files','App'), @('ProgramData','Intuit','QB'),
        @('Scans'), @('QuickBooksBackups'),
        @('Users','bob','a copy'), @('Users','bob','Saved Games')
    )) { $null = New-Item -ItemType Directory -Force -Path (Join-NNParts (@($script:Root) + $p)) }
    Set-Content -Path (Join-NNParts @($script:Root,'Users','bob','Desktop','a.txt')) -Value ('x' * 100)
    Set-Content -Path (Join-NNParts @($script:Root,'Users','bob','Desktop','b.txt')) -Value ('y' * 50)
    # legacy profile junction: must be skipped (reparse point)
    $null = New-Item -ItemType SymbolicLink -Path (Join-NNParts @($script:Root,'Users','bob','Application Data')) -Target (Join-NNParts @($script:Root,'Users','bob','Desktop'))
}

AfterAll { Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue }

Describe 'Get-NNUserProfileDirs' {
    It 'lists real profiles only' {
        $names = (Get-NNUserProfileDirs $script:Root).Name | Sort-Object
        $names | Should -Be @('alice','bob')
    }
}

Describe 'Get-NNProfileTargets' {
    BeforeAll { $script:BobT = Get-NNProfileTargets (Get-Item (Join-NNParts @($script:Root,'Users','bob'))) }
    It 'finds visible folders, OneDrive dirs, and custom user-made folders' {
        ($script:BobT | ForEach-Object Label | Sort-Object) |
            Should -Be @('a copy','Desktop','Documents','OneDrive - Contoso','Saved Games')
    }
    It 'is selected by default with the right DestRel' {
        $d = $script:BobT | Where-Object Label -eq 'Desktop'
        $d.Selected | Should -BeTrue
        $d.DestRel | Should -Be (Join-NNParts @('Users','bob','Desktop'))
    }
    It 'custom folders are selected by default and routed under the user' {
        $cf = $script:BobT | Where-Object Label -eq 'a copy'
        $cf.Selected | Should -BeTrue
        $cf.DestRel | Should -Be (Join-NNParts @('Users','bob','a copy'))
    }
    It 'never includes AppData or legacy junctions' {
        ($script:BobT | ForEach-Object Label) | Should -Not -Contain 'AppData'
        ($script:BobT | ForEach-Object Label) | Should -Not -Contain 'Application Data'
    }
}

Describe 'Get-NNAppDataTargets' {
    BeforeAll { $script:BobA = Get-NNAppDataTargets (Get-Item (Join-NNParts @($script:Root,'Users','bob'))) }
    It 'finds Chrome and Sticky Notes only' {
        ($script:BobA | ForEach-Object Label | Sort-Object) |
            Should -Be @('Chrome (bookmarks, passwords, profiles)','Sticky Notes')
    }
    It 'routes into AppData-Rescue' {
        ($script:BobA | Where-Object Label -like 'Chrome*').DestRel |
            Should -Be (Join-NNParts @('Users','bob','AppData-Rescue','Chrome'))
    }
}

Describe 'Get-NNExtraTargets' {
    BeforeAll { $script:Extras = Get-NNExtraTargets $script:Root }
    It 'flags non-OS root folders, unselected' {
        $s = $script:Extras | Where-Object Label -eq 'Scans'
        $s | Should -Not -BeNullOrEmpty
        $s.Selected | Should -BeFalse
        ($script:Extras | ForEach-Object Label) | Should -Not -Contain 'Windows'
    }
    It 'selects Public Documents but not Public Music' {
        ($script:Extras | Where-Object { $_.Category -eq 'Public' -and $_.Label -eq 'Documents' }).Selected | Should -BeTrue
        ($script:Extras | Where-Object { $_.Category -eq 'Public' -and $_.Label -eq 'Music' }).Selected | Should -BeFalse
    }
    It 'finds QuickBooks ProgramData' {
        ($script:Extras | Where-Object Label -eq 'ProgramData Intuit') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-NNFolderSize' {
    It 'sums file bytes recursively' {
        Get-NNFolderSize (Join-NNParts @($script:Root,'Users','bob','Desktop')) | Should -BeGreaterOrEqual 150
    }
}

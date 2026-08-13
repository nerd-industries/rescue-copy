BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')

    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("nngui-" + [guid]::NewGuid().ToString('N'))
    foreach ($p in @(
        @('Users','bob','Desktop'),
        @('Users','bob','AppData','Local','Google','Chrome','User Data'),
        @('Users','Public','Documents'),
        @('Windows'), @('Scans')
    )) { $null = New-Item -ItemType Directory -Force -Path (Join-NNParts (@($script:Root) + $p)) }
    Set-Content -Path (Join-NNParts @($script:Root,'Users','bob','Desktop','f.txt')) -Value 'data'
}

AfterAll { Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue }

Describe 'Build-NNSelectionModel' {
    It 'groups per user, splits Public folders from drive extras' {
        $m = Build-NNSelectionModel $script:Root $false
        @($m).Count | Should -Be 3
        $m[0].Header | Should -Be 'User: bob'
        ($m[0].Items | ForEach-Object Category) | Should -Not -Contain 'AppData'
        $m[1].Header | Should -Be 'Public folders (shared by all users)'
        ($m[1].Items | ForEach-Object Label) | Should -Contain 'Documents'
        $m[2].Header | Should -Be 'Extras found on drive'
        ($m[2].Items | ForEach-Object Label) | Should -Not -Contain 'Documents'
    }
    It 'adds appdata targets when requested' {
        $m = Build-NNSelectionModel $script:Root $true
        ($m[0].Items | Where-Object Category -eq 'AppData').Count | Should -Be 1
    }
}

Describe 'Get-NNSelectedBytes' {
    It 'sums only selected, sized items' {
        $m = Build-NNSelectionModel $script:Root $false
        foreach ($g in $m) { foreach ($i in $g.Items) { $i.SizeBytes = 100 } }
        foreach ($i in $m[2].Items) { $i.Selected = $false }
        $total = Get-NNSelectedBytes $m
        # bob/Desktop (selected) + Public Documents (selected by default); Scans extra deselected
        $total | Should -Be 200
    }
}

Describe 'Existing-data dialog XAML' {
    It 'is valid XML with the controls the dialog wires' {
        $doc = [xml]$NNExistingXaml
        $doc.Window | Should -Not -BeNullOrEmpty
        $names = $doc.SelectNodes('//*/@*') | Where-Object { $_.LocalName -eq 'Name' } | ForEach-Object Value
        foreach ($n in @('DlgPath','DlgResume','DlgKeepBoth','DlgKeepBothHint','DlgStartOver','DlgCancel')) {
            $names | Should -Contain $n
        }
    }
}

Describe 'XAML' {
    BeforeAll { $script:Doc = [xml]$NNXaml }
    It 'is valid XML' { $script:Doc.Window | Should -Not -BeNullOrEmpty }
    It 'contains every control Task 10 wires' {
        $names = $script:Doc.SelectNodes('//*/@*') |
            Where-Object { $_.LocalName -eq 'Name' } | ForEach-Object Value
        foreach ($n in @('RailStep1','RailStep2','RailStep3','RailStep4','RailStep5',
                         'PanelStep1','PanelStep2','PanelStep3','PanelStep4','PanelStep5',
                         'LvSource','LvDest','BtnBrowseSource','BtnRescan','TxtSrcPick',
                         'TxtJobName','TxtDestPreview','TxtJobHint',
                         'ChkAppData','ChkVerify','ChkForce','TreeSel','TxtTotals','TxtScanStatus',
                         'PbOverall','TxtPhase','TxtCurrentFile','TxtCounters','LbProblems','BtnPause','BtnCancelCopy',
                         'TxtSummary','TxtCloudNote','LbFinalProblems','BtnOpenDest','BtnOpenReport',
                         'BtnBack','BtnNext')) {
            $names | Should -Contain $n
        }
    }
}

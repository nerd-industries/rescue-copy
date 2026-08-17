BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')

    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("nngui-" + [guid]::NewGuid().ToString('N'))
    foreach ($p in @(
        @('Users','bob','Desktop'),
        @('Users','bob','AppData','Local','Google','Chrome','User Data'),
        @('Users','Public','Documents'),
        @('Users','husk','AppData','Roaming'),
        @('Users','bob','EmptyStuff'),
        @('Windows'), @('Scans')
    )) { $null = New-Item -ItemType Directory -Force -Path (Join-NNParts (@($script:Root) + $p)) }
    Set-Content -Path (Join-NNParts @($script:Root,'Users','bob','Desktop','f.txt')) -Value 'data'
}

AfterAll { Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue }

Describe 'Build-NNSelectionModel' {
    It 'groups per user, splits Public folders from drive extras' {
        $m = Build-NNSelectionModel $script:Root $false
        $headers = @($m | ForEach-Object Header)
        $headers | Should -Contain 'User: bob'
        $headers | Should -Contain 'Public folders (shared by all users)'
        $headers | Should -Contain 'Extras found on drive'
        $bob = $m | Where-Object Header -eq 'User: bob'
        ($bob.Items | ForEach-Object Category) | Should -Not -Contain 'AppData'
        $extras = $m | Where-Object Header -eq 'Extras found on drive'
        ($extras.Items | ForEach-Object Label) | Should -Not -Contain 'Documents'
    }
    It 'keeps husk profiles visible as an empty group instead of dropping them' {
        $m = Build-NNSelectionModel $script:Root $false
        $husk = $m | Where-Object Header -eq 'User: husk'
        $husk | Should -Not -BeNullOrEmpty
        @($husk.Items).Count | Should -Be 0
    }
    It 'adds appdata targets when requested' {
        $m = Build-NNSelectionModel $script:Root $true
        $bob = $m | Where-Object Header -eq 'User: bob'
        ($bob.Items | Where-Object Category -eq 'AppData').Count | Should -Be 1
    }
}

Describe 'Get-NNSelectedBytes' {
    It 'sums only selected, sized items' {
        $m = Build-NNSelectionModel $script:Root $false
        foreach ($g in $m) { foreach ($i in $g.Items) { $i.SizeBytes = 100 } }
        $extras = $m | Where-Object Header -eq 'Extras found on drive'
        foreach ($i in $extras.Items) { $i.Selected = $false }
        # selected: bob Desktop + bob EmptyStuff + Public Documents (Scans deselected)
        Get-NNSelectedBytes $m | Should -Be 300
    }
}

Describe 'Invoke-NNScanJob protocol' {
    It 'posts all groups before any sizes, then per-item sizes, then scandone; empties get unticked' {
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Invoke-NNScanJob $script:Root $false $q 7
        $msgs = @(); $x = $null
        while ($q.TryDequeue([ref]$x)) { $msgs += $x }
        $types = @($msgs | ForEach-Object Type)
        # every scangroup precedes the first itemsize
        ([array]::IndexOf($types, 'itemsize')) | Should -BeGreaterThan ([array]::LastIndexOf($types, 'scangroup'))
        $types[-1] | Should -Be 'scandone'
        ($msgs | Where-Object Type -eq 'itemsize' | ForEach-Object Gen | Sort-Object -Unique) | Should -Be 7
        # the empty custom folder sized to 0 and got deselected
        $groups = $msgs | Where-Object Type -eq 'scangroup'
        $bob = ($groups | ForEach-Object Group | Where-Object Header -eq 'User: bob')
        $empty = $bob.Items | Where-Object Label -eq 'EmptyStuff'
        $empty.SizeBytes | Should -Be 0
        $empty.Selected | Should -BeFalse
        ($bob.Items | Where-Object Label -eq 'Desktop').Selected | Should -BeTrue
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

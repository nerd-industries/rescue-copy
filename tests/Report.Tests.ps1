BeforeAll {
    $env:NN_RESCUE_NOGUI = '1'
    . (Join-Path $PSScriptRoot '..' 'NN-RescueCopy.ps1')
    $script:Out = Join-Path ([IO.Path]::GetTempPath()) ("nnrep-" + [guid]::NewGuid().ToString('N') + '.html')
}

AfterAll { Remove-Item -Force $script:Out -ErrorAction SilentlyContinue }

Describe 'New-NNHtmlReport' {
    It 'writes a report containing counts, problems, and cloud-only guidance' {
        $summary = @{ 'OK' = 240; 'CLOUD-ONLY' = 4; 'OPEN-FAIL(err=1392)' = 1 }
        $problems = @('OPEN-FAIL(err=1392)  C:\Users\bob\Desktop\bad.docx')
        $path = New-NNHtmlReport -Summary $summary -Problems $problems -JobName 'Tom Scott' -Bytes 1739461755 -OutPath $script:Out
        $path | Should -Be $script:Out
        $html = Get-Content -Raw $script:Out
        $html | Should -Match 'Tom Scott'
        $html | Should -Match '240'
        $html | Should -Match 'CLOUD-ONLY'
        $html | Should -Match 'bad\.docx'
        $html | Should -Match 'sign'   # cloud-only sign-in guidance present
        $html | Should -Match '1\.6 GB'
    }
    It 'HTML-encodes problem paths' {
        $path = New-NNHtmlReport -Summary @{ OK = 1 } -Problems @('READ-FAIL(x<y&z)  C:\f.txt') -JobName 'j' -Bytes 10 -OutPath $script:Out
        (Get-Content -Raw $script:Out) | Should -Match 'x&lt;y&amp;z'
    }
    It 'is a print-first white document with the embedded logo and a page-broken appendix' {
        $null = New-NNHtmlReport -Summary @{ 'OK' = 3; 'CLOUD-ONLY' = 1 } -Problems @('OPEN-FAIL(err=2)  C:\x.txt') -JobName 'j2' -Bytes 123456789 -OutPath $script:Out
        $html = Get-Content -Raw $script:Out
        $html | Should -Match 'data:image/png;base64,'
        $html | Should -Match '@media print'
        $html | Should -Match 'page-break-before'
        $html | Should -Not -Match 'background:#0f172a'
    }
    It 'pairs plain-language labels with the technical code' {
        $html = Get-Content -Raw $script:Out
        $html | Should -Match 'Copied and verified'
        $html | Should -Match 'Stored only in your cloud account'
        $html | Should -Match 'Total files processed'
    }
}

Describe "Install-Prerequisites" {
    It "does not use the PSFramework.NuGet bootstrapper or PowerShell Gallery HTML package pages" {
        $scriptPath = Join-Path $global:__testData.TestRoot '..\build\powershell\Install-Prerequisites.ps1'
        $content = Get-Content -Path $scriptPath -Raw

        $content | Should -Not -Match 'PSFramework\.NuGet'
        $content | Should -Not -Match 'www\.powershellgallery\.com/packages'
    }
}

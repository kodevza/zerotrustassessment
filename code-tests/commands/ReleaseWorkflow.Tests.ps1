Describe "Release workflow" {
    It "creates a Microsoft Graph PowerShell context from the OIDC token before Connect-ZtAssessment" {
        $workflowPath = Join-Path $global:__testData.TestRoot '..\.github\workflows\release.yml'
        $content = Get-Content -Path $workflowPath -Raw

        $content | Should -Match 'Connect-MgGraph\s+-AccessToken\s+\$secureToken\s+-NoWelcome'
        $content | Should -Not -Match 'Connect-Entra\s+-AccessToken'
    }
}

Describe "Release workflow" {
    It "uses GitHub OIDC directly instead of interactive Connect-ZtAssessment authentication" {
        $workflowPath = Join-Path $global:__testData.TestRoot '..\.github\workflows\release.yml'
        $content = Get-Content -Path $workflowPath -Raw

        $content | Should -Match 'ACTIONS_ID_TOKEN_REQUEST_TOKEN'
        $content | Should -Match 'client_assertion_type'
        $content | Should -Match 'https://graph\.microsoft\.com/\.default'
        $content | Should -Match 'Connect-MgGraph\s+-AccessToken\s+\$secureGraphToken\s+-NoWelcome'
        $content | Should -Match 'Connect-AzAccount[\s\S]+-FederatedToken\s+\$idToken\.value'
        $content | Should -Match "SessionState\.PSVariable\.Set\('ConnectedService', \[string\[\]\]@\('Graph', 'Azure'\)\)"
        $content | Should -Match 'SessionState\.InvokeCommand\.InvokeScript'
        $content | Should -Match 'function script:Test-ZtContext'
        $content | Should -Not -Match 'Connect-Entra\s+-AccessToken'
        $content | Should -Not -Match 'Connect-ZtAssessment\s+-Service\s+Graph,\s*Azure'
    }
}

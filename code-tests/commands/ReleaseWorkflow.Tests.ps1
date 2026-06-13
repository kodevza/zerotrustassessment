Describe "Release workflow" {
    It "does not run the tenant assessment as part of publishing a release" {
        $workflowPath = Join-Path $global:__testData.TestRoot '..\.github\workflows\release.yml'
        $content = Get-Content -Path $workflowPath -Raw

        $content | Should -Not -Match 'Invoke-ZtAssessment'
        $content | Should -Not -Match 'https://graph\.microsoft\.com/\.default'
        $content | Should -Not -Match 'ACTIONS_ID_TOKEN_REQUEST_TOKEN'
        $content | Should -Not -Match 'id-token:\s+write'
    }
}

Describe "Zero Trust assessment workflow" {
    It "runs manually" {
        $workflowPath = Join-Path $global:__testData.TestRoot '..\.github\workflows\zero-trust-assessment.yml'
        $content = Get-Content -Path $workflowPath -Raw

        $content | Should -Match 'workflow_dispatch:'
        $content | Should -Match 'release_version:'
        $content | Should -Match 'azure_subscription_id:'
    }

    It "uses GitHub OIDC directly instead of interactive Connect-ZtAssessment authentication" {
        $workflowPath = Join-Path $global:__testData.TestRoot '..\.github\workflows\zero-trust-assessment.yml'
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

    It "uploads the generated report zip to Azure Blob Storage" {
        $workflowPath = Join-Path $global:__testData.TestRoot '..\.github\workflows\zero-trust-assessment.yml'
        $content = Get-Content -Path $workflowPath -Raw

        $content | Should -Match 'subscription-id:\s+\$\{\{\s*inputs\.azure_subscription_id\s*\}\}'
        $content | Should -Match 'Compress-Archive\s+-Path\s+\$reportDirectory\s+-DestinationPath\s+\$zipPath\s+-Force'
        $content | Should -Match 'az storage account list[\s\S]+zta-purpose'
        $content | Should -Match 'az storage blob upload[\s\S]+--auth-mode\s+login'
        $content | Should -Match 'runs/\$\{\{\s*github\.run_id\s*\}\}/\$\{\{\s*github\.run_attempt\s*\}\}/ZeroTrustReport95\.zip'
    }
}

Describe "Assessment artifact storage Bicep" {
    It "defines subscription-scoped private storage for assessment artifacts" {
        $bicepPath = Join-Path $global:__testData.TestRoot '..\infra\assessment-storage.bicep'
        $modulePath = Join-Path $global:__testData.TestRoot '..\infra\modules\assessment-storage-account.bicep'
        $content = (Get-Content -Path $bicepPath -Raw) + "`n" + (Get-Content -Path $modulePath -Raw)

        $content | Should -Match "targetScope\s*=\s*'subscription'"
        $content | Should -Match "targetScope\s*=\s*'resourceGroup'"
        $content | Should -Match "resourceGroupName\s+string\s*=\s*'rg-zero-trust-assessment'"
        $content | Should -Match "containerName\s+string\s*=\s*'assessment-runs'"
        $content | Should -Match "'zta-purpose':\s*'assessment-artifacts'"
        $content | Should -Match 'Microsoft\.Resources/resourceGroups'
        $content | Should -Match 'Microsoft\.Storage/storageAccounts'
        $content | Should -Match 'Microsoft\.Storage/storageAccounts/blobServices/containers'
        $content | Should -Match 'allowBlobPublicAccess:\s*false'
        $content | Should -Match "minimumTlsVersion:\s*'TLS1_2'"
        $content | Should -Match 'supportsHttpsTrafficOnly:\s*true'
        $content | Should -Match "publicAccess:\s*'None'"
    }
}

targetScope = 'subscription'

@description('Azure region for the resource group and storage account.')
param location string = deployment().location

@description('Resource group that will contain the assessment artifact storage account.')
param resourceGroupName string = 'rg-zero-trust-assessment'

@description('Lowercase storage account name prefix. Keep this short because a deterministic suffix is appended.')
@minLength(3)
@maxLength(11)
param storageNamePrefix string = 'zta'

@description('Private blob container used for uploaded assessment ZIP artifacts.')
@minLength(3)
@maxLength(63)
param containerName string = 'assessment-runs'

var assessmentTags = {
  'zta-purpose': 'assessment-artifacts'
}
var storageAccountName = toLower('${storageNamePrefix}${uniqueString(subscription().id, resourceGroupName)}')

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: assessmentTags
}

module artifactStorage 'modules/assessment-storage-account.bicep' = {
  name: 'assessmentArtifactStorage'
  scope: az.resourceGroup(resourceGroup.name)
  params: {
    assessmentTags: assessmentTags
    containerName: containerName
    location: location
    storageAccountName: storageAccountName
  }
}

output resourceGroupName string = resourceGroup.name
output storageAccountName string = artifactStorage.outputs.storageAccountName
output containerName string = artifactStorage.outputs.containerName

// Global parameters
targetScope = 'subscription'

@description('Build configuration object')
#disable-next-line no-unused-params
param BUILD object

@description('IPAM spoke configuration')
param ipamSpoke object

@description('IPAM configuration')
param ipamConfig object

@description('IPAM-Engine App Registration Client/App ID')
param engineAppId string

@secure()
@description('IPAM-Engine App Registration Client Secret')
param engineAppSecret string

@description('GUID for Resource Naming')
param guid string = newGuid()

// Use ipamConfig for deployment settings
var location = ipamConfig.location
var azureCloud = ipamConfig.azureCloud
var privateAcr = ipamConfig.privateAcr
var deployAsFunc = ipamConfig.deployAsFunc
var deployAsContainer = ipamConfig.deployAsContainer
var uiAppId = ipamConfig.uiAppId
var tags = ipamConfig.tags

// Use ipamSpoke for resource names
var resourceNames = {
  functionName: ipamSpoke.functionApp.name
  appServiceName: ipamSpoke.appService.name
  functionPlanName: ipamSpoke.appServicePlan.function
  appServicePlanName: ipamSpoke.appServicePlan.app
  cosmosAccountName: ipamSpoke.cosmosDb.accountName
  cosmosContainerName: ipamSpoke.cosmosDb.containerName
  cosmosDatabaseName: ipamSpoke.cosmosDb.databaseName
  keyVaultName: ipamSpoke.keyVault.name
  workspaceName: ipamSpoke.logAnalytics.name
  managedIdentityName: ipamSpoke.managedIdentity.name
  resourceGroupName: ipamSpoke.resourceGroup.name
  storageAccountName: ipamSpoke.storageAccount.name
  containerRegistryName: ipamSpoke.containerRegistry.name
}

// Resource Group
resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  location: location
  name: resourceNames.resourceGroupName
  tags: tags
}

// Log Analytics Workspace
module logAnalyticsWorkspace './modules/logAnalyticsWorkspace.bicep' ={
  name: 'logAnalyticsWorkspaceModule'
  scope: resourceGroup
  params: {
    location: location
    workspaceName: resourceNames.workspaceName
  }
}

// Managed Identity for Secure Access to KeyVault
module managedIdentity './modules/managedIdentity.bicep' = {
  name: 'managedIdentityModule'
  scope: resourceGroup
  params: {
    location: location
    managedIdentityName: resourceNames.managedIdentityName
  }
}

// KeyVault for Secure Values
module keyVault './modules/keyVault.bicep' = {
  name: 'keyVaultModule'
  scope: resourceGroup
  params: {
    location: location
    keyVaultName: resourceNames.keyVaultName
    identityPrincipalId:  managedIdentity.outputs.principalId
    identityClientId:  managedIdentity.outputs.clientId
    uiAppId: uiAppId
    engineAppId: engineAppId
    engineAppSecret: engineAppSecret
    workspaceId: logAnalyticsWorkspace.outputs.workspaceId
  }
}

// Cosmos DB for IPAM Database
module cosmos './modules/cosmos.bicep' = {
  name: 'cosmosModule'
  scope: resourceGroup
  params: {
    location: location
    cosmosAccountName: resourceNames.cosmosAccountName
    cosmosContainerName: resourceNames.cosmosContainerName
    cosmosDatabaseName: resourceNames.cosmosDatabaseName
    workspaceId: logAnalyticsWorkspace.outputs.workspaceId
    principalId: managedIdentity.outputs.principalId
  }
}

// Storage Account for Nginx Config/Function Metadata
module storageAccount './modules/storageAccount.bicep' = if (deployAsFunc) {
  scope: resourceGroup
  name: 'storageAccountModule'
  params: {
    location: location
    storageAccountName: resourceNames.storageAccountName
    workspaceId: logAnalyticsWorkspace.outputs.workspaceId
  }
}

// Container Registry
module containerRegistry './modules/containerRegistry.bicep' = if (privateAcr) {
  scope: resourceGroup
  name: 'containerRegistryModule'
  params: {
    location: location
    containerRegistryName: resourceNames.containerRegistryName
    principalId: managedIdentity.outputs.principalId
  }
}

// App Service w/ Docker Compose + CI
module appService './modules/appService.bicep' = if (!deployAsFunc) {
  scope: resourceGroup
  name: 'appServiceModule'
  params: {
    location: location
    azureCloud: azureCloud
    appServiceName: resourceNames.appServiceName
    appServicePlanName: resourceNames.appServicePlanName
    keyVaultUri: keyVault.outputs.keyVaultUri
    cosmosDbUri: cosmos.outputs.cosmosDocumentEndpoint
    databaseName: resourceNames.cosmosDatabaseName
    containerName: resourceNames.cosmosContainerName
    managedIdentityId: managedIdentity.outputs.id
    managedIdentityClientId: managedIdentity.outputs.clientId
    workspaceId: logAnalyticsWorkspace.outputs.workspaceId
    deployAsContainer: deployAsContainer
    privateAcr: privateAcr
    privateAcrUri: privateAcr ? containerRegistry.outputs.acrUri : ''
  }
}

// Function App
module functionApp './modules/functionApp.bicep' = if (deployAsFunc) {
  scope: resourceGroup
  name: 'functionAppModule'
  params: {
    location: location
    azureCloud: azureCloud
    functionAppName: resourceNames.functionName
    functionPlanName: resourceNames.appServicePlanName
    keyVaultUri: keyVault.outputs.keyVaultUri
    cosmosDbUri: cosmos.outputs.cosmosDocumentEndpoint
    databaseName: resourceNames.cosmosDatabaseName
    containerName: resourceNames.cosmosContainerName
    managedIdentityId: managedIdentity.outputs.id
    managedIdentityClientId: managedIdentity.outputs.clientId
    storageAccountName: resourceNames.storageAccountName
    workspaceId: logAnalyticsWorkspace.outputs.workspaceId
    deployAsContainer: deployAsContainer
    privateAcr: privateAcr
    privateAcrUri: privateAcr ? containerRegistry.outputs.acrUri : ''
  }
}

// Outputs
output suffix string = uniqueString(guid)
output subscriptionId string = subscription().subscriptionId
output resourceGroupName string = resourceGroup.name
output appServiceName string = deployAsFunc ? resourceNames.functionName : resourceNames.appServiceName
output appServiceHostName string = deployAsFunc ? functionApp.outputs.functionAppHostName : appService.outputs.appServiceHostName
output appServiceUrl string = deployAsFunc ? 'https://${functionApp.outputs.functionAppHostName}' : 'https://${appService.outputs.appServiceHostName}'
output acrName string = privateAcr ? containerRegistry.outputs.acrName : ''
output acrUri string = privateAcr ? containerRegistry.outputs.acrUri : ''

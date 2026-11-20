// Data-plane RBAC between the apps and their dependencies.
// Runs after the apps exist because system-assigned identities are only created with the app.

@description('Principal ID of the Web API system-assigned identity.')
param webApiPrincipalId string

@description('Principal ID of the Function App system-assigned identity.')
param functionAppPrincipalId string

@description('Name of the App Configuration store.')
param appConfigName string

@description('Name of the separate data storage account.')
param dataStorageAccountName string

@description('Name of the Function App host storage account.')
param hostStorageAccountName string

// Built-in role definition IDs
var roles = {
  appConfigurationDataReader: '516239f1-63e1-4d78-a4de-a74fb236a071'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f2feb4c4f2a'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
}

// Roles the Functions runtime needs on its own host storage for identity-based connections.
var hostStorageRoles = [
  roles.storageBlobDataOwner
  roles.storageQueueDataContributor
  roles.storageTableDataContributor
]

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' existing = {
  name: appConfigName
}

resource dataStorage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: dataStorageAccountName
}

resource hostStorage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: hostStorageAccountName
}

// Web API -> App Configuration: read configuration
resource webApiAppConfigReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, webApiPrincipalId, roles.appConfigurationDataReader)
  scope: appConfig
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.appConfigurationDataReader)
    principalId: webApiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Web API -> data storage: read/write blobs
resource webApiDataStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataStorage.id, webApiPrincipalId, roles.storageBlobDataContributor)
  scope: dataStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalId: webApiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Function App -> App Configuration: read configuration
resource functionAppConfigReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, functionAppPrincipalId, roles.appConfigurationDataReader)
  scope: appConfig
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.appConfigurationDataReader)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Function App -> data storage: read/write blobs
resource functionDataStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataStorage.id, functionAppPrincipalId, roles.storageBlobDataContributor)
  scope: dataStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Function App -> its own host storage: blob, queue and table access for the Functions runtime
resource functionHostStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in hostStorageRoles: {
    name: guid(hostStorage.id, functionAppPrincipalId, roleId)
    scope: hostStorage
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalId: functionAppPrincipalId
      principalType: 'ServicePrincipal'
    }
  }
]

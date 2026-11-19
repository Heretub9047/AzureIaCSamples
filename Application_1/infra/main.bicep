// Application_1 orchestrator.
// Deployed at subscription scope so it can create the resource group, then:
//   1. resource group + two subnets in the existing VNet (other resource group)
//   2. App Insights, App Service Plan, App Config, Key Vault, host + data storage
//   3. Web API and Function App
//   4. RBAC between the apps and their dependencies
targetScope = 'subscription'

// ---------------------------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------------------------

@description('Resource IDs of the existing central privatelink DNS zones.')
type privateDnsZoneIdsType = {
  @description('privatelink.blob.core.windows.net')
  blob: string

  @description('privatelink.queue.core.windows.net')
  queue: string

  @description('privatelink.table.core.windows.net')
  table: string

  @description('privatelink.vaultcore.azure.net')
  keyVault: string

  @description('privatelink.azurewebsites.net')
  webApps: string

  @description('privatelink.azconfig.io')
  appConfiguration: string
}

@description('Existing virtual network that the new subnets are added to.')
type existingVnetType = {
  @description('Subscription ID that contains the VNet.')
  subscriptionId: string

  @description('Resource group that contains the VNet.')
  resourceGroupName: string

  @description('Name of the VNet.')
  name: string
}

@description('A subnet to add to the existing VNet.')
type subnetConfigType = {
  @description('Subnet name.')
  name: string

  @description('Subnet address prefix.')
  addressPrefix: string

  @description('Optional. NSG resource ID (keep it here if policy requires one, or redeploys remove it).')
  networkSecurityGroupResourceId: string?

  @description('Optional. Route table resource ID (same rule as the NSG).')
  routeTableResourceId: string?
}

// ---------------------------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------------------------

@description('Short application name used in resource names, e.g. app1.')
@maxLength(8)
param appName string

@description('Environment name.')
@allowed([
  'dev'
  'test'
])
param environmentName string

@description('Azure region for all resources.')
param location string

@description('Short region code used in resource names, e.g. aue.')
param locationShort string

@description('Tags applied to every resource.')
param tags object = {}

@description('Existing VNet the subnets are added to.')
param existingVnet existingVnetType

@description('Subnet for private endpoint NICs.')
param privateEndpointSubnet subnetConfigType

@description('Subnet delegated to Microsoft.Web/serverFarms for app VNet integration.')
param vnetIntegrationSubnet subnetConfigType

@description('Resource ID of the existing central Log Analytics workspace.')
param logAnalyticsWorkspaceResourceId string

@description('Resource IDs of the existing central privatelink DNS zones.')
param privateDnsZoneIds privateDnsZoneIdsType

@description('App Service Plan SKU.')
param appServicePlanSku string = 'P0v3'

@description('App Service Plan instance count.')
param appServicePlanCapacity int = 1

@description('App Service Plan zone redundancy.')
param appServicePlanZoneRedundant bool = false

@description('Web API .NET version (Windows), e.g. v10.0.')
param webApiNetFrameworkVersion string = 'v10.0'

@description('Function App .NET version (Windows, isolated worker), e.g. v10.0.')
param functionNetFrameworkVersion string = 'v10.0'

@description('Function App worker runtime.')
param functionsWorkerRuntime string = 'dotnet-isolated'

@description('Enable purge protection on App Configuration.')
param appConfigPurgeProtection bool = false

// ---------------------------------------------------------------------------------------------
// Naming (CAF abbreviations). Globally unique names get a short deterministic suffix.
// ---------------------------------------------------------------------------------------------

var resourceGroupName = 'rg-${appName}-${environmentName}-${locationShort}'
var suffix = take(uniqueString(subscription().id, resourceGroupName), 5)
var baseName = '${appName}-${environmentName}-${locationShort}'

var names = {
  appInsights: 'appi-${baseName}'
  appServicePlan: 'asp-${baseName}'
  appConfig: 'appcs-${baseName}-${suffix}'
  keyVault: take('kv-${appName}-${environmentName}-${suffix}', 24)
  webApi: 'app-${appName}-api-${environmentName}-${suffix}'
  functionApp: 'func-${appName}-${environmentName}-${suffix}'
  hostStorage: take(toLower('st${appName}fn${environmentName}${suffix}'), 24)
  dataStorage: take(toLower('st${appName}data${environmentName}${suffix}'), 24)
}

var allTags = union(tags, {
  application: appName
  environment: environmentName
})

// ---------------------------------------------------------------------------------------------
// 1. Resource group + subnets in the existing VNet
// ---------------------------------------------------------------------------------------------

module rg 'modules/resource-group.bicep' = {
  name: 'rg-${baseName}'
  params: {
    name: resourceGroupName
    location: location
    tags: allTags
  }
}

module peSubnet 'modules/subnet.bicep' = {
  name: 'snet-pe-${baseName}'
  scope: resourceGroup(existingVnet.subscriptionId, existingVnet.resourceGroupName)
  params: {
    vnetName: existingVnet.name
    subnetName: privateEndpointSubnet.name
    addressPrefix: privateEndpointSubnet.addressPrefix
    networkSecurityGroupResourceId: privateEndpointSubnet.?networkSecurityGroupResourceId ?? ''
    routeTableResourceId: privateEndpointSubnet.?routeTableResourceId ?? ''
  }
}

// Deployed after the PE subnet: parallel writes to the same VNet fail with AnotherOperationInProgress.
module intSubnet 'modules/subnet.bicep' = {
  name: 'snet-int-${baseName}'
  scope: resourceGroup(existingVnet.subscriptionId, existingVnet.resourceGroupName)
  dependsOn: [
    peSubnet
  ]
  params: {
    vnetName: existingVnet.name
    subnetName: vnetIntegrationSubnet.name
    addressPrefix: vnetIntegrationSubnet.addressPrefix
    networkSecurityGroupResourceId: vnetIntegrationSubnet.?networkSecurityGroupResourceId ?? ''
    routeTableResourceId: vnetIntegrationSubnet.?routeTableResourceId ?? ''
    delegationServiceName: 'Microsoft.Web/serverFarms'
  }
}

// ---------------------------------------------------------------------------------------------
// 2. Shared services and data stores
// ---------------------------------------------------------------------------------------------

module appInsights 'modules/app-insights.bicep' = {
  name: 'appi-${baseName}'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: names.appInsights
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: allTags
  }
}

module appServicePlan 'modules/app-service-plan.bicep' = {
  name: 'asp-${baseName}'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: names.appServicePlan
    location: location
    skuName: appServicePlanSku
    skuCapacity: appServicePlanCapacity
    zoneRedundant: appServicePlanZoneRedundant
    tags: allTags
  }
}

module appConfig 'modules/app-configuration.bicep' = {
  name: 'appcs-${baseName}'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: names.appConfig
    location: location
    privateEndpointSubnetResourceId: peSubnet.outputs.resourceId
    privateDnsZoneResourceId: privateDnsZoneIds.appConfiguration
    enablePurgeProtection: appConfigPurgeProtection
    tags: allTags
  }
}

module keyVault 'modules/key-vault.bicep' = {
  name: 'kv-${baseName}'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: names.keyVault
    location: location
    privateEndpointSubnetResourceId: peSubnet.outputs.resourceId
    privateDnsZoneResourceId: privateDnsZoneIds.keyVault
    tags: allTags
  }
}

// Function App host storage (AzureWebJobsStorage). No file endpoint: a dedicated plan doesn't use a content share.
module hostStorage 'modules/storage-account.bicep' = {
  name: 'st-fn-${baseName}'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: names.hostStorage
    location: location
    privateEndpointSubnetResourceId: peSubnet.outputs.resourceId
    privateEndpointServices: [
      {
        service: 'blob'
        privateDnsZoneResourceId: privateDnsZoneIds.blob
      }
      {
        service: 'queue'
        privateDnsZoneResourceId: privateDnsZoneIds.queue
      }
      {
        service: 'table'
        privateDnsZoneResourceId: privateDnsZoneIds.table
      }
    ]
    tags: allTags
  }
}

// Separate data storage account used by both the Web API and the Function App.
module dataStorage 'modules/storage-account.bicep' = {
  name: 'st-data-${baseName}'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: names.dataStorage
    location: location
    privateEndpointSubnetResourceId: peSubnet.outputs.resourceId
    privateEndpointServices: [
      {
        service: 'blob'
        privateDnsZoneResourceId: privateDnsZoneIds.blob
      }
    ]
    tags: allTags
  }
}

// ---------------------------------------------------------------------------------------------
// 3. Compute
// ---------------------------------------------------------------------------------------------

module webApi 'modules/web-api.bicep' = {
  name: 'app-api-${baseName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: names.webApi
    location: location
    appServicePlanResourceId: appServicePlan.outputs.resourceId
    vnetIntegrationSubnetResourceId: intSubnet.outputs.resourceId
    privateEndpointSubnetResourceId: peSubnet.outputs.resourceId
    privateDnsZoneResourceId: privateDnsZoneIds.webApps
    appInsightsResourceId: appInsights.outputs.resourceId
    appConfigEndpoint: appConfig.outputs.endpoint
    dataStorageBlobEndpoint: dataStorage.outputs.primaryBlobEndpoint
    netFrameworkVersion: webApiNetFrameworkVersion
    tags: allTags
  }
}

module functionApp 'modules/function-app.bicep' = {
  name: 'func-${baseName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: names.functionApp
    location: location
    appServicePlanResourceId: appServicePlan.outputs.resourceId
    hostStorageAccountResourceId: hostStorage.outputs.resourceId
    vnetIntegrationSubnetResourceId: intSubnet.outputs.resourceId
    privateEndpointSubnetResourceId: peSubnet.outputs.resourceId
    privateDnsZoneResourceId: privateDnsZoneIds.webApps
    appInsightsResourceId: appInsights.outputs.resourceId
    dataStorageBlobEndpoint: dataStorage.outputs.primaryBlobEndpoint
    netFrameworkVersion: functionNetFrameworkVersion
    functionsWorkerRuntime: functionsWorkerRuntime
    tags: allTags
  }
}

// ---------------------------------------------------------------------------------------------
// 4. RBAC
// ---------------------------------------------------------------------------------------------

module roleAssignments 'modules/role-assignments.bicep' = {
  name: 'rbac-${baseName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    webApiPrincipalId: webApi.outputs.principalId
    functionAppPrincipalId: functionApp.outputs.principalId
    appConfigName: appConfig.outputs.name
    dataStorageAccountName: dataStorage.outputs.name
    hostStorageAccountName: hostStorage.outputs.name
  }
}

// ---------------------------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------------------------

output resourceGroupName string = rg.outputs.name
output webApiName string = webApi.outputs.name
output webApiHostname string = webApi.outputs.defaultHostname
output functionAppName string = functionApp.outputs.name
output appConfigEndpoint string = appConfig.outputs.endpoint
output keyVaultUri string = keyVault.outputs.uri
output dataStorageAccountName string = dataStorage.outputs.name
output hostStorageAccountName string = hostStorage.outputs.name

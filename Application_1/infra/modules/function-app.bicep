// Windows Function App on the shared (dedicated) App Service Plan with system-assigned identity,
// identity-based host storage (AzureWebJobsStorage__*), VNet integration for outbound traffic,
// and a private endpoint for inbound traffic. Public access is disabled.

@description('Name of the Function App (globally unique).')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the shared App Service Plan.')
param appServicePlanResourceId string

@description('Resource ID of the Function App host (AzureWebJobsStorage) storage account.')
param hostStorageAccountResourceId string

@description('Resource ID of the subnet delegated to Microsoft.Web/serverFarms (VNet integration).')
param vnetIntegrationSubnetResourceId string

@description('Resource ID of the subnet that hosts private endpoint NICs.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.azurewebsites.net private DNS zone.')
param privateDnsZoneResourceId string

@description('Resource ID of Application Insights.')
param appInsightsResourceId string

@description('Endpoint of the App Configuration store the function reads from.')
param appConfigEndpoint string

@description('Blob endpoint of the separate data storage account the function reads/writes.')
param dataStorageBlobEndpoint string

@description('.NET version on Windows for the isolated worker, e.g. v10.0.')
param netFrameworkVersion string = 'v10.0'

@description('FUNCTIONS_WORKER_RUNTIME value matching the runtime stack.')
param functionsWorkerRuntime string = 'dotnet-isolated'

@description('Tags applied to the resource.')
param tags object = {}

module functionApp 'br/public:avm/res/web/site:0.24.0' = {
  name: 'avm-func-${uniqueString(name)}'
  params: {
    name: name
    location: location
    kind: 'functionapp'
    serverFarmResourceId: appServicePlanResourceId
    managedIdentities: {
      systemAssigned: true
    }
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetResourceId: vnetIntegrationSubnetResourceId
    outboundVnetRouting: {
      allTraffic: true
    }
    siteConfig: {
      alwaysOn: true // required on a dedicated plan, otherwise triggers stop firing
      netFrameworkVersion: netFrameworkVersion
      use32BitWorkerProcess: false
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
    }
    basicPublishingCredentialsPolicies: [
      {
        name: 'ftp'
        allow: false
      }
      {
        name: 'scm'
        allow: false
      }
    ]
    configs: [
      {
        name: 'appsettings'
        // Adds AzureWebJobsStorage__accountName / __blobServiceUri / __queueServiceUri / __tableServiceUri
        storageAccountResourceId: hostStorageAccountResourceId
        storageAccountUseIdentityAuthentication: true
        applicationInsightResourceId: appInsightsResourceId
        properties: {
          FUNCTIONS_EXTENSION_VERSION: '~4'
          FUNCTIONS_WORKER_RUNTIME: functionsWorkerRuntime
          AppConfig__Endpoint: appConfigEndpoint
          DataStorage__blobServiceUri: dataStorageBlobEndpoint
        }
      }
    ]
    privateEndpoints: [
      {
        name: 'pe-${name}'
        customNetworkInterfaceName: 'nic-pe-${name}'
        service: 'sites'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: privateDnsZoneResourceId
            }
          ]
        }
        tags: tags
      }
    ]
    tags: tags
  }
}

output name string = functionApp.outputs.name
output resourceId string = functionApp.outputs.resourceId
output defaultHostname string = functionApp.outputs.defaultHostname
output principalId string = functionApp.outputs.?systemAssignedMIPrincipalId ?? ''

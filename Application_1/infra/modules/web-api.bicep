// Windows Web API (App Service) with system-assigned identity, VNet integration for outbound
// traffic, and a private endpoint for inbound traffic. Public access is disabled.

@description('Name of the Web API (globally unique).')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the shared App Service Plan.')
param appServicePlanResourceId string

@description('Resource ID of the subnet delegated to Microsoft.Web/serverFarms (VNet integration).')
param vnetIntegrationSubnetResourceId string

@description('Resource ID of the subnet that hosts private endpoint NICs.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.azurewebsites.net private DNS zone.')
param privateDnsZoneResourceId string

@description('Resource ID of Application Insights.')
param appInsightsResourceId string

@description('Endpoint of the App Configuration store the API reads from.')
param appConfigEndpoint string

@description('Blob endpoint of the data storage account the API reads/writes.')
param dataStorageBlobEndpoint string

@description('.NET version on Windows, e.g. v10.0.')
param netFrameworkVersion string = 'v10.0'

@description('Tags applied to the resource.')
param tags object = {}

module webApi 'br/public:avm/res/web/site:0.24.0' = {
  name: 'avm-app-${uniqueString(name)}'
  params: {
    name: name
    location: location
    kind: 'app'
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
      alwaysOn: true
      netFrameworkVersion: netFrameworkVersion
      use32BitWorkerProcess: false
      metadata: [
        {
          name: 'CURRENT_STACK' // shows .NET as the stack in the portal
          value: 'dotnet'
        }
      ]
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
        applicationInsightResourceId: appInsightsResourceId
        properties: {
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

output name string = webApi.outputs.name
output resourceId string = webApi.outputs.resourceId
output defaultHostname string = webApi.outputs.defaultHostname
output principalId string = webApi.outputs.?systemAssignedMIPrincipalId ?? ''

// App Configuration store: Entra ID auth only, private endpoint, no public access.

@description('Name of the App Configuration store (globally unique).')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the subnet that hosts private endpoint NICs.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.azconfig.io private DNS zone.')
param privateDnsZoneResourceId string

@description('Enable purge protection (recommended outside dev).')
param enablePurgeProtection bool = false

@description('Tags applied to the resource.')
param tags object = {}

module appConfig 'br/public:avm/res/app-configuration/configuration-store:0.10.1' = {
  name: 'avm-appcs-${uniqueString(name)}'
  params: {
    name: name
    location: location
    sku: 'Standard' // private endpoints need Standard or higher
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    enablePurgeProtection: enablePurgeProtection
    // Lets ARM write key-values through the private link later (e.g. via the keyValues param)
    // even though public access and local auth are disabled.
    dataPlaneProxy: {
      authenticationMode: 'Pass-through'
      privateLinkDelegation: 'Enabled'
    }
    privateEndpoints: [
      {
        name: 'pe-${name}'
        customNetworkInterfaceName: 'nic-pe-${name}'
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

output name string = appConfig.outputs.name
output resourceId string = appConfig.outputs.resourceId
output endpoint string = appConfig.outputs.endpoint

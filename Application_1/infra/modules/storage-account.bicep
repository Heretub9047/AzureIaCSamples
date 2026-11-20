// Storage account with Entra ID auth only (shared keys disabled), no public access, and one
// private endpoint + NIC per storage sub-resource (blob, queue, table, file).
// Used twice: Function App host storage and the separate data storage account.

@description('Name of the storage account (3-24 lowercase letters/numbers, globally unique).')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region.')
param location string

@description('Storage SKU.')
param skuName string = 'Standard_LRS'

@description('Resource ID of the subnet that hosts private endpoint NICs.')
param privateEndpointSubnetResourceId string

@description('One entry per sub-resource that needs a private endpoint.')
param privateEndpointServices privateEndpointServiceType[]

@description('Tags applied to the resource.')
param tags object = {}

@description('A storage sub-resource and the private DNS zone its endpoint registers in.')
type privateEndpointServiceType = {
  @description('Sub-resource (group ID).')
  service: ('blob' | 'queue' | 'table' | 'file')

  @description('Resource ID of the matching privatelink.<service>.core.windows.net zone.')
  privateDnsZoneResourceId: string
}

module storage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'avm-st-${uniqueString(name)}'
  params: {
    name: name
    location: location
    kind: 'StorageV2'
    skuName: skuName
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    privateEndpoints: [
      for pe in privateEndpointServices: {
        name: 'pe-${name}-${pe.service}'
        customNetworkInterfaceName: 'nic-pe-${name}-${pe.service}'
        service: pe.service
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: pe.privateDnsZoneResourceId
            }
          ]
        }
        tags: tags
      }
    ]
    tags: tags
  }
}

output name string = storage.outputs.name
output resourceId string = storage.outputs.resourceId
// Not storage.outputs.primaryBlobEndpoint: AVM returns '' for it unless blob containers are declared.
output primaryBlobEndpoint string = storage.outputs.serviceEndpoints.blob

// Key Vault: RBAC authorization, soft delete + purge protection, private endpoint, no public access.

@description('Name of the Key Vault (3-24 characters, globally unique).')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region.')
param location string

@description('Resource ID of the subnet that hosts private endpoint NICs.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.vaultcore.azure.net private DNS zone.')
param privateDnsZoneResourceId string

@description('Soft delete retention in days.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Tags applied to the resource.')
param tags object = {}

module vault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'avm-kv-${uniqueString(name)}'
  params: {
    name: name
    location: location
    sku: 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
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

output name string = vault.outputs.name
output resourceId string = vault.outputs.resourceId
output uri string = vault.outputs.uri

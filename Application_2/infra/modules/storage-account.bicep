// Storage account for Analysis Services backups.
//
// Analysis Services writes backups using a SAS URI (it has no managed identity support for
// backups), so this account needs shared key access and a reachable public endpoint.
// Anonymous blob access stays off. To narrow the firewall, pass the IP range of the Analysis
// Services region in allowedIpRanges (Microsoft's documented "Selected networks" setup).

@description('Name of the storage account (3-24 lowercase letters/numbers, globally unique).')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region.')
param location string

@description('Storage SKU.')
param skuName string = 'Standard_LRS'

@description('Name of the blob container that holds the backups.')
param backupContainerName string

@description('Days to keep deleted blobs recoverable.')
param deleteRetentionDays int = 14

@description('Optional. CIDR ranges allowed through the storage firewall, e.g. the Analysis Services region IP range. Empty = all networks.')
param allowedIpRanges string[] = []

@description('Tags applied to the resource.')
param tags object = {}

module storage 'br/public:avm/res/storage/storage-account:0.33.2' = {
  name: 'avm-st-${uniqueString(name)}'
  params: {
    name: name
    location: location
    kind: 'StorageV2'
    skuName: skuName
    accessTier: 'Cool' // backups are written once and rarely read
    allowSharedKeyAccess: true // required: Analysis Services uses a SAS URI
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: empty(allowedIpRanges) ? 'Allow' : 'Deny'
      bypass: 'AzureServices'
      ipRules: [
        for range in allowedIpRanges: {
          value: range
          action: 'Allow'
        }
      ]
    }
    blobServices: {
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: deleteRetentionDays
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: deleteRetentionDays
      containers: [
        {
          name: backupContainerName
          publicAccess: 'None'
        }
      ]
    }
    tags: tags
  }
}

output name string = storage.outputs.name
output resourceId string = storage.outputs.resourceId

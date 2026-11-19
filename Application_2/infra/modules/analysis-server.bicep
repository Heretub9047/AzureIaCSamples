// Azure Analysis Services server with backups configured to a storage container.
//
// Native resource on purpose: the AVM analysis-services/server module (0.4.0) has no parameters
// for server administrators or the backup container, and defaults to an allow-all firewall.

@description('Server name: lowercase letters and numbers, starting with a letter, 3-63 characters.')
@minLength(3)
@maxLength(63)
param name string

@description('Azure region.')
param location string

@description('SKU, e.g. D1 (development), B1/B2 (basic), S0-S9 (standard).')
param skuName string

@description('Number of query replicas + 1. Standard tier only; keep 1 for other tiers.')
@minValue(1)
@maxValue(8)
param skuCapacity int = 1

@description('Server administrators: user UPNs, "app:<appId>@<tenantId>" or "obj:<groupObjectId>@<tenantId>".')
@minLength(1)
param administrators string[]

@description('Allow connections from the Power BI service.')
param enablePowerBIService bool = true

@description('IPv4 firewall rules. Empty list + Power BI disabled = no public access.')
param firewallRules firewallRuleType[] = []

@description('Name of the existing backup storage account (same resource group).')
param backupStorageAccountName string

@description('Name of the existing backup container.')
param backupContainerName string

@description('Do not set. Used to calculate the backup SAS expiry; each deployment renews it.')
param baseTime string = utcNow('u')

@description('How long the backup SAS stays valid from deployment time (ISO 8601 duration).')
param backupSasValidity string = 'P1Y'

@description('Tags applied to the resource.')
param tags object = {}

@description('An IPv4 firewall rule.')
type firewallRuleType = {
  @description('Rule name.')
  firewallRuleName: string

  @description('First IP address in the range.')
  rangeStart: string

  @description('Last IP address in the range.')
  rangeEnd: string
}

var skuTier = startsWith(skuName, 'D') ? 'Development' : startsWith(skuName, 'B') ? 'Basic' : 'Standard'

resource backupStorage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: backupStorageAccountName
}

// Container-scoped service SAS that Analysis Services uses to write backups.
var backupSas = backupStorage.listServiceSas('2024-01-01', {
  canonicalizedResource: '/blob/${backupStorageAccountName}/${backupContainerName}'
  signedResource: 'c'
  signedPermission: 'rwdl'
  signedProtocol: 'https'
  signedExpiry: dateTimeAdd(baseTime, backupSasValidity)
}).serviceSasToken

resource server 'Microsoft.AnalysisServices/servers@2017-08-01' = {
  name: name
  location: location
  sku: {
    name: skuName
    tier: skuTier
    capacity: skuCapacity
  }
  properties: {
    asAdministrators: {
      members: administrators
    }
    ipV4FirewallSettings: {
      enablePowerBIService: enablePowerBIService
      firewallRules: firewallRules
    }
    backupBlobContainerUri: '${backupStorage.properties.primaryEndpoints.blob}${backupContainerName}?${backupSas}'
  }
  tags: tags
}

output name string = server.name
output resourceId string = server.id
output serverFullName string = server.properties.serverFullName

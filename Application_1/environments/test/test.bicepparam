using '../../infra/main.bicep'

// TODO: replace every <placeholder> with real values before the first run.

param appName = 'app1'
param environmentName = 'test'
param location = 'australiaeast'
param locationShort = 'aue'

param tags = {
  owner: '<team-name>'
  costCentre: '<cost-centre>'
}

// Existing VNet in another resource group (can be another subscription)
param existingVnet = {
  subscriptionId: '<test-network-subscription-id>'
  resourceGroupName: '<rg-network-test>'
  name: '<vnet-test>'
}

param privateEndpointSubnet = {
  name: 'snet-app1-pe-test'
  addressPrefix: '10.20.1.0/27'
  // Keep these here if policy requires them - a subnet redeploy removes anything not declared.
  // networkSecurityGroupResourceId: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/networkSecurityGroups/<nsg>'
  // routeTableResourceId: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<rt>'
}

param vnetIntegrationSubnet = {
  name: 'snet-app1-int-test'
  addressPrefix: '10.20.1.64/26'
}

param logAnalyticsWorkspaceResourceId = '/subscriptions/<mgmt-subscription-id>/resourceGroups/<rg-monitoring>/providers/Microsoft.OperationalInsights/workspaces/<law-name>'

// Existing central privatelink DNS zones
var dnsZoneRg = '/subscriptions/<connectivity-subscription-id>/resourceGroups/<rg-private-dns>/providers/Microsoft.Network/privateDnsZones'
param privateDnsZoneIds = {
  blob: '${dnsZoneRg}/privatelink.blob.core.windows.net'
  queue: '${dnsZoneRg}/privatelink.queue.core.windows.net'
  table: '${dnsZoneRg}/privatelink.table.core.windows.net'
  keyVault: '${dnsZoneRg}/privatelink.vaultcore.azure.net'
  webApps: '${dnsZoneRg}/privatelink.azurewebsites.net'
  appConfiguration: '${dnsZoneRg}/privatelink.azconfig.io'
}

param appServicePlanSku = 'P1v3'
param appServicePlanCapacity = 1
param appServicePlanZoneRedundant = false

param webApiLinuxFxVersion = 'DOTNETCORE|10.0'
param functionLinuxFxVersion = 'DOTNET-ISOLATED|10.0'
param functionsWorkerRuntime = 'dotnet-isolated'

param appConfigPurgeProtection = true

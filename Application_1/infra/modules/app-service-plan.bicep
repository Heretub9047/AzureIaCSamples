// Windows App Service Plan shared by the Web API and the Function App.

@description('Name of the App Service Plan.')
param name string

@description('Azure region.')
param location string

@description('SKU name, e.g. P0v3, P1v3.')
param skuName string = 'P0v3'

@description('Number of instances.')
param skuCapacity int = 1

@description('Zone redundancy. Needs at least 2-3 instances depending on region; off for dev/test.')
param zoneRedundant bool = false

@description('Tags applied to the resource.')
param tags object = {}

module plan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'avm-asp-${uniqueString(name)}'
  params: {
    name: name
    location: location
    kind: 'windows'
    reserved: false // true only for Linux plans
    skuName: skuName
    skuCapacity: skuCapacity
    zoneRedundant: zoneRedundant
    tags: tags
  }
}

output name string = plan.outputs.name
output resourceId string = plan.outputs.resourceId

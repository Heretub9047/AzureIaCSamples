// Resource group for the application (deployed at subscription scope).
targetScope = 'subscription'

@description('Name of the resource group.')
param name string

@description('Azure region for the resource group.')
param location string

@description('Tags applied to the resource group.')
param tags object = {}

module resourceGroup 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'avm-rg-${uniqueString(name)}'
  params: {
    name: name
    location: location
    tags: tags
  }
}

output name string = resourceGroup.outputs.name
output resourceId string = resourceGroup.outputs.resourceId

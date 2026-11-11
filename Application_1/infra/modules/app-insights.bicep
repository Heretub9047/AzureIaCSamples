// Workspace-based Application Insights linked to an existing (central) Log Analytics workspace.

@description('Name of the Application Insights component.')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the existing Log Analytics workspace.')
param logAnalyticsWorkspaceResourceId string

@description('Tags applied to the resource.')
param tags object = {}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'avm-appi-${uniqueString(name)}'
  params: {
    name: name
    location: location
    kind: 'web'
    applicationType: 'web'
    workspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: tags
  }
}

output name string = appInsights.outputs.name
output resourceId string = appInsights.outputs.resourceId

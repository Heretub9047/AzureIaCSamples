// RBAC between the Automation Account and the Analysis Services server.
// Runs after the main resources because the system-assigned identity only exists once the
// Automation Account has been created.

@description('Principal ID of the Automation Account system-assigned identity.')
param automationAccountPrincipalId string

@description('Name of the Analysis Services server.')
param analysisServerName string

// Built-in role definition IDs
var roles = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
}

resource analysisServer 'Microsoft.AnalysisServices/servers@2017-08-01' existing = {
  name: analysisServerName
}

// Automation Account -> Analysis Services server: suspend and resume (scoped to this server only)
resource automationAasContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(analysisServer.id, automationAccountPrincipalId, roles.contributor)
  scope: analysisServer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.contributor)
    principalId: automationAccountPrincipalId
    principalType: 'ServicePrincipal'
  }
}

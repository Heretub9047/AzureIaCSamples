targetScope = 'subscription'

param policyDefinitionName string

param policydisplayName string

param description string = ''

param policyMode string = 'Indexed'

param metadata string

param policyParameters string

param policyRule string



resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: policyDefinitionName
  properties: {
    policyType: 'Custom'
    displayName: policydisplayName
    description: description
    mode: policyMode
    metadata: json(metadata)
    policyRule: json(policyRule)
    parameters: json(policyParameters)
  }
}

output policyDefinitionId string = policyDefinition.id
output policyDefinitionNameOutput string = policyDefinition.name

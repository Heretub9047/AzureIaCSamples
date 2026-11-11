// Adds ONE subnet to an existing virtual network that lives in another resource group.
//
// Native resource on purpose: the AVM virtual-network module manages the WHOLE VNet and would
// try to reconcile (and potentially remove) subnets owned by other teams. This module only
// touches the subnet it declares.
//
// WARNING: a subnet deployment replaces the subnet's full definition. Anything not declared here
// (NSG, route table, delegation, service endpoints) is removed on redeploy, so keep this module
// as the single source of truth for the subnet.

@description('Name of the existing virtual network.')
param vnetName string

@description('Name of the subnet to create or update.')
param subnetName string

@description('Address prefix for the subnet, e.g. 10.10.1.0/27.')
param addressPrefix string

@description('Optional. Resource ID of a network security group to associate.')
param networkSecurityGroupResourceId string = ''

@description('Optional. Resource ID of a route table to associate.')
param routeTableResourceId string = ''

@description('Optional. Service to delegate the subnet to, e.g. Microsoft.Web/serverFarms.')
param delegationServiceName string = ''

@description('Whether network policies (NSG/UDR) apply to private endpoints in this subnet.')
@allowed([
  'Disabled'
  'Enabled'
  'NetworkSecurityGroupEnabled'
  'RouteTableEnabled'
])
param privateEndpointNetworkPolicies string = 'Disabled'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: addressPrefix
    networkSecurityGroup: empty(networkSecurityGroupResourceId) ? null : {
      id: networkSecurityGroupResourceId
    }
    routeTable: empty(routeTableResourceId) ? null : {
      id: routeTableResourceId
    }
    delegations: empty(delegationServiceName) ? [] : [
      {
        name: 'delegation'
        properties: {
          serviceName: delegationServiceName
        }
      }
    ]
    privateEndpointNetworkPolicies: privateEndpointNetworkPolicies
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

output name string = subnet.name
output resourceId string = subnet.id

// Application_2 orchestrator.
// Deployed at subscription scope so it can create the resource group, then:
//   1. resource group
//   2. backup storage account, Analysis Services server
//   3. Automation Account (+ server variable and, outside prod, the 6PM pause schedule),
//      PowerShell 7.4 runtime environment and the two runbooks
//   4. RBAC: Automation Account identity -> Analysis Services server
// Runbook script content is published by the pipeline after this deployment.
targetScope = 'subscription'

// ---------------------------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------------------------

@description('An Analysis Services IPv4 firewall rule.')
type firewallRuleType = {
  @description('Rule name.')
  firewallRuleName: string

  @description('First IP address in the range.')
  rangeStart: string

  @description('Last IP address in the range.')
  rangeEnd: string
}

// ---------------------------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------------------------

@description('Short application name used in resource names: lowercase letters and numbers only, e.g. app2.')
@maxLength(8)
param appName string

@description('Environment name.')
@allowed([
  'dev'
  'test'
  'uat'
  'prod'
])
param environmentName string

@description('Azure region for all resources.')
param location string

@description('Short region code used in resource names, e.g. aue.')
param locationShort string

@description('Tags applied to every resource.')
param tags object = {}

@description('Analysis Services SKU, e.g. D1, B1, S0, S1.')
param analysisServerSku string

@description('Analysis Services instance count (query replicas + 1). Standard tier only.')
param analysisServerCapacity int = 1

@description('Analysis Services administrators: UPNs, "app:<appId>@<tenantId>" or "obj:<groupObjectId>@<tenantId>".')
param analysisServerAdministrators string[]

@description('Allow the Power BI service through the Analysis Services firewall.')
param analysisServerEnablePowerBI bool = true

@description('Analysis Services IPv4 firewall rules.')
param analysisServerFirewallRules firewallRuleType[] = []

@description('Optional. CIDR ranges allowed through the backup storage firewall, e.g. the Analysis Services region IP range. Empty = all networks.')
param backupStorageAllowedIpRanges string[] = []

@description('Create the daily 6PM pause schedule. False in production, which runs 24/7.')
param enablePauseSchedule bool = environmentName != 'prod'

@description('First run of the pause schedule: ISO 8601 with UTC offset, e.g. 2026-11-20T18:00:00+11:00. The pipeline calculates it.')
param pauseScheduleStartTime string = ''

@description('Time zone the pause schedule keeps 6PM in.')
param pauseScheduleTimeZone string = 'Australia/Sydney'

// ---------------------------------------------------------------------------------------------
// Naming (CAF abbreviations). Globally unique names get a short deterministic suffix.
// ---------------------------------------------------------------------------------------------

var resourceGroupName = 'rg-${appName}-${environmentName}-${locationShort}'
var suffix = take(uniqueString(subscription().id, resourceGroupName), 5)
var baseName = '${appName}-${environmentName}-${locationShort}'

var names = {
  analysisServer: toLower('aas${appName}${environmentName}${suffix}')
  backupStorage: take(toLower('st${appName}bak${environmentName}${suffix}'), 24)
  backupContainer: 'aas-backups'
  automationAccount: 'aa-${baseName}'
  serverVariable: 'AnalysisServerResourceId'
  pauseRunbook: 'Suspend-AnalysisServer' // must match runbooks/<name>.ps1
  startRunbook: 'Resume-AnalysisServer' // must match runbooks/<name>.ps1
  pauseSchedule: 'Daily-6PM-Pause'
}

var allTags = union(tags, {
  application: appName
  environment: environmentName
})

// ---------------------------------------------------------------------------------------------
// 1. Resource group
// ---------------------------------------------------------------------------------------------

module rg 'modules/resource-group.bicep' = {
  name: 'rg-${baseName}'
  params: {
    name: resourceGroupName
    location: location
    tags: allTags
  }
}

// ---------------------------------------------------------------------------------------------
// 2. Backup storage + Analysis Services
// ---------------------------------------------------------------------------------------------

module backupStorage 'modules/storage-account.bicep' = {
  name: 'st-bak-${baseName}'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: names.backupStorage
    location: location
    backupContainerName: names.backupContainer
    allowedIpRanges: backupStorageAllowedIpRanges
    tags: allTags
  }
}

module analysisServer 'modules/analysis-server.bicep' = {
  name: 'aas-${baseName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: names.analysisServer
    location: location
    skuName: analysisServerSku
    skuCapacity: analysisServerCapacity
    administrators: analysisServerAdministrators
    enablePowerBIService: analysisServerEnablePowerBI
    firewallRules: analysisServerFirewallRules
    backupStorageAccountName: backupStorage.outputs.name // also orders this after the storage account
    backupContainerName: names.backupContainer
    tags: allTags
  }
}

// ---------------------------------------------------------------------------------------------
// 3. Automation Account and runbooks
// ---------------------------------------------------------------------------------------------

module automationAccount 'modules/automation-account.bicep' = {
  name: 'aa-${baseName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: names.automationAccount
    location: location
    analysisServerResourceId: analysisServer.outputs.resourceId
    serverVariableName: names.serverVariable
    enablePauseSchedule: enablePauseSchedule
    pauseScheduleName: names.pauseSchedule
    pauseScheduleStartTime: pauseScheduleStartTime
    pauseScheduleTimeZone: pauseScheduleTimeZone
    tags: allTags
  }
}

module runbooks 'modules/automation-runbooks.bicep' = {
  name: 'aa-runbooks-${baseName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    automationAccountName: automationAccount.outputs.name
    location: location
    pauseRunbookName: names.pauseRunbook
    startRunbookName: names.startRunbook
    tags: allTags
  }
}

// ---------------------------------------------------------------------------------------------
// 4. RBAC
// ---------------------------------------------------------------------------------------------

module roleAssignments 'modules/role-assignments.bicep' = {
  name: 'rbac-${baseName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    automationAccountPrincipalId: automationAccount.outputs.principalId
    analysisServerName: analysisServer.outputs.name
  }
}

// ---------------------------------------------------------------------------------------------
// Outputs (the runbook publish script reads these)
// ---------------------------------------------------------------------------------------------

output resourceGroupName string = rg.outputs.name
output analysisServerName string = analysisServer.outputs.name
output analysisServerFullName string = analysisServer.outputs.serverFullName
output backupStorageAccountName string = backupStorage.outputs.name
output automationAccountName string = automationAccount.outputs.name
output pauseRunbookName string = runbooks.outputs.pauseRunbookName
output startRunbookName string = runbooks.outputs.startRunbookName
output pauseScheduleName string = enablePauseSchedule ? names.pauseSchedule : ''

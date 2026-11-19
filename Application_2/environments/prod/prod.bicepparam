using '../../infra/main.bicep'

// TODO: replace every <placeholder> with real values before the first run.

param appName = 'app2'
param environmentName = 'prod'
param location = 'australiaeast'
param locationShort = 'aue'

param tags = {
  owner: '<team-name>'
  costCentre: '<cost-centre>'
}

// Analysis Services
param analysisServerSku = 'S1'
param analysisServerCapacity = 1
param analysisServerAdministrators = [
  // UPN, 'obj:<groupObjectId>@<tenantId>' (Entra group) or 'app:<appId>@<tenantId>' (service principal)
  'obj:<prod-aas-admins-group-object-id>@<tenant-id>'
]
param analysisServerEnablePowerBI = true
param analysisServerFirewallRules = [
  // {
  //   firewallRuleName: 'corp-network'
  //   rangeStart: '203.0.113.0'
  //   rangeEnd: '203.0.113.255'
  // }
]

// Backup storage firewall: empty = all networks. To restrict, add the Analysis Services region IP range.
param backupStorageAllowedIpRanges = []

// Production runs 24/7: no pause schedule. The start runbook is still deployed for ad-hoc use.
param enablePauseSchedule = false

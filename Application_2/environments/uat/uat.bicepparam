using '../../infra/main.bicep'

// TODO: replace every <placeholder> with real values before the first run.

param appName = 'app2'
param environmentName = 'uat'
param location = 'australiaeast'
param locationShort = 'aue'

param tags = {
  owner: '<team-name>'
  costCentre: '<cost-centre>'
}

// Analysis Services
param analysisServerSku = 'S0'
param analysisServerCapacity = 1
param analysisServerAdministrators = [
  // UPN, 'obj:<groupObjectId>@<tenantId>' (Entra group) or 'app:<appId>@<tenantId>' (service principal)
  'obj:<uat-aas-admins-group-object-id>@<tenant-id>'
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

// Daily 6PM pause (non-production). The pipeline sets PAUSE_SCHEDULE_START to the next 6PM in
// Australia/Sydney with the correct UTC offset, e.g. 2026-11-20T18:00:00+11:00.
// Running locally (Linux/WSL, GNU date):
//   export PAUSE_SCHEDULE_START=$(TZ=Australia/Sydney date -d "$(TZ=Australia/Sydney date -d '+1 day' +%F) 18:00" +%Y-%m-%dT%H:%M:%S%:z)
param enablePauseSchedule = true
param pauseScheduleStartTime = readEnvironmentVariable('PAUSE_SCHEDULE_START')
param pauseScheduleTimeZone = 'Australia/Sydney'

// Automation Account with a system-assigned identity, the Automation variable the runbooks read
// to find the server, and (non-production only) the daily pause schedule.

@description('Name of the Automation Account.')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the Analysis Services server the runbooks act on.')
param analysisServerResourceId string

@description('Name of the Automation variable that holds the server resource ID.')
param serverVariableName string

@description('Create the daily pause schedule (false in production).')
param enablePauseSchedule bool

@description('Name of the pause schedule.')
param pauseScheduleName string

@description('First run of the pause schedule: ISO 8601 with UTC offset, at least 5 minutes in the future.')
param pauseScheduleStartTime string

@description('Time zone the schedule keeps its time of day in, e.g. Australia/Sydney.')
param pauseScheduleTimeZone string

@description('Tags applied to the resource.')
param tags object = {}

module automationAccount 'br/public:avm/res/automation/automation-account:0.19.4' = {
  name: 'avm-aa-${uniqueString(name)}'
  params: {
    name: name
    location: location
    skuName: 'Basic'
    disableLocalAuth: true
    managedIdentities: {
      systemAssigned: true
    }
    variables: [
      {
        name: serverVariableName
        description: 'Resource ID of the Analysis Services server the runbooks pause and start.'
        value: '"${analysisServerResourceId}"' // Automation variable values are JSON-encoded
        isEncrypted: false
      }
    ]
    schedules: enablePauseSchedule
      ? [
          {
            name: pauseScheduleName
            description: 'Pauses the Analysis Services server every day at 6PM.'
            frequency: 'Day'
            interval: 1
            startTime: pauseScheduleStartTime
            timeZone: pauseScheduleTimeZone
          }
        ]
      : []
    tags: tags
  }
}

output name string = automationAccount.outputs.name
output resourceId string = automationAccount.outputs.resourceId
output principalId string = automationAccount.outputs.?systemAssignedMIPrincipalId ?? ''

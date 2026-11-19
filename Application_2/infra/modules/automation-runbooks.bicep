// PowerShell 7.4 runtime environment and the two runbooks (pause and start).
//
// Native resources on purpose: the AVM automation-account module (0.19.4) can only create
// runbooks on the legacy runtimes (PowerShell72 etc.), not on a PowerShell 7.4 runtime
// environment. PowerShell 7.1/7.2 are out of support.
//
// ARM can't hold runbook script content inline, so these runbooks are created empty. The
// pipeline then uploads and publishes runbooks/<name>.ps1 and links the pause schedule
// (pipelines/scripts/publish-runbooks.sh).

@description('Name of the existing Automation Account.')
param automationAccountName string

@description('Azure region.')
param location string

@description('Name of the runtime environment (letters, numbers, - and _ only).')
param runtimeEnvironmentName string = 'PowerShell-74'

@description('Version of the default Az PowerShell package in the runtime environment.')
param azPackageVersion string = '12.3.0'

@description('Name of the runbook that pauses the server.')
param pauseRunbookName string

@description('Name of the runbook that starts the server.')
param startRunbookName string

@description('Tags applied to the runbooks.')
param tags object = {}

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
}

resource runtimeEnvironment 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automationAccount
  name: runtimeEnvironmentName
  location: location
  properties: {
    description: 'PowerShell 7.4 with the default Az package.'
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
    defaultPackages: {
      Az: azPackageVersion
    }
  }
}

resource pauseRunbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: automationAccount
  name: pauseRunbookName
  location: location
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtimeEnvironment.name
    description: 'Pauses (suspends) the Analysis Services server. Runs daily at 6PM outside production.'
    logProgress: false
    logVerbose: false
  }
  tags: tags
}

resource startRunbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: automationAccount
  name: startRunbookName
  location: location
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtimeEnvironment.name
    description: 'Starts (resumes) the Analysis Services server. Run ad hoc.'
    logProgress: false
    logVerbose: false
  }
  tags: tags
}

output pauseRunbookName string = pauseRunbook.name
output startRunbookName string = startRunbook.name

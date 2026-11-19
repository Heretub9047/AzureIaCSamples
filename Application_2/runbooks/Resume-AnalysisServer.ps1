<#
.SYNOPSIS
    Starts (resumes) an Azure Analysis Services server.

.DESCRIPTION
    Runs in Azure Automation (PowerShell 7.4 runtime environment) as the Automation Account's
    system-assigned managed identity. Not scheduled: start it ad hoc from the portal, CLI or
    PowerShell (Start-AzAutomationRunbook).

    Uses the Analysis Services REST API through Invoke-AzRestMethod, so it only needs
    Az.Accounts (part of the default Az package) and no extra modules.

    The identity needs Contributor on the server (granted by infra/modules/role-assignments.bicep).

.PARAMETER ServerResourceId
    Resource ID of the server. Defaults to the 'AnalysisServerResourceId' Automation variable.

.PARAMETER TimeoutMinutes
    How long to wait for the server to reach the Succeeded (running) state.
#>
param(
    [string] $ServerResourceId,
    [int] $TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2017-08-01'

if (-not $ServerResourceId) {
    $ServerResourceId = Get-AutomationVariable -Name 'AnalysisServerResourceId'
}
if (-not $ServerResourceId) {
    throw 'No server resource ID passed and the AnalysisServerResourceId Automation variable is empty.'
}

Connect-AzAccount -Identity | Out-Null

function Get-ServerState {
    $response = Invoke-AzRestMethod -Method GET -Path "${ServerResourceId}?api-version=$apiVersion"
    if ($response.StatusCode -ne 200) {
        throw "Failed to read server '$ServerResourceId' (HTTP $($response.StatusCode)): $($response.Content)"
    }
    return ($response.Content | ConvertFrom-Json).properties.state
}

$state = Get-ServerState
Write-Output "Server '$ServerResourceId' is currently '$state'."

switch ($state) {
    'Succeeded' {
        Write-Output 'Server is already running. Nothing to do.'
        return
    }
    'Resuming' {
        Write-Output 'Server is already resuming. Waiting for it to finish.'
    }
    { $_ -in 'Paused', 'Suspended' } {
        $response = Invoke-AzRestMethod -Method POST -Path "${ServerResourceId}/resume?api-version=$apiVersion"
        if ($response.StatusCode -notin 200, 202) {
            throw "Resume request failed (HTTP $($response.StatusCode)): $($response.Content)"
        }
        Write-Output 'Resume requested.'
    }
    default {
        throw "Server is in state '$state' and can't be started right now."
    }
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds 15
    $state = Get-ServerState
    Write-Output "State: $state"
} while (($state -ne 'Succeeded') -and ((Get-Date) -lt $deadline))

if ($state -ne 'Succeeded') {
    throw "Server did not reach 'Succeeded' within $TimeoutMinutes minutes (last state: '$state')."
}

Write-Output 'Server started.'

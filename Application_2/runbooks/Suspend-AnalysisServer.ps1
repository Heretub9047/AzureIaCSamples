<#
.SYNOPSIS
    Pauses (suspends) an Azure Analysis Services server.

.DESCRIPTION
    Runs in Azure Automation (PowerShell 7.4 runtime environment) as the Automation Account's
    system-assigned managed identity. Linked to the daily 6PM schedule in every environment
    except production.

    Uses the Analysis Services REST API through Invoke-AzRestMethod, so it only needs
    Az.Accounts (part of the default Az package) and no extra modules.

    The identity needs Contributor on the server (granted by infra/modules/role-assignments.bicep).

.PARAMETER ServerResourceId
    Resource ID of the server. Defaults to the 'AnalysisServerResourceId' Automation variable.

.PARAMETER TimeoutMinutes
    How long to wait for the server to reach the Paused state.
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
    { $_ -in 'Paused', 'Suspended' } {
        Write-Output 'Server is already paused. Nothing to do.'
        return
    }
    { $_ -in 'Pausing', 'Suspending' } {
        Write-Output 'Server is already pausing. Waiting for it to finish.'
    }
    'Succeeded' {
        $response = Invoke-AzRestMethod -Method POST -Path "${ServerResourceId}/suspend?api-version=$apiVersion"
        if ($response.StatusCode -notin 200, 202) {
            throw "Suspend request failed (HTTP $($response.StatusCode)): $($response.Content)"
        }
        Write-Output 'Suspend requested.'
    }
    default {
        throw "Server is in state '$state' and can't be paused right now."
    }
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds 15
    $state = Get-ServerState
    Write-Output "State: $state"
} while (($state -notin 'Paused', 'Suspended') -and ((Get-Date) -lt $deadline))

if ($state -notin 'Paused', 'Suspended') {
    throw "Server did not reach 'Paused' within $TimeoutMinutes minutes (last state: '$state')."
}

Write-Output 'Server paused.'

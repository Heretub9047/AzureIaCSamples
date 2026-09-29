#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Removes Azure RBAC role assignments listed in a CSV file.

.DESCRIPTION
    Works at resource, resource group, subscription and management group scope.

    Expected CSV columns:
        SubscriptionName, SubscriptionId, PrincipleDisplayName, SigninName,
        ObjectID, RoleDefinitionName, AssignmentScope, RoleAssignmentId

    For each row the script:
      1. Switches subscription context when needed (skipped for management group scopes).
      2. Looks up the live assignment at AssignmentScope, matching on RoleAssignmentId
         (full ID or bare GUID). If RoleAssignmentId is blank it falls back to
         ObjectID + RoleDefinitionName + AssignmentScope.
      3. Skips assignments that are only INHERITED at that scope (they must be removed
         where they are actually assigned) and ones that no longer exist.
      4. Asks for confirmation (Yes / Yes to all / No / Quit) unless -Force is used,
         then removes the assignment.
      5. Writes every outcome to a results CSV log.

.PARAMETER CsvPath
    Path to the input CSV.

.PARAMETER TenantId
    Optional tenant to connect to if you are not already signed in.

.PARAMETER LogPath
    Optional path for the results log. Defaults to a timestamped CSV next to the input file.

.PARAMETER Force
    Skips the confirmation prompt and removes every matching assignment.

.EXAMPLE
    # Prompts before each removal
    .\Remove-AzRoleAssignmentsFromCsv.ps1 -CsvPath .\assignments.csv

.EXAMPLE
    # No prompts
    .\Remove-AzRoleAssignmentsFromCsv.ps1 -CsvPath .\assignments.csv -TenantId <tenant-guid> -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$TenantId,

    [string]$LogPath,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers
function Get-AssignmentGuid {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    return ($Id.Trim().TrimEnd('/') -split '/')[-1].ToLowerInvariant()
}

function Test-IsManagementGroupScope {
    param([string]$Scope)
    return $Scope -match '^/providers/Microsoft\.Management/managementGroups/'
}

function Get-SubscriptionIdFromScope {
    param([string]$Scope)
    if ($Scope -match '^/subscriptions/([0-9a-fA-F-]{36})') { return $Matches[1] }
    return $null
}

function New-ResultRecord {
    param($Row, [string]$Status, [string]$Message)
    [pscustomobject]@{
        Timestamp            = (Get-Date).ToString('s')
        Status               = $Status
        Message              = $Message
        SubscriptionName     = $Row.SubscriptionName
        SubscriptionId       = $Row.SubscriptionId
        PrincipleDisplayName = $Row.PrincipleDisplayName
        SigninName           = $Row.SigninName
        ObjectID             = $Row.ObjectID
        RoleDefinitionName   = $Row.RoleDefinitionName
        AssignmentScope      = $Row.AssignmentScope
        RoleAssignmentId     = $Row.RoleAssignmentId
    }
}
#endregion

#region Input
$resolvedCsv = (Resolve-Path -Path $CsvPath).Path
if (-not $LogPath) {
    $LogPath = Join-Path -Path (Split-Path -Path $resolvedCsv -Parent) `
                        -ChildPath ("RoleAssignmentRemoval_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

$rows = @(Import-Csv -Path $resolvedCsv)
if ($rows.Count -eq 0) { throw "CSV '$resolvedCsv' contains no rows." }

$required = 'SubscriptionId', 'ObjectID', 'RoleDefinitionName', 'AssignmentScope', 'RoleAssignmentId'
$columns  = $rows[0].PSObject.Properties.Name
$missing  = $required | Where-Object { $_ -notin $columns }
if ($missing) { throw "CSV is missing required column(s): $($missing -join ', ')" }

# De-duplicate on assignment ID (or principal+role+scope when ID is blank)
$rows = $rows | Group-Object -Property {
    $g = Get-AssignmentGuid $_.RoleAssignmentId
    if ($g) { $g } else { "{0}|{1}|{2}" -f $_.ObjectID, $_.RoleDefinitionName, $_.AssignmentScope }
} | ForEach-Object { $_.Group[0] }

Write-Host "Loaded $(@($rows).Count) unique assignment(s) from $resolvedCsv" -ForegroundColor Cyan
#endregion

#region Connect
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context -or ($TenantId -and $context.Tenant.Id -ne $TenantId)) {
    $connectParams = @{}
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-AzAccount @connectParams | Out-Null
    $context = Get-AzContext
}
Write-Host "Signed in as $($context.Account.Id) (tenant $($context.Tenant.Id))" -ForegroundColor Cyan
$currentSubId = if ($context.Subscription) { $context.Subscription.Id } else { $null }
#endregion

#region Process
$results = New-Object System.Collections.Generic.List[object]
$i = 0
$total = @($rows).Count
$confirmAll = $Force.IsPresent
$quit = $false

foreach ($row in $rows) {
    if ($quit) {
        $results.Add((New-ResultRecord $row 'Aborted' 'Run stopped by user'))
        continue
    }
    $i++
    $scope = "$($row.AssignmentScope)".Trim().TrimEnd('/')
    $label = "{0} | {1} | {2}" -f $(if ($row.PrincipleDisplayName) { $row.PrincipleDisplayName } else { $row.ObjectID }),
                                  $row.RoleDefinitionName, $scope
    Write-Progress -Activity 'Removing role assignments' -Status $label -PercentComplete (($i / $total) * 100)

    try {
        if ([string]::IsNullOrWhiteSpace($scope)) {
            $results.Add((New-ResultRecord $row 'Skipped' 'AssignmentScope is empty')); continue
        }

        # Switch subscription context for subscription / RG / resource scopes
        if (-not (Test-IsManagementGroupScope $scope)) {
            $subId = if ($row.SubscriptionId) { "$($row.SubscriptionId)".Trim() } else { Get-SubscriptionIdFromScope $scope }
            if (-not $subId) {
                $results.Add((New-ResultRecord $row 'Skipped' 'Could not determine SubscriptionId')); continue
            }
            if ($subId -ne $currentSubId) {
                Set-AzContext -Subscription $subId -WarningAction SilentlyContinue | Out-Null
                $currentSubId = $subId
            }
        }

        # Find the live assignment(s) visible at this scope
        $candidates = @(Get-AzRoleAssignment -Scope $scope -WarningAction SilentlyContinue)
        $targetGuid = Get-AssignmentGuid $row.RoleAssignmentId

        if ($targetGuid) {
            $match = @($candidates | Where-Object { (Get-AssignmentGuid $_.RoleAssignmentId) -eq $targetGuid })
        }
        else {
            $match = @($candidates | Where-Object {
                $_.ObjectId -eq $row.ObjectID -and $_.RoleDefinitionName -eq $row.RoleDefinitionName
            })
        }

        if ($match.Count -eq 0) {
            $results.Add((New-ResultRecord $row 'NotFound' 'Assignment not found (may already be removed)'))
            Write-Host "  [NotFound] $label" -ForegroundColor DarkYellow
            continue
        }

        # Only remove assignments made directly at this scope, not inherited ones
        $direct = @($match | Where-Object { $_.Scope.TrimEnd('/') -eq $scope })
        if ($direct.Count -eq 0) {
            $actual = ($match | Select-Object -ExpandProperty Scope -Unique) -join '; '
            $results.Add((New-ResultRecord $row 'Inherited' "Assignment is inherited from: $actual"))
            Write-Host "  [Inherited] $label (assigned at $actual)" -ForegroundColor DarkYellow
            continue
        }

        foreach ($ra in $direct) {
            if ($quit) { break }

            if (-not $confirmAll) {
                $prompt = "Remove '{0}' for {1} [{2}] at {3}?`n[Y] Yes  [A] Yes to all  [N] No  [Q] Quit" -f `
                          $ra.RoleDefinitionName, $ra.DisplayName, $ra.ObjectId, $ra.Scope
                $answer = "$(Read-Host $prompt)".Trim().ToUpperInvariant()

                switch ($answer) {
                    'Y' { }
                    'A' { $confirmAll = $true }
                    'Q' { $quit = $true }
                    default { $answer = 'N' }
                }

                if ($quit) {
                    $results.Add((New-ResultRecord $row 'Aborted' 'Run stopped by user'))
                    break
                }
                if ($answer -eq 'N') {
                    $results.Add((New-ResultRecord $row 'Declined' 'Removal not confirmed'))
                    Write-Host "  [Declined] $label" -ForegroundColor DarkYellow
                    continue
                }
            }

            Remove-AzRoleAssignment -InputObject $ra -ErrorAction Stop | Out-Null
            $results.Add((New-ResultRecord $row 'Removed' "Removed $($ra.RoleAssignmentId)"))
            Write-Host "  [Removed] $label" -ForegroundColor Green
        }
    }
    catch {
        $results.Add((New-ResultRecord $row 'Failed' $_.Exception.Message))
        Write-Host "  [Failed] $label : $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Progress -Activity 'Removing role assignments' -Completed
#endregion

#region Output
$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
$results | Group-Object Status | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.Name, $_.Count) }
Write-Host "Log written to: $LogPath" -ForegroundColor Cyan

if ($results.Status -contains 'Failed') { exit 1 }
#endregion

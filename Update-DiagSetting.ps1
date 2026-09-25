#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Repoints Azure diagnostic settings from their current Log Analytics workspace to a new one,
    leaving storage account / event hub / partner destinations and log/metric categories untouched.

.DESCRIPTION
    For each resource ID supplied (any subscription in the current tenant):
      1. Reads all diagnostic settings on the resource via ARM REST
      2. Builds and displays a plan: current workspace -> new workspace, plus the storage account being kept
      3. Asks for confirmation (unless -Force), then PUTs each setting back with ONLY workspaceId changed
      4. Re-reads each setting to verify the workspace changed and storage account / event hub did not
      5. Prints a colour-coded results summary and exports a CSV report

    Settings that have no Log Analytics destination (e.g. storage-only) are skipped, not modified.

.PARAMETER ResourceIdFile
    .txt file (one resource ID per line; blank lines and lines starting with # are ignored)
    or .csv file with a 'ResourceId' column.

.PARAMETER ResourceId
    Alternatively, pass resource IDs directly as an array.

.PARAMETER NewWorkspaceId
    Full resource ID of the target Log Analytics workspace.

.PARAMETER DiagnosticSettingName
    Optional. Only update diagnostic settings with this name.

.PARAMETER OldWorkspaceId
    Optional. Only update settings currently pointing at this specific workspace.

.PARAMETER Force
    Skip the interactive confirmation prompt.

.PARAMETER ReportPath
    Where to write the CSV report.

.EXAMPLE
    # Dry run - shows the plan, changes nothing
    .\Update-DiagSettingWorkspace.ps1 -ResourceIdFile .\resources.txt `
        -NewWorkspaceId "/subscriptions/<sub>/resourceGroups/rg-logs/providers/Microsoft.OperationalInsights/workspaces/law-new" -WhatIf

.EXAMPLE
    # Real run, only settings currently on the old workspace
    .\Update-DiagSettingWorkspace.ps1 -ResourceIdFile .\resources.txt `
        -NewWorkspaceId "/subscriptions/<sub>/resourceGroups/rg-logs/providers/Microsoft.OperationalInsights/workspaces/law-new" `
        -OldWorkspaceId "/subscriptions/<sub>/resourceGroups/rg-old/providers/Microsoft.OperationalInsights/workspaces/law-old"
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ResourceIdFile,

    [Parameter(Mandatory, ParameterSetName = 'List')]
    [string[]]$ResourceId,

    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$NewWorkspaceId,

    [string]$DiagnosticSettingName,

    [string]$OldWorkspaceId,

    [switch]$Force,

    [string]$ReportPath = (".\DiagSettingUpdate_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '2021-05-01-preview'

#region Helpers ---------------------------------------------------------------

function Invoke-Arm {
    param([string]$Path, [string]$Method = 'GET', [string]$Body)
    # Reads must still happen under -WhatIf, so neutralise it for the REST call itself
    $WhatIfPreference = $false
    $params = @{ Path = $Path; Method = $Method }
    if ($Body) { $params.Payload = $Body }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $resp = Invoke-AzRestMethod @params
        if ($resp.StatusCode -ne 429) { return $resp }
        $wait = 10 * $attempt
        Write-Host "    Throttled (429), retrying in $wait s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds $wait
    }
    return $resp
}

function Get-ErrorText($Response) {
    try {
        $j = $Response.Content | ConvertFrom-Json
        if ($j.error.message) { return "$($j.error.code): $($j.error.message)" }
    } catch { }
    return "HTTP $($Response.StatusCode) $($Response.Content)"
}

function Get-ShortName([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return '-' }
    return ($Id.TrimEnd('/') -split '/')[-1]
}

function Test-SameId([string]$A, [string]$B) {
    return ([string]$A).Trim().TrimEnd('/').ToLowerInvariant() -eq ([string]$B).Trim().TrimEnd('/').ToLowerInvariant()
}

function Write-Banner([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 90) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("=" * 90) -ForegroundColor Cyan
}

#endregion

#region Pre-flight -----------------------------------------------------------

$ctx = Get-AzContext
if (-not $ctx) { throw "Not logged in. Run Connect-AzAccount first." }
Write-Host "Signed in as : $($ctx.Account.Id)" -ForegroundColor Gray
Write-Host "Tenant       : $($ctx.Tenant.Id)" -ForegroundColor Gray

# Load resource IDs
if ($PSCmdlet.ParameterSetName -eq 'File') {
    if ($ResourceIdFile -like '*.csv') {
        $rawIds = (Import-Csv $ResourceIdFile).ResourceId
    } else {
        $rawIds = Get-Content $ResourceIdFile | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') }
    }
} else {
    $rawIds = $ResourceId
}

$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$ids = foreach ($r in $rawIds) {
    $id = $r.Trim().Trim('"').TrimEnd('/')
    if (-not $id.StartsWith('/')) { $id = "/$id" }
    if ($seen.Add($id)) { $id }
}
if (-not $ids) { throw "No resource IDs found." }
Write-Host "Resources    : $(@($ids).Count) unique resource ID(s) loaded" -ForegroundColor Gray

# Validate target workspace exists / is accessible
$wsResp = Invoke-Arm -Path "$($NewWorkspaceId)?api-version=2022-10-01"
if ($wsResp.StatusCode -ne 200) {
    throw "Cannot read target workspace '$NewWorkspaceId': $(Get-ErrorText $wsResp)"
}
Write-Host "Target LAW   : $(Get-ShortName $NewWorkspaceId)  ($NewWorkspaceId)" -ForegroundColor Gray

#endregion

#region Phase 1 - Discovery / plan -------------------------------------------

Write-Banner "PHASE 1 - Discovering diagnostic settings"

$plan = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($id in $ids) {
    $i++
    Write-Progress -Activity "Reading diagnostic settings" -Status $id -PercentComplete (($i / @($ids).Count) * 100)

    $resp = Invoke-Arm -Path "$id/providers/Microsoft.Insights/diagnosticSettings?api-version=$ApiVersion"
    if ($resp.StatusCode -ne 200) {
        $plan.Add([pscustomobject]@{
            Resource = Get-ShortName $id; SettingName = '-'; Action = 'ERROR'
            CurrentWorkspace = '-'; NewWorkspace = '-'; StorageAccount = '-'; EventHub = '-'
            Reason = Get-ErrorText $resp; ResourceId = $id
            CurrentWorkspaceId = $null; StorageAccountId = $null; EventHubRuleId = $null; Properties = $null
        })
        continue
    }

    $settings = @(($resp.Content | ConvertFrom-Json).value)
    if ($settings.Count -eq 0) {
        $plan.Add([pscustomobject]@{
            Resource = Get-ShortName $id; SettingName = '-'; Action = 'SKIP'
            CurrentWorkspace = '-'; NewWorkspace = '-'; StorageAccount = '-'; EventHub = '-'
            Reason = 'No diagnostic settings on resource'; ResourceId = $id
            CurrentWorkspaceId = $null; StorageAccountId = $null; EventHubRuleId = $null; Properties = $null
        })
        continue
    }

    foreach ($s in $settings) {
        $p = $s.properties
        $action = 'UPDATE'; $reason = ''

        if ($DiagnosticSettingName -and $s.name -ne $DiagnosticSettingName) {
            $action = 'SKIP'; $reason = "Name does not match '$DiagnosticSettingName'"
        } elseif (-not $p.workspaceId) {
            $action = 'SKIP'; $reason = 'No Log Analytics destination (left untouched)'
        } elseif (Test-SameId $p.workspaceId $NewWorkspaceId) {
            $action = 'SKIP'; $reason = 'Already points to target workspace'
        } elseif ($OldWorkspaceId -and -not (Test-SameId $p.workspaceId $OldWorkspaceId)) {
            $action = 'SKIP'; $reason = 'Current workspace is not -OldWorkspaceId'
        }

        $plan.Add([pscustomobject]@{
            Resource           = Get-ShortName $id
            SettingName        = $s.name
            Action             = $action
            CurrentWorkspace   = Get-ShortName $p.workspaceId
            NewWorkspace       = if ($action -eq 'UPDATE') { Get-ShortName $NewWorkspaceId } else { '-' }
            StorageAccount     = Get-ShortName $p.storageAccountId
            EventHub           = if ($p.eventHubAuthorizationRuleId) { Get-ShortName $p.eventHubName } else { '-' }
            Reason             = $reason
            ResourceId         = $id
            CurrentWorkspaceId = $p.workspaceId
            StorageAccountId   = $p.storageAccountId
            EventHubRuleId     = $p.eventHubAuthorizationRuleId
            Properties         = $p
        })
    }
}
Write-Progress -Activity "Reading diagnostic settings" -Completed

# Show the plan
$plan | Format-Table Action, Resource, SettingName, CurrentWorkspace, NewWorkspace, StorageAccount, EventHub, Reason -AutoSize |
    Out-String -Width 4096 | Write-Host

$toUpdate = @($plan | Where-Object Action -eq 'UPDATE')
$skipped  = @($plan | Where-Object Action -eq 'SKIP')
$errored  = @($plan | Where-Object Action -eq 'ERROR')

Write-Host ("  To update : {0}" -f $toUpdate.Count) -ForegroundColor Yellow
Write-Host ("  Skipped   : {0}" -f $skipped.Count)  -ForegroundColor DarkGray
Write-Host ("  Errors    : {0}" -f $errored.Count)  -ForegroundColor $(if ($errored.Count) { 'Red' } else { 'DarkGray' })

if ($toUpdate.Count -eq 0) {
    Write-Host "`nNothing to update." -ForegroundColor Green
    $plan | Select-Object Action, Resource, SettingName, CurrentWorkspace, NewWorkspace, StorageAccount, Reason, ResourceId |
        Export-Csv -Path $ReportPath -NoTypeInformation
    Write-Host "Report: $ReportPath"
    return
}

#endregion

#region Phase 2 - Confirm ----------------------------------------------------

if (-not $WhatIfPreference -and -not $Force) {
    Write-Host ""
    $answer = Read-Host "Proceed with updating $($toUpdate.Count) diagnostic setting(s)? Type YES to continue"
    if ($answer -cne 'YES') { Write-Host "Aborted by user. No changes made." -ForegroundColor Yellow; return }
}

#endregion

#region Phase 3 - Update and verify ------------------------------------------

Write-Banner "PHASE 2 - Updating and verifying"

$results = [System.Collections.Generic.List[object]]::new()
$n = 0
foreach ($item in $plan) {
    if ($item.Action -ne 'UPDATE') {
        $results.Add([pscustomobject]@{
            Status = $item.Action; Resource = $item.Resource; SettingName = $item.SettingName
            OldWorkspace = $item.CurrentWorkspace; WorkspaceNow = $item.CurrentWorkspace
            StorageBefore = $item.StorageAccount; StorageNow = $item.StorageAccount
            Detail = $item.Reason; ResourceId = $item.ResourceId
        })
        continue
    }

    $n++
    Write-Host ""
    Write-Host ("[{0}/{1}] {2} / {3}" -f $n, $toUpdate.Count, $item.Resource, $item.SettingName) -ForegroundColor White
    Write-Host ("        Workspace : {0}  ->  {1}" -f $item.CurrentWorkspace, (Get-ShortName $NewWorkspaceId)) -ForegroundColor Yellow
    Write-Host ("        Storage   : {0}  (unchanged)" -f $item.StorageAccount) -ForegroundColor Gray

    $status = ''; $detail = ''; $wsNow = $item.CurrentWorkspace; $saNow = $item.StorageAccount
    $settingPath = "$($item.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([uri]::EscapeDataString($item.SettingName))?api-version=$ApiVersion"

    if ($PSCmdlet.ShouldProcess("$($item.ResourceId) [$($item.SettingName)]",
                                "Change workspace $($item.CurrentWorkspace) -> $(Get-ShortName $NewWorkspaceId)")) {
        try {
            # Copy every existing property as-is, only swap workspaceId
            $newProps = [ordered]@{}
            foreach ($prop in $item.Properties.PSObject.Properties) {
                if ($null -ne $prop.Value) { $newProps[$prop.Name] = $prop.Value }
            }
            $newProps['workspaceId'] = $NewWorkspaceId
            $body = @{ properties = $newProps } | ConvertTo-Json -Depth 20

            $put = Invoke-Arm -Path $settingPath -Method PUT -Body $body
            if ($put.StatusCode -notin 200, 201) { throw (Get-ErrorText $put) }

            # Verify by reading it back
            $get = Invoke-Arm -Path $settingPath
            if ($get.StatusCode -ne 200) { throw "Verification read failed: $(Get-ErrorText $get)" }
            $after = ($get.Content | ConvertFrom-Json).properties
            $wsNow = Get-ShortName $after.workspaceId
            $saNow = Get-ShortName $after.storageAccountId

            $wsOk = Test-SameId $after.workspaceId $NewWorkspaceId
            $saOk = Test-SameId $after.storageAccountId $item.StorageAccountId
            $ehOk = Test-SameId $after.eventHubAuthorizationRuleId $item.EventHubRuleId

            if ($wsOk -and $saOk -and $ehOk) {
                $status = 'VERIFIED'; $detail = 'Workspace updated; other destinations unchanged'
                Write-Host "        [VERIFIED] Workspace is now $wsNow, storage still $saNow" -ForegroundColor Green
            } else {
                $status = 'MISMATCH'
                $detail = "wsOk=$wsOk storageOk=$saOk eventHubOk=$ehOk"
                Write-Host "        [MISMATCH] $detail" -ForegroundColor Magenta
            }
        } catch {
            $status = 'FAILED'; $detail = $_.Exception.Message
            Write-Host "        [FAILED] $detail" -ForegroundColor Red
        }
    } else {
        $status = 'WHATIF'; $detail = 'No change made (-WhatIf)'
    }

    $results.Add([pscustomobject]@{
        Status = $status; Resource = $item.Resource; SettingName = $item.SettingName
        OldWorkspace = $item.CurrentWorkspace; WorkspaceNow = $wsNow
        StorageBefore = $item.StorageAccount; StorageNow = $saNow
        Detail = $detail; ResourceId = $item.ResourceId
    })
}

#endregion

#region Phase 4 - Summary ----------------------------------------------------

Write-Banner "RESULTS"

$colour = @{ VERIFIED = 'Green'; WHATIF = 'Cyan'; SKIP = 'DarkGray'; MISMATCH = 'Magenta'; FAILED = 'Red'; ERROR = 'Red' }
$fmt = "{0,-9} {1,-30} {2,-25} {3,-20} {4,-20} {5,-20}"
Write-Host ($fmt -f 'STATUS', 'RESOURCE', 'SETTING', 'OLD WORKSPACE', 'WORKSPACE NOW', 'STORAGE NOW') -ForegroundColor White
Write-Host ("-" * 130) -ForegroundColor DarkGray
foreach ($r in $results) {
    $line = $fmt -f $r.Status, $r.Resource, $r.SettingName, $r.OldWorkspace, $r.WorkspaceNow, $r.StorageNow
    Write-Host $line -ForegroundColor $colour[$r.Status]
}

Write-Host ""
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-9}: {1}" -f $_.Name, $_.Count) -ForegroundColor $colour[$_.Name]
}

$results | Export-Csv -Path $ReportPath -NoTypeInformation
Write-Host "`nFull report written to: $((Resolve-Path $ReportPath).Path)" -ForegroundColor Cyan

#endregion

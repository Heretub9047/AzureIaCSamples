# Set-AzDiagSettingReplacement.ps1
#
# Removes chosen existing diagnostic settings from a list of resources and creates a replacement
# setting with a specified name, Log Analytics workspace and log categories.
#
# Intended for resources where an Azure Policy DeployIfNotExists remediation failed because an existing
# diagnostic setting already sends the same logs to a workspace (Azure rejects a second setting that
# uses the same category + destination). Run once per resource type: edit the CONFIG block below, then
# run the whole script (works as a file OR pasted / "Run Selection" - it does not use param() or $PSCmdlet).
#
# For each resource ID in the file:
#   1. Reads existing diagnostic settings and the log categories the resource supports
#   2. Validates $LogCategories against what the resource supports (resource skipped if invalid)
#   3. Lets you choose which existing settings to remove (interactive, or $RemoveSettingName)
#   4. Backs the removed settings up to JSON, deletes them, creates the new setting, verifies it
#   5. If creating the new setting fails, the removed settings are restored from the backup
# Writes report.csv + JSON backups to $BackupFolder.
#
# Requires: Connect-AzAccount already done (Az.Accounts).

# ==== CONFIG - edit for each run ===========================================================================
$ResourceIdFile    = '.\resources.txt'          # one resource ID per line; blank lines / # comments ignored
$NewSettingName    = 'setByPolicy-xxx'          # name of the replacement diagnostic setting
$NewWorkspaceId    = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-logs/providers/Microsoft.OperationalInsights/workspaces/law-name'
$LogCategories     = @('AuditEvent')            # log categories to enable (no category groups)
$MetricCategories  = @()                        # metric categories e.g. @('AllMetrics') | @() or $null = no metrics added
$DestinationType   = ''                         # '' = leave unset | 'Dedicated' | 'AzureDiagnostics'
$RemoveSettingName = @()                        # @() = prompt per resource | names/wildcards e.g. @('old-*') | @('*') = all
$DryRun            = $true                      # $true = show the plan only, change nothing
$SkipConfirm       = $false                     # $true = skip the per-resource YES prompt
$BackupFolder      = ".\DiagSettingBackup_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
# ===========================================================================================================

$ErrorActionPreference = 'Stop'
$ApiVersion = '2021-05-01-preview'

#region Helpers ---------------------------------------------------------------

function Invoke-Arm {
    param([string]$Path, [string]$Method = 'GET', [string]$Body)
    $p = @{ Path = $Path; Method = $Method }
    if ($Body) { $p.Payload = $Body }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $resp = Invoke-AzRestMethod @p
        if ($resp.StatusCode -ne 429) { return $resp }
        Start-Sleep -Seconds (10 * $attempt)
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
    ($Id.TrimEnd('/') -split '/')[-1]
}

function Test-SameId([string]$A, [string]$B) {
    ([string]$A).Trim().TrimEnd('/') -ieq ([string]$B).Trim().TrimEnd('/')
}

function Get-CategorySummary($Props) {
    $c = @()
    foreach ($l in @($Props.logs)) {
        if ($l.enabled) { $c += $(if ($l.categoryGroup) { "grp:$($l.categoryGroup)" } else { $l.category }) }
    }
    foreach ($m in @($Props.metrics)) { if ($m.enabled) { $c += "metric:$($m.category)" } }
    if ($c) { $c -join ', ' } else { '-' }
}

function Get-SettingPath([string]$Id, [string]$Name) {
    "$Id/providers/Microsoft.Insights/diagnosticSettings/$([uri]::EscapeDataString($Name))?api-version=$ApiVersion"
}

function Get-CleanProperties($Props) {
    $h = [ordered]@{}
    foreach ($p in $Props.PSObject.Properties) { if ($null -ne $p.Value) { $h[$p.Name] = $p.Value } }
    $h
}

#endregion

#region Pre-flight ------------------------------------------------------------

if (-not (Get-AzContext)) { throw "Not logged in. Run Connect-AzAccount first." }
if (-not (Test-Path $ResourceIdFile -PathType Leaf)) { throw "Resource file not found: $ResourceIdFile" }
if ($NewWorkspaceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
    throw "`$NewWorkspaceId is not a valid Log Analytics workspace resource ID."
}
if ($NewWorkspaceId -like '*00000000-0000-0000-0000-000000000000*') { throw "Set `$NewWorkspaceId in the CONFIG block." }
if ([string]::IsNullOrWhiteSpace($NewSettingName)) { throw "Set `$NewSettingName in the CONFIG block." }
if (@($LogCategories).Count -eq 0) { throw "Set `$LogCategories in the CONFIG block." }
if ($DestinationType -and $DestinationType -notin 'Dedicated', 'AzureDiagnostics') {
    throw "`$DestinationType must be '', 'Dedicated' or 'AzureDiagnostics'."
}

$ids = Get-Content $ResourceIdFile |
    ForEach-Object { $_.Trim().Trim('"').TrimEnd('/') } |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    ForEach-Object { if ($_.StartsWith('/')) { $_ } else { "/$_" } } |
    Select-Object -Unique
if (-not $ids) { throw "No resource IDs found in $ResourceIdFile." }

$ws = Invoke-Arm -Path "$($NewWorkspaceId)?api-version=2022-10-01"
if ($ws.StatusCode -ne 200) { throw "Cannot read workspace '$NewWorkspaceId': $(Get-ErrorText $ws)" }

Write-Host "Signed in as   : $((Get-AzContext).Account.Id)" -ForegroundColor Gray
Write-Host "Resources      : $(@($ids).Count)" -ForegroundColor Gray
Write-Host "New setting    : $NewSettingName -> $(Get-ShortName $NewWorkspaceId)" -ForegroundColor Gray
Write-Host "Log categories : $($LogCategories -join ', ')" -ForegroundColor Gray
$MetricCategories = @($MetricCategories | Where-Object { $_ -and $_.Trim() })    # $null / '' -> no metrics
Write-Host "Metrics        : $(if ($MetricCategories) { $MetricCategories -join ', ' } else { '(none)' })" -ForegroundColor Gray
Write-Host "Dry run        : $DryRun" -ForegroundColor $(if ($DryRun) { 'Cyan' } else { 'Yellow' })

New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null

# The new setting body is the same for every resource of this type
$newLogs  = @($LogCategories | ForEach-Object { @{ category = $_; enabled = $true } })
$newProps = [ordered]@{ workspaceId = $NewWorkspaceId; logs = $newLogs }
if ($MetricCategories.Count -gt 0) {
    $newProps.metrics = @($MetricCategories | ForEach-Object { @{ category = $_; enabled = $true } })
}
if ($DestinationType) { $newProps.logAnalyticsDestinationType = $DestinationType }
$newBody = @{ properties = $newProps } | ConvertTo-Json -Depth 20

#endregion

#region Process each resource -------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result($Id, $Status, $Removed, $Detail) {
    $results.Add([pscustomobject]@{
        Status = $Status; Resource = Get-ShortName $Id; Removed = ($Removed -join '; ')
        NewSetting = $NewSettingName; Detail = $Detail; ResourceId = $Id })
    $c = switch ($Status) { 'REPLACED' { 'Green' } 'DRYRUN' { 'Cyan' } 'SKIPPED' { 'DarkGray' } default { 'Red' } }
    Write-Host ("  [{0}] {1}" -f $Status, $Detail) -ForegroundColor $c
}

$n = 0
foreach ($id in $ids) {
    $n++
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $n, @($ids).Count, $id) -ForegroundColor White

    # --- read existing settings
    $resp = Invoke-Arm -Path "$id/providers/Microsoft.Insights/diagnosticSettings?api-version=$ApiVersion"
    if ($resp.StatusCode -ne 200) { Add-Result $id 'ERROR' @() (Get-ErrorText $resp); continue }
    $existing = @(($resp.Content | ConvertFrom-Json).value)

    # --- validate requested categories against what the resource supports
    $catResp = Invoke-Arm -Path "$id/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=$ApiVersion"
    if ($catResp.StatusCode -eq 200) {
        $cats = @(($catResp.Content | ConvertFrom-Json).value)
        $logCats = @($cats | Where-Object { $_.properties.categoryType -eq 'Logs' } | ForEach-Object name)

        $metricCats = @($cats | Where-Object { $_.properties.categoryType -eq 'Metrics' } | ForEach-Object name)

        $bad  = @($LogCategories    | Where-Object { $logCats    -inotcontains $_ } | ForEach-Object { "log '$_'" })
        $bad += @($MetricCategories | Where-Object { $metricCats -inotcontains $_ } | ForEach-Object { "metric '$_'" })
        if ($bad) {
            Add-Result $id 'SKIPPED' @() ("Not supported by this resource: {0}. Supported logs: {1}; metrics: {2}" -f
                ($bad -join ', '), ($logCats -join ', '), ($metricCats -join ', '))
            continue
        }
    } else {
        Write-Host "  (could not read supported categories - skipping validation)" -ForegroundColor DarkYellow
    }

    # --- show what's there
    if ($existing.Count -gt 0) {
        Write-Host "  Existing diagnostic settings:" -ForegroundColor Gray
        $i = 0
        foreach ($s in $existing) {
            $i++
            $p = $s.properties
            Write-Host ("    {0}. {1}" -f $i, $s.name) -ForegroundColor Yellow
            Write-Host ("         workspace : {0}" -f (Get-ShortName $p.workspaceId))
            if ($p.storageAccountId)            { Write-Host ("         storage   : {0}" -f (Get-ShortName $p.storageAccountId)) }
            if ($p.eventHubAuthorizationRuleId) { Write-Host ("         eventhub  : {0}" -f (Get-ShortName $p.eventHubName)) }
            Write-Host ("         categories: {0}" -f (Get-CategorySummary $p))
        }
    } else {
        Write-Host "  No existing diagnostic settings." -ForegroundColor Gray
    }

    # --- choose which to remove
    $toRemove = @()
    if ($existing.Count -gt 0) {
        if (@($RemoveSettingName).Count -gt 0) {
            $toRemove = @($existing | Where-Object {
                $nm = $_.name
                [bool]($RemoveSettingName | Where-Object { $nm -like $_ })
            })
        } else {
            $ans = Read-Host "  Remove which? (numbers e.g. 1,3 | 'all' | Enter = none)"
            if ($ans -ieq 'all') { $toRemove = $existing }
            elseif ($ans.Trim()) {
                $toRemove = @(($ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) |
                    Where-Object { $_ -ge 1 -and $_ -le $existing.Count } | Select-Object -Unique | ForEach-Object { $existing[$_ - 1] })
            }
        }
    }

    # A setting that already has the new name is overwritten by the PUT; no delete needed
    $toDelete  = @($toRemove | Where-Object { $_.name -ine $NewSettingName })
    $nameClash = @($existing | Where-Object { $_.name -ieq $NewSettingName -and $_ -notin $toRemove })
    if ($nameClash) {
        Write-Host "  Note: '$NewSettingName' already exists and was not selected - it will be overwritten." -ForegroundColor DarkYellow
    }

    if ($existing.Count -gt 0 -and $toRemove.Count -eq 0 -and -not $nameClash) {
        Add-Result $id 'SKIPPED' @() 'Nothing selected for removal'
        continue
    }
    $newCount = $existing.Count - $toDelete.Count + $(if ($existing.name -icontains $NewSettingName) { 0 } else { 1 })
    if ($newCount -gt 5) {
        Add-Result $id 'SKIPPED' @() 'Would exceed the limit of 5 diagnostic settings per resource'
        continue
    }

    Write-Host ("  Plan: remove [{0}]  ->  create '{1}'" -f (($toDelete.name) -join ', '), $NewSettingName) -ForegroundColor Cyan

    if ($DryRun) {
        Add-Result $id 'DRYRUN' $toDelete.name 'No change made ($DryRun = $true)'
        continue
    }

    # --- confirm
    if (-not $SkipConfirm) {
        if ((Read-Host "  Type YES to apply") -cne 'YES') { Add-Result $id 'SKIPPED' @() 'Declined by user'; continue }
    }

    # --- backup, delete, create, verify (restore on failure)
    $safe = (Get-ShortName $id) -replace '[^\w\.-]', '_'
    $backupFile = Join-Path $BackupFolder ("{0}_{1}.json" -f $safe, [guid]::NewGuid().ToString('N').Substring(0, 6))
    $existing | ConvertTo-Json -Depth 20 | Set-Content -Path $backupFile -Encoding utf8

    $deleted = @()
    try {
        foreach ($s in $toDelete) {
            $d = Invoke-Arm -Path (Get-SettingPath $id $s.name) -Method DELETE
            if ($d.StatusCode -notin 200, 204) { throw "Delete of '$($s.name)' failed: $(Get-ErrorText $d)" }
            $deleted += $s
            Write-Host "  Removed '$($s.name)'" -ForegroundColor Yellow
        }

        $put = Invoke-Arm -Path (Get-SettingPath $id $NewSettingName) -Method PUT -Body $newBody
        if ($put.StatusCode -notin 200, 201) { throw "Create of '$NewSettingName' failed: $(Get-ErrorText $put)" }

        $get = Invoke-Arm -Path (Get-SettingPath $id $NewSettingName)
        if ($get.StatusCode -ne 200) { throw "Verification read failed: $(Get-ErrorText $get)" }
        $after = ($get.Content | ConvertFrom-Json).properties
        if (-not (Test-SameId $after.workspaceId $NewWorkspaceId)) { throw "Verification failed: workspace is $($after.workspaceId)" }

        Add-Result $id 'REPLACED' $toDelete.name ("Created '{0}' ({1}); backup: {2}" -f $NewSettingName, (Get-CategorySummary $after), $backupFile)
    } catch {
        $err = $_.Exception.Message
        $restored = @()
        foreach ($s in $deleted) {
            try {
                $body = @{ properties = (Get-CleanProperties $s.properties) } | ConvertTo-Json -Depth 20
                $r = Invoke-Arm -Path (Get-SettingPath $id $s.name) -Method PUT -Body $body
                if ($r.StatusCode -in 200, 201) { $restored += $s.name }
            } catch { }
        }
        $detail = "$err | restored: [$($restored -join ', ')] of [$(($deleted.name) -join ', ')] | backup: $backupFile"
        Add-Result $id 'FAILED' $deleted.name $detail
    }
}

#endregion

#region Summary ---------------------------------------------------------------

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    $c = switch ($_.Name) { 'REPLACED' { 'Green' } 'DRYRUN' { 'Cyan' } 'SKIPPED' { 'DarkGray' } default { 'Red' } }
    Write-Host ("  {0,-9}: {1}" -f $_.Name, $_.Count) -ForegroundColor $c
}
$report = Join-Path $BackupFolder 'report.csv'
$results | Export-Csv -Path $report -NoTypeInformation
Write-Host "Report and backups: $((Resolve-Path $BackupFolder).Path)" -ForegroundColor Cyan

#endregion

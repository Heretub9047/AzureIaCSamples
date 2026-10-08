#Requires -Version 5.1
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Calculates the Azure cost of specific resources listed in a CSV file over a date range.

.DESCRIPTION
    The CSV can contain resources from many subscriptions. The script:
      1. Reads full resource IDs from the CSV (column 'ResourceId', or 'ResourceID' / 'Id').
      2. Groups them by subscription (parsed from the resource ID).
      3. Queries the Cost Management Query API once per subscription (in batches of IDs),
         for the supplied date range, grouped by resource.
      4. Writes a per-resource cost CSV (resources with no cost in the period are included
         with a cost of 0) and prints a total per currency.

    Notes:
      - Requires Cost Management Reader (or equivalent) on each subscription.
      - Cost data can lag by up to 24-48 hours. The Query API supports ranges of up to 1 year;
        longer ranges are split into 12-month chunks automatically.
      - Costs are returned by the Query API in the billing currency of each subscription.
      - Deleted resources still show cost for the period they existed, as long as you have
        their original resource ID.
      - Costs for child resources roll up under the ID Azure bills against, which can differ
        from the portal resource ID (e.g. some extensions/meters). Such IDs are reported as 0.

.PARAMETER CsvPath
    Path to the input CSV.

.PARAMETER StartDate
    First day of the range (inclusive).

.PARAMETER EndDate
    Last day of the range (inclusive).

.PARAMETER CostType
    ActualCost (default) or AmortizedCost (spreads reservation / savings plan purchases).

.PARAMETER TenantId
    Optional tenant to connect to if you are not already signed in.

.PARAMETER OutputPath
    Optional path for the results CSV. Defaults to a timestamped CSV next to the input file.

.PARAMETER BatchSize
    Number of resource IDs per API request. Default 50.

.EXAMPLE
    .\Get-AzResourceCostFromCsv.ps1 -CsvPath .\resources.csv -StartDate 2026-09-01 -EndDate 2026-09-30

.EXAMPLE
    .\Get-AzResourceCostFromCsv.ps1 -CsvPath .\resources.csv -StartDate 2026-07-01 -EndDate 2026-09-30 `
        -CostType AmortizedCost -TenantId <tenant-guid>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [datetime]$StartDate,

    [Parameter(Mandatory = $true)]
    [datetime]$EndDate,

    [ValidateSet('ActualCost', 'AmortizedCost')]
    [string]$CostType = 'ActualCost',

    [string]$TenantId,

    [string]$OutputPath,

    [ValidateRange(1, 200)]
    [int]$BatchSize = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($EndDate.Date -lt $StartDate.Date) { throw 'EndDate must be on or after StartDate.' }

#region Helpers
# Splits a resource ID into subscription / resource group / type / name.
# Child resources: .../providers/Microsoft.Sql/servers/srv/databases/db -> type 'Microsoft.Sql/servers/databases', name 'srv/db'
function Get-ResourceIdParts {
    param([string]$Id)
    if ($Id -notmatch '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/([^/]+)/providers/(.+)$') { return $null }
    $segments = @($Matches[3].Split('/'))
    if ($segments.Count -lt 3) { return $null }
    $types = @($segments[0]) + @(for ($i = 1; $i -lt $segments.Count; $i += 2) { $segments[$i] })
    $names = @(for ($i = 2; $i -lt $segments.Count; $i += 2) { $segments[$i] })
    [pscustomobject]@{
        Sub           = $Matches[1].ToLowerInvariant()
        ResourceGroup = $Matches[2]
        Type          = $types -join '/'
        Name          = $names -join '/'
    }
}
# Splits a date range into chunks of at most 12 months (Query API limit is 1 year)
function Get-DateChunks {
    param([datetime]$From, [datetime]$To)
    $cursor = $From.Date
    while ($cursor -le $To.Date) {
        $chunkEnd = $cursor.AddYears(1).AddDays(-1)
        if ($chunkEnd -gt $To.Date) { $chunkEnd = $To.Date }
        [pscustomobject]@{ From = $cursor; To = $chunkEnd }
        $cursor = $chunkEnd.AddDays(1)
    }
}

# POSTs to the Cost Management API with retry on throttling (429) and follows nextLink paging
function Invoke-CostQuery {
    param([string]$SubscriptionId, [string]$Body)

    $path = "/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $allRows = New-Object System.Collections.Generic.List[object]
    $columns = $null

    while ($path) {
        $attempt = 0
        do {
            $attempt++
            $response = Invoke-AzRestMethod -Method POST -Path $path -Payload $Body
            if ($response.StatusCode -eq 429 -or $response.StatusCode -eq 503) {
                $wait = 30
                $retryAfter = $response.Headers | Where-Object { $_.Key -in 'x-ms-ratelimit-microsoft.costmanagement-entity-retry-after', 'Retry-After' } |
                              Select-Object -First 1
                if ($retryAfter) { $wait = [int]@($retryAfter.Value)[0] + 1 }
                Write-Host "    Throttled, waiting ${wait}s (attempt $attempt)..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            }
        } while (($response.StatusCode -eq 429 -or $response.StatusCode -eq 503) -and $attempt -lt 6)

        if ($response.StatusCode -ne 200) {
            throw "Cost query failed ($($response.StatusCode)): $($response.Content)"
        }

        $json = $response.Content | ConvertFrom-Json
        if (-not $columns) { $columns = @($json.properties.columns.name) }
        foreach ($r in @($json.properties.rows)) { if ($null -ne $r) { $allRows.Add($r) } }

        # nextLink is an absolute URL; Invoke-AzRestMethod wants a path
        $next = $json.properties.PSObject.Properties['nextLink']
        $path = if ($next -and $next.Value) { ([uri]$next.Value).PathAndQuery } else { $null }
    }

    [pscustomobject]@{ Columns = $columns; Rows = $allRows }
}
#endregion

#region Input
$resolvedCsv = (Resolve-Path -Path $CsvPath).Path
if (-not $OutputPath) {
    $OutputPath = Join-Path -Path (Split-Path -Path $resolvedCsv -Parent) `
                            -ChildPath ("ResourceCosts_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

$rows = @(Import-Csv -Path $resolvedCsv)
if ($rows.Count -eq 0) { throw "CSV '$resolvedCsv' contains no rows." }

$idColumn = 'ResourceId', 'ResourceID', 'Id', 'ID' | Where-Object { $_ -in $rows[0].PSObject.Properties.Name } | Select-Object -First 1
if (-not $idColumn) { throw "CSV must have a 'ResourceId' column (also accepted: ResourceID, Id)." }

$bySub = @{}       # subscriptionId -> list of resource IDs
$info  = @{}       # lower-cased resource ID -> parsed details
foreach ($row in $rows) {
    $id = "$($row.$idColumn)".Trim().TrimEnd('/')
    if (-not $id) { continue }
    $parts = Get-ResourceIdParts $id
    if (-not $parts) { Write-Warning "Skipping invalid resource ID: $id"; continue }
    $lid = $id.ToLowerInvariant()
    if ($info.ContainsKey($lid)) { continue }   # de-duplicate
    $info[$lid] = $parts
    if (-not $bySub.ContainsKey($parts.Sub)) { $bySub[$parts.Sub] = New-Object System.Collections.Generic.List[string] }
    $bySub[$parts.Sub].Add($id)
}
if ($info.Count -eq 0) { throw 'No valid resource IDs found in the CSV.' }

Write-Host ("Loaded {0} unique resource(s) across {1} subscription(s)" -f $info.Count, $bySub.Count) -ForegroundColor Cyan
Write-Host ("Period: {0:yyyy-MM-dd} to {1:yyyy-MM-dd} ({2})" -f $StartDate, $EndDate, $CostType) -ForegroundColor Cyan
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
#endregion

#region Query
# key: lower-cased resource ID + currency -> cost
$costs = @{}
$failedSubs = @{}
$chunks = @(Get-DateChunks -From $StartDate -To $EndDate)
$subIndex = 0

foreach ($sub in $bySub.Keys) {
    $subIndex++
    $ids = $bySub[$sub]
    Write-Progress -Activity 'Querying costs' -Status "Subscription $sub ($subIndex of $($bySub.Count))" `
                   -PercentComplete (($subIndex / $bySub.Count) * 100)
    Write-Host "Subscription $sub : $($ids.Count) resource(s)" -ForegroundColor White

    try {
        for ($b = 0; $b -lt $ids.Count; $b += $BatchSize) {
            $batch = @($ids[$b..([Math]::Min($b + $BatchSize, $ids.Count) - 1)])

            foreach ($chunk in $chunks) {
                $body = @{
                    type       = $CostType
                    timeframe  = 'Custom'
                    timePeriod = @{
                        from = $chunk.From.ToString('yyyy-MM-dd') + 'T00:00:00Z'
                        to   = $chunk.To.ToString('yyyy-MM-dd') + 'T23:59:59Z'
                    }
                    dataset    = @{
                        granularity = 'None'
                        aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                        grouping    = @(@{ type = 'Dimension'; name = 'ResourceId' })
                        filter      = @{
                            dimensions = @{
                                name     = 'ResourceId'
                                operator = 'In'
                                values   = $batch
                            }
                        }
                    }
                } | ConvertTo-Json -Depth 10 -Compress

                $result = Invoke-CostQuery -SubscriptionId $sub -Body $body
                if (-not $result.Columns) { continue }

                $iCost = [array]::IndexOf($result.Columns, 'Cost')
                if ($iCost -lt 0) { $iCost = [array]::IndexOf($result.Columns, 'PreTaxCost') }
                $iRes = [array]::IndexOf($result.Columns, 'ResourceId')
                $iCur = [array]::IndexOf($result.Columns, 'Currency')
                if ($iCost -lt 0 -or $iRes -lt 0) { throw "Unexpected columns returned: $($result.Columns -join ', ')" }

                foreach ($r in $result.Rows) {
                    $cur = if ($iCur -ge 0) { "$($r[$iCur])" } else { '' }
                    $key = "$($r[$iRes])".ToLowerInvariant() + '|' + $cur
                    if (-not $costs.ContainsKey($key)) { $costs[$key] = 0.0 }
                    $costs[$key] += [double]$r[$iCost]
                }
            }
        }
    }
    catch {
        $failedSubs[$sub] = $_.Exception.Message
        Write-Host "  [Failed] $sub : $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Progress -Activity 'Querying costs' -Completed
#endregion

#region Output
$output = New-Object System.Collections.Generic.List[object]
foreach ($sub in $bySub.Keys) {
    foreach ($id in $bySub[$sub]) {
        $lid = $id.ToLowerInvariant()
        $matches_ = @($costs.Keys | Where-Object { $_.StartsWith("$lid|") })
        $src = $info[$lid]

        if ($failedSubs.ContainsKey($sub)) {
            $output.Add([pscustomobject]@{
                SubscriptionId = $sub; ResourceGroup = $src.ResourceGroup; Type = $src.Type; Name = $src.Name; ResourceId = $id
                Cost = $null; Currency = $null; Status = 'Failed'; Message = $failedSubs[$sub]
            })
        }
        elseif ($matches_.Count -eq 0) {
            $output.Add([pscustomobject]@{
                SubscriptionId = $sub; ResourceGroup = $src.ResourceGroup; Type = $src.Type; Name = $src.Name; ResourceId = $id
                Cost = 0; Currency = $null; Status = 'NoCost'; Message = 'No cost recorded for the period'
            })
        }
        else {
            foreach ($k in $matches_) {
                $output.Add([pscustomobject]@{
                    SubscriptionId = $sub; ResourceGroup = $src.ResourceGroup; Type = $src.Type; Name = $src.Name; ResourceId = $id
                    Cost = [math]::Round($costs[$k], 4); Currency = $k.Substring($lid.Length + 1)
                    Status = 'OK'; Message = ''
                })
            }
        }
    }
}

$output | Sort-Object SubscriptionId, @{ Expression = 'Cost'; Descending = $true } |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host 'Total cost' -ForegroundColor Cyan
$output | Where-Object { $_.Status -eq 'OK' } | Group-Object Currency | ForEach-Object {
    $sum = ($_.Group | Measure-Object -Property Cost -Sum).Sum
    Write-Host ("  {0,-5} {1:N2}" -f $_.Name, $sum)
}
Write-Host ''
Write-Host 'Status' -ForegroundColor Cyan
$output | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.Name, $_.Count) }
Write-Host "Results written to: $OutputPath" -ForegroundColor Cyan

if ($failedSubs.Count -gt 0) { exit 1 }
#endregion

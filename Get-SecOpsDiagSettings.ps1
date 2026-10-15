#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Finds diagnostic settings whose name contains 'SecOps' (case-insensitive) on a list of resources
    and checks that any Log Analytics destination points at the expected workspace.

.DESCRIPTION
    Reads resource IDs from resources.txt (one per line; blank lines and lines starting with # are ignored),
    lists the diagnostic settings on each resource, keeps those with a name matching 'secops', and reports:
      - Compliant     : sends to the expected Log Analytics workspace
      - NonCompliant  : sends to a different Log Analytics workspace
      - NoWorkspace   : setting has no Log Analytics destination (storage / event hub / partner only)

    By default the script is read-only. Use -Remediate to repoint NonCompliant settings to the expected
    workspace (only workspaceId is changed; all other properties are preserved). -WhatIf is supported.

.PARAMETER ResourceIdFile
    Path to the resource ID list. Defaults to .\resources.txt

.PARAMETER Remediate
    Update NonCompliant settings to point at the expected workspace.

.PARAMETER ReportPath
    CSV report output path.

.EXAMPLE
    .\Get-SecOpsDiagSettings.ps1

.EXAMPLE
    .\Get-SecOpsDiagSettings.ps1 -Remediate -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ResourceIdFile = '.\resources.txt',
    [switch]$Remediate,
    [string]$ReportPath = (".\SecOpsDiagSettings_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
)

# ---- EDIT ME: the Log Analytics workspace SecOps diagnostic settings must point to -------------------
$ExpectedWorkspaceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-secops/providers/Microsoft.OperationalInsights/workspaces/law-secops'
# -------------------------------------------------------------------------------------------------------

$NamePattern = 'secops'                  # -match is case-insensitive
$ApiVersion  = '2021-05-01-preview'
$ErrorActionPreference = 'Stop'

function Invoke-Arm {
    param([string]$Path, [string]$Method = 'GET', [string]$Body)
    $WhatIfPreference = $false           # reads must still run under -WhatIf
    $params = @{ Path = $Path; Method = $Method }
    if ($Body) { $params.Payload = $Body }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $resp = Invoke-AzRestMethod @params
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
    return "HTTP $($Response.StatusCode)"
}

function Test-SameId([string]$A, [string]$B) {
    return $A.Trim().TrimEnd('/') -ieq $B.Trim().TrimEnd('/')
}

# ---- Pre-flight ---------------------------------------------------------------------------------------
if (-not (Get-AzContext)) { throw "Not logged in. Run Connect-AzAccount first." }
if (-not (Test-Path $ResourceIdFile -PathType Leaf)) { throw "Resource file not found: $ResourceIdFile" }
if ($ExpectedWorkspaceId -like '*00000000-0000-0000-0000-000000000000*') {
    throw "Set `$ExpectedWorkspaceId at the top of the script before running."
}

$ids = Get-Content $ResourceIdFile |
    ForEach-Object { $_.Trim().Trim('"').TrimEnd('/') } |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    ForEach-Object { if ($_.StartsWith('/')) { $_ } else { "/$_" } } |
    Select-Object -Unique
if (-not $ids) { throw "No resource IDs found in $ResourceIdFile." }

Write-Host "Resources         : $(@($ids).Count)" -ForegroundColor Gray
Write-Host "Expected workspace: $ExpectedWorkspaceId" -ForegroundColor Gray

# ---- Scan ---------------------------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($id in $ids) {
    $resp = Invoke-Arm -Path "$id/providers/Microsoft.Insights/diagnosticSettings?api-version=$ApiVersion"
    if ($resp.StatusCode -ne 200) {
        $results.Add([pscustomobject]@{
            Status = 'ERROR'; SettingName = '-'; CurrentWorkspaceId = ''; Detail = (Get-ErrorText $resp); ResourceId = $id })
        continue
    }

    $matched = @(($resp.Content | ConvertFrom-Json).value | Where-Object { $_.name -match $NamePattern })
    if ($matched.Count -eq 0) {
        $results.Add([pscustomobject]@{
            Status = 'NoSecOpsSetting'; SettingName = '-'; CurrentWorkspaceId = ''; Detail = 'No diagnostic setting name contains SecOps'; ResourceId = $id })
        continue
    }

    foreach ($s in $matched) {
        $ws = $s.properties.workspaceId
        $detail = ''
        if (-not $ws) {
            $status = 'NoWorkspace'; $detail = 'No Log Analytics destination'
        } elseif (Test-SameId $ws $ExpectedWorkspaceId) {
            $status = 'Compliant'
        } else {
            $status = 'NonCompliant'; $detail = 'Points to a different workspace'

            if ($Remediate) {
                $path = "$id/providers/Microsoft.Insights/diagnosticSettings/$([uri]::EscapeDataString($s.name))?api-version=$ApiVersion"
                if ($PSCmdlet.ShouldProcess("$id [$($s.name)]", "Set workspace to $ExpectedWorkspaceId")) {
                    try {
                        $props = [ordered]@{}
                        foreach ($p in $s.properties.PSObject.Properties) { if ($null -ne $p.Value) { $props[$p.Name] = $p.Value } }
                        $props['workspaceId'] = $ExpectedWorkspaceId
                        $put = Invoke-Arm -Path $path -Method PUT -Body (@{ properties = $props } | ConvertTo-Json -Depth 20)
                        if ($put.StatusCode -notin 200, 201) { throw (Get-ErrorText $put) }
                        $status = 'Remediated'; $detail = "Was: $ws"; $ws = $ExpectedWorkspaceId
                    } catch {
                        $status = 'RemediationFailed'; $detail = $_.Exception.Message
                    }
                } else {
                    $detail = 'Would remediate (-WhatIf)'
                }
            }
        }

        $results.Add([pscustomobject]@{
            Status = $status; SettingName = $s.name; CurrentWorkspaceId = $ws; Detail = $detail; ResourceId = $id })
    }
}

# ---- Output -------------------------------------------------------------------------------------------
$results | Format-Table Status, SettingName, CurrentWorkspaceId, ResourceId, Detail -AutoSize |
    Out-String -Width 4096 | Write-Host

$colour = @{ Compliant = 'Green'; Remediated = 'Green'; NonCompliant = 'Red'; RemediationFailed = 'Red'
             ERROR = 'Red'; NoWorkspace = 'Yellow'; NoSecOpsSetting = 'DarkGray' }
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    $c = $colour[$_.Name]; if (-not $c) { $c = 'White' }
    Write-Host ("  {0,-18}: {1}" -f $_.Name, $_.Count) -ForegroundColor $c
}

$results | Export-Csv -Path $ReportPath -NoTypeInformation
Write-Host "`nReport written to: $((Resolve-Path $ReportPath).Path)" -ForegroundColor Cyan

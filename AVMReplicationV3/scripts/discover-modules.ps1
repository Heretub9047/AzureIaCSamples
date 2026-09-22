<#
.SYNOPSIS
    Discovers all published Azure Verified Modules (AVM) Bicep module paths by
    reading the authoritative module-index CSVs maintained in the
    Azure/Azure-Verified-Modules GitHub repo.

.DESCRIPTION
    Output: a plain text file, one module path per line, e.g.
        avm/res/storage/storage-account
        avm/ptn/ai-ml/ai-foundry

    These paths map directly onto:
      - the public MCR bicep registry:      mcr.microsoft.com/bicep/<module-path>
      - the upstream GitHub source repo:    Azure/bicep-registry-modules/<module-path>
      - our mirrored repo location:         bicep/<module-path>

.PARAMETER OutputPath
    Where to write the resulting list of module paths. Defaults to modules.txt
    in the current directory.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$OutputPath = "modules.txt"
)

$ErrorActionPreference = "Stop"

$IndexBase = "https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/static/module-indexes"
$Indexes = @(
    "$IndexBase/BicepResourceModules.csv",
    "$IndexBase/BicepPatternModules.csv",
    "$IndexBase/BicepUtilityModules.csv"
)

# Which module statuses to include.
#   Available = actively published, supported
#   Orphaned  = still published, but currently unmaintained
#   Proposed  = NOT yet published to the registry -- always excluded
$includeStatuses = @("Available")
$includeOrphaned = $env:AVM_INCLUDE_ORPHANED
if ([string]::IsNullOrWhiteSpace($includeOrphaned)) { $includeOrphaned = "true" }
if ($includeOrphaned -eq "true") { $includeStatuses += "Orphaned" }

function Get-ModulePath {
    param([string]$PublicRegistryReference)

    # Expected format: "br/public:avm/res/storage/storage-account:X.Y.Z"
    # Non-published (child/local-only) modules show "n/a" here.
    if ([string]::IsNullOrWhiteSpace($PublicRegistryReference)) { return $null }
    $ref = $PublicRegistryReference.Trim()
    if (-not $ref.StartsWith("br/public:")) { return $null }

    $withoutPrefix = $ref.Substring("br/public:".Length)
    $lastColon = $withoutPrefix.LastIndexOf(":")
    if ($lastColon -lt 0) { return $withoutPrefix }
    return $withoutPrefix.Substring(0, $lastColon)
}

$modulePaths = [System.Collections.Generic.HashSet[string]]::new()

foreach ($url in $Indexes) {
    Write-Host "Fetching index: $url"
    try {
        $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
    }
    catch {
        Write-Warning "  Failed to fetch $url : $_"
        continue
    }

    $rows = $raw | ConvertFrom-Csv
    $matched = 0

    foreach ($row in $rows) {
        if ($includeStatuses -notcontains $row.ModuleStatus) { continue }

        $modulePath = Get-ModulePath -PublicRegistryReference $row.PublicRegistryReference
        if ([string]::IsNullOrWhiteSpace($modulePath)) { continue }

        [void]$modulePaths.Add($modulePath)
        $matched++
    }

    Write-Host "  $matched published modules matched from this index"
}

if ($modulePaths.Count -eq 0) {
    Write-Error "Discovered zero modules -- aborting so we don't wipe a good state"
    exit 1
}

$modulePaths | Sort-Object | Set-Content -Path $OutputPath -Encoding utf8

Write-Host "Wrote $($modulePaths.Count) module paths to $OutputPath"

<#
.SYNOPSIS
    Reads "module,tag" rows produced by get-tags.ps1, works out which ones
    are missing from the destination ACR, and imports only those using
    `az acr import` (a server-side copy -- no image data flows through the
    agent).

.PARAMETER ModulesTagsFile
    Path to the modules-tags.csv produced by get-tags.ps1.

.NOTES
    Reads ACR_NAME, DEST_PREFIX, PARALLELISM, DRY_RUN from environment
    variables (set via the pipeline's AzureCLI@2 task) so the pipeline YAML
    doesn't need to change shape between bash/PowerShell versions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModulesTagsFile
)

$ErrorActionPreference = "Stop"

$AcrName = $env:ACR_NAME
if ([string]::IsNullOrWhiteSpace($AcrName)) {
    throw "Set ACR_NAME to the destination registry name (without .azurecr.io)"
}
$DestPrefix = if ($env:DEST_PREFIX) { $env:DEST_PREFIX } else { "bicep" }
$SourceRegistry = "mcr.microsoft.com"
$Parallelism = if ($env:PARALLELISM) { [int]$env:PARALLELISM } else { 6 }
$MaxRetries = 3
$DryRun = $env:DRY_RUN -eq "true"

# --- Load discovered module/tag pairs -----------------------------------
$rows = Get-Content -Path $ModulesTagsFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
    $parts = $_.Split(",", 2)
    [pscustomobject]@{ Module = $parts[0]; Tag = $parts[1] }
}
$byModule = $rows | Group-Object -Property Module

Write-Host "== Computing diff against $AcrName.azurecr.io =="

$toImport = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($group in $byModule) {
    $module = $group.Name
    $repo = "$DestPrefix/$module"

    $existingTags = @()
    try {
        $existingRaw = az acr repository show-tags `
            --name $AcrName `
            --repository $repo `
            --output tsv `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0 -and $existingRaw) {
            $existingTags = $existingRaw -split "`n" | Where-Object { $_.Trim() -ne "" }
        }
    }
    catch {
        # Repository doesn't exist yet in the destination -- everything is new
    }

    $sourceTags = $group.Group.Tag | Sort-Object -Unique
    $missing = $sourceTags | Where-Object { $existingTags -notcontains $_ }

    foreach ($tag in $missing) {
        $toImport.Add([pscustomobject]@{ Module = $module; Tag = $tag })
    }
}

Write-Host "== $($toImport.Count) module/version(s) need importing =="

if ($toImport.Count -eq 0) {
    Write-Host "Nothing to do. Registry is already up to date."
    exit 0
}

if ($DryRun) {
    Write-Host "DRY_RUN=true -- listing what would be imported:"
    $toImport | ForEach-Object { Write-Host "$DestPrefix/$($_.Module):$($_.Tag)" }
    exit 0
}

# --- Import missing module/version pairs in parallel --------------------
$importResults = $toImport | ForEach-Object -Parallel {
    $module = $_.Module
    $tag = $_.Tag
    $acrName = $using:AcrName
    $destPrefix = $using:DestPrefix
    $sourceRegistry = $using:SourceRegistry
    $maxRetries = $using:MaxRetries

    $repo = "$destPrefix/$module"
    $source = "$sourceRegistry/${repo}:$tag"

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        $err = az acr import `
            --name $acrName `
            --source $source `
            --image "${repo}:$tag" `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ Status = "OK"; Repo = $repo; Tag = $tag }
        }
        Write-Warning "attempt $attempt failed for ${repo}:${tag} -- $err"
        Start-Sleep -Seconds ($attempt * 5)
    }

    return [pscustomobject]@{ Status = "FAIL"; Repo = $repo; Tag = $tag }
} -ThrottleLimit $Parallelism

$okCount = ($importResults | Where-Object { $_.Status -eq "OK" }).Count
$failed = $importResults | Where-Object { $_.Status -eq "FAIL" }

Write-Host "== Sync complete: $okCount imported, $($failed.Count) failed =="

if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host "FAIL $($_.Repo):$($_.Tag)" }
    exit 1
}

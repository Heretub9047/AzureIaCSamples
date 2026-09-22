<#
.SYNOPSIS
    Scans every module folder under bicep/avm/** and bicep/custom/**, works
    out the version each one should be published at, and publishes anything
    missing from the destination ACR via `az bicep publish`.

.DESCRIPTION
    Version resolution:
      - bicep/avm/**    -> looked up in bicep/avm/_manifest.json (maintained
                            by sync-avm-source.ps1; upstream's own
                            version.json only has MAJOR.MINOR, so it is not
                            used here)
      - bicep/custom/**  -> read directly from that module's own
                            version.json, which MUST contain a full
                            MAJOR.MINOR.PATCH "version" field, e.g.
                            { "version": "1.0.0" }

    A "module folder" is any directory containing a main.bicep file.

    Because this diffs against what's already published in the ACR (rather
    than relying on git diff), it's safe to run repeatedly / on a schedule
    as a safety net -- already-published versions are always skipped.

.PARAMETER RepoRoot
    Local path to the checked-out repo (e.g. $(Build.SourcesDirectory)).

.PARAMETER AcrName
    Destination ACR name, without ".azurecr.io".

.PARAMETER DryRun
    If true, only reports what would be published.

.NOTES
    Requires an authenticated `az` session (run from inside an AzureCLI@2
    pipeline task) whose identity has AcrPush (or higher) on the destination
    ACR -- `az bicep publish` is a registry *push* (data-plane), unlike
    `az acr import` which is a control-plane operation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$AcrName,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$MaxRetries = 3

# --- Make sure the bicep CLI is present and current ------------------------
az bicep install 2>&1 | Out-Null
az bicep upgrade 2>&1 | Out-Null

# --- Load the AVM manifest --------------------------------------------------
$manifestPath = Join-Path $RepoRoot "bicep/avm/_manifest.json"
$manifest = if (Test-Path $manifestPath) {
    Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
}
else {
    @{}
}

# --- Discover every module folder ------------------------------------------
$bicepRoot = Join-Path $RepoRoot "bicep"
$moduleDirs = Get-ChildItem -Path $bicepRoot -Recurse -Filter "main.bicep" -File |
    ForEach-Object { $_.Directory }

Write-Host "Found $($moduleDirs.Count) module folder(s) under bicep/"

$toPublish = [System.Collections.Generic.List[pscustomobject]]::new()
$skippedNoVersion = [System.Collections.Generic.List[string]]::new()

foreach ($dir in $moduleDirs) {
    $relativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $dir.FullName) -replace "\\", "/"
    # relativePath looks like: bicep/avm/res/storage/storage-account
    #                       or bicep/custom/ptn/my-pattern

    $version = $null

    if ($relativePath.StartsWith("bicep/avm/")) {
        $manifestKey = $relativePath.Substring("bicep/".Length) # avm/res/...
        if ($manifest.ContainsKey($manifestKey)) {
            $version = $manifest[$manifestKey]
        }
    }
    elseif ($relativePath.StartsWith("bicep/custom/")) {
        $versionJsonPath = Join-Path $dir.FullName "version.json"
        if (Test-Path $versionJsonPath) {
            try {
                $versionJson = Get-Content $versionJsonPath -Raw | ConvertFrom-Json
                if ($versionJson.version -match '^\d+\.\d+\.\d+$') {
                    $version = $versionJson.version
                }
            }
            catch {
                Write-Warning "Failed to parse $versionJsonPath : $_"
            }
        }
    }

    if (-not $version) {
        $skippedNoVersion.Add($relativePath)
        continue
    }

    $toPublish.Add([pscustomobject]@{
        RelativePath = $relativePath
        Registry     = $relativePath # 1:1 with the ACR repository path
        Version      = $version
        MainBicep    = Join-Path $dir.FullName "main.bicep"
    })
}

if ($skippedNoVersion.Count -gt 0) {
    Write-Warning "Skipped $($skippedNoVersion.Count) module folder(s) with no resolvable version:"
    $skippedNoVersion | ForEach-Object { Write-Warning "  $_" }
}

# --- Diff against what's already in the ACR ---------------------------------
$missing = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($item in $toPublish) {
    $existingTags = @()
    $showTagsOutput = az acr repository show-tags `
        --name $AcrName `
        --repository $item.Registry `
        --output tsv `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and $showTagsOutput) {
        $existingTags = $showTagsOutput -split "`n" | Where-Object { $_.Trim() -ne "" }
    }

    if ($existingTags -notcontains $item.Version) {
        $missing.Add($item)
    }
}

Write-Host "== $($missing.Count) of $($toPublish.Count) module(s) need publishing =="

if ($missing.Count -eq 0) {
    Write-Host "Nothing to do. Registry is already up to date."
    exit 0
}

if ($DryRun) {
    Write-Host "DryRun -- listing what would be published:"
    $missing | ForEach-Object { Write-Host "$($_.Registry):$($_.Version)" }
    exit 0
}

# --- Publish -----------------------------------------------------------------
$okCount = 0
$failed = [System.Collections.Generic.List[string]]::new()

foreach ($item in $missing) {
    $target = "br:$AcrName.azurecr.io/$($item.Registry):$($item.Version)"
    $published = $false

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $output = az bicep publish --file $item.MainBicep --target $target --force 2>&1
        if ($LASTEXITCODE -eq 0) { $published = $true; break }
        Write-Warning "attempt $attempt failed publishing $target -- $output"
        Start-Sleep -Seconds ($attempt * 5)
    }

    if ($published) {
        Write-Host "OK   $target"
        $okCount++
    }
    else {
        Write-Host "FAIL $target"
        $failed.Add($target)
    }
}

Write-Host "== Publish complete: $okCount published, $($failed.Count) failed =="

if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host "FAIL $_" }
    exit 1
}

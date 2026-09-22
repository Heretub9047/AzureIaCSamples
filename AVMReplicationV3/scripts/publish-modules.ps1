<#
.SYNOPSIS
    Scans every module VERSION folder under bicep/avm/** and bicep/custom/**
    and publishes anything missing from the destination ACR via
    `az bicep publish`.

.DESCRIPTION
    A "module version folder" is any directory containing a main.bicep file.
    Its version is simply its own folder name, e.g.:

        bicep/avm/res/storage/storage-account/0.30.1/main.bicep
          -> registry repo "bicep/avm/res/storage/storage-account", version "0.30.1"

        bicep/custom/ptn/landing-zone/1.1.0/main.bicep
          -> registry repo "bicep/custom/ptn/landing-zone", version "1.1.0"

    This applies uniformly to mirrored AVM modules and hand-authored custom
    modules -- both use the same "one folder per version, never edited once
    published" layout, so there's no separate manifest or version.json
    lookup needed; the folder structure IS the version record.

    If a version-folder's own version.json contains a "version" field that
    doesn't match the folder name, that's flagged as a warning (it likely
    means someone hand-edited version.json without renaming the folder) but
    the folder name still wins, since that's what the ACR tag is based on.

    Because this diffs against what's already published in the ACR (rather
    than relying on git diff), it's safe to run repeatedly / on a schedule
    as a safety net -- already-published versions are always skipped, and
    already-published versions are never republished or overwritten.

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
$VersionFolderPattern = '^\d+\.\d+\.\d+$'

# --- Make sure the bicep CLI is present and current ------------------------
az bicep install 2>&1 | Out-Null
az bicep upgrade 2>&1 | Out-Null

# --- Discover every module VERSION folder -----------------------------------
$bicepRoot = Join-Path $RepoRoot "bicep"
$moduleDirs = Get-ChildItem -Path $bicepRoot -Recurse -Filter "main.bicep" -File |
    ForEach-Object { $_.Directory }

Write-Host "Found $($moduleDirs.Count) module version folder(s) under bicep/"

$toPublish = [System.Collections.Generic.List[pscustomobject]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()

foreach ($dir in $moduleDirs) {
    $version = $dir.Name # the version folder's own name

    if ($version -notmatch $VersionFolderPattern) {
        $relativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $dir.FullName) -replace "\\", "/"
        $skipped.Add("$relativePath (folder name '$version' is not a MAJOR.MINOR.PATCH version)")
        continue
    }

    $registryRepo = [System.IO.Path]::GetRelativePath($RepoRoot, $dir.Parent.FullName) -replace "\\", "/"
    # e.g. bicep/avm/res/storage/storage-account  or  bicep/custom/ptn/landing-zone

    # Best-effort sanity check against version.json, if present
    $versionJsonPath = Join-Path $dir.FullName "version.json"
    if (Test-Path $versionJsonPath) {
        try {
            $versionJson = Get-Content $versionJsonPath -Raw | ConvertFrom-Json
            if ($versionJson.version -and $versionJson.version -ne $version) {
                Write-Warning "$registryRepo/$version : version.json says '$($versionJson.version)' but folder is named '$version' -- using the folder name"
            }
        }
        catch {
            Write-Warning "Failed to parse $versionJsonPath : $_"
        }
    }

    $toPublish.Add([pscustomobject]@{
        Registry  = $registryRepo
        Version   = $version
        MainBicep = Join-Path $dir.FullName "main.bicep"
    })
}

if ($skipped.Count -gt 0) {
    Write-Warning "Skipped $($skipped.Count) folder(s) that don't look like a version folder:"
    $skipped | ForEach-Object { Write-Warning "  $_" }
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

Write-Host "== $($missing.Count) of $($toPublish.Count) module version(s) need publishing =="

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

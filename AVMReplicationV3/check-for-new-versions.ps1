<#
.SYNOPSIS
    Cheaply checks whether any module in -ModulesLatestFile has a version
    not yet present in the current checkout, and sets a pipeline output
    variable (hasNewVersions = true/false) accordingly.

.DESCRIPTION
    This is deliberately the lightest possible check: it just looks at
    bicep/<module>/<version> under the already-checked-out working tree
    (i.e. whatever -TargetBranch's content is, from the job's initial
    `checkout: self` step) -- no extra git fetch, no branch switching.

    It exists purely so the pipeline can skip the heavy
    sync-avm-source.ps1 step entirely (branch checkout/merge, commit, push,
    PR create/lookup) via a `condition:` when there's nothing to do, rather
    than running that step and having it no-op internally.

    Because this only checks against -TargetBranch, it can occasionally say
    "yes, new versions" even when those exact versions are already sitting
    in an unmerged mirror PR -- that's fine: sync-avm-source.ps1 still does
    its own accurate check (merged against the pending branch) before
    deciding whether to actually commit/push/open a PR, so this pre-check
    only needs to answer "is it worth even trying", not "is there
    definitely something to commit".

.PARAMETER ModulesLatestFile
    Path to the module,version CSV produced by get-latest-versions.ps1.

.PARAMETER RepoRoot
    Local path to the checked-out repo (e.g. $(Build.SourcesDirectory)).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModulesLatestFile,
    [Parameter(Mandatory)][string]$RepoRoot
)

$ErrorActionPreference = "Stop"

$rows = Get-Content -Path $ModulesLatestFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
    $parts = $_.Split(",", 2)
    [pscustomobject]@{ Module = $parts[0]; Version = $parts[1] }
}

$missing = $rows | Where-Object {
    $existingDir = Join-Path $RepoRoot ("bicep/" + $_.Module + "/" + $_.Version)
    -not (Test-Path $existingDir)
}

Write-Host "$($rows.Count) modules checked; $($missing.Count) have a version not yet in this checkout"

if ($missing.Count -gt 0) {
    Write-Host "Examples:"
    $missing | Select-Object -First 10 | ForEach-Object { Write-Host "  $($_.Module) -> $($_.Version)" }
}

$hasNewVersions = if ($missing.Count -gt 0) { "true" } else { "false" }
Write-Host "##vso[task.setvariable variable=hasNewVersions;isOutput=true]$hasNewVersions"

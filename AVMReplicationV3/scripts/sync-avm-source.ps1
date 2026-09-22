<#
.SYNOPSIS
    Captures the source of any AVM module version we haven't already
    mirrored into a permanent, version-numbered folder under bicep/avm/**,
    pushes the result to a dedicated branch, and opens a pull request into
    -TargetBranch (creating one only if one isn't already open).

.DESCRIPTION
    For each module in -ModulesLatestFile (module,version rows from
    get-latest-versions.ps1 -- the *currently latest published* version of
    each module), this script checks whether
    bicep/<module>/<version>/ already exists (checking both -TargetBranch
    and any not-yet-merged work already sitting on -BranchName).

      - If it already exists: skip. Once a version's folder has been
        captured, it is a permanent historical record and is NEVER
        overwritten or refetched, even if upstream's main branch has since
        moved on.
      - If it doesn't exist: fetch main.bicep / version.json / README.md
        from the upstream repo's current main branch and write them into
        the new bicep/<module>/<version>/ folder.

    Rather than opening a new branch/PR every run (which would pile up
    duplicate open PRs whenever one sits unreviewed overnight), this script
    reuses a single long-lived branch (-BranchName, default
    "avm-mirror-sync"): each run rebases it onto the current target branch,
    adds any newly-captured versions as additional commits, and only opens
    a new PR if there isn't already an open one for that branch. Merging
    that PR is what actually lands new versions into -TargetBranch.

    IMPORTANT LIMITATION: upstream (Azure/bicep-registry-modules) does not
    expose a reliable way to fetch the exact historical source of a
    specific past PATCH version -- the PATCH is assigned by Microsoft's own
    CI at publish time with no corresponding git tag. So "the currently
    latest version's folder" is filled with "whatever main currently
    contains", which is accurate AS LONG AS this script runs at least once
    per newly-published version. If a module publishes two or more new
    versions between mirror runs, only the latest of those is captured --
    the skipped intermediate version(s) simply never get a folder here
    (they remain available directly on mcr.microsoft.com if ever needed).

    Deliberately does NOT fetch the module's tests/ subfolder, matching the
    "deployable files only" mirror policy.

.PARAMETER ModulesLatestFile
    Path to the module,version CSV produced by get-latest-versions.ps1.

.PARAMETER RepoRoot
    Local path to the checked-out repo (e.g. $(Build.SourcesDirectory)).

.PARAMETER UpstreamRef
    Git ref in Azure/bicep-registry-modules to pull source from. Defaults to
    "main".

.PARAMETER TargetBranch
    Branch in THIS repo the pull request should target. Defaults to "main".

.PARAMETER BranchName
    The long-lived branch this script pushes mirror commits to and opens
    the PR from. Defaults to "avm-mirror-sync".

.PARAMETER Parallelism
    Concurrent file downloads from GitHub. Defaults to 12.

.PARAMETER CommitUserName / CommitUserEmail
    Identity to attribute mirror commits to.

.PARAMETER OrganizationUri / Project / RepositoryId / AccessToken
    Azure DevOps REST API coordinates used to look up / create the pull
    request. Default to the pipeline's own predefined variables
    ($env:SYSTEM_COLLECTIONURI, $env:SYSTEM_TEAMPROJECT,
    $env:BUILD_REPOSITORY_ID) and the job's OAuth token
    ($env:SYSTEM_ACCESSTOKEN, which must be explicitly mapped into the
    task's env block in the pipeline YAML).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModulesLatestFile,
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$UpstreamRef = "main",
    [string]$TargetBranch = "main",
    [string]$BranchName = "avm-mirror-sync",
    [int]$Parallelism = 12,
    [string]$CommitUserName = "AVM Mirror Bot",
    [string]$CommitUserEmail = "avm-mirror-bot@localhost",
    [string]$OrganizationUri = $(if ($env:SYSTEM_COLLECTIONURI) { $env:SYSTEM_COLLECTIONURI } else { $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI }),
    [string]$Project = $env:SYSTEM_TEAMPROJECT,
    [string]$RepositoryId = $env:BUILD_REPOSITORY_ID,
    [string]$AccessToken = $env:SYSTEM_ACCESSTOKEN
)

$ErrorActionPreference = "Stop"

$UpstreamRawBase = "https://raw.githubusercontent.com/Azure/bicep-registry-modules/$UpstreamRef"
$DeployableFiles = @("main.bicep", "version.json", "README.md")

# --- Get the working branch into a known state ------------------------------
Push-Location $RepoRoot
try {
    git config user.name $CommitUserName
    git config user.email $CommitUserEmail

    git fetch origin $TargetBranch
    git checkout $TargetBranch
    git pull origin $TargetBranch

    $remoteBranchExists = [bool](git ls-remote --heads origin $BranchName)

    if ($remoteBranchExists) {
        Write-Host "Branch '$BranchName' already exists remotely -- continuing it"
        git fetch origin $BranchName
        git checkout -B $BranchName "origin/$BranchName"
        # Bring in anything that's landed on the target branch since this
        # branch was last pushed (e.g. a previous mirror PR got merged, or
        # a custom-module PR merged in the meantime).
        git merge "origin/$TargetBranch" --no-edit
    }
    else {
        Write-Host "Branch '$BranchName' doesn't exist yet -- branching from $TargetBranch"
        git checkout -b $BranchName "origin/$TargetBranch"
    }
}
finally {
    Pop-Location
}

# --- Work out which versions still need capturing ---------------------------
$rows = Get-Content -Path $ModulesLatestFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
    $parts = $_.Split(",", 2)
    [pscustomobject]@{ Module = $parts[0]; Version = $parts[1] }
}

$toFetch = $rows | Where-Object {
    $existingDir = Join-Path $RepoRoot ("bicep/" + $_.Module + "/" + $_.Version)
    -not (Test-Path $existingDir)
}

Write-Host "$($rows.Count) modules checked; $($toFetch.Count) have a new version to capture"

if ($toFetch.Count -eq 0) {
    Write-Host "Nothing new to mirror."
    exit 0
}

Write-Host "Fetching source for $($toFetch.Count) new module version(s) (parallelism=$Parallelism)..."

# --- Phase 1: fetch, in parallel -------------------------------------------
$fetched = $toFetch | ForEach-Object -Parallel {
    $module = $_.Module
    $version = $_.Version
    $base = "$using:UpstreamRawBase/$module"
    $files = $using:DeployableFiles

    $content = @{}
    $ok = $true
    foreach ($file in $files) {
        try {
            $resp = Invoke-WebRequest -Uri "$base/$file" -UseBasicParsing -ErrorAction Stop
            $content[$file] = $resp.Content
        }
        catch {
            if ($file -eq "main.bicep") {
                Write-Warning "REQUIRED file main.bicep missing for $module -- skipping ($_)"
                $ok = $false
            }
            # version.json / README.md are best-effort; a 404 just means
            # this particular module doesn't ship one.
        }
    }

    if (-not $ok) { return }

    [pscustomobject]@{
        Module  = $module
        Version = $version
        Content = $content
    }
} -ThrottleLimit $Parallelism

Write-Host "Fetched $($fetched.Count) of $($toFetch.Count) new module version(s) successfully"

# --- Phase 2: write new, permanent version folders --------------------------
$capturedModules = [System.Collections.Generic.List[string]]::new()

foreach ($item in $fetched) {
    $versionDir = Join-Path $RepoRoot ("bicep/" + $item.Module + "/" + $item.Version)

    if (Test-Path $versionDir) {
        Write-Host "Skipping $($item.Module)/$($item.Version) -- folder already exists"
        continue
    }

    New-Item -ItemType Directory -Force -Path $versionDir | Out-Null

    foreach ($file in $DeployableFiles) {
        if ($item.Content.ContainsKey($file)) {
            $targetPath = Join-Path $versionDir $file
            Set-Content -Path $targetPath -Value $item.Content[$file] -NoNewline -Encoding utf8
        }
    }

    $capturedModules.Add("$($item.Module) ($($item.Version))")
}

if ($capturedModules.Count -eq 0) {
    Write-Host "No new version folders were created -- nothing to commit."
    exit 0
}

Write-Host "Captured $($capturedModules.Count) new module version(s):"
$capturedModules | ForEach-Object { Write-Host "  $_" }

# --- Commit + push to the dedicated mirror branch ----------------------------
Push-Location $RepoRoot
try {
    git add "bicep/avm"

    $summary = if ($capturedModules.Count -le 10) {
        $capturedModules -join ", "
    }
    else {
        "$($capturedModules.Count) new module versions"
    }
    $commitMessage = "AVM mirror sync: $summary"

    git commit -m $commitMessage
    git push origin "HEAD:$BranchName"
}
finally {
    Pop-Location
}

Write-Host "Pushed mirror sync commit to '$BranchName': $commitMessage"

# --- Open a PR, unless one is already open for this branch ------------------
if (-not $AccessToken) {
    Write-Warning "No access token available -- skipping PR creation. Push System.AccessToken into the pipeline task's env block to enable this."
    exit 0
}
if (-not $OrganizationUri -or -not $Project -or -not $RepositoryId) {
    Write-Warning "Missing OrganizationUri/Project/RepositoryId -- skipping PR creation."
    exit 0
}

$headers = @{ Authorization = "Bearer $AccessToken" }
$apiBase = "$($OrganizationUri.TrimEnd('/'))/$Project/_apis/git/repositories/$RepositoryId/pullrequests"

$searchUrl = "$apiBase`?searchCriteria.sourceRefName=refs/heads/$BranchName&searchCriteria.targetRefName=refs/heads/$TargetBranch&searchCriteria.status=active&api-version=7.1"
$existing = Invoke-RestMethod -Uri $searchUrl -Headers $headers -Method Get

if ($existing.count -gt 0) {
    $prId = $existing.value[0].pullRequestId
    Write-Host "PR #$prId is already open for '$BranchName' -> '$TargetBranch' -- new commits will show up there automatically."
    exit 0
}

Write-Host "No open PR found for '$BranchName' -- creating one."

$body = @{
    sourceRefName = "refs/heads/$BranchName"
    targetRefName = "refs/heads/$TargetBranch"
    title         = "AVM mirror sync"
    description   = "Automated sync of newly published Azure Verified Module versions.`n`nCaptured module version(s) in this update:`n`n$(($capturedModules | ForEach-Object { "- $_" }) -join "`n")`n`nEach version lives in its own permanent folder and is never modified once merged. See README.md for details on the versioning model."
} | ConvertTo-Json

$createUrl = "$apiBase`?api-version=7.1"
$pr = Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body $body -ContentType "application/json"

Write-Host "Created PR #$($pr.pullRequestId): $($pr.url)"

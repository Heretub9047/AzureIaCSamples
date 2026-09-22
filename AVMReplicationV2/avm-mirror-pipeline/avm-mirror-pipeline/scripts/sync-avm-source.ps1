<#
.SYNOPSIS
    Syncs the deployable source of every discovered AVM module from the
    upstream Azure/bicep-registry-modules GitHub repo into bicep/avm/** of
    this repo, updates the version manifest, and pushes the result to main.

.DESCRIPTION
    For each module in -ModulesLatestFile (module,version rows from
    get-latest-versions.ps1), fetches main.bicep, version.json and README.md
    from the upstream repo's main branch and writes them to
    <RepoRoot>/bicep/<module>/. Deliberately does NOT fetch the module's
    tests/ subfolder, matching the "deployable files only" mirror policy.

    bicep/avm/_manifest.json is the source of truth the publish pipeline
    reads to know which version each mirrored module folder currently
    represents (upstream's own version.json only stores MAJOR.MINOR --
    the PATCH is assigned by Microsoft's own CI at publish time -- so we
    record the *actual* resolved version, taken from MCR, separately).

    Commits directly to the branch checked out at -RepoRoot (no PR step),
    per team decision. Requires the pipeline identity to have push rights
    on that branch.

.PARAMETER ModulesLatestFile
    Path to the module,version CSV produced by get-latest-versions.ps1.

.PARAMETER RepoRoot
    Local path to the checked-out repo (e.g. $(Build.SourcesDirectory)).

.PARAMETER UpstreamRef
    Git ref in Azure/bicep-registry-modules to pull source from. Defaults to
    "main".

.PARAMETER TargetBranch
    Branch in THIS repo to commit and push to. Defaults to "main".

.PARAMETER Parallelism
    Concurrent file downloads from GitHub. Defaults to 12.

.PARAMETER CommitUserName / CommitUserEmail
    Identity to attribute the mirror commit to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModulesLatestFile,
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$UpstreamRef = "main",
    [string]$TargetBranch = "main",
    [int]$Parallelism = 12,
    [string]$CommitUserName = "AVM Mirror Bot",
    [string]$CommitUserEmail = "avm-mirror-bot@localhost"
)

$ErrorActionPreference = "Stop"

$UpstreamRawBase = "https://raw.githubusercontent.com/Azure/bicep-registry-modules/$UpstreamRef"
$DeployableFiles = @("main.bicep", "version.json", "README.md")
$ManifestPath = Join-Path $RepoRoot "bicep/avm/_manifest.json"

# --- Load current manifest ------------------------------------------------
$manifest = if (Test-Path $ManifestPath) {
    Get-Content $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
}
else {
    @{}
}

$rows = Get-Content -Path $ModulesLatestFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
    $parts = $_.Split(",", 2)
    [pscustomobject]@{ Module = $parts[0]; Version = $parts[1] }
}

Write-Host "Fetching source for $($rows.Count) modules (parallelism=$Parallelism)..."

# --- Phase 1: fetch, in parallel -------------------------------------------
$fetched = $rows | ForEach-Object -Parallel {
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
                Write-Warning "REQUIRED file main.bicep missing for $module -- skipping module ($_)"
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

Write-Host "Fetched $($fetched.Count) of $($rows.Count) modules successfully"

# --- Phase 2: write to disk + update manifest (sequential, cheap) ---------
$changedModules = [System.Collections.Generic.List[string]]::new()

foreach ($item in $fetched) {
    $module = $item.Module
    $localDir = Join-Path $RepoRoot ("bicep/" + $module)
    New-Item -ItemType Directory -Force -Path $localDir | Out-Null

    $moduleChanged = $false

    foreach ($file in $DeployableFiles) {
        $targetPath = Join-Path $localDir $file
        if ($item.Content.ContainsKey($file)) {
            $newContent = $item.Content[$file]
            $existing = if (Test-Path $targetPath) { Get-Content $targetPath -Raw } else { $null }
            if ($existing -ne $newContent) {
                Set-Content -Path $targetPath -Value $newContent -NoNewline -Encoding utf8
                $moduleChanged = $true
            }
        }
        elseif (Test-Path $targetPath) {
            # Upstream no longer ships this optional file (e.g. README.md removed)
            Remove-Item -Path $targetPath -Force
            $moduleChanged = $true
        }
    }

    if ($manifest[$module] -ne $item.Version) {
        $manifest[$module] = $item.Version
        $moduleChanged = $true
    }

    if ($moduleChanged) {
        $changedModules.Add("$module ($($item.Version))")
    }
}

# --- Write manifest (only if it actually changed, to keep diffs clean) ----
# Sort keys alphabetically so the manifest diff stays minimal and readable.
$sortedManifest = [ordered]@{}
foreach ($key in ($manifest.Keys | Sort-Object)) { $sortedManifest[$key] = $manifest[$key] }
$newManifestJson = $sortedManifest | ConvertTo-Json -Depth 5
$existingManifestJson = if (Test-Path $ManifestPath) { Get-Content $ManifestPath -Raw } else { "" }
if ($newManifestJson.Trim() -ne $existingManifestJson.Trim()) {
    Set-Content -Path $ManifestPath -Value $newManifestJson -Encoding utf8
}

if ($changedModules.Count -eq 0) {
    Write-Host "No module changes detected -- nothing to commit."
    exit 0
}

Write-Host "Changed modules ($($changedModules.Count)):"
$changedModules | ForEach-Object { Write-Host "  $_" }

# --- Commit + push straight to the checked-out branch ----------------------
Push-Location $RepoRoot
try {
    git config user.name $CommitUserName
    git config user.email $CommitUserEmail

    git add "bicep/avm"

    $summary = if ($changedModules.Count -le 10) {
        $changedModules -join ", "
    }
    else {
        "$($changedModules.Count) modules updated"
    }
    $commitMessage = "AVM mirror sync: $summary"

    git commit -m $commitMessage

    $pushed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        git push origin "HEAD:$TargetBranch" 2>&1 | Tee-Object -Variable pushOutput
        if ($LASTEXITCODE -eq 0) { $pushed = $true; break }

        Write-Warning "push attempt $attempt failed, pulling --rebase and retrying: $pushOutput"
        git pull --rebase origin $TargetBranch
    }

    if (-not $pushed) {
        throw "Failed to push mirror sync commit after 3 attempts"
    }

    Write-Host "Pushed mirror sync commit: $commitMessage"
}
finally {
    Pop-Location
}

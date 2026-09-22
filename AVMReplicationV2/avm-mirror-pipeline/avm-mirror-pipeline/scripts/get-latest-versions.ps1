<#
.SYNOPSIS
    For every module path in -ModulesFile, finds the latest published version
    on mcr.microsoft.com and writes "module,version" rows to -OutputFile.

.DESCRIPTION
    We only need the *latest* version here (not full tag history) because the
    mirror pipeline's job is to keep bicep/avm/** in sync with the current
    upstream source -- publishing of individual historical versions already
    happened when they were first mirrored.

.PARAMETER ModulesFile
    Path to the modules.txt produced by discover-modules.ps1.

.PARAMETER OutputFile
    Where to write the resulting module,version CSV.

.PARAMETER Parallelism
    Number of modules to query concurrently. Defaults to 8.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModulesFile,
    [Parameter(Mandatory)][string]$OutputFile,
    [int]$Parallelism = 8
)

$ErrorActionPreference = "Stop"
$Registry = "mcr.microsoft.com"
$MaxRetries = 4

$modules = Get-Content -Path $ModulesFile | Where-Object { $_.Trim() -ne "" }
Write-Host "Resolving latest version for $($modules.Count) modules (parallelism=$Parallelism)..."

$results = $modules | ForEach-Object -Parallel {
    $module = $_
    $repo = "bicep/$module"
    $registry = $using:Registry
    $maxRetries = $using:MaxRetries

    $tags = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $output = & oras repo tags "$registry/$repo" 2>&1
            if ($LASTEXITCODE -eq 0) { $tags = $output; break }
            Write-Warning "attempt $attempt failed listing tags for $repo`: $output"
        }
        catch {
            Write-Warning "attempt $attempt threw for $repo`: $_"
        }
        Start-Sleep -Seconds ($attempt * 2)
    }

    if (-not $tags) {
        Write-Warning "giving up on $repo after $maxRetries attempts -- skipping"
        return
    }

    # Pick the highest semantic version tag. AVM tags are plain X.Y.Z with no
    # pre-release suffixes, so [version] parses them directly; anything that
    # doesn't parse (unexpected tag format) is ignored rather than breaking
    # the whole run.
    $latest = $tags |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" } |
        ForEach-Object {
            try { [pscustomobject]@{ Raw = $_; Parsed = [version]$_ } } catch { $null }
        } |
        Where-Object { $_ -ne $null } |
        Sort-Object -Property Parsed -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        Write-Warning "no parseable version tags found for $repo -- skipping"
        return
    }

    "$module,$($latest.Raw)"
} -ThrottleLimit $Parallelism

$results | Where-Object { $_ } | Set-Content -Path $OutputFile -Encoding utf8

$lineCount = (Get-Content -Path $OutputFile | Measure-Object -Line).Lines
Write-Host "Resolved latest version for $lineCount modules -> $OutputFile"

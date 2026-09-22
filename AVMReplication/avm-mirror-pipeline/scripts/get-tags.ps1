<#
.SYNOPSIS
    For every module path in -ModulesFile, lists all published tags on
    mcr.microsoft.com and writes "module,tag" rows to -OutputFile.

.PARAMETER ModulesFile
    Path to the modules.txt produced by discover-modules.ps1.

.PARAMETER OutputFile
    Where to write the resulting module,tag CSV.

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
Write-Host "Listing tags for $($modules.Count) modules (parallelism=$Parallelism)..."

$results = $modules | ForEach-Object -Parallel {
    $module = $_
    $repo = "bicep/$module"
    $registry = $using:Registry
    $maxRetries = $using:MaxRetries

    $tags = $null
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $output = & oras repo tags "$registry/$repo" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $tags = $output
                break
            }
            Write-Warning "attempt $attempt failed listing tags for $repo`: $output"
        }
        catch {
            Write-Warning "attempt $attempt threw for $repo`: $_"
        }
        Start-Sleep -Seconds ($attempt * 2)
    }

    if (-not $tags) {
        Write-Warning "giving up on $repo after $maxRetries attempts"
        return
    }

    foreach ($tag in $tags) {
        $tag = $tag.Trim()
        if ($tag -ne "") {
            "$module,$tag"
        }
    }
} -ThrottleLimit $Parallelism

$results | Set-Content -Path $OutputFile -Encoding utf8

$lineCount = (Get-Content -Path $OutputFile | Measure-Object -Line).Lines
Write-Host "Discovered $lineCount module/tag combinations -> $OutputFile"

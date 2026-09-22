<#
.SYNOPSIS
    Installs a pinned version of the ORAS CLI (https://oras.land).

.DESCRIPTION
    ORAS is used ONLY to list tags on the public mcr.microsoft.com registry
    (read-only "oras repo tags"), so we know which version is currently the
    latest published version of each AVM module.

.PARAMETER Version
    ORAS version to install. Defaults to 1.2.2.

.PARAMETER InstallDir
    Directory to install the oras binary into.
#>
[CmdletBinding()]
param(
    [string]$Version = "1.2.2",
    [string]$InstallDir = (Join-Path ([System.IO.Path]::GetTempPath()) "oras-install")
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

if ($IsWindows) {
    $os = "windows"; $ext = "zip"; $binName = "oras.exe"
}
else {
    $os = "linux"; $ext = "tar.gz"; $binName = "oras"
}

$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
    "arm64"
}
else {
    "amd64"
}

$archiveName = "oras_${Version}_${os}_${arch}.$ext"
$url = "https://github.com/oras-project/oras/releases/download/v$Version/$archiveName"

Write-Host "Downloading ORAS $Version from $url"
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$archivePath = Join-Path $tmpDir $archiveName

Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing

if ($ext -eq "zip") {
    Expand-Archive -Path $archivePath -DestinationPath $tmpDir -Force
}
else {
    tar -xzf $archivePath -C $tmpDir
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed" }
}

$destBin = Join-Path $InstallDir $binName
Copy-Item -Path (Join-Path $tmpDir $binName) -Destination $destBin -Force
if (-not $IsWindows) { chmod +x $destBin }
Remove-Item -Recurse -Force $tmpDir

Write-Host "ORAS installed at $destBin"
& $destBin version

Write-Host "##vso[task.setvariable variable=orasInstallDir]$InstallDir"

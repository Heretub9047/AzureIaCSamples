<#
.SYNOPSIS
    Deletes specific blobs (files) and whole folders from Azure Storage accounts, driven by a CSV.

.DESCRIPTION
    The input CSV must have two columns:
        Type  - "File" or "Folder"
        URI   - Full blob URL, e.g.
                  File:   https://myaccount.blob.core.windows.net/external/dataset/file.json
                  Folder: https://myaccount.blob.core.windows.net/external/dataset/
                          (trailing slash optional)

    Rows can span multiple storage accounts and containers. Both blob (.blob.) and
    ADLS Gen2 (.dfs.) endpoints are accepted, as are sovereign cloud suffixes.

    Progress is shown on screen as each row is processed, and a CSV report is written with
    one line per blob acted on, with a Status of:
        Deleted   - blob was removed
        NotFound  - file, folder or container didn't exist (or folder was empty)
        Skipped   - row was invalid, duplicated, or blocked by a safety rule
        Failed    - delete was attempted but errored (permissions, lease, etc.)
        WhatIf    - dry run; would have been deleted

    The report is written even if the script is interrupted with Ctrl+C.

.PARAMETER CsvPath
    Path to the input CSV.

.PARAMETER ReportPath
    Where to write the report. Defaults to .\DeletionReport_<timestamp>.csv

.PARAMETER SasToken
    Use one SAS token for all accounts (needs Delete + List permissions).

.PARAMETER AccountKeys
    Hashtable of account name -> account key, e.g. @{ myaccount = '...key...' }

.PARAMETER AllowContainerRoot
    Allow a Folder row that points at a container root (deletes everything in that container).
    Blocked by default.

.PARAMETER Force
    Skip the "type YES to continue" confirmation.

.EXAMPLE
    # Dry run using your Entra ID sign-in (run Connect-AzAccount first)
    .\Remove-AzBlobsFromCsv.ps1 -CsvPath .\deletions.csv -WhatIf

.EXAMPLE
    # Real run
    .\Remove-AzBlobsFromCsv.ps1 -CsvPath .\deletions.csv

.EXAMPLE
    # Using account keys
    .\Remove-AzBlobsFromCsv.ps1 -CsvPath .\deletions.csv -AccountKeys @{ acct1 = 'key1'; acct2 = 'key2' }

.NOTES
    Requires the Az.Storage module:  Install-Module Az.Storage -Scope CurrentUser
    With Entra ID auth (default) your identity needs "Storage Blob Data Contributor" (or Owner)
    on each account/container. If blob soft delete is enabled on an account, deleted blobs
    remain recoverable for the retention period.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'EntraId')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$ReportPath = (Join-Path (Get-Location) ("DeletionReport_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))),

    [Parameter(ParameterSetName = 'Sas', Mandatory = $true)]
    [string]$SasToken,

    [Parameter(ParameterSetName = 'Key', Mandatory = $true)]
    [hashtable]$AccountKeys,

    [switch]$AllowContainerRoot,

    [switch]$Force
)

Set-StrictMode -Version Latest
$AuthMode = $PSCmdlet.ParameterSetName
$DryRun   = [bool]$WhatIfPreference

#region ---------- Setup checks ----------
if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    throw "Az.Storage module not found. Install it with: Install-Module Az.Storage -Scope CurrentUser"
}
Import-Module Az.Storage -ErrorAction Stop

if ($AuthMode -eq 'EntraId' -and -not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Host "Not signed in to Azure - launching Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount -ErrorAction Stop | Out-Null
}
#endregion

#region ---------- Helpers ----------
$Results  = [System.Collections.Generic.List[object]]::new()
$Contexts = @{}

function Add-Result {
    param($RowNumber, $Type, $Uri, $Account, $Container, $Blob, $Status, $Message)
    $Results.Add([pscustomobject]@{
        Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Row        = $RowNumber
        Type       = $Type
        SourceUri  = $Uri
        Account    = $Account
        Container  = $Container
        Blob       = $Blob
        Status     = $Status
        Message    = $Message
    })
}

function Write-Status {
    param([string]$Prefix, [string]$Text, [string]$Status)
    $colour = switch ($Status) {
        'Deleted'  { 'Green' }
        'WhatIf'   { 'Cyan' }
        'NotFound' { 'Yellow' }
        'Skipped'  { 'DarkYellow' }
        'Failed'   { 'Red' }
        default    { 'Gray' }
    }
    Write-Host ("{0} " -f $Prefix) -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-9}" -f $Status) -NoNewline -ForegroundColor $colour
    Write-Host (" {0}" -f $Text)
}

function Test-NotFound {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e.GetType().Name -match 'NotFound' -or
            $e.Message -match '\b404\b|BlobNotFound|ContainerNotFound|PathNotFound|Can not find') {
            return $true
        }
        $e = $e.InnerException
    }
    return $false
}

function ConvertFrom-BlobUri {
    # Returns @{ Account; Endpoint; Container; BlobPath } or throws
    param([string]$Uri)
    $u = [System.Uri]$Uri
    if ($u.Scheme -ne 'https' -and $u.Scheme -ne 'http') { throw "Not an http(s) URL" }

    $hostParts = $u.Host.Split('.', 3)          # account . blob|dfs . core.windows.net
    if ($hostParts.Count -lt 3 -or $hostParts[1] -notin @('blob', 'dfs')) {
        throw "Host '$($u.Host)' is not a blob/dfs storage endpoint"
    }

    $path = [System.Uri]::UnescapeDataString($u.AbsolutePath).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($path)) { throw "URL has no container" }

    $slash = $path.IndexOf('/')
    if ($slash -lt 0) { $container = $path; $blobPath = '' }
    else              { $container = $path.Substring(0, $slash); $blobPath = $path.Substring($slash + 1) }

    return @{
        Account   = $hostParts[0].ToLowerInvariant()
        Endpoint  = $hostParts[2]
        Container = $container
        BlobPath  = $blobPath
    }
}

function Get-StorageCtx {
    param([string]$Account, [string]$Endpoint)
    $key = "$Account|$Endpoint"
    if (-not $Contexts.ContainsKey($key)) {
        switch ($AuthMode) {
            'Sas' { $ctx = New-AzStorageContext -StorageAccountName $Account -SasToken $SasToken -Endpoint $Endpoint }
            'Key' {
                if (-not $AccountKeys.ContainsKey($Account)) { throw "No key supplied in -AccountKeys for account '$Account'" }
                $ctx = New-AzStorageContext -StorageAccountName $Account -StorageAccountKey $AccountKeys[$Account] -Endpoint $Endpoint
            }
            default { $ctx = New-AzStorageContext -StorageAccountName $Account -UseConnectedAccount -Endpoint $Endpoint }
        }
        $Contexts[$key] = $ctx
    }
    return $Contexts[$key]
}

function Remove-OneBlob {
    # Returns @{ Status; Message }
    param($Ctx, [string]$Container, [string]$Blob)
    if ($DryRun) { return @{ Status = 'WhatIf'; Message = 'Dry run - not deleted' } }
    try {
        Remove-AzStorageBlob -Container $Container -Blob $Blob -Context $Ctx -Force -WhatIf:$false -ErrorAction Stop
        return @{ Status = 'Deleted'; Message = '' }
    }
    catch {
        if (Test-NotFound $_) { return @{ Status = 'NotFound'; Message = 'Blob no longer exists' } }
        return @{ Status = 'Failed'; Message = $_.Exception.Message }
    }
}
#endregion

#region ---------- Load & validate CSV ----------
$rows = @(Import-Csv -Path $CsvPath)
if ($rows.Count -eq 0) { throw "CSV '$CsvPath' has no data rows." }

$headers = $rows[0].PSObject.Properties.Name
foreach ($h in 'Type', 'URI') {
    if ($headers -notcontains $h) { throw "CSV is missing the required '$h' column. Found: $($headers -join ', ')" }
}

$accounts = $rows | ForEach-Object {
    try { (ConvertFrom-BlobUri $_.URI.Trim()).Account } catch { }
} | Sort-Object -Unique

Write-Host ""
Write-Host "Azure blob deletion" -ForegroundColor White
Write-Host ("  Input      : {0}" -f (Resolve-Path $CsvPath))
Write-Host ("  Rows       : {0}" -f $rows.Count)
Write-Host ("  Accounts   : {0}" -f ($accounts -join ', '))
Write-Host ("  Auth       : {0}" -f $AuthMode)
Write-Host ("  Mode       : {0}" -f $(if ($DryRun) { 'DRY RUN (-WhatIf) - nothing will be deleted' } else { 'LIVE - blobs will be deleted' })) `
    -ForegroundColor $(if ($DryRun) { 'Cyan' } else { 'Red' })
Write-Host ("  Report     : {0}" -f $ReportPath)
Write-Host ""

if (-not $DryRun -and -not $Force) {
    $answer = Read-Host "Type YES to continue"
    if ($answer -cne 'YES') { Write-Host "Aborted." -ForegroundColor Yellow; return }
}
#endregion

#region ---------- Process ----------
$seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$total = $rows.Count
$i     = 0
$sw    = [System.Diagnostics.Stopwatch]::StartNew()

try {
    foreach ($row in $rows) {
        $i++
        $rowNum  = $i + 1   # +1 for header line, so it matches the line number in the CSV
        $typeRaw = "$($row.Type)".Trim()
        $uri     = "$($row.URI)".Trim()
        $prefix  = "[{0}/{1}]" -f $i, $total

        Write-Progress -Id 1 -Activity "Deleting from Azure Storage" `
            -Status ("Row {0} of {1}: {2}" -f $i, $total, $uri) `
            -PercentComplete ([int](($i - 1) / $total * 100))

        # --- Validate type ---
        $type = switch -Regex ($typeRaw) {
            '^(file|blob)'          { 'File' }
            '^(folder|dir|prefix)'  { 'Folder' }
            default                 { $null }
        }
        if (-not $type) {
            Add-Result $rowNum $typeRaw $uri '' '' '' 'Skipped' "Unknown Type '$typeRaw' (expected File or Folder)"
            Write-Status $prefix "$uri  (unknown type '$typeRaw')" 'Skipped'
            continue
        }

        # --- Validate URI ---
        if ([string]::IsNullOrWhiteSpace($uri)) {
            Add-Result $rowNum $type $uri '' '' '' 'Skipped' 'Empty URI'
            Write-Status $prefix "(empty URI)" 'Skipped'
            continue
        }
        try { $p = ConvertFrom-BlobUri $uri }
        catch {
            Add-Result $rowNum $type $uri '' '' '' 'Skipped' "Invalid URI: $($_.Exception.Message)"
            Write-Status $prefix "$uri  (invalid URI)" 'Skipped'
            continue
        }

        # --- Duplicates ---
        if (-not $seen.Add("$type|$uri")) {
            Add-Result $rowNum $type $uri $p.Account $p.Container $p.BlobPath 'Skipped' 'Duplicate row'
            Write-Status $prefix "$uri  (duplicate)" 'Skipped'
            continue
        }

        try { $ctx = Get-StorageCtx -Account $p.Account -Endpoint $p.Endpoint }
        catch {
            Add-Result $rowNum $type $uri $p.Account $p.Container $p.BlobPath 'Failed' "Could not create storage context: $($_.Exception.Message)"
            Write-Status $prefix "$uri  (no storage context)" 'Failed'
            continue
        }

        if ($type -eq 'File') {
            # ---------- Single file ----------
            $blobName = $p.BlobPath
            if ([string]::IsNullOrWhiteSpace($blobName) -or $blobName.EndsWith('/')) {
                Add-Result $rowNum $type $uri $p.Account $p.Container $blobName 'Skipped' 'Type is File but URI points to a folder/container'
                Write-Status $prefix "$uri  (File row points at a folder)" 'Skipped'
                continue
            }

            $exists = $false
            try {
                $null = Get-AzStorageBlob -Container $p.Container -Blob $blobName -Context $ctx -ErrorAction Stop
                $exists = $true
            }
            catch {
                if (Test-NotFound $_) {
                    Add-Result $rowNum $type $uri $p.Account $p.Container $blobName 'NotFound' 'Blob or container does not exist'
                    Write-Status $prefix $uri 'NotFound'
                }
                else {
                    Add-Result $rowNum $type $uri $p.Account $p.Container $blobName 'Failed' "Lookup failed: $($_.Exception.Message)"
                    Write-Status $prefix "$uri  ($($_.Exception.Message))" 'Failed'
                }
            }

            if ($exists) {
                $r = Remove-OneBlob -Ctx $ctx -Container $p.Container -Blob $blobName
                Add-Result $rowNum $type $uri $p.Account $p.Container $blobName $r.Status $r.Message
                $msg = if ($r.Message -and $r.Status -eq 'Failed') { "$uri  ($($r.Message))" } else { $uri }
                Write-Status $prefix $msg $r.Status
            }
        }
        else {
            # ---------- Folder ----------
            $folder = $p.BlobPath.TrimEnd('/')
            if ([string]::IsNullOrEmpty($folder) -and -not $AllowContainerRoot) {
                Add-Result $rowNum $type $uri $p.Account $p.Container '' 'Skipped' 'Folder is a container root - use -AllowContainerRoot to permit'
                Write-Status $prefix "$uri  (container root blocked)" 'Skipped'
                continue
            }
            $blobPrefix = if ($folder) { "$folder/" } else { '' }

            # List everything under the prefix (paged)
            $blobs = [System.Collections.Generic.List[object]]::new()
            $listFailed = $false
            try {
                $token = $null
                do {
                    $page = @(Get-AzStorageBlob -Container $p.Container -Prefix $blobPrefix -Context $ctx `
                                -MaxCount 5000 -ContinuationToken $token -ErrorAction Stop)
                    if ($page.Count -gt 0) {
                        $blobs.AddRange($page)
                        $token = $page[-1].ContinuationToken
                    }
                    else { $token = $null }
                } while ($token)
            }
            catch {
                $listFailed = $true
                if (Test-NotFound $_) {
                    Add-Result $rowNum $type $uri $p.Account $p.Container $blobPrefix 'NotFound' 'Container does not exist'
                    Write-Status $prefix "$uri  (container not found)" 'NotFound'
                }
                else {
                    Add-Result $rowNum $type $uri $p.Account $p.Container $blobPrefix 'Failed' "Listing failed: $($_.Exception.Message)"
                    Write-Status $prefix "$uri  ($($_.Exception.Message))" 'Failed'
                }
            }
            if ($listFailed) { continue }

            if ($blobs.Count -eq 0) {
                Add-Result $rowNum $type $uri $p.Account $p.Container $blobPrefix 'NotFound' 'Folder is empty or does not exist'
                Write-Status $prefix "$uri  (empty / not found)" 'NotFound'
                continue
            }

            Write-Status $prefix ("{0}  ({1} blob(s) found)" -f $uri, $blobs.Count) 'Info'

            # Deepest paths first, so ADLS Gen2 directory entries are emptied before they're removed
            $ordered = $blobs | Sort-Object @{ Expression = { ($_.Name -split '/').Count }; Descending = $true },
                                            @{ Expression = { $_.Name }; Descending = $true }

            $counts = @{ Deleted = 0; WhatIf = 0; NotFound = 0; Failed = 0 }
            $j = 0
            foreach ($b in $ordered) {
                $j++
                if ($j -eq 1 -or $j % 25 -eq 0 -or $j -eq $blobs.Count) {
                    Write-Progress -Id 2 -ParentId 1 -Activity "Folder: $uri" `
                        -Status ("Blob {0} of {1}: {2}" -f $j, $blobs.Count, $b.Name) `
                        -PercentComplete ([int]($j / $blobs.Count * 100))
                }
                $r = Remove-OneBlob -Ctx $ctx -Container $p.Container -Blob $b.Name
                $counts[$r.Status]++
                Add-Result $rowNum $type $uri $p.Account $p.Container $b.Name $r.Status $r.Message
                if ($r.Status -eq 'Failed') {
                    Write-Status "      " "$($b.Name)  ($($r.Message))" 'Failed'
                }
            }
            Write-Progress -Id 2 -Activity "Folder" -Completed

            # ADLS Gen2: remove the (now empty) directory entry itself, if one exists
            if ($folder -and -not $DryRun) {
                try {
                    $null = Get-AzStorageBlob -Container $p.Container -Blob $folder -Context $ctx -ErrorAction Stop
                    $r = Remove-OneBlob -Ctx $ctx -Container $p.Container -Blob $folder
                    $counts[$r.Status]++
                    Add-Result $rowNum $type $uri $p.Account $p.Container $folder $r.Status ("Directory entry. " + $r.Message).Trim()
                } catch { }  # no directory entry (flat namespace) - nothing to do
            }

            $summary = ($counts.GetEnumerator() | Where-Object { $_.Value -gt 0 } |
                        ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
            $folderStatus = if ($counts.Failed -gt 0) { 'Failed' } elseif ($DryRun) { 'WhatIf' } else { 'Deleted' }
            Write-Status "      " "folder done: $summary" $folderStatus
        }
    }
}
finally {
    Write-Progress -Id 1 -Activity "Deleting from Azure Storage" -Completed
    $sw.Stop()

    # Always write the report, even on Ctrl+C or an unexpected error
    if ($Results.Count -gt 0) {
        $Results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
    }

    Write-Host ""
    Write-Host ("Finished in {0:hh\:mm\:ss}  ({1} of {2} rows processed)" -f $sw.Elapsed, $i, $total) -ForegroundColor White
    foreach ($s in 'Deleted', 'WhatIf', 'NotFound', 'Skipped', 'Failed') {
        $n = @($Results | Where-Object Status -eq $s).Count
        if ($n -gt 0) { Write-Status "  " ("{0} blob/row result(s)" -f $n) $s }
    }
    if ($Results.Count -gt 0) { Write-Host ("Report written to: {0}" -f $ReportPath) -ForegroundColor White }
}
#endregion

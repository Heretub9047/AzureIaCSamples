<#
.SYNOPSIS
    Reads (via workaround) the current IP allow list for a Power Pages website,
    using the documented Power Platform API (powerpages namespace).

.DESCRIPTION
    The Power Platform API for Power Pages currently only publishes a POST endpoint
    ("Add Allowed IP Addresses") for this feature — there is no documented GET/List
    endpoint. However, the POST response always echoes back the FULL resulting
    IpAddressEntity[] list, not just any newly added entries.

    This script uses that behavior as a read-only mechanism: it submits an EMPTY
    IpAddresses array (adds nothing) so the response reflects the current state,
    then saves that state to a local JSON snapshot file so you can track/diff it
    over time, since the platform itself doesn't expose a public read endpoint.

    This script does not add, remove, or modify anything on the website.

    Reference:
    https://learn.microsoft.com/en-us/rest/api/power-platform/powerpages/websites/add-allowed-ip-addresses
    https://learn.microsoft.com/en-us/power-pages/admin/admin-api

.PARAMETER EnvironmentId
    The Dataverse/Power Platform environment ID that hosts the Power Pages website.

.PARAMETER WebsiteId
    The Power Pages website's unique ID (GUID). If you don't know it, omit this and
    supply -Subdomain instead; the script will look it up via Get Websites.

.PARAMETER Subdomain
    The website's subdomain, e.g. for https://contoso.powerappsportals.com this is
    "contoso". Used to resolve WebsiteId automatically if WebsiteId isn't supplied.

.PARAMETER StateFilePath
    Path to the local JSON snapshot file used to track the list between runs.
    Defaults to .\PowerPagesIPAllowList.json in the current directory.

.EXAMPLE
    Connect-AzAccount
    .\Get-PowerPagesIPAllowList.ps1 -EnvironmentId $envId -Subdomain "contoso"

.EXAMPLE
    .\Get-PowerPagesIPAllowList.ps1 -EnvironmentId $envId -WebsiteId $siteId -Verbose

.NOTES
    Requires Az.Accounts (Install-Module Az.Accounts -Scope CurrentUser) and an
    interactive sign-in via Connect-AzAccount. Per Microsoft's docs, the service
    principal (app-only) flow isn't currently available for Power Pages admin APIs —
    use an interactive/delegated user token.

    Because the empty-array submission relies on documented request/response shape
    rather than a documented GET, treat the result as best-effort. If the API
    rejects an empty array, the error from the catch block will make that clear.
#>

[CmdletBinding(DefaultParameterSetName = 'BySubdomain')]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByWebsiteId')]
    [string]$WebsiteId,

    [Parameter(Mandatory = $true, ParameterSetName = 'BySubdomain')]
    [string]$Subdomain,

    [Parameter()]
    [string]$StateFilePath = ".\PowerPagesIPAllowList.json",

    [Parameter()]
    [string]$ApiVersion = "2024-10-01"
)

# ---------------------------------------------------------------------------
# 1. Acquire an access token for the Power Platform API
# ---------------------------------------------------------------------------
try {
    $tokenObj = Get-AzAccessToken -ResourceUrl "https://api.powerplatform.com"
    $accessToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
        )
    }
    else {
        $tokenObj.Token
    }
}
catch {
    Write-Error "Failed to acquire access token. Make sure you've run Connect-AzAccount first. $_"
    return
}

$headers = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

# ---------------------------------------------------------------------------
# 2. Resolve WebsiteId from Subdomain if needed
# ---------------------------------------------------------------------------
if (-not $WebsiteId) {
    $listUri = "https://api.powerplatform.com/powerpages/environments/$EnvironmentId/websites?api-version=$ApiVersion"
    try {
        $sites = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers
    }
    catch {
        Write-Error "Failed to list websites for environment '$EnvironmentId'. $_"
        return
    }

    $match = $sites | Where-Object { $_.subdomain -eq $Subdomain }
    if (-not $match) {
        Write-Error "No website found with subdomain '$Subdomain' in environment '$EnvironmentId'."
        return
    }
    if (@($match).Count -gt 1) {
        Write-Warning "Multiple websites matched subdomain '$Subdomain'. Using the first result."
        $match = @($match)[0]
    }

    $WebsiteId = $match.id
    Write-Verbose "Resolved WebsiteId: $WebsiteId"
}

# ---------------------------------------------------------------------------
# 3. Call the API with an empty IpAddresses array (adds nothing, read-only intent)
# ---------------------------------------------------------------------------
$body = @{ IpAddresses = @() } | ConvertTo-Json -Depth 5

$uri = "https://api.powerplatform.com/powerpages/environments/$EnvironmentId/websites/$WebsiteId/ipaddressrules?api-version=$ApiVersion"

try {
    Write-Verbose "Calling $uri"
    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
}
catch {
    Write-Error "Failed to call ipaddressrules endpoint. $_"
    return
}

# ---------------------------------------------------------------------------
# 4. Persist the resulting state locally
# ---------------------------------------------------------------------------
$snapshot = [PSCustomObject]@{
    EnvironmentId = $EnvironmentId
    WebsiteId     = $WebsiteId
    Subdomain     = $Subdomain
    RetrievedOn   = (Get-Date).ToUniversalTime().ToString("o")
    IpAddresses   = $response
}

try {
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFilePath -Encoding UTF8
    Write-Verbose "Saved snapshot to $StateFilePath"
}
catch {
    Write-Warning "Fetched the list successfully, but failed to write the local snapshot file. $_"
}

# ---------------------------------------------------------------------------
# 5. Output
# ---------------------------------------------------------------------------
Write-Host "Current IP allow list for website $WebsiteId (environment $EnvironmentId):" -ForegroundColor Cyan
$response | Format-Table IpAddress, IpType, CreatedOn -AutoSize

return $response

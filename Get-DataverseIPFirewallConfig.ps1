<#
.SYNOPSIS
    Reads (via workaround) and manages the IP allow list for a Power Pages website,
    using the documented Power Platform API (powerpages namespace).

.DESCRIPTION
    The Power Platform API for Power Pages currently only publishes a POST endpoint
    ("Add Allowed IP Addresses") for this feature — there is no documented GET/List
    endpoint. However, the POST response always echoes back the FULL resulting
    IpAddressEntity[] list, not just the newly added entries. This script uses that
    behavior as a read mechanism:

      - "Get" mode: submits an empty IpAddresses array (adds nothing) so the response
        reflects the current state, then saves it to a local JSON snapshot file.
      - "Add" mode: submits the IP address(es) you specify, and updates the same
        local snapshot file with the new full state returned by the API.

    Because there's no public GET, this script also keeps a local JSON file
    (-StateFilePath) as your source of truth between runs, so you can diff changes
    over time even though the platform itself doesn't expose read access.

    Reference:
    https://learn.microsoft.com/en-us/rest/api/power-platform/powerpages/websites/add-allowed-ip-addresses
    https://learn.microsoft.com/en-us/power-pages/admin/admin-api

.PARAMETER Action
    "Get" to fetch/snapshot the current list (adds nothing).
    "Add" to add one or more new IP addresses/ranges to the list.

.PARAMETER EnvironmentId
    The Dataverse/Power Platform environment ID that hosts the Power Pages website.

.PARAMETER WebsiteId
    The Power Pages website's unique ID (GUID). If you don't know it, omit this and
    supply -Subdomain instead; the script will look it up via Get Websites.

.PARAMETER Subdomain
    The website's subdomain, e.g. for https://contoso.powerappsportals.com this is
    "contoso". Used to resolve WebsiteId automatically if WebsiteId isn't supplied.

.PARAMETER IpAddresses
    One or more IP addresses/CIDR ranges to add. Only used when -Action Add.
    IPv6 addresses are auto-detected; everything else is treated as IPv4.

.PARAMETER StateFilePath
    Path to the local JSON snapshot file used to track the list between runs.
    Defaults to .\PowerPagesIPAllowList.json in the current directory.

.EXAMPLE
    Connect-AzAccount
    .\Manage-PowerPagesIPAllowList.ps1 -Action Get -EnvironmentId $envId -Subdomain "contoso"

.EXAMPLE
    .\Manage-PowerPagesIPAllowList.ps1 -Action Add -EnvironmentId $envId -WebsiteId $siteId `
        -IpAddresses "203.0.113.10/32","2001:db8::/32"

.NOTES
    Requires Az.Accounts (Install-Module Az.Accounts -Scope CurrentUser) and an
    interactive sign-in via Connect-AzAccount. Per Microsoft's docs, the service
    principal (app-only) flow isn't currently available for Power Pages admin APIs —
    use an interactive/delegated user token.
#>

[CmdletBinding(DefaultParameterSetName = 'BySubdomain')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Get', 'Add')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByWebsiteId')]
    [string]$WebsiteId,

    [Parameter(Mandatory = $true, ParameterSetName = 'BySubdomain')]
    [string]$Subdomain,

    [Parameter()]
    [string[]]$IpAddresses,

    [Parameter()]
    [string]$StateFilePath = ".\PowerPagesIPAllowList.json",

    [Parameter()]
    [string]$ApiVersion = "2024-10-01"
)

if ($Action -eq 'Add' -and (-not $IpAddresses -or $IpAddresses.Count -eq 0)) {
    Write-Error "-IpAddresses is required when -Action Add."
    return
}

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
# 3. Build the request body
# ---------------------------------------------------------------------------
function New-IpAddressEntry {
    param([string]$Address)

    $isIPv6 = $Address -match ':'
    [PSCustomObject]@{
        IpAddress     = $Address
        IpAddressType = if ($isIPv6) { "IPv6" } else { "IPv4" }
    }
}

$entriesToSubmit = @()
if ($Action -eq 'Add') {
    $entriesToSubmit = @($IpAddresses | ForEach-Object { New-IpAddressEntry -Address $_ })
}
# For -Action Get, we submit an empty array so nothing is added, but the API
# still returns the full current list in its response.

$body = @{ IpAddresses = $entriesToSubmit } | ConvertTo-Json -Depth 5

# ---------------------------------------------------------------------------
# 4. Call the API
# ---------------------------------------------------------------------------
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
# 5. Persist the resulting full state locally
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
# 6. Output
# ---------------------------------------------------------------------------
Write-Host "Current IP allow list for website $WebsiteId (environment $EnvironmentId):" -ForegroundColor Cyan
$response | Format-Table IpAddress, IpType, CreatedOn -AutoSize

return $response

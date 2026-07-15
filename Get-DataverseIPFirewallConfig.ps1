<#
.SYNOPSIS
    Retrieves the IP firewall configuration for a Power Platform (Dataverse) environment
    using the Dataverse OData Web API.

.DESCRIPTION
    Authenticates against Microsoft Entra ID (Azure AD) using the OAuth2 client credentials
    flow with an app registration (service principal), then queries the `organizations`
    entity in Dataverse for the IP firewall related columns:

        - enableipbasedfirewallrule
        - allowediprangeforfirewall
        - enableipbasedfirewallruleinauditmode
        - allowedservicetagsforfirewall
        - allowapplicationuseraccess
        - allowmicrosofttrustedservicetags

    Reference:
    https://learn.microsoft.com/en-us/power-platform/admin/ip-firewall#enable-ip-firewall-using-the-dataverse-odata-api

.PARAMETER EnvironmentUrl
    The base URL of the Dataverse environment, e.g. https://yourorg.crm.dynamics.com

.PARAMETER TenantId
    Your Entra ID (Azure AD) tenant ID (GUID or verified domain, e.g. contoso.onmicrosoft.com)

.PARAMETER ClientId
    The Application (client) ID of an app registration that has API permission to
    Dynamics CRM / Dataverse (user_impersonation, or is set up for app-only auth) and
    has been added to the target environment as an application user with a security
    role that can read the organizations table (e.g. System Administrator).

.PARAMETER ClientSecret
    The client secret for the app registration. Passed as a SecureString.

.EXAMPLE
    $secret = Read-Host -AsSecureString "Enter client secret"
    .\Get-DataverseIPFirewallConfig.ps1 `
        -EnvironmentUrl "https://yourorg.crm.dynamics.com" `
        -TenantId "00000000-0000-0000-0000-000000000000" `
        -ClientId "11111111-1111-1111-1111-111111111111" `
        -ClientSecret $secret

.NOTES
    Requires PowerShell 5.1+ or PowerShell 7+. No external modules required
    (uses Invoke-RestMethod directly against the token endpoint and the Web API).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentUrl,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [System.Security.SecureString]$ClientSecret
)

# ---------------------------------------------------------------------------
# 1. Normalize the environment URL and derive the resource/audience URL
# ---------------------------------------------------------------------------
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$resourceUrl    = $EnvironmentUrl

Write-Verbose "Environment URL: $EnvironmentUrl"

# ---------------------------------------------------------------------------
# 2. Acquire an OAuth2 access token via client credentials flow
# ---------------------------------------------------------------------------
$plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
)

$tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

$tokenBody = @{
    client_id     = $ClientId
    client_secret = $plainSecret
    scope         = "$resourceUrl/.default"
    grant_type    = "client_credentials"
}

try {
    Write-Verbose "Requesting access token from $tokenEndpoint"
    $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    $accessToken = $tokenResponse.access_token
}
catch {
    Write-Error "Failed to acquire access token. $_"
    return
}
finally {
    # Clear the plaintext secret from memory as soon as we're done with it
    $plainSecret = $null
}

if (-not $accessToken) {
    Write-Error "No access token was returned. Check your TenantId, ClientId and ClientSecret."
    return
}

# ---------------------------------------------------------------------------
# 3. Query the `organizations` entity for the IP firewall settings
# ---------------------------------------------------------------------------
$selectFields = @(
    "organizationid",
    "name",
    "enableipbasedfirewallrule",
    "allowediprangeforfirewall",
    "enableipbasedfirewallruleinauditmode",
    "allowedservicetagsforfirewall",
    "allowapplicationuseraccess",
    "allowmicrosofttrustedservicetags"
) -join ","

$apiUri = "$EnvironmentUrl/api/data/v9.2/organizations?`$select=$selectFields"

$headers = @{
    "Authorization"    = "Bearer $accessToken"
    "Accept"           = "application/json"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
}

try {
    Write-Verbose "Querying $apiUri"
    $response = Invoke-RestMethod -Method Get -Uri $apiUri -Headers $headers
}
catch {
    Write-Error "Failed to query the Dataverse Web API. $_"
    return
}

if (-not $response.value -or $response.value.Count -eq 0) {
    Write-Warning "No organization record was returned. Verify the environment URL and that the app user has access."
    return
}

$org = $response.value[0]

# ---------------------------------------------------------------------------
# 4. Build a friendly summary object
# ---------------------------------------------------------------------------
$firewallConfig = [PSCustomObject]@{
    OrganizationId               = $org.organizationid
    OrganizationName             = $org.name
    IPFirewallEnabled            = $org.enableipbasedfirewallrule
    AllowedIPRanges              = $org.allowediprangeforfirewall
    AuditOnlyModeEnabled         = $org.enableipbasedfirewallruleinauditmode
    AllowedServiceTags           = $org.allowedservicetagsforfirewall
    AllowAllApplicationUsers     = $org.allowapplicationuseraccess
    AllowMicrosoftTrustedServices = $org.allowmicrosofttrustedservicetags
}

$firewallConfig | Format-List

return $firewallConfig

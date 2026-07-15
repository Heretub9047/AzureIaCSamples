<#
.SYNOPSIS
    Retrieves the IP firewall configuration for a Power Platform (Dataverse) environment
    using the Dataverse OData Web API.

.DESCRIPTION
    Authenticates against Microsoft Entra ID (Azure AD) using your interactively
    signed-in Az PowerShell session (Connect-AzAccount), then queries the
    `organizations` entity in Dataverse for the IP firewall related columns:

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

.EXAMPLE
    Install-Module Az.Accounts -Scope CurrentUser
    Connect-AzAccount
    .\Get-DataverseIPFirewallConfig.ps1 `
        -EnvironmentUrl "https://yourorg.crm.dynamics.com" `
        -TenantId "00000000-0000-0000-0000-000000000000"

.NOTES
    Requires the Az.Accounts module (Install-Module Az.Accounts -Scope CurrentUser)
    and an active interactive session via Connect-AzAccount. The signed-in user must
    have access to the target Dataverse environment (e.g. System Administrator role).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentUrl,

    [Parameter(Mandatory = $true)]
    [string]$TenantId
)

# ---------------------------------------------------------------------------
# 1. Normalize the environment URL and derive the resource/audience URL
# ---------------------------------------------------------------------------
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$resourceUrl    = $EnvironmentUrl

Write-Verbose "Environment URL: $EnvironmentUrl"

# ---------------------------------------------------------------------------
# 2. Acquire an OAuth2 access token via the signed-in Az context (interactive)
# ---------------------------------------------------------------------------
# Requires: Install-Module Az.Accounts -Scope CurrentUser
# and an interactive sign-in: Connect-AzAccount

try {
    Write-Verbose "Requesting access token for $resourceUrl via Get-AzAccessToken"
    $tokenObj = Get-AzAccessToken -ResourceUrl $resourceUrl -TenantId $TenantId

    if ($tokenObj.Token -is [System.Security.SecureString]) {
        # Newer Az.Accounts versions return a SecureString
        $accessToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
        )
    }
    else {
        # Older Az.Accounts versions return a plain string
        $accessToken = $tokenObj.Token
    }
}
catch {
    Write-Error "Failed to acquire access token via Get-AzAccessToken. Make sure you've run Connect-AzAccount first. $_"
    return
}

if (-not $accessToken) {
    Write-Error "No access token was returned. Check your TenantId and that you're signed in with Connect-AzAccount."
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

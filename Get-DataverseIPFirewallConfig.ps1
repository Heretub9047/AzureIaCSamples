<#
.SYNOPSIS
    Tests service principal (client credentials) authentication against the
    Power Platform API and confirms whether the token is authorized to call it.

.DESCRIPTION
    Acquires a token via the OAuth2 client credentials flow (app-only, no user
    context) and calls a low-risk, well-documented endpoint (List Environments)
    to confirm the service principal is correctly consented and registered as
    a Power Platform management application.

    Note: Per Microsoft's Power Pages admin API documentation, the service
    principal flow isn't currently available for the `powerpages` namespace
    specifically (Add/list IP address rules, etc.) — even if this script
    succeeds, the ipaddressrules endpoint from the earlier script may still
    require a delegated (user) token. This script is here to isolate that.

.PARAMETER TenantId
    Your Entra ID tenant ID.

.PARAMETER ClientId
    The Application (client) ID of your app registration.

.PARAMETER ClientSecret
    The client secret for the app registration, as a SecureString.

.EXAMPLE
    $secret = Read-Host -AsSecureString "Enter client secret"
    .\Test-PowerPlatformApiServicePrincipal.ps1 -TenantId $tenantId -ClientId $clientId -ClientSecret $secret

.NOTES
    Prerequisites (one-time, done by a tenant admin):
      1. App registration has an Application permission granted (with admin
         consent) to the "Power Platform API" resource (appId 8578e004-a5c6-46e7-913e-12f58912df43).
      2. The app is registered as a Power Platform management application:
         New-PowerAppManagementApp -ApplicationId <your-client-id>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [System.Security.SecureString]$ClientSecret,

    [Parameter()]
    [string]$ApiVersion = "2024-10-01"
)

# ---------------------------------------------------------------------------
# 1. Acquire a token via client credentials flow
# ---------------------------------------------------------------------------
$plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
)

$tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

$tokenBody = @{
    client_id     = $ClientId
    client_secret = $plainSecret
    scope         = "https://api.powerplatform.com/.default"
    grant_type    = "client_credentials"
}

try {
    Write-Verbose "Requesting token from $tokenEndpoint"
    $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    $accessToken = $tokenResponse.access_token
}
catch {
    Write-Error "Failed to acquire token. Check ClientId/ClientSecret/TenantId, and that the app has API permissions to 'Power Platform API'. $_"
    return
}
finally {
    $plainSecret = $null
}

if (-not $accessToken) {
    Write-Error "No access token returned."
    return
}

# ---------------------------------------------------------------------------
# 2. Decode and display the token's claims for diagnostic purposes
# ---------------------------------------------------------------------------
$parts = $accessToken.Split('.')
$payload = $parts[1].Replace('-', '+').Replace('_', '/')
switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
$claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json

Write-Host "Token claims:" -ForegroundColor Cyan
$claims | Select-Object aud, appid, tid, roles | Format-List

# ---------------------------------------------------------------------------
# 3. Test call: List Environments (tenant-level, low risk, well documented)
# ---------------------------------------------------------------------------
$headers = @{ Authorization = "Bearer $accessToken" }
$uri = "https://api.powerplatform.com/environmentmanagement/environments?api-version=$ApiVersion"

try {
    Write-Verbose "Calling $uri"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    Write-Host "`nSUCCESS - service principal is authorized against api.powerplatform.com" -ForegroundColor Green
    $response.value | Select-Object -First 5 name, properties | Format-Table -AutoSize
}
catch {
    Write-Host "`nFAILED calling api.powerplatform.com" -ForegroundColor Red
    Write-Error $_
    Write-Host "`nIf this is a 403, confirm:" -ForegroundColor Yellow
    Write-Host "  1. Admin consent was granted for the app's Power Platform API permission" -ForegroundColor Yellow
    Write-Host "  2. New-PowerAppManagementApp -ApplicationId $ClientId has been run by a tenant admin" -ForegroundColor Yellow
    return
}

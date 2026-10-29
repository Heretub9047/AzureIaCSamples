<#
.SYNOPSIS
    Prices Azure compute resources (AUD) at Public, MCA, 1-year RI and 3-year RI rates.

.DESCRIPTION
    Reads a text file of Azure resource IDs (one per line, '#' comments allowed) and writes a CSV.

    Supported resource types
      Microsoft.Compute/virtualMachines
      Microsoft.Sql/servers                (expanded to its databases + elastic pools)
      Microsoft.Sql/servers/databases
      Microsoft.Sql/servers/elasticPools
      Microsoft.Web/serverfarms            (App Service Plans)
      Microsoft.Fabric/capacities

    Price sources
      Public  : Azure Retail Prices API (https://prices.azure.com), currencyCode=AUD
      MCA     : Cost Management Price Sheet API
                POST /providers/Microsoft.Billing/billingAccounts/{ba}/billingProfiles/{bp}
                     /providers/Microsoft.CostManagement/pricesheets/default/download?api-version=2023-09-01
                Rates are looked up by meterId (the same meterId the Retail API returns).
                Enterprise Agreement subscriptions (no billing profile) use the subscription-scope
                Consumption price sheet instead: GET /subscriptions/{id}/providers/Microsoft.Consumption/
                pricesheets/default?api-version=2023-05-01. No billing account/profile name is needed.
                The "MCA Price per Month" column holds the agreement (MCA or EA) rate either way.
      1Y / 3Y : Reservation Order Calculate API
                POST /providers/Microsoft.Capacity/calculatePrice?api-version=2022-11-01
                (billingPlan = Upfront so the response is the whole-term total, divided by 12/36).
                There is NO fallback to Retail/public pricing: if a reservation cannot be calculated
                (call refused, SKU not in the catalog, not eligible) the price is 0 and the Comments
                column gives the reason.
    Savings plans are never considered.

    All "per month" values are for the full SKU count, using -HoursPerMonth (default 730).
    SKU Count means: VM = 1, App Service Plan = instances, SQL = vCores (DTU = 1), Fabric = 1 (priced per CU).
    VMs are always priced compute-only (the base/Linux meter): no Windows or other OS licence cost
    is included in any column, regardless of the VM's OS or Azure Hybrid Benefit setting.

.PARAMETER InputFile            Text file of resource IDs.
.PARAMETER OutputFile           CSV path (default: AzurePricing_<timestamp>.csv in the current folder).
.PARAMETER BillingAccountName   Optional. Override the MCA billing account name (auto-detected per subscription).
.PARAMETER BillingProfileName   Optional. Override the MCA billing profile name.
.PARAMETER SkipMca              Don't download the price sheet.
.PARAMETER SkipReservations     Don't price reservations.

.EXAMPLE
    Connect-AzAccount
    .\Get-AzurePricing.ps1 -InputFile .\resources.txt -OutputFile .\pricing.csv

.NOTES
    Requires Az.Accounts. Needs Reader on the resources; billing profile Reader (or similar) for the
    price sheet; reservation price calculation needs a user who can purchase reservations on the
    billing scope (otherwise the reservation price is 0 with the reason in Comments).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [string]$OutputFile = (Join-Path (Get-Location) ("AzurePricing_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date))),
    [string]$BillingAccountName,
    [string]$BillingProfileName,
    [int]$HoursPerMonth = 730,
    [switch]$SkipMca,
    [switch]$SkipReservations
)

$ErrorActionPreference = 'Stop'
$script:Hours      = [double]$HoursPerMonth
$script:Days       = $script:Hours / 24
$script:RetailCache  = @{}
$script:SubNameCache = @{}
$script:CatalogCache = @{}
$script:BillingCache = @{}
$script:BillingErr   = @{}
$script:MeterIdRegex = '^[0-9a-fA-F-]{36}$'

function Norm([string]$s) { ($s -replace '[\s_\-]', '').ToLowerInvariant() }

#region ARM helpers
function Invoke-Arm {
    param([string]$Path, [string]$Method = 'GET', [string]$Payload)
    $p = @{ Path = $Path; Method = $Method }
    if ($Payload) { $p.Payload = $Payload }
    for ($i = 0; $i -lt 4; $i++) {
        $r = Invoke-AzRestMethod @p
        if ($r.StatusCode -eq 429 -or $r.StatusCode -ge 500) { Start-Sleep -Seconds (3 * ($i + 1)); continue }
        return $r
    }
    $r
}

function Get-ArmJson([string]$Path) {
    $r = Invoke-Arm -Path $Path
    if ($r.StatusCode -ge 400) { throw "GET $Path failed ($($r.StatusCode)): $($r.Content)" }
    $r.Content | ConvertFrom-Json
}

function Split-ResourceId([string]$Id) {
    $p = $Id.Trim().Trim('/') -split '/'
    if ($p.Count -lt 8 -or $p[0] -ne 'subscriptions' -or $p[2] -ne 'resourceGroups' -or $p[4] -ne 'providers') { return $null }
    $types = @(); for ($i = 6; $i -lt $p.Count; $i += 2) { $types += $p[$i] }
    [pscustomobject]@{
        Id   = '/' + ($p -join '/')
        Sub  = $p[1]
        RG   = $p[3]
        Type = ('{0}/{1}' -f $p[5], ($types -join '/')).ToLowerInvariant()
        Name = $p[-1]
    }
}

function Get-SubscriptionName([string]$SubId) {
    if (-not $script:SubNameCache.ContainsKey($SubId)) {
        $n = $SubId
        try { $n = (Get-ArmJson "/subscriptions/${SubId}?api-version=2022-12-01").displayName } catch { }
        $script:SubNameCache[$SubId] = $n
    }
    $script:SubNameCache[$SubId]
}
#endregion

#region Retail prices
function Get-RetailItems([string]$Filter) {
    if ($script:RetailCache.ContainsKey($Filter)) { return $script:RetailCache[$Filter] }
    $u = 'https://prices.azure.com/api/retail/prices?currencyCode=AUD&api-version=2023-01-01-preview&$filter=' + [uri]::EscapeDataString($Filter)
    $items = New-Object System.Collections.Generic.List[object]
    while ($u) {
        $r = $null
        for ($i = 0; $i -lt 4 -and -not $r; $i++) {
            try { $r = Invoke-RestMethod -Uri $u -Method Get }
            catch { if ($i -eq 3) { throw }; Start-Sleep -Seconds (2 * ($i + 1)) }
        }
        foreach ($it in $r.Items) { $items.Add($it) }
        $u = $r.NextPageLink
    }
    $script:RetailCache[$Filter] = $items.ToArray()
    $script:RetailCache[$Filter]
}
#endregion

#region Pricing model per resource type
function New-Pricing {
    [pscustomobject]@{
        Sku = ''; Count = 1; Os = ''
        Components  = @()      # Public/MCA: @{Item (retail item); Factor (units->month); Qty}
        ResType     = $null    # Microsoft.Capacity reservedResourceType, $null = no API call
        ResGuess    = ''       # SKU name to send if the catalog lookup fails
        ResPattern  = ''       # regex on Norm(catalog sku name)
        ResQty      = 1
        ResFallback = @()      # Retail reservation lookup: @{MeterId; Qty}
        NoResReason = 'no reservation is available for this SKU'
        Uplift      = 0.0      # monthly licence uplift added to reservation prices
        Supported   = $true
        Notes       = (New-Object System.Collections.Generic.List[string])
    }
}

function Get-VmPricing([string]$Loc, [string]$Size, [string]$OsType, [string]$License) {
    $p = New-Pricing; $p.Sku = $Size; $p.Os = $OsType
    $p.ResType = 'VirtualMachines'; $p.ResGuess = $Size; $p.ResPattern = '^' + (Norm $Size) + '$'
    $items = @(Get-RetailItems "serviceName eq 'Virtual Machines' and armRegionName eq '$Loc' and armSkuName eq '$Size' and priceType eq 'Consumption'") |
        Where-Object { "$($_.skuName) $($_.meterName)" -notmatch 'Spot|Low Priority' -and $_.productName -notmatch 'Cloud Services' }
    $lin = $items | Where-Object { $_.productName -notmatch 'Windows' } | Select-Object -First 1
    if (-not $lin) { $p.Supported = $false; $p.Notes.Add("No retail price found for $Size in $Loc"); return $p }
    # Compute only: always the base (non-Windows) meter, so no OS licence is ever included
    $p.Components  = @([pscustomobject]@{ Item = $lin; Factor = $script:Hours; Qty = 1 })
    $p.ResFallback = @([pscustomobject]@{ MeterId = $lin.meterId; Qty = 1 })
    if ($OsType -eq 'Windows') { $p.Notes.Add('Windows licence excluded: compute-only pricing for all columns') }
    $p
}

function Get-AspPricing([string]$Loc, [string]$SkuName, [int]$Capacity, [bool]$LinuxPlan) {
    $p = New-Pricing; $p.Sku = $SkuName; $p.Count = $Capacity; $p.Os = $(if ($LinuxPlan) { 'Linux' } else { 'Windows' })
    $p.ResType = 'AppService'; $p.ResGuess = $SkuName; $p.ResQty = $Capacity; $p.ResPattern = (Norm $SkuName) + '$'
    $n = Norm $SkuName
    $item = @(Get-RetailItems "serviceName eq 'Azure App Service' and armRegionName eq '$Loc' and priceType eq 'Consumption'") |
        Where-Object { (Norm $_.skuName) -eq $n -and (($_.productName -like '*Linux') -eq $LinuxPlan) -and $_.meterName -notmatch 'Stamp' } |
        Select-Object -First 1
    if (-not $item) { $p.Supported = $false; $p.Notes.Add("No retail price found for App Service SKU $SkuName ($($p.Os)) in $Loc"); return $p }
    $p.Components  = @([pscustomobject]@{ Item = $item; Factor = $script:Hours; Qty = $Capacity })
    $p.ResFallback = @([pscustomobject]@{ MeterId = $item.meterId; Qty = $Capacity })
    if ($SkuName -match '^I') { $p.Notes.Add('Isolated plan: App Service Environment stamp fee not included') }
    $p
}

function Get-FabricPricing([string]$Loc, [string]$SkuName) {
    $p = New-Pricing; $p.Sku = $SkuName
    if ($SkuName -notmatch '^F(\d+)$') { $p.Supported = $false; $p.Notes.Add("Unrecognised Fabric SKU $SkuName"); return $p }
    $cu = [int]$Matches[1]
    # Capacity-unit meter (same meterId carries the PAYG rate and the reservation rate)
    $meter = '3b246afa-33ae-51c8-ae5e-bf9fe8f8010b'
    $item = @(Get-RetailItems "meterId eq '$meter' and armRegionName eq '$Loc' and priceType eq 'Consumption'") | Select-Object -First 1
    if (-not $item) { $p.Supported = $false; $p.Notes.Add("No Fabric capacity price in $Loc"); return $p }
    $p.Components  = @([pscustomobject]@{ Item = $item; Factor = $script:Hours; Qty = $cu })
    $p.ResType = 'Fabric'; $p.ResGuess = $SkuName; $p.ResQty = $cu; $p.ResPattern = 'fabric'
    $p.Notes.Add("Priced as $cu CU x 24x7 (pause/scale not modelled)")
    $p
}

function Get-SqlPricing([string]$Loc, $Sku, [bool]$ZoneRedundant, [bool]$IsPool, [string]$License) {
    $p = New-Pricing; $p.Sku = [string]$Sku.name
    $cap = [int]$Sku.capacity
    if ($p.Sku -match '^(GP_S|GP|BC|HS)_([A-Za-z]+\d*)(?:_(\d+))?$') {
        $code = $Matches[1]; $fam = $Matches[2]
        if (-not $cap -and $Matches[3]) { $cap = [int]$Matches[3] }
        if ($code -eq 'GP_S') { $p.Supported = $false; $p.Notes.Add('Serverless is usage-billed; not priced'); return $p }
        $tierText = @{ GP = 'General Purpose'; BC = 'Business Critical'; HS = 'Hyperscale' }[$code]
        $p.Count = $cap; $p.ResQty = $cap
        $items = @(Get-RetailItems "serviceName eq 'SQL Database' and armRegionName eq '$Loc' and priceType eq 'Consumption' and contains(productName,'$tierText') and contains(productName,'Compute') and contains(productName,'$fam')") |
            Where-Object { $_.productName -notmatch 'Serverless|Secondary|Free|Named' -and $_.meterName -match 'vCore' }
        $base = $items | Where-Object { $_.skuName -eq 'vCore' } | Select-Object -First 1
        $zr   = $items | Where-Object { $_.skuName -eq 'vCore ZR' } | Select-Object -First 1
        if (-not $base) { $p.Supported = $false; $p.Notes.Add("No retail vCore price for $($p.Sku) in $Loc"); return $p }
        $comps = @([pscustomobject]@{ Item = $base; Factor = $script:Hours; Qty = $cap })
        $fb    = @([pscustomobject]@{ MeterId = $base.meterId; Qty = $cap })
        if ($ZoneRedundant -and $zr) {
            $comps += [pscustomobject]@{ Item = $zr; Factor = $script:Hours; Qty = $cap }
            $fb    += [pscustomobject]@{ MeterId = $zr.meterId; Qty = $cap }
            $p.Notes.Add('Zone redundant: Public/MCA include the ZR meter; reservation price excludes the ZR surcharge')
        }
        $p.Components = $comps; $p.ResFallback = $fb
        $p.ResType = 'SqlDatabases'; $p.ResGuess = "SQLDB_${code}_Compute_$fam"
        $p.ResPattern = 'sqldb' + $code.ToLower() + 'compute' + $fam.ToLower() + '$'
        if ($License -eq 'BasePrice') { $p.Notes.Add('Azure Hybrid Benefit (BasePrice) set: licence-included rate shown') }
        return $p
    }
    if (-not $IsPool -and $Sku.tier -in 'Basic', 'Standard', 'Premium') {
        $item = @(Get-RetailItems "serviceName eq 'SQL Database' and armRegionName eq '$Loc' and priceType eq 'Consumption' and productName eq 'SQL Database Single $($Sku.tier)'") |
            Where-Object { $_.skuName -eq $p.Sku -and $_.meterName -notmatch 'Secondary' } | Select-Object -First 1
        if ($item) {
            $p.Components = @([pscustomobject]@{ Item = $item; Factor = $script:Days; Qty = 1 })
            $p.NoResReason = 'DTU-based databases are not eligible for reservations'; return $p
        }
    }
    $p.Supported = $false; $p.Notes.Add("SQL SKU '$($p.Sku)' / tier '$($Sku.tier)' is not supported by this script"); $p
}
#endregion

#region Reservations
function Get-ReservationSkuName($P, [string]$SubId, [string]$Loc) {
    $key = "$SubId|$($P.ResType)|$Loc"
    if (-not $script:CatalogCache.ContainsKey($key)) {
        $cat = @()
        try {
            $cat = @((Get-ArmJson "/subscriptions/$SubId/providers/Microsoft.Capacity/catalogs?api-version=2022-11-01&reservedResourceType=$($P.ResType)&location=$Loc").value)
        } catch { }
        $script:CatalogCache[$key] = $cat
    }
    $hit = $script:CatalogCache[$key] | Where-Object { (Norm $_.name) -match $P.ResPattern } | Select-Object -First 1
    if ($hit) { $hit.name } else { $P.ResGuess }
}

# Returns @{ Monthly = [double] or $null; Note = string }
function Get-ReservationMonthly($P, [string]$SubId, [string]$Loc, [int]$Years) {
    if (-not $P.Supported) { return @{ Monthly = $null; Note = "${Years}Y reservation not calculated: resource could not be priced" } }
    if (-not $P.ResType)   { return @{ Monthly = $null; Note = "${Years}Y reservation not calculated: $($P.NoResReason)" } }
    $months = 12 * $Years
    $why = ''
    if ($true) {
        try {
            $sku  = Get-ReservationSkuName $P $SubId $Loc
            $body = @{
                sku        = @{ name = $sku }
                location   = $Loc
                properties = @{
                    reservedResourceType = $P.ResType
                    billingScopeId       = "/subscriptions/$SubId"
                    term                 = "P${Years}Y"
                    billingPlan          = 'Upfront'
                    quantity             = [int]$P.ResQty
                    displayName          = 'price-calc'
                    appliedScopeType     = 'Shared'
                }
            }
            if ($P.ResType -eq 'VirtualMachines') { $body.properties.reservedResourceProperties = @{ instanceFlexibility = 'On' } }
            $r = Invoke-Arm -Method POST -Path '/providers/Microsoft.Capacity/calculatePrice?api-version=2022-11-01' -Payload ($body | ConvertTo-Json -Depth 6)
            if ($r.StatusCode -eq 200) {
                $t = ($r.Content | ConvertFrom-Json).properties.billingCurrencyTotal
                if ($t -and $null -ne $t.amount) {
                    $note = ''
                    if ($t.currencyCode -ne 'AUD') { $note = "${Years}Y reservation returned in $($t.currencyCode), not AUD" }
                    return @{ Monthly = ([double]$t.amount / $months) + $P.Uplift; Note = $note }
                }
                $why = 'calculatePrice returned no total'
            } else {
                $m = try { ($r.Content | ConvertFrom-Json).error.message } catch { $r.Content }
                $why = "calculatePrice $($r.StatusCode): $m"
            }
        } catch { $why = $_.Exception.Message }
    }
    @{ Monthly = $null; Note = "${Years}Y reservation not calculated: $why" }
}
#endregion

#region MCA price sheet
function Get-BillingScope([string]$SubId) {
    if ($BillingAccountName) { return @{ Account = $BillingAccountName; Profile = $BillingProfileName } }
    if (-not $script:BillingCache.ContainsKey($SubId)) {
        $res = $null
        try {
            $bp = (Get-ArmJson "/subscriptions/$SubId/providers/Microsoft.Billing/billingProperty/default?api-version=2020-05-01").properties
            $res = @{ Account = ($bp.billingAccountId -split '/')[-1]; Profile = ($bp.billingProfileId -split '/')[-1] }
            if (-not $res.Account) { $res = $null }   # EA: account present, no billing profile
        } catch { $script:BillingErr[$SubId] = $_.Exception.Message }
        $script:BillingCache[$SubId] = $res
    }
    $script:BillingCache[$SubId]
}

# Subscription-scope price sheet (Microsoft.Consumption) - the Enterprise Agreement route; needs no billing profile.
# unitPrice is per unitOfMeasure (e.g. "100 Hours"), so it is divided by that leading quantity to get a per-unit rate.
function Get-SubscriptionPriceMap([string]$SubId, $Meters) {
    $map = @{}; $cur = ''
    $path = "/subscriptions/$SubId/providers/Microsoft.Consumption/pricesheets/default?api-version=2023-05-01&`$top=1000"
    while ($path) {
        $j = Get-ArmJson $path
        foreach ($r in $j.properties.pricesheets) {
            $mid = "$($r.meterId)".ToLowerInvariant()
            if (-not $Meters.Contains($mid) -or $map.ContainsKey($mid)) { continue }
            $div = 1.0
            if ("$($r.unitOfMeasure)" -match '^\s*([\d,]*\.?\d+)') { $div = [double]($Matches[1] -replace ',', ''); if ($div -le 0) { $div = 1.0 } }
            $map[$mid] = [double]$r.unitPrice / $div
            if (-not $cur) { $cur = $r.currencyCode }
        }
        if ($map.Count -ge $Meters.Count) { break }
        $next = $j.properties.nextLink
        $path = if ($next) { ([uri]$next).PathAndQuery } else { $null }
    }
    if ($map.Count -eq 0) { throw 'subscription price sheet returned no matching meters' }
    @{ Prices = $map; Currency = $cur }
}

function Get-McaPriceMap([string]$Ba, [string]$Bp, $Meters) {
    $path = "/providers/Microsoft.Billing/billingAccounts/$Ba/billingProfiles/$Bp/providers/Microsoft.CostManagement/pricesheets/default/download?api-version=2023-09-01"
    $r = Invoke-Arm -Method POST -Path $path
    if ($r.StatusCode -notin 200, 202) { throw "Price sheet request failed ($($r.StatusCode)): $($r.Content)" }
    $url = $null
    if ($r.StatusCode -eq 200) { $url = ($r.Content | ConvertFrom-Json).downloadUrl }
    else {
        $loc  = [string]$r.Headers.Location
        $wait = 30; try { $wait = [math]::Min(30, [math]::Max(5, [int]$r.Headers.RetryAfter.Delta.TotalSeconds)) } catch { }
        for ($i = 0; $i -lt 40 -and -not $url; $i++) {
            Write-Host "  waiting for price sheet ($($i + 1))..."
            Start-Sleep -Seconds $wait
            $q = Invoke-AzRestMethod -Method GET -Uri $loc
            if ($q.StatusCode -eq 200) { $url = ($q.Content | ConvertFrom-Json).downloadUrl }
            elseif ($q.StatusCode -ne 202) { throw "Price sheet poll failed ($($q.StatusCode)): $($q.Content)" }
        }
    }
    if (-not $url) { throw 'Timed out waiting for the price sheet' }

    $dir = Join-Path ([IO.Path]::GetTempPath()) ("pricesheet_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $file = Join-Path $dir 'download.bin'
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        $head = [IO.File]::ReadAllBytes($file)[0..1]
        $csvs = @()
        if ($head[0] -eq 0x50 -and $head[1] -eq 0x4B) {
            Rename-Item $file 'download.zip'
            Expand-Archive -Path (Join-Path $dir 'download.zip') -DestinationPath (Join-Path $dir 'x')
            $csvs = @(Get-ChildItem (Join-Path $dir 'x') -Recurse -Filter *.csv).FullName
        } else { Rename-Item $file 'sheet.csv'; $csvs = @(Join-Path $dir 'sheet.csv') }

        $map = @{}; $cur = ''
        foreach ($csv in $csvs) {
            $cols = $null
            Import-Csv -Path $csv | ForEach-Object {
                if (-not $cols) {
                    $cols = @{}
                    foreach ($n in $_.PSObject.Properties.Name) { $cols[(Norm $n)] = $n }
                }
                $mid = "$($_.($cols['meterid']))".ToLowerInvariant()
                if (-not $Meters.Contains($mid)) { return }
                if ($cols['pricetype'] -and $_.($cols['pricetype']) -notin 'Consumption', '') { return }
                if ($cols['tierminimumunits'] -and $_.($cols['tierminimumunits']) -and [double]$_.($cols['tierminimumunits']) -gt 0) { return }
                if ($map.ContainsKey($mid)) { return }
                $div = 1.0
                if ($cols['unitofmeasure'] -and "$($_.($cols['unitofmeasure']))" -match '^\s*([\d,]*\.?\d+)') { $div = [double]($Matches[1] -replace ',', ''); if ($div -le 0) { $div = 1.0 } }
                $map[$mid] = [double]::Parse("$($_.($cols['unitprice']))", [Globalization.CultureInfo]::InvariantCulture) / $div
                $cc = if ($cols['billingcurrency']) { $cols['billingcurrency'] } elseif ($cols['currency']) { $cols['currency'] } else { $cols['currencycode'] }
                if ($cc -and -not $cur) { $cur = $_.$cc }
            }
        }
        @{ Prices = $map; Currency = $cur }
    } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
#endregion

#region Resource discovery
function Get-Entities([string]$RawId) {
    $id = Split-ResourceId $RawId
    $base = @{ ResourceId = $RawId.Trim(); RG = ''; Sub = ''; Name = ''; Loc = '' }
    if (-not $id) { return ,@([pscustomobject]@{ Err = "Not a valid resource ID: $RawId"; ResourceId = $RawId; Sub = ''; RG = ''; Name = ''; Loc = ''; Pricing = $null }) }

    $out = New-Object System.Collections.Generic.List[object]
    function Add-Entity($rid, $name, $loc, $pricing) {
        $out.Add([pscustomobject]@{ Err = $null; ResourceId = $rid; Sub = $id.Sub; RG = $id.RG; Name = $name; Loc = $loc; Pricing = $pricing })
    }
    $norm = { param($l) ("$l").ToLowerInvariant() -replace '\s', '' }

    switch ($id.Type) {
        'microsoft.compute/virtualmachines' {
            $r = Get-ArmJson "$($id.Id)?api-version=2024-03-01"
            $loc = & $norm $r.location
            Add-Entity $id.Id $id.Name $loc (Get-VmPricing $loc $r.properties.hardwareProfile.vmSize $r.properties.storageProfile.osDisk.osType $r.properties.licenseType)
        }
        'microsoft.web/serverfarms' {
            $r = Get-ArmJson "$($id.Id)?api-version=2023-12-01"
            $loc = & $norm $r.location
            $linux = ($r.kind -match 'linux') -or ($r.properties.reserved -eq $true)
            $cap = [int]$r.sku.capacity; if ($cap -lt 1) { $cap = [int]$r.properties.numberOfWorkers }; if ($cap -lt 1) { $cap = 1 }
            Add-Entity $id.Id $id.Name $loc (Get-AspPricing $loc $r.sku.name $cap $linux)
        }
        'microsoft.fabric/capacities' {
            $r = Get-ArmJson "$($id.Id)?api-version=2023-11-01"
            $loc = & $norm $r.location
            Add-Entity $id.Id $id.Name $loc (Get-FabricPricing $loc $r.sku.name)
        }
        'microsoft.sql/servers' {
            $dbs   = @((Get-ArmJson "$($id.Id)/databases?api-version=2023-08-01").value)
            $pools = @((Get-ArmJson "$($id.Id)/elasticPools?api-version=2023-08-01").value)
            foreach ($d in $dbs) {
                if ($d.name -eq 'master' -or $d.properties.elasticPoolId) { continue }
                $loc = & $norm $d.location
                Add-Entity $d.id "$($id.Name)/$($d.name)" $loc (Get-SqlPricing $loc $d.sku ([bool]$d.properties.zoneRedundant) $false $d.properties.currentSku.name)
            }
            foreach ($pl in $pools) {
                $loc = & $norm $pl.location
                Add-Entity $pl.id "$($id.Name)/$($pl.name)" $loc (Get-SqlPricing $loc $pl.sku ([bool]$pl.properties.zoneRedundant) $true $pl.properties.licenseType)
            }
            if ($out.Count -eq 0) {
                $out.Add([pscustomobject]@{ Err = 'SQL server has no billable databases or elastic pools'; ResourceId = $id.Id; Sub = $id.Sub; RG = $id.RG; Name = $id.Name; Loc = ''; Pricing = $null })
            }
        }
        { $_ -in 'microsoft.sql/servers/databases', 'microsoft.sql/servers/elasticpools' } {
            $isPool = $id.Type -like '*elasticpools'
            $r = Get-ArmJson "$($id.Id)?api-version=2023-08-01"
            $loc = & $norm $r.location
            $parts = $id.Id.Trim('/') -split '/'
            $lic = if ($isPool) { $r.properties.licenseType } else { $r.properties.currentSku.name }
            $pr = Get-SqlPricing $loc $r.sku ([bool]$r.properties.zoneRedundant) $isPool $lic
            if (-not $isPool -and $r.properties.elasticPoolId) { $pr.Notes.Add('Database is in an elastic pool; its own SKU is not billed separately') }
            Add-Entity $id.Id ("{0}/{1}" -f $parts[7], $parts[9]) $loc $pr
        }
        default {
            $out.Add([pscustomobject]@{ Err = "Unsupported resource type '$($id.Type)'"; ResourceId = $id.Id; Sub = $id.Sub; RG = $id.RG; Name = $id.Name; Loc = ''; Pricing = $null })
        }
    }
    , $out.ToArray()
}
#endregion

#region Main
if (-not (Get-Module -ListAvailable Az.Accounts)) { throw 'Az.Accounts module is required: Install-Module Az.Accounts' }
if (-not (Get-AzContext)) { throw 'Not signed in. Run Connect-AzAccount first.' }
if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile" }

$ids = Get-Content $InputFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -Unique
Write-Host "Resolving $($ids.Count) resource ID(s) and retail prices..."
$entities = New-Object System.Collections.Generic.List[object]
foreach ($rid in $ids) {
    try { foreach ($e in (Get-Entities $rid)) { $entities.Add($e) } }
    catch {
        Write-Warning "$rid : $($_.Exception.Message)"
        $s = Split-ResourceId $rid
        $entities.Add([pscustomobject]@{ Err = $_.Exception.Message; ResourceId = $rid; Sub = $s.Sub; RG = $s.RG; Name = $s.Name; Loc = ''; Pricing = $null })
    }
}

# MCA price sheets (one per billing profile)
$mca = @{}   # sub -> @{Prices; Currency} or error string
if (-not $SkipMca) {
    $meters = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $entities) { if ($e.Pricing) { foreach ($c in $e.Pricing.Components) { [void]$meters.Add($c.Item.meterId.ToLowerInvariant()) } } }
    $sheets = @{}
    foreach ($sub in ($entities | Where-Object { $_.Pricing -and $_.Pricing.Components.Count } | ForEach-Object Sub | Select-Object -Unique)) {
        $scope = Get-BillingScope $sub
        $isMca = $scope -and $scope.Profile
        # MCA: one price sheet per billing profile. EA / other: subscription-scope price sheet, shared per billing account.
        $key = if ($isMca) { "mca|$($scope.Account)|$($scope.Profile)" } elseif ($scope -and $scope.Account) { "ea|$($scope.Account)" } else { "sub|$sub" }
        if (-not $sheets.ContainsKey($key)) {
            try {
                if ($isMca) {
                    Write-Host "Downloading MCA price sheet for billing profile $($scope.Profile)..."
                    $sheets[$key] = Get-McaPriceMap $scope.Account $scope.Profile $meters
                } else {
                    Write-Host "No billing profile (EA/other agreement). Reading subscription-scope price sheet via $sub..."
                    $sheets[$key] = Get-SubscriptionPriceMap $sub $meters
                }
            } catch { $sheets[$key] = "Agreement price not available: $($_.Exception.Message)" }
        }
        $mca[$sub] = $sheets[$key]
    }
}

Write-Host 'Pricing...'
$rows = foreach ($e in $entities) {
    $row = [ordered]@{
        'Resource ID'                    = $e.ResourceId
        'Resource Name'                  = $e.Name
        'Resource Group Name'            = $e.RG
        'Subscription Name'              = $(if ($e.Sub) { Get-SubscriptionName $e.Sub } else { '' })
        'Subscription ID'                = $e.Sub
        'Location'                       = $e.Loc
        'Operating System'               = ''
        'SKU'                            = ''
        'SKU Count'                      = ''
        'MCA Price per Month'            = 'N/A'
        'Public Price per Month'         = 'N/A'
        '1 Year Reservation Price Per Month' = 0
        '3 Year Reservation Price Per Month' = 0
        'Notes'                          = ''
        'Comments'                       = ''
    }
    $notes = New-Object System.Collections.Generic.List[string]
    $comments = New-Object System.Collections.Generic.List[string]
    if ($e.Err) { $notes.Add($e.Err) }
    $p = $e.Pricing
    if ($p) {
        $row['Operating System'] = $p.Os; $row['SKU'] = $p.Sku; $row['SKU Count'] = $p.Count
        foreach ($n in $p.Notes) { $notes.Add($n) }
        if ($p.Supported -and $p.Components.Count) {
            $pub = 0.0; foreach ($c in $p.Components) { $pub += $c.Item.retailPrice * $c.Factor * $c.Qty }
            $row['Public Price per Month'] = [math]::Round($pub, 2)

            if (-not $SkipMca) {
                $m = $mca[$e.Sub]
                if ($m -is [string]) { $notes.Add($m) }
                elseif ($m) {
                    $tot = 0.0; $ok = $true
                    foreach ($c in $p.Components) {
                        $k = $c.Item.meterId.ToLowerInvariant()
                        if ($m.Prices.ContainsKey($k)) { $tot += $m.Prices[$k] * $c.Factor * $c.Qty } else { $ok = $false }
                    }
                    if ($ok) {
                        $row['MCA Price per Month'] = [math]::Round($tot, 2)
                        if ($m.Currency -and $m.Currency -ne 'AUD') { $notes.Add("MCA price sheet currency is $($m.Currency), not AUD") }
                    } else { $notes.Add('Meter not found in MCA price sheet') }
                }
            }
        }
    }
    if (-not $SkipReservations) {
        foreach ($y in 1, 3) {
            if ($p) { $res = Get-ReservationMonthly $p $e.Sub $e.Loc $y }
            else    { $res = @{ Monthly = $null; Note = "${y}Y reservation not calculated: resource could not be priced" } }
            if ($null -ne $res.Monthly) {
                $row["$y Year Reservation Price Per Month"] = [math]::Round($res.Monthly, 2)
                if ($res.Note) { $notes.Add($res.Note) }
            } else {
                $row["$y Year Reservation Price Per Month"] = 0
                $comments.Add($res.Note)
            }
        }
    }
    $row['Notes'] = $notes -join '; '
    $row['Comments'] = $comments -join '; '
    [pscustomobject]$row
}

$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $(@($rows).Count) row(s) to $OutputFile"
#endregion

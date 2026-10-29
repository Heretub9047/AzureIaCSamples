<#
.SYNOPSIS
    Prices Azure compute resources (AUD) at Public, agreement (EA/MCA), 1-year RI and 3-year RI rates.

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
      MCA     : (column name kept) the agreement rate from your EA/MCA price sheet CSV, supplied with
                -PriceSheetCsv. Expected columns: EnrollmentNumber, MeterId, MeterName, MeterType,
                MeterCategory, MeterSubCategory, ServiceFamily, Product, SkuID, ProductID, MeterRegion,
                UnitOfMeasure, PartNumber, EffectiveStartDate, EffectiveEndDate, UnitPrice, BasePrice,
                MarketPrice, CurrencyCode, IncludedQuantity, OfferId, Term, PriceType
                (only MeterId and UnitPrice are required). Rows are matched on MeterId - the same meterId the
                Retail API returns. UnitPrice is per UnitOfMeasure (e.g. "100 Hours"), so it is divided by that
                quantity. Reservation rows (PriceType/Term) are ignored. The file is streamed and only rows for
                the meters your resources need are kept, so large sheets load quickly. No price sheet API calls.
      1Y / 3Y : Reservation Order Calculate API
                POST /providers/Microsoft.Capacity/calculatePrice?api-version=2022-11-01
                (billingPlan = Upfront so the response is the whole-term total, divided by 12/36).
                There is NO fallback to Retail/public pricing: if a reservation cannot be calculated
                (call refused, SKU not in the catalog, not eligible) the price is 0 and the Comments
                column gives the reason.
    Savings plans are never considered.

    The CSV is a point-in-time export (e.g. October 2026); the effective date range found in it is printed.
    Nothing is cached on disk: retail prices and reservation quotes are looked up live on every run. Within a
    single run, repeated retail lookups, subscription names and reservation catalogs are reused from memory.

    All "per month" values are for the full SKU count, using -HoursPerMonth (default 730).
    SKU Count means: VM = 1, App Service Plan = instances, SQL = vCores (DTU = 1), Fabric = 1 (priced per CU).
    VMs are always priced compute-only (the base/Linux meter): no Windows or other OS licence cost
    is included in any column, regardless of the VM's OS or Azure Hybrid Benefit setting.

.PARAMETER InputFile            Text file of resource IDs.
.PARAMETER PriceSheetCsv        EA/MCA price sheet CSV export (prompted for if omitted, unless -SkipMca).
.PARAMETER OutputFile           CSV path (default: AzurePricing_<timestamp>.csv in the current folder).
.PARAMETER SkipMca              Don't use the price sheet CSV (agreement column shows N/A).
.PARAMETER SkipReservations     Don't price reservations.

.EXAMPLE
    .\Get-AzurePricing.ps1 -InputFile .\resources.txt -PriceSheetCsv .\pricesheet_oct2026.csv -OutputFile .\pricing.csv

.NOTES
    Requires Az.Accounts and an interactive sign-in. Needs Reader on the resources; reservation price
    calculation needs a user who can purchase reservations on the billing scope (otherwise the reservation
    price is 0 with the reason in Comments).
#>
[CmdletBinding()]
param(
    [string]$InputFile,             # prompted for if omitted
    [string]$PriceSheetCsv,         # EA/MCA price sheet CSV; prompted for if omitted
    [string]$TenantId,              # sign in to / switch to this tenant
    [switch]$UseDeviceAuthentication, # device-code sign-in instead of a browser window
    [switch]$ForceLogin,            # always prompt for sign-in, even if a session already exists
    [switch]$SignOutWhenDone,       # Disconnect-AzAccount when finished
    [switch]$NonInteractive,        # no prompts (needs -InputFile, -PriceSheetCsv and an existing session)
    [string]$OutputFile = (Join-Path (Get-Location) ("AzurePricing_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date))),
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

function Norm([string]$s) { ($s -replace '[\s_\-]', '').ToLowerInvariant() }

# MeterRegion values in the price sheet CSV that represent the Australian Azure regions (the only ones in scope)
$script:CsvRegions = @('AU Central', 'AU Central 2', 'AU East', 'AU Southeast')
$script:ArmRegions = @('australiacentral', 'australiacentral2', 'australiaeast', 'australiasoutheast')


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

#region Agreement price sheet (CSV export)
# Splits one CSV line into fields (handles "quoted, fields" and "" escapes). Lines without quotes take the fast path.
function Split-CsvLine([string]$Line) {
    if ($Line.IndexOf('"') -lt 0) { return $Line.Split(',') }
    $f = New-Object System.Collections.Generic.List[string]
    $sb = New-Object Text.StringBuilder; $q = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($q) {
            if ($c -eq '"') { if ($i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '"') { [void]$sb.Append('"'); $i++ } else { $q = $false } }
            else { [void]$sb.Append($c) }
        } elseif ($c -eq '"') { $q = $true }
        elseif ($c -eq ',') { $f.Add($sb.ToString()); [void]$sb.Clear() }
        else { [void]$sb.Append($c) }
    }
    $f.Add($sb.ToString())
    $f.ToArray()
}

# Reads the EA/MCA price sheet CSV (streamed, so large files are fine) and keeps one rate per wanted meterId.
#   UnitPrice is per UnitOfMeasure (e.g. "100 Hours"), so it is divided by that leading quantity -> rate per single unit.
#   Reservation / savings-plan rows (PriceType or Term set) are ignored.
#   If a meter has several rows, the row with the lowest IncludedQuantity wins, then the latest EffectiveStartDate.
function Import-PriceSheetCsv([string]$Path, $Meters) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $reader = New-Object IO.StreamReader($Path, $true)
    try {
        $hdr = $reader.ReadLine()
        if (-not $hdr) { throw "Price sheet CSV is empty: $Path" }
        $ix = @{}; $names = Split-CsvLine $hdr
        for ($i = 0; $i -lt $names.Count; $i++) { $ix[(Norm $names[$i])] = $i }
        foreach ($need in 'meterid', 'unitprice') { if (-not $ix.ContainsKey($need)) { throw "Price sheet CSV has no '$need' column (found: $($names -join ', '))" } }
        $iMeter = $ix['meterid']; $iPrice = $ix['unitprice']
        $iUom   = if ($ix.ContainsKey('unitofmeasure'))      { $ix['unitofmeasure'] }      else { -1 }
        $iType  = if ($ix.ContainsKey('pricetype'))          { $ix['pricetype'] }          else { -1 }
        $iTerm  = if ($ix.ContainsKey('term'))               { $ix['term'] }               else { -1 }
        $iInc   = if ($ix.ContainsKey('includedquantity'))   { $ix['includedquantity'] }   else { -1 }
        $iStart = if ($ix.ContainsKey('effectivestartdate')) { $ix['effectivestartdate'] } else { -1 }
        $iEnd   = if ($ix.ContainsKey('effectiveenddate'))   { $ix['effectiveenddate'] }   else { -1 }
        $iCur   = if ($ix.ContainsKey('currencycode'))       { $ix['currencycode'] }       else { -1 }
        $iEnr   = if ($ix.ContainsKey('enrollmentnumber'))   { $ix['enrollmentnumber'] }   else { -1 }
        $iReg   = if ($ix.ContainsKey('meterregion'))       { $ix['meterregion'] }       else { -1 }
        $maxIx  = (@($iMeter, $iPrice, $iUom, $iType, $iTerm, $iInc, $iStart, $iEnd, $iCur, $iEnr, $iReg) | Measure-Object -Maximum).Maximum

        $best = @{}; $cur = ''; $enr = New-Object 'System.Collections.Generic.HashSet[string]'
        $first = $null; $last = $null
        $n = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Length -eq 0) { continue }
            $n++
            if ($n % 250000 -eq 0) { Write-Host ("  price sheet CSV: {0:N0} rows read, {1}/{2} meters found, {3:N0}s" -f $n, $best.Count, $Meters.Count, $sw.Elapsed.TotalSeconds) }
            $f = Split-CsvLine $line
            if ($f.Count -le $maxIx) { continue }
            $mid = $f[$iMeter].Trim().ToLowerInvariant()
            if (-not $Meters.Contains($mid)) { continue }
            # Only the Australian regions matter; rows with a blank region (global meters) are kept
            if ($iReg -ge 0 -and $f[$iReg].Trim() -and $f[$iReg].Trim() -notin $script:CsvRegions) { continue }
            if ($iType -ge 0 -and $f[$iType] -match 'reserv|savings') { continue }
            if ($iTerm -ge 0 -and $f[$iTerm].Trim() -and $f[$iTerm].Trim() -notmatch '^(0|none|n/?a)$') { continue }

            $price = 0.0
            if (-not [double]::TryParse($f[$iPrice], [Globalization.NumberStyles]::Float, $inv, [ref]$price)) { continue }
            $div = 1.0
            if ($iUom -ge 0 -and $f[$iUom] -match '^\s*([\d,]*\.?\d+)') { $div = [double]($Matches[1] -replace ',', ''); if ($div -le 0) { $div = 1.0 } }
            $inc = 0.0
            if ($iInc -ge 0 -and $f[$iInc]) { [void][double]::TryParse($f[$iInc], [Globalization.NumberStyles]::Float, $inv, [ref]$inc) }
            $start = [datetime]::MinValue
            if ($iStart -ge 0 -and $f[$iStart]) { [void][datetime]::TryParse($f[$iStart], $inv, [Globalization.DateTimeStyles]::None, [ref]$start) }

            $old = $best[$mid]
            if ($old -and ($inc -gt $old.Inc -or ($inc -eq $old.Inc -and $start -le $old.Start))) { continue }
            $best[$mid] = @{ Price = $price / $div; Inc = $inc; Start = $start }

            if (-not $cur -and $iCur -ge 0) { $cur = $f[$iCur].Trim() }
            if ($iEnr -ge 0 -and $f[$iEnr]) { [void]$enr.Add($f[$iEnr].Trim()) }
            if ($start -gt [datetime]::MinValue) {
                if (-not $first -or $start -lt $first) { $first = $start }
                $e2 = [datetime]::MinValue
                if ($iEnd -ge 0 -and [datetime]::TryParse($f[$iEnd], $inv, [Globalization.DateTimeStyles]::None, [ref]$e2) -and (-not $last -or $e2 -gt $last)) { $last = $e2 }
            }
        }
        $prices = @{}; foreach ($k in $best.Keys) { $prices[$k] = $best[$k].Price }
        @{ Prices = $prices; Currency = $cur; RowsRead = $n; Enrollments = @($enr); From = $first; To = $last }
    } finally { $reader.Dispose() }
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

# Interactive sign-in: uses your own account (browser or device-code prompt); no stored credentials or secrets.
$ctx = Get-AzContext
$login = @{}
if ($TenantId) { $login.Tenant = $TenantId }
if ($UseDeviceAuthentication) { $login.UseDeviceAuthentication = $true }
if ($ForceLogin -or -not $ctx -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)) {
    Write-Host 'Sign in to Azure when prompted...'
    [void](Connect-AzAccount @login)
    $ctx = Get-AzContext
}
if (-not $ctx) { throw 'Sign-in failed or was cancelled.' }
Write-Host ("Signed in as {0} (tenant {1})" -f $ctx.Account.Id, $ctx.Tenant.Id)
if (-not $NonInteractive) {
    if ((Read-Host 'Continue with this account? [Y/n]') -match '^\s*n') { throw 'Cancelled by user.' }
}


if (-not $InputFile) {
    if ($NonInteractive) { throw '-InputFile is required with -NonInteractive.' }
    $InputFile = (Read-Host 'Path to text file of Azure resource IDs').Trim('"').Trim()
}
if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile" }
if (-not $SkipMca) {
    if (-not $PriceSheetCsv) {
        if ($NonInteractive) { throw '-PriceSheetCsv is required with -NonInteractive (or use -SkipMca).' }
        $PriceSheetCsv = (Read-Host 'Path to EA/MCA price sheet CSV').Trim('"').Trim()
    }
    $PriceSheetCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PriceSheetCsv)   # .NET needs an absolute path
    if (-not (Test-Path -LiteralPath $PriceSheetCsv)) { throw "Price sheet CSV not found: $PriceSheetCsv" }
}
if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('OutputFile')) {
    $o = (Read-Host "Output CSV path [$OutputFile]").Trim('"').Trim()
    if ($o) { $OutputFile = $o }
}

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

# Agreement (EA/MCA) rates come from the price sheet CSV, filtered to the meters these resources use
$agreement = $null
if (-not $SkipMca) {
    $meters = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $entities) { if ($e.Pricing) { foreach ($c in $e.Pricing.Components) { [void]$meters.Add($c.Item.meterId.ToLowerInvariant()) } } }
    Write-Host "Reading price sheet CSV for $($meters.Count) meter(s): $PriceSheetCsv"
    $agreement = Import-PriceSheetCsv $PriceSheetCsv $meters
    Write-Host ("  {0:N0} rows read, {1} meter(s) matched; effective {2:yyyy-MM-dd} to {3:yyyy-MM-dd}; currency {4}; enrollment(s) {5}" -f
        $agreement.RowsRead, $agreement.Prices.Count, $agreement.From, $agreement.To, $agreement.Currency, ($agreement.Enrollments -join ','))
    if ($agreement.Enrollments.Count -gt 1) { Write-Warning 'Price sheet CSV contains more than one enrollment number; the best-matching row per meter is used.' }
}

foreach ($e in $entities) { if ($e.Loc -and $e.Loc -notin $script:ArmRegions) { Write-Warning "$($e.Name) is in '$($e.Loc)', outside the Australian regions (AU Central, AU Central 2, AU East, AU Southeast); agreement prices may be missing." } }

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
                $m = $agreement
                if ($m -is [string]) { $notes.Add($m) }
                elseif ($m) {
                    $tot = 0.0; $ok = $true
                    foreach ($c in $p.Components) {
                        $k = $c.Item.meterId.ToLowerInvariant()
                        if ($m.Prices.ContainsKey($k)) { $tot += $m.Prices[$k] * $c.Factor * $c.Qty } else { $ok = $false }
                    }
                    if ($ok) {
                        $row['MCA Price per Month'] = [math]::Round($tot, 2)
                        if ($m.Currency -and $m.Currency -ne 'AUD') { $notes.Add("Price sheet currency is $($m.Currency), not AUD") }
                    } else { $notes.Add('Meter not found in the price sheet CSV') }
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
if ($SignOutWhenDone) { [void](Disconnect-AzAccount); Write-Host 'Signed out.' }
#endregion

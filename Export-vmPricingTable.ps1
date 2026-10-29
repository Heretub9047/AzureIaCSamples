<#
.SYNOPSIS
    Builds a VM price table (per 730 hours) from an EA/MCA price sheet CSV.

.DESCRIPTION
    Reads the price sheet CSV (streamed, so very large files are fine) and writes a CSV with one row per
    VM SKU and location:

      VM SKU | Location | Unit Price per 730 hours | Base Price per 730 hours | Market Price per 730 hours

    Columns used from the price sheet: MeterCategory, MeterSubCategory, MeterName, Product, MeterRegion,
    UnitOfMeasure, UnitPrice, BasePrice, MarketPrice, IncludedQuantity, EffectiveStartDate, Term, PriceType.
    No Azure sign-in or API calls are needed.

    * Only rows in MeterCategory 'Virtual Machines' and in the -Regions locations are kept.
    * Compute only: Windows, Spot, Low Priority, Cloud Services and Dedicated Host meters are skipped, and so
      are reservation rows (Term / PriceType).
    * Prices are per UnitOfMeasure ("1 Hour", "10 Hours", "100 Hours" ...), so each is divided by that
      quantity to get a per-hour price and then multiplied by -Hours (default 730).
    * VM SKU is derived from MeterName: "D2s v5" -> Standard_D2s_v5. A meter covering several sizes
      ("D2 v3/D2s v3") produces one row per size.
    * If a SKU/location has several rows, the one with the lowest IncludedQuantity, then the latest
      EffectiveStartDate, is used.

    Reservations (columns "1 Year Reservation cost per 730 hours" / "3 Year ..."):
    * Come from the Reservation Order Calculate API (POST /providers/Microsoft.Capacity/calculatePrice,
      api-version 2022-11-01, billingPlan Upfront). The whole-term total is divided by 12 / 36 months to give
      the monthly cost, scaled to -Hours (730 = one month). Quantity 1, compute only, shared scope.
    * Needs an interactive Azure sign-in (your own account). The reservable-size catalog is read once per
      region, so calculatePrice is only called for sizes/terms that are actually offered.
    * There is no fallback to retail/public pricing: if a reservation cannot be calculated the value is 0 and
      the Comments column says why. Use -SkipReservations for the price sheet columns only (no sign-in).

.PARAMETER PriceSheetCsv  Price sheet CSV (prompted for if omitted).
.PARAMETER OutputFile     Output CSV (default: VmPriceTable_<timestamp>.csv in the current folder).
.PARAMETER Regions        MeterRegion values to keep (default: AU Central, AU Central 2, AU East, AU Southeast).
.PARAMETER Hours          Hours the prices are scaled to (default 730).

.EXAMPLE
    .\Export-VmPriceTable.ps1 -PriceSheetCsv .\pricesheet_oct2026.csv -OutputFile .\vm_prices.csv
#>
[CmdletBinding()]
param(
    [string]$PriceSheetCsv,
    [string]$OutputFile = (Join-Path (Get-Location) ("VmPriceTable_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date))),
    [string[]]$Regions = @('AU Central', 'AU Central 2', 'AU East', 'AU Southeast'),
    [int]$Hours = 730,
    [switch]$SkipReservations,      # leave the reservation columns out (no Azure sign-in needed)
    [string]$SubscriptionId,        # billing scope for reservation quotes; default: the signed-in context's subscription
    [string]$TenantId,
    [switch]$UseDeviceAuthentication,
    [switch]$ForceLogin,
    [switch]$NonInteractive,        # no "continue with this account?" prompt
    [switch]$SignOutWhenDone
)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

function Norm([string]$s) { ($s -replace '[\s_\-]', '').ToLowerInvariant() }

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

if (-not $PriceSheetCsv) { $PriceSheetCsv = (Read-Host 'Path to price sheet CSV').Trim('"').Trim() }
# .NET file APIs resolve relative paths against the process directory, so make the paths absolute
$PriceSheetCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PriceSheetCsv)
$OutputFile    = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
if (-not (Test-Path -LiteralPath $PriceSheetCsv)) { throw "Price sheet CSV not found: $PriceSheetCsv" }

$reader = New-Object IO.StreamReader($PriceSheetCsv, $true)
$best = @{}
try {
    $hdr = $reader.ReadLine()
    if (-not $hdr) { throw "Price sheet CSV is empty: $PriceSheetCsv" }
    $ix = @{}; $names = Split-CsvLine $hdr
    for ($i = 0; $i -lt $names.Count; $i++) { $ix[(Norm $names[$i])] = $i }
    foreach ($need in 'metercategory', 'metername', 'meterregion', 'unitofmeasure', 'unitprice', 'baseprice', 'marketprice') {
        if (-not $ix.ContainsKey($need)) { throw "Price sheet CSV has no '$need' column (found: $($names -join ', '))" }
    }
    $iCat = $ix['metercategory']; $iName = $ix['metername']; $iReg = $ix['meterregion']; $iUom = $ix['unitofmeasure']
    $iUnit = $ix['unitprice']; $iBase = $ix['baseprice']; $iMkt = $ix['marketprice']
    $iSub   = if ($ix.ContainsKey('metersubcategory'))  { $ix['metersubcategory'] }  else { -1 }
    $iProd  = if ($ix.ContainsKey('product'))           { $ix['product'] }           else { -1 }
    $iInc   = if ($ix.ContainsKey('includedquantity'))  { $ix['includedquantity'] }  else { -1 }
    $iStart = if ($ix.ContainsKey('effectivestartdate')){ $ix['effectivestartdate'] }else { -1 }
    $iTerm  = if ($ix.ContainsKey('term'))              { $ix['term'] }              else { -1 }
    $iType  = if ($ix.ContainsKey('pricetype'))         { $ix['pricetype'] }         else { -1 }
    $maxIx  = (@($iCat, $iName, $iReg, $iUom, $iUnit, $iBase, $iMkt, $iSub, $iProd, $iInc, $iStart, $iTerm, $iType) | Measure-Object -Maximum).Maximum
    $skip = 'Windows|Spot|Low Priority|Cloud Services|Dedicated Host'

    $n = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($line.Length -eq 0) { continue }
        $n++
        if ($n % 250000 -eq 0) { Write-Host ("  {0:N0} rows read, {1} SKU/location prices found, {2:N0}s" -f $n, $best.Count, $sw.Elapsed.TotalSeconds) }
        $f = Split-CsvLine $line
        if ($f.Count -le $maxIx) { continue }
        if ($f[$iCat].Trim() -ne 'Virtual Machines') { continue }
        $region = $f[$iReg].Trim()
        if ($region -notin $Regions) { continue }
        if ($iType -ge 0 -and $f[$iType] -match 'reserv|savings') { continue }
        if ($iTerm -ge 0 -and $f[$iTerm].Trim() -and $f[$iTerm].Trim() -notmatch '^(0|none|n/?a)$') { continue }
        $text = "$($f[$iName]) $(if ($iSub -ge 0) { $f[$iSub] }) $(if ($iProd -ge 0) { $f[$iProd] })"
        if ($text -match $skip) { continue }
        if ($f[$iUom] -notmatch '^\s*([\d,]*\.?\d+)?\s*Hours?\s*$') { continue }   # hourly meters only
        $qty = 1.0; if ($Matches[1]) { $qty = [double]($Matches[1] -replace ',', ''); if ($qty -le 0) { $qty = 1.0 } }

        $unit = 0.0; $base = 0.0; $mkt = 0.0
        if (-not [double]::TryParse($f[$iUnit], [Globalization.NumberStyles]::Float, $inv, [ref]$unit)) { continue }
        [void][double]::TryParse($f[$iBase], [Globalization.NumberStyles]::Float, $inv, [ref]$base)
        [void][double]::TryParse($f[$iMkt],  [Globalization.NumberStyles]::Float, $inv, [ref]$mkt)
        $inc = 0.0; if ($iInc -ge 0 -and $f[$iInc]) { [void][double]::TryParse($f[$iInc], [Globalization.NumberStyles]::Float, $inv, [ref]$inc) }
        $start = [datetime]::MinValue
        if ($iStart -ge 0 -and $f[$iStart]) { [void][datetime]::TryParse($f[$iStart], $inv, [Globalization.DateTimeStyles]::None, [ref]$start) }

        # "D2 v3/D2s v3" -> one SKU each; "D2s v5" -> Standard_D2s_v5
        foreach ($part in $f[$iName].Split('/')) {
            $p = $part.Trim()
            if (-not $p) { continue }
            $sku = 'Standard_' + ($p -replace '\s+', '_')
            $key = "$sku|$region"
            $old = $best[$key]
            if ($old -and ($inc -gt $old.Inc -or ($inc -eq $old.Inc -and $start -le $old.Start))) { continue }
            $best[$key] = @{ Sku = $sku; Region = $region; Inc = $inc; Start = $start
                             Unit = $unit * $Hours / $qty; Base = $base * $Hours / $qty; Market = $mkt * $Hours / $qty }
        }
    }
    Write-Host ("Read {0:N0} rows in {1:N0}s" -f $n, $sw.Elapsed.TotalSeconds)
} finally { $reader.Dispose() }

if ($best.Count -eq 0) { throw "No Virtual Machines rows found for: $($Regions -join ', '). Check the MeterRegion / MeterCategory values in the CSV." }

#region Reservations (Microsoft.Capacity API)
$script:ArmRegion = @{ 'AU Central' = 'australiacentral'; 'AU Central 2' = 'australiacentral2'; 'AU East' = 'australiaeast'; 'AU Southeast' = 'australiasoutheast' }

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

# Reservable VM sizes for a region: normalised name -> @{ Name; Terms }. $null if the catalog could not be read.
function Get-VmCatalog([string]$Sub, [string]$ArmRegion) {
    $r = Invoke-Arm -Path "/subscriptions/$Sub/providers/Microsoft.Capacity/catalogs?api-version=2022-11-01&reservedResourceType=VirtualMachines&location=$ArmRegion"
    if ($r.StatusCode -ne 200) { Write-Warning "VM reservation catalog for $ArmRegion failed ($($r.StatusCode)): $($r.Content)"; return $null }
    $cat = @{}
    foreach ($c in @(($r.Content | ConvertFrom-Json).value)) { if ($c.name) { $cat[(Norm $c.name)] = @{ Name = $c.name; Terms = @($c.terms) } } }
    $cat
}

# Returns @{ Monthly = [double] or $null; Note = string }. Whole-term upfront total / months = cost per month.
function Get-VmReservationMonthly([string]$Sub, [string]$Sku, [string]$ArmRegion, [int]$Years) {
    $body = @{
        sku        = @{ name = $Sku }
        location   = $ArmRegion
        properties = @{
            reservedResourceType       = 'VirtualMachines'
            billingScopeId             = "/subscriptions/$Sub"
            term                       = "P${Years}Y"
            billingPlan                = 'Upfront'
            quantity                   = 1
            displayName                = 'price-calc'
            appliedScopeType           = 'Shared'
            reservedResourceProperties = @{ instanceFlexibility = 'On' }
        }
    }
    try {
        $r = Invoke-Arm -Method POST -Path '/providers/Microsoft.Capacity/calculatePrice?api-version=2022-11-01' -Payload ($body | ConvertTo-Json -Depth 6)
        if ($r.StatusCode -eq 200) {
            $t = ($r.Content | ConvertFrom-Json).properties.billingCurrencyTotal
            if ($t -and $null -ne $t.amount) {
                $note = ''; if ($t.currencyCode -ne 'AUD') { $note = "${Years}Y reservation returned in $($t.currencyCode), not AUD" }
                return @{ Monthly = [double]$t.amount / (12 * $Years); Note = $note }
            }
            return @{ Monthly = $null; Note = "${Years}Y reservation not calculated: calculatePrice returned no total" }
        }
        $m = try { ($r.Content | ConvertFrom-Json).error.message } catch { $r.Content }
        @{ Monthly = $null; Note = "${Years}Y reservation not calculated: calculatePrice $($r.StatusCode): $m" }
    } catch { @{ Monthly = $null; Note = "${Years}Y reservation not calculated: $($_.Exception.Message)" } }
}
#endregion

$res = @{}   # "sku|region" -> @{ 1 = @{Monthly;Note}; 3 = @{...} }
if (-not $SkipReservations) {
    if (-not (Get-Module -ListAvailable Az.Accounts)) { throw 'Az.Accounts module is required for reservation prices: Install-Module Az.Accounts (or use -SkipReservations)' }
    # Interactive sign-in with your own account; no stored credentials or secrets.
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
    if (-not $NonInteractive -and (Read-Host 'Continue with this account? [Y/n]') -match '^\s*n') { throw 'Cancelled by user.' }
    $sub = if ($SubscriptionId) { $SubscriptionId } elseif ($ctx.Subscription) { $ctx.Subscription.Id } else { $null }
    if (-not $sub) { throw 'No subscription available for reservation quotes: pass -SubscriptionId.' }

    $catalogs = @{}
    foreach ($rg in ($best.Values | ForEach-Object Region | Select-Object -Unique)) {
        $arm = $script:ArmRegion[$rg]
        if ($arm) { $catalogs[$rg] = Get-VmCatalog $sub $arm }
    }
    $items = @($best.Values | Sort-Object { $_.Sku }, { $_.Region })
    $i = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($it in $items) {
        $i++
        if ($i % 25 -eq 0 -or $i -eq 1) { Write-Host ("  reservations {0}/{1} ({2:N0}s)" -f $i, $items.Count, $sw.Elapsed.TotalSeconds) }
        $arm = $script:ArmRegion[$it.Region]; $cat = $catalogs[$it.Region]
        $entry = @{}
        foreach ($y in 1, 3) {
            if (-not $arm) { $entry[$y] = @{ Monthly = $null; Note = "${y}Y reservation not calculated: no Azure region mapping for '$($it.Region)'" }; continue }
            $name = $it.Sku
            if ($cat) {
                $hit = $cat[(Norm $it.Sku)]
                if (-not $hit) { $entry[$y] = @{ Monthly = $null; Note = "${y}Y reservation not calculated: size not in the VM reservation catalog for $arm" }; continue }
                if ($hit.Terms.Count -and "P${y}Y" -notin $hit.Terms) { $entry[$y] = @{ Monthly = $null; Note = "${y}Y reservation not calculated: no ${y}-year term offered for this size" }; continue }
                $name = $hit.Name
            }
            $entry[$y] = Get-VmReservationMonthly $sub $name $arm $y
        }
        $res["$($it.Sku)|$($it.Region)"] = $entry
    }
    if ($SignOutWhenDone) { [void](Disconnect-AzAccount); Write-Host 'Signed out.' }
}

$col = "per $Hours hours"
$rows = $best.Values | Sort-Object { $_.Sku }, { $_.Region } | ForEach-Object {
    $o = [ordered]@{
        'VM SKU'                          = $_.Sku
        'Location'                        = $_.Region
        "Unit Price $col"                 = [math]::Round($_.Unit, 2)
        "Base Price $col"                 = [math]::Round($_.Base, 2)
        "Market Price $col"               = [math]::Round($_.Market, 2)
    }
    if (-not $SkipReservations) {
        $e = $res["$($_.Sku)|$($_.Region)"]; $c = New-Object System.Collections.Generic.List[string]
        foreach ($y in 1, 3) {
            $q = $e[$y]
            # reservation total is for the term; cost for $Hours hours = monthly share scaled from 730h
            if ($null -ne $q.Monthly) { $o["$y Year Reservation cost $col"] = [math]::Round($q.Monthly * $Hours / 730, 2) }
            else { $o["$y Year Reservation cost $col"] = 0 }
            if ($q.Note) { $c.Add($q.Note) }
        }
        $o['Comments'] = $c -join '; '
    }
    [pscustomobject]$o
}
$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $(@($rows).Count) row(s) to $OutputFile"

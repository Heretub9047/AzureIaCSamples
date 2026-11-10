# Get-DeprecatedAutomationRunbooks.ps1
#
# Interactive, read-only scan of Azure Automation accounts for runbooks running on deprecated runtimes
# (default: PowerShell 7.1, PowerShell 7.2, Python 2.7 - editable below or at the prompt).
#
# Flow:
#   1. Uses your current Az sign-in (offers Connect-AzAccount if there isn't one)
#   2. Lists subscriptions and lets you pick which to scan (numbers, ranges, or 'all')
#   3. Lets you confirm / change the list of deprecated runtimes
#   4. Finds every Automation account and runbook, works out each runbook's runtime, and flags matches
#   5. Prints the flagged runbooks, a runtime inventory, and offers a CSV export
#
# Runtime is resolved from the runbook's runtime environment (portal "Runtime environments") when it has
# one, otherwise from its runbookType (PowerShell = 5.1, PowerShell72 = 7.2, PowerShell7 = 7.1,
# Python2 = 2.7, Python3 = 3.8). Edit $LegacyTypeMap below if Microsoft changes these.
#
# Works as a file OR pasted / "Run Selection" - it does not use param() or $PSCmdlet.
# Needs Reader on the subscriptions; uses only Az.Accounts (Invoke-AzRestMethod). Makes no changes in Azure.

# ==== CONFIG =================================================================================================
# Labels are '<Language> <Version>'; wildcards allowed (e.g. 'Python 3.*'). Case-insensitive.
$DeprecatedRuntimes = @('PowerShell 7.1', 'PowerShell 7.2', 'Python 2.7')

# runbookType -> runtime label, used when a runbook has no runtime environment
$LegacyTypeMap = @{
    'PowerShell'         = 'PowerShell 5.1'
    'PowerShellWorkflow' = 'PowerShell Workflow 5.1'
    'PowerShell7'        = 'PowerShell 7.1'
    'PowerShell72'       = 'PowerShell 7.2'
    'Python2'            = 'Python 2.7'
    'Python3'            = 'Python 3.8'
    'Graph'              = 'Graphical'
    'GraphPowerShell'    = 'Graphical PowerShell'
    'GraphPowerShellWorkflow' = 'Graphical PowerShell Workflow'
}
# =============================================================================================================

$ErrorActionPreference = 'Stop'
$ApiVersion = '2023-05-15-preview'      # exposes runtimeEnvironment on runbooks

#region Helpers ---------------------------------------------------------------

function Invoke-Arm {
    param([string]$Path)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $resp = Invoke-AzRestMethod -Path $Path -Method GET
        if ($resp.StatusCode -ne 429) { return $resp }
        Start-Sleep -Seconds (5 * $attempt)
    }
    return $resp
}

# GET a list endpoint and follow nextLink; returns all items. Returns $null (with a warning) on HTTP error.
function Get-ArmList {
    param([string]$Path, [string]$What)
    $items = @()
    while ($Path) {
        $resp = Invoke-Arm -Path $Path
        if ($resp.StatusCode -ne 200) {
            $msg = try { ($resp.Content | ConvertFrom-Json).error.message } catch { "HTTP $($resp.StatusCode)" }
            Write-Warning "  Could not list $What : $msg"
            return $null
        }
        $j = $resp.Content | ConvertFrom-Json
        $items += @($j.value)
        $Path = if ($j.nextLink) { $j.nextLink -replace '^https://[^/]+', '' } else { $null }
    }
    return $items
}

function Select-FromList {
    param([object[]]$Items, [string]$Prompt, [scriptblock]$Label)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  {0,3}. {1}" -f ($i + 1), (& $Label $Items[$i]))
    }
    while ($true) {
        $ans = (Read-Host $Prompt).Trim()
        if ($ans -ieq 'all') { return $Items }
        $picked = [System.Collections.Generic.SortedSet[int]]::new()
        $ok = $ans.Length -gt 0
        foreach ($part in ($ans -split '[,\s]+' | Where-Object { $_ })) {
            if ($part -match '^(\d+)-(\d+)$') { $a = [int]$Matches[1]; $b = [int]$Matches[2]; $a..$b | ForEach-Object { [void]$picked.Add($_) } }
            elseif ($part -match '^\d+$')     { [void]$picked.Add([int]$part) }
            else { $ok = $false }
        }
        if ($ok -and $picked.Count -gt 0 -and $picked.Min -ge 1 -and $picked.Max -le $Items.Count) {
            return @($picked | ForEach-Object { $Items[$_ - 1] })
        }
        Write-Host "  Enter numbers like 1,3 or 2-4, or 'all'." -ForegroundColor Yellow
    }
}

function Get-RuntimeLabel($Runbook, $EnvMap) {
    $p = $Runbook.properties
    if ($p.runtimeEnvironment -and $EnvMap.ContainsKey($p.runtimeEnvironment.ToLowerInvariant())) {
        return $EnvMap[$p.runtimeEnvironment.ToLowerInvariant()]
    }
    if ($p.runtimeEnvironment) {
        # Environment not in the map (no access / deleted): derive from a name like 'PowerShell-7.2'
        if ($p.runtimeEnvironment -match '^(PowerShell|Python)[-_ ]?(\d+(\.\d+)*)') { return "$($Matches[1]) $($Matches[2])" }
        return "Unknown ($($p.runtimeEnvironment))"
    }
    if ($LegacyTypeMap.ContainsKey([string]$p.runbookType)) { return $LegacyTypeMap[[string]$p.runbookType] }
    return "Unknown ($($p.runbookType))"
}

function Test-Deprecated([string]$Label, [string[]]$Patterns) {
    foreach ($pat in $Patterns) { if ($Label -like $pat) { return $true } }
    return $false
}

#endregion

#region Sign-in + subscription choice ----------------------------------------

if (-not (Get-AzContext)) {
    Write-Host "No Azure sign-in found." -ForegroundColor Yellow
    if ((Read-Host "Run Connect-AzAccount now? (Y/n)") -match '^(n|no)$') { throw "Sign-in required." }
    Connect-AzAccount | Out-Null
}
Write-Host "Signed in as: $((Get-AzContext).Account.Id)" -ForegroundColor Gray

$allSubs = Get-ArmList -Path '/subscriptions?api-version=2022-12-01' -What 'subscriptions'
$allSubs = @($allSubs | Where-Object { $_.state -eq 'Enabled' } | Sort-Object displayName)
if ($allSubs.Count -eq 0) { throw "No enabled subscriptions visible to this account." }

Write-Host "`nSubscriptions:" -ForegroundColor Cyan
$subs = Select-FromList -Items $allSubs -Prompt "Scan which? (numbers, ranges, or 'all')" `
    -Label { param($s) "$($s.displayName)  [$($s.subscriptionId)]" }

#endregion

#region Confirm runtimes to flag ---------------------------------------------

Write-Host "`nRuntimes currently flagged as deprecated: $($DeprecatedRuntimes -join ', ')" -ForegroundColor Cyan
Write-Host "  Enter = keep | type a comma-separated list to replace | start with + to add (e.g. +Python 3.8, PowerShell 5.1)"
$ans = (Read-Host "Deprecated runtimes").Trim()
if ($ans.StartsWith('+')) {
    $DeprecatedRuntimes += @($ans.TrimStart('+') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} elseif ($ans) {
    $DeprecatedRuntimes = @($ans -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$DeprecatedRuntimes = @($DeprecatedRuntimes | Select-Object -Unique)
Write-Host "Flagging: $($DeprecatedRuntimes -join ', ')" -ForegroundColor Yellow

#endregion

#region Scan ------------------------------------------------------------------

$all = [System.Collections.Generic.List[object]]::new()
$accountCount = 0
$s = 0
foreach ($sub in $subs) {
    $s++
    Write-Host ("`n[{0}/{1}] {2}" -f $s, $subs.Count, $sub.displayName) -ForegroundColor White

    $accounts = Get-ArmList -Path "/subscriptions/$($sub.subscriptionId)/providers/Microsoft.Automation/automationAccounts?api-version=$ApiVersion" -What 'automation accounts'
    if (-not $accounts) { Write-Host "  No automation accounts." -ForegroundColor DarkGray; continue }

    foreach ($acct in $accounts) {
        $accountCount++
        $rg = ($acct.id -split '/')[4]
        Write-Host "  Account: $($acct.name)  ($rg)" -ForegroundColor Gray

        # Map runtime environment name -> 'Language Version'
        $envMap = @{}
        $envs = Get-ArmList -Path "$($acct.id)/runtimeEnvironments?api-version=$ApiVersion" -What "runtime environments of $($acct.name)"
        foreach ($e in @($envs)) {
            $rt = $e.properties.runtime
            if ($rt.language -and $rt.version) { $envMap[$e.name.ToLowerInvariant()] = "$($rt.language) $($rt.version)" }
        }

        $runbooks = Get-ArmList -Path "$($acct.id)/runbooks?api-version=$ApiVersion" -What "runbooks of $($acct.name)"
        foreach ($rb in @($runbooks)) {
            $label = Get-RuntimeLabel $rb $envMap
            $all.Add([pscustomobject]@{
                Deprecated     = Test-Deprecated $label $DeprecatedRuntimes
                Runtime        = $label
                Runbook        = $rb.name
                State          = $rb.properties.state
                AutomationAcct = $acct.name
                ResourceGroup  = $rg
                Subscription   = $sub.displayName
                SubscriptionId = $sub.subscriptionId
                Location       = $rb.location
                LastModified   = $rb.properties.lastModifiedTime
                RuntimeEnv     = $rb.properties.runtimeEnvironment
                RunbookType    = $rb.properties.runbookType
                ResourceId     = $rb.id
            })
        }
        Write-Host ("    {0} runbook(s)" -f @($runbooks).Count) -ForegroundColor DarkGray
    }
}

#endregion

#region Report ----------------------------------------------------------------

$flagged = @($all | Where-Object Deprecated)

Write-Host "`n$('=' * 90)" -ForegroundColor Cyan
Write-Host "  Scanned $($subs.Count) subscription(s), $accountCount automation account(s), $($all.Count) runbook(s)" -ForegroundColor Cyan
Write-Host ('=' * 90) -ForegroundColor Cyan

Write-Host "`nRuntime inventory (all runbooks):" -ForegroundColor White
$all | Group-Object Runtime | Sort-Object Name | ForEach-Object {
    $isDep = Test-Deprecated $_.Name $DeprecatedRuntimes
    Write-Host ("  {0,-34} {1,5}{2}" -f $_.Name, $_.Count, $(if ($isDep) { '   <-- deprecated' } else { '' })) `
        -ForegroundColor $(if ($isDep) { 'Red' } else { 'Gray' })
}

if ($flagged.Count -eq 0) {
    Write-Host "`nNo runbooks found on the flagged runtimes." -ForegroundColor Green
} else {
    Write-Host "`n$($flagged.Count) runbook(s) on deprecated runtimes:" -ForegroundColor Red
    $flagged | Sort-Object Runtime, Subscription, AutomationAcct, Runbook |
        Format-Table Runtime, Runbook, State, AutomationAcct, ResourceGroup, Subscription, LastModified -AutoSize |
        Out-String -Width 4096 | Write-Host
}

$exp = (Read-Host "Export to CSV? (a = all runbooks, d = deprecated only, Enter = no)").Trim().ToLower()
if ($exp -in 'a', 'd') {
    $rows = if ($exp -eq 'a') { $all } else { $flagged }
    $path = ".\DeprecatedRunbooks_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    $rows | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Saved: $((Resolve-Path $path).Path)" -ForegroundColor Cyan
}

# Leave the data in the session for ad-hoc filtering: $all (every runbook), $flagged (deprecated only)

#endregion

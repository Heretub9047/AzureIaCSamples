<#
.SYNOPSIS
  Converts Azure Policy JSON exports to Bicep parameter (.bicepparam) files.
  One .bicepparam is generated per JSON file, targeting main.bicep.
#>

$inputFolder  = Join-Path $PSScriptRoot 'PoliciesJSON'
$outputFolder = Join-Path $PSScriptRoot 'PoliciesBicepParam'

# ---------------------------------------------------------------------------
# Recursive JSON -> Bicep literal converter
# ---------------------------------------------------------------------------
function ConvertTo-BicepValue {
    param(
        $value,
        [int]$indent = 0
    )

    $pad      = '  ' * $indent
    $padInner = '  ' * ($indent + 1)

    if ($null -eq $value) {
        return 'null'
    }

    $typeName = $value.GetType().Name

    # Booleans must be checked before numeric types
    if ($typeName -eq 'Boolean') {
        return $value.ToString().ToLower()
    }

    if ($typeName -in @('Int32','Int64','Double','Decimal')) {
        return $value.ToString()
    }

    if ($typeName -eq 'String') {
        # Escape single quotes inside the string
        $escaped = $value -replace "'", "''"
        return "'$escaped'"
    }

    # Arrays (PS arrays or ArrayList)
    if ($value -is [System.Collections.IEnumerable] -and $typeName -ne 'String' -and $value -isnot [System.Collections.IDictionary]) {
        $items = @($value)
        if ($items.Count -eq 0) { return '[]' }

        $lines = @('[')
        foreach ($item in $items) {
            $converted = ConvertTo-BicepValue -value $item -indent ($indent + 1)
            $lines += "$padInner$converted"
        }
        $lines += "$pad]"
        return ($lines -join "`n")
    }

    # Objects (PSCustomObject or Hashtable)
    if ($typeName -eq 'PSCustomObject' -or $value -is [System.Collections.IDictionary]) {
        $props = if ($value -is [System.Collections.IDictionary]) {
            $value.Keys | ForEach-Object { [PSCustomObject]@{ Name = $_; Value = $value[$_] } }
        } else {
            $value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }
        }

        $propList = @($props)
        if ($propList.Count -eq 0) { return '{}' }

        # Bicep reserved words that must be quoted when used as object property keys
        $bicepKeywords = @(
            'if','for','in','null','true','false',
            'param','var','output','resource','module','targetScope',
            'existing','import','func','type','using','metadata',
            'string','int','bool','object','array'
        )

        $lines = @('{')
        foreach ($prop in $propList) {
            $key = $prop.Name
            # Quote keys that contain special characters (e.g. $schema, hyphens)
            # or that are Bicep reserved words
            if ($key -match '[^a-zA-Z0-9_]' -or $bicepKeywords -contains $key) {
                $key = "'$key'"
            }
            $converted = ConvertTo-BicepValue -value $prop.Value -indent ($indent + 1)
            $lines += "$padInner${key}: $converted"
        }
        $lines += "$pad}"
        return ($lines -join "`n")
    }

    # Fallback: treat as string
    return "'$value'"
}

# ---------------------------------------------------------------------------
# Main conversion loop
# ---------------------------------------------------------------------------
$jsonFiles = Get-ChildItem -Path $inputFolder -Filter '*.json'
$success   = 0
$failure   = 0

foreach ($file in $jsonFiles) {
    try {
        $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json

        $policyDefinitionName = $json.name
        $policydisplayName    = $json.displayName
        $description          = if ($null -ne $json.description) { $json.description } else { '' }
        $policyMode           = if ($null -ne $json.mode)        { $json.mode }        else { 'Indexed' }
        $metadata             = $json.metadata
        $policyParameters     = $json.parameters
        $policyRule           = $json.policyRule

        $metadataVal        = ConvertTo-BicepValue -value $metadata        -indent 0
        $policyParamsVal    = ConvertTo-BicepValue -value $policyParameters -indent 0
        $policyRuleVal      = ConvertTo-BicepValue -value $policyRule       -indent 0

        $bicepParam = @"
using '../main.bicep'

param policyDefinitionName = $(ConvertTo-BicepValue $policyDefinitionName)
param policydisplayName = $(ConvertTo-BicepValue $policydisplayName)
param description = $(ConvertTo-BicepValue $description)
param policyMode = $(ConvertTo-BicepValue $policyMode)
param metadata = $metadataVal
param policyParameters = $policyParamsVal
param policyRule = $policyRuleVal
"@

        $outPath = Join-Path $outputFolder "$($file.BaseName).bicepparam"
        Set-Content -Path $outPath -Value $bicepParam -Encoding UTF8
        $success++
    }
    catch {
        Write-Warning "FAILED: $($file.Name) — $_"
        $failure++
    }
}

Write-Host ""
Write-Host "Conversion complete." -ForegroundColor Cyan
Write-Host "  Success : $success" -ForegroundColor Green
Write-Host "  Failed  : $failure" -ForegroundColor $(if ($failure -gt 0) { 'Red' } else { 'Green' })

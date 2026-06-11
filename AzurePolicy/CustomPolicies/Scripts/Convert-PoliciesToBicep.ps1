# Convert Azure Policy JSON files to Bicep parameter files

function Split-ConcatArgs {
    param([string]$ArgsStr)
    $result = @()
    $depth = 0
    $inString = $false
    $current = [System.Text.StringBuilder]::new()
    foreach ($char in $ArgsStr.ToCharArray()) {
        if ($char -eq "'" -and -not $inString) {
            $inString = $true
            [void]$current.Append($char)
        } elseif ($char -eq "'" -and $inString) {
            $inString = $false
            [void]$current.Append($char)
        } elseif ($char -eq '(' -and -not $inString) {
            $depth++
            [void]$current.Append($char)
        } elseif ($char -eq ')' -and -not $inString) {
            $depth--
            [void]$current.Append($char)
        } elseif ($char -eq ',' -and $depth -eq 0 -and -not $inString) {
            $trimmed = $current.ToString().Trim()
            if ($trimmed.Length -gt 0) { $result += $trimmed }
            $current = [System.Text.StringBuilder]::new()
        } else {
            [void]$current.Append($char)
        }
    }
    $last = $current.ToString().Trim()
    if ($last.Length -gt 0) { $result += $last }
    return $result
}

function Convert-ConcatToInterpolation {
    param([string]$ArgsStr)
    $parts = Split-ConcatArgs $ArgsStr
    $sb = [System.Text.StringBuilder]::new()
    foreach ($part in $parts) {
        $part = $part.Trim()
        if ($part -match "^parameters\('([^']+)'\)$") {
            [void]$sb.Append('$')
            [void]$sb.Append('{')
            [void]$sb.Append($Matches[1])
            [void]$sb.Append('}')
        } elseif ($part -match "^'(.*)'$") {
            [void]$sb.Append($Matches[1])
        } else {
            # Other expression (e.g. field()) - wrap in ${}
            [void]$sb.Append('$')
            [void]$sb.Append('{')
            [void]$sb.Append($part)
            [void]$sb.Append('}')
        }
    }
    return "'" + $sb.ToString() + "'"
}

function Convert-ArmExpression {
    param([string]$Value)
    $expr = $Value.Substring(1, $Value.Length - 2).Trim()

    # parameters('x') -> x
    if ($expr -match "^parameters\('([^']+)'\)$") { return $Matches[1] }

    # field('x') -> field('x')
    if ($expr -match "^field\('([^']*)'\)$") { return "field('$($Matches[1])')" }

    # first(parameters('x')) -> first(x)
    if ($expr -match "^first\(parameters\('([^']+)'\)\)$") { return "first($($Matches[1]))" }

    # last(parameters('x')) -> last(x)
    if ($expr -match "^last\(parameters\('([^']+)'\)\)$") { return "last($($Matches[1]))" }

    # equals(parameters('x'), 'value') -> (x == 'value')
    if ($expr -match "^equals\(parameters\('([^']+)'\),\s*'([^']*)'\)$") {
        return "($($Matches[1]) == '$($Matches[2])')"
    }

    # concat(...) -> string interpolation
    if ($expr -match "^concat\((.+)\)$") {
        return Convert-ConcatToInterpolation $Matches[1]
    }

    # Fallback: return expression as-is (unquoted)
    return $expr
}

function Test-NeedsQuoting {
    param([string]$Key)
    return ($Key -match '^[^a-zA-Z_]' -or $Key -match '[^a-zA-Z0-9_]')
}

function Convert-ValueToBicep {
    param($Value, [int]$Indent = 0)
    $pad = "  " * $Indent
    $innerPad = "  " * ($Indent + 1)

    if ($null -eq $Value) { return "null" }

    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }

    if ($Value -is [int32] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) {
        return "$Value"
    }

    if ($Value -is [string]) {
        if ($Value -match '^\[.+\]$') { return Convert-ArmExpression $Value }
        $escaped = $Value -replace "'", "''"
        return "'$escaped'"
    }

    if ($Value -is [System.Object[]]) {
        if ($Value.Count -eq 0) { return "[]" }
        $lines = @("[")
        foreach ($item in $Value) {
            $itemBicep = Convert-ValueToBicep $item ($Indent + 1)
            $lines += "$innerPad$itemBicep"
        }
        $lines += "$pad]"
        return ($lines -join "`n")
    }

    if ($Value -is [PSCustomObject]) {
        $props = @($Value.PSObject.Properties)
        if ($props.Count -eq 0) { return "{}" }
        $lines = @("{")
        foreach ($prop in $props) {
            $key = $prop.Name
            if (Test-NeedsQuoting $key) { $key = "'$key'" }
            $valBicep = Convert-ValueToBicep $prop.Value ($Indent + 1)
            $lines += "$innerPad${key}: $valBicep"
        }
        $lines += "$pad}"
        return ($lines -join "`n")
    }

    return "'$Value'"
}

function Get-PolicySlug {
    param([string]$DisplayName)
    $name = $DisplayName
    if ($DisplayName.Contains('(')) {
        $name = $DisplayName.Substring(0, $DisplayName.IndexOf('(')).Trim()
    }
    $name = $name.ToLower()
    $name = $name -replace '[^a-z0-9\s]', ''
    $name = $name -replace '\s+', '-'
    $name = $name.Trim('-')
    return $name
}

# ── Main ────────────────────────────────────────────────────────────────────
$inputDir  = "c:\VsCode\Other\PolicyConversion\PoliciesJSON"
$outputDir = "c:\VsCode\Other\PolicyConversion\PoliciesBicepParam"

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$jsonFiles = Get-ChildItem -Path $inputDir -Filter "*.json" | Sort-Object Name
$converted = 0; $failed = 0

foreach ($file in $jsonFiles) {
    try {
        $data = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

        $displayName  = $data.displayName
        $description  = $data.description
        $metadata     = $data.metadata
        $parameters   = $data.parameters
        $policyRule   = $data.policyRule
        $mode         = if ($data.mode) { $data.mode } else { "Indexed" }

        $slug = Get-PolicySlug $displayName
        $guid = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

        $metadataBicep   = Convert-ValueToBicep $metadata 0
        $parametersBicep = Convert-ValueToBicep $parameters 0
        $policyRuleBicep = Convert-ValueToBicep $policyRule 0

        $displayNameEsc = $displayName -replace "'", "''"
        $descriptionEsc = $description -replace "'", "''"

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("using '../main.bicep'")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("param policyDefinitionName = '$slug'")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("param policydisplayName = '$displayNameEsc'")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("param description = '$descriptionEsc'")
        [void]$sb.AppendLine("")
        if ($mode -ne "Indexed") {
            [void]$sb.AppendLine("param policyMode = '$mode'")
            [void]$sb.AppendLine("")
        }
        [void]$sb.AppendLine("param metadata = '''")
        [void]$sb.AppendLine($metadataBicep)
        [void]$sb.AppendLine("'''")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("param policyParameters = '''")
        [void]$sb.AppendLine($parametersBicep)
        [void]$sb.AppendLine("'''")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("param policyRule = '''")
        [void]$sb.AppendLine($policyRuleBicep)
        [void]$sb.AppendLine("'''")

        $outputPath = Join-Path $outputDir "$guid.bicepparam"
        [System.IO.File]::WriteAllText($outputPath, $sb.ToString(), [System.Text.Encoding]::UTF8)

        $converted++
        Write-Host "[$converted] $($file.Name)" -ForegroundColor Green
    }
    catch {
        $failed++
        Write-Error "FAILED: $($file.Name) - $_"
    }
}

Write-Host ""
Write-Host "Done: $converted converted, $failed failed." -ForegroundColor Cyan

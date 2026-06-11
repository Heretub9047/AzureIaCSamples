$ExportPath = "C:\Vscode\Other\PolicyConversion\PoliciesJSON"

$AllPolicies = Import-csv "C:\VsCode\Other\PolicyConversion\PolicyDefinitionTabExport.csv"

foreach ($Policy in $AllPolicies) {
    $PolicySpilt = $Policy.Policy.Split("/")

    $PolicyID = $PolicySpilt[4]

    Try{
        Write-Host "Exporting $($PolicyID) to JSON"
        $PolicyDefinition = az policy definition show --name $PolicyID
        $PolicyDefinition | out-file "$ExportPath\$($PolicyID).json"
        Write-host "Exported $($PolicyID) to JSON" -foregroundcolor green
    }catch{
        Write-Host "Failed to export $($PolicyID)" -ForegroundColor Red
    }
}
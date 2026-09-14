# 99_teardown.ps1 - delete the resource group. The Foundry account, project, model deployment,
# agents, and the pipeline identity all live inside it. The GitHub repo and its Environments
# are left alone (they cost nothing).
# Usage:  .\scripts\99_teardown.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Get-Content (Join-Path $root ".env") | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; Set-Item -Path "Env:$($k.Trim())" -Value $v.Trim()
}
if (-not $env:AZURE_SUBSCRIPTION_ID -or $env:AZURE_SUBSCRIPTION_ID -like "*<*") {
    throw "Edit .env first: AZURE_SUBSCRIPTION_ID is still a placeholder."
}
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
$rg = "rg-ais-$($env:REGION_CODE)-$($env:WORKLOAD)"
Write-Host "This will DELETE resource group $rg (exists: $(az group exists --name $rg))"
if ((Read-Host "Type DELETE to continue") -ne "DELETE") { Write-Host "Aborted."; exit 0 }
az group delete --name $rg --yes --no-wait
Write-Host "Deletion started; it finishes in the background in a few minutes."

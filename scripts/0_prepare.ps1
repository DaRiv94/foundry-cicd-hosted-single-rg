# 0_prepare.ps1 - create the one resource group and let the signed-in user create agents in it.
# Usage:  .\scripts\0_prepare.ps1
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

az group create --name $rg --location $env:AZURE_LOCATION --tags workload=$env:WORKLOAD purpose=foundry-cicd-learning `
    --query "{name:name, state:properties.provisioningState}" -o tsv

# Owner on the subscription has no data-plane rights. Foundry Owner on the group is what
# lets your own account create agents and run evaluations from this machine.
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Foundry Owner" `
    --scope "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$rg" --query id -o tsv | Out-Null
Write-Host "Foundry Owner granted to you on $rg."
Write-Host "Next: .\scripts\1_deploy_infra.ps1 -Env dev"

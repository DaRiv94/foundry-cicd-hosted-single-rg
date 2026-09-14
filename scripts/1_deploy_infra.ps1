# 1_deploy_infra.ps1 - deploy infra/main.bicep into the resource group. Idempotent: rerunning
# changes nothing that already matches. The environment name only labels the deployment,
# because dev, test, and prod share this one project.
# Usage:  .\scripts\1_deploy_infra.ps1 -Env dev
param([Parameter(Mandatory = $true)][ValidateSet("dev", "test", "prod")][string]$Env)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (Test-Path (Join-Path $root ".env")) {
    Get-Content (Join-Path $root ".env") | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2; Set-Item -Path "Env:$($k.Trim())" -Value $v.Trim()
    }
}
if (-not $env:AZURE_SUBSCRIPTION_ID -or $env:AZURE_SUBSCRIPTION_ID -like "*<*") {
    throw "Edit .env first: AZURE_SUBSCRIPTION_ID is still a placeholder."
}
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
$rg = "rg-ais-$($env:REGION_CODE)-$($env:WORKLOAD)"
$stamp = Get-Date -Format "yyyyMMddHHmmss"

Write-Host "Deploying infra/main.bicep into $rg ..."
$outputs = az deployment group create --resource-group $rg --name "infra-$Env-$stamp" `
    --template-file (Join-Path $root "infra\main.bicep") --parameters workload=$env:WORKLOAD regionCode=$env:REGION_CODE `
    --query "properties.outputs" -o json | ConvertFrom-Json
if (-not $outputs) { throw "Deployment failed." }
Write-Host "Project endpoint : $($outputs.projectEndpoint.value)"

# 2_build_image.ps1 - build the agent container image in the registry (dev) or confirm the tag
# exists (test, prod). The build runs inside Azure Container Registry, so no Docker is needed here.
# One registry serves all three environments, so the image built for dev is the exact image
# test and prod deploy. Nothing is rebuilt.
# Usage:  .\scripts\2_build_image.ps1 -Env dev -Tag v1
param(
    [Parameter(Mandatory = $true)][ValidateSet("dev", "test", "prod")][string]$Env,
    [Parameter(Mandatory = $true)][string]$Tag
)
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
$registry = "acrais$($env:REGION_CODE)$($env:WORKLOAD)"
$repo = "frankies-bakery-support"

if ($Env -eq "dev") {
    Write-Host "Building $repo`:$Tag in $registry (remote build, about two minutes) ..."
    az acr build --registry $registry --image "$repo`:$Tag" (Join-Path $root "agent") --no-logs --output none
} else {
    $tags = az acr repository show-tags --name $registry --repository $repo -o tsv
    if ($tags -notcontains $Tag) { throw "Tag $Tag is not in $registry. Run the dev stage first; test and prod reuse its image." }
    Write-Host "Tag $Tag exists in $registry. Nothing to build for $Env."
}
Write-Host "image=$registry.azurecr.io/$repo`:$Tag"

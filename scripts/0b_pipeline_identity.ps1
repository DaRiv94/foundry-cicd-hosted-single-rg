# 0b_pipeline_identity.ps1 - one-time setup for the GitHub Actions pipeline.
#   1. one user-assigned managed identity in the resource group (id-ais-<region>-<workload>-cicd)
#   2. three federated credentials, one per GitHub Environment (dev, test, prod). No secrets.
#   3. three roles on the resource group, each one paid for by one pipeline step:
#        Contributor                            creates the container registry (Bicep) and runs az acr build
#        Role Based Access Control Administrator writes the registry reader assignment for the project identity (Bicep)
#        Foundry Owner                          creates the Foundry account, project, and agent versions
#      A prompt agent needs only the last one. The container registry is what adds the other two.
#   4. the three GitHub Environments and their variables (prod gets a required reviewer)
# Requires: az login, gh auth login (repo + workflow scope), and the GitHub repo already pushed.
# Usage:  .\scripts\0b_pipeline_identity.ps1            (reviewer = the signed-in gh user)
#         .\scripts\0b_pipeline_identity.ps1 -Reviewer someone
param([string]$Reviewer = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Get-Content (Join-Path $root ".env") | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; Set-Item -Path "Env:$($k.Trim())" -Value $v.Trim()
}
foreach ($k in @("AZURE_SUBSCRIPTION_ID", "GITHUB_REPO")) {
    if (-not (Get-Item "Env:$k").Value -or (Get-Item "Env:$k").Value -like "*<*") { throw "Edit .env first: $k is still a placeholder." }
}
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
$sub = $env:AZURE_SUBSCRIPTION_ID
$tenant = az account show --query tenantId -o tsv
$rc = $env:REGION_CODE; $wl = $env:WORKLOAD; $repo = $env:GITHUB_REPO
$rg = "rg-ais-$rc-$wl"
$identityName = "id-ais-$rc-$wl-cicd"

# GitHub identifiers. Repos created after 2026-07-15 present the immutable OIDC subject
#   repo:OWNER@OWNER-ID/REPO@REPO-ID:environment:<name>
# so the federated credential must carry the numeric ids, not just the names.
$owner, $name = $repo -split '/', 2
$ownerId = gh api "users/$owner" --jq '.id'
$repoId = gh api "repos/$repo" --jq '.id'
if (-not $Reviewer) { $Reviewer = gh api user --jq '.login' }
$reviewerId = gh api "users/$Reviewer" --jq '.id'
Write-Host "Repo $repo (owner id $ownerId, repo id $repoId). Prod reviewer: $Reviewer"

# 1. the identity (one for all three environments; the Environment name is the unit of approval, not of infrastructure)
$identity = az identity create --resource-group $rg --name $identityName --location $env:AZURE_LOCATION `
    --query "{clientId:clientId, principalId:principalId}" -o json | ConvertFrom-Json
Write-Host "Identity $identityName  client id $($identity.clientId)"

# 3. the three roles
foreach ($role in @("Contributor", "Role Based Access Control Administrator", "Foundry Owner")) {
    az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal `
        --role $role --scope "/subscriptions/$sub/resourceGroups/$rg" --query id -o tsv | Out-Null
    Write-Host "$role on $rg"
}

foreach ($e in @("dev", "test", "prod")) {
    # 2. federated credential: GitHub jobs running in Environment <e> may sign in as this identity
    $subject = "repo:$owner@$ownerId/$name@${repoId}:environment:$e"
    az identity federated-credential create --name "github-$e" --identity-name $identityName --resource-group $rg `
        --issuer "https://token.actions.githubusercontent.com" --subject $subject --audiences "api://AzureADTokenExchange" `
        --query name -o tsv | Out-Null
    Write-Host "$e : federated credential -> $subject"

    # 4. GitHub Environment + variables. prevent_self_review is only accepted together with reviewers;
    #    it is false so a one-person team can approve its own prod run.
    $body = @{ wait_timer = 0; deployment_branch_policy = $null }
    if ($e -eq "prod") { $body.reviewers = @(@{ type = "User"; id = [int]$reviewerId }); $body.prevent_self_review = $false }
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value ($body | ConvertTo-Json -Depth 4 -Compress) -Encoding ascii
    gh api --method PUT "repos/$repo/environments/$e" --input $tmp --jq '.name' | Out-Null
    Remove-Item $tmp
    gh variable set AZURE_CLIENT_ID --env $e --body $identity.clientId --repo $repo
    gh variable set AZURE_TENANT_ID --env $e --body $tenant --repo $repo
    gh variable set AZURE_SUBSCRIPTION_ID --env $e --body $sub --repo $repo
    Write-Host "$e : GitHub Environment with 3 variables$(if ($e -eq 'prod') { " and required reviewer $Reviewer" })"
}
gh variable set REGION_CODE --body $rc --repo $repo
gh variable set WORKLOAD --body $wl --repo $repo
gh variable set AGENT_NAME --body $env:AGENT_NAME --repo $repo
Write-Host "Repository variables REGION_CODE, WORKLOAD, AGENT_NAME set."
Write-Host "Done. Role assignments can take up to 10 minutes to propagate before the first workflow run succeeds."

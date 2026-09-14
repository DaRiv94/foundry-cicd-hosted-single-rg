#!/usr/bin/env bash
# 0b_pipeline_identity.sh - one-time setup for the GitHub Actions pipeline.
#   1. one user-assigned managed identity in the resource group (id-ais-<region>-<workload>-cicd)
#   2. three federated credentials, one per GitHub Environment (dev, test, prod). No secrets.
#   3. three roles on the resource group, each one paid for by one pipeline step:
#        Contributor                            creates the container registry (Bicep) and runs az acr build
#        Role Based Access Control Administrator writes the registry reader assignment for the project identity (Bicep)
#        Foundry Owner                          creates the Foundry account, project, and agent versions
#      A prompt agent needs only the last one. The container registry is what adds the other two.
#   4. the three GitHub Environments and their variables (prod gets a required reviewer)
# Requires: az login, gh auth login (repo + workflow scope), and the GitHub repo already pushed.
# Usage:  ./scripts/0b_pipeline_identity.sh            (reviewer = the signed-in gh user)
#         ./scripts/0b_pipeline_identity.sh someone
set -euo pipefail
REVIEWER="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"; [[ -z "$line" || "$line" == \#* ]] && continue; export "${line%%=*}=${line#*=}"
done < "$ROOT/.env"
for k in AZURE_SUBSCRIPTION_ID GITHUB_REPO; do
  [[ -n "${!k:-}" && "${!k}" != *"<"* ]] || { echo "Edit .env first: $k is still a placeholder."; exit 1; }
done
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
sub="$AZURE_SUBSCRIPTION_ID"
tenant="$(az account show --query tenantId -o tsv)"
rc="$REGION_CODE"; wl="$WORKLOAD"; repo="$GITHUB_REPO"
rg="rg-ais-$rc-$wl"
identity_name="id-ais-$rc-$wl-cicd"

# GitHub identifiers. Repos created after 2026-07-15 present the immutable OIDC subject
#   repo:OWNER@OWNER-ID/REPO@REPO-ID:environment:<name>
# so the federated credential must carry the numeric ids, not just the names.
owner="${repo%%/*}"; name="${repo#*/}"
owner_id="$(gh api "users/$owner" --jq '.id')"
repo_id="$(gh api "repos/$repo" --jq '.id')"
[[ -n "$REVIEWER" ]] || REVIEWER="$(gh api user --jq '.login')"
reviewer_id="$(gh api "users/$REVIEWER" --jq '.id')"
echo "Repo $repo (owner id $owner_id, repo id $repo_id). Prod reviewer: $REVIEWER"

# 1. the identity (one for all three environments; the Environment name is the unit of approval, not of infrastructure)
read -r client_id principal_id < <(az identity create --resource-group "$rg" --name "$identity_name" --location "$AZURE_LOCATION" \
  --query "[clientId, principalId]" -o tsv | tr '\t' ' ')
echo "Identity $identity_name  client id $client_id"

# 3. the three roles
for role in "Contributor" "Role Based Access Control Administrator" "Foundry Owner"; do
  MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "/subscriptions/$sub/resourceGroups/$rg" --query id -o tsv > /dev/null
  echo "$role on $rg"
done

for e in dev test prod; do
  # 2. federated credential: GitHub jobs running in Environment <e> may sign in as this identity
  subject="repo:$owner@$owner_id/$name@$repo_id:environment:$e"
  az identity federated-credential create --name "github-$e" --identity-name "$identity_name" --resource-group "$rg" \
    --issuer "https://token.actions.githubusercontent.com" --subject "$subject" --audiences "api://AzureADTokenExchange" \
    --query name -o tsv > /dev/null
  echo "$e : federated credential -> $subject"

  # 4. GitHub Environment + variables. prevent_self_review is only accepted together with reviewers;
  #    it is false so a one-person team can approve its own prod run.
  if [[ "$e" == "prod" ]]; then
    body="{\"wait_timer\":0,\"deployment_branch_policy\":null,\"reviewers\":[{\"type\":\"User\",\"id\":$reviewer_id}],\"prevent_self_review\":false}"
  else
    body='{"wait_timer":0,"deployment_branch_policy":null}'
  fi
  printf '%s' "$body" | gh api --method PUT "repos/$repo/environments/$e" --input - --jq '.name' > /dev/null
  gh variable set AZURE_CLIENT_ID --env "$e" --body "$client_id" --repo "$repo"
  gh variable set AZURE_TENANT_ID --env "$e" --body "$tenant" --repo "$repo"
  gh variable set AZURE_SUBSCRIPTION_ID --env "$e" --body "$sub" --repo "$repo"
  echo "$e : GitHub Environment with 3 variables$( [[ "$e" == "prod" ]] && echo " and required reviewer $REVIEWER" )"
done
gh variable set REGION_CODE --body "$rc" --repo "$repo"
gh variable set WORKLOAD --body "$wl" --repo "$repo"
gh variable set AGENT_NAME --body "$AGENT_NAME" --repo "$repo"
echo "Repository variables REGION_CODE, WORKLOAD, AGENT_NAME set."
echo "Done. Role assignments can take up to 10 minutes to propagate before the first workflow run succeeds."

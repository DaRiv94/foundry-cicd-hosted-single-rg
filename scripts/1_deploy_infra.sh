#!/usr/bin/env bash
# 1_deploy_infra.sh - deploy infra/main.bicep into the resource group. Idempotent: rerunning
# changes nothing that already matches. The environment name only labels the deployment,
# because dev, test, and prod share this one project. The pipeline runs this same file.
# Usage:  ./scripts/1_deploy_infra.sh dev
set -euo pipefail
ENV="${1:?usage: 1_deploy_infra.sh dev|test|prod}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; [[ -z "$line" || "$line" == \#* ]] && continue; export "${line%%=*}=${line#*=}"
  done < "$ROOT/.env"
fi
[[ -n "${AZURE_SUBSCRIPTION_ID:-}" && "$AZURE_SUBSCRIPTION_ID" != *"<"* ]] || { echo "Edit .env first: AZURE_SUBSCRIPTION_ID is still a placeholder."; exit 1; }
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
rg="rg-ais-${REGION_CODE}-${WORKLOAD}"

echo "Deploying infra/main.bicep into $rg ..."
az deployment group create --resource-group "$rg" --name "infra-${ENV}-$(date +%Y%m%d%H%M%S)" \
  --template-file "$ROOT/infra/main.bicep" --parameters workload="$WORKLOAD" regionCode="$REGION_CODE" \
  --query "properties.outputs.projectEndpoint.value" -o tsv | sed 's/^/Project endpoint : /'

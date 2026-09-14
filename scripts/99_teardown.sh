#!/usr/bin/env bash
# 99_teardown.sh - delete the resource group. The Foundry account, project, model deployment,
# agents, and the pipeline identity all live inside it. The GitHub repo and its Environments
# are left alone (they cost nothing).
# Usage:  ./scripts/99_teardown.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"; [[ -z "$line" || "$line" == \#* ]] && continue; export "${line%%=*}=${line#*=}"
done < "$ROOT/.env"
[[ -n "${AZURE_SUBSCRIPTION_ID:-}" && "$AZURE_SUBSCRIPTION_ID" != *"<"* ]] || { echo "Edit .env first: AZURE_SUBSCRIPTION_ID is still a placeholder."; exit 1; }
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
rg="rg-ais-${REGION_CODE}-${WORKLOAD}"
echo "This will DELETE resource group $rg (exists: $(az group exists --name "$rg"))"
read -r -p "Type DELETE to continue: " answer
[[ "$answer" == "DELETE" ]] || { echo "Aborted."; exit 0; }
az group delete --name "$rg" --yes --no-wait
echo "Deletion started; it finishes in the background in a few minutes."

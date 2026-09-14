#!/usr/bin/env bash
# 2_build_image.sh - build the agent container image in the registry (dev) or confirm the tag
# exists (test, prod). The build runs inside Azure Container Registry, so no Docker is needed here.
# One registry serves all three environments, so the image built for dev is the exact image
# test and prod deploy. Nothing is rebuilt. The pipeline runs this same file.
# Usage:  ./scripts/2_build_image.sh dev v1
set -euo pipefail
ENV="${1:?usage: 2_build_image.sh dev|test|prod <tag>}"
TAG="${2:?usage: 2_build_image.sh dev|test|prod <tag>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; [[ -z "$line" || "$line" == \#* ]] && continue; export "${line%%=*}=${line#*=}"
  done < "$ROOT/.env"
fi
[[ -n "${AZURE_SUBSCRIPTION_ID:-}" && "$AZURE_SUBSCRIPTION_ID" != *"<"* ]] || { echo "Edit .env first: AZURE_SUBSCRIPTION_ID is still a placeholder."; exit 1; }
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
registry="acrais${REGION_CODE}${WORKLOAD}"
repo="frankies-bakery-support"

if [[ "$ENV" == "dev" ]]; then
  echo "Building $repo:$TAG in $registry (remote build, about two minutes) ..."
  az acr build --registry "$registry" --image "$repo:$TAG" "$ROOT/agent" --no-logs --output none
else
  az acr repository show-tags --name "$registry" --repository "$repo" -o tsv | grep -qx "$TAG" \
    || { echo "Tag $TAG is not in $registry. Run the dev stage first; test and prod reuse its image."; exit 1; }
  echo "Tag $TAG exists in $registry. Nothing to build for $ENV."
fi
echo "image=$registry.azurecr.io/$repo:$TAG"

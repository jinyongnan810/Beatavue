#!/bin/sh
# Run after infra bootstrap and secret provisioning. Uses the configured remote backend.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
ARCHIVE=$(python3 scripts/package-api.py)
OBJECT=$(basename "$ARCHIVE")
gcloud storage cp "$ARCHIVE" "gs://beatavue-function-source/$OBJECT" --project=beatavue
terraform -chdir=infra plan \
  -var="deploy_functions=true" -var="source_object=$OBJECT" \
  -var="upload_token_version=${UPLOAD_TOKEN_VERSION:-1}" -out=deployment.tfplan
terraform -chdir=infra apply deployment.tfplan
echo "Persist deploy_functions, source_object and upload_token_version in your ignored terraform.tfvars for future plans."

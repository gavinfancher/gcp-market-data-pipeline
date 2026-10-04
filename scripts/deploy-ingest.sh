#!/usr/bin/env bash
# Build the ingest image with Cloud Build and point the Cloud Run job at it.
# Terraform creates the job with a placeholder image and ignores image changes,
# so this script (and later CI) owns which image runs.
#   scripts/deploy-ingest.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="${REGION:-us-central1}"
REPO="$(terraform -chdir=infra output -raw image_repo)"
JOB="$(terraform -chdir=infra output -raw ingest_job)"

# Tag with the commit so every image traces back to its code.
TAG="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain -- ingest)" ]]; then
  TAG="${TAG}-dirty-$(date +%Y%m%d%H%M%S)"  # uncommitted changes in ingest/
fi
IMAGE="${REPO}/ingest:${TAG}"

gcloud builds submit ingest --tag "$IMAGE"
gcloud run jobs update "$JOB" --region "$REGION" --image "$IMAGE"
echo "deployed ${IMAGE}"

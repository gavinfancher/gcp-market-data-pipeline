#!/usr/bin/env bash
# Prompt for the Alpaca keys (hidden input) and store each as a new secret version.
# Terraform creates the secrets but never their values, so keys stay out of tfstate.
# Re-run any time to rotate keys; the job reads "latest" on its next start.
set -euo pipefail

for secret in alpaca-api-key-id alpaca-api-secret-key; do
  read -rsp "Value for ${secret}: " value
  echo
  # printf (not echo) so no trailing newline ends up in the secret.
  printf %s "$value" | gcloud secrets versions add "$secret" --data-file=- >/dev/null
  echo "  added new version of ${secret}"
done
unset value

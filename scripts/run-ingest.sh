#!/usr/bin/env bash
# Trigger the ingest Cloud Run job for a date range and wait for it to finish.
#   scripts/run-ingest.sh                          # yesterday
#   scripts/run-ingest.sh 2026-09-01 2026-09-30    # a range
#   scripts/run-ingest.sh 2021-10-01 2026-10-03 4  # a range split across 4 tasks
# Overrides apply to this execution only; the job's defaults are unchanged.
set -euo pipefail

START="${1:-}"
END="${2:-$START}"
TASKS="${3:-1}"
REGION="${REGION:-us-central1}"

args=(--region "$REGION" --tasks "$TASKS" --wait)
if [[ -n "$START" ]]; then
  args+=(--update-env-vars "START_DATE=$START,END_DATE=$END")
fi

gcloud run jobs execute equity-ingest "${args[@]}"

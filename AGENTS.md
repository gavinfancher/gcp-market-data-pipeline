# Agent guide — gcp-market-data-pipeline

Start with README.md.

- `ingest/` is a Python Cloud Run job managed with uv (`uv run`, `uv add`). Keep it stdlib + httpx + google-cloud-storage.
- `infra/` is a single Terraform root with local state. Run `terraform fmt` and `terraform validate` after edits. Never put secret values in Terraform.
- Image deploys go through `scripts/deploy-ingest.sh`, not Terraform (the job ignores image changes).

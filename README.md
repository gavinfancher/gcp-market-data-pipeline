# gcp-market-data-pipeline

Serverless market-data ingest on GCP. A scheduled Cloud Run Job pulls 1-minute stock bars from Alpaca into Cloud Storage, and BigQuery queries the files in place. All infrastructure is Terraform. There are no service account keys, and each workload runs as its own least-privilege identity.

```
Cloud Scheduler ──► Cloud Run Job ──► GCS (landing, date=YYYY-MM-DD/) ──► BigQuery external table
 Tue–Sat 06:00 ET    equity-ingest        bars.csv.gz per trading day        market_data.minute_bars
 (sa-scheduler)      (sa-ingest)
                          ▲
                Secret Manager (Alpaca keys)
```

## Repo layout

```
ingest/      Cloud Run job: Alpaca client, rate limiter, GCS writer (Python, uv)
infra/       Terraform: APIs, bucket, secrets, IAM, registry, job, scheduler, BigQuery
scripts/     The few steps Terraform deliberately doesn't do (secrets, image deploys, manual runs)
```

## Security model

| Identity | Can do | Scope |
|---|---|---|
| `sa-ingest` (the job) | read/write objects | the landing bucket only |
| | read secret values | the two Alpaca secrets only |
| `sa-scheduler` (the trigger) | start the job | the `equity-ingest` job only |

- No JSON keys anywhere. Workloads get credentials from their attached service account.
- Secret values never touch Terraform code or state (see step 2).
- The bucket enforces public access prevention and uniform (IAM-only) access.

---

## Setup from zero

**Prerequisites:** a GCP project with billing, an [Alpaca](https://alpaca.markets) API key pair, and `terraform` (>= 1.9), `gcloud`, and `uv` installed.

```bash
gcloud auth login
gcloud auth application-default login      # credentials Terraform uses
gcloud config set project <PROJECT_ID>
```

### 1. Create the infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # set project_id and bucket_name
terraform init
terraform apply
```

On a brand-new project, an apply can fail with a temporary "internal error" while newly enabled APIs finish setting up. Wait a minute and run `terraform apply` again. Terraform replaces anything that half-failed.

### 2. Add the Alpaca keys (manual)

```bash
scripts/set-secrets.sh
```

Terraform creates the secrets but not their **values**. Anything Terraform sets is stored in plain text in `terraform.tfstate`, so the keys are entered by hand (hidden prompt). Re-run the script to rotate keys.

### 3. Build and deploy the container (manual)

```bash
scripts/deploy-ingest.sh
```

This builds `ingest/` with Cloud Build (on `linux/amd64`, so no local Docker is needed), pushes it to Artifact Registry tagged with the git commit, and points the job at it. Terraform creates the job with a placeholder image and ignores image changes (`lifecycle.ignore_changes`): **Terraform owns the job's config, deploys own the image.** Re-run this script whenever `ingest/` changes.

### 4. Smoke test

```bash
scripts/run-ingest.sh 2026-09-21 2026-09-25
bq query --use_legacy_sql=false \
  'SELECT date, COUNT(*) AS bars FROM `<PROJECT_ID>.market_data.minute_bars` GROUP BY date ORDER BY date'
```

From here, Cloud Scheduler runs the job every trading morning.

---

## Operations

| Task | Command |
|---|---|
| Ingest yesterday | `scripts/run-ingest.sh` |
| Backfill a range | `scripts/run-ingest.sh 2021-10-01 2026-10-03` |
| Backfill across tasks | `scripts/run-ingest.sh 2021-10-01 2026-10-03 4` (the account rate limit is split across tasks, so more tasks won't go faster than the API allows) |
| Trigger the schedule now | `gcloud scheduler jobs run equity-ingest-daily --location us-central1` |
| Recent runs | `gcloud run jobs executions list --job equity-ingest --region us-central1` |
| Deploy code changes | `scripts/deploy-ingest.sh` |
| Change symbols/feed | add `SYMBOLS` / `FEED` env vars to the job in `infra/ingest.tf`, then `terraform apply` |

Re-running a date range is safe: days already in GCS are skipped (`OVERWRITE=true` forces a re-fetch).

Run locally against real GCS:

```bash
cd ingest
export ALPACA_API_KEY_ID=$(gcloud secrets versions access latest --secret=alpaca-api-key-id)
export ALPACA_API_SECRET_KEY=$(gcloud secrets versions access latest --secret=alpaca-api-secret-key)
export DEST_BUCKET=<bucket_name>
START_DATE=2026-09-28 END_DATE=2026-10-02 uv run main.py
```

---

## Teardown

```bash
terraform -chdir=infra destroy
```

This removes everything Terraform manages: the job, scheduler, service accounts and IAM, secrets (including their values), the registry (including images), the BigQuery dataset, and the bucket **with all landed data**.

These are left behind:

| Leftover | Why | Clean up |
|---|---|---|
| Enabled APIs | `disable_on_destroy = false`, so destroy doesn't break other things in the project | free; ignore |
| `<PROJECT_ID>_cloudbuild` bucket | created by `gcloud builds submit`, not Terraform | `gcloud storage rm -r gs://<PROJECT_ID>_cloudbuild` |
| Logs | Cloud Logging retention | expire after 30 days |
| Local `infra/terraform.tfstate` | now empty | keep it, or delete it |

To remove *everything*, including the project: `gcloud projects delete <PROJECT_ID>`.

To rebuild afterwards, repeat steps 1–4. Secrets and images were destroyed, so steps 2 and 3 are needed again.

---

## Design notes

- **Terraform state is local.** This is a one-person project and Terraform only runs from a laptop. With a team, or with Terraform running in CI, it would move to a GCS backend for shared state and locking.
- **External table instead of loading data.** No load jobs and no duplicate storage, and new files are queryable immediately. The `date=` folder layout gives partition pruning. At larger scale, Parquet or Iceberg would be faster.
- **The API quota is the bottleneck, not compute.** Alpaca allows 200 requests/min per account. One task backfills 5 years of 10 symbols in about 15 minutes.

# ---------------------------------------------------------------------------
# Alpaca API secrets
# ---------------------------------------------------------------------------
# Terraform creates the secret *containers* only. The values are added by hand
# with `gcloud secrets versions add`, so the keys never appear in Terraform
# code or in terraform.tfstate (state stores every attribute in plain text).

resource "google_secret_manager_secret" "alpaca" {
  for_each = toset([
    "alpaca-api-key-id",
    "alpaca-api-secret-key",
  ])

  secret_id = each.value

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Ingest service account — the identity the Cloud Run job runs as
# ---------------------------------------------------------------------------

resource "google_service_account" "ingest" {
  account_id   = "sa-ingest"
  display_name = "Alpaca ingest Cloud Run job"

  depends_on = [google_project_service.apis]
}

# Least privilege: every grant below is on ONE resource (this bucket, these
# secrets), never the whole project.

# objectUser = read, list, create, delete objects. The job needs read
# (blob.exists() to skip days already landed) and delete (OVERWRITE=true
# replaces a file). It can't change bucket settings or IAM.
resource "google_storage_bucket_iam_member" "ingest_landing" {
  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectUser"
  member = google_service_account.ingest.member
}

# One binding per secret, reusing the same for_each keys as the secrets.
resource "google_secret_manager_secret_iam_member" "ingest_alpaca" {
  for_each = google_secret_manager_secret.alpaca

  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.ingest.member
}

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

# ---------------------------------------------------------------------------
# Artifact Registry — where the ingest container image lives
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  repository_id = "images"
  location      = var.region
  format        = "DOCKER"

  # Every build pushes a new image; without cleanup they pile up (and cost).
  # "keep" policies win over "delete", so: delete anything older than 30 days,
  # except the 5 most recent versions.
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "${30 * 24 * 60 * 60}s"
    }
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Cloud Run Job
# ---------------------------------------------------------------------------
# Run it (defaults to yesterday):
#   gcloud run jobs execute equity-ingest --region us-central1
# Backfill a range — env overrides apply to that one execution only:
#   gcloud run jobs execute equity-ingest --region us-central1 \
#     --update-env-vars START_DATE=2026-01-01,END_DATE=2026-06-30

resource "google_cloud_run_v2_job" "ingest" {
  name     = "equity-ingest"
  location = var.region

  # The provider defaults this to true, which blocks `terraform destroy`.
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.ingest.email
      timeout         = "600s"
      max_retries     = 1 # safe: main.py skips days already in GCS

      containers {
        # Placeholder so the job can exist before our first build. The real
        # image is deployed with `gcloud run jobs update --image` (see
        # lifecycle below), by hand now and from CI later.
        image = "us-docker.pkg.dev/cloudrun/container/job:latest"

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        env {
          name  = "DEST_BUCKET"
          value = google_storage_bucket.landing.name
        }

        env {
          name = "ALPACA_API_KEY_ID"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.alpaca["alpaca-api-key-id"].secret_id
              version = "latest"
            }
          }
        }

        env {
          name = "ALPACA_API_SECRET_KEY"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.alpaca["alpaca-api-secret-key"].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    # Terraform owns the job's config; deploys own which image runs.
    # Without this, every `terraform apply` would roll back to the placeholder.
    # client/client_version get stamped by gcloud on each update.
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  # The job reads secrets as sa-ingest, so the grants must exist first.
  # Nothing in this block references the IAM resources, so say it explicitly.
  depends_on = [
    google_secret_manager_secret_iam_member.ingest_alpaca,
    google_storage_bucket_iam_member.ingest_landing,
  ]
}

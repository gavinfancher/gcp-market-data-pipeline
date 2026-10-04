# ---------------------------------------------------------------------------
# APIs
# ---------------------------------------------------------------------------
# Terraform loads every .tf file in this folder as one config — the split
# into main.tf / storage.tf / ingest.tf is just for humans.

# for_each creates one resource per item. Each is tracked in state under its
# key, e.g. google_project_service.apis["run.googleapis.com"].
resource "google_project_service" "apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])

  service = each.value

  # Don't turn the API off on `terraform destroy` — other things in the
  # project might be using it.
  disable_on_destroy = false
}

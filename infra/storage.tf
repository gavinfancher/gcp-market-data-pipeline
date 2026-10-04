# ---------------------------------------------------------------------------
# Landing bucket
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "landing" {
  name     = var.bucket_name
  location = var.region

  # IAM only (no per-object ACLs), and never allow public access.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Deleted objects stay recoverable for 7 days.
  soft_delete_policy {
    retention_duration_seconds = 7 * 24 * 60 * 60
  }

  # Raw files are rarely read after the first month; move them to a cheaper class.
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  # Lets `terraform destroy` delete the bucket even if it holds files.
  # Fine for a portfolio project; you'd set false for real data.
  force_destroy = true

  # Terraform figures out ordering from references. This bucket doesn't
  # reference the API resource, so we state the dependency explicitly.
  depends_on = [google_project_service.apis]
}

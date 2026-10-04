# ---------------------------------------------------------------------------
# Daily trigger — Cloud Scheduler runs the ingest job every trading morning
# ---------------------------------------------------------------------------

# Scheduler gets its own identity, separate from sa-ingest. It can start the
# job and nothing else; it can't read the bucket or the Alpaca secrets.
resource "google_service_account" "scheduler" {
  account_id   = "sa-scheduler"
  display_name = "Cloud Scheduler trigger for equity-ingest"

  depends_on = [google_project_service.apis]
}

# roles/run.invoker on THIS job only (includes run.jobs.run).
resource "google_cloud_run_v2_job_iam_member" "scheduler_invoke_ingest" {
  name     = google_cloud_run_v2_job.ingest.name
  location = google_cloud_run_v2_job.ingest.location
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler.member
}

resource "google_cloud_scheduler_job" "ingest_daily" {
  name        = "equity-ingest-daily"
  region      = var.region
  description = "Run equity-ingest for the previous trading day"

  # Tue–Sat at 06:00 New York time. The job defaults to "yesterday", so this
  # covers Mon–Fri sessions (including after-hours bars, which end 20:00 ET).
  # Market holidays need no special case: Alpaca's calendar returns no
  # trading days and the job exits cleanly.
  schedule  = "0 6 * * 2-6"
  time_zone = "America/New_York"

  # If the HTTP call itself fails (not the job — Cloud Run retries tasks),
  # retry a few times with backoff.
  retry_config {
    retry_count = 3
  }

  http_target {
    http_method = "POST"
    # The same Cloud Run Admin API call that `gcloud run jobs execute` makes.
    uri = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.ingest.id}:run"

    # OAuth (not OIDC) because the target is a Google API (*.googleapis.com).
    # OIDC tokens are for calling your own services, e.g. a Cloud Run service URL.
    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoke_ingest]
}

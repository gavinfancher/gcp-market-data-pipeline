output "bucket_url" {
  value = google_storage_bucket.landing.url
}

output "ingest_service_account" {
  value = google_service_account.ingest.email
}

output "image_repo" {
  description = "Push images here, e.g. <image_repo>/ingest:<tag>"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "ingest_job" {
  value = google_cloud_run_v2_job.ingest.name
}

output "bars_table" {
  value = "${var.project_id}.${google_bigquery_dataset.market_data.dataset_id}.${google_bigquery_table.minute_bars.table_id}"
}

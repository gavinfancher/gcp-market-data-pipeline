output "bucket_url" {
  value = google_storage_bucket.landing.url
}

output "ingest_service_account" {
  value = google_service_account.ingest.email
}

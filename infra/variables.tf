variable "project_id" {
  description = "GCP project to deploy into."
  type        = string
}

variable "region" {
  description = "Region for the bucket and Cloud Run job. Keep them together to avoid egress cost."
  type        = string
  default     = "us-central1"
}

variable "bucket_name" {
  description = "Landing bucket for raw files. Must be globally unique across all of GCS."
  type        = string
}

# Which Terraform and which provider plugins this config needs.
# `terraform init` reads this, downloads the providers, and records exact
# versions in .terraform.lock.hcl (commit that file — it's like uv.lock).

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.0"
    }
  }

  # State starts out local (terraform.tfstate in this folder). In a later step
  # we move it to a GCS bucket with `terraform init -migrate-state`.
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Every resource that supports labels gets these, for cost reports and filtering.
  default_labels = {
    app        = "equity-lakehouse"
    managed-by = "terraform"
  }
}

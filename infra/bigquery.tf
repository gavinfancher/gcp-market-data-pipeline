# ---------------------------------------------------------------------------
# BigQuery — query the landed CSVs in place (no load jobs, no copies)
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "market_data" {
  dataset_id = "market_data"
  location   = var.region # must match the bucket's location for external tables

  # Lets `terraform destroy` remove the dataset even if it holds tables.
  delete_contents_on_destroy = true

  depends_on = [google_project_service.apis]
}

locals {
  bars_prefix = "${google_storage_bucket.landing.url}/landing/alpaca/minute_bars"
}

# An external table is just metadata: a schema plus a pointer to files in GCS.
# Every query reads the files directly, so new days show up immediately.
resource "google_bigquery_table" "minute_bars" {
  dataset_id          = google_bigquery_dataset.market_data.dataset_id
  table_id            = "minute_bars"
  deletion_protection = false

  external_data_configuration {
    source_format = "CSV"
    compression   = "GZIP"
    autodetect    = false
    source_uris   = ["${local.bars_prefix}/*"]

    csv_options {
      quote             = "\""
      skip_leading_rows = 1 # header row
    }

    # The job writes .../date=YYYY-MM-DD/bars.csv.gz. Hive partitioning turns
    # that folder name into a `date` column, and a WHERE on `date` means
    # BigQuery only reads the matching folders (less data scanned = cheaper).
    hive_partitioning_options {
      mode              = "CUSTOM"
      source_uri_prefix = "${local.bars_prefix}/{date:DATE}"
    }

    # Columns in the CSV, in file order. `date` is NOT listed — it comes from
    # the folder path above.
    schema = jsonencode([
      { name = "symbol", type = "STRING" },
      { name = "timestamp", type = "TIMESTAMP", description = "Bar start, UTC" },
      { name = "open", type = "FLOAT64" },
      { name = "high", type = "FLOAT64" },
      { name = "low", type = "FLOAT64" },
      { name = "close", type = "FLOAT64" },
      { name = "volume", type = "INT64" },
      { name = "trade_count", type = "INT64" },
      { name = "vwap", type = "FLOAT64", description = "Volume-weighted average price" },
    ])
  }
}

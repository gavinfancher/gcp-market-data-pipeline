"""
Cloud Run Job: copy Massive minute-aggregate flat files (S3) into GCS.

Work is derived from dates, not a manifest:
  - START_DATE / END_DATE (YYYY-MM-DD, inclusive). Both default to yesterday (New York time).
  - Cloud Run sets CLOUD_RUN_TASK_INDEX / CLOUD_RUN_TASK_COUNT. Task i copies every
    date where day_number % TASK_COUNT == i, so `--tasks 20` splits a backfill 20 ways.

Idempotent: files already in GCS are skipped. Weekends/holidays have no source file
and are skipped too.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError
from google.cloud import storage

SOURCE_BUCKET = "flatfiles"
DATASET_PREFIX = "us_stocks_sip/minute_aggs_v1"


class JsonFormatter(logging.Formatter):
    """One JSON object per line — Cloud Logging parses `severity` and `message`."""

    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"severity": record.levelname, "message": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("ingest")


def env_date(name: str, default: date) -> date:
    value = os.environ.get(name)
    return date.fromisoformat(value) if value else default


def dates_for_task(start: date, end: date, task_index: int, task_count: int) -> list[date]:
    days = (end - start).days + 1
    return [
        start + timedelta(days=n)
        for n in range(days)
        if n % task_count == task_index and (start + timedelta(days=n)).weekday() < 5
    ]


def source_key(day: date) -> str:
    return f"{DATASET_PREFIX}/{day:%Y}/{day:%m}/{day.isoformat()}.csv.gz"


def copy_day(s3, bucket: storage.Bucket, dest_prefix: str, day: date) -> str:
    key = source_key(day)
    blob = bucket.blob(f"{dest_prefix}/{key}")
    if blob.exists():
        return "exists"
    try:
        obj = s3.get_object(Bucket=SOURCE_BUCKET, Key=key)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return "missing"  # market holiday, or not published yet
        raise
    blob.upload_from_file(obj["Body"], size=obj["ContentLength"], content_type="application/gzip")
    return "copied"


def main() -> int:
    yesterday = datetime.now(ZoneInfo("America/New_York")).date() - timedelta(days=1)
    start = env_date("START_DATE", yesterday)
    end = env_date("END_DATE", yesterday)
    task_index = int(os.environ.get("CLOUD_RUN_TASK_INDEX", "0"))
    task_count = int(os.environ.get("CLOUD_RUN_TASK_COUNT", "1"))
    workers = int(os.environ.get("WORKERS", "8"))
    dest_bucket = os.environ["DEST_BUCKET"]
    dest_prefix = os.environ.get("DEST_PREFIX", "landing").strip("/")

    days = dates_for_task(start, end, task_index, task_count)
    log.info(f"task {task_index}/{task_count}: {len(days)} weekdays in {start}..{end}")

    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ.get("S3_ENDPOINT", "https://files.massive.com"),
        aws_access_key_id=os.environ["MASSIVE_ACCESS_KEY"],
        aws_secret_access_key=os.environ["MASSIVE_SECRET_KEY"],
        config=BotoConfig(signature_version="s3v4", retries={"max_attempts": 5, "mode": "standard"}),
    )
    bucket = storage.Client().bucket(dest_bucket)

    def run(day: date) -> str:
        try:
            result = copy_day(s3, bucket, dest_prefix, day)
            log.info(f"{day} {result}")
        except Exception as exc:
            result = "failed"
            log.error(f"{day} failed: {exc}")
        return result

    with ThreadPoolExecutor(max_workers=workers) as pool:
        counts = Counter(pool.map(run, days))

    log.info(f"task {task_index} done: {dict(counts)}")
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())

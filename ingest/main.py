"""
Cloud Run Job: Alpaca 1-minute bars → GCS, one gzipped CSV per trading day.

    gs://$DEST_BUCKET/landing/alpaca/minute_bars/date=YYYY-MM-DD/bars.csv.gz

Configuration (all env vars):
  ALPACA_API_KEY_ID / ALPACA_API_SECRET_KEY   from Secret Manager
  DEST_BUCKET                                  landing bucket
  START_DATE / END_DATE                        YYYY-MM-DD inclusive; default yesterday (New York)
  SYMBOLS                                      comma-separated; default below
  FEED                                         sip (default) or iex
  RATE_LIMIT_RPM                               account-wide budget; default 180 (hard cap 200)
  WORKERS                                      days fetched in parallel per task; default 4
  OVERWRITE                                    "true" to re-fetch days already in GCS

Parallelism: Cloud Run sets CLOUD_RUN_TASK_INDEX / CLOUD_RUN_TASK_COUNT. Task i takes
every TASK_COUNT-th trading day. Alpaca's rate limit is per *account*, so each task
gets RATE_LIMIT_RPM / TASK_COUNT — more tasks won't beat the API quota.
"""

from __future__ import annotations

import csv
import gzip
import io
import json
import logging
import os
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from google.cloud import storage

from alpaca import COLUMNS, AlpacaClient
from ratelimit import RateLimiter

MARKET_TZ = ZoneInfo("America/New_York")
DEST_PREFIX = "landing/alpaca/minute_bars"
DEFAULT_SYMBOLS = "AAPL,MSFT,NVDA,AMZN,GOOGL,META,TSLA,JPM,V,JNJ"


class JsonFormatter(logging.Formatter):
    """One JSON object per line — Cloud Logging parses `severity` and `message`."""

    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"severity": record.levelname, "message": record.getMessage()})


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logging.getLogger("httpx").setLevel(logging.WARNING)  # it logs every request at INFO
log = logging.getLogger("ingest")


def env_date(name: str, default: date) -> date:
    value = os.environ.get(name)
    return date.fromisoformat(value) if value else default


def blob_path(day: date) -> str:
    return f"{DEST_PREFIX}/date={day.isoformat()}/bars.csv.gz"


def to_csv_gz(rows: list[tuple]) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb") as gz, io.TextIOWrapper(gz, newline="") as text:
        writer = csv.writer(text)
        writer.writerow(COLUMNS)
        writer.writerows(rows)
    return buf.getvalue()


def ingest_day(client: AlpacaClient, bucket: storage.Bucket, day: date, symbols: list[str], overwrite: bool) -> str:
    blob = bucket.blob(blob_path(day))
    if not overwrite and blob.exists():
        return "exists"
    # Whole calendar day in New York time, so pre/post-market bars are included.
    start = datetime(day.year, day.month, day.day, tzinfo=MARKET_TZ)
    rows = client.get_bars(symbols, start.isoformat(), (start + timedelta(days=1)).isoformat())
    if not rows:
        return "empty"
    blob.upload_from_string(to_csv_gz(rows), content_type="application/gzip")
    log.info(f"{day} wrote {len(rows)} rows")
    return "written"


def main() -> int:
    yesterday = datetime.now(MARKET_TZ).date() - timedelta(days=1)
    start = env_date("START_DATE", yesterday)
    end = env_date("END_DATE", yesterday)
    symbols = [s.strip().upper() for s in os.environ.get("SYMBOLS", DEFAULT_SYMBOLS).split(",") if s.strip()]
    feed = os.environ.get("FEED", "sip")
    workers = int(os.environ.get("WORKERS", "4"))
    overwrite = os.environ.get("OVERWRITE", "").lower() == "true"
    task_index = int(os.environ.get("CLOUD_RUN_TASK_INDEX", "0"))
    task_count = int(os.environ.get("CLOUD_RUN_TASK_COUNT", "1"))
    rpm = float(os.environ.get("RATE_LIMIT_RPM", "180")) / task_count

    bucket = storage.Client().bucket(os.environ["DEST_BUCKET"])
    limiter = RateLimiter(rate_per_min=rpm)

    with AlpacaClient(
        os.environ["ALPACA_API_KEY_ID"], os.environ["ALPACA_API_SECRET_KEY"], limiter, feed=feed
    ) as client:
        days = client.trading_days(start, end)[task_index::task_count]
        log.info(
            f"task {task_index}/{task_count}: {len(days)} trading days in {start}..{end}, "
            f"{len(symbols)} symbols, feed={feed}, {rpm:.0f} rpm"
        )

        def run(day: date) -> str:
            try:
                return ingest_day(client, bucket, day, symbols, overwrite)
            except Exception as exc:
                log.error(f"{day} failed: {exc}")
                return "failed"

        with ThreadPoolExecutor(max_workers=workers) as pool:
            counts = Counter(pool.map(run, days))

    log.info(f"task {task_index} done: {dict(counts)}")
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())

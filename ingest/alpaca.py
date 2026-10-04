"""Thin httpx client for the Alpaca endpoints we ingest from.

Every HTTP call goes through the shared RateLimiter; responses are inspected for
X-RateLimit-Remaining / X-RateLimit-Reset so we throttle proactively and honour
429 backoffs. An httpx.Client is safe to share across threads.
"""

from __future__ import annotations

import logging
import time
from datetime import date

import httpx

from ratelimit import RateLimiter

log = logging.getLogger("alpaca")

DATA_BASE = "https://data.alpaca.markets"
TRADING_BASE = "https://paper-api.alpaca.markets"  # calendar is account-agnostic

# t/o/h/l/c/v/n/vw -> timestamp/open/high/low/close/volume/trade_count/vwap, prefixed by symbol.
BAR_FIELDS = ("t", "o", "h", "l", "c", "v", "n", "vw")
COLUMNS = ("symbol", "timestamp", "open", "high", "low", "close", "volume", "trade_count", "vwap")


class AlpacaClient:
    def __init__(self, key: str, secret: str, limiter: RateLimiter, *, feed: str = "sip", timeout: float = 30.0):
        self._limiter = limiter
        self._feed = feed
        self._client = httpx.Client(
            headers={"APCA-API-KEY-ID": key, "APCA-API-SECRET-KEY": secret},
            timeout=timeout,
        )

    def __enter__(self) -> "AlpacaClient":
        return self

    def __exit__(self, *exc) -> None:
        self._client.close()

    def _get(self, url: str, params: dict, *, max_429: int = 6) -> dict:
        attempts = 0
        while True:
            self._limiter.acquire()
            resp = self._client.get(url, params=params)

            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")

            if resp.status_code == 429:
                attempts += 1
                if attempts > max_429:
                    resp.raise_for_status()
                wait = self._reset_wait(reset)
                log.warning(f"429 rate-limited; backing off {wait:.1f}s (attempt {attempts})")
                self._limiter.back_off(wait)
                continue

            # Proactively pause everyone if we're about to run dry this window.
            if remaining is not None and int(remaining) <= 2:
                self._limiter.back_off(self._reset_wait(reset))

            resp.raise_for_status()
            return resp.json()

    @staticmethod
    def _reset_wait(reset_epoch: str | None) -> float:
        if not reset_epoch:
            return 1.0
        return max(0.5, int(reset_epoch) - time.time() + 0.5)

    def get_bars(self, symbols: list[str], start: str, end: str, *, timeframe: str = "1Min") -> list[tuple]:
        """Rows of (symbol, t, o, h, l, c, v, n, vw) over [start, end), following all pages."""
        params = {
            "symbols": ",".join(symbols),
            "timeframe": timeframe,
            "start": start,
            "end": end,
            "feed": self._feed,
            "limit": 10000,
        }
        rows: list[tuple] = []
        while True:
            body = self._get(f"{DATA_BASE}/v2/stocks/bars", params)
            for symbol, bars in (body.get("bars") or {}).items():
                rows.extend((symbol, *(bar.get(f) for f in BAR_FIELDS)) for bar in bars)
            page_token = body.get("next_page_token")
            if not page_token:
                return rows
            params["page_token"] = page_token

    def trading_days(self, start: date, end: date) -> list[date]:
        """Trading days in [start, end] per Alpaca's calendar (holidays handled)."""
        body = self._get(f"{TRADING_BASE}/v2/calendar", {"start": start.isoformat(), "end": end.isoformat()})
        return [date.fromisoformat(entry["date"]) for entry in body]

"""Thread-safe token-bucket rate limiter for Alpaca's per-minute request cap.

Alpaca Basic allows 200 requests/min per account. The bucket is shared across all
worker threads in a task so the aggregate rate stays under the ceiling. `back_off()`
lets the client impose a hard pause when the server says so (429 or a near-zero
X-RateLimit-Remaining).
"""

from __future__ import annotations

import threading
import time


class RateLimiter:
    def __init__(self, rate_per_min: float, burst: int | None = None):
        self._rate = rate_per_min / 60.0  # tokens per second
        self._capacity = float(burst or max(1, int(rate_per_min)))
        self._tokens = self._capacity
        self._updated = time.monotonic()
        self._blocked_until = 0.0
        self._lock = threading.Lock()

    def acquire(self) -> None:
        """Block until one request is allowed, then consume a token."""
        while True:
            with self._lock:
                now = time.monotonic()
                wait = self._blocked_until - now
                if wait <= 0:
                    self._tokens = min(
                        self._capacity,
                        self._tokens + (now - self._updated) * self._rate,
                    )
                    self._updated = now
                    if self._tokens >= 1:
                        self._tokens -= 1
                        return
                    wait = (1 - self._tokens) / self._rate
            time.sleep(min(wait, 1.0))

    def back_off(self, seconds: float) -> None:
        """Impose a hard pause for everyone (e.g. after a 429)."""
        if seconds <= 0:
            return
        with self._lock:
            self._blocked_until = max(self._blocked_until, time.monotonic() + seconds)

"""Idle-timeout bookkeeping for the on-demand worker lifecycle (docs/01 §3.2)."""

from __future__ import annotations

import time
from typing import Callable


class IdleTracker:
    """Records the time of the last request and reports idle expiry.

    A ``timeout_sec`` of 0 (or less) disables the idle timeout.
    """

    def __init__(
        self, timeout_sec: float, clock: Callable[[], float] = time.monotonic
    ) -> None:
        self.timeout_sec = timeout_sec
        self._clock = clock
        self._last = clock()

    def touch(self) -> None:
        self._last = self._clock()

    @property
    def idle_seconds(self) -> float:
        return self._clock() - self._last

    def is_expired(self) -> bool:
        return self.timeout_sec > 0 and self.idle_seconds >= self.timeout_sec

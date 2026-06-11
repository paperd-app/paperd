from __future__ import annotations

from paperd_worker.idle import IdleTracker


class FakeClock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def test_not_expired_before_timeout() -> None:
    clock = FakeClock()
    tracker = IdleTracker(timeout_sec=600, clock=clock)
    clock.advance(599)
    assert tracker.idle_seconds == 599
    assert not tracker.is_expired()


def test_expired_after_timeout() -> None:
    clock = FakeClock()
    tracker = IdleTracker(timeout_sec=600, clock=clock)
    clock.advance(600)
    assert tracker.is_expired()


def test_touch_resets_idle_time() -> None:
    clock = FakeClock()
    tracker = IdleTracker(timeout_sec=600, clock=clock)
    clock.advance(599)
    tracker.touch()
    assert tracker.idle_seconds == 0
    clock.advance(599)
    assert not tracker.is_expired()
    clock.advance(1)
    assert tracker.is_expired()


def test_zero_timeout_disables_expiry() -> None:
    clock = FakeClock()
    tracker = IdleTracker(timeout_sec=0, clock=clock)
    clock.advance(1_000_000)
    assert not tracker.is_expired()


def test_middleware_touches_tracker() -> None:
    from fastapi.testclient import TestClient

    from paperd_worker.app import create_app
    from conftest import TOKEN, FakeConversionEngine, FakeEmbeddingEngine

    clock = FakeClock()
    tracker = IdleTracker(timeout_sec=600, clock=clock)
    app = create_app(
        TOKEN, FakeConversionEngine(), FakeEmbeddingEngine(), idle_tracker=tracker
    )
    clock.advance(700)
    assert tracker.is_expired()
    with TestClient(app) as client:
        # Even unauthenticated requests count as activity.
        client.get("/health")
    assert tracker.idle_seconds == 0
    assert not tracker.is_expired()

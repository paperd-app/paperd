from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from paperd_worker.app import create_app
from paperd_worker.engines import ConvertOptions, ProgressCallback, Task
from paperd_worker.errors import WorkerError

TOKEN = "test-token-123"


class FakeConversionEngine:
    """Writes dummy output files and reports a little progress."""

    def convert(
        self,
        pdf_path: str,
        output_dir: str,
        options: ConvertOptions,
        progress_cb: ProgressCallback,
    ) -> None:
        progress_cb("layout", 1, 2)
        progress_cb("export", 2, 2)
        out = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "paper.md").write_text(f"# Converted from {pdf_path}\n", encoding="utf-8")
        (out / "paper.docling.json").write_text(
            json.dumps({"source": pdf_path}), encoding="utf-8"
        )


class FailingConversionEngine:
    def __init__(self, error: WorkerError | None = None) -> None:
        self.error = error or WorkerError("PDF_ENCRYPTED", "PDF is password-protected")

    def convert(self, pdf_path, output_dir, options, progress_cb) -> None:
        raise self.error


class SlowConversionEngine:
    def __init__(self, duration: float) -> None:
        self.duration = duration

    def convert(self, pdf_path, output_dir, options, progress_cb) -> None:
        time.sleep(self.duration)


class FakeEmbeddingEngine:
    """Deterministic hash-based 8-dimensional embeddings."""

    model_name = "fake-embedder"
    dimensions = 8
    is_loaded = True

    def embed(self, texts: list[str], task: Task) -> list[list[float]]:
        out: list[list[float]] = []
        for text in texts:
            digest = hashlib.sha256(f"{task}:{text}".encode()).digest()
            out.append([byte / 255.0 for byte in digest[: self.dimensions]])
        return out


@pytest.fixture
def token() -> str:
    return TOKEN


@pytest.fixture
def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def pdf_file(tmp_path: Path) -> Path:
    pdf = tmp_path / "paper.pdf"
    pdf.write_bytes(b"%PDF-1.4 fake")
    return pdf


@pytest.fixture
def client(token: str):
    app = create_app(token, FakeConversionEngine(), FakeEmbeddingEngine())
    with TestClient(app) as test_client:
        yield test_client


def wait_for_job(client: TestClient, auth: dict[str, str], job_id: str, timeout: float = 5.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        response = client.get(f"/jobs/{job_id}", headers=auth)
        assert response.status_code == 200
        body = response.json()
        if body["status"] in ("succeeded", "failed"):
            return body
        time.sleep(0.02)
    raise AssertionError(f"job {job_id} did not finish within {timeout}s")

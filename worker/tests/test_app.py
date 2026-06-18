from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from paperd_worker import __version__
from paperd_worker.app import create_app
from paperd_worker.errors import WorkerError

from conftest import (
    FailingConversionEngine,
    FakeConversionEngine,
    FakeEmbeddingEngine,
    SlowConversionEngine,
    wait_for_job,
)


def assert_error_body(body: dict, code: str) -> None:
    assert set(body) == {"error"}
    assert body["error"]["code"] == code
    assert isinstance(body["error"]["message"], str)


class TestAuth:
    def test_missing_token_is_401(self, client: TestClient) -> None:
        response = client.get("/health")
        assert response.status_code == 401
        assert_error_body(response.json(), "UNAUTHORIZED")

    def test_wrong_token_is_401(self, client: TestClient) -> None:
        response = client.get("/health", headers={"Authorization": "Bearer nope"})
        assert response.status_code == 401
        assert_error_body(response.json(), "UNAUTHORIZED")

    def test_correct_token_succeeds(self, client: TestClient, auth) -> None:
        assert client.get("/health", headers=auth).status_code == 200


class TestHealth:
    def test_shape(self, client: TestClient, auth) -> None:
        body = client.get("/health", headers=auth).json()
        assert body == {"status": "ok", "model_loaded": True, "version": __version__}


class TestEmbed:
    def test_roundtrip(self, client: TestClient, auth) -> None:
        texts = ["chunk text 1", "chunk text 2", "日本語クエリ"]
        response = client.post(
            "/embed", headers=auth, json={"texts": texts, "task": "passage"}
        )
        assert response.status_code == 200
        body = response.json()
        assert body["model"] == "fake-embedder"
        assert body["dimensions"] == 8
        assert len(body["embeddings"]) == len(texts)
        assert all(len(vector) == body["dimensions"] for vector in body["embeddings"])

    def test_deterministic_and_task_sensitive(self, client: TestClient, auth) -> None:
        def embed(task: str):
            return client.post(
                "/embed", headers=auth, json={"texts": ["same text"], "task": task}
            ).json()["embeddings"]

        assert embed("query") == embed("query")
        assert embed("query") != embed("passage")

    def test_invalid_task_rejected(self, client: TestClient, auth) -> None:
        response = client.post(
            "/embed", headers=auth, json={"texts": ["x"], "task": "banana"}
        )
        assert response.status_code == 422


class TestConvert:
    def test_convert_succeeds_and_writes_outputs(
        self, client: TestClient, auth, pdf_file: Path, tmp_path: Path
    ) -> None:
        output_dir = tmp_path / "out"
        response = client.post(
            "/convert",
            headers=auth,
            json={"pdf_path": str(pdf_file), "output_dir": str(output_dir)},
        )
        assert response.status_code == 202
        job_id = response.json()["job_id"]
        assert job_id.startswith("w-")

        body = wait_for_job(client, auth, job_id)
        assert body["status"] == "succeeded"
        assert body["error"] is None
        assert body["job_id"] == job_id
        assert body["progress"] == {"page": 2, "total_pages": 2}
        assert (output_dir / "paper.md").is_file()
        assert json.loads((output_dir / "paper.docling.json").read_text()) == {
            "source": str(pdf_file)
        }

    def test_missing_pdf_is_404(self, client: TestClient, auth, tmp_path: Path) -> None:
        response = client.post(
            "/convert",
            headers=auth,
            json={"pdf_path": str(tmp_path / "nope.pdf"), "output_dir": str(tmp_path)},
        )
        assert response.status_code == 404
        assert_error_body(response.json(), "NOT_FOUND")

    def test_failed_conversion_propagates_error_code(
        self, token: str, auth, pdf_file: Path, tmp_path: Path
    ) -> None:
        app = create_app(token, FailingConversionEngine(), FakeEmbeddingEngine())
        with TestClient(app) as client:
            response = client.post(
                "/convert",
                headers=auth,
                json={"pdf_path": str(pdf_file), "output_dir": str(tmp_path)},
            )
            assert response.status_code == 202
            body = wait_for_job(client, auth, response.json()["job_id"])
            assert body["status"] == "failed"
            assert body["error"] == {
                "code": "PDF_ENCRYPTED",
                "message": "PDF is password-protected",
            }

    def test_unexpected_exception_becomes_internal(
        self, token: str, auth, pdf_file: Path, tmp_path: Path
    ) -> None:
        engine = FailingConversionEngine()
        engine.error = RuntimeError("boom")  # type: ignore[assignment]
        app = create_app(token, engine, FakeEmbeddingEngine())
        with TestClient(app) as client:
            response = client.post(
                "/convert",
                headers=auth,
                json={"pdf_path": str(pdf_file), "output_dir": str(tmp_path)},
            )
            body = wait_for_job(client, auth, response.json()["job_id"])
            assert body["status"] == "failed"
            assert body["error"]["code"] == "INTERNAL"

    def test_timeout(self, token: str, auth, pdf_file: Path, tmp_path: Path) -> None:
        app = create_app(token, SlowConversionEngine(duration=2.0), FakeEmbeddingEngine())
        with TestClient(app) as client:
            response = client.post(
                "/convert",
                headers=auth,
                json={
                    "pdf_path": str(pdf_file),
                    "output_dir": str(tmp_path),
                    "options": {"timeout_sec": 1},
                },
            )
            body = wait_for_job(client, auth, response.json()["job_id"], timeout=10)
            assert body["status"] == "failed"
            assert body["error"]["code"] == "TIMEOUT"


class TestJobs:
    def test_unknown_job_id_is_404(self, client: TestClient, auth) -> None:
        response = client.get("/jobs/w-deadbeef", headers=auth)
        assert response.status_code == 404
        assert_error_body(response.json(), "NOT_FOUND")


class SlowEmbeddingEngine:
    """モデルロードを模した遅いembedder（イベントループ非ブロックの回帰テスト用）"""

    model_name = "slow-model"
    dimensions = 4
    is_loaded = False

    def embed(self, texts, task):
        import time

        time.sleep(2.0)
        self.is_loaded = True
        return [[0.0] * 4 for _ in texts]


def test_slow_embed_does_not_block_other_endpoints(tmp_path):
    """embed実行中（モデルロード中）でも他エンドポイントが即応答すること。

    回帰: async defエンドポイントがブロッキングのembedを直接呼んでいたため、
    embeddingモデル初回ロード中にイベントループ全体が停止し、/convertの202応答すら
    60秒を超えてクライアント側がタイムアウトしていた。
    """
    import threading
    import time

    from fastapi.testclient import TestClient

    from paperd_worker.app import create_app

    app = create_app(
        token="tok",
        conversion_engine=FakeConversionEngine(),
        embedding_engine=SlowEmbeddingEngine(),
    )
    headers = {"Authorization": "Bearer tok"}
    with TestClient(app) as client:
        result: dict = {}

        def slow_embed():
            result["embed"] = client.post(
                "/embed", json={"texts": ["x"], "task": "query"}, headers=headers
            )

        thread = threading.Thread(target=slow_embed)
        thread.start()
        time.sleep(0.3)  # embedがスレッドに入るのを待つ

        start = time.monotonic()
        health = client.get("/health", headers=headers)
        elapsed = time.monotonic() - start

        thread.join()
        assert health.status_code == 200
        assert elapsed < 1.0, f"/healthがembedにブロックされた: {elapsed:.2f}s"
        assert result["embed"].status_code == 200


class OptionRecordingEngine(FakeConversionEngine):
    """convertへ渡されたoptionsを記録する"""

    def __init__(self) -> None:
        self.last_options = None

    def convert(self, pdf_path, output_dir, options, progress_cb) -> None:
        self.last_options = options
        super().convert(pdf_path, output_dir, options, progress_cb)


def test_convert_options_accept_quality_flags(tmp_path):
    """高精度再変換オプション（force_ocr / formula_enrichment）が受理され
    エンジンへ渡ること（docs/05 §3.1 / §5.1）"""
    from paperd_worker.app import create_app
    from conftest import TOKEN, FakeEmbeddingEngine

    engine = OptionRecordingEngine()
    app = create_app(token=TOKEN, conversion_engine=engine, embedding_engine=FakeEmbeddingEngine())
    headers = {"Authorization": f"Bearer {TOKEN}"}
    with TestClient(app) as client:
        pdf = tmp_path / "in.pdf"
        pdf.write_bytes(b"%PDF-1.4 x")
        res = client.post(
            "/convert",
            json={
                "pdf_path": str(pdf),
                "output_dir": str(tmp_path / "out"),
                "options": {"force_ocr": True, "formula_enrichment": True},
            },
            headers=headers,
        )
        assert res.status_code == 202
        wait_for_job(client, headers, res.json()["job_id"])
    opts = engine.last_options
    assert opts.force_ocr is True
    assert opts.formula_enrichment is True
    assert opts.ocr is False  # 既定値は維持


def test_embed_unexpected_exception_returns_internal_with_reason(tmp_path):
    """embed中の予期しない例外（Metal/ML runtimeエラー等）は理由つきINTERNALで返ること"""
    from paperd_worker.app import create_app
    from conftest import TOKEN, FakeConversionEngine

    class ExplodingEmbedder:
        model_name = "boom"
        dimensions = 4
        is_loaded = True

        def embed(self, texts, task):
            raise RuntimeError("ML backend out of memory")

    app = create_app(token=TOKEN, conversion_engine=FakeConversionEngine(),
                     embedding_engine=ExplodingEmbedder())
    with TestClient(app) as client:
        res = client.post("/embed", json={"texts": ["x"], "task": "query"},
                          headers={"Authorization": f"Bearer {TOKEN}"})
    assert res.status_code == 500
    body = res.json()["error"]
    assert body["code"] == "INTERNAL"
    assert "ML backend out of memory" in body["message"]

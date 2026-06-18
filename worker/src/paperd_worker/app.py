"""FastAPI application factory (docs/05 §3, docs/01 §3.1)."""

from __future__ import annotations

import secrets
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, AsyncIterator

import anyio.to_thread

from fastapi import Depends, FastAPI, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import __version__
from .engines import ConversionEngine, ConvertOptions, EmbeddingEngine, Task
from .errors import WorkerError
from .idle import IdleTracker
from .jobs import JobStore


class ConvertRequest(BaseModel):
    pdf_path: str
    output_dir: str
    options: ConvertOptions = Field(default_factory=ConvertOptions)


class EmbedRequest(BaseModel):
    texts: list[str]
    task: Task


def create_app(
    token: str,
    conversion_engine: ConversionEngine,
    embedding_engine: EmbeddingEngine,
    *,
    idle_tracker: IdleTracker | None = None,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        yield
        jobs.shutdown()

    app = FastAPI(title="paperd-worker", version=__version__, lifespan=lifespan)
    jobs = JobStore(conversion_engine)
    expected_auth = f"Bearer {token}"

    async def require_auth(
        authorization: Annotated[str | None, Header()] = None,
    ) -> None:
        if authorization is None or not secrets.compare_digest(
            authorization, expected_auth
        ):
            raise WorkerError("UNAUTHORIZED", "missing or invalid bearer token")

    @app.exception_handler(WorkerError)
    async def worker_error_handler(request: Request, exc: WorkerError) -> JSONResponse:
        return JSONResponse(status_code=exc.http_status, content={"error": exc.to_dict()})

    if idle_tracker is not None:

        @app.middleware("http")
        async def record_last_request(request: Request, call_next):
            idle_tracker.touch()
            return await call_next(request)

    authed = {"dependencies": [Depends(require_auth)]}

    @app.post("/convert", status_code=202, **authed)
    async def convert(req: ConvertRequest) -> dict[str, str]:
        if not Path(req.pdf_path).is_file():
            raise WorkerError("NOT_FOUND", f"input file not found: {req.pdf_path}")
        job_id = jobs.submit(req.pdf_path, req.output_dir, req.options)
        return {"job_id": job_id}

    @app.get("/jobs/{job_id}", **authed)
    async def get_job(job_id: str) -> dict[str, object]:
        job = jobs.get(job_id)
        if job is None:
            raise WorkerError("NOT_FOUND", f"unknown job id: {job_id}")
        return job.to_dict()

    @app.post("/embed", **authed)
    async def embed(req: EmbedRequest) -> dict[str, object]:
        # embedはモデルのロード/推論でブロックする。イベントループを塞ぐと
        # /convert(202)や/healthまで応答不能になりクライアント側がタイムアウトするため、
        # 必ずスレッドプールで実行する
        try:
            embeddings = await anyio.to_thread.run_sync(
                lambda: embedding_engine.embed(req.texts, req.task)
            )
        except WorkerError:
            raise
        except Exception as exc:  # Metal/ML runtimeエラー等。理由をエラーボディに乗せる
            raise WorkerError("INTERNAL", f"embedding failed: {exc}") from exc
        return {
            "embeddings": embeddings,
            "model": embedding_engine.model_name,
            "dimensions": embedding_engine.dimensions,
        }

    @app.get("/health", **authed)
    async def health() -> dict[str, object]:
        return {
            "status": "ok",
            "model_loaded": embedding_engine.is_loaded,
            "version": __version__,
        }

    return app

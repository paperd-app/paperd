"""In-memory job store for async conversion jobs (docs/05 §3.1–3.2).

Conversions run on a single background worker thread, so jobs are serialized
per design (docs/04 §8: convert jobs are a single queue).
"""

from __future__ import annotations

import secrets
import threading
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeoutError
from dataclasses import dataclass, field

from .engines import ConversionEngine, ConvertOptions
from .errors import WorkerError

Status = str  # queued | running | succeeded | failed
Stage = str  # load | ocr | layout | table | export


@dataclass
class Job:
    job_id: str
    status: Status = "queued"
    stage: Stage | None = None
    progress: dict[str, int] | None = None
    error: dict[str, str] | None = None
    pdf_path: str = ""
    output_dir: str = ""
    options: ConvertOptions = field(default_factory=ConvertOptions)

    def to_dict(self) -> dict[str, object]:
        return {
            "job_id": self.job_id,
            "status": self.status,
            "stage": self.stage,
            "progress": self.progress,
            "error": self.error,
        }


class JobStore:
    """Tracks conversion jobs and runs them on one background thread."""

    def __init__(self, engine: ConversionEngine) -> None:
        self._engine = engine
        self._jobs: dict[str, Job] = {}
        self._lock = threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="convert")

    def submit(self, pdf_path: str, output_dir: str, options: ConvertOptions) -> str:
        job_id = "w-" + secrets.token_hex(8)
        job = Job(job_id=job_id, pdf_path=pdf_path, output_dir=output_dir, options=options)
        with self._lock:
            self._jobs[job_id] = job
        self._executor.submit(self._run, job)
        return job_id

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def shutdown(self) -> None:
        self._executor.shutdown(wait=False, cancel_futures=True)

    def _run(self, job: Job) -> None:
        job.status = "running"
        job.stage = "load"

        def progress_cb(stage: str, page: int | None, total_pages: int | None) -> None:
            job.stage = stage
            if page is not None and total_pages is not None:
                job.progress = {"page": page, "total_pages": total_pages}

        try:
            self._convert_with_timeout(job, progress_cb)
            job.status = "succeeded"
        except WorkerError as exc:
            job.status = "failed"
            job.error = exc.to_dict()
        except Exception as exc:  # noqa: BLE001 — job boundary
            job.status = "failed"
            job.error = {"code": "INTERNAL", "message": str(exc)}

    def _convert_with_timeout(self, job: Job, progress_cb) -> None:
        timeout = job.options.timeout_sec
        if timeout <= 0:
            self._engine.convert(job.pdf_path, job.output_dir, job.options, progress_cb)
            return
        # Run the conversion on a nested thread so we can observe the timeout.
        # Python threads cannot be killed, so on timeout the underlying
        # conversion keeps running detached until it finishes on its own.
        inner = ThreadPoolExecutor(max_workers=1, thread_name_prefix="convert-run")
        future = inner.submit(
            self._engine.convert, job.pdf_path, job.output_dir, job.options, progress_cb
        )
        try:
            future.result(timeout=timeout)
        except FutureTimeoutError:
            raise WorkerError(
                "TIMEOUT", f"conversion exceeded timeout_sec={timeout}"
            ) from None
        finally:
            inner.shutdown(wait=False, cancel_futures=True)

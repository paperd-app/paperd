# paperd-worker

Python worker for paperd: PDF → Markdown/JSON conversion (Docling) and
embedding generation (Qwen3-Embedding-0.6B 4bit via MLX) over localhost HTTP. See
`docs/01-architecture.md` §3 and `docs/05-pdf-conversion.md`.

## Setup

Requires Python 3.11+ (`brew install python@3.11` if missing).

```sh
python3.11 -m venv .venv                  # create the local virtualenv
.venv/bin/pip install -e ".[dev]"         # base + dev deps (lightweight, enough for tests)
.venv/bin/pip install -e ".[ml]"          # additionally install docling + MLX embedding runtime
                                          # (needed for real conversion/embedding)
```

Without the `ml` extra the server runs fine, but `/convert` jobs fail and
`/embed` returns `503 MODEL_NOT_READY`.

## Running

```sh
.venv/bin/python -m paperd_worker --token <secret> --port 0 \
    [--lock-file <path>] [--idle-timeout <sec>]
```

- `--token` (or env `PAPERD_WORKER_TOKEN`): required bearer token; all
  endpoints check `Authorization: Bearer <token>`
- `--port`: default 0 = random port on 127.0.0.1
- On startup the worker prints exactly one JSON line to stdout:
  `{"port": <actual port>}` — the parent process reads this
- `--lock-file`: writes `{"pid", "port", "token"}` JSON on startup, removed
  on shutdown (including SIGTERM/SIGINT)
- `--idle-timeout`: shut down after N seconds without requests (0 = disabled,
  the default; MCP on-demand mode uses 600)

## API

All endpoints require the bearer token.

| Endpoint | Description |
|---|---|
| `POST /convert` | `{"pdf_path", "output_dir", "options": {"ocr": false, "max_pages": 500, "timeout_sec": 900}}` → `202 {"job_id": "w-..."}`. Async; writes `paper.md` + `paper.docling.json` into `output_dir`. Conversions are serialized on one worker thread. |
| `GET /jobs/{id}` | `{"job_id", "status": queued\|running\|succeeded\|failed, "stage", "progress", "error"}` |
| `POST /embed` | `{"texts": [...], "task": "passage"\|"query"}` → `{"embeddings", "model", "dimensions"}` |
| `GET /health` | `{"status": "ok", "model_loaded": bool, "version": "0.2.2"}` |

Errors use `{"error": {"code", "message"}}` with this status mapping:
`PDF_CORRUPT` / `PDF_ENCRYPTED` / `PAGE_LIMIT_EXCEEDED` → 400,
`UNAUTHORIZED` → 401, `NOT_FOUND` (missing input file, unknown job id) → 404,
`MODEL_NOT_READY` → 503, `TIMEOUT` → 504, `INTERNAL` → 500.
(`UNAUTHORIZED` and `NOT_FOUND` are additions to the table in doc 05 §3.5.)

Note: on `timeout_sec` expiry the job is reported `failed` with `TIMEOUT`,
but the underlying conversion thread cannot be killed and runs detached
until it finishes.

## Tests

```sh
.venv/bin/pytest
```

Tests use fake engines, so the `ml` extra is not required.

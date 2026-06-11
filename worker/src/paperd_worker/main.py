"""CLI entry point for paperd-worker.

Startup contract (docs/01 §3.1–3.2): bind 127.0.0.1 on a random port, print
exactly one line of JSON ``{"port": <actual port>}`` to stdout, authenticate
all requests with a bearer token, optionally maintain a lock file and shut
down after an idle timeout.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import sys
import threading
from pathlib import Path

import uvicorn

from .app import create_app
from .engines import BgeM3EmbeddingEngine, DoclingConversionEngine
from .idle import IdleTracker


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="paperd-worker")
    parser.add_argument(
        "--token",
        default=os.environ.get("PAPERD_WORKER_TOKEN"),
        help="Bearer token (or env PAPERD_WORKER_TOKEN)",
    )
    parser.add_argument(
        "--port", type=int, default=0, help="Port to bind on 127.0.0.1 (0 = random)"
    )
    parser.add_argument(
        "--lock-file",
        default=None,
        help="Path to a JSON lock file ({pid, port, token}); removed on shutdown",
    )
    parser.add_argument(
        "--idle-timeout",
        type=float,
        default=0,
        help="Shut down after this many idle seconds (0 = disabled)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    if not args.token:
        print(
            "error: --token or PAPERD_WORKER_TOKEN is required", file=sys.stderr
        )
        raise SystemExit(2)

    idle_tracker = IdleTracker(args.idle_timeout)
    app = create_app(
        args.token,
        DoclingConversionEngine(),
        BgeM3EmbeddingEngine(),
        idle_tracker=idle_tracker,
    )

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", args.port))
    port = sock.getsockname()[1]

    server = uvicorn.Server(uvicorn.Config(app, log_level="warning"))

    def watch_idle() -> None:
        ticker = threading.Event()
        while not server.should_exit:
            if idle_tracker.is_expired():
                server.should_exit = True
                break
            ticker.wait(1)

    lock_path = Path(args.lock_file) if args.lock_file else None
    if lock_path is not None:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_path.write_text(
            json.dumps({"pid": os.getpid(), "port": port, "token": args.token}),
            encoding="utf-8",
        )

        def remove_lock_if_owned() -> None:
            # 自分のpidが書かれている場合のみ削除する。
            # 旧ワーカーの遅延シャットダウンが、後継ワーカーの書いた
            # lockファイルを消してしまう競合を防ぐ
            try:
                current = json.loads(lock_path.read_text(encoding="utf-8"))
                if current.get("pid") != os.getpid():
                    return
            except (OSError, ValueError):
                pass
            lock_path.unlink(missing_ok=True)

        # uvicorn captures SIGINT/SIGTERM for graceful shutdown, then restores
        # the previous handlers and re-raises the signal, which would skip the
        # `finally` below. Install a handler that removes the lock file before
        # dying with the default disposition.
        def cleanup_and_reraise(signum: int, frame: object) -> None:
            remove_lock_if_owned()
            signal.signal(signum, signal.SIG_DFL)
            signal.raise_signal(signum)

        signal.signal(signal.SIGTERM, cleanup_and_reraise)
        signal.signal(signal.SIGINT, cleanup_and_reraise)

    # The parent (Swift) process reads this single JSON line from stdout.
    print(json.dumps({"port": port}), flush=True)

    if args.idle_timeout > 0:
        threading.Thread(target=watch_idle, name="idle-watchdog", daemon=True).start()

    try:
        server.run(sockets=[sock])
    finally:
        if lock_path is not None:
            remove_lock_if_owned()


if __name__ == "__main__":
    main()

"""Engine protocols and real (lazily imported) implementations.

The real engines import docling / MLX embedding dependencies inside their
methods so this module imports fine without the ``ml`` extras installed. If an
import fails, a ``WorkerError(code="MODEL_NOT_READY")`` is raised.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable, Literal, Protocol

from pydantic import BaseModel

from .errors import WorkerError

# stage, page, total_pages — page/total_pages may be None when unknown.
ProgressCallback = Callable[[str, int | None, int | None], None]

Task = Literal["passage", "query"]


class ConvertOptions(BaseModel):
    """Conversion options (docs/05 §3.1 defaults).

    force_ocr / formula_enrichment are for high-quality reconversion
    (docs/05 §5.1): slower, but recover broken ToUnicode glyph mappings and
    superscripts/formulas respectively.
    """

    ocr: bool = False
    max_pages: int = 500
    timeout_sec: int = 900
    force_ocr: bool = False
    formula_enrichment: bool = False


class ConversionEngine(Protocol):
    def convert(
        self,
        pdf_path: str,
        output_dir: str,
        options: ConvertOptions,
        progress_cb: ProgressCallback,
    ) -> None:
        """Convert a PDF, writing paper.md and paper.docling.json into output_dir."""
        ...


class EmbeddingEngine(Protocol):
    @property
    def model_name(self) -> str: ...

    @property
    def dimensions(self) -> int: ...

    @property
    def is_loaded(self) -> bool: ...

    def embed(self, texts: list[str], task: Task) -> list[list[float]]: ...


class DoclingConversionEngine:
    """Real conversion engine backed by Docling (requires the ``ml`` extra)."""

    def __init__(self) -> None:
        # オプション組み合わせごとにコンバータをキャッシュ（モデル再ロード回避）
        self._converters: dict[tuple[bool, bool, bool], Any] = {}

    def _converter_for(self, options: ConvertOptions) -> Any:
        from docling.datamodel.base_models import InputFormat
        from docling.datamodel.pipeline_options import PdfPipelineOptions
        from docling.document_converter import DocumentConverter, PdfFormatOption

        key = (options.ocr, options.force_ocr, options.formula_enrichment)
        if key not in self._converters:
            pipeline_options = PdfPipelineOptions(
                do_ocr=options.ocr or options.force_ocr,
                do_formula_enrichment=options.formula_enrichment,
            )
            if options.force_ocr:
                # 既存テキスト層を無視してピクセルから再読取（ToUnicode CMap破損対策 → docs/05 §3.1）。
                # OCRエンジンはmacOS Vision（ocrmac）: モデルDL不要・軽量（→ docs/05 §3.1）
                from docling.datamodel.pipeline_options import OcrMacOptions

                pipeline_options.ocr_options = OcrMacOptions(force_full_page_ocr=True)
            self._converters[key] = DocumentConverter(
                format_options={
                    InputFormat.PDF: PdfFormatOption(pipeline_options=pipeline_options)
                }
            )
        return self._converters[key]

    def convert(
        self,
        pdf_path: str,
        output_dir: str,
        options: ConvertOptions,
        progress_cb: ProgressCallback,
    ) -> None:
        try:
            converter = self._converter_for(options)
        except ImportError as exc:
            raise WorkerError(
                "MODEL_NOT_READY",
                "docling is not installed; run `.venv/bin/pip install -e \".[ml]\"`",
            ) from exc

        progress_cb("load", None, None)
        try:
            result = converter.convert(pdf_path, max_num_pages=options.max_pages)
        except Exception as exc:  # docling raises ConversionError and friends
            message = str(exc)
            lowered = message.lower()
            if "password" in lowered or "encrypt" in lowered:
                raise WorkerError("PDF_ENCRYPTED", message) from exc
            if "max_num_pages" in lowered or "number of pages" in lowered:
                raise WorkerError("PAGE_LIMIT_EXCEEDED", message) from exc
            raise WorkerError("PDF_CORRUPT", message) from exc

        progress_cb("export", None, None)
        doc = result.document
        out = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "paper.md").write_text(doc.export_to_markdown(), encoding="utf-8")
        (out / "paper.docling.json").write_text(
            json.dumps(doc.export_to_dict(), ensure_ascii=False), encoding="utf-8"
        )


class Qwen3EmbeddingEngine:
    """Real embedding engine backed by MLX + Qwen3-Embedding-0.6B 4bit."""

    QUERY_INSTRUCTION = (
        "Instruct: Given a search query, retrieve relevant passages from academic "
        "papers that answer or discuss the query\nQuery: "
    )

    def __init__(
        self,
        model_name: str = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        *,
        batch_size: int = 2,
        max_length: int = 8192,
    ) -> None:
        import threading

        self._model_name = model_name
        self._model: Any = None
        self._tokenizer: Any = None
        self._pad_id: int = 151643
        self._batch_size = batch_size
        self._max_length = max_length
        # 並行リクエスト対策: モデルロードとencodeは直列化する
        #（MLXのlazy evaluationとMetal allocatorのピークを抑える）
        self._lock = threading.Lock()

    @property
    def model_name(self) -> str:
        return self._model_name

    @property
    def dimensions(self) -> int:
        return 1024

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    def embed(self, texts: list[str], task: Task) -> list[list[float]]:
        try:
            import gc

            import mlx.core as mx
            import numpy as np
            from mlx_lm import load
        except ImportError as exc:
            raise WorkerError(
                "MODEL_NOT_READY",
                "MLX embedding dependencies are not installed; run `.venv/bin/pip install -e \".[ml]\"`",
            ) from exc

        with self._lock:
            if self._model is None:
                try:
                    self._model, self._tokenizer = load(self._model_name)
                    self._model.eval()
                    mx.eval(self._model.parameters())
                    self._pad_id = (
                        getattr(self._tokenizer, "pad_token_id", None)
                        or getattr(self._tokenizer, "eos_token_id", 151643)
                    )
                except Exception as exc:
                    raise WorkerError(
                        "MODEL_NOT_READY", f"failed to load {self._model_name}: {exc}"
                    ) from exc

            assert self._tokenizer is not None
            if task == "query":
                inputs = [self.QUERY_INSTRUCTION + text for text in texts]
            else:
                inputs = texts

            vectors: list[list[float]] = []
            for start in range(0, len(inputs), self._batch_size):
                batch = inputs[start : start + self._batch_size]
                encoded = [
                    self._tokenizer.encode(text)[: self._max_length]
                    for text in batch
                ]
                lengths = [max(1, len(ids)) for ids in encoded]
                max_len = max(lengths)
                padded = [
                    ids + [self._pad_id] * (max_len - len(ids))
                    for ids in encoded
                ]

                token_ids = mx.array(padded)
                hidden = self._model.model(token_ids)
                pooled = mx.stack(
                    [hidden[i, length - 1, :] for i, length in enumerate(lengths)]
                )
                pooled = pooled / mx.maximum(
                    mx.linalg.norm(pooled, axis=1, keepdims=True), 1e-12
                )
                pooled = pooled.astype(mx.float32)
                mx.eval(pooled)
                vectors.extend(np.array(pooled).tolist())

                del token_ids, hidden, pooled
                gc.collect()
                if hasattr(mx, "clear_cache"):
                    mx.clear_cache()

            return vectors

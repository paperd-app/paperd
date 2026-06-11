"""Worker error type and HTTP status mapping (docs/05-pdf-conversion.md §3.5).

Error responses always use the body::

    {"error": {"code": "...", "message": "..."}}

HTTP status mapping:

==================== ======
code                 status
==================== ======
PDF_CORRUPT          400
PDF_ENCRYPTED        400
PAGE_LIMIT_EXCEEDED  400
NOT_FOUND            404    (addition: missing input file / unknown job id)
UNAUTHORIZED         401    (addition: missing or invalid bearer token)
MODEL_NOT_READY      503
TIMEOUT              504
INTERNAL             500
==================== ======
"""

from __future__ import annotations

ERROR_STATUS: dict[str, int] = {
    "PDF_CORRUPT": 400,
    "PDF_ENCRYPTED": 400,
    "PAGE_LIMIT_EXCEEDED": 400,
    "NOT_FOUND": 404,
    "UNAUTHORIZED": 401,
    "MODEL_NOT_READY": 503,
    "TIMEOUT": 504,
    "INTERNAL": 500,
}


class WorkerError(Exception):
    """Application error carrying a stable error code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    @property
    def http_status(self) -> int:
        return ERROR_STATUS.get(self.code, 500)

    def to_dict(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message}

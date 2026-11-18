"""One JSON error shape for every failure: {"error": {"code": ..., "message": ...}}."""

import logging
from collections.abc import Mapping

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.backends import BackendError, BackendNotImplementedError
from app.ocr.images import ImageDecodeError
from app.ocr.parsing import OcrParseError
from app.schemas import ErrorDetail, ErrorResponse

logger = logging.getLogger(__name__)

_HTTP_CODES: dict[int, str] = {
    404: "not_found",
    405: "method_not_allowed",
}


class ApiError(Exception):
    """An error that the API reports to the client with a status and a code."""

    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def error_response(
    status_code: int, code: str, message: str, headers: Mapping[str, str] | None = None
) -> JSONResponse:
    body = ErrorResponse(error=ErrorDetail(code=code, message=message))
    return JSONResponse(status_code=status_code, content=body.model_dump(), headers=headers)


def _validation_message(exc: RequestValidationError) -> str:
    parts = []
    for error in exc.errors():
        location = ".".join(str(part) for part in error.get("loc", ()))
        parts.append(f"{location}: {error.get('msg', 'invalid value')}")
    return "; ".join(parts) or "Invalid request."


async def _handle_api_error(request: Request, exc: ApiError) -> JSONResponse:
    return error_response(exc.status_code, exc.code, exc.message)


async def _handle_validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
    return error_response(422, "validation_error", _validation_message(exc))


async def _handle_not_implemented(
    request: Request, exc: BackendNotImplementedError
) -> JSONResponse:
    return error_response(501, "backend_not_implemented", str(exc))


async def _handle_backend_error(request: Request, exc: BackendError) -> JSONResponse:
    # The message is this code's own text, never an upstream answer.
    logger.warning("Backend error %s (%s)", exc.code, exc.status_code)
    return error_response(exc.status_code, exc.code, exc.message)


async def _handle_parse_failed(request: Request, exc: OcrParseError) -> JSONResponse:
    # The problems name fields and error types only, never what the model read.
    logger.warning("OCR answer unreadable after the repair pass: %s", exc.problems)
    return error_response(422, "ocr_parse_failed", str(exc))


async def _handle_image_unreadable(request: Request, exc: ImageDecodeError) -> JSONResponse:
    return error_response(422, "image_unreadable", str(exc))


async def _handle_http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    code = _HTTP_CODES.get(exc.status_code, "http_error")
    return error_response(exc.status_code, code, str(exc.detail), headers=exc.headers)


async def _handle_unexpected(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unexpected error", exc_info=exc)
    return error_response(500, "internal_error", "Internal server error.")


def register_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(ApiError, _handle_api_error)
    app.add_exception_handler(RequestValidationError, _handle_validation_error)
    app.add_exception_handler(BackendNotImplementedError, _handle_not_implemented)
    app.add_exception_handler(BackendError, _handle_backend_error)
    app.add_exception_handler(OcrParseError, _handle_parse_failed)
    app.add_exception_handler(ImageDecodeError, _handle_image_unreadable)
    app.add_exception_handler(StarletteHTTPException, _handle_http_error)
    app.add_exception_handler(Exception, _handle_unexpected)

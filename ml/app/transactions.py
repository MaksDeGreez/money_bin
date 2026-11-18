"""The transaction categoriser over HTTP: `GET` and `POST /categorise/transaction`.

The model is the one `categoriser.serving` fitted (`ml/README.md`, "The transaction categoriser").
It always runs here, on the owner's machine: there is no hosted backend for it and no setting that
could add one. The artefact and the sentence encoder load lazily, once, on the first request that
needs them, so a service that never categorises a transaction pays nothing for it, and a missing
or unreadable artefact answers 501 here without touching `/ocr` or `/categorise`.

Which categories may be answered: the request carries the app's category list (the hand-over shape
of `/categorise`: slug, name, description, group). The model's classes are named by their group and
category names; each is matched to the listed category with the same names (whitespace squished).
A class the list does not name is a 422 `categories_mismatch`: the model would otherwise suggest a
category the app does not know, or silently drop part of its probability.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import TYPE_CHECKING, Annotated, Any, Literal

from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StrictStr, model_validator

from app.config import Settings
from app.errors import ApiError
from app.schemas import CategoryIn, ErrorResponse

if TYPE_CHECKING:  # pragma: no cover
    from categoriser.serving import ServingModel

DEFAULT_MODELS_DIR = Path.home() / "Documents" / "money_bin_data" / "models"
ARTEFACT_GLOB = "transaction-categoriser-*.serving.joblib"
MAX_TRANSACTIONS = 500
MAX_TEXT_LENGTH = 500
# Money as a decimal string with at most two places, as the ledger keeps it; never a JSON number.
DECIMAL = r"^-?\d{1,13}(?:\.\d{1,2})?$"
NOT_CONFIGURED = "transaction_categoriser_not_configured"
UNAVAILABLE = "transaction_categoriser_unavailable"


def _unique_slugs(categories: list[CategoryIn]) -> list[CategoryIn]:
    slugs = [category.slug for category in categories]
    if len(set(slugs)) != len(slugs):
        raise ValueError("category slugs must be unique")
    return categories


Text = Annotated[str | None, Field(default=None, max_length=MAX_TEXT_LENGTH)]


class TransactionIn(BaseModel):
    """One transaction. Every field is optional, but a text or the MCC must be there."""

    model_config = ConfigDict(extra="forbid")

    payee: Text = None
    comment: Text = None
    bank_description: Text = None
    merchant: Text = None
    mcc: str | None = Field(default=None, pattern=r"^\d{4}$")
    amount: StrictStr | None = Field(
        default=None,
        pattern=DECIMAL,
        description="The signed amount in the account's currency (an expense is negative), as a "
        "decimal string.",
    )
    currency: str | None = Field(default=None, pattern=r"^[A-Z]{3}$")
    account_kind: str | None = Field(default=None, max_length=20)

    @model_validator(mode="after")
    def _something_to_go_on(self) -> TransactionIn:
        texts = (self.payee, self.comment, self.bank_description, self.merchant)
        if not any(text and text.strip() for text in texts) and not self.mcc:
            raise ValueError("needs a payee, comment, bank description, merchant or MCC")
        return self


class TransactionCategoriseRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    categories: Annotated[
        list[CategoryIn], Field(min_length=2, max_length=100), AfterValidator(_unique_slugs)
    ]
    transactions: list[TransactionIn] = Field(min_length=1, max_length=MAX_TRANSACTIONS)


class TransactionCandidate(BaseModel):
    category_slug: str = Field(description="One of the request's category slugs.")
    probability: float = Field(ge=0.0, le=1.0)


class TransactionResult(BaseModel):
    """The three best categories of one transaction, best first, and where the answer came from:
    `model`, `history` (the payee's history decided) or `mix`; `history` is `payee` or `mcc`, and
    `history_weight` its weight in the mix."""

    candidates: list[TransactionCandidate] = Field(min_length=1, max_length=3)
    source: Literal["model", "history", "mix"]
    history: Literal["payee", "mcc"] | None
    history_weight: float = Field(ge=0.0, le=1.0)


class TransactionModelInfo(BaseModel):
    model_name: str
    model_version: str = Field(description="The artefact's fit date and the start of its SHA-256.")
    fitted_at: str
    configuration: str
    encoder: str | None
    encoder_loaded: bool
    load_seconds: Decimal


class TransactionCategoriseResponse(BaseModel):
    results: list[TransactionResult]
    model_name: str
    model_version: str
    fitted_at: str
    elapsed_seconds: Decimal


@dataclass
class _Loaded:
    model: ServingModel
    seconds: float
    encoder_loaded: bool = False


class TransactionCategoriser:
    """Holds the served model: loaded on first use, once, under a lock; scored under the same lock
    (one sentence encoder, one request at a time). A failed load is not kept, so a fixed setup
    works on the next request without a restart."""

    def __init__(
        self,
        settings: Settings,
        encoder_factory: Callable[[str], Any] | None = None,
    ) -> None:
        self._settings = settings
        self._encoder_factory = encoder_factory
        self._lock = threading.Lock()
        self._loaded: _Loaded | None = None

    def artefact_path(self) -> Path:
        configured = self._settings.transaction_categoriser_model
        if configured is not None:
            return configured.expanduser()
        folder = DEFAULT_MODELS_DIR
        found = sorted(folder.glob(ARTEFACT_GLOB)) if folder.is_dir() else []
        if not found:
            raise ApiError(
                501,
                NOT_CONFIGURED,
                "No transaction categoriser is set up: fit one with "
                "`python -m categoriser.serving` and set TRANSACTION_CATEGORISER_MODEL, or leave "
                "it in the default models folder.",
            )
        return found[-1]  # the names start with the fit time, so the last is the newest

    def _load(self) -> _Loaded:
        if self._loaded is None:
            # Imported here: scikit-learn and the rest load only once a transaction is categorised.
            from categoriser.serving import ServingError, load, real_encoder

            path = self.artefact_path()
            started = time.perf_counter()
            try:
                model = load(path, self._encoder_factory or real_encoder)
            except ServingError as error:
                raise ApiError(501, UNAVAILABLE, str(error)) from None
            self._loaded = _Loaded(model, time.perf_counter() - started)
        return self._loaded

    def info(self) -> TransactionModelInfo:
        with self._lock:
            loaded = self._load()
            return _info(loaded)

    def categorise(self, request: TransactionCategoriseRequest) -> TransactionCategoriseResponse:
        from categoriser.embeddings import EmbeddingError
        from categoriser.serving import ServingError, TransactionInput

        with self._lock:
            loaded = self._load()
            model = loaded.model
            slugs = _slugs_by_class(model, request.categories)
            inputs = [
                TransactionInput(
                    payee=t.payee,
                    comment=t.comment,
                    bank_description=t.bank_description,
                    merchant=t.merchant,
                    mcc=t.mcc,
                    amount=None if t.amount is None else Decimal(t.amount),
                    currency=t.currency,
                    account_kind=t.account_kind,
                )
                for t in request.transactions
            ]
            started = time.perf_counter()
            try:
                scored = model.score(inputs)
            except (ServingError, EmbeddingError) as error:
                raise ApiError(501, UNAVAILABLE, str(error)) from None
            loaded.encoder_loaded = model.encoder_name is not None
            elapsed = time.perf_counter() - started
        return TransactionCategoriseResponse(
            results=[
                TransactionResult(
                    candidates=[
                        TransactionCandidate(
                            category_slug=slugs[label], probability=_probability(probability)
                        )
                        for label, probability in zip(item.labels, item.probabilities, strict=True)
                    ],
                    source=item.source,  # type: ignore[arg-type]
                    history=item.history,  # type: ignore[arg-type]
                    history_weight=_probability(item.history_weight),
                )
                for item in scored
            ],
            model_name=model.model_name,
            model_version=model.version,
            fitted_at=model.fitted_at,
            elapsed_seconds=Decimal(f"{elapsed:.3f}"),
        )


def _probability(value: float) -> float:
    return round(min(1.0, max(0.0, value)), 6)


def _squish(value: str) -> str:
    return " ".join(value.split())


def _slugs_by_class(model: ServingModel, categories: list[CategoryIn]) -> dict[str, str]:
    """The listed slug of every class of the model; a class the list lacks is a 422."""
    listed = {(_squish(c.group), _squish(c.name)): c.slug for c in categories}
    slugs = {}
    missing = []
    for label in model.labels:
        group, name = model.names[label]
        slug = listed.get((_squish(group), _squish(name)))
        if slug is None:
            missing.append(label)
        else:
            slugs[label] = slug
    if missing:
        raise ApiError(
            422,
            "categories_mismatch",
            f"The model can answer {len(missing)} categor{'y' if len(missing) == 1 else 'ies'} the "
            f"request does not list: {', '.join(missing[:5])}. Refit the model on the app's "
            "taxonomy, or send every category.",
        )
    return slugs


def _info(loaded: _Loaded) -> TransactionModelInfo:
    model = loaded.model
    return TransactionModelInfo(
        model_name=model.model_name,
        model_version=model.version,
        fitted_at=model.fitted_at,
        configuration=model.config.name,
        encoder=model.encoder_name,
        encoder_loaded=loaded.encoder_loaded,
        load_seconds=Decimal(f"{loaded.seconds:.3f}"),
    )


_ERRORS: dict[int | str, dict[str, Any]] = {
    status: {"model": ErrorResponse} for status in (422, 501)
}

router = APIRouter()


def get_categoriser(request: Request) -> TransactionCategoriser:
    categoriser: TransactionCategoriser = request.app.state.transaction_categoriser
    return categoriser


@router.get("/categorise/transaction", responses=_ERRORS)
async def transaction_model(request: Request) -> TransactionModelInfo:
    """Which artefact answers (loads it, not the encoder)."""
    return await run_in_threadpool(get_categoriser(request).info)


@router.post("/categorise/transaction", responses=_ERRORS)
async def categorise_transactions(
    request: Request, body: TransactionCategoriseRequest
) -> TransactionCategoriseResponse:
    return await run_in_threadpool(get_categoriser(request).categorise, body)

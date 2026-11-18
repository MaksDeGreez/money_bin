"""Synthetic inputs for the evaluation harness: a receipt set, a ground-truth export, run folders.

Everything is invented. The item names and merchants are sentinels (`Sentinel...`) so a test can
search the results folder for them.
"""

import json
from pathlib import Path
from typing import Any

QR = {
    "rcpt_000001": {
        "issued_at": "2026-01-15T12:34:00+02:00",
        "total": "102.00",
        "fiscal_number": "4000000001",
        "receipt_number": "900001",
    },
    "rcpt_000002": {
        "issued_at": "2026-02-01T09:00:00+02:00",
        "total": "50.00",
        "fiscal_number": "4000000001",
        "receipt_number": "900002",
    },
    "rcpt_000004": {
        "issued_at": "2026-03-03T10:10:00+02:00",
        "total": "4321.17",
        "fiscal_number": "4000000002",
        "receipt_number": "900004",
    },
}
PARTS = {"rcpt_000001": 1, "rcpt_000002": 2, "rcpt_000003": 1, "rcpt_000004": 1}


def item(name: str, amount: str, slug: str | None = None, *, v2: bool = False) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "name": name,
        "quantity": "1.000",
        "unit_price": amount,
        "amount": amount,
        "discount": "0.00",
    }
    if v2:
        entry["category_slug"] = slug
    return entry


def document(
    kind: str | None,
    items: list[dict[str, Any]],
    *,
    merchant: str | None = None,
    total: str | None = None,
    category_slug: str | None = None,
    v2: bool = False,
) -> dict[str, Any]:
    doc: dict[str, Any] = {
        "kind": kind,
        "merchant": merchant,
        "fiscal_number": None,
        "receipt_number": None,
        "issued_at": None,
        "total": total,
        "currency": "UAH",
        "card_last4": None,
        "is_return": False,
        "items": items,
    }
    if v2:
        doc["category_slug"] = category_slug
    return doc


def truth_line(
    ingest_id: str,
    source: str,
    doc: dict[str, Any],
    *,
    prefilled_by: str | None = None,
    categories_prefilled_by: str | None = None,
    checked: str | None = None,
    qr_check: str = "agrees",
    items_known: bool = True,
    schema_version: int = 1,
    **extra: Any,
) -> dict[str, Any]:
    line: dict[str, Any] = {
        "receipt_id": 1,
        "ingest_id": ingest_id,
        "source": source,
        "source_format": "check01:1" if source == "dps_xml" else None,
        "prefilled_by": prefilled_by,
        "checked_at": "2026-11-01T10:00:00+02:00" if checked else None,
        "check_outcome": checked,
        "qr_check": qr_check,
        "items_known": items_known,
        "schema_version": schema_version,
        "document": doc,
    }
    if schema_version >= 2:
        line["categories_prefilled_by"] = categories_prefilled_by
    line.update(extra)
    return line


def standard_truth() -> list[dict[str, Any]]:
    """r1: an imported file; r2: pre-filled by Model-A; r3: a card slip; r4: a file the QR
    contradicts."""
    return [
        truth_line(
            "rcpt_000001",
            "dps_xml",
            document(
                "fiscal",
                [
                    item("SentinelBread", "40.00"),
                    item("Milk 2.5% 900g", "60.00"),
                    item("Пакет", "2.00"),
                ],
                merchant='ТОВ "SentinelShop"',
                total="102.00",
            ),
        ),
        truth_line(
            "rcpt_000002",
            "manual",
            document("fiscal", [item("Apple", "50.00")], merchant="Other", total="50.00"),
            prefilled_by="mlx-community/Model-A",
        ),
        truth_line(
            "rcpt_000003",
            "manual",
            document("card_slip", [], merchant="Cafe", total="75.00"),
            qr_check="no_qr",
        ),
        truth_line(
            "rcpt_000004",
            "dps_xml",
            document("fiscal", [item("Wrong", "4321.17")], total="4321.17"),
            qr_check="disagrees",
        ),
    ]


def receipt(kind: str | None, items: list[dict[str, Any]], **fields: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "kind": kind,
        "merchant": None,
        "fiscal_number": None,
        "receipt_number": None,
        "issued_at": None,
        "total": None,
        "currency": "UAH",
        "card_last4": None,
        "sum_matches_total": None,
        "items": items,
    }
    body.update(fields)
    return body


def qr_receipt(receipt_id: str, items: list[dict[str, Any]], **fields: Any) -> dict[str, Any]:
    """A predicted fiscal receipt with every QR field right."""
    qr = QR[receipt_id]
    return receipt(
        "fiscal",
        items,
        issued_at=qr["issued_at"],
        total=qr["total"],
        fiscal_number=qr["fiscal_number"],
        receipt_number=qr["receipt_number"],
        **fields,
    )


def prediction(
    receipt_id: str,
    status: str = "ok",
    body: dict[str, Any] | None = None,
    *,
    seconds: float = 10.0,
    images: list[str] | None = None,
    diagnostics: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "receipt_id": receipt_id,
        "status": status,
        "seconds": seconds,
        "repaired": False,
        "images": images or ["full"] * PARTS.get(receipt_id, 1),
        "receipt": body if status == "ok" else None,
        "error": None if status == "ok" else "ocr_parse_failed",
        "diagnostics": diagnostics or {},
    }


def standard_predictions() -> list[dict[str, Any]]:
    return [
        prediction(
            "rcpt_000001",
            body=qr_receipt(
                "rcpt_000001",
                [item("Milk 2,5% 900 г", "60.00"), item("SentinelBred", "40.00")],
                merchant="SentinelShop",
            ),
            seconds=10.0,
        ),
        prediction(
            "rcpt_000002",
            body=qr_receipt("rcpt_000002", [item("Apple", "50.00")], merchant="Other"),
            seconds=20.0,
        ),
        prediction(
            "rcpt_000003",
            body=receipt("fiscal", [], merchant="cafe", total="75.00"),
            seconds=30.0,
        ),
        prediction("rcpt_000004", status="parse_failed", seconds=40.0),
    ]


def write_receipt_set(folder: Path, receipt_ids: list[str] | None = None) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    ids = receipt_ids or list(PARTS)
    with (folder / "receipts.jsonl").open("w", encoding="utf-8") as file:
        for receipt_id in ids:
            parts = PARTS.get(receipt_id, 1)
            line = {
                "receipt_id": receipt_id,
                "batch": "batch_01",
                "images": [{"file": f"images/{receipt_id}_{n}.jpg"} for n in range(1, parts + 1)],
                "qr_fields": QR.get(receipt_id),
                "flags": [] if receipt_id in QR else ["no_qr"],
            }
            file.write(json.dumps(line, ensure_ascii=False) + "\n")
    return folder


def write_truth(folder: Path, lines: list[dict[str, Any]]) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "ground_truth.jsonl").open("w", encoding="utf-8") as file:
        for line in lines:
            file.write(json.dumps(line, ensure_ascii=False) + "\n")
    return folder


def write_run(
    runs: Path,
    run_id: str,
    records: list[dict[str, Any]],
    *,
    model: str = "mlx-community/Model-A",
    backend: str = "mlx",
    crops: bool = False,
    task: str | None = None,
    prompt_version: str | None = "abcdef123456",
    **meta: Any,
) -> Path:
    folder = runs / run_id
    folder.mkdir(parents=True, exist_ok=True)
    run_json: dict[str, Any] = {
        "run_id": run_id,
        "backend": backend,
        "model_name": model,
        "model_version": "0123456789abcdef",
        "prompt_version": prompt_version,
        "git": {"sha": "0123456789abcdef0123456789abcdef01234567", "dirty": False},
        "settings": {"image_max_side": 2048, "max_tokens": 3072, "crops": crops},
        "filters": {"only_tax_qr": False, "ids_file": True, "limit": None},
        "ingest": "/somewhere/private/receipts",
        "started_at": "2026-11-18T12:00:00+00:00",
        "finished_at": "2026-11-18T12:10:00+00:00",
        "load_seconds": 3.5,
        "counts": {"receipts": len(records), "ok": len(records)},
        "stopped": None,
        "peak_memory_gb": 6.5,
    }
    if task is not None:
        run_json["task"] = task
    run_json.update(meta)
    (folder / "run.json").write_text(json.dumps(run_json), encoding="utf-8")
    with (folder / "predictions.jsonl").open("w", encoding="utf-8") as file:
        for record in records:
            file.write(json.dumps(record, ensure_ascii=False) + "\n")
    return folder


def category_line(
    receipt_id: str,
    position: int | None,
    candidates: list[tuple[str, float]],
    *,
    source: str = "model",
    ground_truth_source: str | None = "dps_xml",
    seconds: float = 0.01,
    cost_usd: str | None = None,
) -> dict[str, Any]:
    return {
        "receipt_id": receipt_id,
        "ground_truth_source": ground_truth_source,
        "position": position,
        "candidates": [{"category_slug": slug, "score": score} for slug, score in candidates],
        "source": source,
        "seconds": seconds,
        "cost_usd": cost_usd,
    }

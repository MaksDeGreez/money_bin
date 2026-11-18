"""Offline evaluation of the OCR backends on the receipt set.

- `python -m evaluation.ocr_run`: runs a backend over receipts of a receipt set
  (the output of `tools/receipt_ingest`) and writes a run folder.
- `python -m evaluation.ocr_fields`: scores a run against the QR codes.

Receipt photos and model answers are personal data: the run folder must be
outside any git repository, and both scripts print aggregates only.
"""

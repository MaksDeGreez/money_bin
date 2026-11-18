"""Batch mode: many receipts read in one provider batch, at about half the price.

A batch is not zero-retention: the provider keeps the requests and the answers
until the batch is deleted (at most 30 days). So it is a separate opt-in
(`OPENROUTER_BATCH_ALLOW_RETENTION`), never the default, and the synchronous
path's rules stay as they are (`docs/decisions/0017-ocr-batch-mode.md`).

- `base`: the interface (`OcrBatches`) and its value types.
- `openrouter`: the OpenRouter implementation.
- `routes`: the HTTP endpoints under `/ocr/batches`.
- `schemas`: their request and response models.

The service keeps no state between calls: the Rails app records each batch and
the key of each receipt in it; the service re-reads everything else from
OpenRouter.
"""

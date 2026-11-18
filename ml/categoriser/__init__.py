"""The transaction categoriser: training and evaluation on a history export.

Two steps, so that the test set is scored once. `python -m categoriser.selection EXPORT_DIR` reads
an export (`docs/import-contract.md`), builds one labelled row per transaction, splits the rows by
date with the test set sealed, and tunes and compares the candidates on the validation slice.
`python -m categoriser.score EXPORT_DIR --selection FILE` refits the chosen configuration on the
whole training period and scores it once on the test set. Files go outside the repository.
"""

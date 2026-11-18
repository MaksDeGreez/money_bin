"""The transaction categoriser: training and evaluation on a history export.

`python -m categoriser.train EXPORT_DIR` reads an export (`docs/import-contract.md`), builds one
labelled row per transaction, splits the rows by date, fits rule baselines and a TF-IDF + logistic
regression model on the training rows, and writes the model file and a metrics JSON outside the
repository.
"""

# The evaluation harness (ml/evaluation/harness.py): every number of the results chapter from files.
#
#   make eval                      # score every run, write eval/results/ (JSON and tables)
#   make eval-check                # validate the inputs and print what would be scored; write nothing
#   make eval RUNS_DIR=~/elsewhere EVAL_ARGS="--compare RUN_A RUN_B --diagnostics ~/private/diag"
#
# The inputs live outside the repository. eval/results/ holds aggregates only (see its README.md).

DATA_DIR ?= $(HOME)/Documents/money_bin_data
RECEIPTS_DIR ?= $(DATA_DIR)/receipts
RUNS_DIR ?= $(DATA_DIR)/runs
GROUND_TRUTH_DIR ?= $(DATA_DIR)/ground_truth
RESULTS_DIR ?= $(CURDIR)/eval/results
EVAL_ARGS ?=

# The harness runs in ml/: a relative folder is taken from the repository root; `~` is expanded by
# the harness itself.
from_root = $(if $(filter /% ~%,$(1)),$(1),$(CURDIR)/$(1))

HARNESS = cd ml && uv run python -m evaluation.harness \
	--receipts "$(call from_root,$(RECEIPTS_DIR))" --runs "$(call from_root,$(RUNS_DIR))" \
	--ground-truth "$(call from_root,$(GROUND_TRUTH_DIR))"

.PHONY: eval eval-check

eval:
	$(HARNESS) --out "$(call from_root,$(RESULTS_DIR))" $(EVAL_ARGS)

eval-check:
	$(HARNESS) --check $(EVAL_ARGS)

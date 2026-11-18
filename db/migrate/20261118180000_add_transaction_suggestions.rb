# The transaction categoriser in the app (docs/domain.md, "Transaction suggestions"):
#
# - transaction_lines: the stored suggestion of an uncategorised line (best category and its probability, the
#   runner-up, where it came from, which artefact made it and when), and the provenance of a line's category
#   once a person sets it here: chosen by hand (`person`), a suggestion taken one by one (`suggestion`) or in
#   bulk (`bulk`), with the probability and the artefact of the suggestion taken. Nil: set elsewhere or before
#   this existed (the import, a receipt, manual entry).
# - transaction_suggestion_runs: one run of the job that scores every uncategorised line with the ML service, so
#   the list can show its progress, the artefact it used and why it failed.
# - bulk_acceptances and their items: "accept every suggestion at or above a probability" as a preview a person
#   confirms, then a job; each item is one transaction as it was previewed (its lock_version, its uncategorised
#   lines, the suggestion) and records what happened to it.
class AddTransactionSuggestions < ActiveRecord::Migration[8.1]
  def change
    change_table :transaction_lines, bulk: true do |t|
      t.references :suggested_category, foreign_key: { to_table: :categories, on_delete: :nullify }, index: false
      t.float :suggestion_probability
      t.references :runner_up_category, foreign_key: { to_table: :categories, on_delete: :nullify }, index: false
      t.float :runner_up_probability
      t.string :suggestion_source
      t.string :suggestion_model_version
      t.timestamptz :suggested_at
      t.string :category_origin
      t.float :category_origin_probability
      t.string :category_origin_model_version
    end
    add_index :transaction_lines, :suggested_category_id, where: "suggested_category_id IS NOT NULL"
    add_index :transaction_lines, :runner_up_category_id, where: "runner_up_category_id IS NOT NULL"
    add_check_constraint :transaction_lines, "suggestion_probability BETWEEN 0 AND 1",
      name: "transaction_lines_suggestion_probability_range"
    add_check_constraint :transaction_lines, "runner_up_probability BETWEEN 0 AND 1",
      name: "transaction_lines_runner_up_probability_range"
    add_check_constraint :transaction_lines, "category_origin_probability BETWEEN 0 AND 1",
      name: "transaction_lines_category_origin_probability_range"
    add_check_constraint :transaction_lines, "suggestion_source IN ('model', 'history', 'mix')",
      name: "transaction_lines_suggestion_source_known"
    add_check_constraint :transaction_lines, "category_origin IN ('person', 'suggestion', 'bulk')",
      name: "transaction_lines_category_origin_known"
    # A taken suggestion always says how probable it was and which artefact made it.
    add_check_constraint :transaction_lines,
      "category_origin NOT IN ('suggestion', 'bulk') OR (category_origin_probability IS NOT NULL AND " \
      "category_origin_model_version IS NOT NULL)",
      name: "transaction_lines_taken_suggestion_recorded"
    add_check_constraint :transaction_lines, "category_origin IS NULL OR category_id IS NOT NULL",
      name: "transaction_lines_category_origin_needs_category"

    create_table :transaction_suggestion_runs do |t|
      t.string :status, null: false, default: "queued"
      t.string :model_version
      t.integer :total_count, null: false, default: 0
      t.integer :scored_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.string :error
      t.timestamptz :started_at
      t.timestamptz :finished_at
      t.timestamps
    end
    add_check_constraint :transaction_suggestion_runs, "status IN ('queued', 'running', 'done', 'failed')",
      name: "transaction_suggestion_runs_status_known"

    create_table :bulk_acceptances do |t|
      t.jsonb :filter, null: false, default: {}
      t.integer :threshold_percent, null: false
      t.string :status, null: false, default: "previewed"
      t.integer :total_count, null: false, default: 0
      t.integer :accepted_count, null: false, default: 0
      t.integer :stale_count, null: false, default: 0
      t.integer :changed_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.timestamptz :confirmed_at
      t.timestamptz :started_at
      t.timestamptz :finished_at
      t.string :error
      t.timestamps
    end
    add_check_constraint :bulk_acceptances, "threshold_percent BETWEEN 1 AND 100", name: "bulk_acceptances_threshold_range"
    add_check_constraint :bulk_acceptances, "status IN ('previewed', 'queued', 'running', 'done', 'failed')",
      name: "bulk_acceptances_status_known"

    create_table :bulk_acceptance_items do |t|
      t.references :bulk_acceptance, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :transaction, null: false, foreign_key: { on_delete: :cascade }
      t.integer :lock_version, null: false
      t.bigint :line_ids, array: true, null: false
      t.references :category, null: false, foreign_key: true
      t.float :probability, null: false
      t.string :model_version, null: false
      t.string :outcome
      t.timestamps
    end
    add_index :bulk_acceptance_items, %i[bulk_acceptance_id transaction_id], unique: true
    add_check_constraint :bulk_acceptance_items, "probability BETWEEN 0 AND 1", name: "bulk_acceptance_items_probability_range"
    add_check_constraint :bulk_acceptance_items, "outcome IN ('accepted', 'stale', 'changed', 'failed')",
      name: "bulk_acceptance_items_outcome_known"
    add_check_constraint :bulk_acceptance_items, "cardinality(line_ids) > 0", name: "bulk_acceptance_items_has_lines"
  end
end

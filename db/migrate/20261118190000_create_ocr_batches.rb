# OCR batch mode (docs/decisions/0017-ocr-batch-mode.md, docs/domain.md "OCR in a batch"):
#
# - ocr_batches: one provider batch of up to a hundred receipts. `state` is the app's own life cycle
#   (pending -> submitting -> running -> applying -> finished, or failed, or unknown when a submission's
#   outcome was lost); `provider_status` is what OpenRouter last said. The provider's batch id, the model and
#   provider that ran it, the request counts, the estimated and the actual cost in US dollars, and the times it
#   was submitted, last checked, due to be checked, finished, and deleted upstream (`upstream_deletion`: what
#   the provider did with its copy). `error_code`/`error_message` say why a batch failed; `check_error_code`/
#   `check_error_message` what went wrong at the last check (the service down, batch mode switched off), cleared
#   by the next check that works. Costs are `numeric` without a scale: they keep every digit the provider
#   reported, never rounded.
# - ocr_batch_entries: one receipt in one batch, with the opaque random key (`custom_id`) that stands for it at
#   the provider, and what became of it (`state`, `error_code`, `error_message`, its own cost when reported).
#   The key is the only link between a provider result and a receipt; it lives only here. `followed_up_at`:
#   when the step after an applied (category suggestions) or handed-over (a read one at a time) result was
#   queued; nil until then, so a poll that died in between does it next time.
# - receipts.ocr_batch_id: the open batch the receipt waits in. One column, so a receipt is in at most one
#   open batch; the claim writes it under the receipt's row lock, as Receipts::RequestOcr writes
#   ocr_requested_at, so a synchronous request and a batch never both take a receipt.
class CreateOcrBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :ocr_batches do |t|
      t.string :state, null: false, default: "pending"
      t.integer :receipts_count, null: false
      t.string :provider_batch_id
      t.string :provider_status
      t.string :model
      t.string :provider
      t.integer :requests_total
      t.integer :requests_completed
      t.integer :requests_failed
      t.decimal :estimated_cost_usd
      t.decimal :cost_usd
      t.integer :checks, null: false, default: 0
      t.integer :submit_attempts, null: false, default: 0
      t.timestamptz :submit_started_at
      t.timestamptz :submitted_at
      t.timestamptz :last_checked_at
      t.timestamptz :next_check_at
      t.timestamptz :expires_at
      t.timestamptz :finished_at
      t.timestamptz :deleted_upstream_at
      t.string :upstream_deletion
      t.string :error_code
      t.text :error_message
      t.string :check_error_code
      t.text :check_error_message
      t.timestamps

      t.index :provider_batch_id, unique: true, where: "provider_batch_id IS NOT NULL"
      t.index :state
      t.index :next_check_at

      t.check_constraint "state IN ('pending', 'submitting', 'running', 'applying', 'finished', 'failed', 'unknown')",
        name: "ocr_batches_state_allowed"
      t.check_constraint "receipts_count > 0", name: "ocr_batches_receipts_count_positive"
      t.check_constraint "state NOT IN ('running', 'applying') OR provider_batch_id IS NOT NULL",
        name: "ocr_batches_running_has_provider_id"
      t.check_constraint "deleted_upstream_at IS NULL OR provider_batch_id IS NOT NULL",
        name: "ocr_batches_deleted_has_provider_id"
      t.check_constraint "(deleted_upstream_at IS NULL) = (upstream_deletion IS NULL)",
        name: "ocr_batches_deletion_consistent"
      t.check_constraint "upstream_deletion IN ('deleted', 'unsupported', 'not_applicable', 'gone')",
        name: "ocr_batches_upstream_deletion_allowed"
      t.check_constraint "estimated_cost_usd >= 0 AND cost_usd >= 0", name: "ocr_batches_costs_not_negative"
      t.check_constraint "requests_total >= 0 AND requests_completed >= 0 AND requests_failed >= 0",
        name: "ocr_batches_counts_not_negative"
      t.check_constraint "checks >= 0 AND submit_attempts >= 0", name: "ocr_batches_attempts_not_negative"
      t.check_constraint "provider_batch_id ~ '^[A-Za-z0-9_-]{1,128}$'", name: "ocr_batches_provider_batch_id_format"
    end

    create_table :ocr_batch_entries do |t|
      t.references :ocr_batch, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :receipt, foreign_key: { on_delete: :nullify }
      t.integer :position, null: false
      t.string :custom_id, null: false
      t.string :state, null: false, default: "waiting"
      t.string :error_code
      t.text :error_message
      t.decimal :cost_usd
      t.timestamptz :resolved_at
      t.timestamptz :followed_up_at
      t.timestamps

      t.index :custom_id, unique: true
      t.index %i[ocr_batch_id state]
      t.index %i[ocr_batch_id position], unique: true

      t.check_constraint "custom_id ~ '^[A-Za-z0-9_-]{16,64}$'", name: "ocr_batch_entries_custom_id_format"
      t.check_constraint "state IN ('waiting', 'applied', 'sync_queued', 'failed', 'released', 'superseded')",
        name: "ocr_batch_entries_state_allowed"
      t.check_constraint "(state = 'waiting') = (resolved_at IS NULL)", name: "ocr_batch_entries_resolved_consistent"
      t.check_constraint "position > 0", name: "ocr_batch_entries_position_positive"
      t.check_constraint "cost_usd >= 0", name: "ocr_batch_entries_cost_not_negative"
      t.check_constraint "followed_up_at IS NULL OR state IN ('applied', 'sync_queued')",
        name: "ocr_batch_entries_follow_up_needs_a_result"
    end

    add_reference :receipts, :ocr_batch, foreign_key: { on_delete: :nullify }
  end
end

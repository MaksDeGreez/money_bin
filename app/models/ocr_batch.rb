# One provider batch of receipts read by OCR together (docs/domain.md, "OCR in a batch";
# docs/decisions/0017-ocr-batch-mode.md). Up to a hundred receipts, one entry each (OcrBatchEntry).
#
# Life cycle (`state`):
#
#   pending -> submitting -> running -> applying -> finished
#                  |            |
#                  |            +-> failed     (the provider failed, expired or cancelled it, or no longer has it)
#                  +-> failed / unknown        (refused; or sent and its answer lost: unknown)
#
# - `pending`: created with its receipts held (`receipts.ocr_batch_id`), waiting for OcrBatchSubmitJob.
# - `submitting`: the photos are being sent (OcrBatches::Submit). One that stays here past SUBMIT_STALE_AFTER
#   died mid-send: it becomes `unknown`.
# - `running`: the provider has it (`provider_batch_id`); OcrBatchPollJob checks it at `next_check_at`.
# - `applying`: it completed; its results are being stored, entry by entry (OcrBatches::ApplyResults).
# - `finished`: every entry is resolved. `failed` and `unknown`: its waiting entries were released.
#
# Once it is finished or failed and the provider had it, it is deleted upstream (`deleted_upstream_at`,
# `upstream_deletion`: `deleted`, `unsupported` (the provider keeps its copy by its own rules),
# `not_applicable` or `gone` (OpenRouter no longer had it)). Until then the poller keeps it on its list.
#
# Costs are US dollars as BigDecimal, every digit the provider reported (`numeric` without a scale):
# `estimated_cost_usd` (the service's rough estimate at submission) and `cost_usd` (the provider's `usage.cost`).
class OcrBatch < ApplicationRecord
  STATES = %w[pending submitting running applying finished failed unknown].freeze
  UNFINISHED_STATES = %w[pending submitting running applying].freeze
  UPSTREAM_DELETIONS = %w[deleted unsupported not_applicable gone].freeze
  PROVIDER_BATCH_ID_FORMAT = /\A[A-Za-z0-9_-]{1,128}\z/
  # A submission that has not answered by then died mid-send (the worker was stopped).
  SUBMIT_STALE_AFTER = 15.minutes

  enum :state, STATES.index_by(&:itself), validate: true

  has_many :entries, -> { order(:position) }, class_name: "OcrBatchEntry", inverse_of: :ocr_batch, dependent: :delete_all
  has_many :receipts, through: :entries
  # The receipts that wait in this batch now (their hold).
  has_many :held_receipts, class_name: "Receipt", inverse_of: :ocr_batch, dependent: :nullify

  scope :unfinished, -> { where(state: UNFINISHED_STATES) }
  # Finished or failed at the provider and not deleted there yet.
  scope :awaiting_deletion, -> { where(state: %w[finished failed]).where.not(provider_batch_id: nil).where(deleted_upstream_at: nil) }
  # Everything the poller still has to look at.
  scope :followed, -> { unfinished.or(awaiting_deletion) }
  scope :due, ->(now = Time.current) { where(next_check_at: nil).or(where(next_check_at: ..now)) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  validates :receipts_count, numericality: { only_integer: true, greater_than: 0 }
  validates :provider_batch_id, format: { with: PROVIDER_BATCH_ID_FORMAT }, uniqueness: true, allow_nil: true
  validates :provider_batch_id, presence: true, if: -> { running? || applying? }
  validates :upstream_deletion, inclusion: { in: UPSTREAM_DELETIONS }, allow_nil: true
  validates :upstream_deletion, presence: true, if: -> { deleted_upstream_at.present? }
  validates :deleted_upstream_at, presence: true, if: -> { upstream_deletion.present? }
  validates :provider_batch_id, presence: true, if: -> { deleted_upstream_at.present? }
  validates :checks, :submit_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :estimated_cost_usd, :cost_usd, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :requests_total, :requests_completed, :requests_failed,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  def unfinished?
    UNFINISHED_STATES.include?(state)
  end

  def awaiting_deletion?
    (finished? || failed?) && provider_batch_id.present? && deleted_upstream_at.nil?
  end

  # Releases every entry still waiting (each keeps `code` and `message`), takes the hold off their receipts,
  # and ends the batch as `final_state` (failed or unknown) with the reason. The receipts go back to what they
  # were (`uploaded` or `failed`), free for a read one at a time or another batch, and their open pages are
  # refreshed. Idempotent.
  def release!(final_state, code, message, now: Time.current)
    transaction do
      lock!
      waiting = entries.where(state: "waiting")
      held = Receipt.where(id: waiting.select(:receipt_id), ocr_batch_id: id).order(:id)
      released = held.pluck(:id)
      held.update_all(ocr_batch_id: nil)
      waiting.update_all(state: "released", error_code: code, error_message: message, resolved_at: now, updated_at: now)
      update!(state: final_state, error_code: code, error_message: message, finished_at: finished_at || now, next_check_at: now)
      Receipt.where(id: released).find_each { |receipt| Receipts::LiveUpdate.changed(receipt) }
    end
  end

  # Every waiting entry is resolved and every follow-up (category suggestions, a read one at a time) queued.
  def settled?
    !entries.where(state: "waiting").or(entries.where(state: OcrBatchEntry::FOLLOWED_UP_STATES, followed_up_at: nil)).exists?
  end

  # How many entries are in each state, every state present.
  def entry_counts
    counts = entries.unscope(:order).group(:state).count
    OcrBatchEntry::STATES.index_with { |state| counts.fetch(state, 0) }
  end
end

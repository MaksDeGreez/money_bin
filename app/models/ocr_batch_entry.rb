# One receipt in one OCR batch (OcrBatch), and what became of it.
#
# `custom_id` is the receipt's key at the provider: a random token (RANDOM_BYTES of SecureRandom, URL-safe), never
# the receipt's id or anything else of the app. It is the only link between a provider result and a receipt, and
# it exists only in this table.
#
# `state`:
# - `waiting`: in the batch, no result stored yet;
# - `applied`: the result was stored on the receipt (Receipts::ApplyOcr);
# - `sync_queued`: the answer needs the repair pass a batch cannot run, so the receipt was handed to the normal
#   OCR queue (Receipts::RequestOcr);
# - `failed`: the provider failed this request; the receipt is `failed` with the reason (`error_code`,
#   `error_message`);
# - `released`: the batch failed, expired or was lost; the receipt is back where it was, untouched;
# - `superseded`: a person took the receipt over meanwhile (entered it by hand), or it was deleted; the result,
#   if any, was not used.
# Every state but `waiting` is final and has `resolved_at`.
class OcrBatchEntry < ApplicationRecord
  STATES = %w[waiting applied sync_queued failed released superseded].freeze
  # The outcomes with a step after them: category suggestions (`applied`), a read one at a time (`sync_queued`).
  # `followed_up_at` is set once that step was queued.
  FOLLOWED_UP_STATES = %w[applied sync_queued].freeze
  CUSTOM_ID_FORMAT = /\A[A-Za-z0-9_-]{16,64}\z/
  RANDOM_BYTES = 18

  enum :state, STATES.index_by(&:itself), validate: true

  belongs_to :ocr_batch, inverse_of: :entries
  belongs_to :receipt, optional: true

  validates :custom_id, format: { with: CUSTOM_ID_FORMAT }, uniqueness: true
  validates :position, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :ocr_batch_id }
  validates :followed_up_at, absence: true, unless: -> { FOLLOWED_UP_STATES.include?(state) }
  validates :resolved_at, presence: true, unless: :waiting?
  validates :resolved_at, absence: true, if: :waiting?
  validates :cost_usd, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # A new random key: 24 URL-safe characters, 144 random bits.
  def self.new_custom_id
    SecureRandom.urlsafe_base64(RANDOM_BYTES)
  end

  def resolve!(state, code: nil, message: nil, cost_usd: nil, now: Time.current)
    update!(state:, error_code: code, error_message: message&.squish&.truncate(ReceiptOcrJob::MAX_MESSAGE_LENGTH),
      cost_usd:, resolved_at: now)
  end
end

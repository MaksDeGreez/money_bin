# What a receipt really says, according to one source (docs/domain.md, "Receipt ground truth"). The OCR
# evaluation compares a model's reading of the photos with it.
#
# - `source`: `dps_xml` (a receipt file a person saved from the tax service's receipt page, read by
#   GroundTruthImport) or `manual` (a person's reading of the print, from the review form, a later change).
#   One record per receipt and source.
# - `document`: the receipt in the shape of the OCR contract's `receipt` object (ml/README.md), money and
#   quantities as decimal strings, so a prediction and its ground truth go through one comparison.
#   ReceiptGroundTruth::Document lists the keys and checks them; `schema_version` says which shape.
# - `items_known`: whether the source gave item lines at all. False (the list is then empty) means "no item
#   ground truth"; true with an empty list means "the receipt has no items" (a card slip). Kept apart because
#   the two are different facts and an empty list cannot tell them apart.
# - `prefilled_by`: the model (or source) that filled the form before a person corrected it; nil for an
#   imported record. A record pre-filled by a model is not test ground truth for that model
#   (`independent_of?`).
# - `source_sha256` and `source_format`: for an imported record, the SHA-256 of the file and the name of the
#   format variant that read it. Never the file's path or content.
# - `checked_at`, `check_outcome` (`matches` / `differs`), `check_note`: a person compared the record with the
#   printed receipt. A checked record is never replaced by the import.
#
# It is separate from booking: it never changes the receipt, its items, a transaction or an OCR column, and
# nothing that changes those writes here.
class ReceiptGroundTruth < ApplicationRecord
  SCHEMA_VERSION = 1
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/

  enum :source, { dps_xml: "dps_xml", manual: "manual" }, validate: true
  enum :check_outcome, { matches: "matches", differs: "differs" }, prefix: :check, validate: { allow_nil: true }

  belongs_to :receipt, inverse_of: :ground_truths

  scope :checked, -> { where.not(checked_at: nil) }
  scope :unchecked, -> { where(checked_at: nil) }
  scope :with_items, -> { where(items_known: true) }

  normalizes :prefilled_by, :source_format, with: ->(value) { value.strip.presence }
  normalizes :check_note, with: ->(value) { value.strip.presence }

  validates :source, uniqueness: { scope: :receipt_id, message: "already has a ground-truth record for this receipt" }
  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }
  validates :items_known, inclusion: { in: [ true, false ] }
  validates :source_sha256, format: { with: SHA256_FORMAT }, allow_nil: true
  validates :source_sha256, :source_format, presence: true, if: :dps_xml?
  validates :source_sha256, :source_format, absence: true, if: :manual?
  validates :prefilled_by, absence: { message: "is only for a record a person entered" }, if: :dps_xml?
  validates :check_outcome, presence: true, if: -> { checked_at.present? }
  validates :checked_at, presence: true, if: -> { check_outcome.present? || check_note.present? }
  validate :document_has_the_shape

  # The document with its items as a list of Hashes, string keys, as stored.
  def items
    document.is_a?(Hash) ? Array(document["items"]) : []
  end

  def checked?
    checked_at.present?
  end

  # A person compared the record with the printed receipt: `matches` true when every value agrees.
  def record_check!(matches:, note: nil, at: Time.current)
    update!(checked_at: at, check_outcome: matches ? :matches : :differs, check_note: note)
  end

  # Forgets a check (a person clicked the wrong button).
  def clear_check!
    update!(checked_at: nil, check_outcome: nil, check_note: nil)
  end

  # False when `model_name` filled the form this record was corrected from: scoring that model against it
  # would reward the model for its own answer.
  def independent_of?(model_name)
    prefilled_by.nil? || prefilled_by != model_name.to_s.strip
  end

  private
    def document_has_the_shape
      Document.problems(document, items_known:).each { |problem| errors.add(:document, problem) }
    end
end

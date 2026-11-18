# What a receipt really says, according to one source (docs/domain.md, "Receipt ground truth"). The OCR
# evaluation compares a model's reading of the photos with it, and the item categoriser is evaluated against
# its categories.
#
# - `source`: `dps_xml` (a receipt file a person saved from the tax service's receipt page, read by
#   GroundTruthImport) or `manual` (a person's reading of the print, saved from the review form by
#   Receipts::SaveGroundTruth). One record per receipt and source.
# - `document`: the receipt in the shape of the OCR contract's `receipt` object (ml/README.md), money and
#   quantities as decimal strings, so a prediction and its ground truth go through one comparison.
#   ReceiptGroundTruth::Document lists the keys and checks them; `schema_version` says which shape (1, or 2
#   with categories). A stored record keeps the version it was written in; `current_document` reads any of
#   them as version 2.
# - `items_known`: whether the source gave item lines at all. False (the list is then empty) means "no item
#   ground truth"; true with an empty list means "the receipt has no items" (a card slip). Kept apart because
#   the two are different facts and an empty list cannot tell them apart.
# - `categories_known`: whether the document gives every category (each item's, and a slip's own). False means
#   none is given. An imported record never has categories.
# - `prefilled_by`: what filled the review form before a person corrected it, for a manual record: a model's
#   name (`ocr_model_name`), PREFILLED_BY_HAND (a person started from nothing) or PREFILLED_BY_DPS_XML (the
#   form was filled from the receipt's tax-service record). `prefilled_model_version` and
#   `prefilled_prompt_version` say which version of that model and prompt. A record pre-filled by a model is
#   not test ground truth for that model (`independent_of?`). Nil for an imported record.
#   ReceiptGroundTruth::Prefill derives it from the receipt.
# - `categories_prefilled_by`: the categoriser whose suggestions were on the form when a person chose the
#   categories of a manual record (`receipts.categoriser_model_name`, or CATEGORISER_UNKNOWN when suggestions
#   were there and nothing recorded whose), nil when no item and no slip had a suggestion. The same rule:
#   the record is not test ground truth for that categoriser (`categories_independent_of?`).
# - `source_sha256` and `source_format`: for an imported record, the SHA-256 of the file and the name of the
#   format variant that read it. Never the file's path or content.
# - `checked_at`, `check_outcome` (`matches` / `differs`), `check_note`: a person compared the record with the
#   printed receipt. A checked record is never replaced by the import.
#
# It is separate from booking: it never changes the receipt, its items, a transaction or an OCR column, and
# nothing that changes those writes here. A manual record is a snapshot: later edits of the receipt, its items
# or the ledger leave it as it was saved.
class ReceiptGroundTruth < ApplicationRecord
  SCHEMA_VERSION = Document::CURRENT_VERSION
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  # Values of `prefilled_by` that are not a model. A model name never starts with "source:" (the ML service
  # names models by their repository id or backend), so the two cannot be mistaken for one.
  PREFILLED_BY_HAND = "source:hand".freeze
  PREFILLED_BY_DPS_XML = "source:dps_xml".freeze
  PREFILLED_BY_SOURCES = [ PREFILLED_BY_HAND, PREFILLED_BY_DPS_XML ].freeze
  # `categories_prefilled_by` when suggestions were on the form but the receipt does not say which
  # categoriser made them: the evaluation then leaves the record out for every categoriser.
  CATEGORISER_UNKNOWN = "source:unknown".freeze

  enum :source, { dps_xml: "dps_xml", manual: "manual" }, validate: true
  enum :check_outcome, { matches: "matches", differs: "differs" }, prefix: :check, validate: { allow_nil: true }

  belongs_to :receipt, inverse_of: :ground_truths

  scope :checked, -> { where.not(checked_at: nil) }
  scope :unchecked, -> { where(checked_at: nil) }
  scope :with_items, -> { where(items_known: true) }

  normalizes :prefilled_by, :prefilled_model_version, :prefilled_prompt_version, :categories_prefilled_by, :source_format,
    with: ->(value) { value.strip.presence }
  normalizes :check_note, with: ->(value) { value.strip.presence }

  validates :source, uniqueness: { scope: :receipt_id, message: "already has a ground-truth record for this receipt" }
  validates :schema_version, inclusion: { in: Document::VERSIONS, message: "is not a known schema version" }
  validates :items_known, :categories_known, inclusion: { in: [ true, false ] }
  validates :source_sha256, format: { with: SHA256_FORMAT }, allow_nil: true
  validates :source_sha256, :source_format, presence: true, if: :dps_xml?
  validates :source_sha256, :source_format, absence: true, if: :manual?
  validates :prefilled_by, :prefilled_model_version, :prefilled_prompt_version, :categories_prefilled_by,
    absence: { message: "is only for a record a person entered" }, if: :dps_xml?
  validates :categories_known, inclusion: { in: [ false ], message: "is never true for an imported record" }, if: :dps_xml?
  validates :prefilled_by, presence: { message: "must say what filled the form" }, if: :manual?
  validate :prefilled_by_source_is_known
  validates :categories_prefilled_by, inclusion: { in: [ CATEGORISER_UNKNOWN ], message: "is not a known source" },
    if: -> { categories_prefilled_by&.start_with?("source:") }
  validates :check_outcome, presence: true, if: -> { checked_at.present? }
  validates :checked_at, presence: true, if: -> { check_outcome.present? || check_note.present? }
  validate :document_has_the_shape

  # The document as schema version 2, whatever version it is stored in (a new object).
  def current_document
    Document.upgrade(document, schema_version)
  end

  # A digest of what the record says (the document as version 2, whether items and categories are known). A
  # page that shows the record carries it, so a check is refused when the record changed after the person
  # looked at it (a new import replaced it).
  def content_version
    payload = [ self.class.canonical(current_document), items_known, categories_known ]
    Digest::SHA256.hexdigest(JSON.generate(payload))
  end

  # `value` with every Hash's keys sorted, at any depth, so a digest does not depend on key order (jsonb
  # stores keys in its own order).
  def self.canonical(value)
    case value
    when Hash then value.keys.map(&:to_s).sort.map { |key| [ key, canonical(value.key?(key) ? value[key] : value[key.to_sym]) ] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  # The document with its items as a list of Hashes, string keys, as stored.
  def items
    document.is_a?(Hash) ? Array(document["items"]) : []
  end

  def checked?
    checked_at.present?
  end

  # `:model`, `:hand` or `:dps_xml` for a manual record (what filled the form); nil for an imported one.
  def prefill_kind
    case prefilled_by
    when nil then nil
    when PREFILLED_BY_HAND then :hand
    when PREFILLED_BY_DPS_XML then :dps_xml
    else :model
    end
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
  # would reward the model for its own answer. Any version or prompt of the model counts: the same weights
  # answer much the same.
  def independent_of?(model_name)
    prefilled_by.nil? || prefilled_by != model_name.to_s.strip
  end

  # False when the categoriser `model_name` suggested categories on the form this record's categories were
  # chosen on (or when it is not known which categoriser did).
  def categories_independent_of?(model_name)
    categories_prefilled_by.nil? || (categories_prefilled_by != CATEGORISER_UNKNOWN && categories_prefilled_by != model_name.to_s.strip)
  end

  private
    def document_has_the_shape
      Document.problems(document, items_known:, categories_known:, version: schema_version)
        .each { |problem| errors.add(:document, problem) }
    end

    def prefilled_by_source_is_known
      return unless prefilled_by&.start_with?("source:") && !PREFILLED_BY_SOURCES.include?(prefilled_by)

      errors.add(:prefilled_by, "is not a known source")
    end
end

module Receipts
  # Writes or replaces a receipt's `manual` ground-truth record from the receipt as stored (docs/domain.md,
  # "Manual ground truth"). Receipts::Review calls it after saving the form ("Save as ground truth"), in the
  # same database transaction, with the receipt row locked.
  #
  #   result = Receipts::SaveGroundTruth.call(receipt, confirm: params[:replace_ground_truth])
  #   result.status # :created, :replaced, :unchanged, or :confirm (nothing written: show result.diff and ask)
  #
  # - The record is a snapshot (ReceiptGroundTruth::Snapshot): the receipt's fields and items as stored now,
  #   categories as slugs. Nothing later changes it but saving it again.
  # - Categories are known when every kept item has one and a card slip has its own; otherwise the record says
  #   they are not known and carries none (the review form only gets here then when the person chose "Save
  #   without categories").
  # - `prefilled_by` and its versions come from ReceiptGroundTruth::Prefill.of(receipt), and
  #   `categories_prefilled_by` from Prefill.categoriser(receipt) (nil when categories are not known).
  # - A record that exists is replaced only once the person saw what changes: the first call returns
  #   `:confirm` with the differences and a token; a call with that token replaces it. The token is a digest
  #   of the stored record and of the new snapshot, so a record that changed in between, or a form changed
  #   again after the question, asks again. Saving what the record already says writes nothing (`:unchanged`).
  # - Replacing clears a person's check of the old version: it was about other content.
  # - It never writes the receipt, its items, a transaction or anything OCR owns.
  class SaveGroundTruth
    META_FIELDS = {
      "prefilled_by" => "pre-filled by", "prefilled_model_version" => "model version",
      "prefilled_prompt_version" => "prompt version", "categories_known" => "categories known",
      "categories_prefilled_by" => "categories pre-filled by"
    }.freeze

    Result = Data.define(:status, :record, :diff, :meta_changes, :token) do
      def confirm? = status == :confirm
      def written? = %i[created replaced].include?(status)
      def change_count = (diff ? diff.fields.size : 0) + meta_changes.size
    end

    def self.call(receipt, confirm: nil)
      new(receipt, confirm:).call
    end

    def initialize(receipt, confirm: nil)
      @receipt = receipt
      @confirm = confirm.to_s
    end

    def call
      attributes = snapshot_attributes
      record = ReceiptGroundTruth.lock.find_by(receipt_id: @receipt.id, source: :manual)
      if record.nil?
        record = ReceiptGroundTruth.create!(receipt_id: @receipt.id, source: :manual, **attributes)
        return Result.new(status: :created, record:, diff: nil, meta_changes: [], token: nil)
      end

      diff = ReceiptGroundTruth::Diff.new(record.current_document, attributes[:document])
      meta_changes = META_FIELDS.keys.reject { |key| record.public_send(key) == attributes[key.to_sym] }
      changed = diff.any? || meta_changes.any? || record.schema_version != attributes[:schema_version]
      return Result.new(status: :unchanged, record:, diff:, meta_changes:, token: nil) unless changed

      token = self.class.token(record, attributes)
      unless ActiveSupport::SecurityUtils.secure_compare(@confirm, token)
        return Result.new(status: :confirm, record:, diff:, meta_changes:, token:)
      end

      record.update!(**attributes, checked_at: nil, check_outcome: nil, check_note: nil)
      Result.new(status: :replaced, record:, diff:, meta_changes:, token: nil)
    end

    # The digest of the stored record and the new snapshot, keys sorted so the database's own key order of a
    # jsonb document does not matter.
    def self.token(record, attributes)
      payload = [ record.id, record.updated_at.utc.iso8601(6), record.schema_version, record.document,
                  attributes.transform_keys(&:to_s) ]
      Digest::SHA256.hexdigest(JSON.generate(ReceiptGroundTruth.canonical(payload)))
    end

    private
      def snapshot_attributes
        categories_known = ReceiptGroundTruth::Snapshot.categories_complete?(@receipt)
        prefill = ReceiptGroundTruth::Prefill.of(@receipt)
        {
          document: ReceiptGroundTruth::Snapshot.document(@receipt, categories: categories_known),
          schema_version: ReceiptGroundTruth::SCHEMA_VERSION,
          items_known: true,
          categories_known:,
          **prefill.attributes,
          categories_prefilled_by: (ReceiptGroundTruth::Prefill.categoriser(@receipt) if categories_known)
        }
      end
  end
end

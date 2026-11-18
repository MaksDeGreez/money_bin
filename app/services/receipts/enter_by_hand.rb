module Receipts
  # "Enter by hand": a person types a receipt that OCR could not read (`failed`) or has not read (`uploaded`)
  # into the review form (docs/domain.md, "Entering by hand").
  #
  #   Receipts::EnterByHand.call(receipt)
  #
  # The receipt becomes `extracted`, so the review form opens on it. It gets no items it did not have: an
  # unread receipt starts empty, and a failed one keeps the items of an earlier successful read, if any.
  # `ocr_raw` records that a person started it, `{ "entered_by_hand" => { "started_at", "previous_error" } }`
  # (the OCR failure it replaces, if any). `ocr_model_name`, `ocr_model_version` and `ocr_prompt_version` stay as
  # they are: nil for a receipt no model read, and for a failed one with items, the model that read those items.
  # None is invented. They say what pre-filled the form when the receipt is saved as ground truth
  # (ReceiptGroundTruth::Prefill), so a failed receipt's kept items still name their model.
  #
  # A waiting OCR request is withdrawn (`ocr_requested_at` cleared) under the same row lock that
  # ReceiptOcrJob takes when it starts, so a queued job later finds an `extracted` receipt with no request and
  # leaves it alone: the person's typing is never replaced by a late read. A receipt waiting in an OCR batch
  # leaves it the same way (`ocr_batch_id` cleared): the batch's result for it is then not used
  # (OcrBatches::ApplyResults). A receipt being read (`processing`) is refused, and so is every other status.
  class EnterByHand
    STATUSES = %w[uploaded failed].freeze

    class NotAllowed < StandardError; end

    def self.call(receipt)
      receipt.with_lock do
        unless STATUSES.include?(receipt.status)
          raise NotAllowed, "a receipt that is #{receipt.status} cannot be entered by hand (only uploaded or failed ones)"
        end

        started = { "started_at" => Time.current.iso8601, "previous_error" => receipt.ocr_error }.compact
        receipt.update!(status: :extracted, ocr_requested_at: nil, ocr_batch_id: nil, ocr_raw: { "entered_by_hand" => started })
      end
      LiveUpdate.changed(receipt)
      receipt
    end
  end
end

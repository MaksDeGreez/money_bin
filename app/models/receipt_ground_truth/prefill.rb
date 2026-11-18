class ReceiptGroundTruth
  # What filled a receipt's review form before a person corrected it, read from what the receipt records
  # (docs/domain.md, "The pre-fill rule"):
  #
  #   ReceiptGroundTruth::Prefill.of(receipt) # => #<data by: "stub-ocr", model_version: "0.1.0", prompt_version: nil>
  #
  # - `filled_from` is `dps_xml`: a person filled the fields and items from the receipt's tax-service record
  #   (PREFILLED_BY_DPS_XML). It wins over a model, since it replaced the model's answer in the form, and a
  #   new OCR result clears it.
  # - else `ocr_model_name` is set: that model's answer filled the form (Receipts::ApplyOcr writes the name,
  #   the version and the prompt version together, and replaces every field and item; "Enter by hand" on a
  #   failed receipt keeps the items of the earlier read and these columns with them). When a receipt is read
  #   again by another model after a person corrected it, the new answer replaces the corrections, so the
  #   form now holds that model's answer and the record names it. A record saved before keeps its own
  #   `prefilled_by`: it is a snapshot.
  # - else nothing filled it: the receipt was entered by hand from nothing (PREFILLED_BY_HAND).
  #
  # A person who cleared everything a model filled in and typed it again still gets the model: the rule leans
  # to leaving a receipt out of a model's test set rather than to keeping one it may have shaped.
  #
  # Categories: `categoriser` is the categoriser whose suggestions were on the form when the person chose the
  # categories: `receipts.categoriser_model_name` when a kept item (or a card slip) carries a suggestion, or
  # CATEGORISER_UNKNOWN when one does and the receipt does not say whose; nil when none does.
  Prefill = Data.define(:by, :model_version, :prompt_version) do
    def self.categoriser(receipt)
      items = receipt.items.reject(&:marked_for_destruction?)
      suggested = items.any?(&:suggested_category_id) || (receipt.card_slip? && receipt.suggested_category_id.present?)
      return nil unless suggested

      receipt.categoriser_model_name.to_s.strip.presence || CATEGORISER_UNKNOWN
    end

    def self.of(receipt)
      if receipt.filled_from == "dps_xml"
        new(by: PREFILLED_BY_DPS_XML, model_version: nil, prompt_version: nil)
      elsif receipt.ocr_model_name.present?
        new(by: receipt.ocr_model_name.strip, model_version: receipt.ocr_model_version.presence,
          prompt_version: receipt.ocr_prompt_version.presence)
      else
        new(by: PREFILLED_BY_HAND, model_version: nil, prompt_version: nil)
      end
    end

    # The record's columns.
    def attributes
      { prefilled_by: by, prefilled_model_version: model_version, prefilled_prompt_version: prompt_version }
    end
  end
end

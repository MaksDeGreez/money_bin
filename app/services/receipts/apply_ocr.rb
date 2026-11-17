module Receipts
  # Stores an OCR result on a receipt and moves it to `extracted`.
  #
  #   Receipts::ApplyOcr.call(receipt, MlClient.new.ocr(images))
  #
  # - `ocr_raw` gets the full response body as the service returned it, and `ocr_model_name` and
  #   `ocr_model_version` the model that produced it.
  # - `merchant_name`, `fiscal_number`, `receipt_number`, `issued_at`, `total` and `currency` come from the
  #   receipt part. A null in the answer stores nil.
  # - The items are replaced by the returned ones. An item's position is its place in the answer, counting
  #   from 1 like a printed receipt, so position N is always `ocr_raw["receipt"]["items"][N - 1]`.
  #   Money and quantities are parsed with BigDecimal; text that is not a decimal becomes nil. Money with more
  #   than two decimal places, or a quantity with more than three, is refused by the models (never rounded),
  #   so it counts as unreadable like any other refused value.
  #
  # OCR output is not always tidy, so a value the models refuse does not stop the receipt:
  # - an optional field the model refuses (an unreadable date, a total out of range or with three decimal
  #   places, a bad currency on the receipt; a zero quantity or an odd unit price on an item) is stored as nil;
  # - an item that is still refused after that (no name, no readable amount, an amount with three decimal
  #   places, a negative discount) is skipped. Its position stays free, so the gap and `ocr_raw` show what was left out, and the items no
  #   longer sum to the total, which the person sees at review.
  #
  # Everything runs in one database transaction with the receipt row locked. Applying the same result twice
  # gives the same rows. A `reviewed` receipt is never changed: it raises AlreadyReviewed.
  class ApplyOcr
    RECEIPT_FIELDS = {
      merchant_name: "merchant", fiscal_number: "fiscal_number", receipt_number: "receipt_number",
      issued_at: "issued_at", total: "total", currency: "currency"
    }.freeze
    # Item fields that may be nil, so a refused value is dropped instead of the whole item.
    OPTIONAL_ITEM_FIELDS = %i[quantity unit_price].freeze
    FIRST_POSITION = 1

    class Error < StandardError; end
    # The receipt was already accepted into the ledger; a new OCR result must not change it.
    class AlreadyReviewed < Error; end

    def self.call(receipt, result)
      new(receipt, result).call
    end

    # `result` is an MlClient::OcrResult (or anything with `body`, `receipt`, `model_name` and
    # `model_version`).
    def initialize(receipt, result)
      @receipt = receipt
      @result = result
    end

    # Returns the receipt.
    def call
      @receipt.with_lock do
        raise AlreadyReviewed, "receipt #{@receipt.id} is already reviewed" if @receipt.reviewed?

        assign_receipt_fields
        @receipt.save!
        replace_items
      end
      @receipt
    end

    private
      def assign_receipt_fields
        data = @result.receipt
        @receipt.assign_attributes(
          ocr_raw: @result.body, ocr_model_name: @result.model_name, ocr_model_version: @result.model_version,
          status: :extracted,
          merchant_name: text(data["merchant"]), fiscal_number: text(data["fiscal_number"]),
          receipt_number: text(data["receipt_number"]), issued_at: time(data["issued_at"]),
          total: decimal(data["total"]), currency: text(data["currency"])
        )
        clear_refused(@receipt, RECEIPT_FIELDS.keys)
      end

      def replace_items
        ReceiptItem.where(receipt_id: @receipt.id).delete_all
        @receipt.items.reset

        @result.receipt["items"].each_with_index do |data, index|
          item = @receipt.items.build(
            position: FIRST_POSITION + index, name: text(data["name"]), quantity: decimal(data["quantity"]),
            unit_price: decimal(data["unit_price"]), amount: decimal(data["amount"]),
            discount: decimal(data["discount"]) || BigDecimal("0")
          )
          clear_refused(item, OPTIONAL_ITEM_FIELDS)
          if item.valid?
            item.save!
          else
            skip(item)
          end
        end
      end

      # Sets each of `fields` that fails validation to nil.
      def clear_refused(record, fields)
        return if record.valid?

        fields.each { |field| record[field] = nil if record.errors.include?(field) }
      end

      def skip(item)
        @receipt.items.delete(item)
        Rails.logger.warn(
          "Receipts::ApplyOcr: receipt #{@receipt.id} skipped item at position #{item.position} " \
          "(#{item.errors.attribute_names.join(', ')} refused)"
        )
      end

      def text(value)
        value.is_a?(String) ? value.squish.presence : nil
      end

      # A decimal from a string (or a number, though the service sends strings). Never through Float.
      def decimal(value)
        case value
        when String then BigDecimal(value.strip, exception: false)
        when Integer, BigDecimal then BigDecimal(value)
        end
      end

      def time(value)
        Time.zone.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end
  end
end

require_relative "ml_batch_stubs"
require_relative "receipt_images"

# Building receipts and OCR batches for the batch tests. Include it in a test case (it includes MlBatchStubs and
# ReceiptImages).
module OcrBatchHelpers
  def self.included(base)
    base.include MlBatchStubs
    base.include ReceiptImages
  end

  def batch_receipt(red = 10, **attributes)
    @batch_colour = (@batch_colour || 0) + 1
    Receipt.create!(images: [ image_upload(png_bytes(red:, green: @batch_colour % 256, blue: @batch_colour / 256)) ],
      **attributes)
  end

  # A batch holding `receipts` (each gets a waiting entry and the hold), in `state`.
  def held_batch(receipts, state: "running", provider_batch_id: "batch_t1", **attributes)
    provider_batch_id = nil if state == "pending"
    batch = OcrBatch.create!(state:, receipts_count: receipts.size, provider_batch_id:, next_check_at: 1.minute.ago,
      **attributes)
    receipts.each_with_index do |receipt, index|
      batch.entries.create!(receipt:, position: index + 1, custom_id: OcrBatchEntry.new_custom_id)
      receipt.update_columns(ocr_batch_id: batch.id)
    end
    batch
  end

  def key_of(batch, receipt)
    batch.entries.find_by!(receipt:).custom_id
  end

  def available_capability(**overrides)
    MlClient::BatchCapability.new(body: {}, available: true, code: nil, message: nil, model_name: "example/vision-model",
      model_version: "v", providers: [ "anthropic" ], max_receipts: 100, max_upload_bytes: 300.megabytes,
      retention_days: 30, **overrides)
  end
end

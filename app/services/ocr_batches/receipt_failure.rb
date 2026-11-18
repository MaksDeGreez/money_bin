module OcrBatches
  # Marks a receipt of a batch `failed` with the reason, in the shape ReceiptOcrJob stores
  # (`ocr_raw: { "error" => { "code", "message" } }`), and takes it out of the batch. Call it with the receipt row
  # locked. `update_columns`, as the job: a failure is recorded even if another validation of the receipt fails.
  module ReceiptFailure
    module_function

    def record(receipt, code, message)
      reason = { "code" => code, "message" => message.to_s.squish.truncate(ReceiptOcrJob::MAX_MESSAGE_LENGTH) }
      receipt.update_columns(status: "failed", ocr_raw: { "error" => reason }, ocr_requested_at: nil, ocr_batch_id: nil,
        updated_at: Time.current)
      Receipts::LiveUpdate.changed(receipt)
    end
  end
end

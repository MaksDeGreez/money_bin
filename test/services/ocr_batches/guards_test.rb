require "test_helper"
require_relative "../../support/ocr_batch_helpers"

# The synchronous OCR path and a person's work, while a receipt waits in a batch.
class OcrBatches::GuardsTest < ActiveJob::TestCase
  include OcrBatchHelpers

  test "a stray read one at a time leaves a receipt in a batch to the batch" do
    receipt = batch_receipt
    held_batch([ receipt ])

    ReceiptOcrJob.perform_now(receipt)

    assert receipt.reload.uploaded?
    assert_not_requested :post, ml_url("/ocr")
  end

  test "entering by hand takes the receipt out of its batch" do
    receipt = batch_receipt
    held_batch([ receipt ])

    Receipts::EnterByHand.call(receipt)

    assert receipt.reload.extracted?
    assert_nil receipt.ocr_batch_id
  end
end

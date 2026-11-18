require "test_helper"
require_relative "../support/ml_service_stubs"

class ReceiptCategoriseJobTest < ActiveJob::TestCase
  include MlServiceStubs

  test "fills the suggestions of an extracted receipt, without OCR" do
    receipt = receipts(:corner_receipt)
    texts = receipt.items.map(&:name)
    stub_ml_categorise(texts)

    ReceiptCategoriseJob.perform_now(receipt)

    assert_empty ml_requests(:ocr)
    assert_equal texts, JSON.parse(ml_requests(:categorise).sole.body)["texts"]
    assert receipt.items.reload.all? { |item| item.suggested_by == "model" }
  end

  test "has its own queue, which the OCR capsule works first" do
    assert_equal "receipt_categorise", ReceiptCategoriseJob.new.queue_name
  end

  test "a receipt deleted before the job ran is discarded" do
    receipt = receipts(:corner_receipt)
    job = ReceiptCategoriseJob.new(receipt)
    serialized = job.serialize
    receipt.items.delete_all
    receipt.delete

    assert_nothing_raised { ActiveJob::Base.execute(serialized) }
  end
end

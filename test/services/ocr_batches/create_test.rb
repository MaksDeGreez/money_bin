require "test_helper"
require_relative "../../support/ocr_batch_helpers"

class OcrBatches::CreateTest < ActiveSupport::TestCase
  include OcrBatchHelpers
  include ActiveJob::TestHelper

  test "claims the unread and failed receipts of a relation, in its order, with random keys" do
    first = batch_receipt
    second = batch_receipt
    relation = Receipt.where(id: [ first.id, second.id, receipts(:corner_receipt).id ]).order(:id)

    batches = nil
    assert_enqueued_with(job: OcrBatchSubmitJob) { batches = OcrBatches::Create.call(relation, capability: available_capability) }

    batch = batches.sole
    assert batch.pending?
    assert_equal 2, batch.receipts_count
    assert_equal [ first.id, second.id ], batch.entries.map(&:receipt_id)
    assert_equal [ 1, 2 ], batch.entries.map(&:position)
    batch.entries.each do |entry|
      assert_match OcrBatchEntry::CUSTOM_ID_FORMAT, entry.custom_id
      assert_equal 24, entry.custom_id.size
      assert_not_includes entry.custom_id, entry.receipt_id.to_s if entry.receipt_id > 9
    end
    assert_equal [ batch.id ] * 2, [ first.reload.ocr_batch_id, second.reload.ocr_batch_id ]
    assert_nil receipts(:corner_receipt).reload.ocr_batch_id, "an extracted receipt is not sent"
  end

  test "includes failed receipts without items, as Read all does, and skips those with items" do
    failed = receipts(:failed_receipt)

    OcrBatches::Create.call(Receipt.where(id: failed.id), capability: available_capability)

    assert failed.reload.in_ocr_batch?
  end

  test "a receipt waiting for a read one at a time, or already in a batch, is not taken" do
    queued = batch_receipt
    Receipts::RequestOcr.first_read(queued)
    held = batch_receipt
    held_batch([ held ])

    batches = OcrBatches::Create.call(Receipt.where(id: [ queued.id, held.id ]), capability: available_capability)

    assert_empty batches
    assert_nil queued.reload.ocr_batch_id
  end

  test "a held receipt is not queued one at a time, not even by opening its page" do
    receipt = batch_receipt
    OcrBatches::Create.call(Receipt.where(id: receipt.id), capability: available_capability)

    assert_no_enqueued_jobs(only: ReceiptOcrJob) do
      assert_empty Receipts::RequestOcr.first_read(receipt)
      assert_empty Receipts::RequestOcr.read_all(Receipt.where(id: receipt.id))
    end
    assert_nil receipt.reload.ocr_requested_at
  end

  test "splits by the service's receipt limit and by photo bytes" do
    receipts = Array.new(5) { batch_receipt }
    relation = Receipt.where(id: receipts.map(&:id)).order(:id)

    batches = OcrBatches::Create.call(relation, capability: available_capability(max_receipts: 2))

    assert_equal [ 2, 2, 1 ], batches.map(&:receipts_count)
    assert_equal receipts.map(&:id), batches.flat_map { |batch| batch.entries.map(&:receipt_id) }

    bytes = receipts.first.images.first.blob.byte_size
    Receipt.where(id: receipts.map(&:id)).update_all(ocr_batch_id: nil)
    by_size = OcrBatches::Create.call(relation, capability: available_capability(max_upload_bytes: bytes * 3))
    assert_equal [ 3, 2 ], by_size.map(&:receipts_count)
  end

  test "refuses to run when batch mode is not available" do
    off = available_capability(available: false, code: "openrouter_batch_not_allowed")
    assert_raises(ArgumentError) { OcrBatches::Create.call(Receipt.all, capability: off) }
  end
end

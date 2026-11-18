require "test_helper"

class ReceiptCountsQueryTest < ActiveSupport::TestCase
  test "counts the fixture receipts per status, read by OCR and with ground truth" do
    counts = ReceiptCountsQuery.new.call

    assert_equal Receipt.count, counts.total
    assert_equal Receipt.statuses.keys, counts.by_status.keys
    assert_equal Receipt.group(:status).count, counts.by_status.reject { |_, count| count.zero? }
    assert_equal counts.total, counts.by_status.values.sum
    assert_equal Receipt.where.not(ocr_model_name: nil).count, counts.read_by_ocr
    assert_equal ReceiptGroundTruth.distinct.count(:receipt_id), counts.with_ground_truth
  end

  test "a receipt with two ground-truth records counts once; one entered by hand is not read by OCR" do
    receipt = receipts(:new_receipt)
    before = ReceiptCountsQuery.new.call
    receipt.update_columns(status: "extracted", ocr_raw: { "entered_by_hand" => { "started_at" => Time.current.iso8601 } })
    # The market receipt has an imported record already; a manual one is its second.
    second = receipt_ground_truths(:corner_manual).attributes.except("id").merge("receipt_id" => receipts(:market_receipt).id)
    ReceiptGroundTruth.insert_all!([ second ])
    assert_equal 2, receipts(:market_receipt).ground_truths.count

    after = ReceiptCountsQuery.new.call

    assert_equal before.read_by_ocr, after.read_by_ocr
    assert_equal before.with_ground_truth, after.with_ground_truth
    assert_equal before.by_status["extracted"] + 1, after.by_status["extracted"]
    assert_equal before.by_status["uploaded"] - 1, after.by_status["uploaded"]
  end

  test "no receipts: every count is zero, in one query" do
    ReceiptGroundTruth.delete_all
    ReceiptItem.delete_all
    Receipt.delete_all

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    counts = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ReceiptCountsQuery.new.call }

    assert_equal 1, queries
    assert_equal 0, counts.total
    assert_equal Receipt.statuses.keys.index_with(0), counts.by_status
    assert_equal 0, counts.read_by_ocr
    assert_equal 0, counts.with_ground_truth
  end
end

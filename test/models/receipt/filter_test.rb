require "test_helper"

class Receipt::FilterTest < ActiveSupport::TestCase
  def ids(filter)
    filter.scope.map(&:id).sort
  end

  test "no filter shows every receipt, newest first" do
    filter = Receipt::Filter.new

    assert_equal Receipt.count, filter.scope.count
    assert_not filter.any?
    assert_equal({}, filter.to_params)
  end

  test "values that are not choices are dropped" do
    filter = Receipt::Filter.new(status: "lost", kind: "napkin", qr: "maybe", batch: "  ", incomplete: "0", page: "2")

    assert_equal({}, filter.to_params)
  end

  test "each value narrows the scope and comes back in the parameters" do
    receipts(:corner_receipt).update_columns(kind: "card_slip")
    filter = Receipt::Filter.new("status" => "extracted", "kind" => "card_slip", "qr" => "without", "batch" => "october-shopping")

    assert_equal [ receipts(:corner_receipt).id ], ids(filter)
    assert_equal({ batch: "october-shopping", status: "extracted", kind: "card_slip", qr: "without" }, filter.to_params)
  end

  test "incomplete only" do
    receipts(:new_receipt).update_columns(incomplete: true)
    filter = Receipt::Filter.new(incomplete: "1")

    assert_equal [ receipts(:new_receipt).id ], ids(filter)
    assert_equal({ incomplete: "1" }, filter.to_params)
  end

  test "the counts per status ignore the status filter and list every status" do
    counts = Receipt::Filter.new(status: "failed", batch: "october-shopping").status_counts

    assert_equal({ "uploaded" => 0, "processing" => 0, "extracted" => 1, "reviewed" => 1, "failed" => 0 }, counts)
  end

  test "merge changes or removes one value" do
    filter = Receipt::Filter.new(status: "failed", kind: "fiscal")

    assert_equal({ kind: "fiscal" }, filter.merge(status: nil).to_params)
    assert_equal({ status: "uploaded", kind: "fiscal" }, filter.merge(status: "uploaded").to_params)
  end

  test "neighbours follow the filtered order" do
    receipts(:new_receipt).update_columns(created_at: 1.day.ago)
    filter = Receipt::Filter.new(kind: "unknown") # new_receipt (uploaded in the app), then failed_receipt (rcpt_000042)

    assert_equal [ nil, receipts(:failed_receipt).id ], filter.neighbours(receipts(:new_receipt))
    assert_equal [ receipts(:new_receipt).id, nil ], filter.neighbours(receipts(:failed_receipt))
    assert_equal [ nil, nil ], filter.neighbours(receipts(:market_receipt))
  end

  test "the batches are the distinct labels in order" do
    assert_equal %w[november-shopping october-shopping], Receipt::Filter.batches
  end

  test "the next receipt to review follows the filtered order, wraps around, and skips everything but extracted" do
    receipts(:new_receipt).update_columns(status: "extracted")
    receipts(:new_receipt).update_columns(created_at: 1.minute.from_now)
    filter = Receipt::Filter.new
    order = filter.scope.pluck(:id)
    assert_equal [ receipts(:new_receipt), receipts(:corner_receipt), receipts(:failed_receipt), receipts(:market_receipt) ].map(&:id), order

    assert_equal receipts(:corner_receipt).id, filter.next_to_review(receipts(:new_receipt))
    assert_equal receipts(:new_receipt).id, filter.next_to_review(receipts(:corner_receipt)), "wraps to the start"
    assert_equal receipts(:new_receipt).id, filter.next_to_review(receipts(:market_receipt))
  end

  test "the next receipt to review is found after one that just left a status filter" do
    filter = Receipt::Filter.new("status" => "extracted")
    receipts(:new_receipt).update_columns(status: "extracted")
    receipts(:corner_receipt).update_columns(status: "reviewed")

    assert_equal receipts(:new_receipt).id, filter.next_to_review(receipts(:corner_receipt))
    assert_nil Receipt::Filter.new("status" => "failed").next_to_review(receipts(:corner_receipt))
    assert_nil Receipt::Filter.new("batch" => "november-shopping").next_to_review(receipts(:corner_receipt))
  end
  # --- Ground truth ---------------------------------------------------------------------------------------
  # Fixtures: market_receipt has a checked tax-service record, corner_receipt a manual one, the others none.

  test "the ground-truth filter: labelled by hand, not labelled, with a tax-service record, with none" do
    market, corner, fresh, failed = receipts(:market_receipt, :corner_receipt, :new_receipt, :failed_receipt).map(&:id)
    assert_equal [ corner ], ids(Receipt::Filter.new(truth: "manual"))
    assert_equal [ market, fresh, failed ].sort, ids(Receipt::Filter.new(truth: "unlabelled"))
    assert_equal [ market ], ids(Receipt::Filter.new(truth: "dps_xml"))
    assert_equal [ fresh, failed ].sort, ids(Receipt::Filter.new(truth: "none"))
    assert_equal({ truth: "none" }, Receipt::Filter.new(truth: "none", check: "maybe").to_params)
    assert_equal({}, Receipt::Filter.new(truth: "all").to_params)
  end

  test "the check filter keeps receipts whose tax-service record was checked, or not" do
    assert_equal [ receipts(:market_receipt).id ], ids(Receipt::Filter.new(check: "checked"))
    assert_empty ids(Receipt::Filter.new(check: "unchecked"))
    receipt_ground_truths(:market_dps).clear_check!
    assert_equal [ receipts(:market_receipt).id ], ids(Receipt::Filter.new(check: "unchecked"))
  end

  test "the ground-truth counts ignore their own filter and apply the others" do
    filter = Receipt::Filter.new(truth: "manual", batch: "october-shopping")
    assert_equal({ "manual" => 1, "unlabelled" => 1, "dps_xml" => 1, "none" => 0 }, filter.truth_counts)
    assert_equal({ "checked" => 0, "unchecked" => 0 }, filter.check_counts, "the truth filter still applies to the check counts")
    assert_equal({ "checked" => 1, "unchecked" => 0 }, Receipt::Filter.new.check_counts)
  end

  test "labelling progress counts the labelled receipts and their items in the filter" do
    progress = Receipt::Filter.new.labelling_progress
    assert_equal [ Receipt.count, 1, 0 ], [ progress.receipts, progress.labelled, progress.labelled_items ]
    receipt_ground_truths(:corner_manual).update_columns(document: receipt_ground_truths(:market_dps).document)
    assert_equal 3, Receipt::Filter.new(batch: "october-shopping").labelling_progress.labelled_items
    assert_equal 0, Receipt::Filter.new(batch: "november-shopping").labelling_progress.labelled
    unlabelled = Receipt::Filter.new(truth: "unlabelled").labelling_progress
    assert_equal [ Receipt.count, 1 ], [ unlabelled.receipts, unlabelled.labelled ], "the ground-truth filter is left out"
  end

  test "the next receipt to label has no manual record and an open form, follows the order and wraps around" do
    market, corner = receipts(:market_receipt, :corner_receipt)
    filter = Receipt::Filter.new
    assert_equal market.id, filter.next_to_label(corner), "reviewed counts: its form is open"
    assert_nil filter.next_to_label(market), "corner is labelled; the others are not read yet"

    receipt_ground_truths(:corner_manual).delete
    assert_equal corner.id, filter.next_to_label(market)
    corner.update_columns(ocr_requested_at: Time.current)
    assert_nil filter.next_to_label(market), "OCR queued: not now"
  end

  test "the next receipt to label is found after one that just left the 'not labelled' filter" do
    receipt_ground_truths(:corner_manual).delete
    filter = Receipt::Filter.new(truth: "unlabelled")
    ReceiptGroundTruth.create!(receipt: receipts(:market_receipt), source: :manual, schema_version: 2, items_known: false,
      prefilled_by: ReceiptGroundTruth::PREFILLED_BY_HAND, document: ReceiptGroundTruth::Document.blank)
    assert_equal receipts(:corner_receipt).id, filter.next_to_label(receipts(:market_receipt))
  end
end

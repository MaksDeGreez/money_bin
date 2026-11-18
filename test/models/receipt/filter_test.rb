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
end

require "test_helper"

class Receipts::EnterByHandTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "an unread receipt becomes extracted with no items, and ocr_raw records that a person started it" do
    receipt = receipts(:new_receipt)

    travel_to Time.zone.local(2026, 11, 18, 10, 0) do
      Receipts::EnterByHand.call(receipt)
    end

    receipt.reload
    assert receipt.extracted?
    assert receipt.entered_by_hand?
    assert_equal({ "entered_by_hand" => { "started_at" => "2026-11-18T10:00:00+02:00" } }, receipt.ocr_raw)
    assert_nil receipt.ocr_model_name, "no model read it, and none is invented"
    assert_empty receipt.items
    assert receipt.reviewable?
    assert_equal 1, receipt.lock_version
  end

  test "a failed receipt keeps the failure it replaces and the items of an earlier read" do
    receipt = receipts(:failed_receipt)
    receipt.update_columns(ocr_model_name: "stub-ocr")
    receipt.items.create!(position: 1, name: "Bread", amount: BigDecimal("30.00"))

    Receipts::EnterByHand.call(receipt)

    receipt.reload
    assert_equal({ "code" => "unsupported_media_type", "message" => "The file is not a supported image." },
      receipt.ocr_raw.dig("entered_by_hand", "previous_error"))
    assert_nil receipt.ocr_error
    assert_equal [ "Bread" ], receipt.items.map(&:name)
    assert_equal "stub-ocr", receipt.ocr_model_name, "the model that read the kept items stays named"
  end

  test "a waiting OCR request is withdrawn, so a queued job leaves the typed receipt alone" do
    receipt = receipts(:new_receipt)
    receipt.update_columns(ocr_requested_at: 1.minute.ago)

    Receipts::EnterByHand.call(receipt)
    assert_nil receipt.reload.ocr_requested_at

    ReceiptOcrJob.perform_now(receipt)
    assert receipt.reload.extracted?
    assert receipt.entered_by_hand?
  end

  test "a receipt being read, already read or accepted is refused" do
    receipts(:new_receipt).update_columns(status: "processing")
    [ receipts(:new_receipt), receipts(:corner_receipt), receipts(:market_receipt) ].each do |receipt|
      before = receipt.reload.attributes
      error = assert_raises(Receipts::EnterByHand::NotAllowed) { Receipts::EnterByHand.call(receipt) }
      assert_match "cannot be entered by hand", error.message
      assert_equal before, receipt.reload.attributes
    end
  end
end

require "test_helper"
require_relative "../../support/ml_service_stubs"

class Receipts::ApplyOcrTest < ActiveSupport::TestCase
  include MlServiceStubs

  def apply(receipt, result)
    Receipts::ApplyOcr.call(receipt, result)
  end

  def item_rows(receipt)
    receipt.items.reload.map do |item|
      [ item.position, item.name, item.quantity, item.unit_price, item.amount, item.discount ]
    end
  end

  test "stores the answer, fills the receipt and its items, and marks it extracted" do
    receipt = receipts(:new_receipt)
    result = ml_ocr_result

    assert_same receipt, apply(receipt, result)

    receipt.reload
    assert receipt.extracted?
    assert_equal result.body, receipt.ocr_raw
    assert_equal "stub-ocr", receipt.ocr_model_name
    assert_equal "0.1.0", receipt.ocr_model_version
    assert_equal "Sample Grocer", receipt.merchant_name
    assert_equal "3000000007", receipt.fiscal_number
    assert_equal "000451", receipt.receipt_number
    assert_equal Time.utc(2026, 9, 14, 7, 20), receipt.issued_at
    assert_equal BigDecimal("117.40"), receipt.total
    assert_equal "UAH", receipt.currency
    assert_equal [
      [ 1, "Oat milk 1 l", BigDecimal("1"), BigDecimal("54.90"), BigDecimal("54.90"), BigDecimal("0") ],
      [ 2, "Apples", BigDecimal("1.25"), BigDecimal("52"), BigDecimal("62.50"), BigDecimal("2.50") ]
    ], item_rows(receipt)
    assert receipt.items.all? { |item| item.amount.is_a?(BigDecimal) }
    assert receipt.items.none?(&:category_id)
  end

  test "amounts are parsed as decimals, never through floats" do
    receipt = receipts(:new_receipt)
    apply(receipt, ml_ocr_result(receipt: { total: "0.30", items: [
      { name: "A", quantity: "3", unit_price: "0.10", amount: "0.10", discount: "0.00" },
      { name: "B", quantity: "1", unit_price: "0.20", amount: "0.20", discount: "0.00" }
    ] }))

    assert_equal receipt.reload.total, receipt.items_total
  end

  test "null fields are stored as nil and an answer without items leaves none" do
    receipt = receipts(:new_receipt)

    apply(receipt, ml_ocr_result(receipt: { merchant: nil, fiscal_number: nil, receipt_number: nil, issued_at: nil, items: [] }))

    receipt.reload
    assert receipt.extracted?
    assert_nil receipt.merchant_name
    assert_nil receipt.fiscal_number
    assert_nil receipt.receipt_number
    assert_nil receipt.issued_at
    assert_equal BigDecimal("117.40"), receipt.total
    assert_empty receipt.items
  end

  test "text is squished, a missing discount is zero, and a time without offset is Kyiv time" do
    receipt = receipts(:new_receipt)

    apply(receipt, ml_ocr_result(receipt: { merchant: "  Sample   Grocer \n", currency: "uah", issued_at: "2026-09-14T10:20:00",
      items: [ { name: " Tea\tbags ", amount: "45.00" } ] }))

    receipt.reload
    assert_equal "Sample Grocer", receipt.merchant_name
    assert_equal "UAH", receipt.currency
    assert_equal Time.utc(2026, 9, 14, 7, 20), receipt.issued_at
    assert_equal [ [ 1, "Tea bags", nil, nil, BigDecimal("45"), BigDecimal("0") ] ], item_rows(receipt)
  end

  test "replaces the receipt's items" do
    receipt = receipts(:corner_receipt)
    old_ids = receipt.items.ids
    assert_equal 3, old_ids.size

    apply(receipt, ml_ocr_result)

    assert_equal [ "Oat milk 1 l", "Apples" ], receipt.items.reload.map(&:name)
    assert_not ReceiptItem.exists?(id: old_ids)
  end

  test "applying the same answer twice gives the same rows" do
    receipt = receipts(:new_receipt)
    apply(receipt, ml_ocr_result)
    first = [ receipt.reload.attributes.except("updated_at"), item_rows(receipt) ]

    assert_no_difference -> { ReceiptItem.count } do
      apply(receipt, ml_ocr_result)
    end

    assert_equal first, [ receipt.reload.attributes.except("updated_at"), item_rows(receipt) ]
  end

  test "works on a failed receipt and on one stuck in processing" do
    %i[failed processing].each do |status|
      receipt = receipts(:new_receipt)
      receipt.update!(status:, ocr_raw: { "error" => { "code" => "ml_timeout", "message" => "Too slow." } })

      apply(receipt, ml_ocr_result)

      assert receipt.reload.extracted?
      assert_equal "stub", receipt.ocr_raw["backend"]
    end
  end

  test "a reviewed receipt is never changed" do
    receipt = receipts(:market_receipt)
    before = [ receipt.attributes, item_rows(receipt) ]

    assert_raises(Receipts::ApplyOcr::AlreadyReviewed) { apply(receipt, ml_ocr_result) }

    assert_equal before, [ receipt.reload.attributes, item_rows(receipt) ]
  end

  test "the status is checked on the locked row, not on a stale copy" do
    stale = Receipt.find(receipts(:corner_receipt).id)
    receipts(:corner_receipt).update_columns(status: "reviewed")

    assert_raises(Receipts::ApplyOcr::AlreadyReviewed) { apply(stale, ml_ocr_result) }
    assert_equal 3, stale.items.count
  end

  test "receipt fields the model refuses are stored as nil" do
    receipt = receipts(:new_receipt)

    apply(receipt, ml_ocr_result(receipt: { issued_at: "yesterday", total: "1e14", currency: "EURO" }))

    receipt.reload
    assert receipt.extracted?
    assert_nil receipt.issued_at
    assert_nil receipt.total
    assert_nil receipt.currency
    assert_equal "Sample Grocer", receipt.merchant_name
  end

  test "item quantities and unit prices the model refuses are dropped, the item is kept" do
    receipt = receipts(:new_receipt)

    apply(receipt, ml_ocr_result(receipt: { items: [
      { name: "Gift card", quantity: "0", unit_price: "1e14", amount: "500.00", discount: "0.00" },
      { name: "Bag", quantity: "about two", unit_price: "2.00", amount: "4.00", discount: "0.00" }
    ] }))

    assert_equal [
      [ 1, "Gift card", nil, nil, BigDecimal("500"), BigDecimal("0") ],
      [ 2, "Bag", nil, BigDecimal("2"), BigDecimal("4"), BigDecimal("0") ]
    ], item_rows(receipt)
  end

  test "an item the model still refuses is skipped, its position stays free, and the answer is kept" do
    receipt = receipts(:new_receipt)
    items = [
      { name: "Bread", quantity: "1", unit_price: "30.00", amount: "30.00", discount: "0.00" },
      { name: "  ", quantity: "1", unit_price: "10.00", amount: "10.00", discount: "0.00" },
      { name: "Smudged", quantity: "1", unit_price: "5.00", amount: "5,00", discount: "0.00" },
      { name: "Coupon", quantity: "1", unit_price: "5.00", amount: "5.00", discount: "-1.00" },
      { name: "Cheese", quantity: "1", unit_price: "80.00", amount: "80.00", discount: "0.00" }
    ]

    apply(receipt, result = ml_ocr_result(receipt: { items: }))

    receipt.reload
    assert receipt.extracted?
    assert_equal [ [ 1, "Bread" ], [ 5, "Cheese" ] ], receipt.items.map { |item| [ item.position, item.name ] }
    assert_equal result.body, receipt.ocr_raw
    assert_equal 5, receipt.ocr_raw.dig("receipt", "items").size
    assert_equal "Cheese", receipt.ocr_raw.dig("receipt", "items", 4, "name")
  end

  test "values of the wrong JSON type are treated as missing" do
    receipt = receipts(:new_receipt)

    apply(receipt, ml_ocr_result(receipt: { merchant: 42, issued_at: 1_700_000_000, total: 117.4, items: [
      { name: "Water", quantity: 2, unit_price: 12.5, amount: 25, discount: nil }
    ] }))

    receipt.reload
    assert_nil receipt.merchant_name
    assert_nil receipt.issued_at
    assert_nil receipt.total, "a float total is not trusted"
    assert_equal [ [ 1, "Water", BigDecimal("2"), nil, BigDecimal("25"), BigDecimal("0") ] ], item_rows(receipt)
  end

  test "a failure rolls everything back" do
    receipt = receipts(:corner_receipt)
    result = ml_ocr_result
    # The first item is stored, then reading the second one fails.
    items = Object.new
    items.define_singleton_method(:each_with_index) do |&block|
      block.call(result.receipt["items"].first, 0)
      raise IOError, "boom"
    end
    broken = result.with(receipt: result.receipt.merge("items" => items))

    assert_raises(IOError) { apply(receipt, broken) }

    receipt.reload
    assert receipt.extracted?
    assert_equal "Corner Shop", receipt.merchant_name
    assert_equal 3, receipt.items.count
  end
end

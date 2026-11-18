require "test_helper"
require_relative "../../support/ml_service_stubs"
require "turbo/broadcastable/test_helper"

class Receipts::ReviewTest < ActiveSupport::TestCase
  include MlServiceStubs
  include Turbo::Broadcastable::TestHelper

  setup do
    @receipt = receipts(:corner_receipt)
    @water, @sandwich, @deposit = receipt_items(:corner_water, :corner_sandwich, :corner_deposit)
  end

  # The form's fields for `receipt` as the page renders them, with `changes` on top.
  def form(receipt = @receipt, items: nil, **changes)
    items ||= receipt.items.map do |item|
      { id: item.id.to_s, name: item.name, quantity: item.quantity&.to_s("F"), unit_price: item.unit_price&.to_s("F"),
        discount: item.discount.to_s("F"), amount: item.amount.to_s("F"), category_id: item.category_id.to_s, _destroy: "0" }
    end
    {
      lock_version: receipt.lock_version.to_s, kind: receipt.kind.to_s, merchant_name: receipt.merchant_name.to_s,
      issued_at: receipt.issued_at&.in_time_zone&.strftime("%Y-%m-%dT%H:%M:%S").to_s, total: receipt.total&.to_s("F").to_s,
      currency: receipt.currency.to_s, fiscal_number: receipt.fiscal_number.to_s, receipt_number: receipt.receipt_number.to_s,
      card_last4: receipt.card_last4.to_s, incomplete: receipt.incomplete? ? "1" : "0", category_id: receipt.category_id.to_s,
      items_attributes: items.each_with_index.to_h { |item, index| [ index.to_s, item ] }
    }.merge(changes)
  end

  def item_form(item, **changes)
    form[:items_attributes].values.find { |row| row[:id] == item.id.to_s }.merge(changes)
  end

  def review(params = form, intent: "save", receipt: @receipt)
    Receipts::Review.new(Receipt.find(receipt.id), params, intent:)
  end

  def rows_with(*changed)
    ids = changed.map { |row| row[:id] }
    form[:items_attributes].values.reject { |row| ids.include?(row[:id]) } + changed
  end

  # --- Save ---------------------------------------------------------------------------------------------

  test "a save stores the corrected fields and items, and the receipt stays extracted" do
    params = form(merchant_name: "Corner Shop No. 2", total: "152,50", issued_at: "2026-10-08T12:07:30", fiscal_number: "123",
                  items: [ item_form(@water, name: "Still water 1.5 l", amount: "60,00"), item_form(@sandwich), item_form(@deposit) ])

    assert review(params).call

    @receipt.reload
    assert @receipt.extracted?
    assert_equal [ "Corner Shop No. 2", BigDecimal("152.50"), "123" ], [ @receipt.merchant_name, @receipt.total, @receipt.fiscal_number ]
    assert_equal Time.zone.local(2026, 10, 8, 12, 7, 30), @receipt.issued_at
    assert_equal "Still water 1.5 l", @water.reload.name
    assert_equal 1, @receipt.lock_version, "every save moves the version"
  end

  test "a save never changes ocr_raw, the model, the QR ground truth, the batch or the ingest id" do
    @receipt.update_columns(ocr_raw: { "receipt" => { "items" => [ { "name" => "Sparkling water" } ] } }, qr_total: BigDecimal("150.00"),
                            qr_payload: "qr", ingest_id: "rcpt_000777")
    before = @receipt.reload.attributes.slice("ocr_raw", "ocr_model_name", "ocr_model_version", "qr_payload", "qr_issued_at", "qr_total",
                                              "qr_fiscal_number", "qr_receipt_number", "batch", "ingest_id", "sha256", "status")
    params = form(total: "999.00", fiscal_number: "999").merge(qr_total: "999.00", ocr_raw: { "x" => 1 }, status: "reviewed", batch: "x",
                                                                 ocr_model_name: "person", ingest_id: "rcpt_000999")

    assert review(params).call

    after = @receipt.reload.attributes.slice(*before.keys)
    assert_equal before, after
    assert_equal BigDecimal("999.00"), @receipt.total
  end

  test "an accept never changes ocr_raw either" do
    @receipt.update_columns(ocr_raw: { "receipt" => { "total" => "152.50" } })

    assert review(form(account_id: accounts(:card_uah).id.to_s), intent: "accept").call

    assert_equal({ "receipt" => { "total" => "152.50" } }, @receipt.reload.ocr_raw)
    assert @receipt.reviewed?
  end

  test "money is read with a comma or a dot, and spaces between thousands are dropped" do
    params = form(total: "1 152,50", items: [ item_form(@water, amount: "1 060,00", unit_price: "530", quantity: "2,000"),
                                              item_form(@sandwich, amount: "+95.0"), item_form(@deposit, amount: "−2,50") ])

    assert review(params).call

    assert_equal BigDecimal("1152.50"), @receipt.reload.total
    assert_equal [ BigDecimal("1060"), BigDecimal("530"), BigDecimal("2") ], @water.reload.slice(:amount, :unit_price, :quantity).values
    assert_equal BigDecimal("95"), @sandwich.reload.amount
    assert_equal BigDecimal("-2.50"), @deposit.reload.amount
  end

  test "more decimal places than the column keeps is an error next to the field, never rounded, and nothing is saved" do
    result = review(form(total: "152.505", items: rows_with(item_form(@water, amount: "60.004", quantity: "1.2345"))))

    assert_not result.call

    assert_equal BigDecimal("152.50"), @receipt.reload.total
    assert_equal BigDecimal("60.00"), @water.reload.amount
    assert_equal [ "must have at most 2 decimal places (it is never rounded)" ], result.form_receipt.errors[:total]
    water = result.form_receipt.items.find { |item| item.id == @water.id }
    assert_equal "60.004", water.read_attribute_before_type_cast("amount"), "the typed value stays on the form"
    assert_includes water.errors[:amount], "must have at most 2 decimal places (it is never rounded)"
    assert_includes water.errors[:quantity], "must have at most 3 decimal places (it is never rounded)"
    assert_equal 0, @receipt.lock_version
  end

  test "a value that rounds to the stored one is still refused, not passed over as unchanged" do
    result = review(form(items: rows_with(item_form(@water, amount: "60.004"))))

    assert_not result.call
    assert_includes result.form_receipt.items.find { |item| item.id == @water.id }.errors[:amount],
      "must have at most 2 decimal places (it is never rounded)"
    assert_equal 0, @receipt.reload.lock_version
  end

  test "text that is not a plain decimal is refused, an exponent and a float-looking value included" do
    %w[abc 1e3 1,250.40 12.5.0 0x10].each do |text|
      result = review(form(items: rows_with(item_form(@water, amount: text))))

      assert_not result.call, text
      water = result.form_receipt.items.find { |item| item.id == @water.id }
      assert_equal [ MoneyInput::MESSAGE ], water.errors[:amount], text
      assert_equal text, water.read_attribute_before_type_cast("amount"), text
    end
    assert_equal BigDecimal("60.00"), @water.reload.amount
  end

  test "an unreadable date and time is an error that keeps the typed value" do
    result = review(form(issued_at: "next tuesday"))

    assert_not result.call
    assert_equal [ "must be a date and time" ], result.form_receipt.errors[:issued_at]
    assert_equal "next tuesday", result.form_receipt.read_attribute_before_type_cast("issued_at")
  end

  test "a category chosen or changed by a person marks the item accepted_by_user; an untouched one keeps its flag" do
    params = form(items: rows_with(item_form(@sandwich, category_id: categories(:takeaway).id.to_s)))

    assert review(params).call

    assert @sandwich.reload.accepted_by_user
    assert_equal categories(:takeaway), @sandwich.category
    assert_not @water.reload.accepted_by_user, "the water's category did not change"
  end

  test "clearing a category clears the flag; a group is refused as a category" do
    @water.update!(accepted_by_user: true)

    assert review(form(items: rows_with(item_form(@water, category_id: "")))).call
    assert_nil @water.reload.category
    assert_not @water.accepted_by_user

    @receipt.reload
    result = review(form(items: rows_with(item_form(@water, category_id: categories(:groceries_group).id.to_s))))
    assert_not result.call
    assert_includes result.form_receipt.items.find { |item| item.id == @water.id }.errors[:category], "must be a category, not a group"
  end

  test "a new row is added after every item and every item of the OCR answer; a blank new row is left out" do
    @receipt.update_columns(ocr_raw: { "receipt" => { "items" => Array.new(5) { { "name" => "x" } } } })
    new_row = { name: "Chewing gum", quantity: "", unit_price: "", discount: "", amount: "12.00", category_id: categories(:groceries).id.to_s }
    blank = { name: "", quantity: "", unit_price: "", discount: "0", amount: "", category_id: "" }

    assert_difference -> { @receipt.items.count }, 1 do
      assert review(form(items: rows_with + [ new_row, blank ])).call
    end

    gum = @receipt.items.find_by!(name: "Chewing gum")
    assert_equal 6, gum.position
    assert_equal BigDecimal("0"), gum.discount
    assert gum.accepted_by_user
  end

  test "a row marked for removal is removed" do
    assert_difference -> { @receipt.items.count }, -1 do
      assert review(form(items: rows_with(item_form(@deposit, _destroy: "1")))).call
    end
    assert_not ReceiptItem.exists?(@deposit.id)
  end

  test "an invalid new row is an error on that row and nothing is saved" do
    new_row = { name: "", quantity: "0", unit_price: "", discount: "-1", amount: "5", category_id: "" }

    result = review(form(merchant_name: "Changed", items: rows_with + [ new_row ]))

    assert_not result.call
    row = result.form_receipt.items.find(&:new_record?)
    assert_includes row.errors[:name], "can't be blank"
    assert_includes row.errors[:discount], "must be greater than or equal to 0"
    assert_equal "Corner Shop", @receipt.reload.merchant_name
  end

  # --- Card slips -------------------------------------------------------------------------------------------

  test "a receipt with items becomes a card slip only with the confirmation, which removes its items" do
    result = review(form(kind: "card_slip", category_id: categories(:groceries).id.to_s))

    assert_not result.call
    assert_match "confirm removing the 3 item(s)", result.form_receipt.errors[:kind].first
    assert_equal 3, @receipt.items.count

    assert review(form(kind: "card_slip", category_id: categories(:groceries).id.to_s, remove_items: "1")).call
    assert_equal 0, @receipt.items.count
    assert @receipt.reload.card_slip?
    assert_equal categories(:groceries), @receipt.category
  end

  test "only a card slip keeps a category of its own" do
    @receipt.items.delete_all
    @receipt.update_columns(kind: "card_slip", category_id: categories(:groceries).id)

    assert review(form(@receipt.reload, kind: "fiscal")).call

    assert_nil @receipt.reload.category_id
  end

  # --- Stale forms and receipts that may not be edited -------------------------------------------------------

  test "a form rendered before another save is refused and nothing is written; the typed values stay" do
    stale = form(merchant_name: "Typed in an old tab", items: rows_with(item_form(@water, amount: "61.00")))
    assert review(form(merchant_name: "Saved in another tab")).call

    result = review(stale)

    assert_not result.call
    assert result.conflict?
    assert_equal "Saved in another tab", @receipt.reload.merchant_name
    assert_equal BigDecimal("60.00"), @water.reload.amount
    assert_equal "Typed in an old tab", result.form_receipt.merchant_name
    assert_equal "61.00", result.form_receipt.items.find { |item| item.id == @water.id }.read_attribute_before_type_cast("amount")
    assert_match "changed somewhere else", result.form_receipt.errors[:base].first
    assert_equal "0", result.version, "the page keeps the version it was rendered from"
  end

  test "a form rendered before OCR read the receipt again is refused, even though its items are gone" do
    stale = form(items: rows_with(item_form(@water, name: "Typed")))
    Receipts::ApplyOcr.call(Receipt.find(@receipt.id).tap { |receipt| receipt.update_columns(status: "processing") },
                            ml_ocr_result(receipt: { items: [ { name: "Tea", quantity: "1.000", unit_price: "10.00", amount: "10.00", discount: "0.00" } ] }))

    result = review(stale)

    assert_not result.call
    assert result.conflict?
    assert_equal [ "Tea" ], @receipt.reload.items.map(&:name)
    assert_equal "Typed", result.form_receipt.items.find { |item| item.id == @water.id }.name
  end

  test "nothing is saved while OCR is queued or running, and the typed values stay" do
    [ { ocr_requested_at: 1.minute.ago }, { status: "processing" } ].each do |state|
      @receipt.update_columns(state)
      result = review(form(merchant_name: "Typed"))

      assert_not result.call, state.inspect
      assert_match "OCR is reading this receipt again", result.form_receipt.errors[:base].first
      assert_equal "Typed", result.form_receipt.merchant_name
      assert_equal "Corner Shop", @receipt.reload.merchant_name
      @receipt.update_columns(ocr_requested_at: nil, status: "extracted")
    end
  end

  test "an accepted receipt is not changed by a plain save" do
    receipt = receipts(:market_receipt)
    params = form(receipt, merchant_name: "Changed", transaction_lock_version: "0")

    result = review(params, receipt:)

    assert_not result.call
    assert_match "Accept again", result.form_receipt.errors[:base].first
    assert_equal "Example Market", receipt.reload.merchant_name
  end

  test "an unreviewable status is refused" do
    receipt = receipts(:failed_receipt)

    assert_not review(form(receipt), receipt:).call
  end

  # --- Accept -----------------------------------------------------------------------------------------------

  test "accept saves the corrections and books them as one transaction" do
    params = form(account_id: accounts(:card_uah).id.to_s, items: rows_with(item_form(@sandwich, category_id: categories(:takeaway).id.to_s)))
    result = review(params, intent: "accept")

    assert_difference -> { Transaction.count }, 1 do
      assert result.call
    end

    transaction = result.transaction
    assert transaction.confirmed?
    assert_equal BigDecimal("-152.50"), transaction.amount
    assert_equal [ [ categories(:groceries).id, BigDecimal("-57.50") ], [ categories(:takeaway).id, BigDecimal("-95.00") ] ],
      transaction.lines.map { |line| [ line.category_id, line.amount ] }
    assert @receipt.reload.reviewed?
    assert_equal @receipt.lock_version.to_s, result.version
  end

  test "accept without an account changes nothing and asks for one" do
    result = review(form(merchant_name: "Typed"), intent: "accept")

    assert_no_difference -> { Transaction.count } do
      assert_not result.call
    end
    assert_equal [ "Not accepted: choose the account to book it on." ], result.form_receipt.errors[:account_id]
    assert_equal "Corner Shop", @receipt.reload.merchant_name, "a refused accept saves nothing"
    assert_equal "Typed", result.form_receipt.merchant_name
    assert_equal "0", result.version
  end

  test "accept again with items that no longer sum to the booked amount changes nothing and says why" do
    receipt = receipts(:market_receipt)
    soap = receipt_items(:market_soap)
    params = form(receipt, transaction_lock_version: "0",
                  items: form(receipt)[:items_attributes].values.map { |row| row[:id] == soap.id.to_s ? row.merge(amount: "200.00") : row })
    result = review(params, intent: "accept", receipt:)

    assert_not result.call

    assert_match "the items sum to 1200.4 but the transaction amount is -1250.4", result.form_receipt.errors[:base].first
    assert_equal BigDecimal("250.00"), soap.reload.amount
    assert_equal BigDecimal("-1250.40"), transactions(:market_split).reload.amount
    assert receipt.reload.reviewed?
    soap_row = result.form_receipt.items.find { |item| item.id == soap.id }
    assert_equal "200.00", soap_row.read_attribute_before_type_cast("amount")
    assert_not soap_row.new_record?
  end

  test "accept again books the corrected categories into the same transaction" do
    receipt = receipts(:market_receipt)
    soap = receipt_items(:market_soap)
    params = form(receipt, transaction_lock_version: "0",
                  items: form(receipt)[:items_attributes].values.map { |row| row[:id] == soap.id.to_s ? row.merge(category_id: categories(:groceries).id.to_s) : row })
    result = review(params, intent: "accept", receipt:)

    assert_no_difference -> { Transaction.count } do
      assert result.call
    end
    assert_equal transactions(:market_split), result.transaction
    assert_equal [ [ categories(:groceries).id, BigDecimal("-1250.40") ] ], result.transaction.lines.map { |line| [ line.category_id, line.amount ] }
  end

  test "accept again from a page rendered before the transaction changed is refused" do
    receipt = receipts(:market_receipt)
    params = form(receipt, transaction_lock_version: "0")
    transactions(:market_split).update!(comment: "Edited elsewhere")

    result = review(params, intent: "accept", receipt:)

    assert_not result.call
    assert result.conflict?
    assert_equal 1, transactions(:market_split).reload.lock_version
  end

  test "the same accept sent twice books once: the second form is stale" do
    params = form(account_id: accounts(:card_uah).id.to_s)

    assert_difference -> { Transaction.count }, 1 do
      assert review(params, intent: "accept").call
      assert_not review(params, intent: "accept").call
    end
  end

  test "a card slip is accepted from its total and its one category" do
    @receipt.items.delete_all
    @receipt.update_columns(kind: "card_slip")
    params = form(@receipt.reload, category_id: categories(:cafes).id.to_s, account_id: accounts(:card_uah).id.to_s)
    result = review(params, intent: "accept")

    assert result.call

    assert_equal [ [ categories(:cafes).id, BigDecimal("-152.50") ] ], result.transaction.lines.map { |line| [ line.category_id, line.amount ] }
    assert result.transaction.confirmed?
  end

  # --- Found in review ----------------------------------------------------------------------------------------

  test "a row removed before a refused accept stays removed on the form, so the next accept does not book it" do
    params = form(items: rows_with(item_form(@deposit, _destroy: "1")))
    result = review(params, intent: "accept")

    assert_not result.call

    assert ReceiptItem.exists?(@deposit.id), "the refusal saved nothing"
    deposit = result.form_receipt.items.find { |item| item.id == @deposit.id }
    assert deposit&.marked_for_destruction?, "the removed row is still on the form, marked for removal"
    assert_equal BigDecimal("155.00"), result.form_receipt.items_total

    accepted = review(params.merge(account_id: accounts(:card_uah).id.to_s), intent: "accept")
    assert accepted.call
    assert_equal BigDecimal("-155.00"), accepted.transaction.amount
    assert_not ReceiptItem.exists?(@deposit.id)
  end

  test "an accept the models refuse is a reason on the form, not an error page" do
    huge = (Transaction::AMOUNT_LIMIT - 1).to_s
    params = form(total: "", account_id: accounts(:card_uah).id.to_s,
                  items: [ item_form(@water, amount: huge), item_form(@sandwich, amount: huge), item_form(@deposit) ])
    result = review(params, intent: "accept")

    assert_no_difference -> { Transaction.count } do
      assert_not result.call
    end
    assert_match(/\ANot accepted: Amount must be greater than/, result.form_receipt.errors[:base].first)
    assert_equal BigDecimal("60.00"), @water.reload.amount
  end

  test "a save refreshes the receipt's other open pages and the list" do
    assert review(form(merchant_name: "Corner Shop 2")).call

    assert_turbo_stream_broadcasts @receipt, count: 1
    assert_turbo_stream_broadcasts Receipts::LiveUpdate::STREAM, count: 1
  end

  test "the conflict copy keeps each stored item's suggestion" do
    stale = form
    assert review(form(merchant_name: "Saved elsewhere")).call

    result = review(stale)

    assert_not result.call
    sandwich = result.form_receipt.items.find { |item| item.id == @sandwich.id }
    assert_equal [ categories(:takeaway).id, 0.62 ], [ sandwich.suggested_category_id, sandwich.confidence ]
  end
end

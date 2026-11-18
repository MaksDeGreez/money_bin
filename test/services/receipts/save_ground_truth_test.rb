require "test_helper"
require_relative "../../support/ml_service_stubs"

# "Save as ground truth" from the review form: Receipts::Review with intent "ground_truth", which saves the form
# and then writes the manual record through Receipts::SaveGroundTruth (docs/domain.md, "Manual ground truth").
class Receipts::SaveGroundTruthTest < ActiveSupport::TestCase
  include MlServiceStubs

  setup do
    @receipt = receipts(:corner_receipt)
    @water, @sandwich, @deposit = receipt_items(:corner_water, :corner_sandwich, :corner_deposit)
    # corner_receipt has a version 1 manual fixture; these tests start without it.
    receipt_ground_truths(:corner_manual).delete
  end

  # The review form's fields for `receipt` as the page renders them, with `changes` on top.
  def form(receipt = @receipt, items: nil, **changes)
    receipt = receipt.reload
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

  # Every item with a category: the sandwich has only a suggestion in the fixtures.
  def categorised_form(receipt = @receipt, **changes)
    rows = form(receipt)[:items_attributes].transform_values do |row|
      row[:id] == @sandwich.id.to_s ? row.merge(category_id: categories(:takeaway).id.to_s) : row
    end
    form(receipt, **changes).merge(items_attributes: rows)
  end

  def label(params = categorised_form, receipt: @receipt)
    review = Receipts::Review.new(Receipt.find(receipt.id), params, intent: "ground_truth")
    [ review.call, review ]
  end

  def record(receipt = @receipt)
    ReceiptGroundTruth.manual.find_by(receipt_id: receipt.id)
  end

  # --- Saving -------------------------------------------------------------------------------------------------

  test "saves the form and snapshots the receipt as stored: decimal strings, category slugs, Kyiv time" do
    saved, review = label(categorised_form(merchant_name: "Corner Shop No. 2", items: nil))
    assert saved
    assert_equal :created, review.ground_truth.status

    truth = record
    assert_equal "Corner Shop No. 2", @receipt.reload.merchant_name, "the form is saved as Save does"
    assert_equal 2, truth.schema_version
    assert truth.items_known
    assert truth.categories_known
    document = truth.document
    assert_equal({ "kind" => "fiscal", "merchant" => "Corner Shop No. 2", "fiscal_number" => nil, "receipt_number" => nil,
                   "issued_at" => "2026-10-08T12:05:00+03:00", "total" => "152.50", "currency" => "UAH", "card_last4" => nil,
                   "is_return" => nil, "category_slug" => nil }, document.except("items"))
    assert_equal [
      { "name" => "Sparkling water 1.5 l", "quantity" => "2.000", "unit_price" => "30.00", "amount" => "60.00",
        "discount" => "0.00", "category_slug" => "groceries/groceries" },
      { "name" => "Sandwich", "quantity" => "1.000", "unit_price" => "95.00", "amount" => "95.00", "discount" => "0.00",
        "category_slug" => "eating-out/takeaway-fast-food" },
      { "name" => "Bottle deposit returned", "quantity" => "1.000", "unit_price" => "-2.50", "amount" => "-2.50",
        "discount" => "0.00", "category_slug" => "groceries/groceries" }
    ], document["items"]
    JSON.generate(document).then { |json| assert_no_match(/":\s*-?\d/, json, "no JSON number holds money or a quantity") }
  end

  test "labelling never books and never moves the status" do
    transactions = Transaction.count
    lines = TransactionLine.count
    assert label.first
    assert @receipt.reload.extracted?
    assert_nil @receipt.transaction_id
    assert_equal [ transactions, lines ], [ Transaction.count, TransactionLine.count ]
  end

  test "Save and Accept never write ground truth" do
    assert Receipts::Review.new(Receipt.find(@receipt.id), categorised_form, intent: "save").call
    assert Receipts::Review.new(Receipt.find(@receipt.id), categorised_form.merge(account_id: accounts(:card_uah).id.to_s),
      intent: "accept").call
    assert_nil record
  end

  test "a value with more places than its column keeps is refused on the form, never rounded into the record" do
    params = categorised_form
    params[:items_attributes]["0"] = params[:items_attributes]["0"].merge(amount: "60.004")
    saved, review = label(params)
    assert_not saved
    assert_not_empty review.form_receipt.items.find { |item| item.id == @water.id }.errors[:amount]
    assert_nil record
  end

  test "a quantity keeps its three places" do
    @water.update!(quantity: BigDecimal("0.335"))
    assert label.first
    assert_equal "0.335", record.document["items"].first["quantity"]
  end

  # --- Completeness -------------------------------------------------------------------------------------------

  test "every item needs a category, unless the person saves without categories" do
    saved, review = label(form)
    assert_not saved
    sandwich = review.form_receipt.items.find { |item| item.id == @sandwich.id }
    assert_equal [ "must be chosen to save as ground truth" ], sandwich.errors[:category_id]
    assert_includes review.form_receipt.errors[:base], Receipts::Review::CATEGORIES_NEEDED
    assert_nil record
    assert_equal 0, @receipt.reload.lock_version, "nothing is saved"

    saved, _ = label(form.merge(without_categories: "1"))
    assert saved
    assert_not record.categories_known
    assert record.document["items"].all? { |item| item["category_slug"].nil? }, "the record carries none"
    assert_nil record.categories_prefilled_by
  end

  test "with every category chosen, 'without categories' still records them" do
    assert label(categorised_form(without_categories: "1")).first
    assert record.categories_known
  end

  test "a card slip needs its own category" do
    @receipt.items.delete_all
    params = form(kind: "card_slip", items: [])
    saved, review = label(params)
    assert_not saved
    assert_equal [ "must be chosen to save as ground truth" ], review.form_receipt.errors[:category_id]

    assert label(form(kind: "card_slip", items: [], category_id: categories(:cafes).id.to_s)).first
    assert_equal "eating-out/cafes-bars-restaurants", record.document["category_slug"]
    assert_equal [], record.document["items"]
  end

  test "the kind must be set, and a whole receipt needs its total and date; an incomplete one may lack them" do
    saved, review = label(categorised_form(kind: "", total: "", issued_at: ""))
    assert_not saved
    errors = review.form_receipt.errors
    assert_equal [ "must be set to save as ground truth" ], errors[:kind]
    assert_match(/is needed to save as ground truth/, errors[:total].first)
    assert_match(/is needed to save as ground truth/, errors[:issued_at].first)

    assert label(categorised_form(total: "", issued_at: "", incomplete: "1")).first
    assert_nil record.document["total"]
    assert_nil record.document["issued_at"]
  end

  test "a fiscal receipt needs its items; whether they sum to the total is not enforced" do
    saved, review = label(form(items: form[:items_attributes].values.map { |row| row.merge(_destroy: "1") }))
    assert_not saved
    assert_includes review.form_receipt.errors[:base], "A fiscal receipt needs its items to be saved as ground truth."

    assert label(categorised_form(total: "999.99")).first, "a rounding line can make the items differ from the total"
  end

  test "a stale form saves nothing and keeps the typed values" do
    Receipt.find(@receipt.id).update!(merchant_name: "Changed in another tab")
    saved, review = label(categorised_form(@receipt, lock_version: "0", merchant_name: "Typed"))
    assert_not saved
    assert review.conflict?
    assert_equal "Typed", review.form_receipt.merchant_name
    assert_nil record
  end

  # --- A booked receipt -------------------------------------------------------------------------------------

  test "a booked receipt is saved as ground truth as it is, without touching its transaction" do
    receipt = receipts(:market_receipt)
    transaction = receipt.ledger_transaction
    params = form(receipt).merge(transaction_lock_version: transaction.lock_version.to_s)
    before = [ receipt.lock_version, transaction.lock_version, transaction.lines.map(&:attributes) ]

    saved, review = label(params, receipt:)
    assert saved, review.form_receipt.errors.full_messages.to_sentence
    assert receipt.reload.reviewed?
    transaction.reload
    assert_equal before, [ receipt.lock_version, transaction.lock_version, transaction.lines.map(&:attributes) ]
    assert_equal 3, record(receipt).items.size
  end

  test "a booked receipt's empty fields, sent as empty text by the form, are no change" do
    receipt = receipts(:market_receipt)
    receipt.update_columns(receipt_number: nil, merchant_name: nil)
    params = form(receipt).merge(transaction_lock_version: receipt.ledger_transaction.lock_version.to_s)
    assert_equal "", params[:receipt_number]
    saved, review = label(params, receipt:)
    assert saved, review.form_receipt.errors.full_messages.to_sentence
    assert_nil record(receipt).document["receipt_number"]
  end

  test "a booked receipt with changes on the form is refused: that is Accept again" do
    receipt = receipts(:market_receipt)
    params = form(receipt, merchant_name: "Another").merge(transaction_lock_version: receipt.ledger_transaction.lock_version.to_s)
    saved, review = label(params, receipt:)
    assert_not saved
    assert_includes review.form_receipt.errors[:base], Receipts::Review::BOOKED_UNCHANGED
    assert_equal "Another", review.form_receipt.merchant_name, "the typed value stays on the form"
    assert_equal "Example Market", receipt.reload.merchant_name
    assert_nil record(receipt)
  end

  # --- The snapshot -------------------------------------------------------------------------------------------

  test "the record is a snapshot: later edits of the receipt, its items, the ledger and the taxonomy leave it alone" do
    assert label.first
    before = record.attributes

    assert Receipts::Review.new(Receipt.find(@receipt.id), categorised_form(merchant_name: "Edited", total: "1.00"), intent: "save").call
    assert_equal before, record.reload.attributes, "a later Save"

    @water.reload.update!(name: "Renamed", amount: BigDecimal("1.00"), category: categories(:cafes))
    @deposit.destroy!
    assert_equal before, record.reload.attributes, "an item edited or removed"

    categories(:groceries).update!(name: "Renamed groceries")
    assert_equal before, record.reload.attributes, "a category renamed (its slug stays)"

    transaction = Receipts::Accept.call(Receipt.find(@receipt.id), account: accounts(:card_uah))
    transaction.lines.first.update_columns(amount: transaction.lines.first.amount)
    transaction.destroy!
    assert_equal before, record.reload.attributes, "booking and unbooking"

    @receipt.reload.update_columns(status: "extracted")
    Receipts::ApplyOcr.call(Receipt.find(@receipt.id), ml_ocr_result(model_name: "another-model"))
    assert_equal before, record.reload.attributes, "a new OCR result"
  end

  # --- Replacing ----------------------------------------------------------------------------------------------

  test "saving again shows what changes and replaces only once confirmed; nothing is saved while it asks" do
    assert label.first
    first = record.attributes
    params = categorised_form(merchant_name: "Corner Shop Ltd")
    params[:items_attributes]["0"] = params[:items_attributes]["0"].merge(amount: "61.00")

    saved, review = label(params)
    assert_not saved
    assert review.confirmation_needed?
    result = review.ground_truth
    assert_equal [ "merchant" ], result.diff.fields
    assert_equal 1, result.diff.items_changed
    assert_equal first, record.reload.attributes, "the record is untouched"
    assert_equal "Corner Shop", @receipt.reload.merchant_name, "and the form is not saved either"
    assert_equal "Corner Shop Ltd", review.form_receipt.merchant_name, "the typed values stay"

    assert label(params.merge(replace_ground_truth: result.token)).first
    assert_equal "Corner Shop Ltd", record.reload.document["merchant"]
    assert_equal "61.00", record.document["items"].first["amount"]
  end

  test "a record that changed between the question and the confirmation asks again" do
    assert label.first
    params = categorised_form(merchant_name: "Other")
    saved, review = label(params)
    assert_not saved
    record.update!(document: record.document.merge("total" => "1.00"))

    saved, review = label(params.merge(replace_ground_truth: review.ground_truth.token))
    assert_not saved
    assert review.confirmation_needed?
    assert_equal "Corner Shop", record.reload.document["merchant"]
  end

  test "rows marked for removal stay marked across the question, and the confirmed save removes them" do
    assert label.first
    params = categorised_form
    params[:items_attributes]["2"] = params[:items_attributes]["2"].merge(_destroy: "1")
    saved, review = label(params)
    assert_not saved
    assert review.form_receipt.items.find { |item| item.id == @deposit.id }.marked_for_destruction?
    assert ReceiptItem.exists?(@deposit.id), "nothing was saved"

    assert label(params.merge(replace_ground_truth: review.ground_truth.token)).first
    assert_not ReceiptItem.exists?(@deposit.id)
    assert_equal 2, record.reload.items.size
  end

  test "a record the store refuses rolls the form save back too, with the reason on the form" do
    long = "x" * (ReceiptGroundTruth::Document::TEXT_LIMIT + 1)
    saved, review = label(categorised_form(merchant_name: long))
    assert_not saved
    assert_match(/\ANot saved as ground truth: Document merchant must be text or null/, review.form_receipt.errors[:base].first)
    assert_equal "Corner Shop", @receipt.reload.merchant_name
    assert_nil record
  end

  test "a confirmation is for the differences shown: a form changed again asks again" do
    assert label.first
    saved, review = label(categorised_form(merchant_name: "First"))
    assert_not saved
    token = review.ground_truth.token

    saved, review = label(categorised_form(merchant_name: "Second", replace_ground_truth: token))
    assert_not saved
    assert review.confirmation_needed?
    assert_equal "Corner Shop", record.reload.document["merchant"]
  end

  test "saving what the record already says writes nothing and asks nothing" do
    assert label.first
    before = record.attributes
    saved, review = label
    assert saved
    assert_equal :unchanged, review.ground_truth.status
    assert_equal before, record.reload.attributes
  end

  test "replacing a checked manual record clears the check" do
    assert label.first
    record.record_check!(matches: true)
    saved, review = label(categorised_form(merchant_name: "Other"))
    assert_not saved
    assert label(categorised_form(merchant_name: "Other", replace_ground_truth: review.ground_truth.token)).first
    assert_not record.reload.checked?
  end

  # --- prefilled_by -------------------------------------------------------------------------------------------

  test "a receipt OCR read is pre-filled by its model, version and prompt version" do
    receipt = receipts(:new_receipt)
    Receipts::ApplyOcr.call(receipt, ml_ocr_result(prompt_version: "p-1a2b"))
    params = form(receipt, items: receipt.items.map do |item|
      { id: item.id.to_s, name: item.name, quantity: item.quantity&.to_s("F"), unit_price: item.unit_price&.to_s("F"),
        discount: item.discount.to_s("F"), amount: item.amount.to_s("F"), category_id: categories(:groceries).id.to_s }
    end, kind: "fiscal")
    assert label(params, receipt:).first

    truth = record(receipt)
    assert_equal [ "stub-ocr", "0.1.0", "p-1a2b" ], [ truth.prefilled_by, truth.prefilled_model_version, truth.prefilled_prompt_version ]
    assert_not truth.independent_of?("stub-ocr")
  end

  test "a receipt entered by hand from nothing is pre-filled by nothing" do
    receipt = receipts(:new_receipt)
    Receipts::EnterByHand.call(receipt)
    params = form(receipt.reload, kind: "fiscal", merchant_name: "Typed", total: "10.00", issued_at: "2026-10-08T12:00",
      currency: "UAH", items: [ { name: "Typed item", amount: "10.00", discount: "0", category_id: categories(:groceries).id.to_s } ])
    assert label(params, receipt:).first

    truth = record(receipt)
    assert_equal ReceiptGroundTruth::PREFILLED_BY_HAND, truth.prefilled_by
    assert_nil truth.prefilled_model_version
    assert truth.independent_of?("stub-ocr")
  end

  test "a failed receipt entered by hand keeps the items of its earlier read, and their model" do
    Receipt.where(id: @receipt.id).update_all(status: "failed", ocr_raw: { "error" => { "code" => "ml_timeout", "message" => "x" } },
      ocr_prompt_version: "p-old")
    Receipts::EnterByHand.call(Receipt.find(@receipt.id))
    assert label.first
    assert_equal [ "stub-ocr", "p-old" ], [ record.prefilled_by, record.prefilled_prompt_version ]
  end

  test "a form filled from the tax-service record is pre-filled by that record, even after a plain save" do
    ReceiptGroundTruth.create!(receipt: @receipt, source: :dps_xml, schema_version: 2, items_known: true,
      source_sha256: "b" * 64, source_format: "dps_check01.v1",
      document: ReceiptGroundTruth::Document.blank.merge("kind" => "fiscal"))
    assert Receipts::Review.new(Receipt.find(@receipt.id), categorised_form(filled_from: "dps_xml"), intent: "save").call
    assert_equal "dps_xml", @receipt.reload.filled_from

    assert label.first, "the later ground-truth save does not carry the field: the receipt remembers it"
    assert_equal ReceiptGroundTruth::PREFILLED_BY_DPS_XML, record.prefilled_by
    assert_nil record.prefilled_model_version
  end

  test "filled_from is ignored without a tax-service record, and takes no other value" do
    assert label(categorised_form(filled_from: "dps_xml")).first
    assert_nil @receipt.reload.filled_from
    assert_equal "stub-ocr", record.prefilled_by

    assert_not Receipt.new(filled_from: "manual").tap(&:validate).errors[:filled_from].empty?
  end

  test "read again by another model after a person corrected it: the new answer pre-fills, the old record keeps its model" do
    assert label.first
    @receipt.update_columns(filled_from: "dps_xml", categoriser_model_name: "invented-categoriser")
    Receipts::ApplyOcr.call(Receipt.find(@receipt.id), ml_ocr_result(model_name: "model-b", model_version: "2.0", prompt_version: "p-b"))
    assert_equal "stub-ocr", record.reload.prefilled_by, "the snapshot keeps what filled it"

    receipt = @receipt.reload
    assert_nil receipt.filled_from, "the new answer replaced the fill"
    assert_nil receipt.categoriser_model_name, "and the items that carried the suggestions"
    assert_equal ReceiptGroundTruth::Prefill.new(by: "model-b", model_version: "2.0", prompt_version: "p-b"),
      ReceiptGroundTruth::Prefill.of(receipt)

    params = form(receipt, kind: "fiscal", items: receipt.items.map do |item|
      { id: item.id.to_s, name: item.name, quantity: item.quantity&.to_s("F"), unit_price: item.unit_price&.to_s("F"),
        discount: item.discount.to_s("F"), amount: item.amount.to_s("F"), category_id: categories(:groceries).id.to_s }
    end)
    saved, review = label(params)
    assert_not saved
    assert label(params.merge(replace_ground_truth: review.ground_truth.token)).first
    assert_equal [ "model-b", "2.0", "p-b" ], [ record.prefilled_by, record.prefilled_model_version, record.prefilled_prompt_version ]
  end

  test "an OCR answer that named no model is not taken for entering by hand" do
    @receipt.update_columns(ocr_model_name: "", ocr_raw: { "receipt" => { "items" => [] } })
    assert label.first
    assert_equal ReceiptGroundTruth::PREFILLED_BY_UNKNOWN_MODEL, record.prefilled_by
  end

  # --- categories_prefilled_by ------------------------------------------------------------------------------

  test "suggestions on the form name their categoriser, or an unknown one when the receipt does not say" do
    assert label.first
    assert_equal ReceiptGroundTruth::CATEGORISER_UNKNOWN, record.categories_prefilled_by, "the fixtures' items carry suggestions"

    record.destroy!
    @receipt.reload.update_columns(categoriser_model_name: "invented-categoriser")
    saved, review = label(categorised_form)
    assert saved
    assert_equal :created, review.ground_truth.status
    assert_equal "invented-categoriser", record.categories_prefilled_by
    assert_not record.categories_independent_of?("invented-categoriser")
  end

  test "no suggestion on the form: no categoriser" do
    ReceiptItem.where(receipt_id: @receipt.id).update_all(suggested_category_id: nil, confidence: nil)
    @receipt.update_columns(categoriser_model_name: "invented-categoriser")
    assert label.first
    assert_nil record.categories_prefilled_by
  end

  test "a review save keeps the categoriser; it is not a form field" do
    @receipt.update_columns(categoriser_model_name: "invented-categoriser")
    assert Receipts::Review.new(Receipt.find(@receipt.id), categorised_form(categoriser_model_name: "typed"), intent: "save").call
    assert_equal "invented-categoriser", @receipt.reload.categoriser_model_name
  end

  test "the snapshot refuses a value it would have to round" do
    error = assert_raises(ReceiptGroundTruth::Snapshot::Unrepresentable) { ReceiptGroundTruth::Snapshot.money(BigDecimal("60.005")) }
    assert_no_match(/60/, error.message, "it names no value")
  end
end

require "test_helper"

class ReceiptGroundTruthTest < ActiveSupport::TestCase
  DIGEST = "a" * 64

  def document(**overrides)
    receipt_ground_truths(:market_dps).document.deep_dup.merge(overrides.stringify_keys)
  end

  def item(**overrides)
    { "name" => "Invented tea", "quantity" => "1.000", "unit_price" => "10.00", "amount" => "10.00", "discount" => "0.00" }
      .merge(overrides.stringify_keys)
  end

  def build(**attributes)
    ReceiptGroundTruth.new(receipt: receipts(:new_receipt), source: :dps_xml, schema_version: 1, items_known: true,
      source_sha256: DIGEST, source_format: "dps_check01.v1", document: document, **attributes)
  end

  def document_errors(record)
    record.valid?
    record.errors[:document]
  end

  # Runs one statement that must break a constraint, in its own savepoint.
  def assert_constraint(name, &block)
    error = assert_raises(ActiveRecord::StatementInvalid) { ReceiptGroundTruth.transaction(requires_new: true, &block) }
    assert_includes error.message, name
  end

  test "the fixtures are valid and the receipt knows its records" do
    assert build.valid?
    assert_equal [ receipt_ground_truths(:market_dps) ], receipts(:market_receipt).ground_truths.to_a
    assert receipt_ground_truths(:market_dps).checked?
    assert_not receipt_ground_truths(:corner_manual).checked?
    assert_equal 3, receipt_ground_truths(:market_dps).items.size
  end

  test "money and quantities must be decimal strings: a float or any JSON number is refused" do
    assert_includes document_errors(build(document: document(total: 1250.4))), "total must be a decimal string with two places, or null"
    assert_includes document_errors(build(document: document(total: BigDecimal("1250.40")))), "total must be a decimal string with two places, or null"
    assert_not build(document: document(items: [ item(amount: 10.0) ])).valid?
    assert_not build(document: document(items: [ item(quantity: 1) ])).valid?
  end

  test "a value with more places than its column keeps is refused, never rounded" do
    assert_not build(document: document(total: "1250.405")).valid?
    assert_not build(document: document(total: "1250.4")).valid?, "one spelling per value: exactly two places"
    assert_not build(document: document(items: [ item(unit_price: "10.005") ])).valid?
    assert_not build(document: document(items: [ item(quantity: "0.0005") ])).valid?
    assert_not build(document: document(items: [ item(quantity: "0.000") ])).valid?, "a quantity is above zero"
    assert build(document: document(items: [ item(quantity: "0.125", amount: "-1.20") ])).valid?, "a deposit returned is negative"
  end

  test "the document has exactly the contract's keys" do
    missing = document.except("items")
    assert_includes document_errors(build(document: missing)), "misses items"
    assert_includes document_errors(build(document: document(cashier: "x"))), "has unknown keys (1)"
    assert_includes document_errors(build(document: document(items: [ item.except("discount") ]))), "item 1 misses discount"
    assert_includes document_errors(build(document: document(items: [ item(name: " ") ]))), "item 1 name must be text"
    assert_includes document_errors(build(document: document(items: [ item(discount: "-1.00") ]))),
      "item 1 discount must be a decimal string with two places, not negative, or null"
    assert_includes document_errors(build(document: "text")), "must be a JSON object"
  end

  test "the header fields are checked" do
    assert_not build(document: document(kind: "invoice")).valid?
    assert_not build(document: document(issued_at: "2026-10-03 18:40")).valid?
    assert_not build(document: document(issued_at: "2026-02-30T18:40:00+02:00")).valid?
    assert_not build(document: document(currency: "uah")).valid?
    assert_not build(document: document(card_last4: "42")).valid?
    assert_not build(document: document(is_return: "no")).valid?
    assert_not build(document: document(merchant: 12)).valid?
    assert build(document: ReceiptGroundTruth::Document.blank(1), items_known: false).valid?, "every value may be unknown"
  end

  test "no item lines from the source and a receipt without items are different facts" do
    assert build(document: document(items: []), items_known: false).valid?
    assert build(document: document(items: []), items_known: true).valid?
    assert_includes document_errors(build(items_known: false)), "items must be empty when the source gave no item lines"
  end

  test "an imported record keeps its file digest and format and has no prefill; a manual one has no file" do
    assert_not build(source_sha256: nil).valid?
    assert_not build(source_sha256: "ABC").valid?
    assert_not build(source_format: nil).valid?
    assert_not build(prefilled_by: "stub-ocr").valid?
    assert_not build(source: :manual).valid?, "a manual record has no file digest"
    assert build(source: :manual, source_sha256: nil, source_format: nil, prefilled_by: "stub-ocr").valid?
  end

  test "one record per receipt and source" do
    duplicate = build(receipt: receipts(:market_receipt))
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:source], "already has a ground-truth record for this receipt"
    assert build(receipt: receipts(:market_receipt), source: :manual, source_sha256: nil, source_format: nil, prefilled_by: "stub-ocr").valid?
  end

  test "a record pre-filled by a model is not test ground truth for that model" do
    manual = receipt_ground_truths(:corner_manual)
    assert_not manual.independent_of?("stub-ocr")
    assert manual.independent_of?("another-model")
    assert receipt_ground_truths(:market_dps).independent_of?("stub-ocr")
  end

  test "a person's check is recorded and can be cleared" do
    record = receipt_ground_truths(:corner_manual)
    at = Time.zone.parse("2026-10-09 09:00")
    record.record_check!(matches: false, note: " the total is smudged ", at:)
    record.reload
    assert record.checked?
    assert record.check_differs?
    assert_equal at, record.checked_at
    assert_equal "the total is smudged", record.check_note
    assert_includes ReceiptGroundTruth.checked, record

    record.record_check!(matches: true)
    assert record.reload.check_matches?
    assert_nil record.check_note

    record.clear_check!
    assert_not record.reload.checked?
    assert_nil record.check_outcome
    assert_includes ReceiptGroundTruth.unchecked, record
  end

  test "a check writes its own columns only: the time the content was saved stays" do
    record = receipt_ground_truths(:market_dps)
    saved = record.updated_at
    record.record_check!(matches: false, note: "x")
    assert_equal saved, record.reload.updated_at
    record.clear_check!
    assert_equal saved, record.reload.updated_at
    assert_raises(ActiveRecord::RecordInvalid) { record.record_check!(matches: true, note: "x", at: nil) }
  end

  test "a check needs both its time and its outcome" do
    assert_not build(checked_at: Time.current).valid?
    assert_not build(check_outcome: :matches).valid?
    assert_not build(check_note: "note").valid?
    assert_not build(checked_at: Time.current, check_outcome: "maybe").valid?
  end

  test "the database refuses what the model refuses" do
    id = receipt_ground_truths(:market_dps).id
    write = ->(attributes) { ReceiptGroundTruth.where(id:).update_all(attributes) }
    assert_constraint("receipt_ground_truths_source_allowed") { write.(source: "ocr") }
    assert_constraint("receipt_ground_truths_unknown_items_empty") { write.(items_known: false) }
    assert_constraint("receipt_ground_truths_document_shape") { write.(document: [ 1 ]) }
    assert_constraint("receipt_ground_truths_document_shape") { write.(document: { "items" => {} }) }
    assert_constraint("receipt_ground_truths_document_shape") { write.(document: {}, items_known: false) }
    assert_constraint("receipt_ground_truths_imported_fields") { write.(source_sha256: nil) }
    assert_constraint("receipt_ground_truths_imported_fields") { write.(prefilled_by: "stub-ocr") }
    assert_constraint("receipt_ground_truths_source_sha256_format") { write.(source_sha256: "x") }
    assert_constraint("receipt_ground_truths_check_consistent") { write.(check_outcome: nil) }
    assert_constraint("receipt_ground_truths_check_consistent") { write.(checked_at: nil, check_outcome: nil, check_note: "x") }
    assert_constraint("receipt_ground_truths_check_outcome_allowed") { write.(check_outcome: "maybe") }
    assert_constraint("receipt_ground_truths_schema_version_positive") { write.(schema_version: 0) }
    assert_constraint("receipt_ground_truths_manual_fields") do
      ReceiptGroundTruth.where(id: receipt_ground_truths(:corner_manual).id).update_all(source_sha256: DIGEST)
    end
    assert_constraint("index_receipt_ground_truths_on_receipt_id_and_source") do
      ReceiptGroundTruth.insert_all!([ ReceiptGroundTruth.find(id).attributes.except("id") ])
    end
  end

  test "editing the receipt, its items or its transaction never changes the ground truth" do
    record = receipt_ground_truths(:market_dps)
    before = record.attributes
    receipt = receipts(:market_receipt)

    receipt.update!(total: BigDecimal("1.00"), merchant_name: "Another name", kind: :card_slip, issued_at: Time.current)
    receipt.items.first.update!(name: "Renamed", amount: BigDecimal("1.00"))
    receipt.items.last.destroy!
    receipt.ledger_transaction.destroy!

    assert_equal before, record.reload.attributes
  end

  test "a deleted receipt takes its ground truth with it" do
    id = receipt_ground_truths(:corner_manual).id
    receipts(:corner_receipt).destroy!
    assert_not ReceiptGroundTruth.exists?(id)
  end

  # --- Schema version 2: categories -------------------------------------------------------------------------

  def v2_document(**overrides)
    ReceiptGroundTruth::Document.upgrade(document, 1).merge(overrides.stringify_keys)
  end

  def v2_item(**overrides)
    item(category_slug: "groceries/groceries", **overrides)
  end

  def manual(**attributes)
    ReceiptGroundTruth.new(receipt: receipts(:new_receipt), source: :manual, schema_version: 2, items_known: true,
      categories_known: true, prefilled_by: "stub-ocr", document: v2_document(items: [ v2_item ]), **attributes)
  end

  test "a version 1 record stays valid and reads as version 2 with no categories, the stored document untouched" do
    record = receipt_ground_truths(:market_dps)
    assert_equal 1, record.schema_version
    assert record.valid?
    upgraded = record.current_document
    assert_equal ReceiptGroundTruth::Document::KEYS.sort, upgraded.keys.sort
    assert_nil upgraded["category_slug"]
    assert upgraded["items"].all? { |row| row.key?("category_slug") && row["category_slug"].nil? }
    assert_empty ReceiptGroundTruth::Document.problems(upgraded, categories_known: false)
    assert_not record.document.key?("category_slug"), "reading never rewrites the stored document"
    assert_not record.document["items"].first.key?("category_slug")
    assert_not record.changed?
  end

  test "each schema version has its own keys, and an unknown version is refused" do
    assert_includes document_errors(build(document: v2_document)), "has unknown keys (1)", "version 1 has no category_slug"
    assert_includes document_errors(manual(document: document)), "misses category_slug"
    assert_not build(schema_version: 3).valid?
    assert_includes ReceiptGroundTruth::Document.problems(document, version: 3), "has an unknown schema version"
  end

  test "categories are category slugs: never a group, never a name" do
    assert manual.valid?
    assert_not manual(document: v2_document(items: [ v2_item(category_slug: "groceries") ])).valid?, "a group is not a category"
    assert_not manual(document: v2_document(items: [ v2_item(category_slug: "Groceries") ])).valid?
    assert_not manual(document: v2_document(items: [ v2_item(category_slug: 12) ])).valid?
    assert_not manual(document: v2_document(category_slug: "groceries/groceries", items: [ v2_item ])).valid?,
      "only a card slip has a category of its own"
    slip = v2_document(kind: "card_slip", category_slug: "eating-out/takeaway-fast-food", items: [])
    assert manual(document: slip).valid?
  end

  test "categories known means every one is given; not known means none is" do
    assert_includes document_errors(manual(document: v2_document(items: [ v2_item, v2_item(category_slug: nil) ]))),
      "categories are known, so every item needs one"
    assert_includes document_errors(manual(document: v2_document(kind: "card_slip", items: []))),
      "categories are known, so a card slip needs its category"
    assert_includes document_errors(manual(categories_known: false)), "categories are not known, so every category must be null"
    assert manual(categories_known: false, document: v2_document(items: [ v2_item(category_slug: nil) ])).valid?
    assert_includes document_errors(build(categories_known: true)), "categories cannot be known in schema version 1"
  end

  test "a manual record says what pre-filled it; an imported one has no categories and no pre-fill" do
    assert_not manual(prefilled_by: nil).valid?
    assert manual(prefilled_by: ReceiptGroundTruth::PREFILLED_BY_HAND).valid?
    assert manual(prefilled_by: ReceiptGroundTruth::PREFILLED_BY_DPS_XML).valid?
    assert_not manual(prefilled_by: "source:guess").valid?
    assert manual(categories_prefilled_by: ReceiptGroundTruth::CATEGORISER_UNKNOWN).valid?
    assert_not manual(categories_prefilled_by: "source:guess").valid?
    assert_not build(categories_prefilled_by: "a-categoriser").valid?
    assert_not build(prefilled_model_version: "1").valid?
    imported = build(schema_version: 2, document: v2_document, categories_known: true)
    assert_not imported.valid?
  end

  test "the pre-fill rule for categories" do
    assert manual.categories_independent_of?("tfidf-v1")
    assert_not manual(categories_prefilled_by: "tfidf-v1").categories_independent_of?("tfidf-v1")
    assert manual(categories_prefilled_by: "tfidf-v1").categories_independent_of?("another")
    unknown = manual(categories_prefilled_by: ReceiptGroundTruth::CATEGORISER_UNKNOWN)
    assert_not unknown.categories_independent_of?("tfidf-v1"), "not knowing whose suggestions they were excludes every categoriser"
    unknown_model = manual(prefilled_by: ReceiptGroundTruth::PREFILLED_BY_UNKNOWN_MODEL)
    assert unknown_model.valid?
    assert_not unknown_model.independent_of?("stub-ocr"), "an answer that named no model counts for none"
    assert_equal :model, manual.prefill_kind
    assert_equal :hand, manual(prefilled_by: ReceiptGroundTruth::PREFILLED_BY_HAND).prefill_kind
    assert_nil receipt_ground_truths(:market_dps).prefill_kind
  end

  test "the database refuses categories where the model does" do
    record = manual(receipt: receipts(:failed_receipt))
    record.save!
    write = ->(attributes) { ReceiptGroundTruth.where(id: record.id).update_all(attributes) }
    assert_constraint("receipt_ground_truths_unknown_categories_null") { write.(categories_known: false) }
    assert_constraint("receipt_ground_truths_categories_need_version_2") { write.(schema_version: 1) }
    assert_constraint("receipt_ground_truths_manual_fields") { write.(prefilled_by: nil) }
    dps = ReceiptGroundTruth.where(id: receipt_ground_truths(:market_dps).id)
    assert_constraint("receipt_ground_truths_imported_fields") { dps.update_all(categories_prefilled_by: "x") }
    assert_constraint("receipt_ground_truths_imported_fields") { dps.update_all(schema_version: 2, categories_known: true) }
  end

  test "decimal_string writes exact places and never rounds" do
    document = ReceiptGroundTruth::Document
    assert_equal "12.50", document.decimal_string(BigDecimal("12.5"), 2)
    assert_equal "-0.10", document.decimal_string(BigDecimal("-0.1"), 2)
    assert_equal "3.000", document.decimal_string(BigDecimal("3"), 3)
    assert_equal "10000000000.00", document.decimal_string(BigDecimal("1e10"), 2)
    assert_nil document.decimal_string(BigDecimal("12.345"), 2)
    assert_nil document.decimal_string(12.5, 2), "a float is never money"
    assert_nil document.decimal_string(BigDecimal("Infinity"), 2)
  end
end

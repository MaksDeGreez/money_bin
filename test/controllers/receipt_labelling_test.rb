require "test_helper"

# Labelling receipts in the app: "Save as ground truth" in the review form, the ground truth on a receipt
# page, the check of a tax-service record against the print, and finding work in the list (docs/domain.md,
# "Manual ground truth", "Checking an imported record").
class ReceiptLabellingTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in_as users(:owner)
    receipt_ground_truths(:corner_manual).delete
  end

  def corner
    receipts(:corner_receipt)
  end

  # The form as the page sends it, every item with a category.
  def review_params(receipt, **changes)
    items = receipt.items.each_with_index.to_h do |item, index|
      [ index.to_s, { id: item.id, name: item.name, quantity: item.quantity&.to_s("F"), unit_price: item.unit_price&.to_s("F"),
                      discount: item.discount.to_s("F"), amount: item.amount.to_s("F"),
                      category_id: (item.category_id || categories(:takeaway).id).to_s, _destroy: "0" } ]
    end
    { lock_version: receipt.reload.lock_version, kind: receipt.kind, merchant_name: receipt.merchant_name,
      issued_at: receipt.issued_at&.in_time_zone&.strftime("%Y-%m-%dT%H:%M:%S"), total: receipt.total&.to_s("F"),
      currency: receipt.currency, items_attributes: items }.merge(changes)
  end

  def manual_record(receipt = corner)
    ReceiptGroundTruth.manual.find_by(receipt_id: receipt.id)
  end

  def add_dps_record(receipt, **attributes)
    ReceiptGroundTruth.create!(receipt:, source: :dps_xml, schema_version: 2, items_known: true, source_sha256: "c" * 64,
      source_format: "dps_check01.v1", document: ReceiptGroundTruth::Document.blank.merge(
        "kind" => "fiscal", "merchant" => "Corner Shop", "issued_at" => "2026-10-08T12:05:00+03:00", "total" => "152.50",
        "currency" => "UAH",
        "items" => [ { "name" => "Sparkling water 1.5 l", "quantity" => "2.000", "unit_price" => "30.00", "amount" => "60.00",
                       "discount" => "0.00", "category_slug" => nil },
                     { "name" => "Sandwich with ham", "quantity" => "1.000", "unit_price" => "95.00", "amount" => "95.00",
                       "discount" => "0.00", "category_slug" => nil } ]), **attributes)
  end

  # --- The form ---------------------------------------------------------------------------------------------

  test "the form offers Save as ground truth with its shortcut and Save without categories" do
    get receipt_path(corner)

    assert_select "form##{dom_id(corner, :review_form)}" do
      assert_select "button[name=intent][value=ground_truth][data-form-guard-target=groundTruth]", text: /Save as ground truth/ do
        assert_select ".kbd", count: 3
      end
      assert_select "input[type=checkbox][name='receipt[without_categories]']"
      assert_select "input[type=hidden][name='receipt[filled_from]']"
    end
    assert_select "#ground-truth", text: /Not labelled yet/
  end

  test "Save as ground truth saves, labels, books nothing and offers the next receipt to label, focused" do
    receipts(:market_receipt).ground_truths.delete_all

    assert_no_difference -> { Transaction.count } do
      patch receipt_path(corner, batch: "october-shopping"), params: { intent: "ground_truth", receipt: review_params(corner) }
    end

    assert_redirected_to receipt_path(corner, batch: "october-shopping", labelled: 1)
    assert_equal "Saved as ground truth.", flash[:notice]
    assert corner.reload.extracted?
    assert_equal "stub-ocr", manual_record.prefilled_by

    follow_redirect!
    assert_select "a#next-to-label[autofocus][data-controller=autofocus][href=?]",
      receipt_path(receipts(:market_receipt), batch: "october-shopping"), text: /Next receipt to label/
    assert_select "[role=status]", text: /Labelled by hand in this list: 1 of 2 receipts, 3 items/
    assert_select "#ground-truth", text: /Pre-filled by\s+stub-ocr \(0.1.0\)/
    assert_select "button[name=intent][value=ground_truth]", text: /Save as ground truth again/
  end

  test "a gap keeps the typed values and marks the fields; nothing is saved" do
    params = review_params(corner, merchant_name: "Typed")
    params[:items_attributes]["1"][:category_id] = ""

    patch receipt_path(corner), params: { intent: "ground_truth", receipt: params }

    assert_response :unprocessable_content
    assert_select "input[name='receipt[merchant_name]'][value=?]", "Typed"
    assert_select "[role=alert]", text: /Every item needs a category/
    assert_select ".line-row-errors", text: /must be chosen to save as ground truth/
    assert_nil manual_record
    assert_equal "Corner Shop", corner.reload.merchant_name
  end

  test "the account chosen on the form stays chosen after Save as ground truth" do
    patch receipt_path(corner), params: { intent: "ground_truth", receipt: review_params(corner, account_id: accounts(:cash_uah).id) }
    assert_redirected_to receipt_path(corner, labelled: 1, account: accounts(:cash_uah).id)
    follow_redirect!
    assert_select "select#receipt_account_id option[selected][value=?]", accounts(:cash_uah).id.to_s
  end

  test "saving again shows a short summary of what changes and replaces only once confirmed" do
    patch receipt_path(corner), params: { intent: "ground_truth", receipt: review_params(corner) }
    params = review_params(corner, merchant_name: "Corner Shop Ltd")
    params[:items_attributes]["0"][:amount] = "61.00"

    patch receipt_path(corner), params: { intent: "ground_truth", receipt: params }

    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /already has ground truth/
    assert_select "[role=alert]", text: /What changes: 1 field \(merchant\); 1 item \(1 changed\)\./
    assert_select "button[data-form-guard-focus][name=intent][value=ground_truth]", text: /Replace the ground truth/
    token = css_select("input[name='receipt[replace_ground_truth]']").first["value"]
    assert_equal "Corner Shop", manual_record.document["merchant"]

    patch receipt_path(corner), params: { intent: "ground_truth", receipt: params.merge(replace_ground_truth: token) }
    assert_redirected_to receipt_path(corner, labelled: 1)
    assert_equal "Saved as ground truth: the earlier record is replaced.", flash[:notice]
    assert_equal "Corner Shop Ltd", manual_record.reload.document["merchant"]
  end

  # --- A tax-service record ---------------------------------------------------------------------------------

  test "a tax-service record can fill the form: the page carries its values in the form's formats" do
    add_dps_record(corner)
    get receipt_path(corner)

    form = css_select("form##{dom_id(corner, :review_form)}").first
    fill = JSON.parse(form["data-receipt-review-fill-value"])
    assert_equal({ "receipt_kind" => "fiscal", "receipt_merchant_name" => "Corner Shop", "receipt_issued_at" => "2026-10-08T12:05:00",
                   "receipt_total" => "152.50", "receipt_currency" => "UAH", "receipt_fiscal_number" => "",
                   "receipt_receipt_number" => "", "receipt_card_last4" => "" }, fill["fields"])
    assert_equal({ "name" => "Sandwich with ham", "quantity" => "1.000", "unit_price" => "95.00", "discount" => "0.00", "amount" => "95.00" },
      fill["items"].last)
    assert_equal "##{dom_id(corner, :items)}", form["data-receipt-review-line-items-outlet"]
    assert_select "button[data-action='receipt-review#fillFromRecord']", text: /Fill the form from the tax-service record/
  end

  test "the page compares a tax-service record with the receipt and marks the differences" do
    add_dps_record(corner)
    get receipt_path(corner)

    assert_select "#ground-truth" do
      assert_select "tr", text: /Sandwich with ham.*Differs: name/m
      assert_select "tr.data-grid-sub", text: /Sandwich/
      assert_select "tr", text: /Only on the receipt/
      assert_select "tr", text: /Total\s*152.50\s*152.50/ do
        assert_select ".badge", count: 0
      end
      assert_select "button[name=outcome][value=matches]", text: /Matches the print/
      assert_select "button[name=outcome][value=differs]", text: /Differs from the print/
    end
  end

  def check(record, outcome, note: nil, receipt: corner, **query)
    post receipt_ground_truth_check_path(receipt, **query),
      params: { outcome:, ground_truth_check: { version: record&.content_version, note: } }
  end

  test "a tax-service record is checked against the print, checked again, and forgotten" do
    record = add_dps_record(corner)
    get receipt_path(corner)
    assert_select "input[name='ground_truth_check[version]'][value=?]", record.content_version

    check(record, "differs", note: " the second line is smudged ", truth: "dps_xml")
    assert_redirected_to receipt_path(corner, truth: "dps_xml", anchor: "ground-truth")
    record.reload
    assert record.check_differs?
    assert_equal "the second line is smudged", record.check_note

    check(record, "matches")
    assert record.reload.check_matches?
    assert_nil record.check_note
    follow_redirect!
    assert_select "#ground-truth", text: /Matches the print, checked/

    delete receipt_ground_truth_check_path(corner)
    assert_not record.reload.checked?
  end

  test "a check never touches the record's document, the receipt or its items" do
    record = add_dps_record(corner)
    before = [ record.document, corner.attributes.except("updated_at"), corner.items.map(&:attributes) ]
    check(record, "matches")
    assert_equal before, [ record.reload.document, corner.reload.attributes.except("updated_at"), corner.items.map(&:attributes) ]
  end

  test "a check needs an outcome and a tax-service record" do
    record = add_dps_record(corner)
    check(record, "maybe")
    assert_match(/Not recorded/, flash[:alert])
    assert_not record.reload.checked?

    check(record, "matches", receipt: receipts(:new_receipt))
    assert_equal "This receipt has no tax-service record to check.", flash[:alert]
  end

  test "a check is about the content the page showed: a record replaced since is not checked" do
    record = add_dps_record(corner)
    shown = record.content_version
    record.update!(document: record.document.merge("total" => "999.00"), source_sha256: "d" * 64)

    post receipt_ground_truth_check_path(corner), params: { outcome: "matches", ground_truth_check: { version: shown } }

    assert_match(/changed after this page was opened/, flash[:alert])
    assert_not record.reload.checked?
  end

  test "checks need a signed-in session" do
    record = add_dps_record(corner)
    sign_out
    check(record, "matches")
    assert_redirected_to new_session_path
    patch receipt_path(corner), params: { intent: "ground_truth", receipt: review_params(corner) }
    assert_redirected_to new_session_path
    assert_not record.reload.checked?
    assert_nil manual_record
  end

  test "a receipt shown read-only shows its ground truth too" do
    record = add_dps_record(receipts(:failed_receipt).tap { |receipt| receipt.update_columns(ingest_id: "rcpt_000042") })
    get receipt_path(receipts(:failed_receipt))
    assert_select "#ground-truth", text: /Not checked against the print yet/
    assert record
  end

  # --- The list ---------------------------------------------------------------------------------------------

  test "the list filters by ground truth, counts each choice, shows the progress and marks each row" do
    patch receipt_path(corner), params: { intent: "ground_truth", receipt: review_params(corner) }

    get receipts_path(truth: "manual")

    assert_select "select[name=truth] option[selected][value=manual]", text: "Labelled by hand (1)"
    assert_select "select[name=truth] option[value=none]", text: "No ground truth (2)"
    assert_select "select[name=check] option[value=checked]", text: "Checked against the print (0)"
    assert_select "[role=status]", text: /Labelled by hand: 1 of 4 receipts in this list, 3 items/
    assert_select "tbody tr", count: 1
    assert_select "tr##{dom_id(corner)} .badge", text: "By hand"
    assert_select "tr##{dom_id(corner)} a[href=?]", receipt_path(corner, truth: "manual")

    get receipts_path
    assert_select "tr##{dom_id(receipts(:market_receipt))} .badge[title=?]", "Tax-service record, checked: matches the print"
  end
end

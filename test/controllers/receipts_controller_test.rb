require "test_helper"
require_relative "../support/receipt_images"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionView::RecordIdentifier
  include ReceiptImages

  setup { sign_in_as users(:owner) }

  def ocr_jobs
    enqueued_jobs.select { |job| job["job_class"] == "ReceiptOcrJob" }
  end

  def photo_file(red: 10, name: "receipt.png", type: "image/png", bytes: nil)
    file = Tempfile.new([ "receipt", File.extname(name) ])
    file.binmode
    file.write(bytes || png_bytes(red:))
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, true, original_filename: name)
  end

  # --- Sign-in --------------------------------------------------------------------------------------------

  test "every receipt page needs a signed-in session" do
    sign_out

    get receipts_path
    assert_redirected_to new_session_path
    get receipt_path(receipts(:new_receipt))
    assert_redirected_to new_session_path
    get new_receipt_path
    assert_redirected_to new_session_path

    assert_no_difference -> { Receipt.count } do
      post receipts_path, params: { receipt: { images: [ photo_file ] } }
    end
    post read_receipt_path(receipts(:failed_receipt))
    post read_all_receipts_path
    assert_empty ocr_jobs
    assert_nil receipts(:failed_receipt).reload.ocr_requested_at
  end

  test "the main navigation links to the receipts" do
    get root_path

    assert_select "nav[aria-label=Main] a[href=?]", receipts_path, text: "Receipts"
  end

  # --- Index ----------------------------------------------------------------------------------------------

  test "the list shows every receipt with its row details and the counts per status" do
    get receipts_path

    assert_response :success
    assert_select "tbody tr", Receipt.count
    assert_select "tr##{dom_id(receipts(:market_receipt))}" do
      assert_select "a.data-grid-link", text: "rcpt_000041"
      assert_select "img.photo-thumb[src=?]", receipt_photo_path(receipts(:market_receipt), active_storage_attachments(:market_photo), :thumb)
      assert_select "td", text: "Accepted"
      assert_select "td", text: "Fiscal receipt"
      assert_select ".badge", text: "QR"
      assert_select "td", text: "Example Market"
      assert_select "td", text: "2026-10-03 18:40"
      assert_select "td.data-grid-num", text: "1 250.40 UAH"
      assert_select "td.data-grid-num", text: "3"
      assert_select "td a[title=?]", "Transaction ##{transactions(:market_split).id}"
    end
    assert_select "nav.count-tabs a", text: /Not read yet\s*1/
    assert_select "nav.count-tabs a", text: /OCR failed\s*1/
    assert_select "nav.count-tabs a[aria-current=page]", text: /All\s*4/
    assert_select "[data-controller=live-refresh][data-live-refresh-pending-value=false] turbo-cable-stream-source"
    assert_select "[data-turbo-prefetch=false] a[href^='/receipts/']"
  end

  test "the list is newest first: uploaded in the app by upload time, then by ingest number, highest first" do
    receipts(:new_receipt).update_columns(created_at: 2.days.ago)
    receipts(:corner_receipt).update_columns(created_at: 1.day.ago)

    get receipts_path

    expected = [ receipts(:corner_receipt), receipts(:new_receipt), receipts(:failed_receipt), receipts(:market_receipt) ]
    assert_equal expected.map { |receipt| dom_id(receipt) }, css_select("tbody tr").map { |row| row["id"] }
  end

  test "the filters keep their state in the URL, in the form, the links and the counts" do
    receipts(:corner_receipt).update_columns(kind: "card_slip")
    get receipts_path(batch: "october-shopping", kind: "card_slip")

    assert_select "tbody tr", 1
    assert_select "tr##{dom_id(receipts(:corner_receipt))}"
    assert_select "select[name=batch] option[selected][value=?]", "october-shopping"
    assert_select "select[name=kind] option[selected][value=?]", "card_slip"
    assert_select "tr##{dom_id(receipts(:corner_receipt))} a.data-grid-link[href=?]",
      receipt_path(receipts(:corner_receipt), batch: "october-shopping", kind: "card_slip")
    assert_select "nav.count-tabs a[href=?]", receipts_path(batch: "october-shopping", kind: "card_slip", status: "extracted"),
      text: /Read, to review\s*1/
    assert_select "nav.count-tabs a", text: /Accepted\s*0/
    assert_select "form[role=search] input[name=commit]", false, "the submit button must not add itself to the URL"
  end

  test "each filter narrows the list" do
    {
      { status: "failed" } => [ :failed_receipt ],
      { kind: "fiscal" } => [ :market_receipt, :corner_receipt ],
      { kind: "unknown" } => [ :new_receipt, :failed_receipt ],
      { qr: "with" } => [ :market_receipt, :failed_receipt ],
      { qr: "without" } => [ :corner_receipt, :new_receipt ],
      { batch: "november-shopping" } => [ :failed_receipt ]
    }.each do |filter, names|
      get receipts_path(filter)
      shown = css_select("tbody tr").map { |row| row["id"] }
      assert_equal names.map { |name| dom_id(receipts(name)) }.sort, shown.sort, filter.inspect
    end

    receipts(:corner_receipt).update_columns(incomplete: true)
    get receipts_path(incomplete: "1")
    assert_equal [ dom_id(receipts(:corner_receipt)) ], css_select("tbody tr").map { |row| row["id"] }
    assert_select "input[type=checkbox][name=incomplete][checked]"
  end

  test "an unknown filter value is ignored instead of failing" do
    get receipts_path(status: "lost", kind: "napkin", qr: "maybe", page: "x")

    assert_response :success
    assert_select "tbody tr", Receipt.count

    get "/receipts?page[]=2&status[]=failed"
    assert_response :success
  end

  test "an empty filter says so and links to the whole list" do
    get receipts_path(batch: "no-such-batch")

    assert_select ".callout", text: /No receipt matches this filter/
    assert_select ".callout a[href=?]", receipts_path
  end

  test "the list is paginated and the page links keep the filter" do
    with_per_page(2) do
      get receipts_path(qr: "without")
      assert_select "tbody tr", 2
      assert_select "nav.pagination", false

      get receipts_path
      assert_select "tbody tr", 2
      assert_select "nav.pagination a[rel=next][href=?]", receipts_path(page: 2)

      get receipts_path(page: 2, kind: "unknown", qr: "with")
      assert_select "tbody tr", 1, "a page past the end shows the last page"
    end
  end

  test "'Read all in this filter' shows how many receipts it would queue" do
    get receipts_path

    assert_select "form[action=?]", read_all_receipts_path do |form|
      assert_match(/Queue 2 receipts for OCR/, form.first["data-turbo-confirm"])
      assert_match(/one receipt at a time/, form.first["data-turbo-confirm"])
    end
    assert_select "button", text: /Read all in this filter \(2\)/

    get receipts_path(status: "extracted")
    assert_select "form[action^=?]", read_all_receipts_path, false
  end

  # --- Receipt page ---------------------------------------------------------------------------------------

  test "a receipt page shows its photos and, for an accepted receipt, the review form with Accept again" do
    receipt = receipts(:market_receipt)

    get receipt_path(receipt)

    assert_response :success
    assert_select "h1", "rcpt_000041"
    photo = active_storage_attachments(:market_photo)
    assert_select ".review-photos a.photo-frame[href=?][target=_blank]", receipt_photo_path(receipt, photo, :full) do
      assert_select "img[src=?][alt=?]", receipt_photo_path(receipt, photo, :page), "Photo 1 of 1 of rcpt_000041"
    end
    assert_select "##{dom_id(receipt, :status)}", text: "Accepted"
    assert_select "##{dom_id(receipt, :data)} form##{dom_id(receipt, :review_form)}[action=?]", receipt_path(receipt) do
      assert_select "input[name='receipt[merchant_name]'][value=?]", "Example Market"
      assert_select "input[name='receipt[fiscal_number]'][value=?]", "4000000001"
      assert_select "input[name='receipt[lock_version]'][value=?]", "0"
      assert_select "input[name='receipt[transaction_lock_version]'][value=?]", "0"
      assert_select "input[name='receipt[items_attributes][1][name]'][value=?]", "Hard cheese 1 kg"
      assert_select "input[name='receipt[items_attributes][1][quantity]'][value=?]", "1"
      assert_select "input[name='receipt[items_attributes][1][unit_price]'][value=?]", "1010.00"
      assert_select "input[name='receipt[items_attributes][1][discount]'][value=?]", "50.00"
      assert_select "input[name='receipt[items_attributes][1][amount]'][value=?]", "960.00"
      assert_select "select[name='receipt[items_attributes][1][category_id]'] option[selected][value=?]", categories(:groceries).id.to_s
      assert_select "[data-money-totals-target=sum]", "1 250.40 UAH"
      assert_select "[data-money-totals-target=difference]", "0.00 UAH"
      assert_select ".badge", text: "Match", count: 4
      assert_select "button[name=intent][value=accept]", text: /Accept again/
      assert_select "button[name=intent][value=save]", false, "an accepted receipt changes only by accepting it again"
      assert_select "a[href=?]", transaction_path(transactions(:market_split)), text: /transaction #/
    end
    assert_select "[data-controller=live-refresh] turbo-cable-stream-source"
  end

  test "a receipt page shows suggestions with their confidence and the QR values next to their fields" do
    receipt = receipts(:corner_receipt)
    receipt.update_columns(qr_total: BigDecimal("150.00"), qr_issued_at: receipt.issued_at + 30.seconds)

    get receipt_path(receipt)

    assert_select "[data-suggestion-id=?][data-suggestion-confidence=?]", categories(:takeaway).id.to_s, "0.62" do
      assert_select "input[value=?]", "Sandwich"
      assert_select ".line-suggestion", text: /Suggested: Takeaway & fast food · 62%/
      assert_select ".combobox[data-combobox-suggestion-value=?]", categories(:takeaway).id.to_s
    end
    assert_select "[data-money-totals-target=difference]", "0.00 UAH"
    assert_select ".field", text: /Total.*QR code:\s*150.00 UAH.*Mismatch.*Use the QR value/m do
      assert_select "button[data-qr-value=?][data-qr-field=?]", "150.00", "receipt_total"
    end
    assert_select ".field", text: /Date and time.*QR code:\s*2026-10-08 12:05.*Match/m
    assert_select ".field", text: /Fiscal number.*QR code/m, count: 0
    assert_select "button[name=intent][value=save]", text: /Save/
    assert_select "button[name=intent][value=accept]", text: /\AAccept/
  end

  test "the items' gap to the printed total is shown with its sign" do
    receipt = receipts(:corner_receipt)
    receipt.update_columns(total: BigDecimal("160.00"))

    get receipt_path(receipt)

    assert_select "[data-money-totals-target=difference]", "7.50 UAH"
    assert_select "[data-money-totals-target=total]", "160.00 UAH"
  end

  test "a receipt being read again shows its stored data read-only, without the form" do
    receipt = receipts(:corner_receipt)
    receipt.update_columns(ocr_requested_at: 1.minute.ago)

    get receipt_path(receipt)

    assert_select "form##{dom_id(receipt, :review_form)}", false
    assert_select "##{dom_id(receipt, :data)}" do
      assert_select ".data-row", text: /Merchant\s*Corner Shop/
      assert_select "tbody tr", text: /Sandwich.*Suggested: Takeaway & fast food\s*\(62%\)/m
      assert_select ".data-row", text: /Items sum\s*152.50 UAH/
    end
  end

  test "a failed receipt shows the stored failure and offers to read it again" do
    receipt = receipts(:failed_receipt)

    get receipt_path(receipt)

    assert_select ".callout-danger", text: /OCR failed.*The file is not a supported image.*unsupported_media_type/m
    assert_select "form[action=?]:not([data-turbo-confirm])", read_receipt_path(receipt), text: /Read again/
    assert_empty ocr_jobs, "opening a failed receipt does not queue it"
  end

  test "a failed receipt with items from an earlier read asks before reading it again" do
    receipt = receipts(:failed_receipt)
    receipt.items.create!(position: 1, name: "Bread", amount: BigDecimal("30.00"))

    get receipt_path(receipt)

    assert_select "form[action=?][data-turbo-confirm*=?]", read_receipt_path(receipt), "earlier read"
  end

  test "a lost request (older than a day) offers 'Read again' once more; a waiting one does not" do
    receipt = receipts(:failed_receipt)
    receipt.update_columns(ocr_requested_at: 2.hours.ago)
    get receipt_path(receipt)
    assert_select "form[action=?]", read_receipt_path(receipt), false
    assert_select ".callout-danger", text: /Queued to read again/

    receipt.update_columns(ocr_requested_at: (Receipt::OCR_REQUEST_LOST_AFTER + 1.hour).ago)
    get receipt_path(receipt)
    assert_select "form[action=?]", read_receipt_path(receipt)
  end

  test "a receipt stuck in processing says so and offers 'Read again'" do
    receipt = receipts(:failed_receipt)
    receipt.update_columns(status: "processing", updated_at: 2.hours.ago)

    get receipt_path(receipt)

    assert_select ".callout-signal", text: /may have been lost/
    assert_select "form[action=?]", read_receipt_path(receipt)
    post read_receipt_path(receipt)
    assert_equal 1, ocr_jobs.size
  end

  test "an extracted receipt offers to read it again behind a confirmation; a reviewed one does not" do
    get receipt_path(receipts(:corner_receipt))
    assert_select "form[action=?][data-turbo-confirm*=?]", read_receipt_path(receipts(:corner_receipt)), "replaced"

    get receipt_path(receipts(:market_receipt))
    assert_select "form[action=?]", read_receipt_path(receipts(:market_receipt)), false
    assert_empty ocr_jobs
  end

  test "previous and next walk the filtered list and keep the filter" do
    filter = { qr: "without" } # corner_receipt and new_receipt
    receipts(:new_receipt).update_columns(created_at: 1.day.ago)

    get receipt_path(receipts(:corner_receipt), filter)
    assert_select "a[rel=prev]", false
    assert_select "a[rel=next][href=?]", receipt_path(receipts(:new_receipt), filter)
    assert_select "a[href=?]", receipts_path(filter), text: /Back to the list/

    get receipt_path(receipts(:new_receipt), filter)
    assert_select "a[rel=prev][href=?]", receipt_path(receipts(:corner_receipt), filter)
    assert_select "a[rel=next]", false
  end

  test "a receipt outside the filter shows no previous or next link" do
    get receipt_path(receipts(:market_receipt), status: "failed")

    assert_response :success
    assert_select "a[rel=prev], a[rel=next]", false
  end

  test "a missing receipt is a 404" do
    get receipt_path(id: 0)

    assert_response :not_found
  end

  # --- OCR on opening -------------------------------------------------------------------------------------

  test "opening an unread receipt queues OCR once, however often it is opened" do
    receipt = receipts(:new_receipt)

    get receipt_path(receipt)
    get receipt_path(receipt)
    get receipt_path(receipt)

    assert_equal 1, ocr_jobs.size
    assert_equal receipt.to_global_id.to_s, ocr_jobs.sole["arguments"].first["_aj_globalid"]
    assert receipt.reload.ocr_pending?
    assert_select ".callout", text: /Queued for OCR at/
    assert_select "[data-controller=live-refresh][data-live-refresh-pending-value=true]", 1,
      "a page waiting for OCR asks again when its stream (re)connects"
  end

  test "a prefetch or a HEAD request does not queue OCR" do
    receipt = receipts(:new_receipt)

    get receipt_path(receipt), headers: { "X-Sec-Purpose" => "prefetch" }
    get receipt_path(receipt), headers: { "Sec-Purpose" => "prefetch;prerender" }
    head receipt_path(receipt)

    assert_empty ocr_jobs
    assert_nil receipt.reload.ocr_requested_at
  end

  test "opening a receipt that is read, being read or accepted queues nothing" do
    receipts(:new_receipt).update_columns(status: "processing")

    %i[new_receipt corner_receipt market_receipt failed_receipt].each { |name| get receipt_path(receipts(name)) }

    assert_empty ocr_jobs
  end

  test "when the queue cannot be reached the page says so and the receipt is not marked queued" do
    receipt = receipts(:new_receipt)

    with_singleton_method(ReceiptOcrJob.queue_adapter, :enqueue, ->(*) { raise RedisClient::CannotConnectError, "down" }) do
      get receipt_path(receipt)
    end

    assert_response :success
    assert_select ".callout-danger", text: /OCR could not be queued/
    assert_nil receipt.reload.ocr_requested_at
    assert_select ".callout", text: /Not read yet, and not queued/
  end

  test "when the queue goes away during 'Read all' the notice says how many were queued" do
    receipts(:new_receipt).update_columns(created_at: 1.day.ago)
    pushes = 0
    flaky = lambda do |job|
      pushes += 1
      raise RedisClient::CannotConnectError, "down" if pushes > 1

      enqueued_jobs << { "job_class" => job.class.name, "arguments" => job.serialize["arguments"] }
    end

    with_singleton_method(ReceiptOcrJob.queue_adapter, :enqueue, flaky) { post read_all_receipts_path }

    assert_match(/OCR could not be queued.*1 receipt were queued before it stopped/, flash[:alert])
  end

  # --- Read again -----------------------------------------------------------------------------------------

  test "'Read again' queues a failed receipt once and returns to the page it came from" do
    receipt = receipts(:failed_receipt)
    from = receipt_url(receipt, status: "failed")

    post read_receipt_path(receipt), headers: { "Referer" => from }
    assert_redirected_to from
    post read_receipt_path(receipt), headers: { "Referer" => from }

    assert_equal 1, ocr_jobs.size
    assert_match(/already queued/, flash[:alert])
  end

  test "'Read again' queues an extracted receipt" do
    post read_receipt_path(receipts(:corner_receipt))

    assert_redirected_to receipt_path(receipts(:corner_receipt))
    assert_equal 1, ocr_jobs.size
    assert receipts(:corner_receipt).reload.ocr_pending?
  end

  test "'Read again' never queues a reviewed receipt" do
    post read_receipt_path(receipts(:market_receipt))

    assert_empty ocr_jobs
    assert_nil receipts(:market_receipt).reload.ocr_requested_at
    assert_match(/accepted into the ledger/, flash[:alert])
  end

  test "'Read again' does not queue a receipt that is being read or not read yet" do
    receipts(:failed_receipt).update_columns(status: "processing", updated_at: Time.current)

    post read_receipt_path(receipts(:failed_receipt))
    post read_receipt_path(receipts(:new_receipt))

    assert_empty ocr_jobs
  end

  test "a redirect never leaves the app, whatever the referrer says" do
    post read_receipt_path(receipts(:failed_receipt)), headers: { "Referer" => "https://example.com/elsewhere" }

    assert_redirected_to receipt_path(receipts(:failed_receipt))
  end

  # --- Read all -------------------------------------------------------------------------------------------

  test "'Read all' queues the unread and failed receipts of the filter, once, and keeps the filter" do
    post read_all_receipts_path(qr: "with")

    assert_redirected_to receipts_path(qr: "with")
    assert_equal [ receipts(:failed_receipt).to_global_id.to_s ], ocr_jobs.map { |job| job["arguments"].first["_aj_globalid"] }
    assert_match(/Queued 1 receipt for OCR.*one receipt at a time/, flash[:notice])

    post read_all_receipts_path
    assert_equal 2, ocr_jobs.size, "the failed receipt is already queued; only the unread one is added"

    post read_all_receipts_path
    assert_equal 2, ocr_jobs.size
    assert_match(/Nothing to queue/, flash[:alert])

    get receipts_path
    assert_select "[data-controller=live-refresh][data-live-refresh-pending-value=true]"
  end

  test "'Read all' never queues an extracted or a reviewed receipt" do
    post read_all_receipts_path(batch: "october-shopping")

    assert_empty ocr_jobs
  end

  # --- Upload ---------------------------------------------------------------------------------------------

  test "the upload page has a form for one to three photos and a batch" do
    get new_receipt_path

    assert_response :success
    assert_select "form[action=?][enctype='multipart/form-data']", receipts_path do
      assert_select "input[type=file][name='receipt[images][]'][multiple][accept*='image/heic']"
      assert_select "input[name='receipt[batch]']"
    end
  end

  test "an upload stores the receipt, queues OCR once and opens the receipt page" do
    assert_difference -> { Receipt.count } do
      post receipts_path, params: { receipt: { images: [ photo_file(red: 1), photo_file(red: 2) ], batch: " november " } }
    end

    receipt = Receipt.order(:id).last
    assert_redirected_to receipt_path(receipt)
    assert_equal "november", receipt.batch
    assert_equal 2, receipt.images.count
    assert receipt.uploaded?
    assert_equal 1, ocr_jobs.size

    follow_redirect!
    assert_equal 1, ocr_jobs.size, "opening the page right after does not queue it again"
  end

  test "an upload that breaks a rule shows the model's errors on the form" do
    assert_no_difference -> { Receipt.count } do
      post receipts_path, params: { receipt: { images: [ photo_file(name: "notes.txt", type: "text/plain", bytes: "hello") ] } }
    end
    assert_response :unprocessable_content
    assert_select ".field-error", text: /must be photos/
    assert_select "input[type=file][aria-invalid=true]"

    post receipts_path, params: { receipt: { images: (1..4).map { |red| photo_file(red:) } } }
    assert_response :unprocessable_content
    assert_select ".field-error", text: /between 1 and 3 photos/

    post receipts_path, params: { receipt: { batch: "x" } }
    assert_response :unprocessable_content
    assert_select ".field-error", text: /between 1 and 3 photos/
    assert_empty ocr_jobs
  end

  test "photos that were already uploaded link to the existing receipt" do
    post receipts_path, params: { receipt: { images: [ photo_file(red: 7) ] } }
    existing = Receipt.order(:id).last

    assert_no_difference -> { Receipt.count } do
      post receipts_path, params: { receipt: { images: [ photo_file(red: 7) ] } }
    end

    assert_response :unprocessable_content
    assert_select ".callout a[href=?]", receipt_path(existing)
    assert_select ".field-error", text: /already uploaded/
  end

  # --- Review form: save, accept, enter by hand ------------------------------------------------------------

  def review_params(receipt, **changes)
    items = receipt.items.each_with_index.to_h do |item, index|
      [ index.to_s, { id: item.id, name: item.name, quantity: item.quantity&.to_s("F"), unit_price: item.unit_price&.to_s("F"),
                      discount: item.discount.to_s("F"), amount: item.amount.to_s("F"), category_id: item.category_id.to_s, _destroy: "0" } ]
    end
    { lock_version: receipt.lock_version, kind: receipt.kind, merchant_name: receipt.merchant_name, total: receipt.total&.to_s("F"),
      currency: receipt.currency, items_attributes: items }.merge(changes)
  end

  test "Save stores the corrections and comes back to the receipt with the filter" do
    receipt = receipts(:corner_receipt)

    patch receipt_path(receipt, status: "extracted"),
      params: { intent: "save", receipt: review_params(receipt, merchant_name: "Corner Shop 2", account_id: accounts(:cash_uah).id) }

    assert_redirected_to receipt_path(receipt, status: "extracted", account: accounts(:cash_uah).id)
    follow_redirect!
    # The account chosen before the save stays chosen.
    assert_select "select#receipt_account_id option[selected][value=?]", accounts(:cash_uah).id.to_s
    assert_equal "Saved.", flash[:notice]
    assert_equal "Corner Shop 2", receipt.reload.merchant_name
    assert receipt.extracted?
  end

  test "Accept books the receipt and lands on its transaction, which offers the next receipt to review" do
    receipt = receipts(:corner_receipt)
    receipts(:new_receipt).update_columns(status: "extracted")

    assert_difference -> { Transaction.count }, 1 do
      patch receipt_path(receipt), params: { intent: "accept", receipt: review_params(receipt, account_id: accounts(:card_uah).id) }
    end

    transaction = receipt.reload.ledger_transaction
    assert_redirected_to transaction_path(transaction, accepted: 1)
    follow_redirect!
    assert_select "h1", "Transaction ##{transaction.id}"
    assert_select ".callout", text: /Needs review:\s*a line has no category/
    assert_select "tbody tr", text: /Groceries \/ Groceries\s*-57.50 UAH/
    assert_select "tbody tr", text: /No category\s*-95.00 UAH/
    assert_select "a[href=?]", receipt_path(receipt), text: /Back to Receipt ##{receipt.id}/
    assert_select "a#next-receipt[autofocus][href=?]", receipt_path(receipts(:new_receipt)), text: /Next receipt to review/
  end

  test "a refused save renders the form again with the typed values, the errors and the unsaved flag" do
    receipt = receipts(:corner_receipt)
    params = review_params(receipt, total: "152,505")
    params[:items_attributes]["0"][:amount] = "60,004"

    patch receipt_path(receipt), params: { intent: "save", receipt: params }

    assert_response :unprocessable_content
    assert_select "form##{dom_id(receipt, :review_form)}[data-form-guard-dirty-value=true][data-form-guard-errors-value=true]" do
      assert_select "input[name='receipt[total]'][value=?][aria-invalid=true]", "152.505"
      assert_select "input[name='receipt[items_attributes][0][amount]'][value=?][aria-invalid=true]", "60.004"
      assert_select ".line-row-errors", text: /Amount must have at most 2 decimal places/
      assert_select "[role=alert]", text: /Nothing was saved/
    end
    assert_equal BigDecimal("152.50"), receipt.reload.total
  end

  test "a save from a stale page is a conflict that keeps the typed values and links to the current version" do
    receipt = receipts(:corner_receipt)
    stale = review_params(receipt, merchant_name: "Typed in an old tab")
    receipt.update!(merchant_name: "Saved elsewhere")

    patch receipt_path(receipt), params: { intent: "save", receipt: stale }

    assert_response :conflict
    assert_select "input[name='receipt[merchant_name]'][value=?]", "Typed in an old tab"
    assert_select "input[name='receipt[lock_version]'][value=?]", "0"
    assert_select "[role=alert]", text: /changed somewhere else/
    assert_select "[role=alert] a[target=_blank][href=?]", receipt_path(receipt)
    assert_equal "Saved elsewhere", receipt.reload.merchant_name
  end

  test "a refused accept says why next to the account and saves nothing" do
    receipt = receipts(:corner_receipt)

    patch receipt_path(receipt), params: { intent: "accept", receipt: review_params(receipt, merchant_name: "Typed") }

    assert_response :unprocessable_content
    assert_select "select#receipt_account_id[aria-invalid=true]"
    assert_select ".field-error", text: "Not accepted: choose the account to book it on."
    assert_select "input[name='receipt[merchant_name]'][value=?]", "Typed"
    assert_equal "Corner Shop", receipt.reload.merchant_name
  end

  test "the form offers the active accounts, the receipt's currency first, the last one used chosen" do
    get receipt_path(receipts(:corner_receipt))

    assert_select "select#receipt_account_id" do
      assert_select "optgroup[label='In UAH'] option", 2
      assert_select "optgroup[label='Other currencies'] option", text: "Savings USD (USD)"
      assert_select "option", text: /Old e-wallet/, count: 0
      assert_select "option[selected][value=?]", accounts(:card_uah).id.to_s
    end
  end

  test "the category picker submits a category from the taxonomy, never free text" do
    get receipt_path(receipts(:corner_receipt))

    assert_select "[data-suggestion-id] .combobox" do
      assert_select "input.combobox-input[role=combobox]:not([name])"
      assert_select "select[hidden][tabindex='-1'][name$='[category_id]']" do
        assert_select "option[value='']", "No category"
        assert_select "optgroup[label='Eating out'] option[value=?]", categories(:takeaway).id.to_s, text: "Takeaway & fast food"
        assert_select "optgroup[label=Uncategorised]", false
      end
    end
  end

  test "a card slip shows its category and no items; a receipt with items switching to a slip asks to remove them" do
    receipt = receipts(:corner_receipt)

    get receipt_path(receipt)
    assert_select "[data-receipt-review-target=slipOnly][hidden]", 2
    assert_select "input[name='receipt[remove_items]']", text: nil
    assert_select ".callout", text: /Remove its 3 items when saving/

    receipt.items.delete_all
    receipt.update_columns(kind: "card_slip", card_last4: "4242", category_id: categories(:cafes).id)
    get receipt_path(receipt)
    assert_select "[data-receipt-review-target=slipOnly]:not([hidden])", 2
    assert_select "[data-receipt-review-target=itemsOnly][hidden]"
    assert_select "input[name='receipt[card_last4]'][value='4242']"
    assert_select "select[name='receipt[category_id]'] option[selected][value=?]", categories(:cafes).id.to_s
    assert_select "input[name='receipt[remove_items]']", false
  end

  test "rows typed into a receipt switched to a card slip can be confirmed for removal" do
    receipt = receipts(:corner_receipt)
    receipt.items.delete_all
    params = review_params(receipt.reload, kind: "card_slip",
                           items_attributes: { "0" => { name: "Typed row", amount: "5.00", discount: "0", _destroy: "0" } })

    patch receipt_path(receipt), params: { intent: "save", receipt: params }

    assert_response :unprocessable_content
    assert_select "input[name='receipt[remove_items]']"
    assert_select ".callout", text: /Remove its 1 item when saving/

    params[:remove_items] = "1"
    patch receipt_path(receipt), params: { intent: "save", receipt: params }
    assert_redirected_to receipt_path(receipt)
    assert_empty receipt.reload.items
    assert receipt.card_slip?
  end

  test "a receipt about to be accepted warns about the same date and amount on the account" do
    receipt = receipts(:corner_receipt)
    same = Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 8), amount: "-152.50", source: :bank,
                               lines_attributes: [ { amount: "-152.50" } ])

    get receipt_path(receipt)

    assert_select ".callout", text: /Possibly booked already/ do
      assert_select "a[href=?]", transaction_path(same)
    end
  end

  test "Enter by hand opens the review form on a failed receipt" do
    receipt = receipts(:failed_receipt)
    get receipt_path(receipt)
    assert_select "form[action=?]", enter_by_hand_receipt_path(receipt), text: /Enter by hand/

    post enter_by_hand_receipt_path(receipt)

    assert_redirected_to receipt_path(receipt)
    assert receipt.reload.extracted?
    follow_redirect!
    assert_select "form##{dom_id(receipt, :review_form)}"
    assert_select "p", text: "Entered by hand; waiting for review."
    assert_select "input[name='receipt[items_attributes][0][name]']", 1, "one empty row to start typing in"
  end

  test "Enter by hand on an unread receipt with a waiting request asks first, and a reviewed receipt is refused" do
    receipt = receipts(:new_receipt)
    receipt.update_columns(ocr_requested_at: 1.minute.ago)
    get receipt_path(receipt)
    assert_select "form[action=?][data-turbo-confirm*=?]", enter_by_hand_receipt_path(receipt), "withdrawn"

    post enter_by_hand_receipt_path(receipts(:market_receipt))
    assert_match "Not entered by hand", flash[:alert]
    assert receipts(:market_receipt).reload.reviewed?
  end

  test "the review actions need a signed-in session" do
    sign_out
    receipt = receipts(:corner_receipt)

    patch receipt_path(receipt), params: { intent: "save", receipt: review_params(receipt, merchant_name: "x") }
    assert_redirected_to new_session_path
    post enter_by_hand_receipt_path(receipts(:failed_receipt))
    assert_redirected_to new_session_path
    assert_equal "Corner Shop", receipt.reload.merchant_name
    assert receipts(:failed_receipt).reload.failed?
  end

  test "the receipt list links a booked receipt to its transaction" do
    get receipts_path

    assert_select "tr##{dom_id(receipts(:market_receipt))} a[href=?]", transaction_path(transactions(:market_split))
  end

  private
    def with_per_page(count)
      original = Pagination::PER_PAGE
      Pagination.send(:remove_const, :PER_PAGE)
      Pagination.const_set(:PER_PAGE, count)
      yield
    ensure
      Pagination.send(:remove_const, :PER_PAGE)
      Pagination.const_set(:PER_PAGE, original)
    end
end

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
      assert_select "td span[title=?]", "Transaction ##{transactions(:market_split).id}"
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
      { kind: "fiscal" } => [ :market_receipt ],
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

  test "a receipt page shows its photos and its stored data" do
    receipt = receipts(:market_receipt)

    get receipt_path(receipt)

    assert_response :success
    assert_select "h1", "rcpt_000041"
    photo = active_storage_attachments(:market_photo)
    assert_select "a.photo-frame[href=?][target=_blank]", receipt_photo_path(receipt, photo, :full) do
      assert_select "img[src=?][alt=?]", receipt_photo_path(receipt, photo, :page), "Photo 1 of 1 of rcpt_000041"
    end
    assert_select "##{dom_id(receipt, :status)}", text: "Accepted"
    assert_select "##{dom_id(receipt, :data)}" do
      assert_select ".data-row", text: /Merchant\s*Example Market/
      assert_select ".data-row", text: /Fiscal number\s*4000000001/
      assert_select ".data-row", text: /Ingest number\s*rcpt_000041/
      assert_select "tbody tr", text: /Hard cheese 1 kg\s*1\s*1 010.00\s*50.00\s*960.00\s*Groceries/
      assert_select ".data-row", text: /Items sum\s*1 250.40 UAH/
      assert_select ".badge", text: "Items match the total"
      assert_select ".badge", text: "Match", count: 4
    end
    assert_select "[data-controller=live-refresh] turbo-cable-stream-source"
  end

  test "a receipt page shows suggestions with their confidence, the card digits and QR mismatches" do
    receipt = receipts(:corner_receipt)
    receipt.update_columns(qr_total: BigDecimal("150.00"), qr_issued_at: receipt.issued_at + 30.seconds)

    get receipt_path(receipt)

    assert_select "tbody tr", text: /Sandwich.*Suggested: Takeaway & fast food\s*\(62%\)/m
    assert_select ".badge", text: "Items match the total"
    assert_select ".data-row", text: /Card\s*•••• 4242/
    assert_select "tr", text: /Total\s*150.00\s*152.50\s*Mismatch/
    assert_select "tr", text: /Issued at\s*2026-10-08 12:05\s*2026-10-08 12:05\s*Match/
    assert_select "tr", text: /Fiscal number.*Not in the QR code/m, count: 0
  end

  test "the items' gap to the printed total is shown with its sign" do
    receipt = receipts(:corner_receipt)
    receipt.update_columns(total: BigDecimal("160.00"))

    get receipt_path(receipt)

    assert_select ".data-row", text: /Difference\s*7.50 UAH\s*Items missing/
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
    receipts(:failed_receipt).update_columns(status: "processing")

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

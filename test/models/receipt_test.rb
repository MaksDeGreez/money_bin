require "test_helper"
require_relative "../support/receipt_images"

class ReceiptTest < ActiveSupport::TestCase
  include ReceiptImages

  def assert_violates(constraint, error = ActiveRecord::StatementInvalid, &block)
    exception = assert_raises(error) { Receipt.transaction(requires_new: true, &block) }
    assert_includes exception.message, constraint
  end

  def sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  test "a new receipt with one photo gets the photo's digest as its fingerprint" do
    bytes = png_bytes(red: 200)
    receipt = Receipt.create!(images: [ image_upload(bytes) ])

    assert receipt.uploaded?
    assert_equal sha256(bytes), receipt.sha256
    assert_equal "image/png", receipt.images.first.content_type
  end

  test "the photo is stored, and the test helper deletes it afterwards" do
    receipt = Receipt.create!(images: [ image_upload(png_bytes(green: 7)) ])
    blob = receipt.images.first.blob

    assert blob.service.exist?(blob.key)
    delete_stored_receipt_files
    assert_not blob.service.exist?(blob.key)
  end

  test "several photos are fingerprinted over their sorted digests, so the order does not matter" do
    photos = [ png_bytes(red: 1), png_bytes(red: 2), png_bytes(red: 3) ]
    receipt = Receipt.create!(images: photos.map { |bytes| image_upload(bytes) })

    assert_equal sha256(photos.map { |bytes| sha256(bytes) }.sort.join), receipt.sha256
    assert_equal receipt.sha256, Receipt.fingerprint(photos.reverse.map { |bytes| image_upload(bytes) })

    again = Receipt.new(images: photos.reverse.map { |bytes| image_upload(bytes) })
    assert_not again.valid?
    assert_includes again.errors[:sha256], "matches a receipt that was already uploaded"
  end

  test "a subset of the photos counts as a different receipt" do
    photos = [ png_bytes(red: 4), png_bytes(red: 5) ]
    Receipt.create!(images: photos.map { |bytes| image_upload(bytes) })

    assert Receipt.new(images: [ image_upload(photos.first) ]).valid?
  end

  test "the same photo cannot be attached twice to one receipt" do
    bytes = png_bytes(red: 6)
    receipt = Receipt.new(images: [ image_upload(bytes, filename: "a.png"), image_upload(bytes, filename: "b.png") ])

    assert_not receipt.valid?
    assert_includes receipt.errors[:images], "must be different photos: the same photo is attached twice"

    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png_bytes(red: 8)), filename: "r.png")
    twice = Receipt.new(images: [ blob, blob.signed_id ])
    assert_not twice.valid?
    assert_includes twice.errors[:images], "must be different photos: the same photo is attached twice"
  end

  test "photos uploaded ahead of the form are attached by their signed blob ids" do
    bytes = png_bytes(green: 40)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "r.png", content_type: "image/png")

    receipt = Receipt.new(images: [ blob.signed_id, "" ])

    assert receipt.valid?, receipt.errors.full_messages.to_sentence
    assert_equal sha256(bytes), receipt.sha256
    receipt.save!
    assert_equal [ blob ], receipt.reload.images.blobs
  end

  test "an invalid signed blob id is a validation error, not an exception" do
    receipt = Receipt.new(images: [ "not-a-signed-id" ])

    assert_not receipt.valid?
    assert_includes receipt.errors[:images], "include 1 upload id(s) that are not valid or have expired; upload the photo again"

    receipt.images = [ image_upload(png_bytes(green: 41)) ]
    assert receipt.valid?
  end

  test "attach accepts a signed blob id on a saved receipt" do
    receipt = Receipt.create!(images: [ image_upload(png_bytes(green: 42)) ])
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png_bytes(green: 43)), filename: "back.png")

    receipt.images.attach(blob.signed_id)

    assert_equal 2, receipt.reload.images.count
  end

  test "attach on a new receipt sets the fingerprint too" do
    receipt = Receipt.new(batch: " weekend ")
    receipt.images.attach(image_upload(png_bytes(blue: 9)))
    receipt.save!

    assert_equal sha256(png_bytes(blue: 9)), receipt.sha256
    assert_equal "weekend", receipt.batch
  end

  test "a given fingerprint is kept" do
    digest = sha256("something else")
    receipt = Receipt.create!(sha256: digest, images: [ image_upload ])

    assert_equal digest, receipt.sha256
  end

  test "the same photo cannot be uploaded twice" do
    Receipt.create!(images: [ image_upload(png_bytes(red: 50)) ])
    again = Receipt.new(images: [ image_upload(png_bytes(red: 50)) ])

    assert_not again.valid?
    assert_includes again.errors[:sha256], "matches a receipt that was already uploaded"
  end

  test "a receipt needs one to three photos" do
    receipt = Receipt.new(sha256: sha256("no photo"))
    assert_not receipt.valid?
    assert_includes receipt.errors[:images], "must be between 1 and 3 photos (got 0)"

    four = Receipt.new(images: (1..4).map { |red| image_upload(png_bytes(red:)) })
    assert_not four.valid?
    assert_includes four.errors[:images], "must be between 1 and 3 photos (got 4)"
  end

  test "a receipt without photos has no fingerprint" do
    receipt = Receipt.new

    assert_not receipt.valid?
    assert_includes receipt.errors[:sha256], "can't be blank"
  end

  test "only photos are accepted" do
    text = Receipt.new(images: [ image_upload("total 10.00\n", filename: "notes.txt", content_type: "text/plain") ])
    assert_not text.valid?
    assert_includes text.errors[:images], "must be photos (JPEG, PNG, WebP or HEIC); notes.txt is text/plain"

    svg = Receipt.new(images: [ image_upload(%(<svg xmlns="http://www.w3.org/2000/svg"/>), filename: "r.svg", content_type: "image/svg+xml") ])
    assert_not svg.valid?
    assert_match "r.svg is image/svg+xml", svg.errors[:images].to_sentence
  end

  # The byte size is set on the blob, so the test needs no 15 MB of real data.
  test "a photo larger than the ML service accepts is refused" do
    assert_equal 15 * 1024 * 1024, Receipt::MAX_IMAGE_BYTES

    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png_bytes(red: 90)), filename: "big.png", content_type: "image/png")
    blob.update_column(:byte_size, Receipt::MAX_IMAGE_BYTES + 1)
    receipt = Receipt.new(images: [ blob ])

    assert_not receipt.valid?
    assert_includes receipt.errors[:images], "must be at most 15 MB (15728640 bytes) each; big.png has 15728641 bytes"

    blob.update_column(:byte_size, Receipt::MAX_IMAGE_BYTES)
    assert Receipt.new(images: [ blob ]).valid?
  end

  test "the content type comes from the bytes, not from the declared type" do
    receipt = Receipt.new(images: [ image_upload(png_bytes, filename: "photo", content_type: "text/plain") ])

    assert receipt.valid?
    assert_equal "image/png", receipt.images.first.content_type
  end

  test "fingerprint reads files, IO objects, uploads and blobs and rewinds them" do
    bytes = png_bytes(red: 77)
    io = StringIO.new(bytes)
    file = Tempfile.new([ "receipt", ".png" ], binmode: true).tap { |f| f.write(bytes) && f.flush }
    upload = Rack::Test::UploadedFile.new(file.path, "image/png", true)

    [ io, file, upload, { io: StringIO.new(bytes) }, { "io" => StringIO.new(bytes) } ].each do |source|
      assert_equal sha256(bytes), Receipt.fingerprint(source), source.class.name
    end
    assert_equal bytes, io.read

    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "r.png")
    assert_equal sha256(bytes), Receipt.fingerprint([ blob ])
  ensure
    file&.close!
  end

  test "fingerprint refuses no images and unreadable sources" do
    assert_raises(ArgumentError) { Receipt.fingerprint([]) }
    assert_raises(ArgumentError) { Receipt.fingerprint("/tmp/receipt.png") }
  end

  test "status must be listed and is stored as a string" do
    receipt = receipts(:new_receipt)
    assert_equal "uploaded", Receipt.where(id: receipt).pick(:status)
    assert_equal %w[uploaded processing extracted reviewed failed], Receipt.statuses.values

    receipt.status = "scanned"
    assert_not receipt.valid?
    assert_includes receipt.errors[:status], "is not included in the list"
  end

  test "currency is three letters when present" do
    receipt = receipts(:new_receipt)

    receipt.currency = " eur "
    assert receipt.valid?
    assert_equal "EUR", receipt.currency

    receipt.currency = "EURO"
    assert_not receipt.valid?
    assert_includes receipt.errors[:currency], "must be three letters (ISO 4217)"
  end

  test "total fits decimal(15, 2)" do
    receipt = receipts(:new_receipt)
    receipt.total = 10**13

    assert_not receipt.valid?
  end

  test "total has at most two decimal places" do
    receipt = receipts(:new_receipt)
    receipt.total = "12.345"

    assert_not receipt.valid?
    assert_includes receipt.errors[:total], "must have at most 2 decimal places (it is never rounded)"
    receipt.total = "12.30"
    assert receipt.valid?
  end

  test "kind is fiscal, card_slip or not known yet" do
    receipt = receipts(:new_receipt)
    assert_nil receipt.kind
    assert receipt.valid?
    assert_equal %w[fiscal card_slip], Receipt.kinds.values

    receipt.kind = "invoice"
    assert_not receipt.valid?
    assert_includes receipt.errors[:kind], "is not included in the list"

    receipt.kind = :card_slip
    assert receipt.valid?
    assert receipt.card_slip?
  end

  test "incomplete is false by default and never nil" do
    assert_not Receipt.new.incomplete?

    receipt = receipts(:new_receipt)
    receipt.incomplete = nil
    assert_not receipt.valid?
  end

  test "card_last4 is four digits when present" do
    receipt = receipts(:new_receipt)

    [ "123", "12345", "12a4", "١٢٣٤" ].each do |value|
      receipt.card_last4 = value
      assert_not receipt.valid?, value
      assert_includes receipt.errors[:card_last4], "must be four digits"
    end
    receipt.card_last4 = "0042"
    assert receipt.valid?
  end

  test "ingest_id is rcpt_ and six or more digits, and unique" do
    receipt = receipts(:new_receipt)

    [ "rcpt_12345", "RCPT_000001", "rcpt_00000a", "000001" ].each do |value|
      receipt.ingest_id = value
      assert_not receipt.valid?, value
    end
    receipt.ingest_id = "rcpt_1000000"
    assert receipt.valid?

    receipt.ingest_id = receipts(:market_receipt).ingest_id
    assert_not receipt.valid?
    assert_includes receipt.errors[:ingest_id], "has already been taken"
  end

  test "qr_total fits decimal(15, 2) and is never rounded" do
    receipt = receipts(:new_receipt)

    receipt.qr_total = "12.345"
    assert_not receipt.valid?
    assert_includes receipt.errors[:qr_total], "must have at most 2 decimal places (it is never rounded)"
    receipt.qr_total = 10**13
    assert_not receipt.valid?
    receipt.qr_total = "12.30"
    assert receipt.valid?
  end

  test "the QR ground truth is kept apart from what OCR read" do
    receipt = receipts(:market_receipt)

    assert receipt.tax_qr?
    assert_equal [ receipt.total, receipt.issued_at ], [ receipt.qr_total, receipt.qr_issued_at ]
    receipt.qr_total = BigDecimal("1.00")
    assert_equal BigDecimal("1250.40"), receipt.total
  end

  test "tax_qr? is true when any QR value is present" do
    receipt = receipts(:new_receipt)
    assert_not receipt.tax_qr?

    Receipt::QR_FIELDS.each do |field|
      receipt = receipts(:new_receipt)
      receipt[field] = field == :qr_total ? BigDecimal("0") : (field == :qr_issued_at ? Time.current : "1")
      assert receipt.tax_qr?, field
    end
  end

  test "index filters by kind and by tax QR" do
    receipts(:corner_receipt).update_columns(kind: "card_slip")
    assert_equal [ receipts(:market_receipt) ], Receipt.fiscal.to_a
    assert_equal [ receipts(:corner_receipt) ], Receipt.card_slip.to_a
    assert_equal [ receipts(:new_receipt), receipts(:failed_receipt) ].sort_by(&:id), Receipt.kind_unknown.order(:id).to_a
    assert_equal [ receipts(:market_receipt), receipts(:failed_receipt) ].sort_by(&:id), Receipt.with_tax_qr.order(:id).to_a

    receipts(:new_receipt).update_column(:qr_receipt_number, "1")
    assert_equal [ receipts(:market_receipt), receipts(:new_receipt), receipts(:failed_receipt) ].sort_by(&:id),
      Receipt.with_tax_qr.order(:id).to_a
    assert_equal [ receipts(:corner_receipt) ], Receipt.without_tax_qr.to_a
    assert_equal Receipt.count, Receipt.with_tax_qr.count + Receipt.without_tax_qr.count
  end

  test "a receipt is pristine while uploaded, without items and without a transaction" do
    assert receipts(:new_receipt).pristine?
    assert_not receipts(:corner_receipt).pristine?
    assert_not receipts(:market_receipt).pristine?

    receipt = receipts(:new_receipt)
    receipt.items.create!(position: 1, name: "Tea", amount: BigDecimal("1"))
    assert_not receipt.pristine?
  end

  test "a receipt with ground truth is not pristine: the receipt load keeps it" do
    receipt = receipts(:new_receipt)
    receipt.ground_truths.create!(source: :manual, schema_version: 2, items_known: false,
      prefilled_by: ReceiptGroundTruth::PREFILLED_BY_HAND,
      document: ReceiptGroundTruth::Document.blank)
    assert_not receipt.pristine?
  end

  test "a transaction has at most one receipt" do
    receipt = receipts(:corner_receipt)
    receipt.ledger_transaction = transactions(:market_split)

    assert_not receipt.valid?
    assert_includes receipt.errors[:transaction_id], "already has a receipt"
  end

  test "a transaction id that does not exist is a validation error" do
    receipt = receipts(:corner_receipt)
    receipt.transaction_id = Transaction.maximum(:id) + 1

    assert_not receipt.valid?
    assert_includes receipt.errors[:ledger_transaction], "does not exist"
  end

  test "links to its transaction both ways" do
    assert_equal transactions(:market_split), receipts(:market_receipt).ledger_transaction
    assert_equal receipts(:market_receipt), transactions(:market_split).receipt
  end

  test "items are ordered by position and sum to items_total" do
    receipt = receipts(:corner_receipt)
    receipt_items(:corner_water).update!(position: 9)

    assert_equal [ "Sandwich", "Bottle deposit returned", "Sparkling water 1.5 l" ], receipt.items.reload.map(&:name)
    assert_equal BigDecimal("152.50"), receipt.items_total
  end

  test "destroying a receipt destroys its items" do
    assert_difference -> { ReceiptItem.count }, -3 do
      receipts(:corner_receipt).destroy!
    end
  end

  test "destroying the transaction keeps the receipt, unlinked and back in review" do
    receipt = receipts(:market_receipt)
    transactions(:market_split).destroy!

    receipt.reload
    assert_nil receipt.transaction_id
    assert receipt.extracted?
    assert_equal 3, receipt.items.count
    assert Receipts::Accept.call(receipt, account: accounts(:card_uah)).persisted?
  end

  test "destroying the transaction moves the receipt's version, so a form rendered while it was booked is stale" do
    receipt = receipts(:market_receipt)

    transactions(:market_split).destroy!

    assert_equal 1, receipt.reload.lock_version
  end

  test "a card slip's category and its suggestion must be categories, not groups; the confidence is 0..1" do
    receipt = receipts(:corner_receipt)

    receipt.category = categories(:groceries_group)
    receipt.suggested_category = categories(:eating_out)
    receipt.suggested_category_confidence = 1.5
    assert_not receipt.valid?
    assert_includes receipt.errors[:category], "must be a category, not a group"
    assert_includes receipt.errors[:suggested_category], "must be a category, not a group"
    assert receipt.errors[:suggested_category_confidence].any?

    receipt.assign_attributes(category: categories(:cafes), suggested_category: categories(:takeaway), suggested_category_confidence: 0.4)
    assert receipt.valid?
    receipt.category_id = Category.maximum(:id) + 1
    assert_not receipt.valid?
    assert_includes receipt.errors[:category], "does not exist"
  end

  test "the database checks the suggested category's confidence" do
    assert_violates("receipts_suggested_category_confidence_range") { receipts(:new_receipt).update_column(:suggested_category_confidence, 1.01) }
  end

  test "a receipt is reviewable when read or accepted and no OCR is queued or running" do
    assert receipts(:corner_receipt).reviewable?
    assert receipts(:market_receipt).reviewable?
    assert_not receipts(:new_receipt).reviewable?
    assert_not receipts(:failed_receipt).reviewable?

    receipts(:corner_receipt).update_columns(ocr_requested_at: 1.minute.ago)
    assert_not receipts(:corner_receipt).reviewable?
  end

  test "what accepting books: the items' sum, or a slip's total" do
    receipt = receipts(:corner_receipt)
    assert_equal BigDecimal("152.50"), receipt.booking_total

    receipt.kind = :card_slip
    receipt.total = BigDecimal("99.90")
    assert_equal BigDecimal("99.90"), receipt.booking_total
  end

  test "a receipt on a destroyed transfer leg goes back to review, also through the other leg" do
    receipt = receipts(:corner_receipt)
    receipt.update_columns(transaction_id: transactions(:withdrawal_in).id, status: "reviewed")

    transactions(:withdrawal_out).destroy!

    receipt.reload
    assert_nil receipt.transaction_id
    assert receipt.extracted?
  end

  test "a failed destroy leaves the receipt reviewed and linked" do
    receipt = receipts(:market_receipt)
    stale = Transaction.find(transactions(:market_split).id)
    transactions(:market_split).update!(comment: "Edited elsewhere")

    assert_raises(ActiveRecord::StaleObjectError) { stale.destroy }

    receipt.reload
    assert receipt.reviewed?
    assert_equal transactions(:market_split).id, receipt.transaction_id
  end

  test "a linked receipt that was never accepted keeps its status when the transaction goes" do
    receipt = receipts(:corner_receipt)
    receipt.update_columns(transaction_id: transactions(:coffee).id)

    transactions(:coffee).destroy!

    assert receipt.reload.extracted?
    assert_nil receipt.transaction_id
  end

  test "the database checks kind, card digits and ingest id" do
    receipt = receipts(:new_receipt)

    assert_violates("receipts_kind_allowed") { receipt.update_column(:kind, "invoice") }
    assert_violates("receipts_card_last4_format") { receipt.update_column(:card_last4, "12a4") }
    assert_violates("receipts_ingest_id_format") { receipt.update_column(:ingest_id, "rcpt_1") }
    assert_violates("index_receipts_on_ingest_id", ActiveRecord::RecordNotUnique) do
      receipt.update_column(:ingest_id, receipts(:market_receipt).ingest_id)
    end
    assert_violates("not-null") { Receipt.where(id: receipt).update_all(incomplete: nil) }
    receipt.update_column(:ingest_id, nil)
    receipts(:corner_receipt).update_column(:ingest_id, nil)
    assert_equal 2, Receipt.where(ingest_id: nil).count, "many receipts may have no ingest id"
  end

  test "the database checks status, currency and fingerprint" do
    receipt = receipts(:new_receipt)

    assert_violates("receipts_status_allowed") { receipt.update_column(:status, "scanned") }
    assert_violates("receipts_currency_format") { Receipt.where(id: receipt).update_all("currency = 'eur'") }
    assert_violates("receipts_sha256_format") { receipt.update_column(:sha256, "ABC") }
    assert_violates("index_receipts_on_sha256", ActiveRecord::RecordNotUnique) do
      receipt.update_column(:sha256, receipts(:market_receipt).sha256)
    end
  end

  test "the database allows one receipt per transaction" do
    assert_violates("index_receipts_on_transaction_id", ActiveRecord::RecordNotUnique) do
      receipts(:corner_receipt).update_column(:transaction_id, transactions(:market_split).id)
    end
  end

  test "newest first: uploaded in the app by upload time, then by ingest number as a number" do
    Receipt.where(ingest_id: nil).update_all(created_at: 1.year.ago)
    receipts(:new_receipt).update_columns(created_at: 1.day.ago)
    receipts(:corner_receipt).update_columns(ingest_id: "rcpt_1000000")

    order = Receipt.newest_first.map(&:id)

    assert_equal [ :new_receipt, :corner_receipt, :failed_receipt, :market_receipt ].map { |name| receipts(name).id }, order
  end

  test "ocr_error is the stored failure reason, or nil" do
    assert_equal "unsupported_media_type", receipts(:failed_receipt).ocr_error["code"]
    assert_nil receipts(:market_receipt).ocr_error
    assert_nil receipts(:new_receipt).ocr_error
    assert_nil Receipt.new(ocr_raw: { "error" => "text" }).ocr_error
  end

  test "a request is pending once recorded, and waiting until it counts as lost" do
    receipt = receipts(:new_receipt)
    assert_not receipt.ocr_pending?

    receipt.ocr_requested_at = 1.hour.ago
    assert receipt.ocr_pending?
    assert receipt.ocr_request_waiting?

    receipt.ocr_requested_at = (Receipt::OCR_REQUEST_LOST_AFTER + 1.minute).ago
    assert receipt.ocr_pending?
    assert_not receipt.ocr_request_waiting?
  end

  test "a receipt is stuck when it has been processing for longer than a read takes" do
    receipt = receipts(:new_receipt)
    receipt.status = "processing"
    receipt.updated_at = 10.minutes.ago
    assert_not receipt.ocr_stuck?

    receipt.updated_at = (Receipt::OCR_STUCK_AFTER + 1.minute).ago
    assert receipt.ocr_stuck?
  end

  test "the photos are in upload order and have JPEG variants for the pages" do
    receipt = Receipt.create!(images: [ image_upload(png_bytes(red: 1)), image_upload(png_bytes(red: 2)) ])

    assert_equal receipt.images.attachments.map(&:id).sort, receipt.ordered_images.map(&:id)
    %i[thumb page full].each do |name|
      assert_equal "jpeg", receipt.ordered_images.first.variant(name).variation.format.to_s, name
    end
  end
end

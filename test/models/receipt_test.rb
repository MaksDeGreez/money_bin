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

  test "destroying the transaction keeps the receipt, unlinked" do
    receipt = receipts(:market_receipt)
    transactions(:market_split).destroy!

    assert_nil receipt.reload.transaction_id
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
end

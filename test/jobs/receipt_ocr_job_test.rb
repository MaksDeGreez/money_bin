require "test_helper"
require_relative "../support/ml_service_stubs"
require_relative "../support/receipt_images"
require "turbo/broadcastable/test_helper"

class ReceiptOcrJobTest < ActiveJob::TestCase
  include MlServiceStubs
  include ReceiptImages
  include Turbo::Broadcastable::TestHelper

  def new_receipt(*colours)
    colours = [ 10 ] if colours.empty?
    Receipt.create!(images: colours.map { |red| image_upload(png_bytes(red:)) })
  end

  def error_of(receipt)
    receipt.reload.ocr_raw["error"]
  end

  test "reads the photos, stores the result and marks the receipt extracted" do
    stub_ml_ocr
    receipt = new_receipt

    ReceiptOcrJob.perform_now(receipt)

    receipt.reload
    assert receipt.extracted?
    assert_equal "stub-ocr", receipt.ocr_model_name
    assert_equal "Sample Grocer", receipt.merchant_name
    assert_equal [ "Oat milk 1 l", "Apples" ], receipt.items.map(&:name)
    assert_equal ml_ocr_body.deep_stringify_keys, receipt.ocr_raw
  end

  test "sends every photo in upload order with its content type" do
    stub_ml_ocr
    receipt = Receipt.create!(images: [
      image_upload(png_bytes(red: 1), filename: "first.png"),
      image_upload(png_bytes(red: 2), filename: "second.png"),
      image_upload(png_bytes(red: 3), filename: "third.png")
    ])

    ReceiptOcrJob.perform_now(receipt)

    parts = multipart_parts(ml_requests(:ocr).sole)
    assert_equal %w[images images images], parts.pluck(:name)
    assert_equal %w[first.png second.png third.png], parts.pluck(:filename)
    assert_equal %w[image/png] * 3, parts.pluck(:content_type)
    assert_equal [ png_bytes(red: 1), png_bytes(red: 2), png_bytes(red: 3) ], parts.pluck(:body)
  end

  test "a HEIF photo is sent as HEIC" do
    stub_ml_ocr
    receipt = new_receipt
    receipt.images.first.blob.update_column(:content_type, "image/heif")

    ReceiptOcrJob.perform_now(receipt)

    assert_equal "image/heic", multipart_parts(ml_requests(:ocr).sole).sole[:content_type]
  end

  test "the receipt is processing while the service reads it" do
    receipt = new_receipt
    seen = nil
    stub_request(:post, ml_url("/ocr")).to_return do
      seen = Receipt.find(receipt.id).status
      { status: 200, body: JSON.generate(ml_ocr_body) }
    end

    ReceiptOcrJob.perform_now(receipt)

    assert_equal "processing", seen
    assert receipt.reload.extracted?
  end

  test "is enqueued on its own queue, which one Sidekiq thread works (config/sidekiq.yml)" do
    receipt = receipts(:new_receipt)

    assert_enqueued_with(job: ReceiptOcrJob, args: [ receipt ], queue: "receipt_ocr") do
      ReceiptOcrJob.perform_later(receipt)
    end
  end

  test "running twice does the work once" do
    stub_ml_ocr
    receipt = new_receipt

    2.times { ReceiptOcrJob.perform_now(receipt) }

    assert_equal 1, ml_requests(:ocr).size
    assert_equal [ "Oat milk 1 l", "Apples" ], receipt.reload.items.map(&:name)
  end

  test "picks up a receipt stuck in processing and retries a failed one on request" do
    stub_ml_ocr
    stuck = new_receipt(1)
    stuck.update_columns(status: "processing")
    failed = new_receipt(2)
    failed.update_columns(status: "failed", ocr_raw: { "error" => { "code" => "ml_timeout", "message" => "Too slow." } })

    ReceiptOcrJob.perform_now(stuck)
    Receipts::RequestOcr.read_again(failed)
    ReceiptOcrJob.perform_now(failed)

    assert stuck.reload.extracted?
    assert failed.reload.extracted?
    assert_nil failed.ocr_raw["error"]
  end

  test "leaves extracted and reviewed receipts alone" do
    stub_ml_ocr

    [ receipts(:corner_receipt), receipts(:market_receipt) ].each do |receipt|
      before = [ receipt.reload.attributes, receipt.items.map(&:attributes) ]
      ReceiptOcrJob.perform_now(receipt)
      assert_equal before, [ receipt.reload.attributes, receipt.items.reload.map(&:attributes) ]
    end
    assert_empty ml_requests(:ocr)
  end

  test "a receipt reviewed while the service was reading it keeps the person's result" do
    receipt = new_receipt
    stub_request(:post, ml_url("/ocr")).to_return do
      Receipt.where(id: receipt.id).update_all(status: "reviewed")
      { status: 200, body: JSON.generate(ml_ocr_body) }
    end

    assert_nothing_raised { ReceiptOcrJob.perform_now(receipt) }

    receipt.reload
    assert receipt.reviewed?
    assert_nil receipt.ocr_raw
    assert_empty receipt.items
  end

  test "a receipt deleted before the job ran is discarded quietly" do
    receipt = new_receipt
    ReceiptOcrJob.perform_later(receipt)
    receipt.destroy!

    assert_nothing_raised { perform_enqueued_jobs }
    assert_no_enqueued_jobs(only: ReceiptOcrJob)
  end

  # --- permanent failures: failed at once, no retry

  test "an error answer marks the receipt failed at once with the service's code" do
    {
      [ 422, "too_many_images" ] => "Send at most 3 files, got 4.",
      [ 415, "unsupported_media_type" ] => "File 'r.gif' has type 'image/gif'.",
      [ 413, "image_too_large" ] => "File 'r.jpg' is larger than the limit of 15728640 bytes.",
      [ 501, "backend_not_implemented" ] => "The mlx backend is a placeholder."
    }.each do |(status, code), message|
      stub_ml_error(:ocr, status:, code:, message:)
      receipt = new_receipt(status % 256)

      ReceiptOcrJob.perform_now(receipt)

      assert receipt.reload.failed?, code
      assert_equal({ "code" => code, "message" => "the ML service answered #{status} #{code}: #{message}" }, error_of(receipt))
      assert_no_enqueued_jobs(only: ReceiptOcrJob)
    end
  end

  test "an invalid answer marks the receipt failed at once" do
    stub_ml(:ocr, status: 200, body: "not json")
    receipt = new_receipt

    ReceiptOcrJob.perform_now(receipt)

    assert receipt.reload.failed?
    assert_equal({ "code" => "invalid_response", "message" => "the ML service answer is not valid JSON" }, error_of(receipt))
    assert_empty receipt.items
    assert_no_enqueued_jobs(only: ReceiptOcrJob)
  end

  test "a receipt without photos fails without calling the service" do
    receipt = new_receipt
    ActiveStorage::Attachment.where(record: receipt).delete_all

    ReceiptOcrJob.perform_now(receipt)

    assert receipt.reload.failed?
    assert_equal({ "code" => "no_images", "message" => "the receipt has no photos" }, error_of(receipt))
    assert_empty ml_requests(:ocr)
  end

  test "a photo whose file is gone fails without calling the service" do
    receipt = receipts(:new_receipt) # fixture blobs have no bytes

    ReceiptOcrJob.perform_now(receipt)

    assert receipt.reload.failed?
    assert_equal "image_missing", error_of(receipt)["code"]
    assert_empty ml_requests(:ocr)
    assert_no_enqueued_jobs(only: ReceiptOcrJob)
  end

  test "a long error message is cut short and kept on one line" do
    stub_ml_error(:ocr, status: 422, code: "validation_error", message: "images: bad\nvalue " * 100)
    receipt = new_receipt

    ReceiptOcrJob.perform_now(receipt)

    message = error_of(receipt)["message"]
    assert_equal ReceiptOcrJob::MAX_MESSAGE_LENGTH, message.length
    assert_not_includes message, "\n"
  end

  # --- transient failures: retried, failed when the attempts run out

  test "a transient failure is retried and the receipt stays processing" do
    stub_request(:post, ml_url("/ocr")).to_timeout
    receipt = new_receipt

    assert_enqueued_with(job: ReceiptOcrJob, args: [ receipt ]) do
      ReceiptOcrJob.perform_now(receipt)
    end

    receipt.reload
    assert receipt.processing?
    assert_nil receipt.ocr_raw
  end

  test "a retry that succeeds stores the result" do
    receipt = new_receipt
    stub_request(:post, ml_url("/ocr"))
      .to_raise(Errno::ECONNREFUSED).then
      .to_return(status: 503, body: JSON.generate(error: { code: "internal_error", message: "Busy." })).then
      .to_return(status: 200, body: JSON.generate(ml_ocr_body))

    perform_enqueued_jobs { ReceiptOcrJob.perform_later(receipt) }

    assert receipt.reload.extracted?
    assert_requested :post, ml_url("/ocr"), times: 3
  end

  test "when the attempts run out the receipt fails with the last reason" do
    {
      -> { stub_request(:post, ml_url("/ocr")).to_timeout } => "ml_timeout",
      -> { stub_request(:post, ml_url("/ocr")).to_raise(Errno::ECONNREFUSED) } => "ml_unreachable",
      -> { stub_ml_error(:ocr, status: 500, code: "internal_error", message: "Internal server error.") } => "internal_error"
    }.each.with_index do |(stub, code), index|
      WebMock.reset!
      stub.call
      receipt = new_receipt(index + 1)

      perform_enqueued_jobs { ReceiptOcrJob.perform_later(receipt) }

      assert receipt.reload.failed?, code
      assert_equal code, error_of(receipt)["code"]
      assert_requested :post, ml_url("/ocr"), times: ReceiptOcrJob::ATTEMPTS
    end
  end

  test "a failure is not recorded on a receipt reviewed or deleted meanwhile" do
    reviewed = receipts(:market_receipt)
    job = ReceiptOcrJob.new(reviewed)
    job.mark_failed(MlClient::TimeoutError.new("too slow"))
    assert reviewed.reload.reviewed?

    gone = new_receipt
    job = ReceiptOcrJob.new(gone)
    gone.destroy!
    assert_nothing_raised { job.mark_failed(MlClient::TimeoutError.new("too slow")) }
  end

  test "an unexpected error is raised and the receipt stays processing" do
    stub_ml_ocr
    receipt = new_receipt
    failing = ->(*) { raise ActiveRecord::ConnectionNotEstablished, "database gone" }

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      with_singleton_method(Receipts::ApplyOcr, :call, failing) { ReceiptOcrJob.perform_now(receipt) }
    end
    assert receipt.reload.processing?
  end

  # --- requests (Receipts::RequestOcr) and re-reads

  test "starting clears the waiting request" do
    stub_ml_ocr
    receipt = new_receipt
    receipt.update_columns(ocr_requested_at: Time.current)

    ReceiptOcrJob.perform_now(receipt)

    assert_nil receipt.reload.ocr_requested_at
    assert receipt.extracted?
  end

  test "an extracted receipt is read again only while a request to read it again waits, and its items are replaced" do
    stub_ml_ocr
    receipt = new_receipt
    ReceiptOcrJob.perform_now(receipt)
    assert_equal 2, receipt.reload.items.count

    stub_ml_ocr(receipt: { merchant: "Second Read", items: [ { name: "Bread", amount: "30.00" } ] })
    ReceiptOcrJob.perform_now(receipt)
    assert_equal "Sample Grocer", receipt.reload.merchant_name, "a stray job leaves an extracted receipt alone"

    Receipts::RequestOcr.read_again(receipt)
    ReceiptOcrJob.perform_now(receipt)

    receipt.reload
    assert receipt.extracted?
    assert_equal "Second Read", receipt.merchant_name
    assert_equal [ "Bread" ], receipt.items.map(&:name)
    assert_nil receipt.ocr_requested_at
  end

  test "a stray job leaves a failed receipt failed: only a request reads it again" do
    stub_ml_ocr
    receipt = receipts(:failed_receipt)

    ReceiptOcrJob.perform_now(receipt)

    assert receipt.reload.failed?
    assert_equal "unsupported_media_type", receipt.ocr_error["code"]
    assert_empty ml_requests(:ocr)
  end

  test "a request that counts as lost no longer lets the job replace a read result" do
    stub_ml_ocr
    receipt = receipts(:corner_receipt)
    receipt.update_columns(ocr_requested_at: (Receipt::OCR_REQUEST_LOST_AFTER + 1.hour).ago)

    ReceiptOcrJob.perform_now(receipt)

    assert receipt.reload.extracted?
    assert_equal 3, receipt.items.count
    assert_empty ml_requests(:ocr)
  end

  test "a request for a receipt accepted in the meantime is dropped without reading it" do
    stub_ml_ocr
    receipt = receipts(:market_receipt)
    receipt.update_columns(ocr_requested_at: Time.current)

    ReceiptOcrJob.perform_now(receipt)

    assert_nil receipt.reload.ocr_requested_at
    assert receipt.reviewed?
    assert_empty ml_requests(:ocr)
  end

  # --- live updates (Receipts::LiveUpdate)

  test "the receipt's page and the list are refreshed when the job starts and when it finishes" do
    receipt = new_receipt
    during = nil
    stub_request(:post, ml_url("/ocr")).to_return do
      during = capture_turbo_stream_broadcasts(receipt).size
      { status: 200, body: JSON.generate(ml_ocr_body) }
    end

    ReceiptOcrJob.perform_now(receipt)

    assert_equal 1, during, "one refresh when the job starts, before the service answers"
    assert_turbo_stream_broadcasts receipt, count: 2
    assert_turbo_stream_broadcasts Receipts::LiveUpdate::STREAM, count: 2
  end

  test "the receipt's page is refreshed when the job fails" do
    stub_ml_error(:ocr, status: 422, code: "too_many_images", message: "Send at most 3 files, got 4.")
    receipt = new_receipt

    ReceiptOcrJob.perform_now(receipt)

    assert_turbo_stream_broadcasts receipt, count: 2
  end
end

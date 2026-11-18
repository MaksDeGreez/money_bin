require "test_helper"
require_relative "../../support/ocr_batch_helpers"

class OcrBatches::SubmitTest < ActiveSupport::TestCase
  include OcrBatchHelpers
  include ActiveJob::TestHelper

  setup do
    @receipts = [ batch_receipt, batch_receipt ]
    @batch = held_batch(@receipts, state: "pending")
  end

  test "sends the held receipts with their keys and records the provider's batch" do
    stub_ml_batch_create(id: "batch_t1")

    assert_equal :submitted, OcrBatches::Submit.call(@batch)

    @batch.reload
    assert @batch.running?
    assert_equal "batch_t1", @batch.provider_batch_id
    assert_equal "Anthropic", @batch.provider
    assert_equal "example/vision-model", @batch.model
    assert_equal BigDecimal("0.0025"), @batch.estimated_cost_usd
    assert_not_nil @batch.submitted_at
    assert @batch.next_check_at > Time.current
    manifest = JSON.parse(multipart_parts(ml_batch_requests(:post, "/ocr/batches").sole).first[:body])
    assert_equal @batch.entries.map(&:custom_id), manifest.map { |entry| entry["key"] }
    assert @receipts.all? { |receipt| receipt.reload.in_ocr_batch? }
  end

  test "a batch that is not pending is left alone" do
    @batch.update!(state: "submitting")
    assert_equal :skipped, OcrBatches::Submit.call(@batch)
    assert_not_requested :post, ml_url("/ocr/batches")
  end

  test "a receipt a person took over before sending is not sent" do
    Receipts::EnterByHand.call(@receipts.first)
    stub_ml_batch_create

    OcrBatches::Submit.call(@batch)

    manifest = JSON.parse(multipart_parts(ml_batch_requests(:post, "/ocr/batches").sole).first[:body])
    assert_equal [ key_of(@batch, @receipts.second) ], manifest.map { |entry| entry["key"] }
    assert_equal "superseded", @batch.entries.find_by!(receipt: @receipts.first).state
  end

  test "a batch whose receipts all left is finished without sending" do
    @receipts.each { |receipt| Receipts::EnterByHand.call(receipt) }
    assert_equal :empty, OcrBatches::Submit.call(@batch)
    assert @batch.reload.finished?
    assert_not_requested :post, ml_url("/ocr/batches")
  end

  test "a receipt whose photo is gone fails as a read one at a time would" do
    @receipts.first.images.first.blob.service.delete(@receipts.first.images.first.blob.key)
    stub_ml_batch_create

    OcrBatches::Submit.call(@batch)

    receipt = @receipts.first.reload
    assert receipt.failed?
    assert_equal "image_missing", receipt.ocr_error["code"]
    assert_nil receipt.ocr_batch_id
    assert_equal "failed", @batch.entries.find_by!(receipt:).state
  end

  test "nothing reached the provider: tried again later, then given up" do
    stub_ml_batch_error(:post, "/ocr/batches", status: 503, code: "openrouter_rate_limited")

    assert_equal :retry_later, OcrBatches::Submit.call(@batch)
    @batch.reload
    assert @batch.pending?
    assert_equal 1, @batch.submit_attempts
    assert_equal "openrouter_rate_limited", @batch.check_error_code
    assert @batch.next_check_at > 30.seconds.from_now

    @batch.update!(submit_attempts: OcrBatches::Submit::RETRY_WAITS.size)
    assert_equal :failed, OcrBatches::Submit.call(@batch)
    assert @batch.reload.failed?
    assert @receipts.none? { |receipt| receipt.reload.in_ocr_batch? }
    assert_equal [ "released" ], @batch.entries.map(&:state).uniq
  end

  test "an unreachable service is tried again" do
    stub_request(:post, ml_url("/ocr/batches")).to_raise(Errno::ECONNREFUSED)
    assert_equal :retry_later, OcrBatches::Submit.call(@batch)
    assert @batch.reload.pending?
  end

  test "a refusal for good fails the batch with the reason and releases its receipts" do
    stub_ml_batch_error(:post, "/ocr/batches", status: 424, code: "openrouter_batch_zdr_required",
      message: "OpenRouter refused the batch: the account's privacy settings require zero data retention.")

    assert_equal :failed, OcrBatches::Submit.call(@batch)

    @batch.reload
    assert @batch.failed?
    assert_equal "openrouter_batch_zdr_required", @batch.error_code
    assert_includes @batch.error_message, "privacy settings"
    @receipts.each do |receipt|
      receipt.reload
      assert receipt.uploaded?, "a released receipt is back as it was"
      assert_nil receipt.ocr_batch_id
    end
  end

  test "batch mode switched off in the service fails the batch" do
    stub_ml_batch_error(:post, "/ocr/batches", status: 501, code: "openrouter_batch_not_allowed")
    assert_equal :failed, OcrBatches::Submit.call(@batch)
    assert_equal "openrouter_batch_not_allowed", @batch.reload.error_code
  end

  test "a lost answer makes the batch unknown and releases its receipts" do
    stub_request(:post, ml_url("/ocr/batches")).to_raise(Net::ReadTimeout)
    assert_equal :unknown, OcrBatches::Submit.call(@batch)
    assert @batch.reload.unknown?
    assert_includes @batch.error_message, "OpenRouter's logs"
    assert @receipts.none? { |receipt| receipt.reload.in_ocr_batch? }

    other = held_batch([ batch_receipt ], state: "pending", provider_batch_id: nil)
    stub_ml_batch_error(:post, "/ocr/batches", status: 504, code: "openrouter_batch_submit_unknown")
    assert_equal :unknown, OcrBatches::Submit.call(other)
  end

  test "too large: half of the receipts move to a new pending batch" do
    stub_ml_batch_error(:post, "/ocr/batches", status: 413, code: "batch_too_large")

    assert_equal :split, OcrBatches::Submit.call(@batch)

    @batch.reload
    other = OcrBatch.where.not(id: [ @batch.id ]).order(:id).last
    assert @batch.pending?
    assert other.pending?
    assert_equal [ @receipts.first.id ], @batch.entries.map(&:receipt_id)
    assert_equal [ @receipts.second.id ], other.entries.map(&:receipt_id)
    assert_equal [ 1, 1 ], [ @batch.receipts_count, other.receipts_count ]
    assert_equal other.id, @receipts.second.reload.ocr_batch_id
    assert_equal [ 1 ], other.entries.map(&:position)
  end

  test "one receipt that is still too large fails" do
    @receipts.second.reload
    Receipts::EnterByHand.call(@receipts.second)
    stub_ml_batch_error(:post, "/ocr/batches", status: 413, code: "batch_too_large")

    assert_equal :failed, OcrBatches::Submit.call(@batch)
    assert_equal "batch_too_large", @batch.reload.error_code
  end

  test "only a connection that never opened is tried again; one cut after sending is unknown" do
    { Errno::ECONNREFUSED => :retry_later, Net::OpenTimeout => :retry_later, SocketError => :retry_later,
      EOFError => :unknown, Errno::ECONNRESET => :unknown, Errno::EPIPE => :unknown, Net::ReadTimeout => :unknown }
      .each do |failure, outcome|
        batch = held_batch([ batch_receipt ], state: "pending")
        stub_request(:post, ml_url("/ocr/batches")).to_raise(failure)
        assert_equal outcome, OcrBatches::Submit.call(batch), failure.name
        WebMock.reset!
      end
  end

  test "a server error is tried again only when its code says nothing went out" do
    { [ 503, "openrouter_rate_limited" ] => :retry_later, [ 502, "openrouter_unreachable" ] => :retry_later,
      [ 503, "openrouter_catalogue_unavailable" ] => :retry_later, [ 500, "internal_error" ] => :unknown,
      [ 502, "openrouter_upstream_error" ] => :unknown, [ 504, "openrouter_batch_submit_unknown" ] => :unknown,
      [ 501, "openrouter_batch_not_allowed" ] => :failed }.each do |(status, code), outcome|
      batch = held_batch([ batch_receipt ], state: "pending")
      stub_ml_batch_error(:post, "/ocr/batches", status:, code:)
      assert_equal outcome, OcrBatches::Submit.call(batch), code
      WebMock.reset!
    end
  end

  test "a photo over the provider's inline limit fails its receipt only; the rest are sent again" do
    key = key_of(@batch, @receipts.second)
    stub_ml_batch_error(:post, "/ocr/batches", status: 422, code: "batch_image_too_large",
      message: "A photo of receipt key #{key} is larger than the batch provider takes inline.")

    assert_equal :retry_later, OcrBatches::Submit.call(@batch)

    assert @batch.reload.pending?
    assert @receipts.second.reload.failed?
    assert_equal "batch_image_too_large", @receipts.second.ocr_error["code"]
    assert_nil @receipts.second.ocr_batch_id
    assert @receipts.first.reload.in_ocr_batch?
    assert_equal %w[waiting failed], @batch.entries.map(&:state)
  end

  test "a submission the poller gave up on meanwhile keeps the provider's id, so it is deleted" do
    stub_request(:post, ml_url("/ocr/batches")).to_return do
      @batch.reload.release!("unknown", "submit_unknown", "given up")
      { status: 202, body: JSON.generate(ml_batch_status_body("batch_late1")), headers: { "Content-Type" => "application/json" } }
    end

    assert_equal :stale, OcrBatches::Submit.call(@batch)

    @batch.reload
    assert @batch.failed?
    assert_equal "submit_late", @batch.error_code
    assert_equal "batch_late1", @batch.provider_batch_id
    assert @batch.awaiting_deletion?
    assert @receipts.none? { |receipt| receipt.reload.in_ocr_batch? }
  end
end

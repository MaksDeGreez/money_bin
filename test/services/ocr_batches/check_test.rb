require "test_helper"
require_relative "../../support/ocr_batch_helpers"

class OcrBatches::CheckTest < ActiveSupport::TestCase
  include OcrBatchHelpers
  include ActiveJob::TestHelper

  setup do
    @receipts = [ batch_receipt, batch_receipt, batch_receipt ]
    @batch = held_batch(@receipts)
    @a, @b, @c = @receipts.map { |receipt| key_of(@batch, receipt) }
  end

  def check(batch = @batch)
    OcrBatches::Check.call(batch.reload)
    batch.reload
  end

  test "a running batch is checked again later, with a growing wait" do
    stub_ml_batch_status("batch_t1", state: "running", cost_usd: "0.0001")

    check

    assert @batch.running?
    assert_equal 1, @batch.checks
    assert_equal BigDecimal("0.0001"), @batch.cost_usd
    assert_equal "in_progress", @batch.provider_status
    assert_in_delta 90, @batch.next_check_at - @batch.last_checked_at, 1
    assert_equal 1.minute, OcrBatches::Check.interval(0)
    assert_equal 15.minutes, OcrBatches::Check.interval(30)
  end

  test "the whole life: completed, stored as a read one at a time stores it, deleted upstream" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(@a), ml_batch_ok(@b, cost: "0.1"), ml_batch_ok(@c) ], cost: "0.000000000123")
    stub_ml_batch_delete("batch_t1")
    with_env("CATEGORISE_BACKEND" => "stub") do
      assert_enqueued_jobs 3, only: ReceiptCategoriseJob do
        check
      end
    end

    assert @batch.finished?
    assert_equal BigDecimal("0.000000000123"), @batch.cost_usd
    assert_equal "deleted", @batch.upstream_deletion
    assert_not_nil @batch.deleted_upstream_at
    assert_equal [ "applied" ], @batch.entries.map(&:state).uniq
    assert_equal BigDecimal("0.1"), @batch.entries.find_by!(custom_id: @b).cost_usd

    expected = ml_batch_ok(@a)[:ocr].deep_stringify_keys
    @receipts.each do |receipt|
      receipt.reload
      assert receipt.extracted?
      assert_nil receipt.ocr_batch_id
      assert_equal "Sample Grocer", receipt.merchant_name
      assert_equal BigDecimal("117.40"), receipt.total
      assert_equal [ "Oat milk 1 l", "Apples" ], receipt.items.map(&:name)
      assert_equal "example/vision-model", receipt.ocr_model_name
      assert_equal "example/vision-model-20260101", receipt.ocr_model_version
      assert_equal "abc123def456", receipt.ocr_prompt_version
    end
    assert_equal expected, @receipts.first.reload.ocr_raw
    assert_not OcrBatch.followed.exists?(@batch.id)
  end

  test "with suggestions switched off no categorise job is queued" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(@a), ml_batch_ok(@b), ml_batch_ok(@c) ])
    stub_ml_batch_delete("batch_t1")
    with_env("CATEGORISE_BACKEND" => "off") do
      assert_no_enqueued_jobs(only: ReceiptCategoriseJob) { check }
    end
  end

  test "partial failure: a parse failure goes to the normal queue, other errors fail the receipt" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [
      ml_batch_ok(@a),
      ml_batch_error(@b, "ocr_parse_failed", message: "The answer was not valid receipt JSON."),
      ml_batch_error(@c, "openrouter_batch_refused", retry_sync: false, message: "Refused.")
    ])
    stub_ml_batch_delete("batch_t1")

    assert_enqueued_jobs 1, only: ReceiptOcrJob do
      check
    end

    assert @batch.finished?
    states = @batch.entries.to_h { |entry| [ entry.custom_id, entry.state ] }
    assert_equal({ @a => "applied", @b => "sync_queued", @c => "failed" }, states)
    assert @receipts.first.reload.extracted?
    second = @receipts.second.reload
    assert second.uploaded?
    assert second.ocr_pending?, "queued for a read one at a time"
    third = @receipts.third.reload
    assert third.failed?
    assert_equal({ "code" => "openrouter_batch_refused", "message" => "Refused." }, third.ocr_raw["error"])
  end

  test "a request error that a read one at a time may fix says so" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(@a), ml_batch_ok(@b) ])
    stub_ml_batch_delete("batch_t1")

    check

    third = @receipts.third.reload
    assert third.failed?
    assert_equal "batch_result_missing", third.ocr_error["code"]
    assert_includes third.ocr_error["message"], "Read again"
  end

  test "above the hand-over limit, parse failures fail instead of being read again at full price" do
    assert_equal 5, OcrBatches::ApplyResults.handoff_limit(3)
    assert_equal 10, OcrBatches::ApplyResults.handoff_limit(100)
    @batch.entries.first(2).each { |entry| entry.update!(state: "sync_queued", resolved_at: Time.current) }
    results = MlClient::BatchResults.new(body: {}, batch: nil, results: [ ml_batch_error(@c, "ocr_parse_failed") ].map(&:deep_stringify_keys))

    with_singleton_method(OcrBatches::ApplyResults, :handoff_limit, ->(_receipts) { 2 }) do
      OcrBatches::ApplyResults.call(@batch, results)
    end

    assert_equal "failed", @batch.entries.find_by!(custom_id: @c).state
    assert @receipts.third.reload.failed?
  end

  test "a person who entered the receipt by hand meanwhile keeps their work" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(@a), ml_batch_ok(@b), ml_batch_ok(@c) ])
    stub_ml_batch_delete("batch_t1")
    typed = @receipts.first
    Receipts::EnterByHand.call(typed)
    typed.reload.update!(merchant_name: "Typed by a person")

    check

    typed.reload
    assert typed.extracted?
    assert typed.entered_by_hand?
    assert_equal "Typed by a person", typed.merchant_name
    assert_empty typed.items
    assert_equal "superseded", @batch.entries.find_by!(custom_id: @a).state
    assert_equal "applied", @batch.entries.find_by!(custom_id: @b).state
  end

  test "a person's edit racing the poll: the hold is checked under the row lock" do
    results = MlClient::BatchResults.new(body: {}, batch: nil, results: [ ml_batch_ok(@a) ].map(&:deep_stringify_keys))
    # The person enters it by hand after the results were fetched and before this entry is stored.
    Receipts::EnterByHand.call(@receipts.first)

    OcrBatches::ApplyResults.call(@batch, results)

    assert @receipts.first.reload.entered_by_hand?
    assert_equal "superseded", @batch.entries.find_by!(custom_id: @a).state
  end

  test "two polls do the work once" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(@a), ml_batch_ok(@b), ml_batch_ok(@c) ])
    stub_ml_batch_delete("batch_t1")
    results = MlClient.new.ocr_batch_results("batch_t1")

    OcrBatches::ApplyResults.call(@batch, results)
    item_ids = @receipts.map { |receipt| receipt.reload.items.ids }
    second = OcrBatches::ApplyResults.call(@batch, results)

    assert_empty second
    assert_equal item_ids, @receipts.map { |receipt| receipt.reload.items.ids }
    check
    check
    assert_requested :delete, ml_url("/ocr/batches/batch_t1"), times: 1
    # Once fetched above, once by the first check; the second check found the batch finished and asked nothing.
    assert_equal 2, ml_batch_requests(:get, "/ocr/batches/batch_t1/results").size
    assert_equal 1, ml_batch_requests(:get, "/ocr/batches/batch_t1").size
  end

  test "a poll that dies half way loses nothing and applies nothing twice" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(@a), ml_batch_ok(@b), ml_batch_ok(@c) ])
    stub_ml_batch_delete("batch_t1")
    second_id = @receipts.second.id
    original = Receipts::ApplyOcr.method(:call)
    dying = lambda do |receipt, result|
      raise SignalException, "TERM" if receipt.id == second_id

      original.call(receipt, result)
    end

    with_singleton_method(Receipts::ApplyOcr, :call, dying) do
      assert_raises(SignalException) { check }
    end
    @batch.reload
    assert @batch.applying?
    assert_equal %w[applied waiting waiting], @batch.entries.map(&:state)
    assert @receipts.second.reload.uploaded?
    assert @receipts.second.in_ocr_batch?
    first_items = @receipts.first.reload.items.ids

    check

    assert @batch.finished?
    assert_equal %w[applied] * 3, @batch.entries.map(&:state)
    assert_equal first_items, @receipts.first.reload.items.ids
    assert @receipts.all? { |receipt| receipt.reload.extracted? }
  end

  test "an error storing one entry is reported, that receipt released, the others stored" do
    stub_ml_batch_status("batch_t1", state: "completed")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(@a), ml_batch_ok(@b), ml_batch_ok(@c) ])
    stub_ml_batch_delete("batch_t1")
    second_id = @receipts.second.id
    original = Receipts::ApplyOcr.method(:call)
    broken = ->(receipt, result) { receipt.id == second_id ? raise(ArgumentError, "a bug") : original.call(receipt, result) }

    with_singleton_method(Receipts::ApplyOcr, :call, broken) { check }

    assert @batch.finished?
    assert_equal %w[applied released applied], @batch.entries.map(&:state)
    assert_equal "internal_error", @batch.entries.second.error_code
    assert @receipts.second.reload.uploaded?
    assert_nil @receipts.second.ocr_batch_id
  end

  test "an expired batch releases its receipts and is deleted upstream" do
    stub_ml_batch_status("batch_t1", state: "expired",
      error: { code: "batch_expired", message: "The provider did not finish the batch before it expired." })
    stub_ml_batch_delete("batch_t1", upstream_status: "not_applicable")

    check

    assert @batch.failed?
    assert_equal "batch_expired", @batch.error_code
    assert_equal "not_applicable", @batch.upstream_deletion
    assert_equal [ "released" ], @batch.entries.map(&:state).uniq
    @receipts.each do |receipt|
      receipt.reload
      assert receipt.uploaded?
      assert_nil receipt.ocr_batch_id
    end
  end

  test "a failed batch that refused inline images says so in its own words" do
    stub_ml_batch_status("batch_t1", state: "failed",
      error: { code: "openrouter_batch_inline_images_refused", message: "Photos are never put on a public URL." })
    stub_ml_batch_delete("batch_t1")

    check

    assert_equal "openrouter_batch_inline_images_refused", @batch.error_code
    assert @receipts.none? { |receipt| receipt.reload.in_ocr_batch? }
  end

  test "a batch OpenRouter no longer has is released and counted as gone" do
    stub_ml_batch_error(:get, "/ocr/batches/batch_t1", status: 404, code: "batch_not_found")

    check

    assert @batch.failed?
    assert_equal "gone", @batch.upstream_deletion
    assert_not OcrBatch.followed.exists?(@batch.id)
  end

  test "a submission that died mid-send becomes unknown once stale" do
    stuck = held_batch([ batch_receipt ], state: "submitting", provider_batch_id: nil, submit_started_at: 1.minute.ago)
    check(stuck)
    assert stuck.submitting?

    stuck.update!(submit_started_at: 1.hour.ago)
    check(stuck)
    assert stuck.unknown?
    assert_equal "submit_unknown", stuck.error_code
  end

  test "a deletion that fails is tried again by the poller, not lost" do
    @batch.update!(state: "finished", finished_at: Time.current)
    stub_ml_batch_error(:delete, "/ocr/batches/batch_t1", status: 501, code: "openrouter_batch_not_allowed",
      message: "Batch mode is off.")

    OcrBatches::Poll.call

    @batch.reload
    assert @batch.awaiting_deletion?
    assert_equal "openrouter_batch_not_allowed", @batch.check_error_code
    assert @batch.next_check_at >= 4.minutes.from_now
    assert OcrBatch.followed.exists?(@batch.id)
  end

  test "the poller records a failed check and goes on with the other batches" do
    other = held_batch([ batch_receipt ], provider_batch_id: "batch_t2")
    stub_request(:get, ml_url("/ocr/batches/batch_t1")).to_raise(Errno::ECONNREFUSED)
    stub_ml_batch_status("batch_t2", state: "running")

    assert_equal 2, OcrBatches::Poll.call

    assert_equal "ml_unreachable", @batch.reload.check_error_code
    assert @batch.running?
    assert_equal 1, other.reload.checks
    assert_nil other.check_error_code
  end

  test "a pending batch that is due is handed to the submitter" do
    pending = held_batch([ batch_receipt ], state: "pending")
    stub_ml_batch_status("batch_t1", state: "running")

    assert_enqueued_with(job: OcrBatchSubmitJob) { OcrBatches::Poll.call }
    assert pending.reload.pending?
  end
end

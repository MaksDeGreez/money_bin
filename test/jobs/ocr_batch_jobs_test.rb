require "test_helper"
require_relative "../support/ocr_batch_helpers"

class OcrBatchJobsTest < ActiveJob::TestCase
  include OcrBatchHelpers

  setup { @cache = ActiveSupport::Cache::MemoryStore.new }

  def chain
    @cache.read(OcrBatchPollJob::CACHE_KEY)
  end

  test "nothing to follow: no chain is started" do
    assert_no_enqueued_jobs { assert_not OcrBatchPollJob.ensure_scheduled(cache: @cache) }
  end

  test "a followed batch starts one chain, and a live chain is left alone" do
    held_batch([ batch_receipt ])

    assert_enqueued_jobs(1, only: OcrBatchPollJob) { assert OcrBatchPollJob.ensure_scheduled(cache: @cache) }
    assert_no_enqueued_jobs { assert_not OcrBatchPollJob.ensure_scheduled(cache: @cache) }
  end

  test "a chain that is overdue by more than the grace is started again" do
    held_batch([ batch_receipt ])
    @cache.write(OcrBatchPollJob::CACHE_KEY, { token: "old", due_at: 20.minutes.ago })

    assert_enqueued_jobs(1, only: OcrBatchPollJob) { OcrBatchPollJob.ensure_scheduled(cache: @cache) }
    assert_not_equal "old", chain[:token]
  end

  test "a run polls and queues the next run for when a batch is due, within the limits" do
    batch = held_batch([ batch_receipt ])
    stub_ml_batch_status("batch_t1", state: "running")
    @cache.write(OcrBatchPollJob::CACHE_KEY, { token: "t1", due_at: Time.current })

    freeze_time do
      assert_enqueued_with(job: OcrBatchPollJob, args: [ "t1" ], at: 90.seconds.from_now) do
        OcrBatchPollJob.new.perform("t1", cache: @cache)
      end
      assert_equal 1, batch.reload.checks
      assert_equal 90.seconds.from_now, chain[:due_at]
    end
  end

  test "a job of a retired chain does nothing" do
    held_batch([ batch_receipt ])
    @cache.write(OcrBatchPollJob::CACHE_KEY, { token: "new", due_at: Time.current })

    assert_no_enqueued_jobs { OcrBatchPollJob.new.perform("old", cache: @cache) }
    assert_not_requested :get, ml_url("/ocr/batches/batch_t1")
  end

  test "the chain ends when nothing is followed any more" do
    @cache.write(OcrBatchPollJob::CACHE_KEY, { token: "t1", due_at: Time.current })
    assert_no_enqueued_jobs { OcrBatchPollJob.new.perform("t1", cache: @cache) }
    assert_nil chain
  end

  test "a run while another holds the lock checks nothing" do
    held_batch([ batch_receipt ])
    with_singleton_method(OcrBatches::Exclusive, :run, ->(_name) { false }) do
      OcrBatchPollJob.new.perform("t1", cache: @cache)
    end
    assert_not_requested :get, ml_url("/ocr/batches/batch_t1")
  end

  test "the exclusive lock lets one run in at a time" do
    inner = nil
    outer = OcrBatches::Exclusive.run(:test) do
      # Another database session (the tests pin the pool to one connection).
      other = PG.connect(ActiveRecord::Base.lease_connection.raw_connection.conninfo_hash.compact)
      key = Zlib.crc32("money_bin:ocr_batches:test")
      inner = other.exec("SELECT pg_try_advisory_lock(#{key}) AS locked").first["locked"]
      other.close
    end
    assert outer
    assert_equal "f", inner
  end

  test "the submit job sends one pending batch and queues itself for the next" do
    first = held_batch([ batch_receipt ], state: "pending")
    second = held_batch([ batch_receipt ], state: "pending")
    stub_ml_batch_create(id: "batch_s1")

    assert_enqueued_jobs(1, only: OcrBatchSubmitJob) { OcrBatchSubmitJob.perform_now }

    assert first.reload.running?
    assert second.reload.pending?
  end

  test "the submit job leaves a batch that waits for its retry" do
    waiting = held_batch([ batch_receipt ], state: "pending")
    waiting.update!(next_check_at: 5.minutes.from_now)

    OcrBatchSubmitJob.perform_now

    assert waiting.reload.pending?
    assert_not_requested :post, ml_url("/ocr/batches")
  end
end

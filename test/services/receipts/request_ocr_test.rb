require "test_helper"

module Receipts
  class RequestOcrTest < ActiveJob::TestCase
    def queued_ids
      enqueued_jobs.select { |job| job["job_class"] == "ReceiptOcrJob" }
        .map { |job| GlobalID::Locator.locate(job["arguments"].first["_aj_globalid"]).id }
    end

    test "first_read queues an unread receipt once and records the request" do
      receipt = receipts(:new_receipt)

      freeze_time do
        assert_equal [ receipt.id ], RequestOcr.first_read(receipt)
        assert_equal Time.current, receipt.reload.ocr_requested_at
      end
      assert_equal [], RequestOcr.first_read(receipt)
      assert_equal [ receipt.id ], queued_ids
    end

    test "first_read queues nothing that was read, is being read or failed" do
      receipts(:new_receipt).update_columns(status: "processing")

      %i[new_receipt corner_receipt market_receipt failed_receipt].each do |name|
        assert_equal [], RequestOcr.first_read(receipts(name)), name
      end
      assert_empty queued_ids
    end

    test "read_again queues a failed or an extracted receipt, never a reviewed or an unread one" do
      assert_equal [ receipts(:failed_receipt).id ], RequestOcr.read_again(receipts(:failed_receipt))
      assert_equal [ receipts(:corner_receipt).id ], RequestOcr.read_again(receipts(:corner_receipt))
      assert_equal [], RequestOcr.read_again(receipts(:market_receipt))
      assert_equal [], RequestOcr.read_again(receipts(:new_receipt))

      assert_equal [ receipts(:failed_receipt).id, receipts(:corner_receipt).id ], queued_ids
      assert_nil receipts(:market_receipt).reload.ocr_requested_at
    end

    test "read_again takes a receipt stuck in processing, not one being read now" do
      receipt = receipts(:new_receipt)
      receipt.update_columns(status: "processing", updated_at: 10.minutes.ago)
      assert_equal [], RequestOcr.read_again(receipt)

      receipt.update_columns(updated_at: (Receipt::OCR_STUCK_AFTER + 1.minute).ago)
      assert_equal [ receipt.id ], RequestOcr.read_again(receipt)
      assert receipt.reload.ocr_stuck?
    end

    test "read_all leaves a failed receipt with items from an earlier read alone" do
      receipts(:failed_receipt).items.create!(position: 1, name: "Bread", amount: BigDecimal("30.00"))

      assert_equal [ receipts(:new_receipt).id ], RequestOcr.read_all(Receipt.all)
      assert_equal [ receipts(:failed_receipt).id ], RequestOcr.read_again(receipts(:failed_receipt)), "it can still be read again by hand"
    end

    test "a request uses the receipt's current row, not a stale copy" do
      stale = Receipt.find(receipts(:corner_receipt).id)
      receipts(:corner_receipt).update_columns(status: "reviewed", transaction_id: transactions(:snack).id)

      assert_equal [], RequestOcr.read_again(stale)
      assert_empty queued_ids
    end

    test "read_all queues the unread and failed receipts of the relation in its order, skipping waiting ones" do
      receipts(:new_receipt).update_columns(created_at: 1.day.ago)
      # A failed receipt whose request is already waiting (written past the model: it needs no photo here).
      Receipt.insert_all!([ { status: "failed", sha256: "a" * 64, ocr_requested_at: 1.hour.ago } ])

      ids = RequestOcr.read_all(Receipt.newest_first)

      assert_equal [ receipts(:new_receipt).id, receipts(:failed_receipt).id ], ids
      assert_equal ids, queued_ids
      assert_equal [], RequestOcr.read_all(Receipt.all)
    end

    test "a request older than a day counts as lost and may be made again" do
      receipt = receipts(:new_receipt)
      receipt.update_columns(ocr_requested_at: (RequestOcr::STALE_AFTER + 1.minute).ago)

      assert_equal [ receipt.id ], RequestOcr.first_read(receipt)
    end

    test "when the queue cannot be reached the request is taken back" do
      receipt = receipts(:new_receipt)

      with_singleton_method(ReceiptOcrJob.queue_adapter, :enqueue, ->(*) { raise RedisClient::CannotConnectError, "down" }) do
        assert_raises(RequestOcr::QueueUnavailable) { RequestOcr.first_read(receipt) }
      end

      assert_nil receipt.reload.ocr_requested_at
      assert_equal [ receipt.id ], RequestOcr.first_read(receipt), "it can be requested again"
    end

    test "when the queue goes away half way, only the receipts that were queued stay claimed" do
      receipts(:new_receipt).update_columns(created_at: 1.day.ago)
      pushes = 0
      flaky = lambda do |job|
        pushes += 1
        raise RedisClient::CannotConnectError, "down" if pushes > 1

        enqueued_jobs << { "job_class" => job.class.name, "arguments" => job.serialize["arguments"] }
      end

      with_singleton_method(ReceiptOcrJob.queue_adapter, :enqueue, flaky) do
        assert_raises(RequestOcr::QueueUnavailable) { RequestOcr.read_all(Receipt.newest_first) }
      end

      error = assert_raises(RequestOcr::QueueUnavailable) { raise RequestOcr::QueueUnavailable.new("x", queued: [ 1 ]) }
      assert_equal [ 1 ], error.queued
      assert receipts(:new_receipt).reload.ocr_pending?, "queued: still claimed"
      assert_nil receipts(:failed_receipt).reload.ocr_requested_at, "not queued: claim taken back"
      assert_equal 2, pushes, "after the first error the rest is not tried"
    end

    test "with the real Sidekiq adapter a successful push keeps the claim" do
      pushed = []
      fake_client = Class.new do
        define_method(:initialize) { |**| }
        define_method(:push) { |item| pushed << item; SecureRandom.hex(12) }
      end
      original_adapter = ReceiptOcrJob.queue_adapter
      ReceiptOcrJob.queue_adapter = ActiveJob::QueueAdapters::SidekiqAdapter.new
      Thread.current[:sidekiq_client_class] = fake_client
      Thread.current[:sidekiq_redis_pool] = :no_redis_in_this_test

      ids = RequestOcr.read_all(Receipt.newest_first)

      assert_equal 2, ids.size
      assert_equal ids.size, pushed.size
      assert_equal [ "receipt_ocr" ], pushed.map { |item| item["queue"] }.uniq
      assert Receipt.where(id: ids).all?(&:ocr_pending?), "a real push must not look like a failure"
    ensure
      Thread.current[:sidekiq_client_class] = nil
      Thread.current[:sidekiq_redis_pool] = nil
      ReceiptOcrJob.queue_adapter = original_adapter
    end

    test "a request updates the receipt's open pages" do
      receipt = receipts(:new_receipt)
      calls = []

      with_singleton_method(LiveUpdate, :requested, ->(ids) { calls << ids }) do
        RequestOcr.first_read(receipt)
        RequestOcr.first_read(receipt)
      end

      assert_equal [ [ receipt.id ] ], calls
    end
  end
end

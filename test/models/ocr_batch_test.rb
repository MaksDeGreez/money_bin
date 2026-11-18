require "test_helper"
require_relative "../support/ocr_batch_helpers"

class OcrBatchTest < ActiveSupport::TestCase
  include OcrBatchHelpers

  test "a running batch needs the provider's id, and ids are unique and plain" do
    batch = OcrBatch.new(state: "running", receipts_count: 1)
    assert_not batch.valid?
    assert batch.errors.include?(:provider_batch_id)

    batch.provider_batch_id = "../x"
    assert_not batch.valid?
    batch.provider_batch_id = ocr_batches(:finished_batch).provider_batch_id
    assert_not batch.valid?
    batch.provider_batch_id = "batch_new1"
    assert batch.valid?
  end

  test "the database refuses what the model refuses" do
    batch = ocr_batches(:finished_batch)
    entry = ocr_batch_entries(:finished_entry)
    [
      -> { batch.update_columns(state: "sleeping") },
      -> { OcrBatch.where(id: batch.id).update_all(cost_usd: -1) },
      -> { OcrBatch.where(id: batch.id).update_all(upstream_deletion: nil) },
      -> { entry.update_columns(custom_id: "short") },
      -> { entry.update_columns(state: "waiting") }
    ].each do |write|
      assert_raises(ActiveRecord::StatementInvalid) { OcrBatch.transaction(requires_new: true) { write.call } }
    end
  end

  test "costs keep every digit" do
    batch = ocr_batches(:finished_batch)
    batch.update!(cost_usd: BigDecimal("0.000000000000000000123456789"))
    assert_equal BigDecimal("0.000000000000000000123456789"), batch.reload.cost_usd
  end

  test "followed: unfinished, or finished and not deleted upstream yet" do
    assert_not OcrBatch.followed.exists?
    running = held_batch([ batch_receipt ])
    assert_equal [ running ], OcrBatch.followed.to_a
    running.update!(state: "finished")
    assert running.awaiting_deletion?
    assert OcrBatch.followed.exists?(running.id)
    running.update!(deleted_upstream_at: Time.current, upstream_deletion: "deleted")
    assert_not OcrBatch.followed.exists?
  end

  test "release frees the waiting receipts only, and is idempotent" do
    waiting = batch_receipt
    done = batch_receipt
    batch = held_batch([ waiting, done ])
    batch.entries.second.update!(state: "applied", resolved_at: Time.current)
    done.update_columns(ocr_batch_id: nil, status: "extracted")

    2.times { batch.release!("failed", "batch_expired", "Expired.") }

    assert batch.failed?
    assert_equal %w[released applied], batch.entries.map(&:state)
    assert_nil waiting.reload.ocr_batch_id
    assert_equal({ "waiting" => 0, "applied" => 1, "sync_queued" => 0, "failed" => 0, "released" => 1, "superseded" => 0 },
      batch.entry_counts)
  end

  test "new keys are random and URL-safe" do
    keys = Array.new(50) { OcrBatchEntry.new_custom_id }
    assert_equal 50, keys.uniq.size
    assert keys.all? { |key| key.match?(OcrBatchEntry::CUSTOM_ID_FORMAT) && key.size == 24 }
  end

  test "a receipt waiting in a batch is not pristine, so the receipt load leaves its photos alone" do
    receipt = batch_receipt
    assert receipt.pristine?
    held_batch([ receipt ])
    assert_not receipt.reload.pristine?
  end

  test "the model refuses what the database refuses" do
    batch = ocr_batches(:finished_batch)
    { checks: -1, submit_attempts: -1 }.each do |field, value|
      copy = batch.dup.tap { |record| record.provider_batch_id = "batch_copy1" }
      copy[field] = value
      assert_not copy.valid?, field
    end
    assert_not OcrBatch.new(state: "failed", receipts_count: 1, upstream_deletion: "deleted").valid?
    assert_not OcrBatch.new(state: "failed", receipts_count: 1, deleted_upstream_at: Time.current, upstream_deletion: "gone").valid?
    entry = ocr_batch_entries(:finished_entry).dup.tap { |record| record.custom_id = OcrBatchEntry.new_custom_id }
    assert_not entry.valid?, "a position is unique within its batch"
    entry.position = 2
    assert entry.valid?
    entry.assign_attributes(state: "released", followed_up_at: Time.current)
    assert_not entry.valid?
  end
end

require "test_helper"
require_relative "../support/ocr_batch_helpers"

class OcrBatchesControllerTest < ActionDispatch::IntegrationTest
  include OcrBatchHelpers
  include ActiveJob::TestHelper

  setup { sign_in_as users(:owner) }

  test "needs a signed-in session" do
    sign_out
    get ocr_batches_path
    assert_redirected_to new_session_path
  end

  test "the list shows each batch with its state, costs and a link to its receipts" do
    stub_ml_batch_capability

    get ocr_batches_path

    assert_response :success
    assert_select "h1", "OCR batches"
    assert_select "tr#ocr_batch_#{ocr_batches(:finished_batch).id}" do
      assert_select "td", text: "Finished"
      assert_select "td", text: "$0.000987654321"
      assert_select "a[href=?]", receipts_path(ocr_batch: ocr_batches(:finished_batch).id)
    end
    assert_select "tr#ocr_batch_#{ocr_batches(:expired_batch).id}", text: /did not finish the batch before it expired/
    assert_select ".callout", text: /Batch mode is on.*not zero-retention.*at most 30 days/m
  end

  test "the list says why batch mode is not available" do
    stub_ml_batch_capability(available: false, code: "openrouter_batch_not_allowed", message: "Batch mode is off.")
    get ocr_batches_path
    assert_select ".callout", text: /Batch mode is not available. Batch mode is off.*openrouter_batch_not_allowed/m

    Rails.cache.clear
    stub_request(:get, ml_url("/ocr/batches/capability")).to_raise(Errno::ECONNREFUSED)
    get ocr_batches_path
    assert_response :success
    assert_select ".callout", text: /ml_unreachable/
  end

  test "one batch: its numbers, what became of its receipts, and why" do
    batch = ocr_batches(:expired_batch)

    get ocr_batch_path(batch)

    assert_response :success
    assert_select "h1", "Batch ##{batch.id}"
    assert_select ".callout-danger", text: /expired/
    assert_select "dd", text: /Deleted at OpenRouter/
    assert_select "td", text: "Released"
    assert_select "a[href=?]", receipt_path(receipts(:failed_receipt))
  end

  test "the offer appears only when the service has batch mode and the filter has receipts to send" do
    stub_ml_batch_capability

    get offer_ocr_batches_path(status: "uploaded")

    assert_response :success
    assert_select "turbo-frame#ocr_batch_offer a[href=?]", new_ocr_batch_path(status: "uploaded"), text: /Read in a batch \(1\)/

    Rails.cache.clear
    stub_ml_batch_capability(available: false, code: "openrouter_batch_not_allowed", message: "Off.")
    get offer_ocr_batches_path(status: "uploaded")
    assert_select "turbo-frame#ocr_batch_offer a", count: 0

    get offer_ocr_batches_path(status: "reviewed")
    assert_select "turbo-frame#ocr_batch_offer a", count: 0
  end

  test "the confirmation states the count, the estimate, the wait and what the provider keeps" do
    stub_ml_batch_capability
    stub_ml_batch_estimate(cost: "0.0123", cost_max: "0.0456")

    get new_ocr_batch_path(status: "uploaded")

    assert_response :success
    assert_select "dd", text: /1 receipt \(1 photo\)/
    assert_select "dd", text: /about \$0.0123/
    assert_select "dd", text: /up to a day/
    assert_select "dd", text: /keep them and the\s+answers until the batch is deleted \(at most 30 days\)/
    assert_select "form[action=?] button", ocr_batches_path(status: "uploaded"), text: /Send 1 receipt/
    assert_equal({ "receipts" => 1, "images" => 1 }, JSON.parse(ml_batch_requests(:post, "/ocr/batches/estimate").sole.body))
  end

  test "the confirmation without batch mode sends nothing" do
    stub_ml_batch_capability(available: false, code: "openrouter_batch_not_allowed", message: "Batch mode is off.")
    get new_ocr_batch_path
    assert_response :success
    assert_select "form[action^=?]", ocr_batches_path, count: 0
  end

  test "sending claims the filter's receipts in batches and starts the submitter" do
    stub_ml_batch_capability
    receipt = receipts(:new_receipt)

    assert_enqueued_with(job: OcrBatchSubmitJob) do
      post ocr_batches_path(status: "uploaded")
    end

    assert_redirected_to ocr_batches_path
    assert_match "1 receipt in 1 batch", flash[:notice]
    assert receipt.reload.in_ocr_batch?
    assert receipt.ocr_batch.pending?
  end

  test "sending without batch mode, or with nothing to send, says so" do
    stub_ml_batch_capability(available: false, code: "openrouter_batch_not_allowed", message: "Batch mode is off.")
    post ocr_batches_path(status: "uploaded")
    assert_redirected_to receipts_path(status: "uploaded")
    assert_match "Batch mode is off", flash[:alert]
    assert_not receipts(:new_receipt).reload.in_ocr_batch?

    Rails.cache.clear
    stub_ml_batch_capability
    post ocr_batches_path(status: "reviewed")
    assert_match "Nothing to send", flash[:alert]
  end

  test "check now makes the batch due and starts a new polling chain" do
    batch = held_batch([ batch_receipt ])
    batch.update!(next_check_at: 10.minutes.from_now)

    assert_enqueued_with(job: OcrBatchPollJob) { post check_ocr_batch_path(batch) }

    assert batch.reload.next_check_at <= Time.current
  end

  test "the receipts list filters by batch and asks for the offer after the page is shown" do
    batch = ocr_batches(:finished_batch)

    get receipts_path(ocr_batch: batch.id)

    assert_response :success
    assert_select "table.data-grid tbody tr", count: 1
    assert_select "tr#receipt_#{receipts(:corner_receipt).id}"
    assert_select "a[href=?]", ocr_batches_path

    get receipts_path(status: "uploaded")
    assert_select "turbo-frame#ocr_batch_offer[src=?][loading=lazy]", offer_ocr_batches_path(status: "uploaded")
  end

  test "a receipt waiting in a batch: its page says so and opening it queues nothing" do
    receipt = batch_receipt
    batch = held_batch([ receipt ])

    assert_no_enqueued_jobs(only: ReceiptOcrJob) { get receipt_path(receipt) }

    assert_response :success
    assert_select ".callout", text: /Waiting in\s+batch ##{batch.id}/
    assert_select "a[href=?]", ocr_batch_path(batch)
    assert_select "span", text: "In a batch"
    assert_nil receipt.reload.ocr_requested_at
  end

  test "read again on a failed receipt waiting in a batch is refused" do
    receipt = receipts(:failed_receipt)
    held_batch([ receipt ])

    assert_no_enqueued_jobs(only: ReceiptOcrJob) { post read_receipt_path(receipt) }

    assert_equal "Not queued: the receipt is waiting in an OCR batch.", flash[:alert]
  end

  test "the owner can release the receipts of a batch that is stuck" do
    receipt = batch_receipt
    batch = held_batch([ receipt ])

    post release_ocr_batch_path(batch)

    assert_redirected_to ocr_batch_path(batch)
    assert batch.reload.failed?
    assert_equal "released_by_owner", batch.error_code
    assert_nil receipt.reload.ocr_batch_id
    assert batch.awaiting_deletion?

    post release_ocr_batch_path(batch)
    assert_match "Nothing to release", flash[:alert]
  end

  test "release refuses a batch being sent, and queues the follow-ups of results already stored" do
    sending = held_batch([ batch_receipt ], state: "submitting", provider_batch_id: nil)
    post release_ocr_batch_path(sending)
    assert_match "Nothing to release", flash[:alert]
    assert sending.reload.submitting?

    stored, waiting = batch_receipt, batch_receipt
    applying = held_batch([ stored, waiting ], state: "applying", provider_batch_id: "batch_t9")
    stored.update_columns(ocr_batch_id: nil, status: "extracted")
    applying.entries.first.update!(state: "applied", resolved_at: Time.current)

    with_env("CATEGORISE_BACKEND" => "stub") do
      assert_enqueued_with(job: ReceiptCategoriseJob) { post release_ocr_batch_path(applying) }
    end
    assert_not_nil applying.entries.first.reload.followed_up_at
    assert_equal "released", applying.entries.second.state
  end
end

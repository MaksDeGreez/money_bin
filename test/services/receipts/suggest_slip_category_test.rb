require "test_helper"
require_relative "../../support/transaction_categoriser_stubs"

class Receipts::SuggestSlipCategoryTest < ActiveSupport::TestCase
  include TransactionCategoriserStubs

  # An extracted card slip: no items, one total, a merchant.
  setup do
    @receipt = receipts(:corner_receipt)
    @receipt.items.delete_all
    @receipt.update!(kind: "card_slip", merchant_name: "Invented Kiosk")
  end

  def call
    with_env("CATEGORISE_BACKEND" => "stub") { Receipts::SuggestSlipCategory.call(@receipt) }
  end

  test "a payee booked consistently before suggests its category, without asking the model" do
    @receipt.update!(merchant_name: "  CORNER   cafe ")
    lock_version = @receipt.reload.lock_version

    result = call

    assert_equal [ :suggested, PayeeHistory::CATEGORISER_NAME ], [ result.status, result.source ]
    @receipt.reload
    assert_equal categories(:cafes), @receipt.suggested_category
    assert_in_delta 2 / 2.25, @receipt.suggested_category_confidence
    assert_equal PayeeHistory::CATEGORISER_NAME, @receipt.categoriser_model_name
    assert_nil @receipt.category_id
    assert_equal lock_version, @receipt.lock_version
    assert_not_requested :post, transaction_categoriser_url
  end

  test "otherwise the local transaction categoriser, given the merchant and the total as an expense" do
    stub_categorise_transactions

    result = call

    assert_equal :suggested, result.status
    @receipt.reload
    assert_equal [ categories(:household_supplies), 0.93, "transaction-categoriser" ],
      [ @receipt.suggested_category, @receipt.suggested_category_confidence, @receipt.categoriser_model_name ]
    sent = transaction_requests.sole["transactions"].sole
    assert_equal({ "payee" => "Invented Kiosk", "merchant" => "Invented Kiosk", "amount" => "-152.5", "currency" => "UAH" }, sent)
  end

  test "a payee whose history is split or a tie leaves it to the model" do
    @receipt.update!(merchant_name: "Example Market")
    stub_categorise_transactions

    assert_equal "transaction-categoriser", call.source
    assert_nil PayeeHistory.new.lookup("Example Market")
    assert_equal categories(:cafes).id, PayeeHistory.new.lookup("corner cafe").category_id
    assert_nil PayeeHistory.new.lookup("nobody at all")
  end

  test "a failure never fails the receipt and keeps the earlier suggestion" do
    @receipt.update_columns(suggested_category_id: categories(:groceries).id, suggested_category_confidence: 0.5,
      categoriser_model_name: "transaction-categoriser")
    stub_transaction_categoriser_error(status: 501, code: "transaction_categoriser_not_configured")

    result = call

    assert_equal [ :failed, "transaction_categoriser_not_configured" ], [ result.status, result.error ]
    @receipt.reload
    assert @receipt.extracted?
    assert_equal [ categories(:groceries), "transaction_categoriser_not_configured" ], [ @receipt.suggested_category, @receipt.categoriser_error ]
  end

  test "a payee's labels taken from the model's suggestions are not its history" do
    transaction_lines(:coffee_line).update_columns(category_origin: "bulk", category_origin_probability: 0.9,
      category_origin_model_version: MODEL_VERSION)

    assert_nil PayeeHistory.new.lookup("corner cafe")
  end

  test "an ML service that is not on this machine gets nothing, and the receipt records why" do
    with_env("ML_SERVICE_URL" => "http://remote.example.test:8100") { call }

    assert_equal "ml_not_local", @receipt.reload.categoriser_error
    assert_not_requested :any, /remote\.example\.test/
  end

  test "switched off, it does nothing at all" do
    with_env("CATEGORISE_BACKEND" => "off") do
      assert_equal :off, Receipts::SuggestSlipCategory.call(@receipt).status
    end
    assert_nil @receipt.reload.suggested_category_id
    assert_nil @receipt.categorised_at
  end

  test "only an extracted card slip with a merchant" do
    @receipt.update!(merchant_name: nil)
    assert_equal :skipped, call.status
    @receipt.update!(merchant_name: "Invented Kiosk", kind: "fiscal")
    assert_equal :skipped, call.status
    assert_not_requested :post, transaction_categoriser_url
  end

  test "a category a person chose stays, and a new source then marks the slip as of unknown pre-fill" do
    @receipt.update!(category: categories(:groceries))
    @receipt.update_columns(categoriser_model_name: PayeeHistory::CATEGORISER_NAME)
    stub_categorise_transactions

    call

    @receipt.reload
    assert_equal categories(:groceries), @receipt.category
    assert_equal categories(:household_supplies), @receipt.suggested_category
    assert_equal ReceiptGroundTruth::CATEGORISER_UNKNOWN, @receipt.categoriser_model_name
  end

  test "the categorise job and the OCR job ask for a slip's suggestion" do
    stub_categorise_transactions
    with_env("CATEGORISE_BACKEND" => "stub") { ReceiptCategoriseJob.perform_now(@receipt) }
    assert_equal categories(:household_supplies), @receipt.reload.suggested_category
  end
end

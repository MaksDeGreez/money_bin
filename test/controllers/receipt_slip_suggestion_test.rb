require "test_helper"

# A card slip's own category suggestion on the receipt page (Receipts::SuggestSlipCategory).
class ReceiptSlipSuggestionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:owner)
    @receipt = receipts(:corner_receipt)
  end

  def slip_params(receipt, **changes)
    { lock_version: receipt.lock_version, kind: "card_slip", merchant_name: receipt.merchant_name, total: receipt.total.to_s("F"),
      currency: receipt.currency, remove_items: "1",
      items_attributes: receipt.items.each_with_index.to_h { |item, index| [ index.to_s, { id: item.id, _destroy: "0" } ] } }.merge(changes)
  end

  test "a save that turns a receipt into a card slip asks for the slip's suggestion" do
    with_env("CATEGORISE_BACKEND" => "stub") do
      assert_enqueued_with(job: ReceiptCategoriseJob, args: [ @receipt ]) do
        patch receipt_path(@receipt), params: { intent: "save", receipt: slip_params(@receipt) }
      end
    end
    assert @receipt.reload.card_slip?

    with_env("CATEGORISE_BACKEND" => "stub") do
      assert_no_enqueued_jobs(only: ReceiptCategoriseJob) do
        patch receipt_path(@receipt), params: { intent: "save", receipt: slip_params(@receipt.reload, merchant_name: "Corner Shop 2") }
      end
    end
  end

  test "with suggestions switched off, nothing is asked" do
    with_env("CATEGORISE_BACKEND" => "off") do
      assert_no_enqueued_jobs(only: ReceiptCategoriseJob) do
        patch receipt_path(@receipt), params: { intent: "save", receipt: slip_params(@receipt) }
      end
    end
  end

  test "the slip's suggestion can be taken with Use, and asked for again" do
    @receipt.items.delete_all
    @receipt.update_columns(kind: "card_slip", suggested_category_id: categories(:cafes).id, suggested_category_confidence: 0.89,
      categoriser_model_name: PayeeHistory::CATEGORISER_NAME)

    with_env("CATEGORISE_BACKEND" => "stub") { get receipt_path(@receipt) }

    assert_select "[data-slip-suggestion-id=?]", categories(:cafes).id.to_s do
      assert_select ".field-hint", text: /Suggested: Cafes, bars & restaurants · 89% · from this payee's history/
      assert_select "button[data-action='receipt-review#useSlipSuggestion']", text: "Use"
    end
    assert_select "button", text: /Suggest a category again/
    with_env("CATEGORISE_BACKEND" => "stub") do
      assert_enqueued_with(job: ReceiptCategoriseJob) { post suggest_categories_receipt_path(@receipt) }
    end
  end
end

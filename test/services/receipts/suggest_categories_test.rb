require "test_helper"
require_relative "../../support/ml_service_stubs"
require "turbo/broadcastable/test_helper"

class Receipts::SuggestCategoriesTest < ActiveSupport::TestCase
  include MlServiceStubs
  include Turbo::Broadcastable::TestHelper

  # An extracted receipt with three items: one the label memory knows ("RYE BREAD": the market receipt's
  # "Rye bread" was labelled groceries), two it does not.
  setup do
    @receipt = receipts(:corner_receipt)
    @receipt.items.delete_all
    @bread = @receipt.items.create!(position: 1, name: "RYE BREAD", amount: 40)
    @kebab = @receipt.items.create!(position: 2, name: "Kebab", amount: 95, category: categories(:cafes), accepted_by_user: true)
    @pills = @receipt.items.create!(position: 3, name: "Pills", amount: 60)
  end

  def call
    Receipts::SuggestCategories.call(@receipt)
  end

  test "the label memory first, the rest in one call to the ML service" do
    stub_ml_categorise([ "Kebab", "Pills" ], answers: { "Kebab" => [ [ "eating-out/takeaway-fast-food", 0.81 ] ],
      "Pills" => [ [ "household-shopping/household-supplies", 0.42 ], [ "groceries/groceries", 0.3 ] ] })

    result = call

    assert_equal [ :suggested, 1, 2, nil ], [ result.status, result.memory, result.model, result.error ]
    assert_equal [ categories(:groceries), "memory" ], [ @bread.reload.suggested_category, @bread.suggested_by ]
    assert_in_delta 2 / 2.25, @bread.confidence
    assert_equal [ categories(:takeaway), "model", 0.81 ], [ @kebab.reload.suggested_category, @kebab.suggested_by, @kebab.confidence ]
    assert_equal [ categories(:household_supplies), "model" ], [ @pills.reload.suggested_category, @pills.suggested_by ]
    request = JSON.parse(ml_requests(:categorise).sole.body)
    assert_equal [ "Kebab", "Pills" ], request["texts"]
    assert_equal "Corner Shop", request["merchant"]
    assert_equal Categories::ItemCandidates.payload.map(&:stringify_keys), request["categories"]
    @receipt.reload
    assert_equal "stub-categoriser", @receipt.categoriser_model_name
    assert_not_nil @receipt.categorised_at
    assert_nil @receipt.categoriser_error
  end

  test "a person's category is never overwritten, nor the accepted flag" do
    stub_ml_categorise([ "Kebab", "Pills" ])

    call

    @kebab.reload
    assert_equal categories(:cafes), @kebab.category
    assert @kebab.accepted_by_user
    assert_equal categories(:groceries), @kebab.suggested_category
    assert_nil @pills.reload.category
    assert_not @pills.accepted_by_user
  end

  test "the receipt's lock_version does not move: an open review form stays valid" do
    stub_ml_categorise([ "Kebab", "Pills" ])

    assert_no_changes -> { @receipt.reload.lock_version } do
      call
    end
  end

  test "when the service fails, the memory's suggestions stay, the other items keep theirs, and the error is recorded" do
    @pills.update!(suggested_category: categories(:groceries), suggested_by: "model", confidence: 0.5)
    @receipt.update_columns(categoriser_model_name: "earlier-model")
    stub_ml_error(:categorise, status: 503, code: "openrouter_rate_limited")

    result = call

    assert_equal [ :failed, "openrouter_rate_limited" ], [ result.status, result.error ]
    assert_equal "memory", @bread.reload.suggested_by
    assert_equal [ categories(:groceries), 0.5 ], [ @pills.reload.suggested_category, @pills.confidence ]
    assert_nil @kebab.reload.suggested_category
    @receipt.reload
    assert @receipt.extracted?
    assert_equal "openrouter_rate_limited", @receipt.categoriser_error
    assert_equal "earlier-model", @receipt.categoriser_model_name, "the earlier model's suggestion is still on an item"
  end

  test "an unreachable service is recorded the same way" do
    stub_request(:post, ml_url("/categorise")).to_raise(Errno::ECONNREFUSED)

    assert_equal "ml_unreachable", call.error
    assert_equal LabelMemory::CATEGORISER_NAME, @receipt.reload.categoriser_model_name
  end

  test "when the label memory filled every suggestion, the receipt names the label memory" do
    @kebab.destroy!
    @pills.destroy!

    result = call

    assert_equal [ 1, 0 ], [ result.memory, result.model ]
    assert_empty ml_requests(:categorise)
    assert_equal LabelMemory::CATEGORISER_NAME, @receipt.reload.categoriser_model_name
  end

  test "without any suggestion the receipt names no categoriser" do
    @bread.destroy!
    stub_ml_error(:categorise, status: 501, code: "backend_not_implemented")

    call

    assert_nil @receipt.reload.categoriser_model_name
  end

  test "a mix of memory and model names the model" do
    stub_ml_categorise([ "Kebab", "Pills" ], model_name: "example/vl-model")

    call

    assert_equal "example/vl-model", @receipt.reload.categoriser_model_name
  end

  test "an item renamed while the service was answering is left alone" do
    client = Object.new
    pills = @pills
    client.define_singleton_method(:categorise) do |texts, **|
      pills.update!(name: "Vitamins")
      MlClient.new.categorise(texts, categories: Categories::ItemCandidates.payload)
    end
    stub_ml_categorise([ "Kebab", "Pills" ])

    Receipts::SuggestCategories.call(@receipt, client:)

    assert_nil @pills.reload.suggested_category
    assert_equal "model", @kebab.reload.suggested_by
  end

  test "nothing is written when the receipt is no longer extracted after the call" do
    client = Object.new
    receipt = @receipt
    client.define_singleton_method(:categorise) do |texts, **|
      receipt.update_columns(status: "reviewed")
      MlClient.new.categorise(texts, categories: Categories::ItemCandidates.payload)
    end
    stub_ml_categorise([ "Kebab", "Pills" ])

    Receipts::SuggestCategories.call(@receipt, client:)

    assert @receipt.items.reload.none?(&:suggested_category_id)
    assert_nil @receipt.reload.categorised_at
  end

  test "receipts that are not extracted, and receipts without items, are skipped" do
    assert_equal :skipped, Receipts::SuggestCategories.call(receipts(:market_receipt)).status
    assert_equal :skipped, Receipts::SuggestCategories.call(receipts(:failed_receipt)).status
    @receipt.items.delete_all
    assert_equal :skipped, call.status
    assert_empty ml_requests(:categorise)
  end

  test "the receipt's page and the list are refreshed" do
    stub_ml_categorise([ "Kebab", "Pills" ])

    call

    assert_turbo_stream_broadcasts @receipt, count: 1
  end
end

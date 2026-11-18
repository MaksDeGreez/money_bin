require "test_helper"

module Api
  module V1
    class AccountsAndCategoriesControllerTest < ActionDispatch::IntegrationTest
      include OpenapiTestHelper
      include ApiRequestTestHelper

      test "accounts with their booked balances as decimal strings" do
        Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 9), amount: BigDecimal("-500"), source: :api,
          status: :draft, lines_attributes: [ { category: categories(:groceries), amount: BigDecimal("-500") } ])

        api_get api_v1_accounts_path

        assert_response :success
        assert_api_conform(200)
        assert_equal [
          { "id" => accounts(:cash_uah).id, "name" => "Cash wallet", "kind" => "cash", "currency" => "UAH", "archived" => false, "balance" => "1940.00" },
          { "id" => accounts(:card_uah).id, "name" => "Everyday card", "kind" => "debit", "currency" => "UAH", "archived" => false, "balance" => "4334.60" },
          { "id" => accounts(:savings_usd).id, "name" => "Savings USD", "kind" => "savings", "currency" => "USD", "archived" => false, "balance" => "1000.00" },
          { "id" => accounts(:old_wallet).id, "name" => "Old e-wallet", "kind" => "ewallet", "currency" => "EUR", "archived" => true, "balance" => "0.00" }
        ], json["accounts"]
      end

      test "accounts take no parameters" do
        api_get api_v1_accounts_path, params: { archived: "false" }

        assert_invalid_parameter("archived")
      end

      test "the category tree with slugs and descriptions" do
        api_get api_v1_categories_path

        assert_response :success
        assert_api_conform(200)
        eating_out = json["groups"].find { |group| group["slug"] == "eating-out" }
        assert_equal({ "id" => categories(:eating_out).id, "slug" => "eating-out", "name" => "Eating out", "position" => 2, "description" => nil },
          eating_out.except("categories"))
        assert_equal [ "eating-out/cafes-bars-restaurants", "eating-out/takeaway-fast-food" ], eating_out["categories"].pluck("slug")
        assert_equal "Takeaway, food delivery and fast food.", eating_out["categories"].last["description"]
        assert_equal Category.groups.count, json["groups"].size
      end

      test "categories take no parameters" do
        api_get api_v1_categories_path, params: { group: "eating-out" }

        assert_invalid_parameter("group")
      end
    end
  end
end

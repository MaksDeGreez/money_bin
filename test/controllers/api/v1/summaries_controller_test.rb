require "test_helper"

module Api
  module V1
    class SummariesControllerTest < ActionDispatch::IntegrationTest
      include OpenapiTestHelper
      include ApiRequestTestHelper

      OCTOBER = { from: "2026-10-01", to: "2026-10-31" }.freeze

      def book(account:, amount:, status: :confirmed, category: :groceries, on: Date.new(2026, 10, 20))
        Transaction.create!(account: accounts(account), occurred_on: on, amount: BigDecimal(amount), source: :manual, status:,
          lines_attributes: [ { category: categories(category), amount: BigDecimal(amount) } ])
      end

      def side(code, kind)
        json["currencies"].find { |entry| entry["currency"] == code }&.fetch(kind)
      end

      test "sums a range per currency in the documented shape, money as strings" do
        api_get api_v1_summary_path, params: OCTOBER

        assert_response :success
        assert_api_conform(200)
        assert_equal [ "2026-10-01", "2026-10-31" ], json.values_at("from", "to")
        assert_equal "-2225.40", side("UAH", "expenses")["total"]
        assert_equal "50000.00", side("UAH", "incomes")["total"]
        assert_no_floats(json)
      end

      test "a split transaction counts by its lines, and groups roll up their categories" do
        api_get api_v1_summary_path, params: OCTOBER

        expenses = side("UAH", "expenses")
        by_slug = expenses["by_category"].to_h { |row| [ row.dig("category", "slug"), row ] }
        assert_equal "-1000.40", by_slug.fetch("groceries/groceries")["amount"]
        assert_equal "-250.00", by_slug.fetch("household-shopping/household-supplies")["amount"]
        assert_equal "eating-out", by_slug.fetch("eating-out/cafes-bars-restaurants").dig("group", "slug")
        assert_equal "-830.00", by_slug.fetch(nil)["amount"]
        assert_nil by_slug.fetch(nil)["group"]
        assert_equal "-145.00", expenses["by_group"].find { |row| row.dig("group", "slug") == "eating-out" }["amount"]
        assert_equal [ { "month" => "2026-10", "amount" => "-2225.40" } ], expenses["by_month"].map { |month| month.slice("month", "amount") }
      end

      test "a draft leaks into no figure" do
        book(account: :card_uah, amount: "-5000.00", status: :draft)

        api_get api_v1_summary_path, params: OCTOBER

        assert_api_conform(200)
        assert_equal "-2225.40", side("UAH", "expenses")["total"]
        assert_equal 4, side("UAH", "expenses")["transactions"]
      end

      test "transfer legs leak into no figure" do
        api_get api_v1_summary_path, params: { from: "2026-10-06", to: "2026-10-07" }

        assert_api_conform(200)
        # Only the two transfers happened on those days.
        assert_equal [], json["currencies"]
      end

      test "two currencies are reported apart, never added together" do
        book(account: :savings_usd, amount: "-12.50")

        api_get api_v1_summary_path, params: OCTOBER

        assert_api_conform(200)
        assert_equal %w[UAH USD], json["currencies"].pluck("currency")
        assert_equal "-12.50", side("USD", "expenses")["total"]
        assert_equal "-2225.40", side("UAH", "expenses")["total"]
        assert_equal "0.00", side("USD", "incomes")["total"]
      end

      test "the currency filter keeps one currency" do
        book(account: :savings_usd, amount: "-12.50")

        api_get api_v1_summary_path, params: OCTOBER.merge(currency: "USD")

        assert_api_conform(200)
        assert_equal %w[USD], json["currencies"].pluck("currency")
      end

      test "from and to are required: 400 bad_request" do
        [ { from: "2026-10-01" }, { to: "2026-10-31" }, {} ].each do |params|
          api_get api_v1_summary_path, params: params

          assert_response :bad_request, params.inspect
          assert_api_response_conform(400)
          assert_equal "bad_request", json.dig("error", "code")
        end
      end

      test "a malformed or unknown value is 422 invalid_parameter" do
        {
          OCTOBER.merge(currency: "usd") => "currency",
          OCTOBER.merge(currency: "XAU") => "currency",
          OCTOBER.merge(account_id: "1") => "account_id",
          { from: "2026-10-31", to: "2026-10-01" } => "to",
          { from: "2026-02-30", to: "2026-10-01" } => "from",
          { from: "", to: "2026-10-01" } => "from"
        }.each do |params, parameter|
          api_get api_v1_summary_path, params: params

          assert_invalid_parameter(parameter)
        end
      end
    end
  end
end

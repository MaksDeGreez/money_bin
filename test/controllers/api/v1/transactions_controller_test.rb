require "test_helper"

module Api
  module V1
    class TransactionsControllerTest < ActionDispatch::IntegrationTest
      include OpenapiTestHelper
      include ApiRequestTestHelper

      def book(on: Date.new(2026, 10, 10), amount: "-10.00", category: :groceries, **attributes)
        Transaction.create!(account: accounts(:card_uah), occurred_on: on, amount: BigDecimal(amount), source: :manual,
          lines_attributes: [ { category: categories(category), amount: BigDecimal(amount) } ], **attributes)
      end

      test "lists transactions newest first, in the documented shape" do
        api_get api_v1_transactions_path

        assert_response :success
        assert_api_conform(200)
        assert_equal TransactionsQuery.new.relation.ids, json["transactions"].pluck("id")
        assert_nil json["next_cursor"]
        assert_no_floats(json)
      end

      test "a transaction carries its account, payee, lines, status and receipt" do
        api_get api_v1_transaction_path(transactions(:market_split))

        assert_api_conform(200)
        assert_equal({
          "id" => transactions(:market_split).id, "occurred_on" => "2026-10-03", "occurred_at" => "2026-10-03T18:40:00+03:00",
          "amount" => "-1250.40", "currency" => "UAH", "original_amount" => nil, "original_currency" => nil,
          "status" => "confirmed", "source" => "receipt",
          "account" => { "id" => accounts(:card_uah).id, "name" => "Everyday card", "currency" => "UAH" },
          "payee" => { "id" => payees(:example_market).id, "name" => "Example Market" },
          "merchant" => "Example Market", "comment" => nil, "bank_description" => nil, "mcc" => nil, "transfer_id" => nil,
          "has_receipt" => true, "receipt_id" => receipts(:market_receipt).id,
          "lines" => [
            { "id" => transaction_lines(:market_groceries).id, "amount" => "-1000.40", "comment" => nil,
              "category" => { "id" => categories(:groceries).id, "slug" => "groceries/groceries", "name" => "Groceries" } },
            { "id" => transaction_lines(:market_household).id, "amount" => "-250.00", "comment" => nil,
              "category" => { "id" => categories(:household_supplies).id, "slug" => "household-shopping/household-supplies",
                "name" => "Household supplies" } }
          ].sort_by { |line| line["id"] }
        }, json)
      end

      test "a transfer leg has its transfer id and no lines; a foreign-currency purchase its original amount" do
        api_get api_v1_transaction_path(transactions(:savings_in))
        assert_api_conform(200)
        assert_equal transactions(:savings_in).transfer_id, json["transfer_id"]
        assert_equal [], json["lines"]
        assert_equal "USD", json["currency"]

        api_get api_v1_transaction_path(transactions(:subscription))
        assert_api_conform(200)
        assert_equal [ "-20.00", "USD", "needs_review", false ], json.values_at("original_amount", "original_currency", "status", "has_receipt")
        assert_equal [ nil ], json["lines"].pluck("category")
      end

      test "every filter reaches the query" do
        checks = {
          { from: "2026-10-07" } => %i[savings_out savings_in],
          { to: "2026-10-01" } => %i[salary],
          { account_id: accounts(:savings_usd).id } => %i[savings_in],
          { category_id: categories(:eating_out).id } => %i[coffee snack],
          { status: "needs_review" } => %i[subscription],
          { payee_id: payees(:corner_cafe).id } => %i[coffee],
          { q: "Pastry" } => %i[snack],
          { source: "legacy" } => %i[snack]
        }
        checks.each do |params, expected|
          api_get api_v1_transactions_path, params: params

          assert_api_conform(200)
          assert_equal expected.map { |name| transactions(name).id }.sort, json["transactions"].pluck("id").sort, params.inspect
        end
      end

      test "pages are followed with next_cursor until it is null" do
        seen = []
        params = { limit: 3 }
        loop do
          api_get api_v1_transactions_path, params: params
          assert_api_conform(200)
          seen.concat(json["transactions"].pluck("id"))
          break if json["next_cursor"].nil?

          params = { limit: 3, cursor: json["next_cursor"] }
        end

        assert_equal TransactionsQuery.new.relation.ids, seen
      end

      test "the default page has 50 rows and the largest 200" do
        51.times { |day| book(on: Date.new(2026, 1, 1) + day) }

        api_get api_v1_transactions_path
        assert_equal 50, json["transactions"].size
        assert_not_nil json["next_cursor"]

        api_get api_v1_transactions_path, params: { limit: 200 }
        assert_equal Transaction.count, json["transactions"].size
        assert_nil json["next_cursor"]
      end

      test "a page costs the same number of queries whatever its size (no N+1)" do
        # The newest rows, each with a payee and a categorised line; the newest one has a receipt.
        rows = 30.times.map { |day| book(on: Date.new(2026, 12, 1) + day, comment: "Line #{day}", payee: payees(:example_market)) }
        receipts(:corner_receipt).update_columns(transaction_id: rows.last.id)
        api_get api_v1_transactions_path # records last_used_at once, so it is not counted below

        small = count_queries { api_get api_v1_transactions_path, params: { limit: 2 } }
        large = count_queries { api_get api_v1_transactions_path, params: { limit: 30 } }

        assert_equal 30, json["transactions"].size
        assert_equal small, large
        # The token lookup, then transactions, accounts, payees, receipts, lines and categories.
        assert_equal 7, large
      end

      test "unknown, malformed and empty parameters are 422 invalid_parameter naming the parameter" do
        invalid = {
          { stauts: "draft" } => "stauts",
          { from: "2026-10-32" } => "from",
          { from: "03.10.2026" } => "from",
          { to: "2026-10-01", from: "2026-10-02" } => "to",
          { account_id: "abc" } => "account_id",
          { account_id: "0" } => "account_id",
          { account_id: "999999999" } => "account_id",
          { category_id: "999999999" } => "category_id",
          { payee_id: "1.5" } => "payee_id",
          { status: "booked" } => "status",
          { status: "" } => "status",
          { source: "BANK" } => "source",
          { q: " " } => "q",
          { q: "x" * 201 } => "q",
          { limit: "0" } => "limit",
          { limit: "201" } => "limit",
          { limit: "ten" } => "limit",
          { cursor: "garbage!" } => "cursor",
          { cursor: KeysetCursor.encode("2026-10-01") } => "cursor"
        }
        invalid.each do |params, parameter|
          api_get api_v1_transactions_path, params: params

          assert_invalid_parameter(parameter)
        end
      end

      test "a repeated parameter is refused, not narrowed to one value" do
        get "#{api_v1_transactions_path}?status[]=draft&status[]=confirmed", headers: bearer(plain_token(:agent_read))

        assert_invalid_parameter("status")
      end

      test "show: an unknown or malformed id is 404, a parameter is 422" do
        [ "0", "999999999", "12abc", "abc" ].each do |id|
          api_get "/api/v1/transactions/#{id}"

          assert_response :not_found, id
          assert_api_response_conform(404)
          assert_equal "not_found", json.dig("error", "code")
        end

        api_get api_v1_transaction_path(transactions(:coffee)), params: { expand: "lines" }
        assert_invalid_parameter("expand")
      end
    end
  end
end

require "test_helper"

# What each MCP tool answers, called through /mcp as a client calls it. The contract every tool shares
# (annotations, schemas, a REST twin) is in test/integration/mcp_server_test.rb.
class McpToolsTest < ActionDispatch::IntegrationTest
  include ApiRequestTestHelper
  include McpTestHelper

  setup { host! McpTestHelper::HOST }

  def book(on:, amount:, category: :groceries, status: :confirmed, account: :card_uah)
    Transaction.create!(account: accounts(account), occurred_on: on, amount: BigDecimal(amount), source: :manual, status:,
      lines_attributes: [ { category: categories(category), amount: BigDecimal(amount) } ])
  end

  def group_amount(summary, currency, slug)
    side = summary["currencies"].find { |entry| entry["currency"] == currency }&.fetch("expenses")
    side && side["by_group"].find { |row| row.dig("group", "slug") == slug }&.fetch("amount")
  end

  # The two questions of the demo

  test "groceries last month against the same month a year ago" do
    book(on: Date.new(2025, 10, 12), amount: "-640.25")
    book(on: Date.new(2025, 10, 20), amount: "-99.75")
    book(on: Date.new(2025, 10, 21), amount: "-5000.00", status: :draft)
    book(on: Date.new(2025, 11, 1), amount: "-1.00")

    this_year = mcp_structured("spending_summary", { from: "2026-10-01", to: "2026-10-31" })
    last_year = mcp_structured("spending_summary", { from: "2025-10-01", to: "2025-10-31" })

    assert_equal "-1000.40", group_amount(this_year, "UAH", "groceries")
    assert_equal "-740.00", group_amount(last_year, "UAH", "groceries"), "the draft and November are left out"
    text = mcp_call_tool("spending_summary", { from: "2025-10-01", to: "2025-10-31" }).dig("content", 0, "text")
    assert_includes text, "Groceries (groceries) -740.00"
  end

  test "what was bought on the last receipt: the newest receipt, then its items" do
    receipts(:new_receipt).destroy! # an upload OCR has not read yet would be the newest

    latest = mcp_structured("recent_receipts", { limit: 1 })["receipts"].first
    assert_equal receipts(:corner_receipt).id, latest["id"]

    result = mcp_call_tool("get_receipt", { id: latest["id"] })
    items = result.dig("structuredContent", "items")
    assert_equal [ "Sparkling water 1.5 l", "Sandwich", "Bottle deposit returned" ], items.map { |item| item["name"] }
    assert_equal [ "60.00", "95.00", "-2.50" ], items.map { |item| item["amount"] }
    text = result.dig("content", 0, "text")
    assert_includes text, "Corner Shop"
    assert_includes text, "Sandwich | 1.000 x 95.00 | paid 95.00 | suggested eating-out/takeaway-fast-food (confidence 0.62)"
  end

  # spending_summary

  test "spending_summary: one currency, signs kept, and the text says how to read it" do
    structured = mcp_structured("spending_summary", { from: "2026-10-01", to: "2026-10-31", currency: "UAH" })

    assert_equal [ "UAH" ], structured["currencies"].map { |entry| entry["currency"] }
    text = mcp_call_tool("spending_summary", { from: "2026-10-01", to: "2026-10-31" }).dig("content", 0, "text")
    assert_includes text, "Expenses are negative"
    assert_includes text, "never add two currencies together"
    assert_includes text, "Expenses: -2225.40 UAH in 4 transaction(s)"
    assert_includes text, "Incomes: 50000.00 UAH in 1 transaction(s)"
    assert_includes text, "No category -830.00"
  end

  test "spending_summary: a range with nothing booked" do
    structured = mcp_structured("spending_summary", { from: "2020-01-01", to: "2020-01-31" })

    assert_equal [], structured["currencies"]
    assert_includes mcp_call_tool("spending_summary", { from: "2020-01-01", to: "2020-01-31" }).dig("content", 0, "text"),
      "Nothing was booked in this range."
  end

  test "spending_summary: argument errors name the argument and what is allowed" do
    assert_tool_error(mcp_call_tool("spending_summary", { from: "2026-10-01" }), "Missing required arguments: to")
    assert_tool_error(mcp_call_tool("spending_summary", { from: "2026-02-30", to: "2026-03-01" }), "'from' is not a valid date")
    assert_tool_error(mcp_call_tool("spending_summary", { from: "1 Oct 2026", to: "2026-10-31" }), "/from")
    assert_tool_error(mcp_call_tool("spending_summary", { from: "2026-10-01", to: "2026-10-31", currency: "XYZ" }),
      "'currency' names a currency that no account uses")
    assert_tool_error(mcp_call_tool("spending_summary", { from: "2026-10-01", to: "2026-10-31", currency: "uah" }), "/currency")
  end

  # search_transactions

  test "search_transactions: a category by group slug, category slug or id" do
    by_group = mcp_structured("search_transactions", { category: "eating-out" })["transactions"].map { |row| row["id"] }
    by_slug = mcp_structured("search_transactions", { category: "eating-out/cafes-bars-restaurants" })["transactions"].map { |row| row["id"] }
    by_id = mcp_structured("search_transactions", { category: categories(:eating_out).id })["transactions"].map { |row| row["id"] }

    assert_equal [ transactions(:snack).id, transactions(:coffee).id ], by_group
    assert_equal [ transactions(:coffee).id ], by_slug
    assert_equal by_group, by_id
    assert_tool_error(mcp_call_tool("search_transactions", { category: "eating-in" }), "'category' names no category or group")
    assert_tool_error(mcp_call_tool("search_transactions", { category: 999_999 }), "'category' names no category")
  end

  test "search_transactions: status, payee and text filters, and the readable lines" do
    assert_equal [ transactions(:subscription).id ],
      mcp_structured("search_transactions", { status: "needs_review" })["transactions"].map { |row| row["id"] }
    assert_equal [ transactions(:coffee).id ],
      mcp_structured("search_transactions", { payee_id: payees(:corner_cafe).id })["transactions"].map { |row| row["id"] }
    assert_equal [ transactions(:snack).id ],
      mcp_structured("search_transactions", { text: "  pastry " })["transactions"].map { |row| row["id"] }

    text = mcp_call_tool("search_transactions", { from: "2026-10-03", to: "2026-10-06" }).dig("content", 0, "text")
    assert_includes text, "2026-10-03 | -1250.40 UAH | Example Market | account Everyday card"
    assert_match %r{\| (groceries/groceries -1000\.40, household-shopping/household-supplies -250\.00|household-shopping/household-supplies -250\.00, groceries/groceries -1000\.40) \| confirmed \| id #{transactions(:market_split).id}}, text
    assert_includes text, "2026-10-06 | -2000.00 UAH | Cash withdrawal | account Everyday card"
    assert_includes text, "transfer between own accounts"
    assert_includes text, "no category -830.00 | needs_review"
    assert_includes text, "This is the last page."
  end

  test "search_transactions: pages follow the cursor and match the REST pages" do
    seen = []
    cursor = nil
    loop do
      page = mcp_structured("search_transactions", { limit: 4, cursor: }.compact)
      api_get "/api/v1/transactions", params: { limit: 4, cursor: }.compact
      assert_equal json, JSON.parse(page.to_json)

      seen.concat(page["transactions"].map { |row| row["id"] })
      cursor = page["next_cursor"]
      break if cursor.nil?

      assert_includes mcp_call_tool("search_transactions", { limit: 4, cursor: }).dig("content", 0, "text"), "More rows follow" if seen.size == 4
    end

    assert_equal Transaction.order(occurred_on: :desc, id: :desc).ids, seen
  end

  test "search_transactions: argument errors" do
    assert_tool_error(mcp_call_tool("search_transactions", { cursor: "bm90LWEtY3Vyc29y" }), "'cursor'")
    assert_tool_error(mcp_call_tool("search_transactions", { limit: 500 }), "/limit")
    assert_tool_error(mcp_call_tool("search_transactions", { status: "booked" }), "/status")
    assert_tool_error(mcp_call_tool("search_transactions", { payee: "Corner Cafe" }), "/payee")
    assert_tool_error(mcp_call_tool("search_transactions", { text: " " }), "'text' must contain more than spaces")
    assert_tool_error(mcp_call_tool("search_transactions", { text: "a\u0000b" }), "'text' must be UTF-8 text without NUL characters")
    assert_tool_error(mcp_call_tool("search_transactions", { from: "2026-10-05", to: "2026-10-01" }), "'to' must not be before 'from'")
  end

  # list_categories and list_accounts

  test "list_categories: groups and their categories with slugs and descriptions" do
    structured = mcp_structured("list_categories")
    text = mcp_call_tool("list_categories").dig("content", 0, "text")

    assert_includes structured["groups"].map { |group| group["slug"] }, "groceries"
    assert_includes text, "groceries: Groceries (id #{categories(:groceries_group).id})"
    assert_includes text, "  groceries/groceries: Groceries - Food and everyday groceries, including drinking-water delivery."
  end

  test "list_accounts: balances in each account's own currency" do
    text = mcp_call_tool("list_accounts").dig("content", 0, "text")

    assert_includes text, "id #{accounts(:card_uah).id} | Everyday card | debit | balance 4334.60 UAH"
    assert_includes text, "Savings USD | savings | balance 1000.00 USD"
    assert_includes text, "Old e-wallet | ewallet | balance 0.00 EUR | archived"
  end

  # recent_receipts and get_receipt

  test "recent_receipts: newest first, a status filter, and a page size of 10 by default" do
    receipts = mcp_structured("recent_receipts")["receipts"]
    assert_equal [ receipts(:new_receipt), receipts(:corner_receipt), receipts(:market_receipt), receipts(:failed_receipt) ].map(&:id),
      receipts.map { |row| row["id"] }

    assert_equal [ receipts(:market_receipt).id ], mcp_structured("recent_receipts", { status: "reviewed" })["receipts"].map { |row| row["id"] }
    assert_equal McpTools::RecentReceipts::DEFAULT_LIMIT, mcp_tools["recent_receipts"].dig("inputSchema", "properties", "limit", "description")[/(\d+) by default/, 1].to_i
    text = mcp_call_tool("recent_receipts").dig("content", 0, "text")
    assert_includes text, "id #{receipts(:new_receipt).id} | no time read yet | merchant not read | total ? | 0 item(s) | uploaded | not booked"
    assert_includes text, "Example Market | total 1250.40 UAH | 3 item(s) | reviewed | booked as transaction #{transactions(:market_split).id}"
    assert_tool_error(mcp_call_tool("recent_receipts", { status: "done" }), "/status")
  end

  test "get_receipt: every item, and a clear not found" do
    result = mcp_call_tool("get_receipt", { id: receipts(:market_receipt).id })
    text = result.dig("content", 0, "text")

    assert_equal "1250.40", result.dig("structuredContent", "items_total")
    assert_includes text, "Hard cheese 1 kg | 1.000 x 1010.00, discount 50.00 | paid 960.00 | groceries/groceries"
    assert_not_includes result["structuredContent"].to_json, "4242", "the card digits are never served"

    missing = mcp_call_tool("get_receipt", { id: 999_999_999 })
    assert_tool_error(missing, "No receipt has id 999999999")
    assert_tool_error(mcp_call_tool("get_receipt", {}), "Missing required arguments: id")
  end
end

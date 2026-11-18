require "test_helper"

# The home page: the dashboard. The figures are asserted on the tables each chart carries; the charts' own
# data is read back from Chartkick's inline scripts.
class HomeControllerTest < ActionDispatch::IntegrationTest
  include ApiRequestTestHelper

  TODAY = Time.zone.local(2026, 11, 18, 12)

  setup { travel_to TODAY }

  def book(account: :card_uah, amount:, on: Date.new(2026, 10, 20), status: :confirmed, category: :groceries)
    Transaction.create!(account: accounts(account), occurred_on: on, amount: BigDecimal(amount), source: :manual, status:,
      lines_attributes: [ { category: categories(category), amount: BigDecimal(amount) } ])
  end

  # The rows of the table under a chart, as arrays of cell texts (header cells included).
  def table_rows(chart_title)
    css_select("section[aria-labelledby=#{chart_title}-title] table tbody tr").map do |row|
      row.css("th, td").map { |cell| cell.text.strip }
    end
  end

  def table_total(chart_title)
    css_select("section[aria-labelledby=#{chart_title}-title] table tfoot tr").sole.css("th, td").map { |cell| cell.text.strip }
  end

  # [data, options] of the Chartkick chart with this id, parsed from its inline script.
  def chart_payload(id)
    script = css_select("script").map(&:text).find { |text| text.include?("(#{id.to_json}, ") }
    assert script, "no chart #{id}"
    rest = script[/new Chartkick\["\w+"\]\(#{Regexp.escape(id.to_json)}, (.*)\); \};/m, 1]
    rest.enum_for(:scan, /\], \{/).each do
      cut = Regexp.last_match.begin(0) + 1
      data = JSON.parse(rest[0, cut]) rescue next
      options = JSON.parse(rest[(cut + 2)..]) rescue next
      return [ data, options ]
    end
    flunk "could not read the data of #{id}"
  end

  test "a signed-out visitor is sent to the sign-in page" do
    get root_path

    assert_redirected_to new_session_path
  end

  test "the health check answers without a session" do
    get rails_health_check_path

    assert_response :success
  end

  test "the top bar shows who is signed in and a sign-out button" do
    sign_in_as users(:owner)

    get root_path

    assert_select "header a[href=?]", root_path, text: "Money Bin"
    assert_select "header", text: /owner@example\.com/
    assert_select "header form[action=?] button", session_path, text: "Sign out", count: 1
  end

  test "the dashboard shows the last 12 months in UAH: headline figures, three charts and the receipts, each with its table" do
    sign_in_as users(:owner)

    get root_path

    assert_response :success
    assert_select "main h1", "Overview"
    assert_select "select#period option[selected]", "Last 12 months"
    assert_select "select#currency option[selected]", "UAH"
    assert_select ".stat-tile", text: /Spent in Nov 2026 so far\s*0\.00 UAH\s*Oct 2026: 2 225\.40 UAH\s*Nov 2025: 0\.00 UAH/
    assert_select ".stat-tile", text: /Spent in the last 12 months\s*2 225\.40 UAH\s*Income: 50 000\.00 UAH/
    assert_select ".stat-tile", text: /Uncategorised spending\s*830\.00 UAH\s*1 transaction/
    assert_select ".stat-tile", text: /Needs a look\s*1 transaction/
    assert_select ".stat-tile a[href=?]", receipts_path(status: "extracted"), text: "1 receipt to review"

    months = table_rows("chart-months")
    assert_equal 13, months.size
    assert_equal [ "Nov 2025", "0.00", "0.00" ], months.first
    assert_equal [ "Oct 2026", "2 225.40", "50 000.00" ], months[11]
    assert_equal [ "Total", "2 225.40", "50 000.00" ], table_total("chart-months")

    assert_equal [
      [ "Groceries", "Groceries", "1", "1 000.40" ],
      [ "No category", "", "1", "830.00" ],
      [ "Household supplies", "Household & shopping", "1", "250.00" ],
      [ "Cafes, bars & restaurants", "Eating out", "1", "85.00" ],
      [ "Takeaway & fast food", "Eating out", "1", "60.00" ]
    ], table_rows("chart-categories")

    assert_equal [ [ "Example Market", "1", "1 250.40" ], [ "Corner Cafe", "1", "85.00" ], [ "No payee", "2", "890.00" ] ],
      table_rows("chart-payees")
    assert_equal [ "Total", "4", "2 225.40" ], table_total("chart-payees")

    counts = ReceiptCountsQuery.new.call
    assert_includes table_rows("chart-receipts"), [ "Stored", counts.total.to_s ]
    assert_includes table_rows("chart-receipts"), [ "Accepted into the ledger", counts.by_status["reviewed"].to_s ]
    assert_includes table_rows("chart-receipts"), [ "With ground truth", counts.with_ground_truth.to_s ]
  end

  test "every figure equals the REST summary for the same period and currency" do
    book(amount: "-12.34", on: Date.new(2026, 3, 9), category: :cafes)
    book(amount: "-5.00", on: Date.new(2025, 11, 1), category: :uncategorised)
    book(amount: "250.00", on: Date.new(2025, 12, 31), category: :salary)
    book(amount: "-4.00", on: Date.new(2026, 11, 30), category: :takeaway)
    book(account: :savings_usd, amount: "-20.00", on: Date.new(2026, 10, 9))
    sign_in_as users(:owner)
    money = ->(amount) { ActiveSupport::NumberHelper.number_to_rounded(BigDecimal(amount), precision: 2, delimiter: " ") }
    as_spent = ->(amount) { money.(BigDecimal("0") - BigDecimal(amount)) }

    { { period: "2026" } => %w[2026-01-01 2026-12-31], {} => %w[2025-11-01 2026-11-30] }.each do |params, (from, to)|
      get root_path(params)
      months = table_rows("chart-months").to_h { |month, spent, income| [ month, [ spent, income ] ] }
      categories = table_rows("chart-categories").to_h { |name, _group, _count, spent| [ name, spent ] }
      total = table_total("chart-months")
      payees_total = table_total("chart-payees")

      api_get api_v1_summary_path, params: { from:, to:, currency: "UAH" }
      uah = json["currencies"].sole

      assert_equal as_spent.(uah.dig("expenses", "total")), total[1], params
      assert_equal money.(uah.dig("incomes", "total")), total[2], params
      assert_equal as_spent.(uah.dig("expenses", "total")), payees_total[2], params
      assert_equal uah.dig("expenses", "transactions").to_s, payees_total[1], params
      %w[expenses incomes].each_with_index do |side, column|
        uah.dig(side, "by_month").each do |row|
          figure = side == "expenses" ? as_spent.(row["amount"]) : money.(row["amount"])
          assert_equal figure, months.fetch(Date.parse("#{row['month']}-01").strftime("%b %Y"))[column], [ params, side, row["month"] ]
        end
      end
      uah.dig("expenses", "by_category").each do |row|
        assert_equal as_spent.(row["amount"]), categories.fetch(row.dig("category", "name") || "No category"), [ params, row["category"] ]
      end
    end
  end

  test "the period follows the Kyiv date: half past midnight on 1 December is December" do
    travel_to Time.zone.local(2026, 12, 1, 0, 30)
    sign_in_as users(:owner)

    get root_path

    assert_select ".stat-label", "Spent in Dec 2026 so far"
    assert_equal [ "Dec 2025", "Dec 2026" ], [ table_rows("chart-months").first.first, table_rows("chart-months").last.first ]
  end

  test "the categories beyond the top ten are one Other bar, also in the chart" do
    stub_const(Dashboard, :TOP_CATEGORIES, 2) do
      sign_in_as users(:owner)

      get root_path

      rows = table_rows("chart-categories")
      assert_equal [ "Other (3 categories)", "", "", "395.00" ], rows.last
      data, = chart_payload("chart-categories")
      assert_equal [ "Other (3 categories)", "395.00" ], data.first["data"].last
    end
  end

  test "a draft and a transfer leg change no figure on the page" do
    sign_in_as users(:owner)
    get root_path
    before = [ table_rows("chart-months"), table_rows("chart-categories"), table_rows("chart-payees"), css_select(".stat-tiles").text ]

    book(amount: "-999.00", status: :draft, on: Date.new(2026, 11, 2))
    now = Time.current
    %i[withdrawal_out withdrawal_in savings_out].each do |leg|
      TransactionLine.insert!({ transaction_id: transactions(leg).id, category_id: categories(:groceries).id,
        amount: transactions(leg).amount, created_at: now, updated_at: now })
    end
    get root_path

    assert_equal before, [ table_rows("chart-months"), table_rows("chart-categories"), table_rows("chart-payees"), css_select(".stat-tiles").text ]
  end

  test "two currencies are never added: USD has its own page, chosen in the URL" do
    book(account: :savings_usd, amount: "-20.00", on: Date.new(2026, 10, 9))
    sign_in_as users(:owner)

    get root_path
    assert_select "select#currency option", count: 2
    assert_equal [ "Total", "2 225.40", "50 000.00" ], table_total("chart-months")

    get root_path(currency: "USD")
    assert_select "select#currency option[selected]", "USD"
    assert_equal [ "Total", "20.00", "0.00" ], table_total("chart-months")
    assert_equal [ [ "Groceries", "Groceries", "1", "20.00" ] ], table_rows("chart-categories")
    assert_select ".stat-tile", text: /Spent in the last 12 months\s*20\.00 USD/
  end

  test "the charts get exact decimal strings, never a float, and the tooltip text formatted on the server" do
    book(amount: "-0.10", on: Date.new(2026, 10, 21), category: :cafes)
    book(amount: "-0.20", on: Date.new(2026, 10, 22), category: :cafes)
    sign_in_as users(:owner)

    get root_path

    %w[chart-months chart-categories chart-payees chart-receipts].each do |id|
      data, options = chart_payload(id)
      assert_no_floats data
      assert_no_floats options
      assert_equal true, options["discrete"]
      data.each { |series| assert_equal series["data"].size, series.dig("library", "exact").size }
    end

    months, = chart_payload("chart-months")
    assert_equal %w[Spent Income], months.map { |series| series["name"] }
    assert_includes months.first["data"], [ "Oct 2026", "2225.70" ]
    assert_equal "2 225.70 UAH", months.first.dig("library", "exact")[11]
    categories, = chart_payload("chart-categories")
    assert_includes categories.first["data"], [ "Cafes, bars & restaurants", "85.30" ]
    assert(categories.first["data"].all? { |_, value| value.match?(/\A-?\d+\.\d{2}\z/) })
    receipts, = chart_payload("chart-receipts")
    assert(receipts.first["data"].all? { |_, value| value.is_a?(Integer) })
  end

  test "every chart script carries the page's nonce, and no element has an inline style" do
    sign_in_as users(:owner)

    get root_path

    nonce = response.headers["Content-Security-Policy"][/'nonce-([^']+)'/, 1]
    chart_scripts = css_select("script").select { |script| script.text.include?("Chartkick") }
    assert_equal 4, chart_scripts.size
    chart_scripts.each { |script| assert_equal nonce, script["nonce"] }
    assert_empty css_select("[style]").map { |element| element.to_html[0, 80] }
    assert_select "div#chart-months.chart.chart-lg[aria-hidden=true]"
    assert_select "[data-controller=charts]"
  end

  test "the period is a year from the URL; the grouping switch keeps it" do
    book(amount: "-10.00", on: Date.new(2024, 3, 5))
    sign_in_as users(:owner)

    get root_path(period: "2024", by: "group")

    assert_select "select#period option[selected]", "2024"
    assert_select "select#period option", count: 4
    assert_select "input[type=hidden][name=by][value=group]"
    assert_equal 12, table_rows("chart-months").size
    assert_equal [ [ "Groceries", "10.00" ] ], table_rows("chart-categories")
    assert_select "nav.count-tabs a[aria-current=page]", "Groups"
    assert_select "nav.count-tabs a[href=?]", root_path(period: "2024"), text: "Categories"
  end

  test "a period with nothing in it and a currency with no data each show an empty state, not an empty chart" do
    book(amount: "-10.00", on: Date.new(2024, 3, 5))
    book(account: :savings_usd, amount: "-20.00", on: Date.new(2026, 10, 9))
    sign_in_as users(:owner)

    get root_path(period: "2025")
    assert_select ".callout", text: /Nothing was booked in UAH in 2025\./
    assert_select "#chart-months", count: 0
    assert_select "#chart-categories", count: 0

    get root_path(currency: "EUR")
    assert_select ".callout", text: /Nothing was booked in EUR in the last 12 months\. Other currencies with figures in this period: UAH, USD\./
    assert_select ".callout a[href=?]", root_path(currency: "USD"), text: "USD"
    assert_select "#chart-months", count: 0
    assert_select "#chart-receipts"
  end

  test "an empty ledger says so and still shows the receipts" do
    TransactionLine.delete_all
    Receipt.update_all(transaction_id: nil)
    Transaction.delete_all
    sign_in_as users(:owner)

    get root_path

    assert_response :success
    assert_select ".callout", text: /Nothing is booked yet/
    assert_select "form.filter-bar", count: 0
    assert_select "#chart-months", count: 0
    assert_select "#chart-receipts"
  end

  test "no receipts: the receipts card says so" do
    ReceiptGroundTruth.delete_all
    ReceiptItem.delete_all
    Receipt.delete_all
    sign_in_as users(:owner)

    get root_path

    assert_select "section[aria-labelledby=chart-receipts-title] .callout", text: /No receipts yet/
    assert_select "#chart-receipts", count: 0
  end

  test "the page's queries stay the same as the ledger grows" do
    sign_in_as users(:owner)
    get root_path
    small = count_queries { get root_path }
    # Categories of every group, so a lookup per row or per group would show.
    spread = %i[cafes takeaway household_supplies groceries uncategorised]
    40.times { |index| book(amount: "-1.00", on: Date.new(2026, 1 + (index % 10), 1 + index % 28), category: spread[index % spread.size]) }

    assert_equal small, count_queries { get root_path }
    assert_operator small, :<=, 10
  end
end

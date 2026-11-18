require "test_helper"

class DashboardTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 11, 18)

  def dashboard(**params)
    Dashboard.new(params, today: TODAY)
  end

  def book(account: :card_uah, amount:, on: Date.new(2026, 10, 20), status: :confirmed, category: :groceries, lines: nil)
    lines ||= [ { category: categories(category), amount: } ]
    Transaction.create!(account: accounts(account), occurred_on: on, amount: BigDecimal(amount), source: :manual, status:,
      lines_attributes: lines.map { |line| line.merge(amount: BigDecimal(line[:amount])) })
  end

  def count_queries(&block)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    queries
  end

  def touch_everything(view)
    [ view.period, view.currencies, view.months, view.slices, view.uncategorised, view.payees, view.receipts,
      view.needs_review_count, view.comparison, view.ledger_empty?, view.empty?, view.spent, view.income ]
  end

  test "defaults: the last 12 full months and the whole of this one, UAH, by category" do
    view = dashboard

    assert view.period.last_12?
    assert_equal Date.new(2025, 11, 1), view.period.from
    assert_equal Date.new(2026, 11, 30), view.period.to
    assert_equal 13, view.months.size
    assert_equal Date.new(2025, 11, 1), view.months.first.month
    assert_equal Date.new(2026, 11, 1), view.months.last.month
    assert_equal "UAH", view.currency
    assert_equal "category", view.grouping
    assert_equal({}, view.to_params)
  end

  test "a value that is not a choice falls back to the default" do
    view = dashboard(period: "1999", currency: "uah; drop", by: "payee")

    assert view.period.last_12?
    assert_equal "UAH", view.currency
    assert_equal "category", view.grouping
  end

  test "every year from the first booked row's to this one is a period, 1 January to 31 December" do
    book(amount: "-10.00", on: Date.new(2024, 3, 5))

    assert_equal [ 2026, 2025, 2024 ], dashboard.available_years
    year = dashboard(period: "2024")
    assert_equal Date.new(2024, 1, 1)..Date.new(2024, 12, 31), year.period.from..year.period.to
    assert_equal 12, year.months.size
    current = dashboard(period: "2026")
    assert_equal Date.new(2026, 12, 31), current.period.to
    assert_equal 12, current.months.size
    assert_empty dashboard(period: "2025").slices
    assert dashboard(period: "2023").period.last_12?
    assert_equal({ period: "2024", by: "group" }, year.to_params(by: "group"))
  end

  test "months are zero-filled, spending positive, and every figure is the summary's for the same range" do
    view = dashboard
    summary = SpendingSummaryQuery.new(from: view.period.from, to: view.period.to, currency: "UAH").call.currencies.sole
    october = view.months.find { |row| row.month == Date.new(2026, 10, 1) }

    assert_equal BigDecimal("2225.40"), october.spent
    assert_equal BigDecimal("50000.00"), october.income
    assert_equal [ BigDecimal("0") ], (view.months - [ october ]).flat_map { |row| [ row.spent, row.income ] }.uniq
    assert_equal(-summary.expenses.total, view.spent)
    assert_equal summary.incomes.total, view.income
    assert_equal view.spent, view.months.sum(BigDecimal("0"), &:spent)
    assert_equal summary.expenses.by_category.map { |row| -row.amount }, view.slices.map(&:spent)
    assert(view.months.all? { |row| row.spent.is_a?(BigDecimal) && row.income.is_a?(BigDecimal) })
  end

  test "a draft and a transfer leg are in no figure" do
    before = touch_everything(dashboard)
    book(amount: "-999.00", status: :draft, on: Date.new(2026, 11, 2))
    now = Time.current
    %i[withdrawal_out savings_out].each do |leg|
      TransactionLine.insert!({ transaction_id: transactions(leg).id, category_id: categories(:groceries).id,
        amount: transactions(leg).amount, created_at: now, updated_at: now })
    end

    view = dashboard

    assert_equal before[2], view.months
    assert_equal before[3], view.slices
    assert_equal before[8], view.comparison
    assert_equal before[11], view.spent
  end

  test "two currencies are never added: each is shown on its own, UAH first" do
    book(account: :savings_usd, amount: "-20.00", on: Date.new(2026, 10, 9))
    book(account: :old_wallet, amount: "-7.00", on: Date.new(2026, 10, 9))

    uah = dashboard
    usd = dashboard(currency: "USD")

    assert_equal %w[UAH EUR USD], uah.currencies
    assert_equal BigDecimal("2225.40"), uah.spent
    assert_equal BigDecimal("20.00"), usd.spent
    assert_equal [ BigDecimal("20.00") ], usd.slices.map(&:spent)
    assert_equal BigDecimal("-20.00"), usd.payees.total
  end

  test "a currency with nothing in the period is empty but stays chosen" do
    view = dashboard(currency: "GBP")

    assert view.empty?
    assert_includes view.currencies, "GBP"
    assert_equal BigDecimal("0"), view.spent
    assert_empty view.slices
    assert_nil view.payees
    assert_equal 13, view.months.size
    assert_not view.ledger_empty?
  end

  test "the largest categories, then the rest summed as Other" do
    book(amount: "-5.00", category: :cafes)

    stub_const(Dashboard, :TOP_CATEGORIES, 2) do
      slices = dashboard.slices

      assert_equal %i[category no_category other], slices.map(&:kind)
      assert_equal [ categories(:groceries), nil ], slices.first(2).map(&:record)
      assert_equal 3, slices.last.count
      # household 250 + cafes 85 + 5 + takeaway 60
      assert_equal BigDecimal("400.00"), slices.last.spent
      assert_equal dashboard.spent, slices.sum(BigDecimal("0"), &:spent)
    end
  end

  test "by group, groups roll up their categories" do
    slices = dashboard(by: "group").slices

    assert_equal %i[group no_category group group], slices.map(&:kind)
    eating_out = slices.find { |slice| slice.record == categories(:eating_out) }
    assert_equal BigDecimal("145.00"), eating_out.spent
    assert_nil eating_out.transactions
  end

  test "uncategorised spending is the lines in the Uncategorised category and the lines with no category" do
    assert_equal [ BigDecimal("830.00"), 1 ], dashboard.uncategorised
    book(amount: "-500.00", category: :uncategorised)

    view = dashboard

    assert_equal [ BigDecimal("1330.00"), 2 ], view.uncategorised
    assert_equal [ BigDecimal("0"), 0 ], dashboard(currency: "USD").uncategorised
    slices = view.slices.to_h { |slice| [ slice.kind == :no_category ? :no_category : slice.record, slice.spent ] }
    assert_equal BigDecimal("830.00"), slices[:no_category]
    assert_equal BigDecimal("500.00"), slices[categories(:uncategorised)]
  end

  test "a slice carries its group, so the page needs no lookup per category" do
    slice = dashboard.slices.find { |candidate| candidate.record == categories(:cafes) }

    assert_equal categories(:eating_out), slice.group
  end

  test "a booked row dated later this month or year is counted, as the REST summary counts it" do
    book(amount: "-7.00", on: Date.new(2026, 11, 29))
    book(amount: "-3.00", on: Date.new(2026, 12, 20))

    assert_equal BigDecimal("2232.40"), dashboard.spent
    assert_equal BigDecimal("7.00"), dashboard.comparison.spent
    assert_equal BigDecimal("2235.40"), dashboard(period: "2026").spent
  end

  test "this month so far against the whole previous month and the same month a year before, in any period" do
    book(amount: "-100.00", on: Date.new(2026, 11, 3))
    book(amount: "-40.00", on: Date.new(2025, 11, 30))
    book(amount: "-1.00", on: Date.new(2025, 10, 31))

    [ dashboard, dashboard(period: "2025") ].each do |view|
      comparison = view.comparison

      assert_equal Date.new(2026, 11, 1), comparison.month
      assert_equal BigDecimal("100.00"), comparison.spent
      assert_equal Date.new(2026, 10, 1), comparison.previous_month
      assert_equal BigDecimal("2225.40"), comparison.previous_spent
      assert_equal Date.new(2025, 11, 1), comparison.year_ago_month
      assert_equal BigDecimal("40.00"), comparison.year_ago_spent
    end
  end

  test "needs review counts booked transactions marked so; the receipts are ReceiptCountsQuery's" do
    assert_equal Transaction.needs_review.count, dashboard.needs_review_count
    assert_equal ReceiptCountsQuery.new.call, dashboard.receipts
  end

  test "an empty ledger" do
    TransactionLine.delete_all
    Receipt.update_all(transaction_id: nil)
    Transaction.delete_all

    view = dashboard

    assert view.ledger_empty?
    assert view.empty?
    assert_equal [ 2026 ], view.available_years
  end

  test "a fixed number of queries, whatever the volume" do
    last_12 = count_queries { touch_everything(dashboard) }
    year = count_queries { touch_everything(dashboard(period: "2026")) }
    50.times { |index| book(amount: "-1.00", on: Date.new(2026, 1 + (index % 10), 1 + index % 28), category: index.even? ? :cafes : :takeaway) }

    assert_equal last_12, count_queries { touch_everything(dashboard) }
    assert_equal year, count_queries { touch_everything(dashboard(period: "2026")) }
    assert_operator last_12, :<=, 9
    assert_equal last_12 + 3, year
  end
end

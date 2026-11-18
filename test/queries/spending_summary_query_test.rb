require "test_helper"

class SpendingSummaryQueryTest < ActiveSupport::TestCase
  OCTOBER = Date.new(2026, 10, 1)..Date.new(2026, 10, 31)

  def summarise(from: OCTOBER.first, to: OCTOBER.last, currency: nil)
    SpendingSummaryQuery.new(from:, to:, currency:).call
  end

  def currency(summary, code)
    summary.currencies.find { |entry| entry.currency == code }
  end

  def category_amount(side, fixture)
    side.by_category.find { |row| row.category == categories(fixture) }&.amount
  end

  def book(account:, amount:, on: Date.new(2026, 10, 20), status: :confirmed, lines: nil)
    lines ||= [ { category: categories(:groceries), amount: } ]
    Transaction.create!(account: accounts(account), occurred_on: on, amount: BigDecimal(amount), source: :manual, status:,
      lines_attributes: lines.map { |line| line.merge(amount: BigDecimal(line[:amount])) })
  end

  test "sums the October fixtures: booked expenses and incomes, transfers left out" do
    uah = currency(summarise, "UAH")

    # coffee 85 + market 1250.40 + snack 60 + subscription 830 (needs_review counts); the two transfers do not.
    assert_equal BigDecimal("-2225.40"), uah.expenses.total
    assert_equal 4, uah.expenses.transactions
    assert_equal BigDecimal("50000.00"), uah.incomes.total
    assert_equal 1, uah.incomes.transactions
    assert_kind_of BigDecimal, uah.expenses.total
  end

  test "a split transaction gives each category its own share" do
    expenses = currency(summarise, "UAH").expenses

    assert_equal BigDecimal("-1000.40"), category_amount(expenses, :groceries)
    assert_equal BigDecimal("-250.00"), category_amount(expenses, :household_supplies)
    assert_equal 1, expenses.by_category.find { |row| row.category == categories(:groceries) }.transactions
  end

  test "groups roll up their categories, and lines with no category have a nil category and group" do
    book(account: :card_uah, amount: "-40.00", lines: [ { category: categories(:takeaway), amount: "-40.00" } ])

    expenses = currency(summarise, "UAH").expenses
    eating_out = expenses.by_group.find { |row| row.group == categories(:eating_out) }
    uncategorised = expenses.by_category.find { |row| row.category.nil? }

    # cafes 85 + takeaway 60 + 40
    assert_equal BigDecimal("-185.00"), eating_out.amount
    assert_equal BigDecimal("-830.00"), uncategorised.amount
    assert_nil uncategorised.group
    assert_equal BigDecimal("-830.00"), expenses.by_group.find { |row| row.group.nil? }.amount
    assert_equal categories(:eating_out), expenses.by_category.find { |row| row.category == categories(:takeaway) }.group
    assert_equal expenses.total, expenses.by_group.sum(BigDecimal("0"), &:amount)
  end

  test "a draft is left out of every figure" do
    book(account: :card_uah, amount: "-999.00", status: :draft)
    book(account: :card_uah, amount: "999.00", status: :draft, lines: [ { category: categories(:salary), amount: "999.00" } ])

    uah = currency(summarise, "UAH")

    assert_equal BigDecimal("-2225.40"), uah.expenses.total
    assert_equal BigDecimal("50000.00"), uah.incomes.total
    assert_equal BigDecimal("-1000.40"), category_amount(uah.expenses, :groceries)
  end

  # Transfer legs have no lines (a model rule), which alone would keep them out of the line sums. The lines
  # written here past the model make the summary's own transfer condition the only thing that keeps them out.
  def give_transfer_legs_lines
    now = Time.current
    %i[withdrawal_out withdrawal_in savings_out savings_in].each do |leg|
      TransactionLine.insert!({ transaction_id: transactions(leg).id, category_id: categories(:groceries).id,
        amount: transactions(leg).amount, created_at: now, updated_at: now })
    end
  end

  test "a transfer leg is left out, also when it is the only row of its currency" do
    give_transfer_legs_lines

    summary = summarise
    uah = currency(summary, "UAH")

    # savings_in (+1000 USD) is a transfer leg: USD has nothing else in October.
    assert_nil currency(summary, "USD")
    assert_equal BigDecimal("-2225.40"), uah.expenses.total
    assert_equal BigDecimal("50000.00"), uah.incomes.total
    assert_equal 4, uah.expenses.transactions
    assert_equal BigDecimal("-1000.40"), category_amount(uah.expenses, :groceries)
  end

  test "two currencies are never added together" do
    book(account: :savings_usd, amount: "-12.50")

    summary = summarise

    assert_equal %w[UAH USD], summary.currencies.map(&:currency)
    assert_equal BigDecimal("-12.50"), currency(summary, "USD").expenses.total
    assert_equal BigDecimal("-2225.40"), currency(summary, "UAH").expenses.total
    assert_equal BigDecimal("-12.50"), category_amount(currency(summary, "USD").expenses, :groceries)
    assert_equal BigDecimal("-1000.40"), category_amount(currency(summary, "UAH").expenses, :groceries)
  end

  test "the currency filter keeps one currency" do
    book(account: :savings_usd, amount: "-12.50")

    summary = summarise(currency: "USD")

    assert_equal %w[USD], summary.currencies.map(&:currency)
  end

  test "the range is inclusive on both ends and months are calendar months, oldest first" do
    book(account: :card_uah, amount: "-10.00", on: Date.new(2026, 9, 30))
    book(account: :card_uah, amount: "-20.00", on: Date.new(2026, 11, 1))
    book(account: :card_uah, amount: "-30.00", on: Date.new(2026, 11, 2))

    expenses = currency(summarise(from: Date.new(2026, 9, 30), to: Date.new(2026, 11, 1)), "UAH").expenses

    assert_equal %w[2026-09 2026-10 2026-11], expenses.by_month.map(&:month)
    assert_equal [ BigDecimal("-10.00"), BigDecimal("-2225.40"), BigDecimal("-20.00") ], expenses.by_month.map(&:amount)
    october = expenses.by_month.second
    assert_equal BigDecimal("-1000.40"), october.by_category.find { |row| row.category == categories(:groceries) }.amount
  end

  test "an opposite-sign line lowers its category inside an expense; a refund is an income" do
    book(account: :card_uah, amount: "-97.50", lines: [
      { category: categories(:groceries), amount: "-100.00" }, { category: categories(:takeaway), amount: "2.50" }
    ])
    book(account: :card_uah, amount: "15.00")

    uah = currency(summarise, "UAH")

    assert_equal BigDecimal("-1100.40"), category_amount(uah.expenses, :groceries)
    assert_equal BigDecimal("-57.50"), category_amount(uah.expenses, :takeaway)
    assert_equal BigDecimal("15.00"), category_amount(uah.incomes, :groceries)
  end

  test "rows are ordered by magnitude, largest first" do
    amounts = currency(summarise, "UAH").expenses.by_category.map(&:amount)

    assert_equal amounts.sort_by { |amount| -amount.abs }, amounts
  end

  test "a range with nothing booked has no currencies" do
    assert_empty summarise(from: Date.new(2020, 1, 1), to: Date.new(2020, 12, 31)).currencies
  end

  test "from after to is refused" do
    assert_raises(ArgumentError) { summarise(from: Date.new(2026, 10, 2), to: Date.new(2026, 10, 1)) }
  end

  test "three queries whatever the range" do
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { summarise }

    assert_equal 3, queries
  end
end

require "test_helper"

class TopPayeesQueryTest < ActiveSupport::TestCase
  OCTOBER = Date.new(2026, 10, 1)..Date.new(2026, 10, 31)

  def top(from: OCTOBER.first, to: OCTOBER.last, currency: nil, limit: TopPayeesQuery::DEFAULT_LIMIT)
    TopPayeesQuery.new(from:, to:, currency:, limit:).call
  end

  def of(result, code)
    result.currencies.find { |entry| entry.currency == code }
  end

  def book(account: :card_uah, amount:, payee: nil, on: Date.new(2026, 10, 20), status: :confirmed, lines: nil)
    lines ||= [ { category: categories(:groceries), amount: } ]
    Transaction.create!(account: accounts(account), occurred_on: on, amount: BigDecimal(amount), source: :manual, status:, payee:,
      lines_attributes: lines.map { |line| line.merge(amount: BigDecimal(line[:amount])) })
  end

  test "ranks the October payees by what they took, with their transactions; the rest is the expenses with no payee" do
    uah = of(top, "UAH")

    assert_equal [ payees(:example_market), payees(:corner_cafe) ], uah.payees.map(&:payee)
    assert_equal [ BigDecimal("-1250.40"), BigDecimal("-85.00") ], uah.payees.map(&:amount)
    assert_equal [ 1, 1 ], uah.payees.map(&:transactions)
    # snack 60 and subscription 830 have no payee; the employer's salary is an income and stays out.
    assert_equal BigDecimal("-890.00"), uah.without_payee.amount
    assert_equal 2, uah.without_payee.transactions
    assert_equal 0, uah.other.payees
    assert_equal BigDecimal("-2225.40"), uah.total
    assert_equal 4, uah.transactions
    assert_kind_of BigDecimal, uah.payees.first.amount
  end

  test "the parts add up to the summary's expense total for the same range and currency" do
    book(amount: "-30.00", payee: payees(:corner_cafe))
    book(amount: "-12.00", payee: payees(:employer))
    book(account: :savings_usd, amount: "-5.00", payee: payees(:example_market))

    result = top(limit: 1)
    summary = SpendingSummaryQuery.new(from: OCTOBER.first, to: OCTOBER.last).call

    summary.currencies.each do |expected|
      payees = of(result, expected.currency)
      parts = payees.payees.sum(BigDecimal("0"), &:amount) + payees.other.amount + payees.without_payee.amount
      assert_equal expected.expenses.total, parts, expected.currency
      assert_equal expected.expenses.total, payees.total, expected.currency
      assert_equal expected.expenses.transactions, payees.transactions, expected.currency
    end
  end

  test "a payee beyond the limit is summed in other" do
    book(amount: "-30.00", payee: payees(:corner_cafe))

    uah = of(top(limit: 1), "UAH")

    assert_equal [ payees(:example_market) ], uah.payees.map(&:payee)
    assert_equal 1, uah.other.payees
    assert_equal BigDecimal("-115.00"), uah.other.amount
    assert_equal 2, uah.other.transactions
  end

  test "a split transaction counts once, with all its lines, for its payee; an opposite-sign line lowers it" do
    book(amount: "-95.00", payee: payees(:corner_cafe), lines: [
      { category: categories(:cafes), amount: "-60.00" },
      { category: categories(:takeaway), amount: "-40.00" },
      { category: categories(:groceries), amount: "5.00" }
    ])

    cafe = of(top, "UAH").payees.find { |row| row.payee == payees(:corner_cafe) }

    assert_equal BigDecimal("-180.00"), cafe.amount
    assert_equal 2, cafe.transactions
  end

  test "a draft and a refund are left out" do
    book(amount: "-999.00", payee: payees(:corner_cafe), status: :draft)
    book(amount: "40.00", payee: payees(:corner_cafe), lines: [ { category: categories(:cafes), amount: "40.00" } ])

    cafe = of(top, "UAH").payees.find { |row| row.payee == payees(:corner_cafe) }

    assert_equal BigDecimal("-85.00"), cafe.amount
    assert_equal 1, cafe.transactions
  end

  test "a transfer leg is left out, also when lines were written to it past the model" do
    now = Time.current
    %i[withdrawal_out savings_out].each do |leg|
      transactions(leg).update_columns(payee_id: payees(:corner_cafe).id)
      TransactionLine.insert!({ transaction_id: transactions(leg).id, category_id: categories(:groceries).id,
        amount: transactions(leg).amount, created_at: now, updated_at: now })
    end

    cafe = of(top, "UAH").payees.find { |row| row.payee == payees(:corner_cafe) }

    assert_equal BigDecimal("-85.00"), cafe.amount
  end

  test "each currency stands alone, and currency limits the result to one" do
    book(account: :savings_usd, amount: "-20.00", payee: payees(:example_market))

    all = top
    usd = of(all, "USD")

    assert_equal %w[UAH USD], all.currencies.map(&:currency)
    assert_equal BigDecimal("-20.00"), usd.payees.sole.amount
    assert_equal BigDecimal("-1250.40"), of(all, "UAH").payees.first.amount
    assert_equal %w[USD], top(currency: "USD").currencies.map(&:currency)
  end

  test "ties are broken by name, and the range is inclusive" do
    book(amount: "-1250.40", payee: payees(:corner_cafe), on: OCTOBER.last)

    uah = of(top, "UAH")

    # Corner Cafe 85 + 1250.40 now leads; then Example Market.
    assert_equal [ payees(:corner_cafe), payees(:example_market) ], uah.payees.map(&:payee)
    assert_equal [ 2, 1 ], uah.payees.map(&:transactions)
  end

  test "an empty range has no currencies, and the arguments are checked" do
    assert_empty top(from: Date.new(2020, 1, 1), to: Date.new(2020, 12, 31)).currencies
    assert_raises(ArgumentError) { top(from: OCTOBER.last, to: OCTOBER.first) }
    assert_raises(ArgumentError) { top(limit: 0) }
    assert_raises(ArgumentError) { top(limit: TopPayeesQuery::MAX_LIMIT + 1) }
  end

  test "two queries whatever the range" do
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { top(from: Date.new(2015, 1, 1), to: OCTOBER.last) }

    assert_equal 2, queries
  end
end

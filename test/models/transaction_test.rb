require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  def build_expense(amount: "-100.00", lines: [ { amount: "-100.00" } ], **attributes)
    Transaction.new(
      { account: accounts(:cash_uah), amount:, occurred_on: Date.new(2026, 10, 10), source: :manual,
        lines_attributes: lines }.merge(attributes)
    )
  end

  # One violating statement per savepoint: after a failed statement PostgreSQL rejects everything else in the
  # same transaction, so a second assertion would prove nothing.
  def assert_violates(constraint, error = ActiveRecord::StatementInvalid, &block)
    exception = assert_raises(error) { Transaction.transaction(requires_new: true, &block) }
    assert_includes exception.message, constraint
  end

  def row(**attributes)
    { account_id: accounts(:cash_uah).id, amount: -5, occurred_on: Date.current, source: "manual" }.merge(attributes)
  end

  test "the Transaction constant is the model" do
    assert_operator Transaction, :<, ApplicationRecord
    assert_equal "transactions", Transaction.table_name
    assert_equal "Transaction", Transaction.model_name.name
  end

  test "an association cannot be called transaction, which is why lines use parent" do
    error = assert_raises(ArgumentError) do
      Class.new(ApplicationRecord) do
        self.table_name = "transaction_lines"
        belongs_to :transaction
      end
    end
    assert_match "transaction", error.message
  end

  test "a split expense is valid" do
    expense = build_expense(amount: "-100.00", lines: [ { amount: "-60.00", category: categories(:groceries) }, { amount: "-40.00" } ])

    assert expense.save
    assert_equal 2, expense.lines.count
    assert expense.expense?
    assert_not expense.income?
  end

  test "status defaults to confirmed" do
    assert_equal "confirmed", Transaction.new.status
    assert build_expense.tap(&:save!).confirmed?
  end

  test "amount is required, non-zero and fits decimal(15, 2)" do
    assert_not build_expense(amount: nil).valid?
    assert_not build_expense(amount: 0, lines: [ { amount: -1 } ]).valid?

    too_big = -(10**13)
    expense = build_expense(amount: too_big, lines: [ { amount: too_big } ])
    assert_not expense.valid?
    assert_includes expense.errors[:amount], "must be greater than -10000000000000"

    largest = BigDecimal("-9999999999999.99")
    assert build_expense(amount: largest, lines: [ { amount: largest } ]).valid?
  end

  test "an income is positive" do
    income = build_expense(amount: "250.00", lines: [ { amount: "250.00" } ])

    assert income.valid?
    assert income.income?
    assert_not income.expense?
  end

  test "account and occurred_on are required" do
    assert_not build_expense(account: nil).valid?

    expense = build_expense(occurred_on: nil)
    assert_not expense.valid?
    assert_includes expense.errors[:occurred_on], "can't be blank"
  end

  test "occurred_at is optional and independent of occurred_on" do
    late_evening = Time.zone.parse("2026-10-10 23:30")
    expense = build_expense(occurred_on: Date.new(2026, 10, 11), occurred_at: late_evening)

    assert expense.save
    assert_equal Date.new(2026, 10, 11), expense.reload.occurred_on
    assert_equal late_evening, expense.occurred_at
    assert build_expense(occurred_at: nil).valid?
  end

  test "source is required and must be listed" do
    assert build_expense(source: :api).valid?
    assert_not build_expense(source: nil).valid?

    expense = build_expense(source: "spreadsheet")
    assert_not expense.valid?
    assert_includes expense.errors[:source], "is not included in the list"
  end

  test "source and status are stored as readable strings" do
    assert_equal [ "bank", "needs_review" ], Transaction.where(id: transactions(:subscription)).pick(:source, :status)
    assert transactions(:subscription).from_bank?
    assert_includes Transaction.from_receipt, transactions(:market_split)
    assert_equal %w[legacy receipt manual api bank], Transaction.sources.values
    assert_equal %w[draft needs_review confirmed], Transaction.statuses.values
  end

  test "status must be listed" do
    assert build_expense(status: :draft).valid?

    expense = build_expense(status: "done")
    assert_not expense.valid?
    assert_includes expense.errors[:status], "is not included in the list"
    assert_not build_expense(status: nil).valid?
  end

  test "mcc is four digits when present" do
    assert build_expense(mcc: "5411").valid?
    assert_nil build_expense(mcc: " ").mcc

    [ "541", "54111", "54a1" ].each do |mcc|
      expense = build_expense(mcc:)
      assert_not expense.valid?, mcc
      assert_includes expense.errors[:mcc], "must be exactly four digits"
    end
  end

  test "external id is unique within its source" do
    expense = build_expense(source: :bank, external_id: "example-bank-0001")
    assert_not expense.valid?
    assert_includes expense.errors[:external_id], "has already been taken"

    assert build_expense(source: :api, external_id: "example-bank-0001").valid?
    assert_nil build_expense(external_id: " ").external_id
  end

  test "many transactions of one source may have no external id" do
    assert build_expense.save
    assert build_expense.save
  end

  test "original amount and currency are set together" do
    expense = build_expense(original_amount: "-2.50")
    assert_not expense.valid?
    assert_includes expense.errors[:base], "Original amount and original currency must be set together"

    expense = build_expense(original_currency: "USD")
    assert_not expense.valid?
    assert_includes expense.errors[:base], "Original amount and original currency must be set together"

    assert build_expense(original_amount: "-2.50", original_currency: "usd").valid?
  end

  test "original currency is three letters and differs from the account's" do
    expense = build_expense(original_amount: "-2.50", original_currency: "US")
    assert_not expense.valid?
    assert_includes expense.errors[:original_currency], "must be three letters (ISO 4217)"

    expense = build_expense(original_amount: "-2.50", original_currency: "UAH")
    assert_not expense.valid?
    assert_includes expense.errors[:original_currency], "must differ from the account currency"
  end

  test "original amount is non-zero, in range and has the sign of the amount" do
    expense = build_expense(original_amount: 0, original_currency: "USD")
    assert_not expense.valid?
    assert_includes expense.errors[:original_amount], "must be other than 0"

    expense = build_expense(original_amount: "2.50", original_currency: "USD")
    assert_not expense.valid?
    assert_includes expense.errors[:original_amount], "must have the same sign as the amount"

    expense = build_expense(original_amount: -(10**13), original_currency: "USD")
    assert_not expense.valid?
    assert_includes expense.errors[:original_amount], "must be less than 10000000000000 in magnitude"
  end

  test "a transaction can move to another account in the same currency only" do
    coffee = transactions(:coffee)

    assert_not coffee.update(account: accounts(:savings_usd))
    assert_includes coffee.errors[:account], "cannot change to an account in another currency (UAH to USD): " \
      "the amount would keep its number and change its meaning; enter it again on the new account"
    assert_equal accounts(:card_uah), coffee.reload.account

    assert coffee.update(account: accounts(:cash_uah))
  end

  test "a payee id that does not exist is a validation error" do
    expense = build_expense(payee_id: Payee.maximum(:id) + 1)

    assert_not expense.valid?
    assert_includes expense.errors[:payee], "does not exist"
  end

  test "a transaction needs at least one line" do
    expense = build_expense(lines: [])

    assert_not expense.valid?
    assert_includes expense.errors[:lines], "must have at least one line"
  end

  test "lines must add up exactly to the amount" do
    expense = build_expense(amount: "-100.00", lines: [ { amount: "-60.00" }, { amount: "-39.99" } ])

    assert_not expense.valid?
    assert_includes expense.errors[:lines], "must add up to the transaction amount"
  end

  test "a line may have the opposite sign (a deposit returned)" do
    expense = build_expense(amount: "-95.00", lines: [ { amount: "-100.00" }, { amount: "5.00" } ])

    assert expense.save
    assert_equal [ BigDecimal("-100"), BigDecimal("5") ], expense.lines.map(&:amount)
  end

  test "lines marked for destruction do not count" do
    split = transactions(:market_split)
    split.assign_attributes(amount: "-1000.40", lines_attributes: [ { id: transaction_lines(:market_household).id, _destroy: "1" } ])

    assert split.save
    assert_equal [ transaction_lines(:market_groceries) ], split.lines.reload.to_a
  end

  test "lines can be replaced through the transaction" do
    split = transactions(:market_split)
    attributes = split.lines.map { |line| { id: line.id, _destroy: "1" } } + [ { amount: "-1250.40", category: categories(:groceries) } ]

    assert split.update(lines_attributes: attributes)
    assert_equal [ BigDecimal("-1250.40") ], split.lines.reload.map(&:amount)
  end

  # Two copies of one transaction, both with their lines loaded, as two parallel requests would hold them.
  def two_copies(transaction)
    Array.new(2) { Transaction.find(transaction.id).tap { |copy| copy.lines.load } }
  end

  test "a stale copy cannot save after another copy changed the amount and lines" do
    expense = build_expense.tap(&:save!)
    first, second = two_copies(expense)
    line_id = first.lines.first.id

    assert first.update(amount: "-120.00", lines_attributes: [ { id: line_id, amount: "-120.00" } ])
    assert_raises(ActiveRecord::StaleObjectError) do
      second.update(amount: "-120.00", lines_attributes: [ { amount: "-20.00" } ])
    end

    expense.reload
    assert_equal BigDecimal("-120"), expense.amount
    assert_equal [ BigDecimal("-120") ], expense.lines.map(&:amount)
  end

  test "a change of lines only conflicts with a parallel change of lines only" do
    expense = build_expense.tap(&:save!)
    first, second = two_copies(expense)
    line_id = first.lines.first.id

    assert first.update(lines_attributes: [ { id: line_id, amount: "-60.00" }, { amount: "-40.00" } ])
    assert_raises(ActiveRecord::StaleObjectError) do
      second.update(lines_attributes: [ { id: line_id, amount: "-70.00" }, { amount: "-30.00" } ])
    end

    assert_equal BigDecimal("-100"), expense.reload.lines.sum(:amount)
    assert_equal 2, expense.lines.count
  end

  test "a lines-only change bumps lock_version; a save without changes does not" do
    expense = build_expense.tap(&:save!)

    assert_no_changes -> { expense.reload.lock_version } do
      assert expense.save
    end
    assert_changes -> { expense.reload.lock_version }, from: 0, to: 1 do
      expense.update!(lines_attributes: [ { id: expense.lines.first.id, comment: "Lunch" } ])
    end
  end

  test "a stale copy cannot be destroyed" do
    stale = Transaction.find(transactions(:coffee).id)
    transactions(:coffee).update!(comment: "Flat white")

    assert_raises(ActiveRecord::StaleObjectError) { stale.destroy }
    assert Transaction.exists?(stale.id)
  end

  test "scopes" do
    assert_includes Transaction.expenses, transactions(:coffee)
    assert_not_includes Transaction.expenses, transactions(:salary)
    assert_equal [ transactions(:salary) ], Transaction.incomes.to_a
    assert_equal [ transactions(:snack), transactions(:market_split) ], Transaction.between(Date.new(2026, 10, 3), Date.new(2026, 10, 4)).recent.to_a
  end

  test "destroying a transaction destroys its lines" do
    assert_difference -> { TransactionLine.count }, -2 do
      transactions(:market_split).destroy!
    end
  end

  test "the database rejects a zero amount" do
    assert_violates("transactions_amount_non_zero") { transactions(:coffee).update_column(:amount, 0) }
  end

  test "the database checks the original amount pair" do
    assert_violates("transactions_original_amount_consistent") { transactions(:subscription).update_column(:original_currency, nil) }
    assert_violates("transactions_original_amount_consistent") { transactions(:subscription).update_column(:original_amount, 20) }
    assert_violates("transactions_original_amount_consistent") do
      Transaction.insert_all!([ row(original_amount: 0, original_currency: "USD") ])
    end
  end

  test "the database checks the original currency format" do
    assert_violates("transactions_original_currency_format") do
      Transaction.where(id: transactions(:subscription)).update_all("original_currency = 'usd'")
    end
  end

  test "the database checks the mcc format" do
    assert_violates("transactions_mcc_format") { transactions(:coffee).update_column(:mcc, "58a4") }
  end

  test "the database checks source and status values" do
    assert_violates("transactions_source_allowed") { Transaction.insert_all!([ row(source: "spreadsheet") ]) }
    assert_violates("transactions_status_allowed") { Transaction.insert_all!([ row(status: "done") ]) }
  end

  test "the database keeps external ids unique per source" do
    assert_violates("index_transactions_on_source_and_external_id", ActiveRecord::RecordNotUnique) do
      Transaction.insert_all!([ row(source: "bank", external_id: "example-bank-0001") ])
    end
    assert_nothing_raised { Transaction.insert_all!([ row(source: "bank"), row(source: "bank") ]) }
  end
end

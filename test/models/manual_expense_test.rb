require "test_helper"

class ManualExpenseTest < ActiveSupport::TestCase
  def expense(**attributes)
    ManualExpense.new({ account_id: accounts(:cash_uah).id, payee_name: "Corner Shop", occurred_on: "2026-10-08",
                        rows: { "0" => { name: "Bread", amount: "40,40", category_id: categories(:groceries).id.to_s },
                                "1" => { name: "Soap", amount: "25.00", category_id: categories(:household_supplies).id.to_s },
                                "2" => { name: "Cheese", amount: "100.10", category_id: categories(:groceries).id.to_s } } }.merge(attributes))
  end

  test "saving books one manual expense whose lines are the row amounts summed per category" do
    record = expense(occurred_time: "18:40")

    assert_difference -> { Transaction.count }, 1 do
      assert record.save
    end

    transaction = record.transaction
    assert transaction.from_manual?
    assert transaction.confirmed?
    assert_equal BigDecimal("-165.50"), transaction.amount
    assert_equal accounts(:cash_uah), transaction.account
    assert_equal Date.new(2026, 10, 8), transaction.occurred_on
    assert_equal Time.zone.local(2026, 10, 8, 18, 40), transaction.occurred_at
    assert_equal "Corner Shop", transaction.payee.name
    assert_equal [ [ categories(:groceries).id, BigDecimal("-140.50") ], [ categories(:household_supplies).id, BigDecimal("-25.00") ] ],
      transaction.lines.map { |line| [ line.category_id, line.amount ] }
  end

  test "a row without a category gives an uncategorised line and the expense needs review; no time means no occurred_at" do
    record = expense(rows: [ { amount: "10" } ])

    assert record.save
    assert record.transaction.needs_review?
    assert_nil record.transaction.occurred_at
    assert_equal [ nil ], record.transaction.lines.map(&:category_id)
  end

  test "completely blank rows are dropped; at least one row is needed" do
    record = expense(rows: [ { name: "", amount: "", category_id: "" } ])

    assert_not record.save
    assert_equal [ "Add at least one row with an amount" ], record.errors[:base]
    assert_empty record.rows
  end

  test "amounts are validated as typed: more than two places or not a number is an error on the row, never rounded" do
    record = expense(rows: [ { name: "A", amount: "1.005" }, { name: "B", amount: "1e3" }, { name: "C", amount: "" }, { name: "D", amount: "5" } ])

    assert_no_difference -> { Transaction.count } do
      assert_not record.save
    end
    assert_equal [ [ "must have at most 2 decimal places (it is never rounded)" ], [ MoneyInput::MESSAGE ], [ "can't be blank" ], [] ],
      record.rows.map { |row| row.errors[:amount] }
    assert_equal "1.005", record.rows.first.amount
  end

  test "the rows must sum above zero: incomes are not entered here" do
    record = expense(rows: [ { amount: "5" }, { amount: "-5" } ])

    assert_not record.save
    assert_match "must sum above zero", record.errors[:base].first
  end

  test "the account must be active, the date a date, the time a time, a category a category" do
    record = expense(account_id: accounts(:old_wallet).id, occurred_on: "2026-13-01", occurred_time: "25:00",
                     rows: [ { amount: "1", category_id: categories(:groceries_group).id.to_s } ])

    assert_not record.save
    assert record.errors[:account_id].any?
    assert_equal [ "must be a date" ], record.errors[:occurred_on]
    assert_equal [ "must be a time such as 18:40" ], record.errors[:occurred_time]
    assert_equal [ "must be a category, not a group" ], record.rows.first.errors[:category_id]
  end

  test "a failure after the payee was created leaves neither a payee nor a transaction" do
    record = expense(payee_name: "A brand new shop")
    failing = ->(*) { raise ActiveRecord::RecordInvalid, Transaction.new }

    assert_no_difference [ "Payee.count", "Transaction.count", "TransactionLine.count" ] do
      with_singleton_method(Transaction, :create!, failing) { assert_not record.save }
    end
    assert_nil record.transaction
  end

  test "a blank payee name creates no payee" do
    record = expense(payee_name: "  ")

    assert_no_difference -> { Payee.count } do
      assert record.save
    end
    assert_nil record.transaction.payee
  end
end

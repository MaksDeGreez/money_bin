require "test_helper"

class Transaction::TransferableTest < ActiveSupport::TestCase
  def transfer!(**arguments)
    Transaction.transfer!(**{ from: accounts(:card_uah), to: accounts(:cash_uah), amount: BigDecimal("500"),
                              occurred_on: Date.new(2026, 10, 12) }.merge(arguments))
  end

  def assert_violates(constraint, error = ActiveRecord::StatementInvalid, &block)
    exception = assert_raises(error) { Transaction.transaction(requires_new: true, &block) }
    assert_includes exception.message, constraint
  end

  def leg_row(**attributes)
    { account_id: accounts(:cash_uah).id, amount: 5, occurred_on: Date.current, source: "manual",
      transfer_id: transactions(:withdrawal_in).transfer_id }.merge(attributes)
  end

  test "transfer! creates two legs that share a transfer id" do
    out_leg, in_leg = nil
    assert_difference -> { Transaction.count }, 2 do
      out_leg, in_leg = transfer!(comment: "Pocket money", occurred_at: Time.zone.parse("2026-10-12 10:00"))
    end

    assert_equal BigDecimal("-500"), out_leg.amount
    assert_equal BigDecimal("500"), in_leg.amount
    assert_equal accounts(:card_uah), out_leg.account
    assert_equal accounts(:cash_uah), in_leg.account
    assert_equal out_leg.transfer_id, in_leg.transfer_id
    assert out_leg.transfer_leg? && in_leg.transfer_leg?
    assert_equal "Pocket money", in_leg.comment
    assert in_leg.from_manual?
    assert in_leg.confirmed?
    assert_empty out_leg.lines
    assert_empty out_leg.transfer_problems
  end

  test "transfer! takes both amounts for a cross-currency transfer" do
    out_leg, in_leg = transfer!(to: accounts(:savings_usd), amount: BigDecimal("4150"), to_amount: BigDecimal("100"),
                                source: :bank, status: :needs_review)

    assert_equal BigDecimal("-4150"), out_leg.amount
    assert_equal BigDecimal("100"), in_leg.amount
    assert in_leg.from_bank?
    assert in_leg.needs_review?
  end

  test "transfer! needs to_amount when the currencies differ" do
    error = assert_raises(ArgumentError) { transfer!(to: accounts(:savings_usd)) }
    assert_match "to_amount is required", error.message
  end

  test "transfer! accepts any real Numeric" do
    out_leg, in_leg = transfer!(amount: Rational(5, 2))

    assert_equal BigDecimal("-2.5"), out_leg.reload.amount
    assert_equal BigDecimal("2.5"), in_leg.reload.amount
  end

  test "transfer! rolls back both legs when same-currency amounts do not net to zero" do
    assert_no_difference -> { Transaction.count } do
      error = assert_raises(ActiveRecord::RecordInvalid) { transfer!(to_amount: BigDecimal("490")) }
      assert_match "must net to zero", error.message
    end
  end

  test "transfer! needs two different accounts" do
    error = assert_raises(ArgumentError) { transfer!(to: accounts(:card_uah)) }
    assert_match "two different accounts", error.message
  end

  test "transfer! needs positive numeric amounts" do
    [ 0, -5, "500", nil, Float::NAN, Float::INFINITY, Complex(1, 1) ].each do |amount|
      assert_no_difference -> { Transaction.count } do
        assert_raises(ArgumentError, amount.inspect) { transfer!(amount:, to_amount: 500) }
      end
    end
  end

  test "counterpart" do
    assert_equal transactions(:withdrawal_in), transactions(:withdrawal_out).counterpart
    assert_equal transactions(:savings_out), transactions(:savings_in).counterpart
    assert_nil transactions(:coffee).counterpart
  end

  test "transfer legs are not expenses or incomes" do
    leg = transactions(:withdrawal_out)

    assert_not leg.expense?
    assert_not transactions(:withdrawal_in).income?
    assert_includes Transaction.transfer_legs, leg
    assert_not_includes Transaction.expenses, leg
    assert_not_includes Transaction.incomes, transactions(:withdrawal_in)
  end

  test "the fixture transfers have no problems" do
    assert_empty Transaction.transfer_problems(transactions(:withdrawal_out).transfer_id)
    assert_empty transactions(:savings_in).transfer_problems
    assert_empty transactions(:coffee).transfer_problems
  end

  test "transfer_problems finds a lone leg and a missing transfer" do
    transfer_id = SecureRandom.uuid
    Transaction.insert_all!([ leg_row(transfer_id:) ])

    assert_equal [ "a transfer needs exactly two legs, found 1" ], Transaction.transfer_problems(transfer_id)
    assert_equal [ "a transfer needs exactly two legs, found 0" ], Transaction.transfer_problems(SecureRandom.uuid)
  end

  test "transfer_problems finds legs with lines, on one account, or not netting to zero" do
    out_leg = transactions(:withdrawal_out)
    TransactionLine.insert_all!([ { transaction_id: out_leg.id, amount: -2000 } ])
    transactions(:withdrawal_in).update_columns(account_id: out_leg.account_id, amount: 1990)

    assert_equal [ "a transfer leg cannot have lines", "the two legs must be on different accounts",
                   "the two legs must net to zero when both accounts use the same currency (a fee is a separate expense)" ],
      out_leg.transfer_problems
  end

  # The database index already refuses two stored legs with the same sign, so this is checked in memory.
  test "pair_problems finds legs with the same sign" do
    other = Transaction.new(account: accounts(:savings_usd), amount: -1)

    assert_equal [ "the two legs must have opposite signs" ], Transaction.pair_problems(transactions(:savings_out), other)
  end

  test "a cross-currency pair may have any two amounts" do
    leg = transactions(:savings_in)

    assert leg.update(amount: BigDecimal("1012.34"))
    assert_empty leg.transfer_problems
  end

  test "a same-currency leg cannot change its amount alone" do
    leg = transactions(:withdrawal_in)

    assert_not leg.update(amount: BigDecimal("1990"))
    assert_includes leg.errors[:base], "The two legs must net to zero when both accounts use the same currency (a fee is a separate expense)"
  end

  test "a leg cannot flip its sign" do
    leg = transactions(:savings_in)

    assert_not leg.update(amount: BigDecimal("-1000"))
    assert_includes leg.errors[:base], "The two legs must have opposite signs"
  end

  test "a leg cannot move onto its counterpart's account" do
    leg = transactions(:withdrawal_in)

    assert_not leg.update(account: accounts(:card_uah))
    assert_includes leg.errors[:base], "The two legs must be on different accounts"
  end

  test "other fields of a leg can change" do
    assert transactions(:withdrawal_in).update(comment: "ATM on the corner", occurred_on: Date.new(2026, 10, 7))
  end

  test "a transfer cannot get a third leg" do
    third = Transaction.new(account: accounts(:savings_usd), amount: 1, occurred_on: Date.current, source: :manual,
                            transfer_id: transactions(:withdrawal_in).transfer_id)

    assert_not third.valid?
    assert_includes third.errors[:transfer_id], "already has two legs"
  end

  test "a transfer leg has no lines" do
    leg = transactions(:withdrawal_in)
    leg.lines.build(amount: 2000)

    assert_not leg.valid?
    assert_includes leg.errors[:lines], "must be empty for a transfer leg"
  end

  test "a line cannot be added to a transfer leg on its own" do
    line = TransactionLine.new(parent: transactions(:withdrawal_in), amount: 2000)

    assert_not line.valid?
    assert_includes line.errors[:parent], "is a transfer leg, which cannot have lines"
  end

  test "a leg cannot leave its transfer" do
    leg = transactions(:withdrawal_in)

    assert_not leg.update(transfer_id: nil, lines_attributes: [ { amount: 2000 } ])
    assert_includes leg.errors[:transfer_id], "cannot change once set: the other leg would be left alone"
    assert_not leg.update(transfer_id: SecureRandom.uuid)
  end

  test "an expense can become a transfer leg by dropping its lines" do
    expense = transactions(:snack)
    transfer_id = SecureRandom.uuid
    lines = expense.lines.map { |line| { id: line.id, _destroy: "1" } }

    assert expense.update(transfer_id:, lines_attributes: lines)
    Transaction.create!(account: accounts(:card_uah), amount: 60, occurred_on: expense.occurred_on, source: :manual, transfer_id:)
    assert_empty Transaction.transfer_problems(transfer_id)
  end

  test "destroying one leg destroys the other" do
    out_leg, in_leg = transactions(:withdrawal_out), transactions(:withdrawal_in)

    assert_difference -> { Transaction.count }, -2 do
      out_leg.destroy!
    end
    assert_not Transaction.exists?(in_leg.id)
  end

  test "the database refuses a third leg" do
    assert_violates("index_transactions_one_leg_per_side", ActiveRecord::RecordNotUnique) do
      Transaction.insert_all!([ leg_row(account_id: accounts(:savings_usd).id, amount: 1) ])
    end
  end

  test "the database refuses two legs with the same sign" do
    transfer_id = SecureRandom.uuid

    assert_violates("index_transactions_one_leg_per_side", ActiveRecord::RecordNotUnique) do
      Transaction.insert_all!([ leg_row(transfer_id:, amount: -5), leg_row(transfer_id:, amount: -7, account_id: accounts(:card_uah).id) ])
    end
  end
end

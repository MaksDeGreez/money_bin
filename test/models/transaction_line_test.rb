require "test_helper"

class TransactionLineTest < ActiveSupport::TestCase
  test "belongs to its transaction as parent" do
    assert_equal transactions(:market_split), transaction_lines(:market_groceries).parent
  end

  test "category is optional" do
    line = transaction_lines(:coffee_line)
    line.category = nil

    assert line.valid?
  end

  test "a category must be a leaf, not a group" do
    line = transaction_lines(:coffee_line)
    line.category = categories(:eating_out)

    assert_not line.valid?
    assert_includes line.errors[:category], "must be a category, not a group"
  end

  test "a category id that does not exist is a validation error" do
    line = transaction_lines(:coffee_line)
    line.category_id = Category.maximum(:id) + 1

    assert_not line.valid?
    assert_includes line.errors[:category], "does not exist"
  end

  test "an unchanged category is not looked up again" do
    line = transaction_lines(:coffee_line)
    line.comment = "Flat white"

    assert_queries_match(/FROM "categories"/, count: 0) { assert line.valid? }
  end

  test "amount is required and non-zero" do
    assert_not transactions(:coffee).lines.build.valid?
    assert_not transactions(:coffee).lines.build(amount: 0).valid?
  end

  test "amount must fit decimal(15, 2)" do
    line = transactions(:salary).lines.build(amount: 10**13)

    assert_not line.valid?
    assert_includes line.errors[:amount], "must be less than 10000000000000"
  end

  test "legacy category path is kept and blank becomes nil" do
    assert_equal "Food / Snacks", transaction_lines(:snack_line).legacy_category_path
    assert_nil TransactionLine.new(legacy_category_path: "  ").legacy_category_path
  end

  test "category and comment can be changed on their own" do
    line = TransactionLine.find(transaction_lines(:subscription_line).id)

    assert line.update(category: categories(:takeaway), comment: "Streaming plan")
    assert_equal "Streaming plan", line.reload.comment
  end

  test "a standalone amount change that breaks the sum is rejected" do
    line = TransactionLine.find(transaction_lines(:coffee_line).id)

    assert_not line.update(amount: "-80.00")
    assert_includes line.errors[:amount], "must keep the lines adding up to the transaction amount"
    assert_equal BigDecimal("-85"), line.reload.amount
  end

  test "a standalone line added to a transaction must keep the sum" do
    assert_no_difference -> { TransactionLine.count } do
      assert_not transactions(:coffee).lines.create(amount: -1).persisted?
    end
  end

  test "a standalone line compares itself with the stored amount, not an unsaved one" do
    coffee = Transaction.find(transactions(:coffee).id)
    coffee.amount = "-50.00"
    line = coffee.lines.first

    assert_not line.update(amount: "-50.00")
    assert_includes line.errors[:amount], "must keep the lines adding up to the transaction amount"
    assert_equal [ BigDecimal("-85"), [ BigDecimal("-85") ] ], [ coffee.reload.amount, coffee.lines.map(&:amount) ]
  end

  test "a standalone line compares itself with the stored sibling lines, not loaded ones" do
    split = Transaction.find(transactions(:market_split).id)
    groceries, household = split.lines.to_a
    TransactionLine.where(id: household.id).update_all(amount: "-200.00") # the sum is now 50 short

    assert_not groceries.update(amount: "-1000.40")
    assert groceries.update(amount: "-1050.40")
    assert_equal split.amount, split.lines.sum(:amount)
  end

  test "a standalone amount write locks the transaction row and bumps its lock_version" do
    split = transactions(:market_split)
    TransactionLine.where(id: transaction_lines(:market_household).id).update_all(amount: "-200.00")
    line = TransactionLine.find(transaction_lines(:market_household).id)

    assert_queries_match(/FROM "transactions" WHERE .* FOR UPDATE/) do
      assert line.update(amount: "-250.00")
    end
    assert_equal 1, split.reload.lock_version
  end

  test "a category change on its own does not lock or bump the transaction" do
    line = TransactionLine.find(transaction_lines(:coffee_line).id)

    assert_no_queries_match(/FOR UPDATE/) { assert line.update(category: categories(:takeaway)) }
    assert_equal 0, transactions(:coffee).reload.lock_version
  end

  test "a standalone line checks the stored row for a transfer leg" do
    expense = transactions(:snack)
    stale = Transaction.find(expense.id)
    expense.update!(transfer_id: SecureRandom.uuid, lines_attributes: expense.lines.map { |line| { id: line.id, _destroy: "1" } })

    line = TransactionLine.new(parent: stale, amount: "-60.00")
    assert_not line.save
    assert_equal [ "is a transfer leg, which cannot have lines" ], line.errors[:parent]
  end

  test "a standalone line cannot be added to an unsaved transaction" do
    expense = Transaction.new(account: accounts(:cash_uah), amount: -5, occurred_on: Date.current, source: :manual)
    line = TransactionLine.new(parent: expense, amount: -5)

    assert_not line.valid?
    assert_includes line.errors[:parent], "must be saved first: add new lines through the transaction"
  end

  test "a line cannot be moved to another transaction on its own" do
    line = TransactionLine.find(transaction_lines(:coffee_line).id)
    line.parent = transactions(:snack)

    assert_not line.valid?
    assert_includes line.errors[:parent], "cannot change: the old transaction's lines would no longer add up"
  end

  test "a line cannot be destroyed on its own" do
    line = TransactionLine.find(transaction_lines(:market_household).id)

    assert_no_difference -> { TransactionLine.count } do
      assert_not line.destroy
    end
    assert_raises(ActiveRecord::RecordNotDestroyed) { line.destroy! }
    assert_match "cannot be removed on its own", line.errors.full_messages.to_sentence
  end

  test "the database rejects a zero amount" do
    error = assert_raises(ActiveRecord::StatementInvalid) { transaction_lines(:coffee_line).update_column(:amount, 0) }
    assert_includes error.message, "transaction_lines_amount_non_zero"
  end

  test "a category with lines cannot be destroyed" do
    assert_not categories(:cafes).destroy
    assert Category.exists?(categories(:cafes).id)
  end
end

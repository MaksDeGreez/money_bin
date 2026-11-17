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

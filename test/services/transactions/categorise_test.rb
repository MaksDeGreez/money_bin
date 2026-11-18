require "test_helper"

class Transactions::CategoriseTest < ActiveSupport::TestCase
  Choice = Transactions::Categorise::Choice
  VERSION = "2026-11-18-0123456789ab".freeze

  setup do
    @transaction = transactions(:subscription)
    @line = transaction_lines(:subscription_line)
  end

  def take(line = @line, category: categories(:household_supplies), origin: "suggestion", lock_version: Transaction.find(line.transaction_id).lock_version)
    choice = Choice.new(line_id: line.id, category_id: category.id, origin:, probability: (0.91 unless origin == "person"),
      model_version: (VERSION unless origin == "person"))
    Transactions::Categorise.call(line.transaction_id, lock_version:, choices: [ choice ])
  end

  test "taking the suggestion categorises the line, records it, and confirms the transaction" do
    version = @transaction.lock_version

    result = take

    assert result.categorised?
    @line.reload
    assert_equal categories(:household_supplies), @line.category
    assert_equal [ "suggestion", 0.91, VERSION ], [ @line.category_origin, @line.category_origin_probability, @line.category_origin_model_version ]
    assert_equal "confirmed", @transaction.reload.status
    assert_operator @transaction.lock_version, :>, version
    assert_equal BigDecimal("-830.00"), @line.amount
  end

  test "a category chosen by hand is recorded as the person's, without a probability" do
    take(category: categories(:cafes), origin: "person")

    @line.reload
    assert_equal [ categories(:cafes), "person", nil, nil ], [ @line.category, @line.category_origin, @line.category_origin_probability, @line.category_origin_model_version ]
  end

  test "a line in Uncategorised counts as uncategorised" do
    @line.update!(category: categories(:uncategorised))

    assert take.categorised?
    assert_equal categories(:household_supplies), @line.reload.category
  end

  test "a category a person chose is never overwritten" do
    line = transaction_lines(:coffee_line)

    result = take(line, category: categories(:groceries))

    assert_equal :changed, result.status
    assert_equal categories(:cafes), line.reload.category
    assert_nil line.category_origin
  end

  test "an edit made after the page was loaded wins: a stale version writes nothing" do
    seen = @transaction.lock_version
    @transaction.update!(comment: "edited elsewhere")

    result = take(lock_version: seen)

    assert_equal :stale, result.status
    assert_nil @line.reload.category
    assert_equal "needs_review", @transaction.reload.status
  end

  test "a split transaction is handled line by line and stays to be reviewed while a line is uncategorised" do
    split = Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 8), amount: BigDecimal("-100"), source: "bank",
      merchant: "Invented Shop", status: "needs_review", lines_attributes: [ { amount: BigDecimal("-60") }, { amount: BigDecimal("-40") } ])
    first, second = split.lines.to_a

    assert take(first, category: categories(:groceries), origin: "person").categorised?
    assert_equal "needs_review", split.reload.status
    assert_nil second.reload.category

    assert take(second, category: categories(:household_supplies), origin: "person").categorised?
    assert_equal "confirmed", split.reload.status
  end

  test "a draft stays a draft, and a confirmed transaction stays confirmed" do
    @transaction.update!(status: "draft")
    assert take.categorised?
    assert_equal "draft", @transaction.reload.status
  end

  test "a receipt's other reason to review keeps the transaction to be reviewed" do
    receipt = receipts(:market_receipt)
    transaction = receipt.ledger_transaction
    line = transaction.lines.first
    line.update!(category: nil)
    transaction.update!(status: "needs_review")
    receipt.update_columns(total: receipt.items_total + 1)

    assert take(line, category: categories(:groceries), origin: "person").categorised?
    assert_equal "needs_review", transaction.reload.status
  end

  test "a group, Uncategorised, an unknown origin or no choice at all is refused" do
    [ categories(:groceries_group), categories(:uncategorised) ].each do |category|
      assert_equal :invalid, take(category:, origin: "person").status
    end
    choice = Choice.new(line_id: @line.id, category_id: categories(:cafes).id, origin: "robot", probability: nil, model_version: nil)
    assert_equal :invalid, Transactions::Categorise.call(@transaction.id, lock_version: @transaction.lock_version, choices: [ choice ]).status
    assert_equal :invalid, Transactions::Categorise.call(@transaction.id, lock_version: @transaction.lock_version, choices: []).status
    assert_nil @line.reload.category
  end

  test "a transfer leg or a missing transaction is left alone" do
    leg = transactions(:withdrawal_out)
    choice = Choice.new(line_id: 0, category_id: categories(:cafes).id, origin: "person", probability: nil, model_version: nil)

    assert_equal :changed, Transactions::Categorise.call(leg.id, lock_version: leg.lock_version, choices: [ choice ]).status
    assert_equal :changed, Transactions::Categorise.call(0, lock_version: 0, choices: [ choice ]).status
  end

  test "a taken suggestion without its probability is refused by the database too" do
    assert_raises(ActiveRecord::StatementInvalid) do
      @line.update_columns(category_origin: "bulk", category_origin_probability: nil, category_origin_model_version: nil)
    end
  end
end

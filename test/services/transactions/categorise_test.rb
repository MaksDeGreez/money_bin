require "test_helper"

class Transactions::CategoriseTest < ActiveSupport::TestCase
  Choice = Transactions::Categorise::Choice
  VERSION = "2026-11-18-0123456789ab".freeze

  setup do
    @transaction = transactions(:subscription)
    @line = transaction_lines(:subscription_line)
  end

  def take(line = @line, category: categories(:household_supplies), origin: "suggestion", lock_version: Transaction.find(line.transaction_id).lock_version,
    shown: line.reload.suggested_category_id, shown_version: line.suggestion_model_version)
    choice = Choice.new(line_id: line.id, category_id: category.id, origin:, shown_category_id: shown, shown_model_version: shown_version)
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

  test "a transaction booked from a receipt is categorised on the receipt, never here" do
    transaction = receipts(:market_receipt).ledger_transaction
    line = transaction.lines.first
    line.update!(category: nil)

    assert_equal :on_receipt, take(line, category: categories(:groceries), origin: "person").status
    assert_nil line.reload.category
  end

  test "a receipt's other reason to review keeps the transaction to be reviewed" do
    receipt = receipts(:market_receipt)
    transaction = receipt.ledger_transaction
    receipt.update_columns(total: receipt.items_total + 1)
    transaction.status = "needs_review"

    assert_empty transaction.lines.select(&:uncategorised?)
    assert_equal "needs_review", transaction.status_after_categorising
    receipt.update_columns(total: receipt.items_total)
    assert_equal "confirmed", Transaction.find(transaction.id).tap { |t| t.status = "needs_review" }.status_after_categorising
  end

  test "a save the ledger's rules refuse is invalid, not an exception" do
    @transaction.update_columns(original_currency: "UAH")

    assert_equal :invalid, take.status
    assert_nil @line.reload.category
  end

  test "a line's origin needs its category, and a taken suggestion its probability and artefact" do
    @line.category_origin = "bulk"
    assert_not @line.valid?
    assert_includes @line.errors[:category], "must be set when its origin is"
    assert_includes @line.errors[:category_origin_probability], "can't be blank"
    assert_includes @line.errors[:category_origin_model_version], "can't be blank"
  end

  test "a group, Uncategorised, an unknown origin or no choice at all is refused" do
    [ categories(:groceries_group), categories(:uncategorised) ].each do |category|
      assert_equal :invalid, take(category:, origin: "person").status
    end
    choice = Choice.new(line_id: @line.id, category_id: categories(:cafes).id, origin: "robot")
    assert_equal :invalid, Transactions::Categorise.call(@transaction.id, lock_version: @transaction.lock_version, choices: [ choice ]).status
    assert_equal :invalid, Transactions::Categorise.call(@transaction.id, lock_version: @transaction.lock_version, choices: []).status
    assert_nil @line.reload.category
  end

  test "a transfer leg or a missing transaction is left alone" do
    leg = transactions(:withdrawal_out)
    choice = Choice.new(line_id: 0, category_id: categories(:cafes).id, origin: "person")

    assert_equal :changed, Transactions::Categorise.call(leg.id, lock_version: leg.lock_version, choices: [ choice ]).status
    assert_equal :changed, Transactions::Categorise.call(0, lock_version: 0, choices: [ choice ]).status
  end

  test "a suggestion refreshed since it was shown saves nothing, taken or picked by hand" do
    shown_version = @line.suggestion_model_version
    @line.update_columns(suggested_category_id: categories(:cafes).id, suggestion_model_version: "2026-12-01-abcdefabcdef")

    assert_equal :changed, take(shown: categories(:household_supplies).id, shown_version:).status
    assert_equal :changed, take(category: categories(:groceries), origin: "person", shown: categories(:household_supplies).id, shown_version:).status
    assert_nil @line.reload.category
  end

  test "a taken suggestion must be the one shown, and records the stored probability" do
    assert_equal :invalid, take(category: categories(:cafes)).status
    assert_not take(shown: nil, shown_version: nil).categorised?
    assert take.categorised?
    assert_equal 0.91, @line.reload.category_origin_probability
  end

  test "a taken suggestion without its probability is refused by the database too" do
    assert_raises(ActiveRecord::StatementInvalid) do
      @line.update_columns(category_origin: "bulk", category_origin_probability: nil, category_origin_model_version: nil)
    end
  end

  # --- The edit mode ("Change") ------------------------------------------------------------------------------

  # Every line of `transaction` with the category the person saw (its category now unless `observed` says) and the
  # one chosen (`chosen`: { line => category or nil }; a line not named keeps its category).
  def change(transaction, chosen = {}, observed: {}, lock_version: transaction.reload.lock_version, origin: "person", shown: {})
    choices = transaction.lines.reload.map do |line|
      category = chosen.key?(line) ? chosen[line] : line.category
      Choice.new(line_id: line.id, category_id: category&.id, origin:, observed_category_id: observed.fetch(line, line.category)&.id, **shown)
    end
    Transactions::Categorise.call(transaction.id, lock_version:, choices:, edit: true)
  end

  def split(categories)
    amounts = categories.size == 3 ? [ -50, -30, -20 ] : [ -60, -40 ]
    Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 8), amount: BigDecimal("-100"), source: "bank",
      merchant: "Invented Shop", status: "needs_review",
      lines_attributes: categories.zip(amounts).map { |category, amount| { amount: BigDecimal(amount), category: } })
  end

  test "a person replaces a category: the line is theirs, the transaction confirmed, its version moved" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)
    version = coffee.lock_version

    result = change(coffee, { line => categories(:groceries) })

    assert result.categorised?
    line.reload
    assert_equal [ categories(:groceries), "person", nil, nil ], [ line.category, line.category_origin, line.category_origin_probability, line.category_origin_model_version ]
    assert_operator coffee.reload.lock_version, :>, version
    assert_equal BigDecimal("-85.00"), line.amount
  end

  test "a category set or changed since the form was shown saves nothing, even with the same version" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)
    line.update_columns(category_id: categories(:takeaway).id)

    result = change(coffee, { line => categories(:groceries) }, observed: { line => categories(:cafes) })

    assert_equal :changed, result.status
    assert_equal categories(:takeaway), line.reload.category
  end

  test "a split is saved together: changed lines written, the same category skipped, an empty line left empty" do
    transaction = split([ categories(:groceries), categories(:cafes), nil ])
    first, second, third = transaction.lines.to_a
    second.update_columns(category_origin: "person")

    result = change(transaction, { first => categories(:household_supplies), third => nil })

    assert result.categorised?
    assert_equal [ categories(:household_supplies), "person" ], [ first.reload.category, first.category_origin ]
    assert_equal [ categories(:cafes), "person" ], [ second.reload.category, second.category_origin ]
    assert_nil third.reload.category
    assert_equal "needs_review", transaction.reload.status, "a line is still uncategorised"

    assert change(transaction, { third => categories(:takeaway) }).categorised?
    assert_equal "confirmed", transaction.reload.status
  end

  test "a split with one line changed meanwhile writes none of its lines" do
    transaction = split([ categories(:groceries), categories(:cafes) ])
    first, second = transaction.lines.to_a
    second.update_columns(category_id: categories(:takeaway).id)

    result = change(transaction, { first => categories(:household_supplies), second => categories(:groceries) }, observed: { second => categories(:cafes) })

    assert_equal :changed, result.status
    assert_equal [ categories(:groceries), categories(:takeaway) ], [ first.reload.category, second.reload.category ]
  end

  test "the same categories are a no-op: nothing written, the version stays" do
    coffee = transactions(:coffee)
    version = coffee.lock_version
    updated_at = coffee.updated_at

    result = change(coffee)

    assert result.unchanged?
    assert result.saved?
    assert_equal [ version, updated_at ], [ coffee.reload.lock_version, coffee.updated_at ]
    assert_nil transaction_lines(:coffee_line).reload.category_origin
  end

  test "clearing a category is refused, and so are a group and Uncategorised" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)

    [ nil, categories(:groceries_group), categories(:uncategorised) ].each do |category|
      assert_equal :invalid, change(coffee, { line => category }).status
    end
    assert_equal categories(:cafes), line.reload.category
  end

  test "a taken suggestion is not part of the edit mode" do
    @line.update!(category: categories(:cafes))

    assert_equal :invalid, change(@transaction, { @line => categories(:household_supplies) }, origin: "suggestion",
      shown: { shown_category_id: categories(:household_supplies).id, shown_model_version: VERSION }).status
    assert_equal :invalid, change(@transaction, { @line => categories(:household_supplies) },
      shown: { shown_category_id: categories(:household_supplies).id, shown_model_version: VERSION }).status
    assert_equal [ categories(:cafes), nil ], [ @line.reload.category, @line.category_origin ]
  end

  test "overriding a taken suggestion makes the line the person's, with no probability, keeping the stored suggestion" do
    assert take.categorised?
    assert_equal "suggestion", @line.reload.category_origin

    assert change(@transaction, { @line => categories(:cafes) }).categorised?

    @line.reload
    assert_equal [ categories(:cafes), "person", nil, nil ], [ @line.category, @line.category_origin, @line.category_origin_probability, @line.category_origin_model_version ]
    assert_equal [ categories(:household_supplies).id, 0.91, VERSION ], [ @line.suggested_category_id, @line.suggestion_probability, @line.suggestion_model_version ]
  end

  test "an uncategorised line given its suggested category by hand is the person's label, not a taken suggestion" do
    assert change(@transaction, { @line => categories(:household_supplies) }).categorised?

    assert_equal [ categories(:household_supplies), "person", nil ], [ @line.reload.category, @line.category_origin, @line.category_origin_probability ]
    assert_equal "confirmed", @transaction.reload.status
  end

  test "a stale version saves nothing in the edit mode either" do
    coffee = transactions(:coffee)
    seen = coffee.lock_version
    coffee.update!(comment: "edited elsewhere")

    assert_equal :stale, change(coffee, { transaction_lines(:coffee_line) => categories(:groceries) }, lock_version: seen).status
    assert_equal categories(:cafes), transaction_lines(:coffee_line).reload.category
  end

  test "every line must come, once: a missing or doubled line saves nothing" do
    transaction = split([ categories(:groceries), categories(:cafes) ])
    first, second = transaction.lines.to_a
    choice = ->(line) { Choice.new(line_id: line.id, category_id: categories(:takeaway).id, origin: "person", observed_category_id: line.category_id) }

    assert_equal :changed, Transactions::Categorise.call(transaction.id, lock_version: transaction.lock_version, choices: [ choice.(first) ], edit: true).status
    assert_equal :invalid, Transactions::Categorise.call(transaction.id, lock_version: transaction.lock_version,
      choices: [ choice.(first), choice.(first), choice.(second) ], edit: true).status
    assert_equal [ categories(:groceries), categories(:cafes) ], [ first.reload.category, second.reload.category ]
  end

  test "a transfer leg and a transaction booked from a receipt stay refused in the edit mode" do
    leg = transactions(:withdrawal_out)
    choice = Choice.new(line_id: 0, category_id: categories(:cafes).id, origin: "person")
    assert_equal :changed, Transactions::Categorise.call(leg.id, lock_version: leg.lock_version, choices: [ choice ], edit: true).status

    market = transactions(:market_split)
    assert_equal :on_receipt, change(market, { transaction_lines(:market_groceries) => categories(:takeaway) }).status
    assert_equal categories(:groceries), transaction_lines(:market_groceries).reload.category
  end

  test "without the edit mode a categorised line is still refused, also as a bulk acceptance would ask" do
    line = transaction_lines(:coffee_line)
    bulk = Choice.new(line_id: line.id, category_id: categories(:groceries).id, origin: "bulk", shown_category_id: categories(:groceries).id,
      shown_model_version: VERSION, observed_category_id: categories(:cafes).id)

    assert_equal :changed, Transactions::Categorise.call(line.transaction_id, lock_version: transactions(:coffee).lock_version, choices: [ bulk ]).status
    assert_equal :changed, take(line, category: categories(:groceries), origin: "person").status
    assert_equal categories(:cafes), line.reload.category
  end
end

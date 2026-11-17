require "test_helper"

class Receipts::AcceptTest < ActiveSupport::TestCase
  def accept(receipt, **options)
    Receipts::Accept.call(receipt, **options)
  end

  def line_summary(transaction)
    transaction.lines.reload.map { |line| [ line.category&.slug, line.amount ] }
  end

  test "books a new expense with one line per category" do
    receipt = receipts(:corner_receipt)
    transaction = nil

    assert_difference -> { Transaction.count }, 1 do
      transaction = accept(receipt, account: accounts(:card_uah))
    end

    assert_equal BigDecimal("-152.50"), transaction.amount
    assert_equal accounts(:card_uah), transaction.account
    assert transaction.from_receipt?
    assert_equal Date.new(2026, 10, 8), transaction.occurred_on
    assert_equal receipt.issued_at, transaction.occurred_at
    assert_equal "Corner Shop", transaction.merchant
    # Water 60.00 and the deposit -2.50 are groceries; the sandwich has only a suggestion.
    assert_equal [ [ "groceries/groceries", BigDecimal("-57.50") ], [ nil, BigDecimal("-95.00") ] ], line_summary(transaction)
    assert transaction.needs_review?
    assert receipt.reload.reviewed?
    assert_equal transaction, receipt.ledger_transaction
  end

  test "a suggested category is not used until it is copied to category" do
    transaction = accept(receipts(:corner_receipt), account: accounts(:card_uah))

    assert_nil transaction.lines.find_by(amount: BigDecimal("-95")).category
  end

  test "the transaction is confirmed when every line has a category" do
    receipt_items(:corner_sandwich).update!(category: categories(:takeaway))

    transaction = accept(receipts(:corner_receipt), account: accounts(:card_uah))

    assert transaction.confirmed?
    assert_equal [ [ "groceries/groceries", BigDecimal("-57.50") ], [ "eating-out/takeaway-fast-food", BigDecimal("-95.00") ] ],
      line_summary(transaction)
  end

  test "a category whose items are a refund gives a line of the opposite sign" do
    receipt_items(:corner_deposit).update!(category: categories(:household_supplies))

    transaction = accept(receipts(:corner_receipt), account: accounts(:card_uah))

    assert_includes line_summary(transaction), [ "household-shopping/household-supplies", BigDecimal("2.50") ]
    assert_equal transaction.amount, transaction.lines.sum(:amount)
  end

  test "a category whose items sum to zero adds no line" do
    receipts(:corner_receipt).items.create!(position: 4, name: "Free bag", amount: 0, category: categories(:household_supplies))

    transaction = accept(receipts(:corner_receipt), account: accounts(:card_uah))

    assert_equal 2, transaction.lines.count
  end

  test "accepting twice gives the same result" do
    receipt = receipts(:corner_receipt)
    first = accept(receipt, account: accounts(:card_uah))
    before = line_summary(first)

    second = nil
    assert_no_difference [ "Transaction.count", "TransactionLine.count" ] do
      second = accept(receipt.reload)
    end

    assert_equal first, second
    assert_equal before, line_summary(second)
  end

  test "accepting a linked receipt again replaces the lines" do
    receipt = receipts(:market_receipt)
    receipt_items(:market_soap).update!(category: categories(:groceries))

    transaction = accept(receipt)

    assert_equal transactions(:market_split), transaction
    assert_equal [ [ "groceries/groceries", BigDecimal("-1250.40") ] ], line_summary(transaction)
    assert transaction.confirmed?
  end

  test "accepting again works after the transaction was edited elsewhere" do
    receipt = receipts(:market_receipt)
    receipt.ledger_transaction # an old copy in the association cache
    Transaction.find(transactions(:market_split).id).update!(comment: "Edited in another tab")

    transaction = accept(receipt)

    assert_equal "Edited in another tab", transaction.comment
    assert_equal 2, transaction.lock_version
  end

  test "lines on a linked income carry its positive sign" do
    refund = Transaction.create!(account: accounts(:card_uah), amount: "152.50", occurred_on: Date.new(2026, 10, 9), source: :manual,
                                 lines_attributes: [ { amount: "152.50" } ])
    receipt = receipts(:corner_receipt)
    receipt.update!(ledger_transaction: refund)

    accept(receipt)

    assert_equal [ [ "groceries/groceries", BigDecimal("57.50") ], [ nil, BigDecimal("95.00") ] ], line_summary(refund)
    assert refund.reload.needs_review?
  end

  test "a linked receipt whose items do not match the amount changes nothing" do
    receipt = receipts(:market_receipt)
    receipt.update_column(:status, "extracted")
    receipt_items(:market_soap).update!(amount: "200.00")
    before = line_summary(transactions(:market_split))

    error = assert_raises(Receipts::Accept::TotalMismatch) { accept(receipt) }

    assert_equal BigDecimal("1200.40"), error.items_total
    assert_equal BigDecimal("-1250.40"), error.transaction_amount
    assert_equal "the items sum to 1200.4 but the transaction amount is -1250.4", error.message
    assert_equal before, line_summary(transactions(:market_split))
    assert receipt.reload.extracted?
  end

  test "a linked receipt refuses a different account" do
    assert_raises(ArgumentError) { accept(receipts(:market_receipt), account: accounts(:cash_uah)) }
    assert accept(receipts(:market_receipt), account: accounts(:card_uah))
  end

  test "a receipt linked to a transfer leg is refused" do
    receipt = receipts(:corner_receipt)
    receipt.update_column(:transaction_id, transactions(:withdrawal_out).id)

    error = assert_raises(Receipts::Accept::NotAcceptable) { accept(receipt) }
    assert_equal "the receipt is linked to a transfer leg", error.message
  end

  test "a receipt without a transaction needs an account" do
    assert_no_difference -> { Transaction.count } do
      assert_raises(Receipts::Accept::AccountRequired) { accept(receipts(:corner_receipt)) }
    end
    assert receipts(:corner_receipt).reload.extracted?
  end

  test "the receipt currency must be the account currency" do
    error = assert_raises(Receipts::Accept::CurrencyMismatch) { accept(receipts(:corner_receipt), account: accounts(:savings_usd)) }
    assert_equal "the receipt is in UAH but Savings USD is in USD", error.message
  end

  test "an unknown receipt currency books on any account" do
    receipts(:corner_receipt).update!(currency: nil)

    assert_equal accounts(:savings_usd), accept(receipts(:corner_receipt), account: accounts(:savings_usd)).account
  end

  test "occurred_on is the Kyiv date of issued_at" do
    receipt = receipts(:corner_receipt)
    receipt.update!(issued_at: Time.utc(2026, 10, 8, 22, 30)) # 01:30 on 9 October in Kyiv

    assert_equal Date.new(2026, 10, 9), accept(receipt, account: accounts(:card_uah)).occurred_on
  end

  test "occurred_on is today when issued_at is unknown" do
    receipt = receipts(:corner_receipt)
    receipt.update!(issued_at: nil)

    travel_to Time.utc(2026, 11, 1, 22, 30) do # already 2 November in Kyiv
      transaction = accept(receipt, account: accounts(:card_uah))

      assert_equal Date.new(2026, 11, 2), transaction.occurred_on
      assert_nil transaction.occurred_at
    end
  end

  test "receipts without an OCR result are refused" do
    %w[uploaded processing failed].each do |status|
      receipt = receipts(:corner_receipt)
      receipt.update_column(:status, status)

      error = assert_raises(Receipts::Accept::NotAcceptable, status) { accept(receipt, account: accounts(:card_uah)) }
      assert_equal "a receipt in status #{status} cannot be accepted (it must be extracted or reviewed)", error.message
    end
  end

  test "a receipt with no items is refused" do
    receipt = receipts(:new_receipt)
    receipt.update_column(:status, "extracted")

    error = assert_raises(Receipts::Accept::NotAcceptable) { accept(receipt, account: accounts(:card_uah)) }
    assert_equal "the receipt has no items", error.message
  end

  test "items that sum to zero or less cannot be booked as an expense" do
    receipt = receipts(:corner_receipt)
    receipt.items.where.not(id: receipt_items(:corner_deposit)).delete_all

    error = assert_raises(Receipts::Accept::NothingToBook) { accept(receipt, account: accounts(:card_uah)) }
    assert_equal "the items sum to -2.5, so there is no expense to book", error.message
  end

  test "every refusal is a Receipts::Accept::Error" do
    [ Receipts::Accept::NotAcceptable, Receipts::Accept::AccountRequired, Receipts::Accept::CurrencyMismatch,
      Receipts::Accept::NothingToBook, Receipts::Accept::TotalMismatch ].each do |error|
      assert_operator error, :<, Receipts::Accept::Error
    end
  end
end

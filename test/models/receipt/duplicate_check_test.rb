require "test_helper"

class Receipt::DuplicateCheckTest < ActiveSupport::TestCase
  setup do
    @receipt = receipts(:corner_receipt) # items sum to 152.50, issued 2026-10-08 in Kyiv
  end

  test "finds a transaction on the same account, the same Kyiv date and the same amount" do
    same = Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 8), amount: "-152.50", source: :bank,
                               lines_attributes: [ { amount: "-152.50" } ])
    Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 8), amount: "-152.50", source: :bank,
                        lines_attributes: [ { amount: "-152.50" } ])
    Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 9), amount: "-152.50", source: :bank,
                        lines_attributes: [ { amount: "-152.50" } ])

    check = Receipt::DuplicateCheck.new(@receipt, account: accounts(:card_uah))

    assert_equal [ same ], check.transactions
    assert check.any?
  end

  test "finds another receipt not booked yet with the same date and total, as a slip of the same purchase would be" do
    other = receipts(:new_receipt)
    other.update_columns(kind: "card_slip", total: BigDecimal("152.50"), issued_at: Time.zone.local(2026, 10, 8, 23, 59))

    assert_equal [ other ], Receipt::DuplicateCheck.new(@receipt, account: nil).receipts

    other.update_columns(issued_at: Time.zone.local(2026, 10, 9, 0, 1))
    assert_empty Receipt::DuplicateCheck.new(@receipt, account: nil).receipts
  end

  test "a receipt's own transaction is never a match, and nothing to book means nothing to compare" do
    receipt = receipts(:market_receipt)
    assert_not Receipt::DuplicateCheck.new(receipt, account: accounts(:card_uah)).any?

    receipts(:new_receipt).update_columns(status: "extracted")
    assert_not Receipt::DuplicateCheck.new(receipts(:new_receipt), account: accounts(:card_uah)).any?
  end
end

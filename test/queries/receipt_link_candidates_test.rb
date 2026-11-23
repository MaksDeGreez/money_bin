require "test_helper"

class ReceiptLinkCandidatesTest < ActiveSupport::TestCase
  setup do
    # Issued 2026-10-08 12:05 Kyiv, total 152.50, items sum to 152.50, UAH, merchant "Corner Shop".
    @receipt = receipts(:corner_receipt)
  end

  def expense(amount: "-152.50", on: Date.new(2026, 10, 8), account: accounts(:card_uah), **attributes)
    Transaction.create!(account:, occurred_on: on, amount:, source: :bank, status: :needs_review,
                        lines_attributes: [ { amount: } ], **attributes)
  end

  def found(receipt = @receipt)
    ReceiptLinkCandidates.new(Receipt.find(receipt.id))
  end

  test "an expense of the receipt's amount within two days either side is a candidate; three days is not" do
    inside = [ -2, -1, 0, 1, 2 ].map { |days| expense(on: Date.new(2026, 10, 8) + days) }
    expense(on: Date.new(2026, 10, 5))
    expense(on: Date.new(2026, 10, 11))

    assert_equal inside.map(&:id).sort, found.candidate_ids.sort
    assert_equal [ -2, -1, 0, 1, 2 ], found.candidates.map(&:days).sort
  end

  test "only expenses: an income of the same amount and a transfer leg are not candidates" do
    expense(amount: "152.50")
    Transaction.transfer!(from: accounts(:card_uah), to: accounts(:cash_uah), amount: "152.50", occurred_on: Date.new(2026, 10, 8))

    assert_empty found.candidates
    assert_not found.any?
  end

  test "a transaction booked from another receipt is reported apart, not as a candidate" do
    free = expense
    taken = expense(on: Date.new(2026, 10, 9))
    receipts(:new_receipt).update_columns(transaction_id: taken.id, status: "reviewed")

    assert_equal [ free.id ], found.candidate_ids
    assert_equal [ taken.id ], found.linked_ids
    assert_equal receipts(:new_receipt), found.linked_elsewhere.first.other_receipt
  end

  test "only accounts in the receipt's currency, archived ones included; an unknown currency searches every account" do
    uah = expense
    archived_uah = Account.create!(name: "Closed card", kind: :debit, currency: "UAH", archived: true)
    closed = expense(account: archived_uah)
    usd = expense(account: accounts(:savings_usd))

    assert_equal [ uah.id, closed.id ].sort, found.candidate_ids.sort

    @receipt.update_columns(currency: nil)
    assert_equal [ uah.id, closed.id, usd.id ].sort, found.candidate_ids.sort
  end

  test "no date means no search, never today; the QR time stands in for a missing issued_at" do
    match = expense
    @receipt.update_columns(issued_at: nil)
    travel_to Time.zone.local(2026, 10, 8, 15) do
      assert_nil found.date
      assert_empty found.candidates
    end

    @receipt.update_columns(qr_issued_at: Time.zone.local(2026, 10, 9, 23, 30))
    assert_equal Date.new(2026, 10, 9), found.date
    assert_equal [ match.id ], found.candidate_ids
  end

  test "the Kyiv date counts, not the UTC one" do
    @receipt.update_columns(issued_at: Time.utc(2026, 10, 10, 22, 30)) # 01:30 on 11 October in Kyiv
    late = expense(on: Date.new(2026, 10, 13))

    assert_equal Date.new(2026, 10, 11), found.date
    assert_equal [ late.id ], found.candidate_ids
  end

  test "the printed total, the booking total and the QR total are each searched" do
    @receipt.update_columns(total: BigDecimal("160.00"), qr_total: BigDecimal("161.00"))
    by_total = expense(amount: "-160.00")
    by_items = expense(amount: "-152.50")
    by_qr = expense(amount: "-161.00")
    expense(amount: "-162.00")

    assert_equal [ by_items.id, by_qr.id, by_total.id ].sort, found.candidate_ids.sort
    assert_equal [ BigDecimal("152.50"), BigDecimal("160.00"), BigDecimal("161.00") ], found.amounts.sort
    matches = found.candidates.index_by(&:id)
    assert matches[by_items.id].matches_total
    assert_not matches[by_total.id].matches_total, "Accept would refuse it until the items are corrected"
    assert_not matches[by_qr.id].matches_total
  end

  test "a card slip searches its total" do
    @receipt.items.delete_all
    @receipt.update_columns(kind: "card_slip", total: BigDecimal("640.00"))
    slip = expense(amount: "-640.00")

    assert_equal [ slip.id ], found.candidate_ids
    assert found.candidates.first.matches_total
  end

  test "ranked by days, then by the time gap when known, then by the merchant, then by id" do
    far = expense(on: Date.new(2026, 10, 10))
    no_time = expense
    no_time_merchant = expense(merchant: "CORNER SHOP KYIV")
    near_time = expense(occurred_at: Time.zone.local(2026, 10, 8, 12, 6))
    early_time = expense(occurred_at: Time.zone.local(2026, 10, 8, 9, 0))
    day_before = expense(on: Date.new(2026, 10, 7), occurred_at: Time.zone.local(2026, 10, 7, 12, 5))

    assert_equal [ near_time, early_time, no_time_merchant, no_time, day_before, far ].map(&:id), found.candidate_ids
    assert found.candidates.find { |candidate| candidate.id == no_time_merchant.id }.merchant_match
  end

  test "the merchant matches inside the payee's name or the bank's text, whatever the spacing and case" do
    by_payee = expense(payee: Payee.create!(name: "Corner-Shop #12"))
    by_bank = expense(bank_description: "POS CORNERSHOP 0042")
    other = expense(merchant: "Corner Cafe")

    matches = found.candidates.index_by(&:id)
    assert matches[by_payee.id].merchant_match
    assert matches[by_bank.id].merchant_match
    assert_not matches[other.id].merchant_match
  end

  test "ranking sees every match before the limit, and each list shows at most twenty" do
    expense(on: Date.new(2026, 10, 10)) # far
    22.times { expense(on: Date.new(2026, 10, 9)) }
    best = expense(occurred_at: Time.zone.local(2026, 10, 8, 12, 5))

    assert_equal ReceiptLinkCandidates::LIMIT, found.candidates.size
    assert_equal best.id, found.candidate_ids.first, "the newest row is ranked first although it has the highest id"
  end

  test "the receipt's own transaction is never a match" do
    own = expense
    @receipt.update_columns(transaction_id: own.id, status: "reviewed")

    assert_not found.any?
  end
end

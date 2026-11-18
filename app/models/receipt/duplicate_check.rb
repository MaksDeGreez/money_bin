# Before a receipt is accepted: is the same purchase already in the ledger, or waiting as another receipt?
# A fiscal receipt and its card slip are often two photos of one purchase (docs/domain.md, "The duplicate
# warning").
#
#   check = Receipt::DuplicateCheck.new(receipt, account:)
#   check.transactions  # transactions on `account`, the same Kyiv date, the same amount
#   check.receipts      # other receipts not booked yet, issued the same Kyiv date, with the same total
#
# The amount is what accepting would book (Receipt#booking_total: the items' sum, or a slip's total), as an
# expense; the date is the Kyiv date of `issued_at`, or today when it is unknown, as Receipts::Accept books
# it. The receipt's own transaction is never a match, and transfer legs are left out. A warning, never a
# block: two equal purchases on one day are possible.
class Receipt::DuplicateCheck
  def initialize(receipt, account:)
    @receipt = receipt
    @account = account
    @amount = receipt.booking_total
    @date = receipt.issued_at&.in_time_zone&.to_date || Date.current
  end

  def any?
    transactions.any? || receipts.any?
  end

  def transactions
    @transactions ||= if @account && @amount&.positive?
      Transaction.where(account: @account, occurred_on: @date, amount: -@amount, transfer_id: nil)
        .where.not(id: @receipt.transaction_id).includes(:receipt).order(:id).to_a
    else
      []
    end
  end

  def receipts
    @receipts ||= if @amount&.positive?
      day = @date.in_time_zone.all_day
      Receipt.where(transaction_id: nil, total: @amount, issued_at: day).where.not(id: @receipt.id).order(:id).to_a
    else
      []
    end
  end
end

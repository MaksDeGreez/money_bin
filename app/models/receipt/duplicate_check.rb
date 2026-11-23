# Before a receipt is accepted: is the same purchase waiting as another receipt? A fiscal receipt and its card
# slip are often two photos of one purchase (docs/domain.md, "The duplicate warning"). The ledger side (a bank
# transaction for the same purchase) is "Book as" on the review form (ReceiptLinkCandidates).
#
#   check = Receipt::DuplicateCheck.new(receipt)
#   check.receipts      # other receipts not booked yet, issued the same Kyiv date, with the same total
#
# The amount is what accepting would book (Receipt#booking_total: the items' sum, or a slip's total); the date
# is the Kyiv date of `issued_at`, or today when it is unknown, as Receipts::Accept books a new expense. A
# warning, never a block: two equal purchases on one day are possible.
class Receipt::DuplicateCheck
  def initialize(receipt)
    @receipt = receipt
    @amount = receipt.booking_total
    @date = receipt.issued_at&.in_time_zone&.to_date || Date.current
  end

  def any?
    receipts.any?
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

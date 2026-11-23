# The ledger transactions a receipt may be booked onto instead of a new expense (docs/domain.md, "Booking onto a
# transaction"): the bank's row for the same purchase is usually in the ledger already.
#
#   found = ReceiptLinkCandidates.new(receipt)   # the receipt as last saved
#   found.candidates        # => [Candidate, ...] the person may choose one (at most LIMIT, best first)
#   found.linked_elsewhere  # => [Candidate, ...] the same rule, but another receipt is booked on it: shown only
#
# A match is an expense (amount = minus one of the receipt's amounts), not a transfer leg, dated within
# WINDOW_DAYS days of the receipt's Kyiv date, on an account in the receipt's currency, archived accounts and
# every status included.
# - The date: the Kyiv date of `issued_at`, else of `qr_issued_at`. With neither there is nothing to search
#   (never today: a wrong day would offer wrong rows).
# - The amounts: the distinct known positive values among the printed `total`, the booking total (the items'
#   sum, or a slip's total: Receipt#booking_total) and `qr_total`. A receipt read with a missing line still
#   finds its bank row by its total, and one whose total was misread by its items.
# - An unknown receipt currency searches every account, as Receipts::Accept books an unknown currency on any
#   account; a known one only accounts in that currency.
# The window is a search filter, not a rule: Receipts::Accept checks only the hard rules (an expense, not a
# transfer leg, no other receipt, the currency, the amount).
#
# Ranking, in Ruby over every match (no SQL limit before it): the distance in days; then the gap between the
# transaction's `occurred_at` and the receipt's time, when both are known (unknown after known); then whether
# the merchant name matches (ItemName.key of the receipt's merchant contained in that of the payee's name,
# `merchant` or `bank_description`); then the id. LIMIT of each list are shown.
class ReceiptLinkCandidates
  WINDOW_DAYS = 2
  LIMIT = 20
  TIME_ZONE = "Europe/Kyiv".freeze

  # `days` is the transaction's date minus the receipt's (negative: earlier); `gap` the seconds between the two
  # times (nil when one is unknown); `matches_total`: its amount is the booking total, which Accept requires.
  Candidate = Data.define(:transaction, :days, :gap, :merchant_match, :matches_total) do
    def id = transaction.id
    def other_receipt = transaction.receipt
  end

  attr_reader :receipt

  def initialize(receipt)
    @receipt = receipt
  end

  # The Kyiv date searched around, or nil when the receipt has no date.
  def date
    return @date if defined?(@date)

    time = @receipt.issued_at || @receipt.qr_issued_at
    @date = time&.in_time_zone(TIME_ZONE)&.to_date
  end

  # The receipt amounts searched for, as positive BigDecimals.
  def amounts
    @amounts ||= [ @receipt.total, @receipt.booking_total, @receipt.qr_total ].compact.select(&:positive?).uniq
  end

  def candidates
    load_matches
    @candidates
  end

  def linked_elsewhere
    load_matches
    @linked_elsewhere
  end

  def candidate_ids
    candidates.map(&:id)
  end

  def linked_ids
    linked_elsewhere.map(&:id)
  end

  def any?
    candidates.any? || linked_elsewhere.any?
  end

  private
    def load_matches
      return if @candidates

      matches = search.map { |transaction| candidate(transaction) }.sort_by { |match| rank(match) }
      linked, free = matches.partition(&:other_receipt)
      @candidates = free.first(LIMIT)
      @linked_elsewhere = linked.first(LIMIT)
    end

    def search
      return [] if date.nil? || amounts.empty?

      scope = Transaction.where(transfer_id: nil, amount: amounts.map(&:-@),
                                occurred_on: (date - WINDOW_DAYS)..(date + WINDOW_DAYS))
      scope = scope.where.not(id: @receipt.transaction_id) if @receipt.transaction_id
      scope = scope.joins(:account).where(accounts: { currency: @receipt.currency }) if @receipt.currency
      scope.includes(:account, :payee, :receipt, lines: :category).to_a
        .reject { |transaction| transaction.receipt&.id == @receipt.id }
    end

    def candidate(transaction)
      time = receipt_time
      gap = (transaction.occurred_at - time).abs if transaction.occurred_at && time
      Candidate.new(transaction:, days: (transaction.occurred_on - date).to_i, gap:,
                    merchant_match: merchant_match?(transaction),
                    matches_total: !@receipt.booking_total.nil? && transaction.amount.abs == @receipt.booking_total)
    end

    def rank(match)
      [ match.days.abs, match.gap ? 0 : 1, match.gap || 0, match.merchant_match ? 0 : 1, match.id ]
    end

    def receipt_time
      @receipt.issued_at || @receipt.qr_issued_at
    end

    def merchant_key
      @merchant_key ||= ItemName.key(@receipt.merchant_name)
    end

    def merchant_match?(transaction)
      return false if merchant_key.empty?

      [ transaction.payee&.name, transaction.merchant, transaction.bank_description ]
        .any? { |text| ItemName.key(text).include?(merchant_key) }
    end
end

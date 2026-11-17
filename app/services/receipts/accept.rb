module Receipts
  # Books a receipt into the ledger. The rule: the transaction's lines are the item amounts summed per
  # category.
  #
  #   transaction = Receipts::Accept.call(receipt, account: card)
  #
  # - Items are grouped by `category`; items without one form a single line with no category. Only
  #   `category` counts: a `suggested_category` is used only after it was copied to `category`.
  #   A group whose items sum to zero (a free item) adds no line.
  # - A receipt that already has a transaction: the items must sum to the absolute value of its amount
  #   (else TotalMismatch, with both figures). Its lines are replaced, and they carry its sign.
  # - A receipt without one: `account:` is required. A new expense is created on it: amount = minus the items'
  #   sum, source `receipt`, `occurred_on` = the Kyiv date of `issued_at` (today when unknown),
  #   `occurred_at` = `issued_at`, `merchant` = `merchant_name`. The receipt currency, when known, must be the
  #   account currency.
  # - The transaction ends `needs_review` when a line has no category or when the receipt's printed `total`
  #   is known and the items do not sum to it (Receipt#total_difference says by how much; the items are
  #   still booked, since the person may have edited them on purpose). Otherwise it ends `confirmed`, also
  #   when it was a `draft`: accepting the receipt is the review. The receipt ends `reviewed` and linked to
  #   the transaction.
  # - Only `extracted` receipts (first acceptance) and `reviewed` ones (accept again after a change) can be
  #   accepted. `uploaded` and `processing` have no OCR result yet; `failed` has none to trust.
  #
  # Everything runs in one database transaction with the receipt row locked, so a failure changes nothing
  # and two parallel calls cannot book a receipt twice. Calling it again gives the same result.
  #
  # Errors: every refusal raises a subclass of Receipts::Accept::Error. A record that fails validation
  # (an amount out of range, say) raises ActiveRecord::RecordInvalid as usual.
  class Accept
    ACCEPTABLE_STATUSES = %w[extracted reviewed].freeze
    TIME_ZONE = "Europe/Kyiv".freeze

    class Error < StandardError; end
    # The receipt is in the wrong status, has no items, or is linked to a transfer leg.
    class NotAcceptable < Error; end
    # A receipt without a transaction needs an account to book it on.
    class AccountRequired < Error; end
    # The receipt currency is not the account currency.
    class CurrencyMismatch < Error; end
    # The items' sum is zero or negative, so there is no expense to create.
    class NothingToBook < Error; end

    # The items do not sum to the linked transaction's amount.
    class TotalMismatch < Error
      attr_reader :items_total, :transaction_amount

      def initialize(items_total:, transaction_amount:)
        @items_total = items_total
        @transaction_amount = transaction_amount
        super("the items sum to #{items_total.to_s('F')} but the transaction amount is #{transaction_amount.to_s('F')}")
      end
    end

    def self.call(receipt, account: nil)
      new(receipt, account:).call
    end

    def initialize(receipt, account: nil)
      @receipt = receipt
      @account = account
    end

    # Returns the booked Transaction.
    def call
      @receipt.with_lock do
        check_status
        items = @receipt.items.to_a
        raise NotAcceptable, "the receipt has no items" if items.empty?

        transaction = @receipt.ledger_transaction ? rebook(@receipt.ledger_transaction, items) : book(items)
        @receipt.update!(status: :reviewed, ledger_transaction: transaction)
        transaction
      end
    end

    private
      def check_status
        return if ACCEPTABLE_STATUSES.include?(@receipt.status)

        raise NotAcceptable, "a receipt in status #{@receipt.status} cannot be accepted (it must be extracted or reviewed)"
      end

      def rebook(transaction, items)
        raise NotAcceptable, "the receipt is linked to a transfer leg" if transaction.transfer_leg?
        if @account && @account != transaction.account
          raise ArgumentError, "the receipt is already booked on #{transaction.account.name}, not on #{@account.name}"
        end

        # Locks and re-reads the row, so a parallel edit of the transaction waits instead of failing this
        # call with ActiveRecord::StaleObjectError.
        transaction.lock!
        total = items_total(items)
        if total != transaction.amount.abs
          raise TotalMismatch.new(items_total: total, transaction_amount: transaction.amount)
        end

        lines = lines_for(items, sign: transaction.amount.negative? ? -1 : 1)
        old_lines = transaction.lines.map { |line| { id: line.id, _destroy: true } }
        transaction.update!(lines_attributes: old_lines + lines, status: status_for(lines, items))
        transaction
      end

      def book(items)
        raise AccountRequired, "a receipt without a transaction needs an account" unless @account
        if @receipt.currency && @receipt.currency != @account.currency
          raise CurrencyMismatch, "the receipt is in #{@receipt.currency} but #{@account.name} is in #{@account.currency}"
        end

        total = items_total(items)
        raise NothingToBook, "the items sum to #{total.to_s('F')}, so there is no expense to book" unless total.positive?

        lines = lines_for(items, sign: -1)
        Transaction.create!(
          account: @account, amount: -total, source: :receipt, status: status_for(lines, items),
          occurred_on: @receipt.issued_at&.in_time_zone(TIME_ZONE)&.to_date || Date.current,
          occurred_at: @receipt.issued_at, merchant: @receipt.merchant_name, lines_attributes: lines
        )
      end

      def items_total(items)
        items.sum(BigDecimal("0"), &:amount)
      end

      # One line per category, in the order the categories first appear on the receipt.
      def lines_for(items, sign:)
        items.group_by(&:category_id).filter_map do |category_id, group|
          sum = items_total(group)
          { category_id:, amount: sign * sum } unless sum.zero?
        end
      end

      def status_for(lines, items)
        uncategorised = lines.any? { |line| line[:category_id].nil? }
        short_or_long = @receipt.total.present? && @receipt.total != items_total(items)
        uncategorised || short_or_long ? :needs_review : :confirmed
      end
  end
end

module Receipts
  # Books a receipt into the ledger. The rule: the transaction's lines are the item amounts summed per
  # category (CategoryLines, shared with manual entry).
  #
  #   transaction = Receipts::Accept.call(receipt, account: card)
  #
  # - Items are grouped by `category`; items without one form a single line with no category. Only
  #   `category` counts: a `suggested_category` is used only after it was copied to `category`.
  #   A group whose items sum to zero (a free item) adds no line.
  # - A card slip (`kind` card_slip) has no items: it is booked as one line, its `total` in the receipt's own
  #   `category` (no category gives a line with none). A slip that still has items is refused, and so is
  #   one without a total.
  # - A receipt that already has a transaction: the booked total (the items' sum, or a slip's total) must be
  #   the absolute value of its amount (else TotalMismatch, with both figures). Its lines are replaced, and
  #   they carry its sign.
  # - A receipt without one: `account:` is required. A new expense is created on it: amount = minus the
  #   booked total, source `receipt`, `occurred_on` = the Kyiv date of `issued_at` (today when unknown),
  #   `occurred_at` = `issued_at`, `merchant` = `merchant_name`. The receipt currency, when known, must be the
  #   account currency.
  # - The payee is the one named by `merchant_name` (Payee.find_or_create_by_name!, so the payee
  #   normalisation decides what is the same payee). A linked transaction that already has a payee keeps
  #   it; only an empty one is filled. A blank merchant name sets no payee.
  # - The transaction ends `needs_review` when a line has no category or when the receipt's printed `total`
  #   is known and the items do not sum to it (Receipt#total_difference says by how much; the items are
  #   still booked, since the person may have edited them on purpose). Otherwise it ends `confirmed`, also
  #   when it was a `draft`: accepting the receipt is the review. The receipt ends `reviewed` and linked to
  #   the transaction. `review_reasons` says why in words a person reads.
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
    # The receipt is in the wrong status, has no items (a slip: has items, or no total), or is linked to a
    # transfer leg.
    class NotAcceptable < Error; end
    # A receipt without a transaction needs an account to book it on.
    class AccountRequired < Error; end
    # The receipt currency is not the account currency.
    class CurrencyMismatch < Error; end
    # The booked total is zero or negative, so there is no expense to create.
    class NothingToBook < Error; end

    # The booked total (the items' sum, or a slip's total) is not the linked transaction's amount.
    class TotalMismatch < Error
      attr_reader :items_total, :transaction_amount

      def initialize(items_total:, transaction_amount:, slip: false)
        @items_total = items_total
        @transaction_amount = transaction_amount
        what = slip ? "the slip's total is" : "the items sum to"
        super("#{what} #{items_total.to_s('F')} but the transaction amount is #{transaction_amount.to_s('F')}")
      end
    end

    # Why a transaction booked from `receipt` with `lines` needs review, in words; empty when it does not.
    def self.review_reasons(receipt, lines)
      reasons = []
      reasons << "a line has no category" if CategoryLines.uncategorised?(lines)
      if !receipt.card_slip? && receipt.total && receipt.total != receipt.items_total
        reasons << "the items sum to #{receipt.items_total.to_s('F')}, not to the printed total #{receipt.total.to_s('F')}"
      end
      reasons
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
        entries = entries_to_book

        transaction = @receipt.ledger_transaction ? rebook(@receipt.ledger_transaction, entries) : book(entries)
        @receipt.update!(status: :reviewed, ledger_transaction: transaction)
        transaction
      end
    end

    private
      def check_status
        return if ACCEPTABLE_STATUSES.include?(@receipt.status)

        raise NotAcceptable, "a receipt in status #{@receipt.status} cannot be accepted (it must be extracted or reviewed)"
      end

      # The amounts to book with their categories: the items, or a slip's total in the receipt's category.
      def entries_to_book
        items = @receipt.items.to_a
        unless @receipt.card_slip?
          raise NotAcceptable, "the receipt has no items" if items.empty?

          return items
        end

        if items.any?
          raise NotAcceptable, "a card slip is booked from its total, but this one has #{items.size} item(s): " \
            "remove them or make it a fiscal receipt"
        end
        raise NotAcceptable, "the card slip has no total" if @receipt.total.nil?

        [ CategoryLines::Entry.new(category_id: @receipt.category_id, amount: @receipt.total) ]
      end

      def rebook(transaction, entries)
        raise NotAcceptable, "the receipt is linked to a transfer leg" if transaction.transfer_leg?
        if @account && @account != transaction.account
          raise ArgumentError, "the receipt is already booked on #{transaction.account.name}, not on #{@account.name}"
        end

        # Locks and re-reads the row, so a parallel edit of the transaction waits instead of failing this
        # call with ActiveRecord::StaleObjectError.
        transaction.lock!
        total = CategoryLines.total(entries)
        if total != transaction.amount.abs
          raise TotalMismatch.new(items_total: total, transaction_amount: transaction.amount, slip: @receipt.card_slip?)
        end

        lines = CategoryLines.build(entries, sign: transaction.amount.negative? ? -1 : 1)
        old_lines = transaction.lines.map { |line| { id: line.id, _destroy: true } }
        transaction.update!(lines_attributes: old_lines + lines, status: status_for(lines),
                            payee: transaction.payee || receipt_payee)
        transaction
      end

      def book(entries)
        raise AccountRequired, "a receipt without a transaction needs an account" unless @account
        if @receipt.currency && @receipt.currency != @account.currency
          raise CurrencyMismatch, "the receipt is in #{@receipt.currency} but #{@account.name} is in #{@account.currency}"
        end

        total = CategoryLines.total(entries)
        unless total.positive?
          what = @receipt.card_slip? ? "the slip's total is" : "the items sum to"
          raise NothingToBook, "#{what} #{total.to_s('F')}, so there is no expense to book"
        end

        lines = CategoryLines.build(entries, sign: -1)
        Transaction.create!(
          account: @account, amount: -total, source: :receipt, status: status_for(lines),
          occurred_on: @receipt.issued_at&.in_time_zone(TIME_ZONE)&.to_date || Date.current,
          occurred_at: @receipt.issued_at, merchant: @receipt.merchant_name, payee: receipt_payee, lines_attributes: lines
        )
      end

      # The payee named by the receipt's merchant_name, found by its normalised name or created; nil when the
      # name is blank. Runs inside the service's database transaction, so a failed acceptance keeps no payee.
      def receipt_payee
        name = @receipt.merchant_name
        Payee.find_or_create_by_name!(name) unless Payee.normalize_name(name).empty?
      end

      def status_for(lines)
        self.class.review_reasons(@receipt, lines).any? ? :needs_review : :confirmed
      end
  end
end

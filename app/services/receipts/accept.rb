module Receipts
  # Books a receipt into the ledger. The rule: the transaction's lines are the item amounts summed per
  # category (CategoryLines, shared with manual entry).
  #
  #   transaction = Receipts::Accept.call(receipt, account: card)                    # a new expense
  #   transaction = Receipts::Accept.call(receipt, link: 812, link_lock_version: 3)  # onto a ledger transaction
  #   transaction = Receipts::Accept.call(receipt)                                   # "Accept again"
  #
  # - Items are grouped by `category`; items without one form a single line with no category. Only
  #   `category` counts: a `suggested_category` is used only after it was copied to `category`.
  #   A group whose items sum to zero (a free item) adds no line.
  # - A card slip (`kind` card_slip) has no items: it is booked as one line, its `total` in the receipt's own
  #   `category` (no category gives a line with none). A slip that still has items is refused, and so is
  #   one without a total.
  # - Accept never searches for a transaction (ReceiptLinkCandidates does, for the person to choose).
  # - A receipt that already has a transaction ("Accept again") always rebooks that one: `link:` naming another
  #   is AlreadyLinked, an `account:` other than its account AccountMismatch, a receipt currency corrected to
  #   another than its account's CurrencyMismatch. Without a booking record it is NotAcceptable unless Accept had
  #   created the transaction (`source: receipt`): the earlier state of any other row is unknown.
  # - `link:` (a transaction or its id) on a receipt without one: the person chose that ledger transaction.
  #   It is locked with its lines, and must still be there (LinkGone), at the version the person saw
  #   (`link_lock_version`, else TransactionChanged), an expense and not a transfer leg (NotLinkable), without
  #   another receipt (AlreadyLinked), in the receipt's currency when that is known (CurrencyMismatch). Its
  #   earlier state is recorded (ReceiptBooking), then its lines are replaced.
  # - Rebooking: the booked total (the items' sum, or a slip's total) must be the absolute value of the
  #   transaction's amount (else TotalMismatch, with both figures: the items are corrected, nothing is added).
  #   The lines are replaced and carry its sign, with no `category_origin` (a receipt's categories are the
  #   person's own).
  # - Neither: `account:` is required. A new expense is created on it: amount = minus the
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
  # - Every booking writes the receipt's ReceiptBooking (`linked` with the earlier state, or `created`), and
  #   "Accept again" refreshes its lines digest (docs/domain.md, "Receipt bookings").
  #
  # Everything runs in one database transaction with the receipt row locked, so a failure changes nothing
  # (the record included) and two parallel calls cannot book a receipt twice. Two receipts choosing one
  # transaction: the transaction's row lock makes the second wait and then see the first's link; the unique
  # indexes are the backstop, refused as AlreadyLinked. Calling it again gives the same result.
  #
  # Errors: every refusal raises a subclass of Receipts::Accept::Error. A record that fails validation
  # (an amount out of range, say) raises ActiveRecord::RecordInvalid as usual.
  class Accept
    ACCEPTABLE_STATUSES = %w[extracted reviewed].freeze
    TIME_ZONE = "Europe/Kyiv".freeze
    BOOKED_MEANWHILE = "the transaction or the receipt was booked by another acceptance meanwhile".freeze

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
    # An account other than the linked transaction's was given for a receipt already booked.
    class AccountMismatch < Error; end
    # The chosen transaction is a transfer leg or not an expense.
    class NotLinkable < Error; end
    # The chosen transaction already has another receipt, or the receipt is booked on another transaction.
    class AlreadyLinked < Error; end
    # The chosen transaction is not at the version the person saw.
    class TransactionChanged < Error; end
    # The chosen transaction was deleted.
    class LinkGone < Error; end

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

    def self.call(receipt, account: nil, link: nil, link_lock_version: nil)
      new(receipt, account:, link:, link_lock_version:).call
    end

    def initialize(receipt, account: nil, link: nil, link_lock_version: nil)
      @receipt = receipt
      @account = account
      @link_id = link.is_a?(Transaction) ? link.id : link
      @link_lock_version = link_lock_version
    end

    # Returns the booked Transaction.
    def call
      @receipt.with_lock do
        check_status
        entries = entries_to_book

        # A savepoint: the unique indexes (one receipt per transaction, one record per receipt and per
        # transaction) are the backstop against a parallel booking, and PostgreSQL aborts a transaction after a
        # failed statement, so the violation must roll back to here to come out as a refusal.
        Receipt.transaction(requires_new: true) do
          transaction = if @receipt.transaction_id
            accept_again(entries)
          elsif @link_id
            link(entries)
          else
            book(entries)
          end
          @receipt.update!(status: :reviewed, ledger_transaction: transaction)
          transaction
        end
      rescue ActiveRecord::RecordNotUnique
        raise AlreadyLinked, BOOKED_MEANWHILE
      rescue ActiveRecord::RecordInvalid => error
        # The model's check of the same rule ("already has a receipt") comes first when it sees the other link.
        raise unless error.record.equal?(@receipt) && error.record.errors.include?(:transaction_id)

        raise AlreadyLinked, BOOKED_MEANWHILE
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

      # "Accept again": the receipt's own transaction, never another one.
      def accept_again(entries)
        if @link_id && @link_id.to_s != @receipt.transaction_id.to_s
          raise AlreadyLinked, "the receipt is already booked on transaction ##{@receipt.transaction_id}"
        end

        transaction = lock_transaction(@receipt.transaction_id)
        raise NotAcceptable, "the receipt's transaction no longer exists" unless transaction
        raise NotAcceptable, "the receipt is linked to a transfer leg" if transaction.transfer_leg?
        if @account && @account.id != transaction.account_id
          raise AccountMismatch, "the receipt is already booked on #{transaction.account.name}, not on #{@account.name}"
        end
        # The currency may have been corrected since the booking: the items' numbers would become another currency's.
        check_currency(transaction.account)
        # Booked before bookings were recorded: Accept created every such transaction (source `receipt`). Any other
        # row's earlier state is lost, and recording the current one would make an undo a silent no-op.
        if transaction.receipt_booking.nil? && !transaction.from_receipt?
          raise NotAcceptable, "the receipt's transaction has no record of its state before the receipt was booked on it"
        end

        payee = rebook(transaction, entries)
        record(transaction, payee, mode: :created)
        transaction
      end

      # The person chose this transaction on the review page: its lines are replaced by the receipt's, after its
      # earlier state is recorded. Only the hard rules are checked here; the date window is the search's.
      def link(entries)
        transaction = lock_transaction(@link_id)
        raise LinkGone, "the chosen transaction no longer exists" unless transaction
        # Before the version: a receipt that took it while this one waited on the row lock also moved its version.
        if (other = other_receipt_id(transaction))
          raise AlreadyLinked, "the chosen transaction is already booked from receipt ##{other}"
        end
        raise NotLinkable, "the chosen transaction is a transfer leg" if transaction.transfer_leg?
        raise NotLinkable, "the chosen transaction is not an expense" unless transaction.expense?
        if @link_lock_version.to_s != transaction.lock_version.to_s
          raise TransactionChanged, "the chosen transaction changed somewhere else after the page was opened"
        end
        if @account && @account.id != transaction.account_id
          raise AccountMismatch, "the chosen transaction is on #{transaction.account.name}, not on #{@account.name}"
        end
        check_currency(transaction.account)

        snapshot = ReceiptBooking.snapshot(transaction)
        import_digest = transaction.import_digest
        payee = rebook(transaction, entries)
        record(transaction, payee, mode: :linked, previous: snapshot, import_digest:)
        transaction
      end

      # Another receipt booked on the transaction (read under its row lock), or nil.
      def other_receipt_id(transaction)
        Receipt.where(transaction_id: transaction.id).where.not(id: @receipt.id).pick(:id) ||
          transaction.receipt_booking&.receipt_id
      end

      # The transaction row, then its lines in id order, then its booking record, under row locks (the suggestion job
      # writes lines without moving the transaction's version, so they are locked before they are read; an undo of
      # another receipt may hand the record "Accept created the payee", Receipts::UndoAccept); then read again as
      # stored. nil when the row is gone.
      def lock_transaction(id)
        return nil unless Transaction.lock.find_by(id:)

        TransactionLine.where(transaction_id: id).order(:id).lock.load
        ReceiptBooking.where(transaction_id: id).lock.load
        Transaction.includes(:account, :receipt_booking, :lines).find(id)
      end

      # Replaces the lines with the receipt's, in the transaction's sign. Returns the payee Accept assigned
      # (nil when the transaction keeps its own).
      def rebook(transaction, entries)
        total = CategoryLines.total(entries)
        if total != transaction.amount.abs
          raise TotalMismatch.new(items_total: total, transaction_amount: transaction.amount, slip: @receipt.card_slip?)
        end

        lines = CategoryLines.build(entries, sign: transaction.amount.negative? ? -1 : 1)
        old_lines = transaction.lines.map { |line| { id: line.id, _destroy: true } }
        payee = receipt_payee unless transaction.payee_id
        transaction.update!(lines_attributes: old_lines + lines, status: status_for(lines), payee: transaction.payee || payee)
        payee
      end

      # A known receipt currency must be the account's; an unknown one books anywhere (the amount still has to match).
      def check_currency(account)
        return if @receipt.currency.nil? || @receipt.currency == account.currency

        raise CurrencyMismatch, "the receipt is in #{@receipt.currency} but #{account.name} is in #{account.currency}"
      end

      def book(entries)
        raise AccountRequired, "a receipt without a transaction needs an account" unless @account
        check_currency(@account)

        total = CategoryLines.total(entries)
        unless total.positive?
          what = @receipt.card_slip? ? "the slip's total is" : "the items sum to"
          raise NothingToBook, "#{what} #{total.to_s('F')}, so there is no expense to book"
        end

        lines = CategoryLines.build(entries, sign: -1)
        payee = receipt_payee
        transaction = Transaction.create!(
          account: @account, amount: -total, source: :receipt, status: status_for(lines),
          occurred_on: @receipt.issued_at&.in_time_zone(TIME_ZONE)&.to_date || Date.current,
          occurred_at: @receipt.issued_at, merchant: @receipt.merchant_name, payee:, lines_attributes: lines
        )
        record(transaction, payee, mode: :created)
        transaction
      end

      # Writes the booking record, or refreshes it on "Accept again": the digest of the lines just written and the
      # transaction's version always; the payee when Accept assigned one now, unless the record names a payee
      # Accept created (an undo may remove that one); the mode, `previous` and the import digest only at the first
      # booking.
      def record(transaction, payee, mode:, previous: nil, import_digest: nil)
        booking = transaction.receipt_booking ||
          ReceiptBooking.new(receipt: @receipt, ledger_transaction: transaction, mode:, previous:,
                             transaction_import_digest: (import_digest if mode == :linked))
        if payee && !(booking.payee_created? && booking.assigned_payee_id != payee.id)
          created = @payee_created || (booking.assigned_payee_id == payee.id && booking.payee_created?)
          booking.assign_attributes(assigned_payee: payee, payee_created: created)
        end
        booking.lines_digest = ReceiptBooking.lines_digest(transaction.id)
        booking.booked_lock_version = transaction.lock_version
        booking.save!
      end

      # The payee named by the receipt's merchant_name, found by its normalised name or created; nil when the
      # name is blank. Runs inside the service's database transaction, so a failed acceptance keeps no payee.
      # `@payee_created` says whether this call created it (Payee.find_or_create_by_name! reads the winner of a
      # parallel insert, which this call did not create).
      def receipt_payee
        name = @receipt.merchant_name
        return if Payee.normalize_name(name).empty?

        payee = Payee.find_or_create_by_name!(name)
        @payee_created = payee.previously_new_record?
        payee
      end

      def status_for(lines)
        self.class.review_reasons(@receipt, lines).any? ? :needs_review : :confirmed
      end
  end
end

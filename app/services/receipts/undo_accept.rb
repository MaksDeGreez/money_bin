module Receipts
  # Undoes a receipt's acceptance (docs/domain.md, "Undoing an acceptance"; docs/decisions/0018, "Undo"): the ledger
  # goes back to what it was before Receipts::Accept booked the receipt, and the receipt goes back to `extracted`,
  # waiting for review, with nothing else lost.
  #
  #   result = Receipts::UndoAccept.call(receipt, lock_version: 7, transaction_lock_version: 3)
  #
  # `lock_version` and `transaction_lock_version` are the receipt's and its transaction's versions the person saw:
  # a page opened before a later "Accept again" (or any other change) is refused (Stale), never undoes a newer
  # booking unseen.
  #
  # What it does, by the receipt's booking record (ReceiptBooking):
  # - `linked` (the person chose a ledger transaction): the transaction must still be as Accept left it, by all of
  #   its `lock_version` (the record's `booked_lock_version`), its lines (ReceiptBooking.lines_digest: a line saved
  #   on its own does not move the version), its `import_digest` (a later import that rewrote the row wins: the
  #   export is the source of that row) and its amount (the one in `previous`); else ChangedSinceBooking, which for an
  #   edit in the app says that "Accept again" (it writes the lines anew and records them) makes the undo possible.
  #   The stored category suggestion on its lines is in neither marker on purpose: a refreshed suggestion is nobody's
  #   change.
  #   Then the lines in `previous` (format 1 only; another is UnknownFormat) replace the current ones, built as new
  #   lines through the transaction, so its rules run (the sum, a category not a group); their ids are new, every
  #   other column is restored as recorded, `created_at` and `updated_at` included (the line is the old line put
  #   back; the transaction's own `updated_at` and `lock_version` show the undo). The status comes back from
  #   `previous`, and the payee too when the transaction's payee is still the one Accept assigned, the earlier one,
  #   or none (a payee a person set between two acceptances stays). Columns Accept never writes (the date, the
  #   comment, the account, the merchant) are not in `previous` and stay as they are.
  # - `created` (Accept created the expense): the transaction must still be as Accept left it (version and lines
  #   digest); then it is destroyed with its lines.
  # - No record, on a transaction of source `receipt` (booked before records existed): Accept created it, so it is
  #   destroyed the same way, but without the "unchanged since" check (there is nothing to compare with; no such
  #   receipt was in the real data when the undo came) and keeping its payee, since nothing says who created it. Any
  #   other transaction without a record is refused (NotUndoable): its earlier state is not known.
  # - A transfer leg is refused.
  #
  # References `previous` names that no longer resolve are dropped, not guessed: a category deleted or turned into a
  # group leaves its line without a category (and without the category's origin, which needs one); a suggested
  # category likewise drops the whole stored suggestion, a runner-up just the runner-up. A `confirmed` transaction
  # that thereby gets a line without a category becomes `needs_review`, Accept's own rule. The result lists what
  # was dropped, so the page tells the person.
  #
  # A payee Accept created (`payee_created`) is deleted afterwards when no transaction, no other booking record and no
  # linked booking's `previous` refers to it, inside a savepoint: a parallel reuse or a foreign key keeps the payee and
  # never the undo back. Kept because another booking assigned it too, it passes "Accept created it" on to that one.
  #
  # The receipt ends `extracted` with no transaction (Receipt#release_from_ledger!), its booking record gone; its
  # items, their categories and `accepted_by_user`, its ground truth, OCR and QR columns, photos and
  # `ocr_requested_at` are untouched. Not pristine (it is not `uploaded`), so the receipt load keeps it, and
  # nothing queues OCR for an `extracted` receipt but a person's "Read again".
  #
  # Locks, in Receipts::Accept's order so the two cannot deadlock: the receipt row, the transaction row, its lines in
  # id order (the suggestion job writes lines without moving the transaction's version); then the payee the record
  # assigned, so undos of bookings that share a payee take turns. Everything runs in one
  # database transaction: a refusal changes nothing. Every refusal is a subclass of Error, its message in words for
  # the page; a lock or a reference lost to a parallel writer is Busy. The SQL log is silenced while it writes.
  class UndoAccept
    Result = Data.define(:mode, :transaction_id, :transaction_deleted, :dropped, :payee_removed, :payee_kept) do
      def transaction_deleted? = transaction_deleted
      def payee_removed? = payee_removed
      def payee_kept? = payee_kept
    end

    # The line columns restored from `previous` as recorded: every recorded column but the ids and the references
    # checked one by one.
    PLAIN_COLUMNS = (ReceiptBooking::LINE_COLUMNS - %w[id transaction_id category_id suggested_category_id runner_up_category_id]).freeze
    CATEGORY_ORIGIN_COLUMNS = %w[category_origin category_origin_probability category_origin_model_version].freeze
    SUGGESTION_COLUMNS = %w[suggested_category_id suggestion_probability runner_up_category_id runner_up_probability
                            suggestion_source suggestion_model_version suggested_at].freeze
    RUNNER_UP_COLUMNS = %w[runner_up_category_id runner_up_probability].freeze

    class Error < StandardError; end
    # The receipt is not booked into the ledger (not `reviewed`, or no transaction).
    class NotBooked < Error; end
    # The page is older than the receipt or its transaction.
    class Stale < Error; end
    # The transaction changed after the receipt was booked on it: undoing would overwrite that change.
    class ChangedSinceBooking < Error; end
    # The transaction cannot be put back: a transfer leg, no record of its earlier state, or a record that does not
    # fit it.
    class NotUndoable < Error; end
    # The record of the earlier state has a format this code does not know.
    class UnknownFormat < Error; end
    # A parallel writer held a lock (a deadlock with an import, say): nothing was undone, trying again may work.
    class Busy < Error; end

    def self.call(receipt, lock_version:, transaction_lock_version:)
      new(receipt, lock_version:, transaction_lock_version:).call
    end

    def initialize(receipt, lock_version:, transaction_lock_version:)
      @receipt = receipt
      @lock_version = lock_version
      @transaction_lock_version = transaction_lock_version
      @dropped = []
    end

    # Returns a Result.
    def call
      result = silencing_sql_log { Receipt.transaction(requires_new: true) { undo } }
      @receipt.reload
      LiveUpdate.changed(@receipt)
      result
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      raise Busy, "another change was writing the transaction at the same moment; try again"
    rescue ActiveRecord::InvalidForeignKey
      raise Busy, "something the earlier state refers to was deleted at the same moment; try again"
    end

    private
      def undo
        @receipt.lock!
        check_receipt
        transaction = lock_transaction(@receipt.transaction_id)
        check_transaction(transaction)
        booking = transaction.receipt_booking
        check_booking(transaction, booking)
        lock_assigned_payee(booking)

        if booking&.linked?
          restore(transaction, booking)
        else
          remove(transaction, booking)
        end
      end

      # Undos whose bookings assigned one payee take turns on that payee's row lock (taken last, after Accept's order),
      # so each sees the other's booking gone and its "created" flag handed over, then reads its own flag again.
      def lock_assigned_payee(booking)
        return unless booking&.assigned_payee_id

        Payee.where(id: booking.assigned_payee_id).lock.pick(:id)
        booking.reload
      end

      # The restore writes the earlier lines' comments and amounts: kept out of the SQL log, as the importers do.
      def silencing_sql_log(&block)
        logger = ActiveRecord::Base.logger
        logger ? logger.silence(Logger::WARN, &block) : yield
      end

      def check_receipt
        unless @receipt.reviewed? && @receipt.transaction_id
          raise NotBooked, "the receipt is not booked into the ledger (it is #{@receipt.status})"
        end
        return if @lock_version.to_s == @receipt.lock_version.to_s

        raise Stale, "the receipt changed somewhere else after the page was opened"
      end

      # The transaction row, then its lines in id order, under row locks; then read again as stored.
      def lock_transaction(id)
        raise NotUndoable, "the receipt's transaction no longer exists" unless Transaction.lock.find_by(id:)

        TransactionLine.where(transaction_id: id).order(:id).lock.load
        Transaction.includes(:receipt_booking, :lines).find(id)
      end

      def check_transaction(transaction)
        if @transaction_lock_version.to_s != transaction.lock_version.to_s
          raise Stale, "the transaction changed somewhere else after the page was opened"
        end
        raise NotUndoable, "the receipt is booked on a transfer leg" if transaction.transfer_leg?
      end

      def check_booking(transaction, booking)
        other = ReceiptBooking.where(receipt_id: @receipt.id).where.not(transaction_id: transaction.id).exists?
        if other || (booking && booking.receipt_id != @receipt.id)
          raise NotUndoable, "the record of the booking does not match the receipt and its transaction"
        end

        if booking.nil?
          return if transaction.from_receipt?

          raise NotUndoable, "there is no record of the transaction's state before the receipt was booked on it"
        end
        if booking.created? && !transaction.from_receipt?
          raise NotUndoable, "the record says the receipt created the transaction, but its source is #{transaction.source}"
        end
        check_format(booking) if booking.linked?
        check_unchanged(transaction, booking)
      end

      def check_format(booking)
        format = booking.previous["format"]
        return if format == ReceiptBooking::PREVIOUS_FORMAT

        raise UnknownFormat, "the record of the transaction's earlier state has format #{format.inspect}, which this version " \
          "cannot restore"
      end

      # What a person (or an import) changed since Accept wrote the transaction.
      def check_unchanged(transaction, booking)
        edits = []
        edits << "the transaction itself (its version moved)" if transaction.lock_version != booking.booked_lock_version
        edits << "its lines" if ReceiptBooking.lines_digest(transaction.id) != booking.lines_digest
        others = []
        if booking.linked?
          others << "a later import rewrote it" if transaction.import_digest != booking.transaction_import_digest
          others << "its amount" if transaction.amount != decimal(booking.previous["amount"], "amount")
        end
        return if edits.empty? && others.empty?

        message = "the transaction changed after the receipt was booked on it (#{(edits + others).to_sentence}); " \
          "undoing would overwrite that"
        # An edit in the app (a category from the list, a comment) is overwritten by "Accept again" anyway, which also
        # records the transaction as it leaves it; an import or an amount is not.
        message += ". To undo anyway, accept the receipt again first (it writes the lines anew), then undo" if others.empty?
        raise ChangedSinceBooking, message
      end

      # `linked`: the earlier lines, status and payee come back; the transaction stays.
      def restore(transaction, booking)
        previous = booking.previous
        lines = restored_lines(previous["lines"])
        status = restored_status(previous["status"])
        payee_id = restored_payee_id(transaction, booking, previous["payee_id"])
        old_lines = transaction.lines.map { |line| { id: line.id, _destroy: true } }

        booking.delete
        begin
          transaction.update!(lines_attributes: old_lines + lines, status:, payee_id:)
        rescue ActiveRecord::RecordInvalid => error
          raise NotUndoable, "the transaction's earlier state cannot be restored: #{error.record.errors.full_messages.to_sentence}"
        end
        @receipt.release_from_ledger!

        payee_removed = remove_created_payee(booking)
        Result.new(mode: :linked, transaction_id: transaction.id, transaction_deleted: false, dropped: @dropped.uniq,
          payee_removed:, payee_kept: @payee_kept == true)
      end

      # `created` (or a receipt transaction booked before records existed): the transaction goes, with its lines.
      def remove(transaction, booking)
        transaction.destroy!
        payee_removed = booking ? remove_created_payee(booking) : false
        Result.new(mode: booking ? :created : :unrecorded, transaction_id: transaction.id, transaction_deleted: true,
          dropped: [], payee_removed:, payee_kept: false)
      rescue ActiveRecord::RecordNotDestroyed => error
        raise NotUndoable, "the transaction cannot be deleted: #{error.record.errors.full_messages.to_sentence}"
      end

      # Line attributes from `previous`, for new lines (no id): money from its decimal string, times from ISO 8601
      # with microseconds, references that no longer resolve dropped with what depends on them.
      def restored_lines(stored_lines)
        stored_lines.map do |stored|
          unless stored.is_a?(Hash) && stored.keys.sort == ReceiptBooking::LINE_COLUMNS.sort
            raise NotUndoable, "the record of the transaction's earlier lines is incomplete"
          end

          attributes = stored.slice(*PLAIN_COLUMNS)
          attributes["amount"] = decimal(stored["amount"], "a line's amount")
          ReceiptBooking::TIME_COLUMNS.each { |column| attributes[column] = time(stored[column]) }
          attributes["category_id"] = category(stored["category_id"], "its category") do
            CATEGORY_ORIGIN_COLUMNS.each { |column| attributes[column] = nil }
            @category_dropped = true
          end
          # A recorded suggestion whose best category is gone goes whole; a runner-up is checked on its own (also when
          # the best one was already empty in the record: the database nullifies a deleted suggested category alone).
          suggestion_dropped = false
          attributes["suggested_category_id"] = category(stored["suggested_category_id"], "its suggested category") do
            SUGGESTION_COLUMNS.each { |column| attributes[column] = nil }
            suggestion_dropped = true
          end
          unless suggestion_dropped
            attributes["runner_up_category_id"] = category(stored["runner_up_category_id"], "its runner-up suggestion") do
              RUNNER_UP_COLUMNS.each { |column| attributes[column] = nil }
            end
          end
          attributes
        end
      end

      # The id when it names a category (not a group) now; otherwise nil, noted, and the block clears what depends on
      # it. A key-share lock keeps the category from being deleted until the restored line is in.
      def category(id, what)
        return nil if id.nil?
        return id if Category.leaves.where(id:).lock("FOR KEY SHARE").pick(:id)

        @dropped << (Category.exists?(id:) ? "#{what} is now a group" : "#{what} no longer exists")
        yield
        nil
      end

      def restored_status(status)
        raise NotUndoable, "the record names an unknown status #{status.inspect}" unless Transaction.statuses.key?(status)

        # A category dropped above leaves a line without one: Accept's own rule makes that needs_review.
        @category_dropped && status == "confirmed" ? "needs_review" : status
      end

      # The earlier payee, unless a person set another one between two acceptances (the record would not name it).
      def restored_payee_id(transaction, booking, previous_payee_id)
        current = transaction.payee_id
        unless [ nil, booking.assigned_payee_id, previous_payee_id ].include?(current)
          @payee_kept = true
          return current
        end
        return nil if previous_payee_id.nil?
        return previous_payee_id if Payee.where(id: previous_payee_id).lock("FOR KEY SHARE").pick(:id)

        @dropped << "its earlier payee no longer exists"
        nil
      end

      # Deletes the payee Accept created when nothing refers to it any more. In a savepoint: a refusal keeps the payee
      # and lets the undo commit. Its row is already locked (lock_assigned_payee): a writer that was adding a reference
      # to it (a transaction's foreign key, Payee.find_or_create_by_name!'s key-share read) finished first and is seen,
      # a later one waits and then no longer finds it. When it is kept because another booking also assigned it, that
      # booking inherits "Accept created it", so the last undo of the payee's bookings removes it. True when deleted.
      def remove_created_payee(booking)
        return false unless booking.payee_created? && booking.assigned_payee_id

        Payee.transaction(requires_new: true) do
          payee = Payee.find_by(id: booking.assigned_payee_id)
          if payee.nil?
            false
          elsif payee_in_use?(payee)
            hand_over_created(payee)
            false
          else
            payee.destroy!
            true
          end
        end
      rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed
        false
      end

      # Another booking that assigned the payee takes over "Accept created it". Only one that can be locked at once
      # and still names the payee: a booking an acceptance is rewriting (Accept locks it) keeps its own flag, and then
      # the payee may outlive both bookings, unused and harmless.
      def hand_over_created(payee)
        ids = ReceiptBooking.where(assigned_payee_id: payee.id, payee_created: false).order(:id).limit(1)
          .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
        ReceiptBooking.where(id: ids, assigned_payee_id: payee.id).update_all(payee_created: true, updated_at: Time.current)
      end

      # A transaction names the payee, another booking assigned it, or a linked booking's earlier state names it (an
      # undo of that booking would put it back). The last by JSON containment: a typed comparison that never fails on
      # a value of another type.
      def payee_in_use?(payee)
        Transaction.exists?(payee_id: payee.id) || ReceiptBooking.exists?(assigned_payee_id: payee.id) ||
          ReceiptBooking.linked.where("previous @> ?::jsonb", { payee_id: payee.id }.to_json).exists?
      end

      def decimal(value, what)
        raise ArgumentError unless value.is_a?(String)

        BigDecimal(value)
      rescue ArgumentError, TypeError
        raise NotUndoable, "the record of the transaction's earlier state has an unreadable #{what}"
      end

      def time(value)
        return nil if value.nil?
        raise ArgumentError unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        raise NotUndoable, "the record of the transaction's earlier state has an unreadable time"
      end
  end
end

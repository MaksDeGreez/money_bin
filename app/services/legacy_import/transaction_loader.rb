module LegacyImport
  # Writes the transactions of the export through the Transaction model, so the line-sum and transfer rules
  # are checked on every row. A transaction is found by (source `legacy`, external_id = legacy_id).
  #
  # Ordinary rows:
  # - missing: created with their lines (nested attributes);
  # - stored and different: updated in place; the lines are replaced only when they differ;
  # - stored and the same: not written.
  # The status is `needs_review` when a line has no category or lands in Uncategorised, else `confirmed`.
  #
  # Transfer legs (a `transfer_key` and no lines) are written in pairs, with transfer_id = TransferId.for(key)
  # and status `confirmed`. A stored pair keeps its rows when only details changed (dates, comment, payee,
  # ...), saved leg by leg. When an account, an amount or the status of a leg changed, or the rows were
  # not yet this pair, the stored legs are destroyed and the pair is created again: the legs of a
  # same-currency pair cannot change their amounts one at a time. A row that switches between ordinary and
  # transfer leg is replaced the same way. After all writes every pair is checked with
  # Transaction.transfer_problems.
  #
  # The importer never deletes a row the export does not have: if replacing a pair would destroy such a row
  # (a counterpart, or a row that holds the pair's transfer_id), the import stops instead.
  class TransactionLoader
    # A leg change that cannot be saved one leg at a time.
    PAIR_FIELDS = %w[account_id amount status].freeze

    def initialize(rows, accounts:, payees:, categories:, report:)
      @rows = rows
      @accounts = accounts
      @payees = payees
      @categories = categories
      @report = report
    end

    def call
      @stored = Transaction.from_legacy.where.not(external_id: nil).includes(:lines).index_by(&:external_id)
      # A row stored before this run counts as updated even when it is destroyed and created again.
      @known = @stored.keys.to_set
      @exported = @rows.to_set(&:legacy_id)
      missing = @stored.keys.count { |id| !@exported.include?(id) }
      @report.warn("#{missing} legacy transactions in the database are not in this export; they were left alone") if missing.positive?

      plain, legs = @rows.partition { |row| !row.transfer_leg? }
      plain.each { |row| at(row) { load_plain(row) } }
      pairs = legs.group_by(&:transfer_key)
      pairs.each_value { |pair| at(pair.first) { load_pair(pair) } }
      check_pairs(pairs)
      @report.transfer_pairs = pairs.size
    end

    private
      # Runs the block for one row, so any refusal names that row.
      def at(row, &block)
        @location = Location.of(row)
        RecordErrors.guard(@location, &block)
      end

      def load_plain(row)
        lines, status = lines_and_status(row)
        stored = @stored[row.legacy_id]
        if stored&.transfer_leg?
          destroy(stored)
          stored = nil
        end

        attributes = attributes(row, status:, transfer_id: nil)
        if stored.nil?
          create(row, attributes.merge(lines_attributes: lines))
        else
          update(stored, attributes, lines)
        end
      end

      def update(stored, attributes, lines)
        stored.assign_attributes(attributes)
        lines_differ = !same_lines?(stored.lines, lines)
        stored.lines_attributes = stored.lines.map { |line| { id: line.id, _destroy: true } } + lines if lines_differ

        if lines_differ || stored.has_changes_to_save?
          stored.save!
          @report.count(:transactions, :updated)
        else
          @report.count(:transactions, :unchanged)
        end
      end

      def load_pair(rows)
        transfer_id = TransferId.for(rows.first.transfer_key)
        rows = rows.sort_by { |row| row.amount.negative? ? 0 : 1 } # the out leg first
        wanted = rows.map { |row| attributes(row, status: "confirmed", transfer_id:) }
        stored = rows.map { |row| @stored[row.legacy_id] }
        rows.each { @report.count_status("confirmed") }

        if stored.all? { |leg| leg&.transfer_id == transfer_id }
          update_pair(rows, stored, wanted)
        else
          replace_pair(rows, stored, wanted, transfer_id)
        end
      end

      def update_pair(rows, legs, wanted)
        legs.zip(wanted) { |leg, attributes| leg.assign_attributes(attributes) }
        if legs.any? { |leg| leg.changed.intersect?(PAIR_FIELDS) }
          destroy(legs.first) # takes its counterpart with it
          rows.zip(wanted) { |row, attributes| create(row, attributes) }
          @report.pairs_recreated += 1
        else
          legs.each do |leg|
            next @report.count(:transactions, :unchanged) unless leg.has_changes_to_save?

            leg.save!
            @report.count(:transactions, :updated)
          end
        end
      end

      def replace_pair(rows, stored, wanted, transfer_id)
        stored.compact.each { |leg| destroy(leg) if @stored.key?(leg.external_id) }
        free(transfer_id)
        rows.zip(wanted) { |row, attributes| create(row, attributes) }
        @report.pairs_recreated += 1 if stored.any?
      end

      # Stored rows that still hold this transfer_id belong to another, older pairing. They are replaced
      # when the export has them (their own turn creates them again), else the import stops. Rows sharing a
      # transfer_id are counterparts, so destroying one removes them all.
      def free(transfer_id)
        leg = Transaction.find_by(transfer_id:)
        destroy(leg) if leg
      end

      def destroy(transaction)
        counterpart = transaction.counterpart if transaction.transfer_leg?
        [ transaction, counterpart ].compact.each do |row|
          next if row.from_legacy? && @exported.include?(row.external_id)

          raise Error, "#{@location}: replacing this row would delete a stored transaction that is not in this " \
            "export (database id #{row.id}); fix the pairing or remove that row first"
        end
        transaction.destroy!
        @stored.delete(transaction.external_id)
        @stored.delete(counterpart.external_id) if counterpart
      end

      def create(row, attributes)
        Transaction.create!(attributes.merge(source: :legacy, external_id: row.legacy_id))
        @report.count(:transactions, @known.include?(row.legacy_id) ? :updated : :created)
      end

      def attributes(row, status:, transfer_id:)
        {
          account: @accounts.fetch(row.account_legacy_id), occurred_on: row.occurred_on, occurred_at: row.occurred_at,
          amount: row.amount, original_amount: row.original_amount, original_currency: row.original_currency,
          payee: row.payee_legacy_id && @payees.fetch(row.payee_legacy_id), comment: row.comment, mcc: row.mcc,
          bank_description: row.bank_description, merchant: row.merchant, source_system: row.source_system,
          status:, transfer_id:
        }
      end

      # The nested line attributes and the status they give the transaction.
      def lines_and_status(row)
        review = false
        lines = row.lines.map do |line|
          choice = @categories.for(line.category_legacy_id)
          @report.count_line(choice.outcome)
          review ||= @categories.uncategorised?(choice.category)
          { amount: line.amount, category: choice.category, legacy_category_path: choice.legacy_path, comment: line.comment }
        end
        status = review ? "needs_review" : "confirmed"
        @report.count_status(status)
        [ lines, status ]
      end

      def same_lines?(stored, wanted)
        stored.size == wanted.size && stored.zip(wanted).all? do |line, attributes|
          line.amount == attributes[:amount] && line.category_id == attributes[:category]&.id &&
            line.comment == attributes[:comment] &&
            line.legacy_category_path == TransactionLine.normalize_value_for(:legacy_category_path, attributes[:legacy_category_path])
        end
      end

      def check_pairs(pairs)
        problems = pairs.each_value.flat_map do |rows|
          Transaction.transfer_problems(TransferId.for(rows.first.transfer_key)).map do |problem|
            "#{Location.of(rows.first)}: transfer_key #{problem}"
          end
        end
        raise Error, problems if problems.any?
      end
  end
end

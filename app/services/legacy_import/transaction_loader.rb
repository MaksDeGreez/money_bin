module LegacyImport
  # Writes the transactions of the export through the Transaction model, so the line-sum and transfer rules
  # are checked on every row. A transaction is found by (source `legacy`, external_id = legacy_id), and
  # every row it writes gets `import_digest` = the digest of its export row (RowDigest).
  #
  # Ordinary rows:
  # - missing: created with their lines (nested attributes);
  # - stored with the same digest: not written at all, so changes made in the app since are kept;
  # - stored with another digest (or none): written from the export in place; the lines are replaced only
  #   when they differ.
  # The status is `needs_review` when a line has no category or lands in Uncategorised, else `confirmed`.
  #
  # Transfer legs (a `transfer_key` and no lines) are written in pairs, with transfer_id = TransferId.for(key)
  # and status `confirmed`. A stored pair whose two legs both have the digest of their export rows is not
  # written. Otherwise the legs whose digest changed are saved in place when only details changed (dates,
  # comment, payee, ...). When an account, an amount or the status of such a leg changes, or the rows were
  # not yet this pair, the stored legs are destroyed and the pair is created again from the export: the legs
  # of a same-currency pair cannot change their amounts one at a time. A row that switches between ordinary
  # and transfer leg is replaced the same way. After all writes every pair is checked with
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
        attributes = attributes(row, status:, transfer_id: nil)
        digest = digest(row)
        return unchanged(stored, attributes, lines) if stored && !stored.transfer_leg? && stored.import_digest == digest

        attributes[:import_digest] = digest
        if stored&.transfer_leg?
          destroy(stored)
          stored = nil
        end

        if stored.nil?
          create(row, attributes.merge(lines_attributes: lines))
        else
          update(stored, attributes, lines)
        end
      end

      def update(stored, attributes, lines)
        stored.assign_attributes(attributes)
        unless same_lines?(stored.lines, lines)
          stored.lines_attributes = stored.lines.map { |line| { id: line.id, _destroy: true } } + lines
        end
        stored.save!
        @report.count(:transactions, :updated)
      end

      # A stored row whose export row has not changed since it was written. It is not written; when it
      # differs from the export, a person changed it in the app, and that change is kept.
      def unchanged(stored, attributes, lines)
        @report.count(:transactions, :unchanged)
        @report.count_kept(:transactions) if local_edits?(stored, attributes, lines)
      end

      def load_pair(rows)
        transfer_id = TransferId.for(rows.first.transfer_key)
        rows = rows.sort_by { |row| row.amount.negative? ? 0 : 1 } # the out leg first
        wanted = rows.map { |row| attributes(row, status: "confirmed", transfer_id:).merge(import_digest: digest(row)) }
        stored = rows.map { |row| @stored[row.legacy_id] }
        rows.each { @report.count_status("confirmed") }

        if stored.all? { |leg| leg&.transfer_id == transfer_id }
          update_pair(rows, stored, wanted)
        else
          replace_pair(rows, stored, wanted, transfer_id)
        end
      end

      # Only the legs whose export row changed are written. A change that cannot be saved one leg at a time
      # recreates the whole pair from the export.
      def update_pair(rows, legs, wanted)
        changed = legs.zip(wanted).filter_map do |leg, attributes|
          next if leg.import_digest == attributes[:import_digest]

          leg.assign_attributes(attributes)
          leg
        end

        if changed.any? { |leg| leg.changed.intersect?(PAIR_FIELDS) }
          destroy(legs.first) # takes its counterpart with it
          rows.zip(wanted) { |row, attributes| create(row, attributes) }
          @report.pairs_recreated += 1
        else
          legs.zip(wanted) do |leg, attributes|
            next unchanged(leg, attributes.except(:import_digest), nil) unless changed.include?(leg)

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

      def digest(row)
        RowDigest.transaction(row, payee_key: row.payee_legacy_id && @payees.fetch(row.payee_legacy_id).normalized_name,
          category: @categories.method(:row))
      end

      # True when the stored row differs from what the export would write (`lines` nil for a transfer leg).
      def local_edits?(stored, attributes, lines)
        attributes.any? do |name, value|
          case name
          when :account, :payee then stored.public_send(:"#{name}_id") != value&.id
          else stored.public_send(name) != value
          end
        end || (!lines.nil? && !same_lines?(stored.lines, lines))
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

module LegacyImport
  # Checks every row of an export read by ExportReader and turns it into a Dataset of typed rows. It finds,
  # before anything is written:
  #
  # - a missing key or a value of the wrong type or form (every key of the contract must be present, also
  #   when its value is null; only a line's `comment` may be left out);
  # - a duplicate `legacy_id` inside a file, and two accounts with the same name;
  # - an account `kind` that is not one of the app's kinds;
  # - amounts that are not decimal strings, have more than two decimal places, or are zero;
  # - a transaction whose currency is not its account's, an original amount without its currency (or the
  #   other way round, or with the account currency, or with the other sign), lines that do not add up;
  # - a reference to an account, payee or category that the export does not have;
  # - a transfer key with one leg or three, legs on one account or with the same sign, legs with lines, and a
  #   same-currency pair that does not net to zero.
  #
  # All problems are collected and raised together as one Error. Keys the contract does not name are
  # ignored and reported as a warning.
  class Verifier
    ACCOUNT_KEYS = %w[legacy_id name kind currency archived].freeze
    CATEGORY_KEYS = %w[legacy_id legacy_path group_en category_en].freeze
    PAYEE_KEYS = %w[legacy_id name].freeze
    TRANSACTION_KEYS = %w[
      legacy_id account_legacy_id occurred_on occurred_at amount currency original_amount original_currency
      payee_legacy_id comment mcc bank_description merchant source_system transfer_key lines
    ].freeze
    LINE_KEYS = %w[amount category_legacy_id].freeze
    OPTIONAL_LINE_KEYS = %w[comment].freeze

    # A required key whose value could not be read.
    BAD = Object.new.freeze

    def self.call(export)
      new(export).call
    end

    def initialize(export)
      @export = export
      @problems = []
      @warnings = []
      @unknown_line_keys = Set.new
      # The legacy ids of each file, also of rows with a problem, so a reference to such a row is not
      # reported a second time as unknown.
      @ids = Hash.new { |hash, file| hash[file] = Set.new }
    end

    def call
      accounts = read("accounts.jsonl", ACCOUNT_KEYS) { |row| account(row) }
      categories = read("categories.jsonl", CATEGORY_KEYS) { |row| category(row) }
      payees = read("payees.jsonl", PAYEE_KEYS) { |row| payee(row) }
      transactions = read("transactions.jsonl", TRANSACTION_KEYS) { |row| transaction(row) }

      check_account_names(accounts)
      check_references(transactions, accounts)
      check_transfers(transactions, accounts) if @problems.empty?
      raise Error, @problems if @problems.any?

      Dataset.new(manifest: @export.manifest, accounts:, categories:, payees:, transactions:, warnings: @warnings)
    end

    private
      # The typed rows of one file; rows with a problem are left out (the problems stop the import anyway).
      def read(file, keys)
        seen = {}
        unknown = Set.new
        rows_with_unknown = 0
        rows = @export.rows.fetch(file).filter_map do |raw|
          extra = raw.data.keys - keys
          unknown.merge(extra)
          rows_with_unknown += 1 if extra.any?
          @row = raw
          @row_problem = false
          id = value("legacy_id", :legacy_id)
          next if id == BAD

          if (first = seen[id])
            problem("legacy_id", "is a duplicate (first on line #{first})")
            next
          end
          seen[id] = raw.line
          @ids[file] << id
          typed = yield(raw)
          typed unless @row_problem
        end
        warn_unknown_keys(file, unknown, rows_with_unknown)
        rows
      end

      def account(raw)
        kind = value("kind") do |text|
          raise Values::Invalid, "is not one of #{Account.kinds.keys.join(', ')}" unless Account.kinds.key?(text)

          text
        end
        Dataset::AccountRow.new(
          file: raw.file, line: raw.line, legacy_id: Values.legacy_id(raw.data["legacy_id"]),
          name: value("name", :text), kind:, currency: value("currency", :currency), archived: value("archived", :boolean)
        )
      end

      def category(raw)
        Dataset::CategoryRow.new(
          file: raw.file, line: raw.line, legacy_id: Values.legacy_id(raw.data["legacy_id"]),
          legacy_path: value("legacy_path", :text), group_en: value("group_en", :text_or_nil),
          category_en: value("category_en", :text_or_nil)
        )
      end

      def payee(raw)
        name = value("name", :text)
        problem("name", "is blank once normalised") if name != BAD && Payee.normalize_name(name).empty?
        Dataset::PayeeRow.new(file: raw.file, line: raw.line, legacy_id: Values.legacy_id(raw.data["legacy_id"]), name:)
      end

      def transaction(raw)
        row = Dataset::TransactionRow.new(
          file: raw.file, line: raw.line, legacy_id: Values.legacy_id(raw.data["legacy_id"]),
          account_legacy_id: value("account_legacy_id", :legacy_id),
          occurred_on: value("occurred_on", :date), occurred_at: value("occurred_at", :time_or_nil),
          amount: value("amount", :amount), currency: value("currency", :currency),
          original_amount: value("original_amount") { |text| text.nil? ? nil : Values.amount(text) },
          original_currency: value("original_currency") { |text| text.nil? ? nil : Values.currency(text) },
          payee_legacy_id: value("payee_legacy_id") { |id| id.nil? ? nil : Values.legacy_id(id) },
          comment: value("comment", :text_or_nil), mcc: value("mcc", :mcc_or_nil),
          bank_description: value("bank_description", :text_or_nil), merchant: value("merchant", :text_or_nil),
          source_system: value("source_system", :text_or_nil),
          transfer_key: value("transfer_key") { |key| key.nil? ? nil : Values.text(key) },
          lines: transaction_lines
        )
        check_transaction(row) unless @row_problem
        row
      end

      def transaction_lines
        lines = value("lines") do |list|
          raise Values::Invalid, "must be a JSON array" unless list.is_a?(Array)

          list
        end
        return [] if lines == BAD

        lines.each_with_index.map do |line, index|
          name = "lines[#{index}]"
          next problem(name, "is not a JSON object") || BAD unless line.is_a?(Hash)

          @unknown_line_keys.merge(line.keys - LINE_KEYS - OPTIONAL_LINE_KEYS)
          Dataset::LineRow.new(
            amount: value("#{name}.amount", :amount, data: line, key: "amount"),
            category_legacy_id: value("#{name}.category_legacy_id", data: line, key: "category_legacy_id") { |id| id.nil? ? nil : Values.legacy_id(id) },
            comment: Values.text_or_nil(line["comment"])
          )
        rescue Values::Invalid => error
          problem("#{name}.comment", error.message) || BAD
        end
      end

      # The rules between the fields of one transaction.
      def check_transaction(row)
        if row.original_amount.nil? != row.original_currency.nil?
          problem("original_amount", "and original_currency must both be set or both be null")
        elsif row.original_amount && row.original_amount.positive? != row.amount.positive?
          problem("original_amount", "must have the same sign as amount")
        elsif row.original_currency && row.original_currency == row.currency
          problem("original_currency", "must differ from the transaction currency")
        end

        if row.transfer_leg?
          problem("lines", "must be empty for a transfer leg") if row.lines.any?
        elsif row.lines.empty?
          problem("lines", "must have at least one line (only a transfer leg has none)")
        elsif row.lines.sum(BigDecimal("0"), &:amount) != row.amount
          problem("lines", "do not add up to amount")
        end
      end

      # Account names are unique in the app, so two accounts of the export cannot share one.
      def check_account_names(accounts)
        accounts.group_by { |account| Account.normalize_value_for(:name, account.name) }.each_value do |same|
          same.drop(1).each do |account|
            add(Location.of(account), "name", "is the same as the account on line #{same.first.line}")
          end
        end
      end

      def check_references(transactions, accounts)
        account_currency = accounts.to_h { |account| [ account.legacy_id, account.currency ] }
        account_ids, category_ids, payee_ids = @ids.values_at("accounts.jsonl", "categories.jsonl", "payees.jsonl")

        transactions.each do |row|
          location = Location.of(row)
          currency = account_currency[row.account_legacy_id]
          if !account_ids.include?(row.account_legacy_id)
            add(location, "account_legacy_id", "names an account that is not in accounts.jsonl")
          elsif currency && currency != row.currency
            add(location, "currency", "is not the currency of its account")
          end
          if row.payee_legacy_id && !payee_ids.include?(row.payee_legacy_id)
            add(location, "payee_legacy_id", "names a payee that is not in payees.jsonl")
          end
          row.lines.each_with_index do |line, index|
            next if line.category_legacy_id.nil? || category_ids.include?(line.category_legacy_id)

            add(location, "lines[#{index}].category_legacy_id", "names a category that is not in categories.jsonl")
          end
        end
      end

      # The same rules as Transaction.transfer_problems, on the export, so a broken pair stops the import before
      # anything is written.
      def check_transfers(transactions, accounts)
        currency = accounts.to_h { |account| [ account.legacy_id, account.currency ] }
        transactions.select(&:transfer_leg?).group_by(&:transfer_key).each_value do |legs|
          location = Location.of(legs.first)
          unless legs.size == 2
            add(location, "transfer_key", "has #{legs.size} legs in the export; a transfer needs exactly two " \
              "(legacy_ids #{legs.map { |leg| Values.printable_id(leg.legacy_id) }.join(', ')})")
            next
          end

          out_leg, in_leg = legs
          other = "the leg on line #{in_leg.line}"
          if out_leg.account_legacy_id == in_leg.account_legacy_id
            add(location, "transfer_key", "joins two legs on the same account (#{other})")
          elsif out_leg.amount.positive? == in_leg.amount.positive?
            add(location, "transfer_key", "joins two legs with the same sign (#{other})")
          elsif currency[out_leg.account_legacy_id] == currency[in_leg.account_legacy_id] && out_leg.amount + in_leg.amount != 0
            add(location, "transfer_key", "joins two same-currency legs that do not net to zero (#{other}); " \
              "a fee must be a separate expense row")
          end
        end
      end

      def warn_unknown_keys(file, unknown, rows)
        if unknown.any?
          @warnings << "#{file}: #{rows} #{rows == 1 ? 'row has' : 'rows have'} fields this importer does not read " \
            "(#{field_names(unknown)}); they were ignored"
        end
        return unless file == "transactions.jsonl" && @unknown_line_keys.any?

        @warnings << "#{file}: some lines have fields this importer does not read " \
          "(#{field_names(@unknown_line_keys)}); they were ignored"
      end

      def field_names(keys)
        keys.map { |key| Values.printable_id(key) }.uniq.sort.join(", ")
      end

      # The value of a required key of the current row, read with a Values reader (by name) or a block. A
      # missing key or a value the reader refuses is recorded as a problem and gives BAD.
      def value(field, reader = nil, data: @row.data, key: field)
        return problem(field, "is missing") || BAD unless data.key?(key)

        reader ? Values.public_send(reader, data[key]) : yield(data[key])
      rescue Values::Invalid => error
        problem(field, error.message) || BAD
      end

      # Records a problem of the current row and returns nil.
      def problem(field, text)
        @row_problem = true
        id = @row.data["legacy_id"]
        location = Location.new(file: @row.file, line: @row.line, legacy_id: id.is_a?(Integer) || id.is_a?(String) ? id : nil)
        add(location, field, text)
      end

      def add(location, field, text)
        @problems << "#{location}: #{field} #{text}"
        nil
      end
  end
end

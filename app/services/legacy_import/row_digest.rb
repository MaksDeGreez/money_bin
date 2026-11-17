require "digest"

module LegacyImport
  # The `import_digest` of an account or a transaction: the SHA-256 (64 lower-case hex characters) of a
  # canonical form of the export row the record was written from. A later run that computes the same
  # digest leaves the record alone, so what a person changed in the app since is kept; only a changed export
  # row is written again.
  #
  # The canonical form is the JSON text (JSON.generate, no spaces) of
  #
  #   [VERSION, "account" | "transaction", { field => value, ... }]
  #
  # where every object has its keys sorted, so the order of keys in the file does not matter, and each value
  # is written by its type, so the spelling in the file does not matter either:
  #
  # - an id (legacy_id, account_legacy_id, transfer_key): its text, so 12 and "12" are the same;
  # - an amount: BigDecimal#to_s("F") of the parsed value ("-120", "-120.0" and "-120.00" are all "-120.0");
  # - a date: "YYYY-MM-DD";
  # - a time: UTC with six fraction digits ("2026-01-10T07:00:00.000000Z" for "2026-01-10T09:00:00+02:00");
  # - an account name: squished, as the Account model stores it; other text as given; null as null;
  # - the payee: its normalised name (Payee.normalize_name), which is what finds the payee;
  # - a line's category: the old category's legacy_path, group_en and category_en (squished), which is what
  #   decides the category and the old path the line gets, or null for a line without a category.
  #
  # A transaction's lines are kept in their order. VERSION changes when the form changes; every stored
  # digest then differs once, and the next run writes every row again.
  module RowDigest
    VERSION = 1

    module_function

    def account(row)
      hex("account", legacy_id: row.legacy_id, name: Account.normalize_value_for(:name, row.name), kind: row.kind,
        currency: row.currency, archived: row.archived)
    end

    # `payee_key` is the payee's normalised name (nil for no payee); `category` is the CategoryRow of a line's
    # category_legacy_id (nil for no category).
    def transaction(row, payee_key:, category:)
      lines = row.lines.map do |line|
        { amount: decimal(line.amount), category: category_part(category.call(line.category_legacy_id)), comment: line.comment }
      end
      hex("transaction",
        legacy_id: row.legacy_id, account_legacy_id: row.account_legacy_id, occurred_on: row.occurred_on.iso8601,
        occurred_at: row.occurred_at&.utc&.iso8601(6), amount: decimal(row.amount), currency: row.currency,
        original_amount: decimal(row.original_amount), original_currency: row.original_currency, payee: payee_key,
        comment: row.comment, mcc: row.mcc, bank_description: row.bank_description, merchant: row.merchant,
        source_system: row.source_system, transfer_key: row.transfer_key, lines:)
    end

    def hex(record, fields)
      ::Digest::SHA256.hexdigest(JSON.generate([ VERSION, record, canonical(fields) ]))
    end

    def canonical(value)
      case value
      when Hash then value.map { |key, item| [ key.to_s, canonical(item) ] }.sort_by(&:first).to_h
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def decimal(value)
      value&.to_s("F")
    end

    def category_part(row)
      row && { legacy_path: row.legacy_path, group_en: row.group_en&.squish, category_en: row.category_en&.squish }
    end
  end
end

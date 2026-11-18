class ReceiptGroundTruth
  # The shape of a ground-truth document, schema version 1: the OCR contract's `receipt` object
  # (ml/README.md) without `sum_matches_total` (it is computed, not read), plus `is_return`.
  #
  #   {
  #     "kind" => "fiscal", "merchant" => "Example Market", "fiscal_number" => "4000000001",
  #     "receipt_number" => "900001", "issued_at" => "2026-10-03T18:40:00+03:00", "total" => "123.45",
  #     "currency" => "UAH", "card_last4" => nil, "is_return" => false,
  #     "items" => [ { "name" => "Rye bread", "quantity" => "2.000", "unit_price" => "20.20",
  #                    "amount" => "40.40", "discount" => "0.00" } ]
  #   }
  #
  # Every key is present and only these keys; any value but an item's `name` may be null (not known).
  # Money is a decimal string with exactly two places and a quantity one with exactly three: never a JSON
  # number, so no float ever holds money, and one spelling per value, so comparing strings compares values.
  # `is_return` is true for a return receipt (money paid back, not a purchase).
  module Document
    KEYS = %w[kind merchant fiscal_number receipt_number issued_at total currency card_last4 is_return items].freeze
    ITEM_KEYS = %w[name quantity unit_price amount discount].freeze
    TEXT_KEYS = %w[merchant fiscal_number receipt_number].freeze
    KINDS = %w[fiscal card_slip].freeze
    MONEY = /\A-?\d{1,13}\.\d{2}\z/
    QUANTITY = /\A\d{1,9}\.\d{3}\z/
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})\z/
    TEXT_LIMIT = 500

    module_function

    # A document with every key and nothing known.
    def blank
      KEYS.index_with { nil }.merge("items" => [])
    end

    # `value` (a BigDecimal) as a decimal string with exactly `places` places, or nil when it has more places
    # than that: a value is never rounded.
    def decimal_string(value, places)
      return nil unless value.is_a?(BigDecimal) && value.finite?
      return nil unless value.round(places) == value

      text = value.abs.to_s("F")
      whole, fraction = text.split(".")
      fraction = fraction.to_s.sub(/0+\z/, "")
      "#{'-' if value.negative?}#{whole}.#{fraction.ljust(places, '0')}"
    end

    # The problems of `document` as sentences (empty when it has the shape). They name keys and item
    # positions, never values.
    def problems(document, items_known: true)
      return [ "must be a JSON object" ] unless document.is_a?(Hash)

      problems = key_problems(document.keys, KEYS, "")
      problems << "kind must be one of #{KINDS.join(', ')} or null" unless document["kind"].nil? || KINDS.include?(document["kind"])
      TEXT_KEYS.each { |key| problems << "#{key} must be text or null" unless text?(document[key]) }
      problems << "issued_at must be an ISO 8601 time with an offset, or null" unless matches?(document["issued_at"], TIME) && time?(document["issued_at"])
      problems << "total must be a decimal string with two places, or null" unless matches?(document["total"], MONEY)
      problems << "currency must be three upper-case letters, or null" unless matches?(document["currency"], Account::CURRENCY_FORMAT)
      problems << "card_last4 must be four digits, or null" unless matches?(document["card_last4"], Receipt::CARD_LAST4_FORMAT)
      problems << "is_return must be true, false or null" unless [ true, false, nil ].include?(document["is_return"])
      problems.concat(items_problems(document["items"], items_known))
    end

    def items_problems(items, items_known)
      return [ "items must be a list" ] unless items.is_a?(Array)
      return [ "items must be empty when the source gave no item lines" ] if !items_known && items.any?

      items.each_with_index.flat_map { |item, index| item_problems(item, "item #{index + 1}") }
    end

    def item_problems(item, label)
      return [ "#{label} must be a JSON object" ] unless item.is_a?(Hash)

      problems = key_problems(item.keys, ITEM_KEYS, "#{label} ")
      name = item["name"]
      problems << "#{label} name must be text" unless name.is_a?(String) && name.strip.present? && name.length <= TEXT_LIMIT
      problems << "#{label} quantity must be a positive decimal string with three places, or null" unless quantity?(item["quantity"])
      %w[unit_price amount].each do |key|
        problems << "#{label} #{key} must be a decimal string with two places, or null" unless matches?(item[key], MONEY)
      end
      unless matches?(item["discount"], MONEY) && !item["discount"].to_s.start_with?("-")
        problems << "#{label} discount must be a decimal string with two places, not negative, or null"
      end
      problems
    end

    def key_problems(keys, expected, prefix)
      problems = []
      missing = expected - keys
      extra = keys - expected
      problems << "#{prefix}misses #{missing.join(', ')}" if missing.any?
      problems << "#{prefix}has unknown keys (#{extra.size})" if extra.any?
      problems
    end

    # nil passes; anything else must be a String (never a number) matching `pattern`.
    def matches?(value, pattern)
      value.nil? || (value.is_a?(String) && pattern.match?(value))
    end

    def text?(value)
      value.nil? || (value.is_a?(String) && value.length <= TEXT_LIMIT)
    end

    def quantity?(value)
      matches?(value, QUANTITY) && (value.nil? || BigDecimal(value).positive?)
    end

    # Time.iso8601 would roll 30 February over into March, so the date is checked on its own first.
    def time?(value)
      return true if value.nil?

      year, month, day = value[0, 10].split("-").map(&:to_i)
      Date.valid_date?(year, month, day) && Time.iso8601(value).present?
    rescue ArgumentError
      false
    end
  end
end

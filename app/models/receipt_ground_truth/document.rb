class ReceiptGroundTruth
  # The shape of a ground-truth document: the OCR contract's `receipt` object (ml/README.md) without
  # `sum_matches_total` (it is computed, not read), plus `is_return`, and from schema version 2 the categories.
  #
  # Version 2 (what every writer writes now):
  #
  #   {
  #     "kind" => "fiscal", "merchant" => "Example Market", "fiscal_number" => "4000000001",
  #     "receipt_number" => "900001", "issued_at" => "2026-10-03T18:40:00+03:00", "total" => "123.45",
  #     "currency" => "UAH", "card_last4" => nil, "is_return" => false, "category_slug" => nil,
  #     "items" => [ { "name" => "Rye bread", "quantity" => "2.000", "unit_price" => "20.20",
  #                    "amount" => "40.40", "discount" => "0.00", "category_slug" => "groceries/groceries" } ]
  #   }
  #
  # Version 1 is the same without the two `category_slug` keys. Both stay readable: a stored record is never
  # rewritten to a newer version (an imported record may have been checked by a person, and its content does
  # not change with the shape); whatever reads a record takes `upgrade`d, version 2, documents.
  #
  # Every key is present and only these keys; any value but an item's `name` may be null (not known).
  # Money is a decimal string with exactly two places and a quantity one with exactly three: never a JSON
  # number, so no float ever holds money, and one spelling per value, so comparing strings compares values.
  # `is_return` is true for a return receipt (money paid back, not a purchase).
  #
  # Categories are slugs (Category#slug, "groceries/groceries"), under the key the ML service's contract uses
  # for a category, `category_slug`: a rename keeps the slug, so a record stays right when a category is
  # renamed. An item's `category_slug` is its category; the receipt's `category_slug` is a card slip's one
  # category (a slip has no items) and null for any other kind. `categories_known` (a column of the
  # record, as `items_known` is) says whether the source gave them: true means every item has one and a slip
  # has its own; false means every category is null.
  module Document
    VERSIONS = [ 1, 2 ].freeze
    CURRENT_VERSION = 2
    KEYS_V1 = %w[kind merchant fiscal_number receipt_number issued_at total currency card_last4 is_return items].freeze
    ITEM_KEYS_V1 = %w[name quantity unit_price amount discount].freeze
    KEYS = (KEYS_V1[0...-1] + %w[category_slug items]).freeze
    ITEM_KEYS = (ITEM_KEYS_V1 + %w[category_slug]).freeze
    TEXT_KEYS = %w[merchant fiscal_number receipt_number].freeze
    KINDS = %w[fiscal card_slip].freeze
    MONEY = /\A-?\d{1,13}\.\d{2}\z/
    QUANTITY = /\A\d{1,9}\.\d{3}\z/
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})\z/
    # A category's slug, never a group's: "<group>/<category>".
    CATEGORY = %r{\A#{Category::SLUG_PART}/#{Category::SLUG_PART}\z}
    TEXT_LIMIT = 500

    module_function

    # A document of `version` with every key and nothing known.
    def blank(version = CURRENT_VERSION)
      keys(version).index_with { nil }.merge("items" => [])
    end

    def keys(version)
      version == 1 ? KEYS_V1 : KEYS
    end

    def item_keys(version)
      version == 1 ? ITEM_KEYS_V1 : ITEM_KEYS
    end

    # `document` of schema `version` as a version 2 document, a new object (the stored one is left alone).
    # Version 1 had no categories: they come out null. Not a document (or an unknown version) comes back as it
    # is, for the validator to refuse.
    def upgrade(document, version)
      return document unless document.is_a?(Hash) && VERSIONS.include?(version)
      return document.deep_dup if version == CURRENT_VERSION

      items = document["items"]
      items = items.map { |item| item.is_a?(Hash) ? item.merge("category_slug" => nil) : item } if items.is_a?(Array)
      document.except("items").merge("category_slug" => nil, "items" => items).deep_dup
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

    # The problems of `document` as sentences (empty when it has the shape of schema `version`). They name keys
    # and item positions, never values.
    def problems(document, items_known: true, categories_known: false, version: CURRENT_VERSION)
      return [ "has an unknown schema version" ] unless VERSIONS.include?(version)
      return [ "must be a JSON object" ] unless document.is_a?(Hash)

      problems = key_problems(document.keys, keys(version), "")
      problems << "kind must be one of #{KINDS.join(', ')} or null" unless document["kind"].nil? || KINDS.include?(document["kind"])
      TEXT_KEYS.each { |key| problems << "#{key} must be text or null" unless text?(document[key]) }
      problems << "issued_at must be an ISO 8601 time with an offset, or null" unless matches?(document["issued_at"], TIME) && time?(document["issued_at"])
      problems << "total must be a decimal string with two places, or null" unless matches?(document["total"], MONEY)
      problems << "currency must be three upper-case letters, or null" unless matches?(document["currency"], Account::CURRENCY_FORMAT)
      problems << "card_last4 must be four digits, or null" unless matches?(document["card_last4"], Receipt::CARD_LAST4_FORMAT)
      problems << "is_return must be true, false or null" unless [ true, false, nil ].include?(document["is_return"])
      problems.concat(items_problems(document["items"], items_known, version))
      problems.concat(category_problems(document, categories_known, version))
    end

    def items_problems(items, items_known, version = CURRENT_VERSION)
      return [ "items must be a list" ] unless items.is_a?(Array)
      return [ "items must be empty when the source gave no item lines" ] if !items_known && items.any?

      items.each_with_index.flat_map { |item, index| item_problems(item, "item #{index + 1}", version) }
    end

    def item_problems(item, label, version = CURRENT_VERSION)
      return [ "#{label} must be a JSON object" ] unless item.is_a?(Hash)

      problems = key_problems(item.keys, item_keys(version), "#{label} ")
      name = item["name"]
      problems << "#{label} name must be text" unless name.is_a?(String) && name.strip.present? && name.length <= TEXT_LIMIT
      problems << "#{label} quantity must be a positive decimal string with three places, or null" unless quantity?(item["quantity"])
      %w[unit_price amount].each do |key|
        problems << "#{label} #{key} must be a decimal string with two places, or null" unless matches?(item[key], MONEY)
      end
      unless matches?(item["discount"], MONEY) && !item["discount"].to_s.start_with?("-")
        problems << "#{label} discount must be a decimal string with two places, not negative, or null"
      end
      if version >= 2 && !matches?(item["category_slug"], CATEGORY)
        problems << "#{label} category_slug must be a category's slug, or null"
      end
      problems
    end

    # Version 1 has no categories, so it cannot say they are known. Version 2: known means every item has one
    # and a slip has its own; not known means none anywhere. Only a slip has a category of its own.
    def category_problems(document, categories_known, version)
      if version == 1
        return categories_known ? [ "categories cannot be known in schema version 1" ] : []
      end

      problems = []
      problems << "category_slug must be a category's slug, or null" unless matches?(document["category_slug"], CATEGORY)
      problems << "category_slug is only for a card slip" if !document["category_slug"].nil? && document["kind"] != "card_slip"
      items = document["items"].is_a?(Array) ? document["items"].grep(Hash) : []
      if categories_known
        problems << "categories are known, so every item needs one" if items.any? { |item| item["category_slug"].nil? }
        problems << "categories are known, so a card slip needs its category" if document["kind"] == "card_slip" && document["category_slug"].nil?
      elsif !document["category_slug"].nil? || items.any? { |item| !item["category_slug"].nil? }
        problems << "categories are not known, so every category must be null"
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

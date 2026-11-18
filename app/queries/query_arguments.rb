# Checks the raw values a client sends before they reach a query object, and turns them into the Ruby
# values the queries take (Dates, Integers, enum strings). Shared by both readers of the ledger: the REST
# API (Api::QueryParameters, where every value arrives as a query-string String) and the MCP tools
# (McpTools, where values arrive as JSON: Strings and Integers). So "a date", "an id that exists" or "a
# currency some account uses" mean the same thing on both, and a value one refuses the other refuses too.
#
# A value that is malformed or names nothing raises Invalid, which names the argument and says what is
# allowed. Each caller words it for its own clients ("The parameter 'to' ...", "The argument 'to' ...").
# Every check takes a value that is present: absence (nil) is the caller's business.
module QueryArguments
  class Invalid < StandardError
    attr_reader :name, :reason

    def initialize(name, reason)
      @name = name.to_s
      @reason = reason
      super("'#{@name}' #{reason}")
    end
  end

  # A database id: a positive integer that fits a bigint (PostgreSQL raises on a larger one).
  ID_FORMAT = /\A[1-9][0-9]{0,17}\z/
  MAX_ID = KeysetCursor::MAX_ID
  DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
  TEXT_MAX_LENGTH = 200

  module_function

  # A non-empty String that PostgreSQL can take: valid UTF-8, no NUL character (both would surface as a
  # server error in a query).
  def string(name, value)
    raise Invalid.new(name, "must be a single text value") unless value.is_a?(String)
    raise Invalid.new(name, "must not be empty") if value.empty?
    raise Invalid.new(name, "must be UTF-8 text without NUL characters") if !value.valid_encoding? || value.include?("\0")

    value
  end

  def date(name, value)
    raise Invalid.new(name, "must be a date as YYYY-MM-DD") unless value.is_a?(String) && DATE_FORMAT.match?(value)

    Date.iso8601(value)
  rescue Date::Error
    raise Invalid.new(name, "is not a valid date")
  end

  # `from` and `to` (Dates or nil), checked against each other.
  def date_range(from, to)
    raise Invalid.new(:to, "must not be before 'from'") if from && to && to < from

    [ from, to ]
  end

  # An Integer, or a String of digits as a query string carries it.
  def positive_integer(value)
    return value if value.is_a?(Integer) && value.between?(1, MAX_ID)

    value.to_i if value.is_a?(String) && ID_FORMAT.match?(value) && value.to_i <= MAX_ID
  end

  # The id of an existing row of `model`, as an Integer.
  def id(name, value, model)
    id = positive_integer(value)
    raise Invalid.new(name, "must be a positive integer id") if id.nil?
    raise Invalid.new(name, "names no #{model.model_name.human.downcase} (id #{id})") unless model.exists?(id)

    id
  end

  # A category or a group, by id or by slug ("groceries", "groceries/groceries"); returns its id.
  def category(name, value)
    return id(name, value, Category) unless value.is_a?(String) && !ID_FORMAT.match?(value)

    category = Category.find_by(slug: string(name, value))
    raise Invalid.new(name, "names no category or group (slug #{value}); list_categories gives every slug") if category.nil?

    category.id
  end

  def enum(name, value, values)
    return value if values.include?(value)

    raise Invalid.new(name, "must be one of: #{values.join(', ')}")
  end

  # Free text to search for, stripped; at most TEXT_MAX_LENGTH characters.
  def text(name, value)
    value = string(name, value)
    raise Invalid.new(name, "must be at most #{TEXT_MAX_LENGTH} characters") if value.length > TEXT_MAX_LENGTH
    raise Invalid.new(name, "must contain more than spaces") if value.strip.empty?

    value.strip
  end

  # A currency code that some account uses.
  def currency(name, value)
    raise Invalid.new(name, "must be three upper-case letters (ISO 4217)") unless value.is_a?(String) && Account::CURRENCY_FORMAT.match?(value)
    raise Invalid.new(name, "names a currency that no account uses (#{value})") unless Account.exists?(currency: value)

    value
  end

  # The size of a page: 1 to KeysetCursor::MAX_LIMIT.
  def limit(name, value)
    limit = value.is_a?(Integer) ? value : (value.to_i if value.is_a?(String) && value.match?(/\A[0-9]{1,4}\z/))
    return limit if limit&.between?(1, KeysetCursor::MAX_LIMIT)

    raise Invalid.new(name, "must be a whole number from 1 to #{KeysetCursor::MAX_LIMIT}")
  end
end

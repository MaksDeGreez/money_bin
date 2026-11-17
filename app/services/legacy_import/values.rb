module LegacyImport
  # Strict readers for the values of an export. Each returns the parsed value, or raises Invalid with the
  # kind of problem ("is not a decimal string"); the caller adds the file, line and field. A problem never
  # quotes the value itself.
  module Values
    class Invalid < StandardError; end

    DECIMAL = /\A-?\d+(?:\.\d+)?\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    # Date, "T", hours, minutes and seconds, an optional fraction of at most six digits, and an offset ("Z"
    # or "+02:00"). The column keeps microseconds, so a seventh digit could never be stored as given.
    TIME_WITH_OFFSET = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\z/
    # A legacy id that can be printed in a message: a number or a short code without spaces.
    PRINTABLE_ID = /\A[A-Za-z0-9_.:-]{1,64}\z/

    module_function

    # A legacy id is a JSON integer or a non-empty string. Both are compared as text, so 12 and "12" are the
    # same id. A string with spaces at either end is refused: the models strip `external_id`, so such an id
    # would be stored without them and not found again on the next run.
    def legacy_id(value)
      case value
      when Integer then value.to_s
      when String
        raise Invalid, "is empty" if value.strip.empty?
        raise Invalid, "has spaces at the start or the end" if value.strip != value

        value
      else raise Invalid, "must be an integer or a string"
      end
    end

    # A non-zero amount from a decimal string such as "-1250.50", with at most two decimal places and below
    # 10^13 in magnitude (what decimal(15, 2) holds). Never rounded.
    def amount(value)
      raise Invalid, "must be a decimal string" unless value.is_a?(String)
      raise Invalid, "is not a decimal string" unless value.match?(DECIMAL)

      number = BigDecimal(value)
      raise Invalid, "has more than #{Transaction::MONEY_DECIMAL_PLACES} decimal places" unless
        DecimalPlacesValidator.fits?(number, Transaction::MONEY_DECIMAL_PLACES)
      raise Invalid, "is zero" if number.zero?
      raise Invalid, "is out of range" if number.abs >= Transaction::AMOUNT_LIMIT

      number
    end

    # A calendar date written as YYYY-MM-DD.
    def date(value)
      raise Invalid, "must be a YYYY-MM-DD string" unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value)
    rescue Date::Error
      raise Invalid, "is not a real date"
    end

    # An ISO 8601 time with an offset, or nil.
    def time_or_nil(value)
      return nil if value.nil?
      raise Invalid, "must be an ISO 8601 time with an offset" unless value.is_a?(String) && value.match?(TIME_WITH_OFFSET)

      Time.iso8601(value)
    rescue ArgumentError
      raise Invalid, "is not a real time"
    end

    def currency(value)
      raise Invalid, "must be three upper-case letters" unless value.is_a?(String) && value.match?(Account::CURRENCY_FORMAT)

      value
    end

    def text(value)
      raise Invalid, "must be a string" unless value.is_a?(String)
      raise Invalid, "is blank" if value.strip.empty?

      value
    end

    def text_or_nil(value)
      raise Invalid, "must be a string or null" unless value.nil? || value.is_a?(String)

      value
    end

    def boolean(value)
      raise Invalid, "must be true or false" unless value == true || value == false

      value
    end

    def mcc_or_nil(value)
      return nil if value.nil?
      raise Invalid, "must be a string of four digits" unless value.is_a?(String) && value.match?(Transaction::MCC_FORMAT)

      value
    end

    # The id as it may appear in a message, or a placeholder when it does not look like an id.
    def printable_id(value)
      text = value.to_s
      text.match?(PRINTABLE_ID) ? text : "not printable"
    end
  end
end

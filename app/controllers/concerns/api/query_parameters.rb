module Api
  # Reads and checks query parameters for the API's GET endpoints. A parameter that is unknown, malformed
  # or names something that does not exist raises InvalidParameter, which Api::BaseController answers
  # with 422 `invalid_parameter` and a message that names the parameter. Nothing is ignored silently: an
  # agent that misspells a filter must not get the whole ledger back as if the filter had matched.
  #
  # Each reader returns nil when the parameter is absent, else the checked value in its Ruby type.
  module QueryParameters
    class InvalidParameter < StandardError
      attr_reader :parameter

      def initialize(parameter, message)
        @parameter = parameter.to_s
        super("The parameter '#{@parameter}' #{message}.")
      end
    end

    # A database id: a positive integer that fits a bigint.
    ID_FORMAT = /\A[1-9][0-9]{0,17}\z/
    DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
    TEXT_MAX_LENGTH = 200

    private
      # Refuses every query parameter not listed in `known`.
      def only_known_parameters(*known)
        known = known.map(&:to_s)
        unknown = request.query_parameters.keys - known
        return if unknown.empty?

        expected = known.empty? ? "this endpoint takes no parameters" : "known parameters: #{known.join(', ')}"
        raise InvalidParameter.new(unknown.first, "is not known here (#{expected})")
      end

      # The parameter as a non-empty String, or nil when it is absent. An array or hash value
      # (`status[]=...`), an empty one (`status=`) and one that is not UTF-8 text are refused.
      def string_parameter(name)
        return nil unless request.query_parameters.key?(name.to_s)

        value = request.query_parameters[name.to_s]
        raise InvalidParameter.new(name, "must be a single value") unless value.is_a?(String)
        raise InvalidParameter.new(name, "must not be empty") if value.empty?
        # PostgreSQL refuses both in a query, which would surface as a server error.
        raise InvalidParameter.new(name, "must be UTF-8 text without NUL characters") if !value.valid_encoding? || value.include?("\0")

        value
      end

      def required_parameter(name)
        string_parameter(name) || raise(ActionController::ParameterMissing, name)
      end

      def date_parameter(name, required: false)
        value = required ? required_parameter(name) : string_parameter(name)
        return nil if value.nil?

        raise InvalidParameter.new(name, "must be a date as YYYY-MM-DD") unless DATE_FORMAT.match?(value)

        Date.iso8601(value)
      rescue Date::Error
        raise InvalidParameter.new(name, "is not a valid date")
      end

      # `from` and `to`, checked against each other.
      def date_range_parameters(required: false)
        from = date_parameter(:from, required:)
        to = date_parameter(:to, required:)
        raise InvalidParameter.new(:to, "must not be before 'from'") if from && to && to < from

        [ from, to ]
      end

      # The id of an existing row of `model`, as an Integer.
      def id_parameter(name, model)
        value = string_parameter(name)
        return nil if value.nil?

        raise InvalidParameter.new(name, "must be a positive integer id") unless ID_FORMAT.match?(value)

        id = value.to_i
        raise InvalidParameter.new(name, "names no #{model.model_name.human.downcase} (id #{id})") unless model.exists?(id)

        id
      end

      def enum_parameter(name, values)
        value = string_parameter(name)
        return value if value.nil? || values.include?(value)

        raise InvalidParameter.new(name, "must be one of: #{values.join(', ')}")
      end

      def text_parameter(name)
        value = string_parameter(name)
        return nil if value.nil?

        raise InvalidParameter.new(name, "must be at most #{TEXT_MAX_LENGTH} characters") if value.length > TEXT_MAX_LENGTH
        raise InvalidParameter.new(name, "must contain more than spaces") if value.strip.empty?

        value.strip
      end

      # A currency code that some account uses.
      def currency_parameter(name)
        value = string_parameter(name)
        return nil if value.nil?

        raise InvalidParameter.new(name, "must be three upper-case letters (ISO 4217)") unless Account::CURRENCY_FORMAT.match?(value)
        raise InvalidParameter.new(name, "names a currency that no account uses (#{value})") unless Account.exists?(currency: value)

        value
      end

      def limit_parameter
        value = string_parameter(:limit)
        return KeysetCursor::DEFAULT_LIMIT if value.nil?

        limit = value.match?(/\A[0-9]{1,4}\z/) ? value.to_i : 0
        return limit if limit.between?(1, KeysetCursor::MAX_LIMIT)

        raise InvalidParameter.new(:limit, "must be a whole number from 1 to #{KeysetCursor::MAX_LIMIT}")
      end

      def cursor_parameter
        string_parameter(:cursor)
      end
  end
end

module Api
  # Reads and checks query parameters for the API's GET endpoints. A parameter that is unknown, malformed
  # or names something that does not exist raises QueryArguments::Invalid, which Api::BaseController
  # answers with 422 `invalid_parameter` and a message that names the parameter. Nothing is ignored
  # silently: an agent that misspells a filter must not get the whole ledger back as if the filter had
  # matched.
  #
  # The checks of the values themselves are QueryArguments', which the MCP tools share; this concern adds
  # what is particular to a query string (unknown and repeated names, arrays, a request body).
  #
  # Each reader returns nil when the parameter is absent, else the checked value in its Ruby type.
  module QueryParameters
    private
      # Refuses every query parameter not listed in `known`, and a request body: these endpoints read only
      # the query string, and a filter sent in a JSON or form body would otherwise be ignored.
      def only_known_parameters(*known)
        if request.raw_post.present?
          raise QueryArguments::Invalid.new(body_parameter_name, "was sent in the request body; send it in the query string")
        end

        known = known.map(&:to_s)
        unknown = request.query_parameters.keys - known
        if unknown.any?
          expected = known.empty? ? "this endpoint takes no parameters" : "known parameters: #{known.join(', ')}"
          raise QueryArguments::Invalid.new(unknown.first, "is not known here (#{expected})")
        end

        repeated = query_parameter_names.tally.find { |_name, count| count > 1 }&.first
        raise QueryArguments::Invalid.new(repeated, "must be given once") if repeated
      end

      # The first parameter named in a request body, for the error message: Rails does not parse the body of
      # every GET, so a JSON body is read here. "body" when no name can be read.
      def body_parameter_name
        names = request.request_parameters.keys
        names = Array((JSON.parse(request.raw_post) rescue nil).try(:keys)) if names.empty?
        names.first || "body"
      end

      # The parameter names as they appear in the query string, repeats included. Rails keeps only the last
      # of `status=draft&status=confirmed`, so a repeat can only be seen here.
      def query_parameter_names
        request.query_string.split(/[&;]/).filter_map do |pair|
          name = pair.split("=", 2).first
          Rack::Utils.unescape(name).sub(/\[.*/m, "") if name.present?
        end
      end

      # The parameter as a non-empty String, or nil when it is absent. An array or hash value
      # (`status[]=...`), an empty one (`status=`) and one that is not UTF-8 text are refused.
      def string_parameter(name)
        return nil unless request.query_parameters.key?(name.to_s)

        value = request.query_parameters[name.to_s]
        raise QueryArguments::Invalid.new(name, "must be a single value") unless value.is_a?(String)

        QueryArguments.string(name, value)
      end

      def required_parameter(name)
        string_parameter(name) || raise(ActionController::ParameterMissing, name)
      end

      def date_parameter(name, required: false)
        value = required ? required_parameter(name) : string_parameter(name)
        value && QueryArguments.date(name, value)
      end

      # `from` and `to`, checked against each other.
      def date_range_parameters(required: false)
        QueryArguments.date_range(date_parameter(:from, required:), date_parameter(:to, required:))
      end

      # The id of an existing row of `model`, as an Integer.
      def id_parameter(name, model)
        value = string_parameter(name)
        value && QueryArguments.id(name, value, model)
      end

      def enum_parameter(name, values)
        value = string_parameter(name)
        value && QueryArguments.enum(name, value, values)
      end

      def text_parameter(name)
        value = string_parameter(name)
        value && QueryArguments.text(name, value)
      end

      # A currency code that some account uses.
      def currency_parameter(name)
        value = string_parameter(name)
        value && QueryArguments.currency(name, value)
      end

      def limit_parameter
        value = string_parameter(:limit)
        value ? QueryArguments.limit(:limit, value) : KeysetCursor::DEFAULT_LIMIT
      end

      def cursor_parameter
        string_parameter(:cursor)
      end
  end
end

module McpTools
  # The base of every MCP tool. A tool class sets its name, title, description, input and output schemas
  # and annotations, and implements `answer(**arguments)`, which returns `[text, structured_content]`.
  #
  # The base:
  # - refuses to run without the API token McpController authenticated (the server context carries it), so a
  #   tool can never answer a request that skipped authentication;
  # - turns a bad argument (QueryArguments::Invalid, KeysetCursor::Invalid) and a missing record (NotFound)
  #   into a tool error, `isError: true` with a message that names the argument and what is allowed, so the
  #   model can correct its call. The SDK has already checked the arguments against the input schema (types,
  #   enums, unknown names) before `call` runs;
  # - lets anything else raise: the SDK answers it with a JSON-RPC internal error that carries no message,
  #   no stack trace and no data, and McpServer reports the exception to the Rails log.
  class Base < MCP::Tool
    # Every tool only reads the owner's own ledger: nothing changes, calling it twice gives the same answer
    # (until the ledger changes), and it reaches nothing outside this app.
    ANNOTATIONS = { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }.freeze

    # A record named by an argument that does not exist.
    class NotFound < StandardError; end

    # A token is required: McpController puts the authenticated one in the server context.
    class Unauthenticated < StandardError; end

    DATE_SCHEMA = { type: "string", pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" }.freeze
    ID_SCHEMA = { type: "integer", minimum: 1, maximum: QueryArguments::MAX_ID }.freeze
    LIMIT_SCHEMA = { type: "integer", minimum: 1, maximum: KeysetCursor::MAX_LIMIT }.freeze
    CURSOR_SCHEMA = {
      type: "string", maxLength: KeysetCursor::MAX_LENGTH,
      description: "To read the next page, pass the next_cursor of the previous result unchanged, with the same " \
        "other arguments. Leave it out for the first page."
    }.freeze

    class << self
      def call(server_context:, **arguments)
        raise Unauthenticated, "no API token in the server context" unless server_context[:api_token].is_a?(ApiToken)

        text, structured = answer(**arguments)
        MCP::Tool::Response.new([ { type: "text", text: } ], structured_content: structured)
      rescue QueryArguments::Invalid => error
        error_response("The argument #{error.message}.")
      rescue KeysetCursor::Invalid
        error_response("The argument 'cursor' is not one this server handed out; pass next_cursor from the previous result as it is.")
      rescue NotFound => error
        error_response(error.message)
      end

      private
        def answer(**)
          raise NotImplementedError
        end

        def error_response(message)
          MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
        end

        # The checked Date of an optional argument, or nil.
        def optional_date(name, value)
          value.nil? ? nil : QueryArguments.date(name, value)
        end

        def page_limit(value, default:)
          value.nil? ? default : QueryArguments.limit(:limit, value)
        end

        def cursor(value)
          value.nil? ? nil : QueryArguments.string(:cursor, value)
        end

        # "-1250.40 UAH"; "?" when the amount is not known.
        def money(amount, currency)
          [ amount || "?", currency ].compact.join(" ")
        end

        # A card slip's category for the text: the accepted one, else the suggestion said to be one; nil for
        # a receipt that is not a slip (its categories are on its items).
        def slip_category(json)
          return nil unless json[:kind] == "card_slip"

          if json[:category]
            "category #{json.dig(:category, :slug)}"
          elsif json[:suggested_category]
            "suggested category #{json.dig(:suggested_category, :slug)} (confidence #{json[:confidence]}), not accepted yet"
          else
            "no category yet"
          end
        end

        def more_pages_note(next_cursor)
          return "This is the last page." if next_cursor.nil?

          "More rows follow: call again with the same arguments and cursor \"#{next_cursor}\"."
        end
    end
  end
end

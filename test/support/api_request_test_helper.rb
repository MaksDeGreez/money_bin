# Helpers for the request tests of the read API (test/controllers/api/v1/).
module ApiRequestTestHelper
  # JSON numbers that are allowed to be fractional: a probability is not money.
  FLOAT_KEYS = %w[confidence].freeze

  # A GET with the read token.
  def api_get(path, params: {}, token: :agent_read)
    get path, params:, headers: bearer(plain_token(token))
  end

  def json
    response.parsed_body
  end

  # Fails when the JSON holds a fractional number anywhere but under FLOAT_KEYS: money and quantities must be
  # decimal strings.
  def assert_no_floats(value, path = "$")
    case value
    when Hash then value.each { |key, item| assert_no_floats(item, "#{path}.#{key}") unless FLOAT_KEYS.include?(key) }
    when Array then value.each_with_index { |item, index| assert_no_floats(item, "#{path}[#{index}]") }
    else assert_not_kind_of Float, value, "#{path} is a JSON number with a fraction; money and quantities must be decimal strings"
    end
  end

  # The number of SQL statements the block issues (schema lookups aside). Statements answered by the query
  # cache count too: the test's connection keeps its cache between requests, and what matters is how many
  # statements the code issues.
  def count_queries(&block)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    queries
  end

  def assert_invalid_parameter(parameter)
    assert_response :unprocessable_entity
    assert_api_response_conform(422)
    assert_equal "invalid_parameter", json.dig("error", "code")
    assert_includes json.dig("error", "message"), "'#{parameter}'"
  end
end

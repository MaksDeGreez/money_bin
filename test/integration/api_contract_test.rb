require "test_helper"

# The contract between docs/openapi.yaml and the API:
# - the document keeps the rules that make a response check strict (no undeclared fields, no missing ones);
# - every documented path, method and response status has an example request here, which must answer
#   with that status in the documented shape: a documented path with no test fails;
# - every API route is documented, and every documented path is routed;
# - the rules every endpoint shares: a browser session never authenticates, a read token is enough, a
#   read_write token works too.
class ApiContractTest < ActionDispatch::IntegrationTest
  include OpenapiTestHelper
  include ApiRequestTestHelper

  DOCUMENT = YAML.load_file(OpenapiTestHelper::SCHEMA_PATH)
  HTTP_METHODS = %w[get put post patch delete head options trace].freeze

  # One request per documented "METHOD path status": [path, params, token] (token nil: no Authorization).
  EXAMPLES = {
    "GET /api/v1/status 200" => -> { [ "/api/v1/status", {}, :agent_read ] },
    "GET /api/v1/status 401" => -> { [ "/api/v1/status", {}, nil ] },
    "GET /api/v1/status 422" => -> { [ "/api/v1/status", { x: "1" }, :agent_read ] },
    "GET /api/v1/transactions 200" => -> { [ "/api/v1/transactions", { limit: 5 }, :agent_read ] },
    "GET /api/v1/transactions 401" => -> { [ "/api/v1/transactions", {}, nil ] },
    "GET /api/v1/transactions 422" => -> { [ "/api/v1/transactions", { status: "nope" }, :agent_read ] },
    "GET /api/v1/transactions/{id} 200" => -> { [ "/api/v1/transactions/#{transactions(:coffee).id}", {}, :agent_read ] },
    "GET /api/v1/transactions/{id} 401" => -> { [ "/api/v1/transactions/#{transactions(:coffee).id}", {}, nil ] },
    "GET /api/v1/transactions/{id} 404" => -> { [ "/api/v1/transactions/999999999", {}, :agent_read ] },
    "GET /api/v1/transactions/{id} 422" => -> { [ "/api/v1/transactions/#{transactions(:coffee).id}", { x: "1" }, :agent_read ] },
    "GET /api/v1/accounts 200" => -> { [ "/api/v1/accounts", {}, :agent_read ] },
    "GET /api/v1/accounts 401" => -> { [ "/api/v1/accounts", {}, nil ] },
    "GET /api/v1/accounts 422" => -> { [ "/api/v1/accounts", { x: "1" }, :agent_read ] },
    "GET /api/v1/categories 200" => -> { [ "/api/v1/categories", {}, :agent_read ] },
    "GET /api/v1/categories 401" => -> { [ "/api/v1/categories", {}, nil ] },
    "GET /api/v1/categories 422" => -> { [ "/api/v1/categories", { x: "1" }, :agent_read ] },
    "GET /api/v1/summary 200" => -> { [ "/api/v1/summary", { from: "2026-10-01", to: "2026-10-31" }, :agent_read ] },
    "GET /api/v1/summary 400" => -> { [ "/api/v1/summary", { from: "2026-10-01" }, :agent_read ] },
    "GET /api/v1/summary 401" => -> { [ "/api/v1/summary", { from: "2026-10-01", to: "2026-10-31" }, nil ] },
    "GET /api/v1/summary 422" => -> { [ "/api/v1/summary", { from: "2026-10-01", to: "2026-10-31", currency: "XYZ" }, :agent_read ] },
    "GET /api/v1/receipts 200" => -> { [ "/api/v1/receipts", { limit: 1 }, :agent_read ] },
    "GET /api/v1/receipts 401" => -> { [ "/api/v1/receipts", {}, nil ] },
    "GET /api/v1/receipts 422" => -> { [ "/api/v1/receipts", { limit: "0" }, :agent_read ] },
    "GET /api/v1/receipts/{id} 200" => -> { [ "/api/v1/receipts/#{receipts(:corner_receipt).id}", {}, :agent_read ] },
    "GET /api/v1/receipts/{id} 401" => -> { [ "/api/v1/receipts/#{receipts(:corner_receipt).id}", {}, nil ] },
    "GET /api/v1/receipts/{id} 404" => -> { [ "/api/v1/receipts/999999999", {}, :agent_read ] },
    "GET /api/v1/receipts/{id} 422" => -> { [ "/api/v1/receipts/#{receipts(:corner_receipt).id}", { x: "1" }, :agent_read ] }
  }.freeze

  def self.documented_responses
    DOCUMENT.fetch("paths").flat_map do |path, item|
      item.slice(*HTTP_METHODS).flat_map do |method, operation|
        operation.fetch("responses").keys.map { |status| "#{method.upcase} #{path} #{status}" }
      end
    end
  end

  def self.documented_operations
    DOCUMENT.fetch("paths").flat_map { |path, item| item.slice(*HTTP_METHODS).keys.map { |method| "#{method.upcase} #{path}" } }
  end

  # Every schema object in the document, wherever it sits (components, parameters, responses), with a
  # path to it for the failure message.
  def self.schemas(node = DOCUMENT, path = "#")
    return [] unless node.is_a?(Hash) || node.is_a?(Array)

    pairs = node.is_a?(Hash) ? node.to_a : node.each_with_index.map { |value, index| [ index, value ] }
    own = node.is_a?(Hash) && (node["type"] == "object" || node.key?("properties")) ? [ [ path, node ] ] : []
    own + pairs.flat_map { |key, value| schemas(value, "#{path}/#{key}") }
  end

  def request_example(key)
    path, params, token = instance_exec(&EXAMPLES.fetch(key))
    get path, params:, headers: token ? bearer(plain_token(token)) : {}
  end

  test "every object schema forbids undeclared fields and requires all of its own" do
    self.class.schemas.each do |path, schema|
      assert_equal false, schema["additionalProperties"], "#{path} must set additionalProperties: false"
      assert_equal schema.fetch("properties", {}).keys.sort, Array(schema["required"]).sort,
        "#{path} must list every property in required (a value that may be empty is nullable, not optional)"
      # OpenapiTestHelper#refute_discriminator_key relies on this.
      assert_not schema.fetch("properties", {}).key?("discriminator"), "#{path} must not have a property named discriminator"
    end
  end

  test "the document is OpenAPI 3.0 and loads with strict references" do
    assert_match(/\A3\.0\.\d+\z/, DOCUMENT["openapi"])
    assert_kind_of Committee::Drivers::OpenAPI3::Schema, OpenapiTestHelper.schema
  end

  test "every documented response has an example request here, and no example is stale" do
    assert_equal self.class.documented_responses.sort, EXAMPLES.keys.sort
  end

  EXAMPLES.each_key do |key|
    test "#{key} answers in the documented shape" do
      request_example(key)
      status = key.split.last.to_i

      assert_response status
      status == 200 ? assert_api_conform(status) : assert_api_response_conform(status)
      assert_no_floats(json)
    end
  end

  test "every API route is documented, and every documented path is routed" do
    routed = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      "#{route.verb} #{path.gsub(/:(\w+)/, '{\1}')}" if path.start_with?("/api/")
    end

    assert_equal routed.sort, self.class.documented_operations.sort
  end

  test "a field the document does not describe, a missing required one or a float fails the check" do
    request_example("GET /api/v1/transactions/{id} 200")
    body = json

    broken = [
      body.merge("extra" => 1),
      body.merge("discriminator" => 1),
      body.except("status"),
      body.merge("amount" => -85.0),
      body.merge("lines" => body["lines"].map { |line| line.merge("category" => line["category"].merge("parent" => nil)) })
    ]
    broken.each do |bad|
      with_singleton_method(self, :response_data, -> { [ 200, response.headers, JSON.generate(bad) ] }) do
        assert_raises(Committee::InvalidResponse, Minitest::Assertion) { assert_api_conform(200) }
      end
    end
  end

  test "a query parameter the document does not declare fails the request check" do
    request_example("GET /api/v1/transactions 200")

    with_singleton_method(request, :query_parameters, -> { { "limit" => "5", "undeclared" => "1" } }) do
      env = request.env.merge("action_dispatch.request.query_parameters" => { "limit" => "5", "undeclared" => "1" })
      with_singleton_method(self, :request_object, -> { ActionDispatch::Request.new(env) }) do
        assert_raises(Committee::InvalidRequest) { assert_request_schema_confirm }
      end
    end
  end

  test "every API route is JSON only: a format suffix is not routed" do
    api_get "/api/v1/transactions.xml"
    assert_response :not_found

    api_get "/api/v1/transactions.json"
    assert_response :not_found
  end

  test "a request body is refused, so a filter sent there is never ignored" do
    EXAMPLES.keys.grep(/ 200\z/).each do |key|
      path, _params, _token = instance_exec(&EXAMPLES.fetch(key))
      get path, headers: bearer(plain_token(:agent_read)).merge("Content-Type" => "application/json"),
        env: { "RAW_POST_DATA" => { status: "draft" }.to_json }

      assert_invalid_parameter("status")
    end
  end

  test "a repeated parameter is refused, not narrowed to its last value" do
    get "/api/v1/transactions?status=invalid&status=confirmed", headers: bearer(plain_token(:agent_read))
    assert_invalid_parameter("status")

    get "/api/v1/receipts?limit=1;limit=2", headers: bearer(plain_token(:agent_read))
    assert_invalid_parameter("limit")
  end

  test "a signed-in browser session authenticates no endpoint" do
    sign_in_as users(:owner)

    EXAMPLES.keys.grep(/ 200\z/).each do |key|
      path, params, _token = instance_exec(&EXAMPLES.fetch(key))
      get path, params: params

      assert_response :unauthorized, key
      assert_equal "unauthorized", json.dig("error", "code")
    end
  end

  test "a read_write token reads every endpoint too; a revoked one none" do
    EXAMPLES.keys.grep(/ 200\z/).each do |key|
      path, params, _token = instance_exec(&EXAMPLES.fetch(key))

      get path, params:, headers: bearer(plain_token(:agent_write))
      assert_response :success, key

      get path, params:, headers: bearer(plain_token(:revoked))
      assert_response :unauthorized, key
      assert_equal "invalid_token", json.dig("error", "code")
    end
  end
end

require "committee"

# Checks API requests and responses against docs/openapi.yaml with committee. Include it in an
# ActionDispatch::IntegrationTest and call, after a request:
#
# - `assert_api_conform(200)`: the request (path, query parameters) and the response (status, body) match
#   the document. Use it for requests the document allows;
# - `assert_api_response_conform(422)`: only the response. Use it for requests that are wrong on purpose
#   (an unknown filter, a malformed date), which the request schema rightly refuses.
#
# Every object schema in the document forbids extra properties and requires all of its own
# (test/integration/api_contract_test.rb checks that), so a field added to or dropped from a response
# without the document fails the test.
module OpenapiTestHelper
  include Committee::Test::Methods

  SCHEMA_PATH = Rails.root.join("docs/openapi.yaml").to_s

  def self.schema
    @schema ||= Committee::Drivers.load_from_file(SCHEMA_PATH, parser_options: { strict_reference_validation: true })
  end

  def committee_options
    @committee_options ||= {
      schema: OpenapiTestHelper.schema,
      query_hash_key: "action_dispatch.request.query_parameters",
      parse_response_by_content_type: true,
      validate_success_only: false
    }
  end

  def request_object
    request
  end

  def response_data
    [ response.status, response.headers, response.body ]
  end

  def assert_api_conform(status)
    assert_schema_conform(status)
  end

  def assert_api_response_conform(status)
    assert_response_schema_confirm(status)
  end
end

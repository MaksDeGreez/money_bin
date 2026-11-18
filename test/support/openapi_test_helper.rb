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
      # A query parameter the document does not declare fails the request check.
      strict_query_params: true,
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
    refute_discriminator_key
  end

  def assert_api_response_conform(status)
    assert_response_schema_confirm(status)
    refute_discriminator_key
  end

  # openapi_parser 2.8 drops a key literally named "discriminator" before it checks
  # additionalProperties: false, even in schemas without a discriminator, so such a key would pass
  # unnoticed. No schema in the document has that property (the contract test checks), so any such key is
  # undocumented.
  def refute_discriminator_key(value = JSON.parse(response_data.last))
    case value
    when Hash
      assert_not value.key?("discriminator"), "the response has a key 'discriminator', which docs/openapi.yaml does not describe"
      value.each_value { |item| refute_discriminator_key(item) }
    when Array then value.each { |item| refute_discriminator_key(item) }
    end
  end
end

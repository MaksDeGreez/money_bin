# The plain values behind the api_tokens fixtures (the fixtures store only their digests), and a helper
# for the Authorization header. Test data only: low-entropy values padded to match ApiToken::FORMAT.
module ApiTokenTestHelper
  PLAIN_TOKENS = {
    agent_read: "mbt_#{'fixtureRead'.ljust(ApiToken::RANDOM_LENGTH, '1')}",
    agent_write: "mbt_#{'fixtureWrite'.ljust(ApiToken::RANDOM_LENGTH, '1')}",
    revoked: "mbt_#{'fixtureRevoked'.ljust(ApiToken::RANDOM_LENGTH, '1')}"
  }.freeze

  def plain_token(fixture_name)
    PLAIN_TOKENS.fetch(fixture_name)
  end

  def bearer(plain_token)
    { "Authorization" => "Bearer #{plain_token}" }
  end
end

ActiveSupport.on_load(:active_support_test_case) { include ApiTokenTestHelper }

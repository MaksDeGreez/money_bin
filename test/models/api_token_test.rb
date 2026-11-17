require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  setup { @owner = users(:owner) }

  test "issue returns the record and a prefixed, high-entropy plain token" do
    api_token, plain_token = ApiToken.issue(user: @owner, name: "  Laptop   agent ", scope: "read_write")

    assert api_token.persisted?
    assert_equal "Laptop agent", api_token.name
    assert api_token.read_write?
    assert_match ApiToken::FORMAT, plain_token
    assert_equal 48, plain_token.length
    # 44 base58 characters carry 44 * log2(58), about 257 bits: more than 32 random bytes.
    assert_operator ApiToken::RANDOM_LENGTH * Math.log2(58), :>=, 256
  end

  test "issue defaults to the read scope" do
    api_token, _plain_token = ApiToken.issue(user: @owner, name: "Reader")

    assert api_token.read?
  end

  test "two tokens never share a plain value" do
    plain_tokens = Array.new(20) { |index| ApiToken.issue(user: @owner, name: "Agent #{index}").last }

    assert_equal 20, plain_tokens.uniq.size
  end

  test "only the SHA-256 digest is stored, and the plain value is nowhere in the database" do
    api_token, plain_token = ApiToken.issue(user: @owner, name: "Agent")

    assert_equal Digest::SHA256.hexdigest(plain_token), api_token.reload.token_digest
    assert_not_respond_to api_token, :plain_token
    assert_not_respond_to api_token, :token

    row = ApiToken.connection.select_one("SELECT * FROM api_tokens WHERE id = #{api_token.id}")
    assert row.values.none? { |value| value.to_s.include?(plain_token) }
    assert row.values.none? { |value| value.to_s.include?(plain_token.delete_prefix(ApiToken::PREFIX)) }
  end

  test "an invalid token is not saved and has no plain value" do
    api_token, plain_token = ApiToken.issue(user: @owner, name: " ", scope: "read")

    assert_not api_token.persisted?
    assert_nil plain_token
    assert api_token.errors.added?(:name, :blank)
  end

  test "the scope must be read or read_write" do
    api_token, plain_token = ApiToken.issue(user: @owner, name: "Agent", scope: "admin")

    assert_nil plain_token
    assert api_token.errors.added?(:scope, :inclusion, value: "admin")
  end

  test "the database refuses an unknown scope and a malformed digest" do
    assert_raises(ActiveRecord::StatementInvalid) { api_tokens(:agent_read).update_columns(scope: "admin") }
    assert_raises(ActiveRecord::StatementInvalid) { api_tokens(:agent_read).update_columns(token_digest: "not-a-digest") }
  end

  test "a name is unique among active tokens, and a revoked token's name is free again" do
    duplicate, _plain = ApiToken.issue(user: @owner, name: "Read-only agent")
    assert duplicate.errors.added?(:name, :taken, value: "Read-only agent")

    reused, plain_token = ApiToken.issue(user: @owner, name: "Old import script")
    assert reused.persisted?
    assert plain_token
  end

  test "the database refuses two active tokens with the same name" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      ApiToken.insert!({ user_id: @owner.id, name: "Read-only agent", token_digest: ApiToken.digest("x"), scope: "read" })
    end
  end

  test "the name has a maximum length" do
    api_token, _plain = ApiToken.issue(user: @owner, name: "a" * (ApiToken::NAME_MAX_LENGTH + 1))

    assert api_token.errors.added?(:name, :too_long, count: ApiToken::NAME_MAX_LENGTH)
  end

  test "finds the active token for a plain value" do
    assert_equal api_tokens(:agent_read), ApiToken.find_active_by_plain_token(plain_token(:agent_read))
    assert_equal api_tokens(:agent_write), ApiToken.find_active_by_plain_token(plain_token(:agent_write))
  end

  test "unknown, malformed and revoked tokens find nothing" do
    unknown = "mbt_#{'unknown'.ljust(ApiToken::RANDOM_LENGTH, '1')}"
    malformed = [ nil, "", 42, "mbt_short", plain_token(:agent_read).delete_prefix("mbt_"), "#{plain_token(:agent_read)} ",
      plain_token(:agent_read).sub("mbt_", "xyz_"), plain_token(:agent_read).sub("1", "0") ]

    assert_nil ApiToken.find_active_by_plain_token(unknown)
    malformed.each { |value| assert_nil ApiToken.find_active_by_plain_token(value), value.inspect }
    assert_nil ApiToken.find_active_by_plain_token(plain_token(:revoked))
  end

  test "revoke! stops the token, keeps the row and keeps the first revocation time" do
    api_token = api_tokens(:agent_write)
    first = Time.current.change(usec: 0)

    api_token.revoke!(at: first)
    api_token.revoke!(at: first + 1.hour)

    assert api_token.reload.revoked?
    assert_equal first, api_token.revoked_at
    assert_nil ApiToken.find_active_by_plain_token(plain_token(:agent_write))
    assert_not_includes ApiToken.active, api_token
  end

  test "record_use! writes last_used_at at most once a minute" do
    api_token = api_tokens(:agent_read)
    start = Time.current.change(usec: 0)

    api_token.record_use!(at: start)
    assert_equal start, api_token.reload.last_used_at

    assert_no_queries_match(/UPDATE/) { api_token.record_use!(at: start + 59.seconds) }
    assert_equal start, api_token.reload.last_used_at

    api_token.record_use!(at: start + 61.seconds)
    assert_equal start + 61.seconds, api_token.reload.last_used_at
  end

  test "record_use! does not touch updated_at" do
    api_token = api_tokens(:agent_read)

    assert_no_changes -> { api_token.reload.updated_at } do
      api_token.record_use!
    end
  end

  test "read tokens allow only safe methods, read_write tokens allow every method" do
    %w[GET HEAD OPTIONS get].each { |method| assert api_tokens(:agent_read).allows?(method), method }
    %w[POST PUT PATCH DELETE].each { |method| assert_not api_tokens(:agent_read).allows?(method), method }
    %w[GET POST PUT PATCH DELETE].each { |method| assert api_tokens(:agent_write).allows?(method), method }
  end

  test "the inspect output hides the digest" do
    assert_includes api_tokens(:agent_read).inspect, "token_digest: [FILTERED]"
  end
end

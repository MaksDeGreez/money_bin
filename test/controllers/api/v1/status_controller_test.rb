require "test_helper"

module Api
  module V1
    class StatusControllerTest < ActionDispatch::IntegrationTest
      test "answers with the token's name and scope" do
        get api_v1_status_path, headers: bearer(plain_token(:agent_read))

        assert_response :success
        assert_equal "application/json", response.media_type
        assert_equal({ "status" => "ok", "token" => { "name" => "Read-only agent", "scope" => "read" } }, response.parsed_body)
      end

      test "a read_write token reports its scope" do
        get api_v1_status_path, headers: bearer(plain_token(:agent_write))

        assert_equal "read_write", response.parsed_body.dig("token", "scope")
      end

      test "a token issued through the model works at once" do
        _api_token, token = ApiToken.issue(user: users(:owner), name: "Fresh agent", scope: "read")

        get api_v1_status_path, headers: bearer(token)

        assert_equal "Fresh agent", response.parsed_body.dig("token", "name")
      end

      test "without a token it answers 401" do
        get api_v1_status_path

        assert_response :unauthorized
        assert_equal 'Bearer realm="Money Bin"', response.headers["WWW-Authenticate"]
        assert_equal "unauthorized", response.parsed_body.dig("error", "code")
      end
    end
  end
end

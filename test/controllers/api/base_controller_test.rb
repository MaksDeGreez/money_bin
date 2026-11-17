require "test_helper"

# A controller that exists only in this test, to drive Api::BaseController with methods other than GET.
class ApiBaseProbeController < Api::BaseController
  def show
    render json: { user: Current.user.email_address, token: Current.api_token.name }
  end

  def create
    render json: { created: true }, status: :created
  end

  def missing
    Account.find(0)
  end

  def needs_param
    params.require(:thing)
    head :no_content
  end
end

module Api
  class BaseControllerTest < ActionDispatch::IntegrationTest
    UNAUTHORIZED = { "error" => { "code" => "unauthorized",
      "message" => "Send a personal API token in the header: Authorization: Bearer <token>." } }.freeze
    INVALID_TOKEN = { "error" => { "code" => "invalid_token", "message" => "The API token is unknown or revoked." } }.freeze

    # Test-only routes for the probe controller above, in place of the app's routes for each test.
    with_routing do |routes|
      routes.draw do
        scope "/api/probe", controller: "api_base_probe", defaults: { format: :json } do
          get "/", action: :show
          post "/", action: :create
          put "/", action: :create
          patch "/", action: :create
          delete "/", action: :create
          get "/missing", action: :missing
          get "/needs_param", action: :needs_param
        end
      end
    end

    test "a valid token authenticates and sets the current token and user" do
      get "/api/probe", headers: bearer(plain_token(:agent_read))

      assert_response :success
      assert_equal({ "user" => "owner@example.com", "token" => "Read-only agent" }, response.parsed_body)
    end

    test "the Bearer scheme name is case-insensitive" do
      get "/api/probe", headers: { "Authorization" => "bearer #{plain_token(:agent_read)}" }

      assert_response :success
    end

    test "a missing token, another scheme or an empty value is 401 unauthorized" do
      [ {}, { "Authorization" => "" }, { "Authorization" => "Bearer" }, { "Authorization" => "Bearer " },
        { "Authorization" => "Token #{plain_token(:agent_read)}" },
        { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("owner@example.com", "x") } ].each do |headers|
        get "/api/probe", headers: headers

        assert_response :unauthorized, headers.inspect
        assert_equal 'Bearer realm="Money Bin"', response.headers["WWW-Authenticate"]
        assert_equal UNAUTHORIZED, response.parsed_body
      end
    end

    test "unknown, malformed and revoked tokens all get the same 401 invalid_token" do
      unknown = "mbt_#{'unknown'.ljust(ApiToken::RANDOM_LENGTH, '1')}"
      [ unknown, "mbt_short", "not-a-token", "#{plain_token(:agent_read)}x", "#{plain_token(:agent_read)} extra", plain_token(:revoked) ].each do |value|
        get "/api/probe", headers: bearer(value)

        assert_response :unauthorized, value
        assert_equal 'Bearer realm="Money Bin", error="invalid_token"', response.headers["WWW-Authenticate"]
        assert_equal INVALID_TOKEN, response.parsed_body
      end
    end

    test "a signed-in browser session does not authenticate an API request" do
      sign_in_as users(:owner)

      get "/api/probe"

      assert_response :unauthorized
      assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    end

    test "a read token may use the safe methods" do
      get "/api/probe", headers: bearer(plain_token(:agent_read))
      assert_response :success

      head "/api/probe", headers: bearer(plain_token(:agent_read))
      assert_response :success
    end

    test "a read token is refused with 403 on every method that changes data" do
      %i[ post put patch delete ].each do |method|
        process method, "/api/probe", headers: bearer(plain_token(:agent_read))

        assert_response :forbidden, method
        assert_equal 'Bearer realm="Money Bin", error="insufficient_scope"', response.headers["WWW-Authenticate"]
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
        assert_match(/#{method.upcase} requests need a token with the read_write scope/, response.parsed_body.dig("error", "message"))
      end
    end

    test "a read_write token may use every method" do
      %i[ post put patch delete ].each do |method|
        process method, "/api/probe", headers: bearer(plain_token(:agent_write))

        assert_response :created, method
      end
    end

    test "a successful request records last_used_at at most once a minute" do
      api_token = api_tokens(:agent_read)
      start = Time.current.change(usec: 0)

      travel_to start do
        get "/api/probe", headers: bearer(plain_token(:agent_read))
      end
      assert_equal start, api_token.reload.last_used_at

      travel_to start + 30.seconds do
        assert_no_queries_match(/UPDATE "api_tokens"/) { get "/api/probe", headers: bearer(plain_token(:agent_read)) }
      end
      assert_equal start, api_token.reload.last_used_at

      travel_to start + 2.minutes do
        get "/api/probe", headers: bearer(plain_token(:agent_read))
      end
      assert_equal start + 2.minutes, api_token.reload.last_used_at
    end

    test "a missing record is a 404 in the error shape" do
      get "/api/probe/missing", headers: bearer(plain_token(:agent_read))

      assert_response :not_found
      assert_equal({ "error" => { "code" => "not_found", "message" => "Nothing was found at this address." } }, response.parsed_body)
    end

    test "a missing parameter is a 400 in the error shape" do
      get "/api/probe/needs_param", headers: bearer(plain_token(:agent_read))

      assert_response :bad_request
      assert_equal({ "error" => { "code" => "bad_request", "message" => "The parameter 'thing' is missing." } }, response.parsed_body)
    end
  end
end

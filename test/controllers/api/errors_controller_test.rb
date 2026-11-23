require "test_helper"

module Api
  # The API's fallback route: everything under /api that no endpoint takes. The token comes first, then a
  # 405 for a routed path asked with another method, else a 404; always the API's JSON error shape.
  class ErrorsControllerTest < ActionDispatch::IntegrationTest
    include ApiRequestTestHelper

    UNKNOWN = [ "/api", "/api/", "/api/v1", "/api/nope", "/api/v1/nope", "/api/v2/transactions", "/api/v1/transactions.xml",
      "/api.json", "/api/v1/transactions/1/lines" ].freeze

    test "without a valid token every unknown path and wrong method is the usual 401" do
      requests = UNKNOWN.map { |path| [ :get, path ] } +
        [ [ :post, "/api/v1/transactions" ], [ :delete, "/api/v1/receipts/1" ], [ :options, "/api/v1/status" ], [ :put, "/api" ] ]

      requests.each do |method, path|
        process method, path
        assert_error :unauthorized, "unauthorized", "#{method} #{path}"
        assert_equal 'Bearer realm="Money Bin"', response.headers["WWW-Authenticate"]

        process method, path, headers: bearer(plain_token(:revoked))
        assert_error :unauthorized, "invalid_token", "#{method} #{path}"
      end
    end

    test "with a token of either scope an unknown path is a JSON 404" do
      %i[agent_read agent_write].each do |token|
        UNKNOWN.each do |path|
          get path, headers: bearer(plain_token(token))
          assert_error :not_found, "not_found", "#{token} #{path}"
          assert_nil response.headers["Allow"]
        end

        post "/api/v1/nope", headers: bearer(plain_token(token))
        assert_error :not_found, "not_found", "#{token} POST to an unknown path"
      end
    end

    test "a routed path asked with another method is a 405 naming the methods it answers, never 403 for a read token" do
      %i[agent_read agent_write].each do |token|
        [ [ :post, "/api/v1/transactions" ], [ :put, "/api/v1/transactions/1" ], [ :patch, "/api/v1/summary" ],
          [ :delete, "/api/v1/receipts/1" ], [ :options, "/api/v1/status" ], [ :post, "/api/v1/accounts/" ] ].each do |method, path|
          process method, path, headers: bearer(plain_token(token))

          assert_error :method_not_allowed, "method_not_allowed", "#{token} #{method} #{path}"
          assert_equal "GET, HEAD", response.headers["Allow"]
          assert_includes json.dig("error", "message"), method.to_s.upcase
        end
      end
    end

    test "the token's use is recorded, as on any API path" do
      api_tokens(:agent_read).update_columns(last_used_at: nil)

      get "/api/v1/nope", headers: bearer(plain_token(:agent_read))

      assert_not_nil api_tokens(:agent_read).reload.last_used_at
    end

    test "HEAD on an unknown path is a 404 with no body" do
      head "/api/v1/nope", headers: bearer(plain_token(:agent_read))

      assert_response :not_found
      assert_empty response.body
    end

    test "the documented endpoints still answer: the fallback takes only what they do not" do
      get "/api/v1/status", headers: bearer(plain_token(:agent_read))
      assert_response :success

      head "/api/v1/transactions", headers: bearer(plain_token(:agent_read))
      assert_response :success
    end

    test "allowed_methods reads the routes: per path, or every method the API answers" do
      assert_equal %w[GET HEAD], ErrorsController.allowed_methods
      assert_equal %w[GET HEAD], ErrorsController.allowed_methods("/api/v1/transactions/12/")
      assert_equal [], ErrorsController.allowed_methods("/api/v1/nope")
      assert_equal [], ErrorsController.allowed_methods("/receipts"), "only the API's routes count"
    end

    test "the fallback is drawn after every other API route, so it shadows none" do
      api_routes = Rails.application.routes.routes.select { |route| route.defaults[:controller].to_s.start_with?("api/") }

      assert_equal "api/errors", api_routes.last.defaults[:controller]
      assert_equal 1, api_routes.count { |route| route.defaults[:controller] == "api/errors" }
    end

    private
      def assert_error(status, code, label)
        assert_response status, label
        assert_equal "application/json", response.media_type, label
        assert_equal [ "error" ], json.keys, label
        assert_equal %w[code message], json["error"].keys.sort, label
        assert_equal code, json.dig("error", "code"), label
      end
  end
end

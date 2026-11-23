require "test_helper"

# ApiRequestErrors: requests to /api and /mcp that Rails cannot decode get the agents' JSON error, not an HTML
# page. Some of these URLs cannot be sent through an integration test's request helpers (they parse the URL
# first), so the requests here are raw Rack environments: against the middleware alone, and against the
# assembled application, where the middleware has to sit in the right places.
class ApiRequestErrorsTest < ActiveSupport::TestCase
  BAD_REQUEST = [ ActionController::BadRequest.new("Invalid query parameters: invalid %-encoding (%ff)"),
    ActionDispatch::Http::Parameters::ParseError.new("unexpected token"),
    Rack::Multipart::BoundaryTooLongError.new("multipart boundary size too large") ].freeze

  # --- The middleware alone, around an app that raises.

  test "an exception that means an undecodable request is a JSON 400 on /api and /mcp" do
    BAD_REQUEST.each do |error|
      %w[/api /api/v1/transactions /mcp /mcp/nope /api.json].each do |path|
        status, headers, body = call_raising(error, path)

        assert_equal 400, status, "#{error.class} #{path}"
        assert_json_error headers, body, "bad_request"
      end
    end
  end

  test "an unknown HTTP method is a JSON 405 naming the methods the area answers, never per path" do
    status, headers, body = call_raising(ActionController::UnknownHttpMethod.new("FOO, accepted HTTP methods are ..."), "/api/v1/nope")
    assert_equal 405, status
    assert_equal "GET, HEAD", headers["allow"]
    assert_json_error headers, body, "method_not_allowed"

    status, headers, _body = call_raising(ActionController::UnknownHttpMethod.new("FOO"), "/mcp")
    assert_equal 405, status
    assert_equal "POST", headers["allow"]
  end

  test "other paths and other exceptions pass through untouched" do
    %w[/receipts /apix /mcpx / /settings/api_tokens].each do |path|
      assert_raises(ActionController::BadRequest, path) { call_raising(BAD_REQUEST.first, path) }
    end
    assert_raises(ActiveRecord::RecordNotFound) { call_raising(ActiveRecord::RecordNotFound.new, "/api/v1/transactions") }

    ok = [ 200, {}, [ "fine" ] ]
    assert_equal ok, ApiRequestErrors.new(->(_env) { ok }).call(Rack::MockRequest.env_for("/api/v1/status"))
  end

  test "a path that is not valid UTF-8 is still recognised" do
    status, = call_raising(BAD_REQUEST.first, "/api/v1/\xFF".dup.force_encoding(Encoding::UTF_8))

    assert_equal 400, status
  end

  test "only the exception's class is logged, never its message (which holds the query string)" do
    log = StringIO.new
    with_logger(ActiveSupport::Logger.new(log)) { call_raising(BAD_REQUEST.first, "/api/v1/transactions") }

    assert_includes log.string, "ActionController::BadRequest"
    assert_not_includes log.string, "%ff"
  end

  test "the application uses it after DebugExceptions and before Rack::MethodOverride" do
    stack = Rails.application.middleware.map(&:klass)

    assert_equal ApiRequestErrors, stack[stack.index(ActionDispatch::DebugExceptions) + 1]
    assert_equal ApiRequestErrors, stack[stack.index(Rack::MethodOverride) - 1]
  end

  # --- Raw requests through the whole application.

  test "an invalid percent-encoding in the path or the query is a JSON 400, without a token too" do
    [ [ "/api/v1/transactions/%FF", "" ], [ "/api/v1/transactions/%E0%A4%A", "" ], [ "/api/v1/transactions", "q=%ff" ],
      [ "/api/v1/transactions", "limit=%" ], [ "/api/v1/transactions", "a=2&a[b]=1" ], [ "/api/v1/summary", "from=%ff" ],
      [ "/api/v1/nope", "q=%ff" ], [ "/mcp", "q=%ff" ] ].each do |path, query|
      [ nil, :agent_read ].each do |token|
        status, headers, body = app_call(token && path.start_with?("/api") ? "GET" : "POST", path, query:, token:)

        assert_equal 400, status, "#{path}?#{query} token=#{token.inspect}"
        assert_json_error headers, body, "bad_request"
      end
    end
  end

  test "a malformed escape the router leaves literal is just a path: %GG" do
    status, headers, body = app_call("GET", "/api/v1/transactions/%GG")
    assert_equal 401, status
    assert_json_error headers, body, "unauthorized"

    status, headers, body = app_call("GET", "/api/v1/transactions/%GG", token: :agent_read)
    assert_equal 404, status
    assert_json_error headers, body, "not_found"

    status, headers, body = app_call("GET", "/api/v1/%GG", token: :agent_read)
    assert_equal 404, status
    assert_json_error headers, body, "not_found"
  end

  test "an unknown HTTP method is a JSON 405 through the application" do
    status, headers, body = app_call("FOO", "/api/v1/transactions")
    assert_equal 405, status
    assert_equal "GET, HEAD", headers["allow"]
    assert_json_error headers, body, "method_not_allowed"

    status, headers, body = app_call("FOO", "/mcp")
    assert_equal 405, status
    assert_equal "POST", headers["allow"]
    assert_json_error headers, body, "method_not_allowed"
  end

  test "a form body Rack::MethodOverride cannot read is a JSON 400 on /api and /mcp" do
    boundary = "x" * 100
    multipart = "--#{boundary}\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--#{boundary}--\r\n"

    %w[/api/v1/transactions /mcp].each do |path|
      status, headers, body = app_call("POST", path, body: multipart, content_type: "multipart/form-data; boundary=#{boundary}")

      assert_equal 400, status, path
      assert_json_error headers, body, "bad_request"
    end
  end

  test "a form body MethodOverride reads past is answered by the inner one" do
    %w[a=%ff a=1&a[b]=2 a=%].each do |form|
      status, headers, body = app_call("POST", "/mcp", body: form, content_type: "application/x-www-form-urlencoded", token: :agent_read)

      assert_equal 400, status, form
      assert_json_error headers, body, "bad_request"
    end
  end

  test "a GET whose JSON body does not parse is refused like any request body: 422 invalid_parameter" do
    status, headers, body = app_call("GET", "/api/v1/transactions", body: "{bad", content_type: "application/json", token: :agent_read)

    assert_equal 422, status
    assert_json_error headers, body, "invalid_parameter"
    assert_includes JSON.parse(body.join)["error"]["message"], "'body'"

    status, headers, body = app_call("GET", "/api/v1/transactions", body: "{bad", content_type: "application/json")
    assert_equal 401, status
    assert_json_error headers, body, "unauthorized"
  end

  test "the browser pages keep Rails' own answer" do
    status, headers, _body = app_call("GET", "/receipts", query: "q=%ff")

    assert_equal 400, status
    assert_equal "text/html", headers["content-type"].split(";").first
  end

  private
    def call_raising(error, path)
      ApiRequestErrors.new(->(_env) { raise error }).call(Rack::MockRequest.env_for("/").merge(Rack::PATH_INFO => path))
    end

    # A request built by hand, so the path and query reach the app exactly as written.
    def app_call(method, path, query: "", token: nil, body: "", content_type: nil)
      env = Rack::MockRequest.env_for("/", method: "GET", input: body)
      env.merge!(Rack::REQUEST_METHOD => method, Rack::PATH_INFO => path, Rack::QUERY_STRING => query,
        "REQUEST_URI" => query.empty? ? path : "#{path}?#{query}", "HTTP_HOST" => McpTestHelper::HOST)
      env["CONTENT_TYPE"] = content_type if content_type
      env["HTTP_AUTHORIZATION"] = "Bearer #{plain_token(token)}" if token
      status, headers, response_body = Rails.application.call(env)
      text = +""
      response_body.each { |chunk| text << chunk }
      response_body.close if response_body.respond_to?(:close)
      [ status, headers, [ text ] ]
    end

    def assert_json_error(headers, body, code)
      assert_equal "application/json; charset=utf-8", headers["content-type"]
      parsed = JSON.parse(body.join)
      assert_equal [ "error" ], parsed.keys
      assert_equal %w[code message], parsed["error"].keys.sort
      assert_equal code, parsed["error"]["code"]
    end

    def with_logger(logger)
      original = Rails.logger
      Rails.logger = logger
      yield
    ensure
      Rails.logger = original
    end
end

require "test_helper"

# The MCP server at /mcp as a client sees it: the protocol, the tool list, authentication, the Host and
# Origin rule, the HTTP methods, and the contract every tool must keep. The tools' own behaviour is in
# test/integration/mcp_tools_test.rb.
class McpServerTest < ActionDispatch::IntegrationTest
  include ApiRequestTestHelper
  include McpTestHelper

  # Every tool needs, here: a call that succeeds, a call with a bad argument (and the argument its error
  # must name), and the REST request whose JSON its structured content must equal. A tool added to
  # McpTools.all without an entry fails "every tool has its examples".
  TOOL_EXAMPLES = {
    "spending_summary" => {
      happy: -> { { from: "2026-10-01", to: "2026-10-31" } },
      error: -> { [ { from: "2026-10-31", to: "2026-10-01" }, "'to'" ] },
      rest: -> { [ "/api/v1/summary", { from: "2026-10-01", to: "2026-10-31", currency: "UAH" }, { from: "2026-10-01", to: "2026-10-31", currency: "UAH" } ] }
    },
    "search_transactions" => {
      happy: -> { { limit: 3 } },
      error: -> { [ { account_id: 999_999_999 }, "'account_id'" ] },
      rest: -> {
        [ "/api/v1/transactions", { from: "2026-10-01", to: "2026-10-31", category_id: categories(:eating_out).id, limit: 1 },
          { from: "2026-10-01", to: "2026-10-31", category: "eating-out", limit: 1 } ]
      }
    },
    "list_categories" => {
      happy: -> { {} },
      error: -> { [ { group: "groceries" }, "`/group`" ] },
      rest: -> { [ "/api/v1/categories", {}, {} ] }
    },
    "list_accounts" => {
      happy: -> { {} },
      error: -> { [ { currency: "UAH" }, "`/currency`" ] },
      rest: -> { [ "/api/v1/accounts", {}, {} ] }
    },
    "recent_receipts" => {
      happy: -> { { limit: 2 } },
      error: -> { [ { cursor: "bm90LWEtY3Vyc29y" }, "'cursor'" ] },
      rest: -> { [ "/api/v1/receipts", { limit: 2, status: "extracted" }, { limit: 2, status: "extracted" } ] }
    },
    "get_receipt" => {
      happy: -> { { id: receipts(:market_receipt).id } },
      error: -> { [ { id: "first" }, "`/id`" ] },
      rest: -> { [ "/api/v1/receipts/#{receipts(:market_receipt).id}", {}, { id: receipts(:market_receipt).id } ] }
    }
  }.freeze

  setup { host! McpTestHelper::HOST }

  test "initialize: the server, its instructions, the tools capability, and no session" do
    body = mcp_initialize

    assert_response :success
    result = body.fetch("result")
    assert_equal McpTestHelper::PROTOCOL_VERSION, result["protocolVersion"]
    assert_equal({ "name" => "money-bin", "title" => "Money Bin", "version" => McpServer::VERSION }, result["serverInfo"])
    assert_includes result["instructions"], "Never add or compare amounts in different currencies"
    assert_equal({ "tools" => {} }, result["capabilities"], "only tools: no prompts, resources or logging")
    assert_nil response.headers["Mcp-Session-Id"], "stateless: no session is issued"
    assert_equal "application/json", response.media_type
  end

  test "every request stands alone: a tool can be called without initialize, and nothing is kept" do
    result = mcp_call_tool("list_accounts")
    assert_not result["isError"]

    mcp_request("notifications/initialized", nil, id: nil)
    assert_response :accepted
    assert_nil response.headers["Mcp-Session-Id"]
  end

  test "tools/list: every tool has a title, a description, schemas and the read-only annotations" do
    tools = mcp_request("tools/list").dig("result", "tools")

    assert_equal McpTools.all.map(&:tool_name), tools.map { |tool| tool["name"] }
    tools.each do |tool|
      name = tool["name"]
      assert tool["title"].present?, name
      assert_operator tool["description"].length, :>=, 200, "#{name}: say what the tool is for, its units and rules"
      assert_equal({ "readOnlyHint" => true, "destructiveHint" => false, "idempotentHint" => true, "openWorldHint" => false },
        tool["annotations"].except("title"), name)

      input = tool.fetch("inputSchema")
      assert_equal "object", input["type"], name
      assert_equal false, input["additionalProperties"], "#{name}: an unknown argument must be refused, not ignored"
      input["properties"].each do |argument, schema|
        assert schema["description"].present?, "#{name}.#{argument} has no description"
      end

      output = tool.fetch("outputSchema")
      assert_equal "object", output["type"], name
      assert_equal false, output["additionalProperties"], name
    end
  end

  test "every tool has its examples here, and no example is stale" do
    assert_equal McpTools.all.map(&:tool_name).sort, TOOL_EXAMPLES.keys.sort
  end

  TOOL_EXAMPLES.each do |name, example|
    test "#{name}: a call succeeds with text and structured content that matches its outputSchema" do
      result = mcp_call_tool(name, instance_exec(&example[:happy]))

      assert_not result["isError"], result.inspect
      assert_equal "text", result.dig("content", 0, "type")
      assert result.dig("content", 0, "text").present?
      assert_conforms_to_output_schema(name, result.fetch("structuredContent"))
      assert_no_floats(result["structuredContent"])
    end

    test "#{name}: a bad argument is a tool error that names it" do
      arguments, named = instance_exec(&example[:error])

      assert_tool_error(mcp_call_tool(name, arguments), named)
    end

    test "#{name}: its numbers are the REST endpoint's for the same parameters" do
      path, params, arguments = instance_exec(&example[:rest])

      structured = mcp_structured(name, arguments)
      api_get path, params: params
      assert_response :success

      assert_equal json, JSON.parse(structured.to_json)
    end
  end

  test "an unknown tool is a JSON-RPC error" do
    body = mcp_request("tools/call", { name: "delete_everything", arguments: {} })

    assert_equal(-32602, body.dig("error", "code"))
    assert_includes body.dig("error", "data"), "Tool not found: delete_everything"
  end

  test "a failure inside a tool is an internal error with no message, trace or data from the app" do
    failing = ->(*) { raise ActiveRecord::StatementInvalid, "PG::Error: secret detail from accounts" }

    with_singleton_method(AccountBalancesQuery, :new, failing) do
      body = mcp_request("tools/call", { name: "list_accounts", arguments: {} })

      assert_response :success
      assert_equal({ "code" => -32603, "message" => "Internal error", "data" => "Internal error calling tool list_accounts" }, body["error"])
      assert_not_includes response.body, "secret detail"
      assert_not_includes response.body, "backtrace"
    end
  end

  # Authentication

  test "no token is a 401 with a Bearer challenge that reveals nothing about the tools" do
    [ {}, { "Authorization" => "Bearer" }, { "Authorization" => "Token #{plain_token(:agent_read)}" } ].each do |headers|
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: McpTestHelper::HEADERS.merge(headers)

      assert_response :unauthorized, headers.inspect
      assert_equal 'Bearer realm="Money Bin"', response.headers["WWW-Authenticate"]
      assert_equal "unauthorized", json.dig("error", "code")
      assert_not_includes response.body, "list_accounts"
    end
  end

  test "an unknown, malformed or revoked token is a 401 invalid_token" do
    [ plain_token(:revoked), "mbt_#{'unknown'.ljust(ApiToken::RANDOM_LENGTH, '1')}", "not-a-token" ].each do |value|
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
        headers: McpTestHelper::HEADERS.merge(bearer(value))

      assert_response :unauthorized, value
      assert_equal 'Bearer realm="Money Bin", error="invalid_token"', response.headers["WWW-Authenticate"]
      assert_equal "invalid_token", json.dig("error", "code")
    end
  end

  test "a signed-in browser session without a token gets nothing" do
    sign_in_as users(:owner)

    mcp_request("tools/list", token: nil)

    assert_response :unauthorized
    assert_equal "unauthorized", json.dig("error", "code")
  end

  test "a token of either scope calls the tools, and its use is recorded" do
    %i[agent_read agent_write].each do |token|
      travel_to 5.minutes.from_now do
        assert_not mcp_call_tool("list_accounts", {}, token:)["isError"]
        assert_in_delta Time.current, api_tokens(token).reload.last_used_at, 1.second
      end
    end
  end

  test "a tool refuses to run without the authenticated token in its server context" do
    assert_raises(McpTools::Base::Unauthenticated) { McpTools::ListAccounts.call(server_context: {}) }
    assert_raises(McpTools::Base::Unauthenticated) { McpTools::ListAccounts.call(server_context: { api_token: plain_token(:agent_read) }) }
  end

  test "a failure before the SDK is a 500 with no detail" do
    with_singleton_method(ApiToken, :find_active_by_plain_token, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "secret detail" }) do
      mcp_request("tools/list")
    end

    assert_response :internal_server_error
    assert_equal "internal_error", json.dig("error", "code")
    assert_not_includes response.body, "secret detail"
  end

  test "an unauthenticated request never reaches the server, not even initialize" do
    with_singleton_method(McpServer, :build, ->(**) { flunk "the server was built for an unauthenticated request" }) do
      mcp_initialize(token: nil)
      assert_response :unauthorized
    end
  end

  # Host and Origin

  test "the server answers on the loopback names, with or without the port" do
    [ "localhost:3100", "LOCALHOST:3100", "127.0.0.1:3100", "[::1]:3100", "localhost" ].each do |name|
      assert_not mcp_call_tool("list_accounts", {}, headers: { "Host" => name })["isError"], name
    end
  end

  test "another Host is refused before authentication, so a rebound domain reaches nothing" do
    [ "evil.example:3100", "localhost.evil.example", "127.0.0.1.nip.io:3100", "www.example.com", "localhost.", "0.0.0.0:3100",
      "localhost:3100:evil.example", "127.0.0.1:3100, evil.example", "[::1]junk", "localhost:", "user@localhost", "" ].each do |name|
      with_singleton_method(ApiToken, :find_active_by_plain_token, ->(*) { flunk "the token was checked for #{name}" }) do
        mcp_request("tools/list", headers: { "Host" => name })
      end

      assert_response :forbidden, name
      assert_equal "forbidden_host", json.dig("error", "code")
    end
  end

  test "APP_HOST is allowed when the owner sets it" do
    host! "money.home.arpa:3100"
    mcp_request("tools/list")
    assert_response :forbidden

    with_app_host("money.home.arpa") do
      mcp_request("tools/list")
      assert_response :success
    end

    with_app_host("money.home.arpa:8443") do
      mcp_request("tools/list")
      assert_response :forbidden, "an APP_HOST with a port matches only that port"

      mcp_request("tools/list", headers: { "Host" => "money.home.arpa:8443" })
      assert_response :success
    end
  end

  test "a request from another web page (a foreign or opaque Origin) is refused, with or without a token" do
    [ "http://evil.example", "http://localhost:6274", "http://127.0.0.1:3100", "null", "http://localhost:3100/path",
      "http://user@localhost:3100", "file://", "not a url" ].each do |origin|
      [ :agent_read, nil ].each do |token|
        mcp_request("tools/list", token:, headers: { "Origin" => origin })

        assert_response :forbidden, "#{origin} #{token}"
        assert_equal "forbidden_origin", json.dig("error", "code")
      end
    end
  end

  test "a request from the app's own origin is answered" do
    # The scheme is not compared, as in the SDK: only one server can listen on localhost:3100.
    [ "http://localhost:3100", "HTTP://LOCALHOST:3100", "https://localhost:3100" ].each do |origin|
      mcp_request("tools/list", headers: { "Origin" => origin })

      assert_response :success, origin
    end
  end

  # HTTP methods and the transport

  test "only POST is answered: GET and DELETE are a 405 in stateless mode, after authentication" do
    %i[get delete put patch options].each do |method|
      process method, "/mcp", headers: mcp_headers(:agent_read)

      assert_response :method_not_allowed, method
      assert_equal "POST", response.headers["Allow"]
    end

    get "/mcp", headers: mcp_headers(nil)
    assert_response :unauthorized
  end

  test "the transport's own checks answer in JSON-RPC's error shape" do
    post "/mcp", params: "{not json", headers: mcp_headers(:agent_read)
    assert_response :bad_request
    assert_equal(-32700, json.dig("error", "code"))

    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: mcp_headers(:agent_read).merge("Accept" => "text/html")
    assert_response :not_acceptable

    post "/mcp", params: "jsonrpc=2.0", headers: mcp_headers(:agent_read).merge("Content-Type" => "application/x-www-form-urlencoded")
    assert_response :unsupported_media_type
  end

  test "the stateless lifecycle of protocol 2026-07-28 (no initialize, the version on every request) works behind the same gates" do
    params = { name: "list_accounts", arguments: {},
      _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28", "io.modelcontextprotocol/clientCapabilities" => {} } }
    headers = { "MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/call", "Mcp-Name" => "list_accounts" }

    body = mcp_request("tools/call", params, headers:)
    assert_response :success
    assert_equal accounts(:card_uah).id, body.dig("result", "structuredContent", "accounts").find { |account| account["name"] == "Everyday card" }["id"]

    mcp_request("tools/call", params, token: nil, headers:)
    assert_response :unauthorized
  end

  test "a format suffix or any other path under /mcp is a JSON 404, behind the same gates" do
    message = { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json
    %w[/mcp.json /mcp/nope /mcp/tools/list].each do |path|
      post path, params: message, headers: mcp_headers(:agent_read)
      assert_response :not_found, path
      assert_equal({ "code" => "not_found", "message" => "The MCP server answers at /mcp only." }, json["error"])

      post path, params: message, headers: mcp_headers(nil)
      assert_response :unauthorized, path

      post path, params: message, headers: mcp_headers(:agent_read).merge("Host" => "evil.example:3100")
      assert_response :forbidden, path
      assert_equal "forbidden_host", json.dig("error", "code")
    end

    get "/mcp/nope", headers: mcp_headers(:agent_read)
    assert_response :not_found
  end

  test "a query string Rails cannot decode is a JSON 400, before any gate" do
    post "/mcp?q=%ff", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: mcp_headers(nil)

    assert_response :bad_request
    assert_equal "application/json", response.media_type
    assert_equal "bad_request", json.dig("error", "code")
  end

  private
    def with_app_host(value)
      original = ENV["APP_HOST"]
      ENV["APP_HOST"] = value
      yield
    ensure
      ENV["APP_HOST"] = original
    end
end

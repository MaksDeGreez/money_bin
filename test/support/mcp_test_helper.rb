require "json_schemer"

# Speaking JSON-RPC to the MCP server mounted at /mcp, in an ActionDispatch::IntegrationTest, the way an
# MCP client does: POST, JSON in, JSON out, the API token in the Authorization header.
#
#   host! McpTestHelper::HOST
#   mcp_request("tools/list")                          # the whole JSON-RPC response
#   result = mcp_call_tool("list_accounts")            # the result of tools/call
module McpTestHelper
  # Where Claude Desktop's bridge reaches the server: the development port on localhost.
  HOST = "localhost:3100".freeze
  PROTOCOL_VERSION = "2025-11-25".freeze

  HEADERS = {
    "Content-Type" => "application/json",
    "Accept" => "application/json, text/event-stream",
    "MCP-Protocol-Version" => PROTOCOL_VERSION
  }.freeze

  # POSTs one JSON-RPC request (a notification when `id` is nil) and returns the parsed response.
  def mcp_request(method, params = nil, token: :agent_read, headers: {}, id: 1)
    message = { jsonrpc: "2.0", method: }
    message[:id] = id unless id.nil?
    message[:params] = params unless params.nil?
    post "/mcp", params: message.to_json, headers: mcp_headers(token).merge(headers)
    response.body.empty? ? nil : response.parsed_body
  end

  def mcp_headers(token)
    token ? HEADERS.merge(bearer(plain_token(token))) : HEADERS
  end

  def mcp_initialize(**)
    mcp_request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {},
      clientInfo: { name: "money-bin-test", version: "1.0" } }, **)
  end

  # The `result` of a tools/call. Fails on a JSON-RPC error.
  def mcp_call_tool(name, arguments = {}, **)
    body = mcp_request("tools/call", { name:, arguments: }, **)
    assert_response :success
    assert_nil body["error"], "tools/call #{name} answered a JSON-RPC error: #{body['error'].inspect}"
    body.fetch("result")
  end

  # The structured content of a successful call, checked against the tool's outputSchema (from tools/list,
  # as a client sees it) and for floats.
  def mcp_structured(name, arguments = {}, **)
    result = mcp_call_tool(name, arguments, **)
    assert_not result["isError"], "#{name} failed: #{result.dig('content', 0, 'text')}"
    structured = result.fetch("structuredContent")
    assert_conforms_to_output_schema(name, structured)
    assert_no_floats(structured)
    structured
  end

  def mcp_tools
    @mcp_tools ||= mcp_request("tools/list").dig("result", "tools").index_by { |tool| tool["name"] }
  end

  def assert_conforms_to_output_schema(name, structured)
    schema = mcp_tools.fetch(name).fetch("outputSchema")
    errors = JSONSchemer.schema(schema).validate(structured).map { |error| error["error"] }
    assert_empty errors, "#{name}: the structured content does not match its outputSchema"
  end

  # A tool error (isError: true) whose text names the argument.
  def assert_tool_error(result, argument)
    assert result["isError"], "expected a tool error, got #{result.inspect}"
    assert_nil result["structuredContent"]
    assert_includes result.dig("content", 0, "text"), argument
  end
end

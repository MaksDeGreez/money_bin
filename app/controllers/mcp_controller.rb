# /mcp: the Model Context Protocol server for AI assistants (McpServer, docs/decisions/0008-mcp-server.md).
#
# Every request passes three gates, in this order, before the SDK's transport sees it:
#
# 1. Host and Origin (against DNS rebinding and cross-site requests). The Host header must name this
#    machine (McpServer.allowed_hosts: localhost, 127.0.0.1, ::1, and APP_HOST when set), so a web page
#    cannot reach the server through a domain of its own that resolves to 127.0.0.1; a Host header that is
#    not a plain name or [IPv6] with an optional port is refused too. A request with an
#    Origin header (one sent by a browser) must come from this app's own origin; MCP clients such as
#    Claude Desktop's bridge, the inspector's CLI or curl send none. Anything else is a 403 that says
#    nothing about the tools.
# 2. A personal API token (ApiTokenAuthentication, the REST API's rules): no token, or an unknown,
#    malformed or revoked one, is a 401 with `WWW-Authenticate: Bearer`. A browser session cookie is never
#    read: this is an ActionController::API. A token of either scope may call every tool, since every tool
#    only reads.
# 3. The method: POST carries JSON-RPC messages. In stateless mode there is no event stream to open (GET)
#    and no session to end (DELETE), so every other method is a 405 with `Allow: POST`.
#
# Any other path under /mcp (`/mcp/tools`, `/mcp.json`) passes the same two gates and is then a JSON 404
# (`not_found`). A request Rails cannot decode (`/mcp?q=%ff`) or a method nobody knows never reaches this
# controller: ApiRequestErrors answers it, with the same error shape.
#
# The transport then answers with one JSON object per POST, and protocol errors (a wrong Accept or
# Content-Type, malformed JSON, an unknown method) in JSON-RPC's own error shape. A failure anywhere else
# (the database down while the token is checked, say) is a 500 with no detail, in every environment: the
# exception goes to the Rails log, never to the client, not even as development's debug page.
class McpController < ActionController::API
  include ApiTokenAuthentication

  # A Host header value: a name or an IPv4 address, or an IPv6 address in brackets, and an optional port.
  HOST_FORMAT = /\A(?:\[(?<ipv6>[0-9a-f:.]+)\]|(?<name>[a-z0-9.-]+))(?::[0-9]{1,5})?\z/

  # The one method the server answers (ApiRequestErrors names it too, for a method nobody knows).
  ALLOWED_METHODS = %w[POST].freeze

  wrap_parameters false

  before_action :check_host_and_origin
  before_action :authenticate_api_token

  rescue_from StandardError do |error|
    MCP.configuration.exception_reporter.call(error, {})
    render_api_error :internal_server_error, "internal_error", "The MCP server could not answer; the details are in the app's log."
  end

  def handle
    unless request.post?
      response.headers["Allow"] = ALLOWED_METHODS.join(", ")
      return render_api_error :method_not_allowed, "method_not_allowed",
        "The MCP server is stateless: send JSON-RPC messages with POST. There is no event stream (GET) and no session to end (DELETE)."
    end

    transport = McpServer.transport(McpServer.build(api_token: Current.api_token))
    status, headers, body = transport.handle_request(request)
    self.status = status
    headers.each { |name, value| response.headers[name] = value }
    self.response_body = body
  ensure
    transport&.close
  end

  # Any other path under /mcp, after the same gates.
  def not_found
    render_api_error :not_found, "not_found", "The MCP server answers at /mcp only."
  end

  private
    def check_host_and_origin
      host = request.get_header("HTTP_HOST").to_s.downcase
      origin = request.get_header("HTTP_ORIGIN")

      if !allowed_host?(host)
        render_api_error :forbidden, "forbidden_host", "The MCP server answers only to requests for this machine (localhost)."
      elsif origin && !same_origin?(origin, host)
        render_api_error :forbidden, "forbidden_origin", "The MCP server does not answer requests sent by other web pages."
      end
    end

    # Whether the (down-cased) Host header names an allowed host, with any port ("localhost:3100", "[::1]")
    # or with the exact port of an allowed "host:port" entry.
    def allowed_host?(host)
      match = HOST_FORMAT.match(host)
      return false if match.nil?

      allowed = McpServer.allowed_hosts
      allowed.include?(match[:ipv6] || match[:name]) || allowed.include?(host)
    end

    # Whether the Origin (scheme://host[:port]) names the same host and port as the Host header. A default
    # port may be written or left out on either side.
    def same_origin?(origin, host)
      uri = URI.parse(origin)
      return false unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? && uri.path.empty?

      default_port = ":#{uri.default_port}"
      "#{uri.host}:#{uri.port}".downcase.delete_suffix(default_port) == host.delete_suffix(default_port)
    rescue URI::InvalidURIError
      false
    end
end

# /mcp: the Model Context Protocol server for AI assistants (McpServer, docs/decisions/0008-mcp-server.md).
#
# Every request passes three gates, in this order, before the SDK's transport sees it:
#
# 1. Host and Origin (against DNS rebinding and cross-site requests). The Host header must name this
#    machine (McpServer.allowed_hosts: localhost, 127.0.0.1, ::1, and APP_HOST when set), so a web page
#    cannot reach the server through a domain of its own that resolves to 127.0.0.1. A request with an
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
# The transport then answers with one JSON object per POST, and protocol errors (a wrong Accept or
# Content-Type, malformed JSON, an unknown method) in JSON-RPC's own error shape.
class McpController < ActionController::API
  include ApiTokenAuthentication

  wrap_parameters false

  before_action :check_host_and_origin
  before_action :authenticate_api_token

  def handle
    unless request.post?
      response.headers["Allow"] = "POST"
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

  private
    def check_host_and_origin
      host = request.get_header("HTTP_HOST").to_s.downcase
      origin = request.get_header("HTTP_ORIGIN")

      if !McpServer.allowed_hosts.include?(hostname(host))
        render_api_error :forbidden, "forbidden_host", "The MCP server answers only to requests for this machine (localhost)."
      elsif origin && !same_origin?(origin, host)
        render_api_error :forbidden, "forbidden_origin", "The MCP server does not answer requests sent by other web pages."
      end
    end

    # "localhost" from "localhost:3100", "::1" from "[::1]:3100".
    def hostname(host)
      host.start_with?("[") ? host[/\A\[([^\]]*)\]/, 1].to_s : host.split(":").first.to_s
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

# The Model Context Protocol server: an MCP::Server (the official Ruby SDK) with the read-only tools of
# McpTools, behind a Streamable HTTP transport in stateless mode. McpController builds one per request,
# after it has checked the Host and Origin headers and authenticated the API token
# (docs/decisions/0008-mcp-server.md).
module McpServer
  NAME = "money-bin".freeze
  TITLE = "Money Bin".freeze
  VERSION = "1.0.0".freeze

  # What the client passes to the model before any tool is called.
  INSTRUCTIONS = <<~TEXT.squish.freeze
    Money Bin is the owner's personal finance ledger, read-only through these tools. Every transaction
    belongs to one account and is in that account's currency; amounts are decimal strings with the currency
    next to them, and expenses are negative ("-85.00" means 85.00 spent). Never add or compare amounts in
    different currencies: there are no exchange rates. Drafts are proposals, not money spent: balances and
    spending_summary leave them out. Transfers between the owner's own accounts are neither spending nor
    income. A transaction can be split into several categories; categories sit in groups (slugs like
    "groceries" for a group and "groceries/groceries" for one of its categories, see list_categories).
    Dates are YYYY-MM-DD in Kyiv time. For totals use spending_summary rather than adding up
    search_transactions pages. Receipts (recent_receipts, get_receipt) are shop receipts read by OCR, with
    positive item amounts as printed.
  TEXT

  module_function

  # Only tools are offered: no prompts, no resources, no log messages. The tool list is fixed, so no
  # list-changed notification is promised (a stateless server could not send one anyway).
  CAPABILITIES = { tools: {} }.freeze

  # A server for one request, with the authenticated token in its context for the tools (McpTools::Base
  # refuses to run without it).
  def build(api_token:)
    MCP::Server.new(
      name: NAME, title: TITLE, version: VERSION, instructions: INSTRUCTIONS,
      tools: McpTools.all,
      capabilities: CAPABILITIES.deep_dup,
      server_context: { api_token: }
    )
  end

  # The transport for that server:
  # - stateless: no session is kept between requests and none is issued (no Mcp-Session-Id). Every POST
  #   stands alone and is authenticated on its own, so there is no session to steal, expire or bind to a
  #   token, and Puma's threads and processes need nothing shared;
  # - JSON responses: each POST is answered with one JSON object, not an event stream (the tools answer at
  #   once and send no progress), which a buffered Rails response can carry. `subscriptions/listen` (a
  #   long-lived stream) is therefore not served;
  # - the SDK's own Host and Origin check stays on, behind McpController's (which runs before
  #   authentication), with the same hosts.
  def transport(server)
    MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      enable_json_response: true,
      serve_subscriptions_listen: false,
      dns_rebinding_protection: true,
      allowed_hosts: allowed_hosts
    )
  end

  # The names the MCP endpoint answers to: the loopback names (with any port), plus APP_HOST when the owner
  # serves the app under another name (as config.hosts allows in production), in every environment. An
  # APP_HOST written with a port ("money.home.arpa:8443") matches only that port.
  def allowed_hosts
    [ "localhost", "127.0.0.1", "::1", ENV["APP_HOST"].presence&.downcase ].compact
  end
end

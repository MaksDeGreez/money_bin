# 0008. The MCP server: inside Rails, stateless, read-only tools over the query objects

Status: accepted, after the read API (0007).

## Context

The owner wants to ask an AI assistant about their money in plain words ("how much did I spend on
groceries last month compared with the same month a year ago?", "what did I buy on my last receipt?").
The Model Context Protocol (MCP) is how assistants such as Claude Desktop discover and call tools on a
server. The read API (0007) already answers these questions for scripts; its reading logic lives in query
objects so that an MCP server could reuse it. The app runs on the owner's machine and is never exposed
to the internet; Claude Desktop reaches it through `mcp-remote`, a local bridge that turns Claude
Desktop's stdio connection into Streamable HTTP requests to `http://localhost:3100/mcp`.

## Decision

### Inside the Rails app, with the official Ruby SDK

The server is the `mcp` gem (the official Ruby SDK, 1.10), mounted at `/mcp` in the Rails app
(`McpController`, `McpServer`, the tools in `app/mcp/mcp_tools/`).

- The tools call the same query objects (`app/queries/`) and the same JSON builders (`app/serializers/`)
  as the REST endpoints, in the same process, against the same database. The two interfaces cannot
  disagree about a number, and a test per tool checks that they do not.
- Authentication is the REST API's own code (`ApiTokenAuthentication`, shared by `Api::BaseController`
  and `McpController`), not a second implementation.
- One process to run and to secure. A separate MCP process would need its own access to the database or
  would have to call the REST API over HTTP, with a token of its own and every number serialised twice.

### Streamable HTTP, stateless, one JSON answer per request

The transport is the SDK's `StreamableHTTPTransport` with `stateless: true` and
`enable_json_response: true`; McpController builds a server and a transport for each request.

- **Stateless**: no `Mcp-Session-Id` is issued and nothing is kept between requests. Every POST stands
  alone and is authenticated on its own. There is no session to steal, expire or bind to a token, no
  memory that grows with clients, and nothing for Puma's threads and processes to share. The tools need
  no session: each call carries all its arguments. `initialize` still works (clients send it first), and
  a client that skips it can call a tool directly.
- **JSON answers**: each POST gets one JSON object, not an event stream. The tools answer at once and
  send no progress notifications, and a buffered Rails response carries JSON simply. For the same reason
  the protocol's long-lived `subscriptions/listen` stream is not served.
- **HTTP methods**: POST carries JSON-RPC. There is no server-to-client stream to open (GET) and no
  session to end (DELETE), so every other method is a 405 with `Allow: POST`, as the specification allows.
  Any other path under `/mcp` passes the same gates and is then a JSON 404, and a request Rails cannot
  decode is a JSON 400 before them (0007, "Errors outside the endpoints").
- **Capabilities**: tools only. No prompts, resources or logging are advertised, and no list-changed
  notification is promised (the tool list is fixed, and a stateless server could not send one).

### Authentication: the personal API tokens

`Authorization: Bearer <token>` with a personal API token (0002), exactly as the REST API checks it:
unknown, malformed and revoked tokens get one 401 `invalid_token` answer, a missing token a 401
`unauthorized`, both with `WWW-Authenticate: Bearer realm="Money Bin"`; `last_used_at` is written at most
once a minute. `McpController` is an `ActionController::API`, which reads no cookie, so a signed-in browser
session never authenticates. The token reaches the tools in the SDK's `server_context`, and the tool base
class refuses to run without one, so a tool cannot answer a request that skipped authentication.

The REST API's scope rule is per HTTP method (a `read` token may only GET). MCP sends every call as a
POST, so the rule here is per tool: a tool that changes data would need `read_write`. Every tool today only
reads, so a token of either scope may call all of them.

The SDK's own bearer support (`token_verifier:`) is built for OAuth 2.1 access tokens and protected
resource metadata. It was not used: the app has one user and personal tokens, and sharing the REST API's
check keeps one set of rules and one error shape.

### Host and Origin: against DNS rebinding and cross-site requests

The MCP specification asks a local server to validate the `Origin` header, because a web page in the
owner's browser can send requests to `localhost`, and a domain of the attacker's that resolves to
127.0.0.1 (DNS rebinding) makes those requests look same-origin to the browser. McpController checks, before
it authenticates anything:

- the **Host** header must name this machine: `localhost`, `127.0.0.1` or `::1` (any port), or `APP_HOST`
  when the owner sets it (as `config.hosts` allows in production; for `/mcp` in every environment, and with
  a port only that port). A rebound domain carries its own name in Host and is refused, and so is a value
  that is not a plain name or a bracketed IPv6 address with an optional port. In development Rails would
  let any IP address through `config.hosts`; the MCP endpoint is stricter;
- a request with an **Origin** header (one a browser sent) must come from the app's own origin (same host
  and port as the Host header; the scheme is not compared, since only one server listens on a port). MCP
  clients such as `mcp-remote`, the inspector's command line and curl send no Origin and are not affected.
  `null`, file and foreign origins are refused.

Both refusals are a 403 (`forbidden_host`, `forbidden_origin`) that names no tool. The SDK's own
rebinding check stays on behind this one, with the same host list. A cross-site request could not get far
anyway: it does not know the token, a browser will not add an `Authorization` header to a cross-origin
request without a CORS preflight that the server never approves, and the transport accepts only
`Content-Type: application/json`. The Host and Origin rule closes the remaining door and keeps the
specification's MUST.

### Tools over query objects

| Tool | Query object | REST twin |
| ---- | ------------ | --------- |
| `spending_summary` | `SpendingSummaryQuery` | `GET /api/v1/summary` |
| `search_transactions` | `TransactionsQuery` | `GET /api/v1/transactions` |
| `list_categories` | `CategoryTreeQuery` | `GET /api/v1/categories` |
| `list_accounts` | `AccountBalancesQuery` | `GET /api/v1/accounts` |
| `recent_receipts` | `ReceiptsQuery#page` | `GET /api/v1/receipts` |
| `get_receipt` | `ReceiptsQuery.find` | `GET /api/v1/receipts/{id}` |

- **Arguments** are checked twice. The SDK validates them against each tool's input schema (JSON Schema
  2020-12, `additionalProperties: false`, enums, patterns, ranges), so an unknown or mistyped argument is
  refused before the tool runs. Then the values go through `QueryArguments`, the checks the REST API's
  query parameters use too: a real date, `to` not before `from`, an id or a category slug that exists, a
  currency some account uses, a cursor this server made. `search_transactions` takes a category or a whole
  group by slug or by id (a model knows slugs from `list_categories`; the REST API takes ids only).
- **Errors**: a bad argument or an unknown id is a tool result with `isError: true` and a message that names
  the argument and what is allowed, so the model can correct its call. A failure inside a tool is the
  SDK's JSON-RPC internal error, whose message names only the tool; the exception goes to the Rails log
  (`config/initializers/mcp.rb`), never to the client. A failure before the SDK (the database down while
  the token is checked) is a 500 `internal_error` with no detail from McpController, in development too,
  where Rails would otherwise send its debug page.
- **Results** carry a short text and `structuredContent`. The structured content is exactly the REST
  endpoint's JSON, so money is a decimal string with the currency next to it, dates are ISO 8601, and a
  model can compute with values instead of parsing prose. Each tool's `outputSchema` is generated from the
  same component of `docs/openapi.yaml` (`McpTools::OutputSchema` converts OpenAPI 3.0's `nullable` and
  component references into JSON Schema 2020-12). The text repeats the key figures in a compact form,
  because some clients show the model only the text.
- **Descriptions** are written for a model that knows nothing about the app: what the tool is for, the
  units, that expenses are negative, that two currencies are never added, that drafts and transfers
  between own accounts are not spending, the date format and how to page. The server's `instructions`
  say the same about the ledger in a few sentences.
- **Annotations**: every tool is `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`
  and `openWorldHint: false` (it touches only the owner's own ledger).
- **Page sizes**: `search_transactions` returns 20 rows by default and `recent_receipts` 10 (the REST API
  50): a page goes into the model's context. Both take `limit` up to 200 and the REST API's cursor.

Timings on the development database (about 25,000 transactions): a one-month summary 2 ms, a one-year
summary 3 ms, a page of 20 to 50 transactions 6 ms, of 200 about 15 ms, the other tools under 1 ms.

### Deliberately not offered

- **No write tools.** An assistant cannot create, change or delete anything. Proposing draft transactions
  or accepting receipts will come with the write API, behind the `read_write` scope.
- **No receipt photos.** Photos stay on the owner's machine and are not served to an agent (0002, 0004);
  the receipt tools give the text OCR read from them.
- **No card digits, QR codes or ingest ids**: the receipt JSON leaves them out, as the REST API does.
- **No prompts or resources**, and no server-to-client requests (sampling, elicitation).

## Alternatives considered

- **A separate MCP process** (a small Ruby or Python server calling the REST API): two processes, a
  second token, every number serialised twice, and nothing gained on one machine.
- **The stdio transport** (Claude Desktop starts `bin/rails runner` itself): no HTTP and no token, but every
  conversation would boot Rails, the process would bypass the app's authentication, and only clients on
  the same machine that can run Ruby could use it. HTTP with `mcp-remote` keeps one running server and one
  authentication path.
- **Stateful sessions**: needed only for server-to-client messages, which no tool sends; they would add
  session storage, expiry, and binding a session to its token.
- **OAuth 2.1** (the protocol's authorization flow): for third-party clients and many users; one owner
  with personal tokens does not need an authorization server.
- **Hand-written output schemas**: they would drift from `docs/openapi.yaml`, which already describes the
  same JSON and is checked by the REST tests.

## Consequences

- A new tool is a class in `app/mcp/mcp_tools/` added to `McpTools.all`, with an entry in
  `test/integration/mcp_server_test.rb` (a successful call, a bad argument, the REST request it must equal);
  the test fails until the entry exists, and checks the description, the annotations and both schemas.
- A change to a REST response changes the MCP result and its output schema with it.
- Claude Desktop needs Node.js for `npx mcp-remote`; the README shows the configuration.
- If the app were ever exposed beyond the machine, `APP_HOST` and TLS (production's `force_ssl`) apply to
  `/mcp` as to every page, and the token is still required.

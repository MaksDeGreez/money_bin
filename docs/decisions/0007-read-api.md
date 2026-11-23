# 0007. The read API: query objects, keyset pagination, per-currency summaries, OpenAPI 3.0

Status: accepted, after phase 2.

## Context

AI agents and scripts are the second user of Money Bin. Personal API tokens and `Api::BaseController`
already authenticate them (0002), but the API had one endpoint, `/api/v1/status`. An agent needs to read
the ledger: find transactions, see balances, know the categories, answer "how much did I spend on X", and
look at a receipt. An MCP server will offer the same reads to agents later, so the reading logic must not
live in controllers. The development database holds about 25,000 transactions, so a page must not cost a
query per row or a scan per page.

## Decision

### Endpoints

All `GET`, under `/api/v1`, for a token of either scope: `transactions` (list and one), `accounts`
(with balances), `categories` (the tree), `summary` (expenses and incomes by category, group and month)
and `receipts` (list and one, with items). Photos are not served. `docs/openapi.yaml` describes every
parameter, field and error.

### Query objects in `app/queries/`

`TransactionsQuery`, `AccountBalancesQuery`, `CategoryTreeQuery`, `SpendingSummaryQuery` and
`ReceiptsQuery` are plain Ruby objects. They take values that are already checked (Dates, Integers, enum
strings) and return relations or small `Data` value objects; they know nothing of HTTP.

- The MCP server can call them unchanged, with its own parameter checks in front.
- Each rule sits in one place and is tested without a request: the summary's draft and transfer rules,
  the category-or-group filter, the cursor.
- Controllers only check parameters (`Api::QueryParameters`) and render. Rendering goes through small
  modules in `app/serializers/` that build hashes, with `JsonFormat` for money, quantities, dates and
  times. No serializer gem: the shapes are few, and plain hashes make every key visible next to the
  OpenAPI schema it must match.

### Strict parameters

An unknown parameter, a malformed value, a repeated parameter (`status=a&status=b`, which Rails would
quietly narrow to its last value, or `status[]=...`), a NUL character, an id that names nothing, or `to`
before `from` is a 422 `invalid_parameter` whose message names the parameter. So is a request body: every
endpoint reads only the query string, and an agent whose HTTP tool puts its arguments in a JSON body must
not get the whole ledger back. The routes take no format suffix (`.xml`, `.json`): the API speaks JSON
only. A missing required
parameter (`from` or `to` of the summary) is a 400 `bad_request`, as 0002 set. An agent that misspells a
filter must get an error, not the whole ledger as if the filter had matched. A malformed path id
(`/transactions/12abc`) is a 404: Active Record would read it as 12.

### Keyset pagination

Lists are ordered by a key and the id, newest first: transactions by (`occurred_on`, `id`), receipts by
(the time on the receipt or else the upload time, `id`). A page ends with `next_cursor`, the URL-safe
Base64 of a JSON array holding the last row's key and id, and the next page starts strictly after that
pair (`(occurred_on, id) < (?, ?)`). `limit` is 50 by default and at most 200; the query reads one row
more than the limit to know whether another page exists, so the last page has a null cursor even when it
is exactly full.

- An offset skips rows that are inserted in front of it and repeats rows when one is deleted; a keyset
  position stays where it was. An agent walking the ledger while the importer or the owner adds or
  removes rows sees no duplicates and no gaps. A row whose sort key changes during the walk can move
  across the cursor and be seen twice or not at all: a transaction whose date is edited, or a receipt
  that OCR gives a time (it moves from its upload time to the printed time). Walking again from the start
  sees it once.
- Page N costs what page 1 costs: an index range scan from the cursor, not a skip over N pages.
- The id makes the order total, so rows of one day keep a fixed order.
- The cursor is opaque to clients but not signed: it holds nothing a client could not read from the page
  itself. It is not bound to the filters; a client that changes filters while following it gets a
  consistent, filtered list from the same position. A value the API did not make is a 422.
- Receipts sort by `issued_at` because "my last receipt" means the last purchase; a photo that OCR has
  not read yet has no time on it and sorts by its upload time, so it is new too and an old failed upload
  does not stay on top forever. A time misread into the future keeps its receipt on top until a person
  corrects it.

### The summary: booked only, transfers out, per currency, by lines

- **Booked only.** A draft is a proposal (`docs/domain.md`); `Transaction.booked` is the scope.
- **Transfer legs are left out.** Moving money between own accounts is neither spending nor income; a
  bank fee is already a separate expense.
- **Per currency.** There are no exchange rates yet, so adding UAH to USD would give a number with no
  meaning. Each currency gets its own expenses and incomes, and `currency` keeps one. A base-currency
  view waits for exchange rates (deferred in `docs/domain.md`).
- **Expense or income by the transaction's sign**, as the `expenses` and `incomes` scopes do. A refund
  booked as a positive row is an income; matching refunds to purchases is a later feature.
- **Splits by lines.** The lines of a transaction are summed per category, so a supermarket receipt split
  into groceries and household gives each its share. An opposite-sign line inside an expense (a bottle
  deposit returned) lowers its category's figure. `transactions` in `by_category` counts a split
  transaction once in each of its categories; the side's own `transactions` counts it once.
- **Groups roll up their categories.** A line points at a category, never at a group, so a group's figure
  is the sum of its categories. Lines with no category are reported with a null category and group. The
  "never at a group" rule is the model's only (`docs/domain.md`); a line written past the model at a
  group would be reported as a category with a null group, in the same null-group row as the
  uncategorised lines.
- **Signs are kept.** Expense figures are negative, as in the ledger, so an agent never has to remember
  which endpoint flips the sign.
- **Months** are calendar months of `occurred_on`, oldest first; a month with nothing in it is absent.

It costs three queries whatever the range: one grouped sum of lines (by currency, side, category and
month), one count of transactions, and the category table. Money is summed as `numeric` in PostgreSQL and
as `BigDecimal` in Ruby.

### JSON values

Money is a decimal string with exactly two places and a quantity with exactly three, never a JSON
number: a float cannot hold every decimal amount, and the ML service's contract does the same.
`JsonFormat` refuses a Float and a value it would have to round. The categoriser's `confidence` is a
probability, not money, and stays a JSON number. Dates are ISO 8601; times carry the Kyiv offset.

### N+1 and indexes

A page of transactions preloads accounts, payees, receipts, lines and categories: seven statements with
the token lookup, whatever the page size (a test counts them). A page of receipts is one statement, with
the item count as a subquery, plus one that loads the categories of a card slip's `category` and
`suggested_category` when a receipt on the page refers to one: at most two, whatever the page size (a
test counts them).

The migration `20261118120000_add_read_api_indexes.rb`:

- `transactions (occurred_on, id)` and `transactions (account_id, occurred_on, id)` replace the indexes
  on `occurred_on` and `(account_id, occurred_on)`, which are their prefixes. A page, with or without the
  date and account filters, is an index range scan in the list order, with no sort;
- `transactions (source)` for the source filter;
- `transaction_lines (category_id, transaction_id)` replaces `(category_id)`; it answers the category
  filter's "a line of this transaction in these categories" from the index;
- `receipts (COALESCE(issued_at, created_at AT TIME ZONE 'UTC') DESC, id DESC)` for the receipt order.
  `AT TIME ZONE 'UTC'` turns the UTC `timestamp` into a `timestamptz` and keeps the expression immutable,
  so it can be indexed.

`status` and `payee_id` already had indexes. **`q` has no index, on purpose.** It is a case-insensitive
substring search (`ILIKE '%…%'`) over four columns, one of them in `payees`; a B-tree cannot serve it,
and a trigram index (`pg_trgm`, one GIN index per column) would add an extension and write cost to every
import for a search the owner's ledger does not need yet. Measured on 25,000 transactions, a page with a
term that matches nothing (the worst case: the whole table is read) takes about 5 to 30 ms. If the
ledger grows tenfold, trigram indexes are the way out.

Timings on about 25,000 transactions (the development database for the plain reads, and a scratch copy
of the schema with as many invented rows for the new indexes): a page of 50 transactions, serialized,
6 to 8 ms; a page of 200, about 20 ms; any later page, the same as the first; a summary of one year
4 to 11 ms, of all years 35 to 70 ms.

### OpenAPI 3.0.3, checked by the tests

`docs/openapi.yaml` is OpenAPI **3.0.3**. 3.1 was preferred, but the committee gem (5.6), which the
request tests use to check every response against the document, refuses any 3.1 document
(`Committee::Drivers.load_from_data` raises `OpenAPI3Unsupported`), although the openapi_parser gem
under it has partial 3.1 support. 3.0.3 is the newest version committee validates fully. The difference
that matters here is how a value that may be null is written (`nullable: true` instead of
`type: [..., "null"]`); moving to 3.1 later is a mechanical change.

To make the check strict:

- every object schema has `additionalProperties: false` and lists all its properties in `required`. A
  value that may be empty is `nullable`, never left out, so every response always has every key. A field
  added to a response without the document, or dropped from it, fails the test;
- `test/integration/api_contract_test.rb` checks those two rules over the whole document, keeps one
  example request for every documented path, method and status (a documented response without an
  example fails, and so does an example for an undocumented one), runs each and checks the answer, and
  compares the API routes with the documented paths in both directions;
- the endpoint tests check every response they get, error responses included, and the request too
  (`strict_query_params`: a query parameter the document does not declare fails);
- openapi_parser 2.8 drops a key literally named `discriminator` before it checks
  `additionalProperties: false`, even where no discriminator is declared. `OpenapiTestHelper` therefore
  refuses that key in every response itself, and the contract test keeps the name out of the document.

## Alternatives considered

- **Logic in controllers or model scopes.** Scopes cover single filters, but the category-or-group
  rule, the cursor and the summary would have ended up in controllers, out of reach of the MCP server.
- **Offset pagination (`page=3`)**: simpler, but it drifts while rows are added and gets slower with
  depth. **A signed cursor**: nothing in it is secret, and signing would only make it longer.
- **A serializer gem** (Active Model Serializers, Blueprinter, Alba): another dependency for five shapes.
- **A summary in one currency** through exchange rates: no rates exist yet, and a made-up rate would be
  worse than two honest figures.
- **Counting a split transaction under its largest category**: hides the other shares; summing lines is
  what the ledger's lines are for.
- **rswag or hand-written JSON Schema checks** instead of committee: rswag generates the document from
  RSpec, which this project does not use; committee reads a document written by hand and checks
  Minitest responses against it.
- **Trigram indexes for `q` now**: see above.

### Errors outside the endpoints

The error shape holds for requests no endpoint takes and for requests Rails cannot decode, which once
got Rails' HTML pages:

- **A fallback route** drawn after every API route (`/api(*path)`, `Api::ErrorsController`) takes the
  rest of `/api`. It checks the token first, as every API path does, so without one every path is the
  same 401 and a caller learns nothing about which exist. It skips the scope check, which is about
  methods that change data: a read token sending POST to a GET-only path learns that the method is wrong
  (405 `method_not_allowed`, `Allow` read from the routes, HEAD wherever GET is), not that its token
  only reads. Anything else is a 404 `not_found`: bare `/api`, a misspelt path, a `.xml` suffix. The
  contract test leaves this route out of "every route is documented" by name, and checks it stays last.
- **A Rack middleware** (`lib/middleware/api_request_errors.rb`), for `/api` and `/mcp` paths only,
  answers what fails before any `rescue_from` can see it: the router's and the parameter readers'
  `ActionController::BadRequest` (a path or query whose %-encoding is not UTF-8, `?limit=%`,
  `a=1&a[b]=2`), a body Rack or Rails cannot parse, and the router's `ActionController::UnknownHttpMethod`.
  They become a 400 `bad_request` and a 405 (its `Allow` the methods the area answers anywhere, never per
  path) before the token is checked: the request could not be read far enough, and the answer reveals
  nothing. It sits right after `ActionDispatch::DebugExceptions`, because in development and test that
  renders HTML before `config.exceptions_app` is consulted, so an exceptions app alone would not do; and
  again before `Rack::MethodOverride`, which reads a POST's form body above Rails' error pages and lets
  Rack's multipart errors through. It logs the exception's class only, never the query string.
- A GET whose JSON body does not parse is refused like any other body: 422 `invalid_parameter` naming
  `body`.
- The promise covers requests the web server hands to the app. Puma answers a request it cannot parse
  at all (a malformed request line) itself, in plain text. A 500 is still Rails' own answer, not this shape.

## Deferred

- Writes over the API (an agent proposing a draft transaction, accepting a receipt) and the MCP server.
- Serving receipt photos to an agent.
- Several values for one filter (`status=draft,needs_review`), sorting options, a total row count.
- Zero-filled months in the summary, and a summary filtered by category or account.

## Consequences

- A new read endpoint is a query object, a serializer, a controller that checks its parameters, its
  schema in `docs/openapi.yaml`, and an example per response status in the contract test.
- A new column in an API response is one line in its serializer and one property in the document (added
  to `required`); the receipts serializer has one place (`common`) for fields both receipt shapes share.
  Receipts carry `kind` and `incomplete`, and a card slip its own `category`, `suggested_category` and
  `confidence` (null on any other receipt; `categoriser_model_name` is not exposed); the card digits
  (`card_last4`), the QR code and its ground truth (`qr_*`) and `ingest_id` are left out on purpose: an
  agent reading the ledger needs none of them.
- The MCP server will call the same query objects and can reuse the serializers for the same JSON.

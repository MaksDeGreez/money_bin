# 0002. Authentication and personal API tokens

Status: accepted, phase 1.

## Context

Money Bin has one human user, the owner, who works in the browser, and AI agents and scripts that will
call a REST API (and later an MCP server) on the owner's behalf. It runs on the owner's machine, but it
still holds personal financial data, the repository will be public, and a local web server can be
reached by other software on the same machine and network. So every page and every API call needs an
identity, with as little machinery as possible.

## Decision

### Browser sign-in

- **The Rails 8 authentication generator** (`bin/rails generate authentication`) gives the base: the
  `User` and `Session` models, the `Authentication` concern, `Current`, `SessionsController` and bcrypt
  password hashing through `has_secure_password`. It is plain code in the app, small enough to read in
  full, with no gem to follow. The generated ERB views were rewritten in Slim with the UI helpers.
- **One user only.** There is no sign-up page. The model refuses a second user, and a unique index on the
  constant expression `(true)` (`index_users_single_row`) makes the database refuse it too. The user is
  created on the command line with `bin/rails user:create`, which asks for the e-mail address and the
  password (the password is not echoed and is typed twice) or reads `MONEY_BIN_EMAIL` and
  `MONEY_BIN_PASSWORD` for scripted setups. Seeds never create a user, and no default password exists
  anywhere. Ledger tables keep having no `user_id`.
- **No password reset by e-mail.** The generator adds a `PasswordsController`, a mailer and a signed
  reset token. They were removed, and `has_secure_password reset_token: false` turns the token off. The
  app sends no mail, so a mailed link would be dead code and one more way in. The owner has a shell on the
  machine, so `bin/rails user:password` is the reset: it sets a new password and ends every browser
  session.
- **Passwords** have at least 12 characters (and at most 72 bytes, the bcrypt limit). Changing the
  password ends every other session. Signing out deletes the session row, so an old cookie stops
  working.
- **The session cookie** is the generator's: signed, `HttpOnly`, `SameSite=Lax`, permanent. It is not
  marked `Secure` by the code, so it works over plain HTTP on localhost; in production `force_ssl` marks
  every cookie `Secure`.
- **Sign-in rate limit**: 10 attempts per IP address in 3 minutes (the generator's `rate_limit`). The
  counter lives in the controller cache store, which is Redis in development and production, so it holds
  across Puma workers and restarts. Tests use the null store, where nothing is counted, and the rate
  limit test swaps in a memory counter for itself.
- **Sidekiq Web** is mounted at `/sidekiq` inside a route constraint that looks up the signed session
  cookie in the `sessions` table (`Session.from_cookies`, the same lookup as for pages and Action Cable).
  For a visitor without a valid session the route does not exist: they get a plain 404 and cannot tell
  that the dashboard is there. An API token does not open it.

### Personal API tokens

- **Format**: `mbt_` followed by 44 random base58 characters (48 characters in all). 44 base58
  characters carry about 257 bits, more than 32 random bytes. The app makes the token; a person never
  chooses it. The prefix makes a leaked token easy to spot in a log or for a secret scanner, and base58
  has no look-alike characters and no punctuation, so a double-click selects the whole token.
- **Only a digest is stored**: SHA-256 of the plain token, 64 hex characters, with a unique index. A
  slow password hash (bcrypt, Argon2) exists to slow down guessing of short, human-chosen passwords
  after a database leak. A 257-bit random token cannot be guessed at any hashing speed, so a slow hash
  would only add cost to every API request, and a salted hash could not be found through an index. The
  plain value is returned once, by `ApiToken.issue`, and shown once in the response to the create
  request. It is never stored in the database, the session, the flash or a URL; that page is sent with
  `Cache-Control: no-store` and tells Turbo not to keep a snapshot. Request parameters that contain
  "token" are already filtered from the logs.
- **Lookup**: `ApiToken.find_active_by_plain_token` rejects a malformed value before any query, then finds
  the active row by digest. Unknown, malformed and revoked tokens give the same answer. The only work that
  depends on a secret is the index lookup of a digest, which cannot leak anything useful about a token.
- **Scopes**: `read` allows the safe methods (GET, HEAD, OPTIONS); `read_write` allows every method. The
  column is a string enum with a check constraint, like every enum in the app (`docs/domain.md`).
- **Revocation, not deletion.** Revoking sets `revoked_at`; the row stays, so the list keeps the history.
  A token name is unique among the owner's active tokens, so a revoked token's name can be used again.
- **`last_used_at`** is written at most once a minute per token, without validations or `updated_at`,
  so a busy agent does not write to the database on every request.
- **`Api::BaseController`** (`ActionController::API`) is the base of the REST API. It reads only
  `Authorization: Bearer <token>`; it has no cookie support, so a browser session never authenticates an
  API request, and there is no CSRF check because there is no cookie to forge. It sets
  `Current.api_token` (and so `Current.user`) and checks the scope. Errors have the shape of the ML
  service's errors, `{"error": {"code": "...", "message": "..."}}`: 401 `unauthorized` (no token), 401
  `invalid_token`, both with `WWW-Authenticate: Bearer realm="Money Bin"` (plus `error="..."`), and 403
  `insufficient_scope`. A missing record is 404 `not_found`, a missing parameter 400 `bad_request`.
  `GET /api/v1/status` is the one endpoint for now: it tells an agent that its token works and what
  scope it has.

## Alternatives considered

- **No authentication**, as in the previous version of the app. Rejected: an API for agents needs
  credentials anyway, and a local server is reachable by other programs and browser tabs.
- **Devise** or another gem. Rejected: more code than one user needs, and the generator's code is small
  enough to own.
- **The browser session for the API.** Rejected: agents are not browsers, cookies would bring CSRF into
  the API, and per-agent tokens can be revoked one at a time.
- **OAuth** or JWTs. Rejected for now: there is one user and no third-party client, and a JWT cannot be
  revoked without a lookup, which is what a digest lookup already is.
- **Redirecting signed-out visitors from `/sidekiq` to the sign-in page.** Equally safe; the 404 was
  chosen because it does not reveal the dashboard and needs no second route.

## Deferred

- Token expiry dates and a "rotate" action. Revoking and creating a new token covers both for now.
- Per-resource scopes (for example "receipts only"). Two scopes are enough until the API has resources.
- A rate limit on failed API authentication. Guessing a 257-bit token is hopeless, and an IP-based limit
  on one machine would lock out the owner's own agents when one of them is misconfigured.
- Session expiry and a list of signed-in browsers with a "sign out everywhere" button. Changing the
  password with the rake task ends every session in the meantime.
- A JSON 404 for unknown `/api` paths; today they get Rails' HTML 404.
- Changing the password from the browser.

## Consequences

- Every controller test signs in (`sign_in_as users(:owner)` from `test/support/session_test_helper.rb`),
  and API tests send a fixture token (`bearer(plain_token(:agent_read))` from
  `test/support/api_token_test_helper.rb`).
- New REST API controllers inherit from `Api::BaseController` and get authentication, scope checks and
  the error shape for free. The MCP server should reuse `ApiToken.find_active_by_plain_token` and the
  same scope rule.
- A fresh install needs one extra step, `bin/rails user:create`, before anyone can sign in.

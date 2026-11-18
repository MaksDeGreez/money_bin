# Money Bin

A personal finance tracker for one person and an AI agent. The core flow: take a photo of a receipt, a
local ML service reads it (OCR), the items get categories, and they land in a ledger. AI agents read the
ledger through a REST API (read-only for now); an MCP server comes later. The history kept by the
previous version of the app is loaded with an importer (see "Importing the history"). It is a master's
capstone project (MSc Data Science, engineering project). It is local-first: everything runs on the
owner's machine, and the data and photos stay there.

```
  browser ─┐                       ┌─> PostgreSQL (ledger)
           ├─> Rails app :3100 ────┼─> Redis (Sidekiq queues, cache, Action Cable)
  AI agent ┘   (UI, API, later MCP)├─> local disk (Active Storage: receipt photos)
                     │             │
                     └─> Sidekiq ──┴─> ML service :8100 (FastAPI, ml/)
                                         OCR + categorisation; backend: stub, or a
                                         local Qwen VL model (MLX); OpenRouter later
```

The decisions behind this stack are in [`docs/decisions/0001-stack.md`](docs/decisions/0001-stack.md), and
the ones behind sign-in and API tokens in
[`docs/decisions/0002-authentication-and-api-tokens.md`](docs/decisions/0002-authentication-and-api-tokens.md).
How coding agents share the work is in
[`docs/decisions/0003-agent-tooling.md`](docs/decisions/0003-agent-tooling.md), and how the local OCR model
runs in [`docs/decisions/0005-local-ocr-backend.md`](docs/decisions/0005-local-ocr-backend.md).

## Status

Phase 1: the skeleton and the data model. The Rails app boots with a home page and the UI helpers, the
owner signs in, AI agents authenticate with personal API tokens and read the ledger through a read-only
JSON API, the ML service answers with its stub backend or reads receipts with a local vision model
(`OCR_BACKEND=mlx`, Apple silicon), and CI checks both. The domain model is described in
[`docs/domain.md`](docs/domain.md).

## Requirements

- Ruby 4.0.7 (`.ruby-version`)
- PostgreSQL 18 and Redis 8, for example from Homebrew (`bin/services` starts them with `brew services`)
- [uv](https://docs.astral.sh/uv/) for the ML service (it installs Python 3.12 when needed)
- [gitleaks](https://github.com/gitleaks/gitleaks) for the pre-commit hook (`brew install gitleaks`)
- No Node: Tailwind runs through the standalone CLI bundled with `tailwindcss-rails`

## Setup

```sh
bin/setup                # gems, Python packages, .env, git hooks, services, databases, then bin/dev
bin/setup --skip-server  # the same without starting the app
bin/setup --reset        # also resets the databases (bin/rails db:reset)
bin/rails user:create    # once: the one user who signs in (see "Signing in and API tokens")
```

## Run

```sh
bin/dev                  # http://localhost:3100
```

`bin/dev` checks PostgreSQL and Redis (`bin/services`), removes old compiled assets, and starts the
processes in `Procfile.dev` with foreman:

| Process   | What it is                                   | Port |
| --------- | -------------------------------------------- | ---- |
| `web`     | Puma, the Rails app                          | 3100 (`PORT`) |
| `sidekiq` | background jobs (`config/sidekiq.yml`): 4 threads, plus 1 for OCR jobs | -    |
| `css`     | the Tailwind watcher                         | -    |
| `ml`      | the ML service (`uvicorn app.main:app`)      | 8100 |

Without `uv` (or without `ml/`), `bin/dev` starts everything except the ML service. Useful URLs:
`/` (home), `/session/new` (sign in), `/settings/api_tokens` (API tokens), `/sidekiq` (background jobs,
signed in only), `/api/v1/status` (API check; the whole read API is under `/api/v1`, see "The read
API"), `/up` (health check), <http://127.0.0.1:8100/docs> (ML
service API docs).

## Signing in and API tokens

The app has exactly one user, the owner, and no sign-up page. Create the user once, on the machine that
runs the app:

```sh
bin/rails user:create      # asks for the e-mail address and the password (at least 12 characters)
bin/rails user:password    # sets a new password and signs out every browser
```

The password is typed without echo, twice. For a scripted setup, both tasks read `MONEY_BIN_EMAIL` and
`MONEY_BIN_PASSWORD` from the environment instead of asking (keep such a password out of your shell
history). A second user is refused. There is no password reset by e-mail: `bin/rails user:password` is
the reset. Seeds never create a user.

Every page needs a signed-in session, except the sign-in page and `/up`. Sign in at `/session/new`.
Rails' own Active Storage routes (`/rails/active_storage/...`) are not drawn, because they would skip
the sign-in check: receipt photos will be served by the app's own controllers. Every page is sent with a
strict Content Security Policy, and in production the app answers only to `localhost`, `127.0.0.1`,
`::1` and `APP_HOST`.

AI agents and scripts use **personal API tokens**, not the browser session. Create one at
`/settings/api_tokens` (signed in): give it a name and a scope, `read` (GET requests only) or
`read_write` (every request). The token (`mbt_` and 44 more characters) is shown once, right after it
is created: copy it then. Only a SHA-256 digest of it is stored, so it cannot be shown again; revoke a
lost token and create a new one. Revoked tokens stay in the list.

Send the token in the `Authorization` header:

```sh
export MONEY_BIN_TOKEN='mbt_...'   # the token you copied (placeholder here)
curl -s -H "Authorization: Bearer $MONEY_BIN_TOKEN" http://localhost:3100/api/v1/status
# {"status":"ok","token":{"name":"Laptop agent","scope":"read"}}
```

Errors have one shape, `{"error": {"code": "...", "message": "..."}}`: 401 `unauthorized` (no token) or
`invalid_token` (unknown, malformed or revoked), 403 `insufficient_scope` (a `read` token on a request
that changes data).

## The read API

Agents and scripts read the ledger under `/api/v1` with a token of either scope. Every endpoint, parameter
and response is described in [`docs/openapi.yaml`](docs/openapi.yaml) (OpenAPI 3.0.3), and the request
tests check every response against it. The design is in
[`docs/decisions/0007-read-api.md`](docs/decisions/0007-read-api.md).

- Money and quantities are decimal strings (`"-1250.40"`, `"0.850"`), never JSON numbers. Amounts are
  signed in the account currency: expenses negative, incomes positive.
- Dates are `YYYY-MM-DD`; times carry the Kyiv offset (`2026-10-03T18:40:00+03:00`).
- An unknown or repeated parameter, a malformed value, an id that names nothing or a request body is a
  422 `invalid_parameter` whose message names the parameter; a missing record is a 404 `not_found`.
  Send every parameter in the query string.
- Lists come a page at a time (`limit`, 50 by default, at most 200): pass the answer's `next_cursor` as
  `cursor` for the next page, until it is `null`.

The examples below use invented data and are shortened (`…`).

```sh
H="Authorization: Bearer $MONEY_BIN_TOKEN"
API=http://localhost:3100/api/v1

# Transactions, newest first. Filters: from, to (dates on occurred_on, inclusive), account_id,
# category_id (a category, or a group for all its categories), status, payee_id, q (text search), source.
curl -s -H "$H" "$API/transactions?from=2026-10-01&to=2026-10-31&category_id=12&limit=2"
# {"transactions":[{"id":81,"occurred_on":"2026-10-03","occurred_at":"2026-10-03T18:40:00+03:00",
#   "amount":"-1250.40","currency":"UAH","status":"confirmed","source":"receipt",
#   "account":{"id":2,"name":"Everyday card","currency":"UAH"},"payee":{"id":5,"name":"Example Market"},
#   "transfer_id":null,"has_receipt":true,"receipt_id":7,
#   "lines":[{"id":140,"category":{"id":12,"slug":"groceries/groceries","name":"Groceries"},
#             "amount":"-1000.40","comment":null}, …], …}, …],
#  "next_cursor":"WyIyMDI2LTEwLTAzIiw4MV0"}

# One transaction.
curl -s -H "$H" "$API/transactions/81"

# Accounts with their balances (booked transactions only).
curl -s -H "$H" "$API/accounts"
# {"accounts":[{"id":2,"name":"Everyday card","kind":"debit","currency":"UAH","archived":false,
#   "balance":"4334.60"}, …]}

# The category tree.
curl -s -H "$H" "$API/categories"
# {"groups":[{"id":3,"slug":"eating-out","name":"Eating out","position":2,"description":null,
#   "categories":[{"id":12,"slug":"eating-out/cafes-bars-restaurants","name":"Cafes, bars & restaurants",
#   "position":1,"description":"Meals and drinks at cafes, bars and restaurants."}, …]}, …]}

# Expenses and incomes by category, group and month, per currency (from and to are required;
# currency=UAH keeps one currency). Booked transactions only, transfers left out.
curl -s -H "$H" "$API/summary?from=2026-10-01&to=2026-10-31"
# {"from":"2026-10-01","to":"2026-10-31","currencies":[{"currency":"UAH",
#   "expenses":{"total":"-2225.40","transactions":4,
#     "by_category":[{"category":{…},"group":{…},"amount":"-1000.40","transactions":1}, …],
#     "by_group":[{"group":{…},"amount":"-1000.40"}, …],
#     "by_month":[{"month":"2026-10","amount":"-2225.40","by_category":[…]}]},
#   "incomes":{"total":"50000.00", …}}]}

# Receipts, newest first (status filters them), and one receipt with its items.
curl -s -H "$H" "$API/receipts?limit=1"
# {"receipts":[{"id":7,"status":"reviewed","kind":"fiscal","incomplete":false,"merchant":"Example Market",
#   "issued_at":"2026-10-03T18:40:00+03:00","issued_on":"2026-10-03","total":"1250.40",
#   "currency":"UAH","transaction_id":81,"items_count":3}],"next_cursor":"…"}
curl -s -H "$H" "$API/receipts/7"
# {"id":7, …,"items_total":"1250.40","items":[{"id":20,"position":1,"name":"Rye bread",
#   "quantity":"2.000","unit_price":"20.20","amount":"40.40","discount":"0.00",
#   "category":{…},"suggested_category":{…},"confidence":0.97,"accepted_by_user":true}, …]}
```

## Importing the history

The previous version of the app writes an export folder (a manifest and four JSON Lines files). Keep it
outside this repository: it holds personal data. Then:

```sh
DRY_RUN=1 bin/rails "import:money_bin[/path/to/export]"   # check and count, then roll back
bin/rails "import:money_bin[/path/to/export]"             # import
```

The importer checks the whole export before it writes anything (hashes, counts, every field, references,
transfer pairs), writes everything in one database transaction, and can be run again. Each imported row
remembers a digest of the export row it came from: the same export a second time writes nothing and keeps
every change made in the app since (a category given, a row confirmed, a comment fixed); only a row that
changed in the export is written again from it. It prints counts and warnings only, never a name or an amount, and exits
with status 1 when it stops. The taxonomy must be loaded first (`bin/rails db:seed`). The format and every
rule are in [`docs/import-contract.md`](docs/import-contract.md).

## Receipt photos for OCR evaluation

`tools/receipt_ingest/` is a separate command-line tool (Python, uv). It does not talk to the app. It
turns a folder of phone photos of paper receipts (`RAW_DIR/<batch>/…`) into a numbered receipt set for
testing OCR: it groups the photos into receipts by the pause between them, gives every receipt a number
that stays the same on later runs, writes JPEG copies with all metadata removed, reads the QR code (on a
Ukrainian fiscal receipt it holds the total, the date and time and the fiscal numbers, so it is free
ground truth), crops the receipt and builds a contact sheet for checking the grouping.

```sh
uv run --project tools/receipt_ingest receipt-ingest \
  ~/Documents/money_bin_receipts/raw ~/Documents/money_bin_data/receipts
```

Both folders are outside this repository: receipt photos are personal data. The tool opens the raw
photos read-only, refuses an output folder inside a git repository, and prints counts only. The output
is `images/rcpt_000123_1.jpg` and so on, `receipts.jsonl` (one line per receipt), `groups_review.html`
(the contact sheet) and `state.json`; grouping mistakes are fixed in `groups_override.yaml` in the same
folder. Options, the output format and the rules are in
[`tools/receipt_ingest/README.md`](tools/receipt_ingest/README.md); the reasons are in
[`docs/decisions/0004-receipt-ingest.md`](docs/decisions/0004-receipt-ingest.md).

### Loading the receipt set into the app

```sh
DRY_RUN=1 bin/rails "receipts:load[$HOME/Documents/money_bin_data/receipts]"   # check and count, then roll back
bin/rails "receipts:load[$HOME/Documents/money_bin_data/receipts]"             # load
```

Every receipt of the set becomes a `Receipt` (status `uploaded`) with its photos, its ingest number
(`ingest_id`), its batch and what its tax QR code says (`qr_*` columns, kept apart from what OCR will
read). The task checks the whole `receipts.jsonl` and every image (inside the folder, size, SHA-256,
fingerprint) before it writes anything, then writes one receipt per database transaction. Run it again
after each new ingest run: unchanged receipts are left alone, receipts the tool regrouped get their new
photos while nobody has worked on them yet, and receipts that left the set are deleted while untouched
(otherwise kept and reported). It enqueues no OCR. It prints counts (in total and per batch folder) and receipt ids only, never a QR
value, a total, a date or a photo name, and exits with status 1 when the check fails or a receipt could
not be written. A real run needs Redis (Active Storage analyses photos in background jobs). The rules are
in [`docs/domain.md`](docs/domain.md), "Receipt load".

## Training the transaction categoriser

`ml/categoriser/` trains a model that suggests a category for a transaction (TF-IDF + logistic
regression, with rule baselines to beat) from a history export, and evaluates it on the latest 20% of the
history by date:

```sh
cd ml
uv run python -m categoriser.train /path/to/export   # model + metrics JSON in ~/Documents/money_bin_data/models/
```

It runs locally only. The model file holds payee names, so it and the metrics JSON go to a folder outside
the repository (the command refuses one inside a git repository); the console prints counts and metrics
only. Details: [`ml/README.md`](ml/README.md); reasons:
[`docs/decisions/0006-transaction-categoriser.md`](docs/decisions/0006-transaction-categoriser.md).

## Tests and checks

```sh
bin/ci                   # every check, full output
bin/ci --summary         # one line per step, the output of failed steps only (full log: tmp/ci/last.log)
```

`bin/ci` (steps in `config/ci.rb`) runs: setup, RuboCop, slim-lint, bundler-audit, the importmap audit,
Brakeman, the leak check of the tracked files, the Tailwind build, the Rails tests, the seeds, and ruff
and pytest in `ml/` and in `tools/receipt_ingest/`. Run it before every push.

Parts of it alone:

```sh
bin/rails test                         # all Rails tests; a full run fails below 80% line coverage
bin/rails test test/path/to_test.rb:12 # one file or one test (the coverage minimum is not checked)
bin/rubocop
bin/slim-lint app/views

cd ml
uv run pytest                          # Python tests; fails below 70% coverage
uv run ruff check .
uv run ruff format --check .

cd tools/receipt_ingest
uv run pytest                          # the receipt tool's tests; fails below 80% coverage
uv run ruff check .
uv run ruff format --check .
```

API request tests check every response against `docs/openapi.yaml` with committee
(`test/support/openapi_test_helper.rb`), and `test/integration/api_contract_test.rb` fails when a documented
path or status has no test or an endpoint is not documented.

No test reaches the network (WebMock on the Rails side, the stub backend on the Python side), and no
test needs model weights, real receipts or personal data. Fixtures are invented, and the receipt tool's
tests generate every image they use.

## Configuration

`bin/setup` copies `.env.example` to `.env` (never committed). dotenv loads it in development and
production. Test runs read no `.env` file at all (`config/application.rb`), so a setting written there
for development can never point the tests at development data; a real environment variable (as CI sets
`DATABASE_URL` and `REDIS_URL`) still applies to the tests. Every setting is optional:

| Variable         | Default                         | Meaning |
| ---------------- | ------------------------------- | ------- |
| `REDIS_URL`      | `redis://localhost:6379/<db>`   | Redis for Sidekiq, the cache and Action Cable; overrides the database numbers below |
| `ML_SERVICE_URL` | `http://127.0.0.1:8100`         | where Rails finds the ML service |
| `OCR_BACKEND`    | `stub`                          | the ML service's backend: `stub`, `mlx`, `openrouter` (see `ml/README.md`) |
| `MLX_OCR_MODEL`  | `mlx-community/Qwen2.5-VL-7B-Instruct-4bit` | the `mlx` backend's model; `MLX_OCR_MAX_TOKENS`, `MLX_OCR_IMAGE_MAX_SIDE` and `MLX_OCR_CONSTRAINED_DECODING` tune it (see `ml/README.md`) |
| `PORT`           | `3100`                          | the Rails server port in `bin/dev` |
| `APP_HOST`       | (unset)                         | production only: one more host name to answer to, besides `localhost`, `127.0.0.1` and `::1` |
| `DATABASE_URL`   | (unset)                         | merged over `config/database.yml`; CI sets it in the environment for the tests |

Databases and Redis numbers. The names and numbers are chosen so this app can share PostgreSQL and Redis
with another local app on the same machine without touching its data, and the ports (3100, 8100) do not
clash with the usual 3000 and 8000.

| Environment                 | PostgreSQL database             | Redis database |
| --------------------------- | ------------------------------- | -------------- |
| development                 | `money_bin_v2_development`      | 5 |
| test, main checkout         | `money_bin_v2_test`             | 6 |
| test, linked git worktree   | `money_bin_v2_test_<worktree>`  | one of 7..15 |
| production                  | `money_bin_v2_production`       | 4 |

How the Redis numbers fit with another local app on the same Redis: that app uses databases 0, 1 and 2,
and each of its git worktrees takes a test database from 3 upward, the lowest free one first. This app
uses 4 (production, when `REDIS_URL` is not set), 5 (development), 6 (tests in the main checkout) and
7..15 (tests in linked worktrees). So the two apps can only meet when the other app has several
worktrees running tests at once: its second one would take 4, its third 5. This is a known and accepted
limit, because the other app is no longer developed. If it ever matters, give this app a Redis instance
of its own with `REDIS_URL`. `config/redis_url.rb` and `config/database.yml` are the places that decide
the numbers and names.

## Project layout

```
app/              Rails app: models, controllers, Slim views, UI helpers (app/helpers/ui_helper.rb,
                  app/views/ui/, app/form_builders/ui_form_builder.rb), jobs, query objects
                  (app/queries/, the API's reading logic) and the API's JSON builders (app/serializers/)
bin/              setup, dev, ci, services, worktree and pull request scripts, leak-check, codex-review,
                  favicon
config/           Rails config; ci.rb (the bin/ci steps), redis_url.rb, worktree_isolation.rb
db/               migrations, schema, seeds
design/           favicon/source.png, the artwork behind the logo and the favicons
docs/             domain.md (the data model), import-contract.md (the history export), openapi.yaml
                  (the REST API) and decisions/ (architecture decision records)
ml/               the Python ML service (FastAPI, uv) and the categoriser training (ml/categoriser/);
                  see ml/README.md
test/             Minitest tests and invented fixtures; test/support/coverage.rb is the coverage gate
tools/            receipt_ingest/: the command-line tool that prepares receipt photos for OCR evaluation
                  (Python, uv); see tools/receipt_ingest/README.md
.githooks/        the git hooks (pre-commit, pre-push)
.github/          CI workflow and Dependabot
.claude/          settings, agents and skills for coding agents; CLAUDE.md is their guide
```

## Logo and favicons

The artwork is `design/favicon/source.png`. The logo in the page header is a 160 px copy of it at
`app/assets/images/logo.png`, resized by hand:

```sh
sips -z 160 160 design/favicon/source.png --out app/assets/images/logo.png
```

The icon set in `public/` (`favicon.ico` with 16, 32 and 48 px, `favicon-96.png`, `apple-touch-icon.png`)
is generated from the same source by `bin/favicon`, which only needs libvips. Replace the source and run
the script again to change it. There is no web manifest and no service worker: this is a local tool, not
an installable app.

## Guard rails

This repository will be public. No secrets and no personal data may enter it.

- **Ignored paths** (`.gitignore`): `.env*` (except `.env.example`), `config/*.key` and
  `config/credentials/*.key`, any folder named `data/` at any depth, `storage/` (uploaded photos), model
  weight files (`*.safetensors`, `*.gguf`, `*.pt`, `*.pth`, `*.h5`, `*.ckpt`, `*.onnx` and others),
  iPhone photos (`.heic` and `.heif` in any letter case) and the receipt tool's output (`rcpt_*.jpg`,
  `receipts.jsonl`, `groups_override.yaml`, `groups_review.html`), coverage reports and
  Python caches. `test/config/gitignore_test.rb` checks these rules.
- **Git hooks** in `.githooks/`. `bin/setup` turns them on; by hand: `git config core.hooksPath .githooks`.
  - `pre-commit` runs gitleaks on the staged changes and blocks a commit with a secret. Without gitleaks
    installed it blocks every commit and says how to install it.
  - `pre-push` refuses any push that updates `main` on the remote (open a pull request instead;
    `ALLOW_PUSH_TO_MAIN=1` is for a real emergency only). It then runs `bin/leak-check --pre-push`.
- **The leak check** (`bin/leak-check`) reads forbidden terms from
  `~/Documents/money_bin_data/leak_terms.txt`, a file outside the repository (`LEAK_TERMS_FILE` names
  another one). One term per line; blank lines and lines starting with `#` are ignored; matching is
  literal, ignores case, and puts both sides in Unicode NFC form first (so "й" matches whether it is one
  code point or two). Before a push it checks the added lines, the paths of added or renamed files
  and the messages of every commit the remote does not have yet, plus the pushed ref names, the messages
  of annotated tags and the content of a tag that points at a blob or a tree. Binary files and files
  marked `-diff` are read as text. A hit blocks the push; the report names the commit, the file and the
  line, and the line of the terms file, but never the term. Without the terms file it warns and passes. `bin/leak-check --tree` checks every file
  in the working tree that git tracks or would track (`bin/ci` runs it), and `bin/leak-check --history`
  checks every commit of the local branches and tags, and every tag: run both before making the
  repository public. It does **not** look at the names and e-mail addresses of authors, committers and
  taggers, nor at text that is not stored as UTF-8 (inside a compressed file or a PDF, for example);
  check `git log --format='%an %ae %cn %ce' | sort -u` by hand.
- **CI** (`.github/workflows/ci.yml`) runs on every pull request and on pushes to `main`, in four jobs:
  `rails` (RuboCop, slim-lint, Brakeman, bundler-audit, importmap audit, Tailwind build, tests with the
  coverage minimum, seeds), `python` (ruff, pytest in `ml/`), `receipt_ingest` (ruff, pytest in
  `tools/receipt_ingest/`) and `gitleaks` (a secret scan of the whole history).
  The `CI` job passes only when all four passed; it is the check that decides a merge. The leak check
  does not run on GitHub, because the terms file only exists on the owner's machine.
- **Dependabot** opens weekly, grouped updates for gems, GitHub Actions and the Python packages of `ml/`
  and `tools/receipt_ingest/`. MLX, mlx-vlm and transformers come one pull request each, outside the
  groups: CI cannot run the local model, so each is checked by hand on the Mac.

## Git worktrees

Several coding agents can work at once, each in its own linked git worktree.

```sh
bin/worktree-setup              # inside a new worktree: links .env, .env.local and config/master.key
                                # from the main checkout, then runs bin/setup --skip-server
bin/worktree-remove PATH        # retire one: drops its test databases, removes it, deletes a merged branch
```

All worktrees share the development database and Redis database 5. Each one gets its own test database
(`money_bin_v2_test_<worktree>`) and test Redis database (one of 7..15), so test runs in two worktrees
never wipe each other's data (`config/worktree_isolation.rb`). A known limit: the worktree name is
lowercased and every run of other characters becomes `_`, so two names that differ only in case or
punctuation (`a-1` and `a1`, `Fix` and `fix`) get the same test database; give worktrees names that
differ in letters or digits.

## Contributing

- Every change goes through a branch and a pull request. Nobody pushes to `main`; the pre-push hook
  refuses it.
- Run `bin/ci --summary` before you push.
- The `CI` check must be green before a merge. Pull requests are squash-merged (`gh pr merge <n>
  --squash`). `bin/pr-wait <n>` waits for the checks of a pull request and prints one final line.
- Keep commits small, and keep `README.md`, `CLAUDE.md` and `docs/` current in the same change.
- `CLAUDE.md` is the guide for coding agents; `.claude/agents/` defines the implementer and reviewer
  agents, and `.claude/skills/` holds the delivery pipeline they follow (`ship`), the second-opinion
  review by the Codex CLI (`codex-review`, `bin/codex-review`) and the rules for extending the UI layer
  (`design-system`). The reasons are in
  [`docs/decisions/0003-agent-tooling.md`](docs/decisions/0003-agent-tooling.md).

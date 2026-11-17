# Money Bin

A personal finance tracker for one person and an AI agent. The core flow: take a photo of a receipt, a
local ML service reads it (OCR), the items get categories, and they land in a ledger. A REST API and an
MCP server for AI agents come later, and so does an import of the history kept by the previous version
of the app. It is a master's capstone project (MSc Data Science, engineering project). It is local-first:
everything runs on the owner's machine, and the data and photos stay there.

```
  browser ─┐                       ┌─> PostgreSQL (ledger)
           ├─> Rails app :3100 ────┼─> Redis (Sidekiq queues, cache, Action Cable)
  AI agent ┘   (UI, later API/MCP) ├─> local disk (Active Storage: receipt photos)
                     │             │
                     └─> Sidekiq ──┴─> ML service :8100 (FastAPI, ml/)
                                         OCR + categorisation; backend: stub now,
                                         a local MLX model or OpenRouter later
```

The decisions behind this stack are in [`docs/decisions/0001-stack.md`](docs/decisions/0001-stack.md), and
the ones behind sign-in and API tokens in
[`docs/decisions/0002-authentication-and-api-tokens.md`](docs/decisions/0002-authentication-and-api-tokens.md).

## Status

Phase 1: the skeleton and the data model. The Rails app boots with a home page and the UI helpers, the
owner signs in, AI agents authenticate with personal API tokens, the ML service answers with its stub
backend, and CI checks both. The domain model is described in
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
| `sidekiq` | background jobs (`config/sidekiq.yml`)       | -    |
| `css`     | the Tailwind watcher                         | -    |
| `ml`      | the ML service (`uvicorn app.main:app`)      | 8100 |

Without `uv` (or without `ml/`), `bin/dev` starts everything except the ML service. Useful URLs:
`/` (home), `/session/new` (sign in), `/settings/api_tokens` (API tokens), `/sidekiq` (background jobs,
signed in only), `/api/v1/status` (API check), `/up` (health check), <http://127.0.0.1:8100/docs> (ML
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

## Tests and checks

```sh
bin/ci                   # every check, full output
bin/ci --summary         # one line per step, the output of failed steps only (full log: tmp/ci/last.log)
```

`bin/ci` (steps in `config/ci.rb`) runs: setup, RuboCop, slim-lint, bundler-audit, the importmap audit,
Brakeman, the leak check of the tracked files, the Tailwind build, the Rails tests, the seeds, and in
`ml/` ruff and pytest. Run it before every push.

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
```

No test reaches the network (WebMock on the Rails side, the stub backend on the Python side), and no
test needs model weights, real receipts or personal data. Fixtures are invented.

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

Redis databases 0..3 are left to other apps. `config/redis_url.rb` and `config/database.yml` are the
places that decide this.

## Project layout

```
app/              Rails app: models, controllers, Slim views, UI helpers (app/helpers/ui_helper.rb,
                  app/views/ui/, app/form_builders/ui_form_builder.rb), jobs
bin/              setup, dev, ci, services, worktree and pull request scripts, leak-check
config/           Rails config; ci.rb (the bin/ci steps), redis_url.rb, worktree_isolation.rb
db/               migrations, schema, seeds
docs/             domain.md (the data model) and decisions/ (architecture decision records)
ml/               the Python ML service (FastAPI, uv); see ml/README.md
test/             Minitest tests and invented fixtures; test/support/coverage.rb is the coverage gate
.githooks/        the git hooks (pre-commit, pre-push)
.github/          CI workflow and Dependabot
.claude/          settings, agents and skills for coding agents; CLAUDE.md is their guide
```

## Guard rails

This repository will be public. No secrets and no personal data may enter it.

- **Ignored paths** (`.gitignore`): `.env*` (except `.env.example`), `config/*.key`, any folder named
  `data/` at any depth, `storage/` (uploaded photos), model weight files (`*.safetensors`, `*.gguf`,
  `*.pt`, `*.onnx` and others), coverage reports and Python caches.
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
- **CI** (`.github/workflows/ci.yml`) runs on every pull request and on pushes to `main`, in three jobs:
  `rails` (RuboCop, slim-lint, Brakeman, bundler-audit, importmap audit, Tailwind build, tests with the
  coverage minimum, seeds), `python` (ruff, pytest) and `gitleaks` (a secret scan of the whole history).
  The `CI` job passes only when all three passed; it is the check that decides a merge. The leak check
  does not run on GitHub, because the terms file only exists on the owner's machine.
- **Dependabot** opens weekly, grouped updates for gems, GitHub Actions and the Python packages.

## Git worktrees

Several coding agents can work at once, each in its own linked git worktree.

```sh
bin/worktree-setup              # inside a new worktree: links .env, .env.local and config/master.key
                                # from the main checkout, then runs bin/setup --skip-server
bin/worktree-remove PATH        # retire one: drops its test databases, removes it, deletes a merged branch
```

All worktrees share the development database and Redis database 5. Each one gets its own test database
(`money_bin_v2_test_<worktree>`) and test Redis database (one of 7..15), so test runs in two worktrees
never wipe each other's data (`config/worktree_isolation.rb`).

## Contributing

- Every change goes through a branch and a pull request. Nobody pushes to `main`; the pre-push hook
  refuses it.
- Run `bin/ci --summary` before you push.
- The `CI` check must be green before a merge. Pull requests are squash-merged (`gh pr merge <n>
  --squash`). `bin/pr-wait <n>` waits for the checks of a pull request and prints one final line.
- Keep commits small, and keep `README.md`, `CLAUDE.md` and `docs/` current in the same change.
- `CLAUDE.md` is the guide for coding agents; `.claude/agents/` defines the implementer and reviewer
  agents and `.claude/skills/ship/` the delivery pipeline they follow.

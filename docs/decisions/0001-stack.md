# 0001. The stack

Status: accepted, phase 1.

## Context

Money Bin is a personal finance tracker for one person and an AI agent. The core flow is a receipt photo,
read by OCR, turned into categorised items, stored in a ledger. A REST API and an MCP server for agents
come later, and so does an import of the history kept by the previous version of the app. It is a
master's capstone, built by one developer, and it runs on the owner's own machine.

So the stack must be quick to build with alone, cheap to run on a laptop, keep private data on that
laptop, and leave room for machine learning code, which lives in Python.

## Decision

- **One Rails 8 app with PostgreSQL** holds the domain, the web UI and, later, the REST API and the MCP
  server. PostgreSQL gives exact `numeric` columns for money, `jsonb` for raw OCR output, and solid
  constraints for the ledger's rules.
- **Redis and Sidekiq for background jobs.** Redis also backs the cache and Action Cable. The Solid trio
  (Solid Queue, Solid Cache, Solid Cable) was not chosen: Sidekiq has a mature UI, retries and a long
  record, Redis is already installed for other local work, and one Redis serves all three uses. Each
  environment keeps to its own Redis database numbers (`config/redis_url.rb`).
- **A separate FastAPI service for ML** (`ml/`, Python 3.12, managed with `uv`). Rails calls it over HTTP
  on `127.0.0.1:8100`. It has two endpoints, receipt OCR and item categorisation, and a swappable backend
  chosen by `OCR_BACKEND`: `stub` today (fixed, invented data in the final response shapes), a local
  MLX vision model or a hosted model through OpenRouter later. Rails sees the same contract whatever the
  backend is.
- **Local-first.** Data and receipt photos stay on the machine. Active Storage uses the local disk.
  The only data that may leave it is what a hosted OCR backend needs, and only when the owner turns that
  backend on.
- **Hotwire, Slim and Tailwind without Node.** Turbo and Stimulus over importmap, Slim as the only
  template language, Tailwind CSS v4 through the standalone CLI of `tailwindcss-rails`. There is no
  JavaScript build step and no `node_modules`.

## Alternatives considered

- **ML inside Rails** (Ruby bindings or shelling out to Python scripts). Rejected: the model libraries are
  Python-first, and a long OCR call would hold a Ruby process. A small HTTP service is easy to test alone,
  to replace, and to run with a stub.
- **A Python-only app** (FastAPI or Django for everything). Rejected: Rails gives the CRUD screens, forms,
  jobs and migrations of a ledger app much faster, and the engineering part of the project is the
  boundary between the two, not one framework.
- **SQLite and the Solid trio** (the Rails 8 default). Reasonable for one user, but PostgreSQL's numeric
  types, constraints and `jsonb` suit a ledger better, and Sidekiq and Redis were preferred for jobs (see
  above).
- **A hosted backend** (a cloud database, cloud storage for photos). Rejected: receipts and the ledger are
  personal data, and the app has one user on one machine.
- **A JavaScript front end** (React, a bundler). Rejected: the UI is forms and lists, which Hotwire covers
  without a second toolchain.

## Consequences

- Two languages and two test suites. `bin/ci` and GitHub CI run both: RuboCop, slim-lint, Brakeman, the
  audits and Minitest for Rails; ruff and pytest for Python.
- Development needs PostgreSQL, Redis and `uv` on the machine. `bin/setup` installs the dependencies and
  `bin/services` starts the services; `bin/dev` runs Puma, Sidekiq, the Tailwind watcher and the ML
  service together.
- The Rails to ML boundary is an HTTP contract (`ml/README.md`). Tests on the Rails side stub it with
  WebMock, and the ML tests use the stub backend, so no test needs model weights, real receipts or the
  network.
- Moving OCR to a real model is a change inside `ml/` only.

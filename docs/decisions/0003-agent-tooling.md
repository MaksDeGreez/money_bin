# 0003. Agent tooling: sub-agents, skills and a second-opinion review

Status: accepted, phase 2.

## Context

Most of the code in this repository is written by coding agents that the owner directs. An agent that
plans, writes and checks its own change is anchored on its own reasoning, and one long session that does
everything runs out of room to think. The work also has parts that are easy to get quietly wrong: money
arithmetic, migrations, importers. The tooling has to make an independent check cheap, keep parallel work
from colliding, and never let a review tool write to the tree, reach the database or see a secret.

## Decision

### Roles

- **The main session plans and coordinates.** It researches, writes the plan, puts the open decisions to
  the owner and waits for approval before implementing (`CLAUDE.md`, "Working with the owner"). It owns
  git and GitHub: branches, commits, pull requests, merges.
- **`implementer`** (`.claude/agents/implementer.md`) does one scoped change in a working tree and
  reports back. It never pushes, switches branches or calls `gh`, so several agents can share a tree. Its
  brief states the goal, the scope and what the owner has already decided; the brief is all it knows.
- **`reviewer`** (`.claude/agents/reviewer.md`, read-only) tries to refute a plan or a diff before it
  ships. It gets the code, not the author's conclusion.
- **Codex** (`bin/codex-review`, the `codex-review` skill) is a second opinion from another vendor's
  model, run read-only in its own sandbox. It is for changes to the data model, migrations, money
  arithmetic and importers, and for plans that touch those. It is often right about things a same-model
  review misses and sometimes confidently wrong, so every finding is traced in the code before it is
  accepted, rejected or deferred, and the outcome goes into the pull request.

### Skills

- **`ship`** (`.claude/skills/ship/`) is the delivery pipeline: branch, implement, `bin/ci`, review, pull
  request, wait for the `CI` check, squash merge, report.
- **`codex-review`** (`.claude/skills/codex-review/`) says when and how to run the Codex wrapper and how
  to handle what it returns.
- **`design-system`** (`.claude/skills/design-system/`) is the way to extend or rebrand the UI layer
  (tokens, component classes, UI helpers and partials, the form builder) and to audit views that bypass
  it. It is adapted from `buildermethods/bm-skills` (MIT; the licence is kept next to it). The app has no
  design-system reference page: the source files and their tests are the reference.

### The Codex wrapper

A bare `codex` call goes wrong in several ways: it has write access unless a sandbox is forced, it blocks
forever on an inherited open stdin, it tries to run the test suite without a database, and a revoked
login only shows after twenty seconds of log noise. `bin/codex-review` forces the read-only sandbox, feeds
the prompt through a file, states the ground rules (no tests, no secrets, a time limit) and the output
format, kills the whole process group on a timeout, and exits with a distinct code for each failure, so
the caller reports "no review this time" instead of retrying. Each run is kept under `tmp/codex/<run>/`
(the prompt, the transcript, the review), which git ignores.

### Database evidence (`--sql`)

Codex's read-only sandbox blocks every network connection, the PostgreSQL socket included, so on its own
it reviews code and never data. The wrapper brings the data to it: `--sql FILE` runs the requester's
queries with `psql` before Codex starts (`$DATABASE_URL`, or `money_bin_v2_development`; at most 100 KB
of output) and puts the echoed queries and their results in the prompt as evidence. The prompt names the
database and never prints the URL, which can hold a password. Codex asks for more under "Questions"; the
requester reads those queries and runs them.

The session is made read-only, with a 30 second statement timeout, by a `SET` that psql runs after
connecting and before the file. `PGOPTIONS` cannot do this, because an `options=` parameter in the URL
silently overrides it. The client encoding is pinned to UTF-8 for the same reason: an inherited
`PGCLIENTENCODING` can turn non-ASCII text into replacement characters with exit 0. A file with a psql
meta-command (`\!`, `\o`, `\copy`, `\set ON_ERROR_STOP off`) or a switch back to read-write is refused.

The prompt goes to a hosted model, and so do the query results. The ledger is personal data, so the
queries return counts, sums, ids and statuses, never names, notes or other personal detail. The same
rule covers `--focus` text and plan files.

## Alternatives considered

- **Let Codex reach the database itself.** Rejected. The only Codex setting that lets a sandboxed command
  reach the PostgreSQL socket is a permission profile with the network enabled, and that also opens the
  internet and Redis; the domain allowlist and the limited mode did not stop a plain `curl` to an outside
  host. The connection would also use the owner's own database role, which can write. Codex runs
  unattended and reads untrusted text, so a review with a writable database and the internet is not worth
  the convenience.
- **Give Codex the same permissions as the main agent.** Rejected for the same reason, and because a
  review that runs `bin/ci` would apply every pending migration.
- **A read-only database role for `--sql`.** Only a `pg_read_all_data` role would make the read-only
  session a hard limit. Not worth it while the requester writes the queries: the checks catch mistakes in
  the file, not a file written to get round them.
- **One reviewer only.** Two reviewers of different lineage overlap less than two of the same, and the
  data-heavy changes are where a missed case costs most. Codex stays optional: small and docs-only
  changes skip it, and so does any change when Codex is logged out or out of quota.
- **A design-system reference page in the app**, as the upstream skill builds. Not carried over: the UI
  layer is still small, and a page of samples is one more thing to keep true. Add it when the number of
  primitives makes the source files slow to read.

## Consequences

- The Codex CLI is optional. Without it `bin/codex-review` exits 3 and the pipeline goes on with the
  `reviewer` agent alone. Nothing in `bin/ci` or GitHub CI depends on it.
- A Codex review sends the diff, and whatever `--sql` returned, to a hosted model. The repository is
  meant to be public, so the code is not the concern; the query results are, and the rule above is the
  only guard. Nothing enforces it.
- Known limits of `--sql`: a file of many 29 second statements runs past `--timeout`, and psql's output
  is read whole before the size check.
- The wrapper's argument checks, its dry run and the refusal of an unsafe `--sql` file are tested
  (`test/bin/scripts_test.rb`); a real Codex run is not, because tests never reach the network.

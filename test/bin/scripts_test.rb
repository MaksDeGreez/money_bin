require "test_helper"
require "open3"

# The bin/ scripts' argument checks. Each case stops before the script touches a database, a worktree
# or GitHub.
class BinScriptsTest < ActiveSupport::TestCase
  test "worktree-remove needs exactly one path" do
    out, status = run_script("bin/worktree-remove")

    assert_equal 2, status.exitstatus
    assert_match(/usage: bin\/worktree-remove PATH/, out)
  end

  test "worktree-remove refuses a path that is not a directory" do
    out, status = run_script("bin/worktree-remove", "/no/such/dir")

    assert_equal 2, status.exitstatus
    assert_match(/is not a directory/, out)
  end

  test "worktree-remove refuses the main checkout" do
    skip "this checkout is a linked worktree" if MoneyBin::WorktreeIsolation.worktree_name(Rails.root.to_s)

    out, status = run_script("bin/worktree-remove", Rails.root.to_s)

    assert_equal 2, status.exitstatus
    assert_match(/is the main checkout/, out)
  end

  test "worktree-setup takes no arguments" do
    out, status = run_script("bin/worktree-setup", "extra")

    assert_equal 2, status.exitstatus
    assert_match(/usage: bin\/worktree-setup/, out)
  end

  test "pr-wait checks its arguments before calling GitHub" do
    out, status = run_script("bin/pr-wait")
    assert_equal 2, status.exitstatus
    assert_match(/missing PR number/, out)

    out, status = run_script("bin/pr-wait", "abc")
    assert_equal 2, status.exitstatus
    assert_match(/PR must be a number/, out)

    out, status = run_script("bin/pr-wait", "12", "--timeout", "soon")
    assert_equal 2, status.exitstatus
    assert_match(/--timeout must be whole seconds/, out)
  end

  test "pr-wait prints its help" do
    out, status = run_script("bin/pr-wait", "--help")

    assert status.success?
    assert_match(/usage: bin\/pr-wait <pr>/, out)
  end

  test "codex-review takes one target and known options only" do
    out, status = run_script("bin/codex-review", "--uncommitted", "--plan", "README.md")
    assert_equal 2, status.exitstatus
    assert_match(/choose one target/, out)

    out, status = run_script("bin/codex-review", "--effort", "extreme")
    assert_equal 2, status.exitstatus
    assert_match(/invalid argument: --effort extreme/, out)

    out, status = run_script("bin/codex-review", "--plan", "no/such/plan.md", "--dry-run")
    assert_equal 2, status.exitstatus
    assert_match(/no such file/, out)

    out, status = run_script("bin/codex-review", "main")
    assert_equal 2, status.exitstatus
    assert_match(/unexpected argument: main/, out)
  end

  test "codex-review reports a mistyped commit or base ref as a usage error, not as a failed review" do
    out, status = run_script("bin/codex-review", "--commit", "no-such-commit", "--dry-run")
    assert_equal 2, status.exitstatus
    assert_match(/no such commit: no-such-commit/, out)

    out, status = run_script("bin/codex-review", "--base", "no-such-ref", "--dry-run")
    assert_equal 2, status.exitstatus
    assert_match(/no such base ref: no-such-ref/, out)
  end

  test "codex-review finds a relative --plan from the caller's directory" do
    out, status = Open3.capture2e("../bin/codex-review", "--plan", "../README.md", "--dry-run", chdir: Rails.root.join("app").to_s)

    assert status.success?, out
    assert_match(/Review the plan in `README\.md`/, out)
  end

  test "codex-review --dry-run prints the read-only command and the prompt, and calls nothing" do
    clean = { "CODEX_BIN" => "/no/such/codex", "CODEX_REVIEW_MODEL" => nil, "CODEX_REVIEW_EFFORT" => nil }
    out, status = run_script(clean, "bin/codex-review", "--plan", "README.md",
                             "--focus", "the plan's ordering", "--effort", "medium", "--dry-run")

    assert status.success?, out
    assert_match(%r{\A/no/such/codex exec -s read-only -C .+ --color never -o tmp/codex/\S+/review\.md -m gpt-6\.2-sol -c model_reasoning_effort="medium" -$}, out)
    assert_match(/Review the plan in `README\.md`/, out)
    assert_match(/Extra focus from the requester: the plan's ordering/, out)
    assert_match(/Work read-only/, out)
    assert_match(/^## Verdict$/, out)
  end

  # The model and the effort are always on the command line, so a review does not depend on the machine's
  # own Codex config. A flag wins over the environment, the environment over the built-in default.
  test "codex-review runs on its default model and effort, which the environment or a flag can change" do
    clean = { "CODEX_BIN" => "/no/such/codex", "CODEX_REVIEW_MODEL" => nil, "CODEX_REVIEW_EFFORT" => nil }
    ends_with = ->(model, effort) { %r{review\.md -m #{Regexp.escape(model)} -c model_reasoning_effort="#{effort}" -$} }

    out, status = run_script(clean, "bin/codex-review", "--plan", "README.md", "--dry-run")
    assert status.success?, out
    assert_match ends_with.call("gpt-6.2-sol", "high"), out.lines.first

    from_env = clean.merge("CODEX_REVIEW_MODEL" => "example-model", "CODEX_REVIEW_EFFORT" => "low")
    out, = run_script(from_env, "bin/codex-review", "--plan", "README.md", "--dry-run")
    assert_match ends_with.call("example-model", "low"), out.lines.first

    out, = run_script(from_env, "bin/codex-review", "--plan", "README.md", "--model", "other-model", "--effort", "xhigh", "--dry-run")
    assert_match ends_with.call("other-model", "xhigh"), out.lines.first

    out, = run_script(clean.merge("CODEX_REVIEW_MODEL" => " ", "CODEX_REVIEW_EFFORT" => ""), "bin/codex-review", "--plan", "README.md", "--dry-run")
    assert_match ends_with.call("gpt-6.2-sol", "high"), out.lines.first
  end

  test "codex-review refuses an effort or a model that cannot be one" do
    clean = { "CODEX_BIN" => "/no/such/codex", "CODEX_REVIEW_MODEL" => nil, "CODEX_REVIEW_EFFORT" => nil }

    out, status = run_script(clean.merge("CODEX_REVIEW_EFFORT" => "maximum"), "bin/codex-review", "--plan", "README.md", "--dry-run")
    assert_equal 2, status.exitstatus, out
    assert_match(/CODEX_REVIEW_EFFORT must be one of low, medium, high, xhigh/, out)

    out, status = run_script(clean, "bin/codex-review", "--plan", "README.md", "--model", "a model; rm -rf", "--dry-run")
    assert_equal 2, status.exitstatus, out
    assert_match(/not a model id/, out)
  end

  # OptionParser hands the next word to --model, also when it is another option.
  test "codex-review with the model id forgotten stops instead of swallowing the next option" do
    clean = { "CODEX_BIN" => "/no/such/codex", "CODEX_REVIEW_MODEL" => nil, "CODEX_REVIEW_EFFORT" => nil }

    out, status = run_script(clean, "bin/codex-review", "--plan", "README.md", "--model", "--dry-run")

    assert_equal 2, status.exitstatus, out
    assert_match(/not a model id: "--dry-run"/, out)
  end

  # The checks catch mistakes in a query file; they are not a sandbox (the database role is a superuser).
  test "codex-review refuses a --sql file with a meta-command or a way out of the read-only session" do
    refused = [
      "\\! echo hello",
      "select 1\\! echo hello",
      "select 1;\n\\copy accounts to 'out.csv'",
      "SET TRANSACTION READ WRITE; select 1",
      "set default_transaction_read_only = off; select 1",
      "RESET ALL; select 1",
      "discard all; select 1",
      "copy (select 1) to program 'true'",
      "set role postgres; select 1",
      "SET SESSION AUTHORIZATION postgres; select 1"
    ]

    refused.each do |sql|
      out, status = run_codex_review_with_sql(sql)

      assert_equal 8, status.exitstatus, "#{sql.inspect} was accepted: #{out}"
      assert_match(/plain read-only SQL only/, out)
    end
  end

  test "codex-review --sql refuses a database that is not this app's" do
    [ "postgres://localhost/money_bin", "postgres://localhost/postgres", "postgres://localhost" ].each do |url|
      out, status = run_codex_review_with_sql("select count(*) from accounts", "DATABASE_URL" => url)

      assert_equal 8, status.exitstatus, "#{url} was accepted: #{out}"
      assert_match(/queries only this app's databases \(money_bin_v2_\*\)/, out)
    end
  end

  test "codex-review --dry-run checks a --sql file and runs no query" do
    url = "postgres://someone:hunter2@localhost/money_bin_v2_development"
    out, status = run_codex_review_with_sql("select count(*) from accounts where name like 'reset_%'", "DATABASE_URL" => url)

    assert status.success?, out
    assert_match(/dry run: the queries of `queries\S*\.sql` were checked and not run; the database is `money_bin_v2_development`/, out)
    assert_no_match(/hunter2|someone/, out)
  end

  private

  # A dry run with a --sql file holding `sql`. psql is a path that does not exist: a query that ran would
  # fail the run with "not installed".
  def run_codex_review_with_sql(sql, env = {})
    Tempfile.create([ "queries", ".sql" ]) do |file|
      file.write(sql)
      file.flush
      run_script({ "PSQL_BIN" => "/no/such/psql", "DATABASE_URL" => nil }.merge(env),
                 "bin/codex-review", "--plan", "README.md", "--sql", file.path, "--dry-run")
    end
  end

  def run_script(*command)
    Open3.capture2e(*command, chdir: Rails.root.to_s)
  end
end

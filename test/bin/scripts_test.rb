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
  end

  test "codex-review --dry-run prints the read-only command and the prompt, and calls nothing" do
    out, status = run_script({ "CODEX_BIN" => "/no/such/codex" }, "bin/codex-review", "--plan", "README.md",
                             "--focus", "the plan's ordering", "--effort", "medium", "--dry-run")

    assert status.success?, out
    assert_match(%r{\A/no/such/codex exec -s read-only -C \S+ --color never -o tmp/codex/\S+/review\.md -c model_reasoning_effort="medium" -$}, out)
    assert_match(/Review the plan in `README\.md`/, out)
    assert_match(/Extra focus from the requester: the plan's ordering/, out)
    assert_match(/Work read-only/, out)
    assert_match(/^## Verdict$/, out)
  end

  test "codex-review refuses a --sql file that could leave the read-only session, before it runs anything" do
    [ "\\! echo hello", "select 1;\n\\copy accounts to 'out.csv'", "SET TRANSACTION READ WRITE; select 1" ].each do |sql|
      Tempfile.create([ "queries", ".sql" ]) do |file|
        file.write(sql)
        file.flush
        out, status = run_script({ "PSQL_BIN" => "/no/such/psql" }, "bin/codex-review", "--plan", "README.md",
                                 "--sql", file.path, "--dry-run")

        assert_equal 8, status.exitstatus, out
        assert_match(/plain read-only SQL only/, out)
      end
    end
  end

  private

  def run_script(*command)
    Open3.capture2e(*command, chdir: Rails.root.to_s)
  end
end

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

  private

  def run_script(*command)
    Open3.capture2e(*command, chdir: Rails.root.to_s)
  end
end

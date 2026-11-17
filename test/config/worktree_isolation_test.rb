require "test_helper"
require "tmpdir"

class WorktreeIsolationTest < ActiveSupport::TestCase
  Isolation = MoneyBin::WorktreeIsolation

  test "sanitize produces a safe suffix that a parallel worker number cannot imitate" do
    assert_equal "feat_login", Isolation.sanitize("feat-login")
    assert_equal "money_bin1", Isolation.sanitize("Money Bin-1")
    assert_equal "feature1", Isolation.sanitize("feature_1")
    assert_equal "wt42", Isolation.sanitize("42")
    assert_equal "worktree", Isolation.sanitize("---")
    assert_operator Isolation.sanitize("x" * 80).length, :<=, Isolation::MAX_SUFFIX_LENGTH
  end

  test "the longest test database name of a parallel worker fits in PostgreSQL's limit" do
    Dir.mktmpdir do |common|
      root = fake_worktree(common, "a-very-long-worktree-name-#{'x' * 80}")
      longest = "#{Isolation.test_database(root)}_999"

      assert_operator longest.bytesize, :<=, Isolation::POSTGRES_NAME_LIMIT
    end
  end

  test "the main checkout and CI checkouts get no suffix and the main test Redis database" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, ".git"))

      assert_equal "", Isolation.database_suffix(root)
      assert_equal "money_bin_v2_test", Isolation.test_database(root)
      assert_equal 6, Isolation.test_redis_db(root)
      assert_raises(ArgumentError) { Isolation.worktree_test_database_pattern(root) }
    end
  end

  test "a .git file that does not point into a worktrees directory is not a linked worktree" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".git"), "gitdir: /somewhere/modules/sub\n")
      assert_nil Isolation.worktree_name(root)

      File.write(File.join(root, ".git"), "not a gitdir line\n")
      assert_nil Isolation.worktree_name(root)
    end
  end

  test "a linked worktree gets a suffix and claims the lowest free Redis database" do
    Dir.mktmpdir do |common|
      first = fake_worktree(common, "feat-one")
      second = fake_worktree(common, "feat-two")

      assert_equal "_feat_one", Isolation.database_suffix(first)
      assert_equal "money_bin_v2_test_feat_one", Isolation.test_database(first)
      assert_equal 7, Isolation.test_redis_db(first)
      assert_equal 7, Isolation.test_redis_db(first), "the claim is stable"
      assert_equal 8, Isolation.test_redis_db(second)

      # Removing the first worktree frees its slot for the next one.
      FileUtils.rm_rf(first)
      third = fake_worktree(common, "feat-three")
      assert_equal 7, Isolation.test_redis_db(third)
    end
  end

  test "a claim outside the worktree pool is ignored and claimed again" do
    Dir.mktmpdir do |common|
      root = fake_worktree(common, "feat-one")
      File.write(File.join(common, ".git", "worktrees", "feat-one", Isolation::CLAIM_FILE), "3\n")

      assert_equal 7, Isolation.test_redis_db(root)
    end
  end

  test "when every slot is taken the worktree falls back to a hashed slot in the pool" do
    Dir.mktmpdir do |common|
      Isolation::WORKTREE_REDIS_DBS.each { |db| Isolation.test_redis_db(fake_worktree(common, "busy-#{db}")) }
      extra = fake_worktree(common, "one-too-many")

      db = nil
      _out, err = capture_io { db = Isolation.test_redis_db(extra) }

      assert_includes Isolation::WORKTREE_REDIS_DBS, db
      assert_match(/all of 7\.\.15 are claimed/, err)
    end
  end

  test "the drop pattern matches only this worktree's test databases" do
    Dir.mktmpdir do |common|
      root = fake_worktree(common, "feat-one")
      pattern = Regexp.new(Isolation.worktree_test_database_pattern(root))

      assert_equal "^money_bin_v2_test_feat_one([-_][0-9]+)?$", pattern.source
      %w[money_bin_v2_test_feat_one money_bin_v2_test_feat_one_0 money_bin_v2_test_feat_one-12].each do |name|
        assert_match pattern, name
      end
      %w[
        money_bin money_bin_test money_bin_test_feat_one money_bin_test_feat_one_0
        money_bin_v2_test money_bin_v2_test_0 money_bin_v2_development money_bin_v2_production
        money_bin_v2_test_feat_one_two money_bin_v2_test_feat_onex
      ].each do |name|
        assert_no_match pattern, name
      end
    end
  end

  private

  # Lays out <common>/.git/worktrees/<name>/gitdir and <common>/<name>/.git the way git does.
  def fake_worktree(common, name)
    root = File.join(common, name)
    admin = File.join(common, ".git", "worktrees", name)
    FileUtils.mkdir_p(root)
    FileUtils.mkdir_p(admin)
    File.write(File.join(root, ".git"), "gitdir: #{admin}\n")
    File.write(File.join(admin, "gitdir"), File.join(root, ".git") + "\n")
    root
  end
end

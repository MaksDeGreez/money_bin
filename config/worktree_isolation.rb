# frozen_string_literal: true

require "zlib"

module MoneyBin
  # Gives each linked git worktree its own TEST database and TEST Redis database, so test runs in two
  # worktrees at once (for example two coding agents) do not wipe each other's data. Development and
  # production are not touched: every worktree shares them.
  #
  # How it works. It is cheap and gives the same answer on every boot (plain file reads, no `git` call):
  # - In a linked worktree <root>/.git is a file "gitdir: <common .git>/worktrees/<name>". In the main
  #   checkout and in a CI checkout it is a directory: there is no suffix there, so those keep
  #   money_bin_v2_test and Redis database 6.
  # - <name> is git's own name for the worktree: the directory's basename, made unique by git when two
  #   worktrees share one. Cleaned to [a-z0-9_] and cut to MAX_SUFFIX_LENGTH, it becomes the database
  #   suffix.
  # - Redis has 16 databases (0..15). This app uses 4 (production), 5 (development) and 6 (tests in the
  #   main checkout). Another local app on the same Redis uses 0, 1 and 2, and its own worktrees take test
  #   databases from 3 upward, so the two only meet when it runs tests in several worktrees at once (a
  #   known, accepted limit; REDIS_URL is the way out).
  # - Linked worktrees get one of 7..15. A worktree claims the lowest free one once and records it in its
  #   git admin directory (<common .git>/worktrees/<name>/money-bin-v2-test-redis-db). That file is outside the working tree,
  #   and git deletes it together with the worktree (`git worktree remove` or `prune`), which frees the
  #   slot. A claim whose worktree directory is gone also counts as free. With more than nine live
  #   worktrees, or when the claim cannot be written, the slot falls back to a hash of the name, with a
  #   warning.
  # REDIS_URL and DATABASE_URL still override everything.
  module WorktreeIsolation
    ROOT = File.expand_path("..", __dir__)
    TEST_DATABASE = "money_bin_v2_test"
    MAIN_TEST_REDIS_DB = 6
    WORKTREE_REDIS_DBS = (7..15)
    CLAIM_FILE = "money-bin-v2-test-redis-db"
    LOCK_FILE = "money-bin-v2-test-redis-db.lock"
    # PostgreSQL names stop at 63 bytes. The longest test database name is
    # "money_bin_v2_test" (17) + "_" (1) + the suffix (32) + a parallel worker's "_NNN" (4) = 54 bytes,
    # which leaves room even for a machine with more than 100 test workers.
    MAX_SUFFIX_LENGTH = 32
    POSTGRES_NAME_LIMIT = 63

    module_function

    # "" in the main checkout, "_<name>" in a linked worktree.
    def database_suffix(root = ROOT)
      name = worktree_name(root)
      name ? "_#{sanitize(name)}" : ""
    end

    def test_database(root = ROOT)
      "#{TEST_DATABASE}#{database_suffix(root)}"
    end

    # A PostgreSQL regular expression for a linked worktree's test database and the parallel workers'
    # copies (Rails names them <db>_N; older versions used <db>-N). Used by bin/worktree-remove to pick
    # the databases it drops. It always starts with "^money_bin_v2_test_", so it can never match the
    # main checkout's test database or a database of another app. Raises for the main checkout.
    def worktree_test_database_pattern(root)
      suffix = database_suffix(root)
      raise ArgumentError, "#{root} is not a linked git worktree" if suffix.empty?
      raise ArgumentError, "unsafe database suffix #{suffix.inspect}" unless suffix.match?(/\A_[a-z0-9_]+\z/)

      "^#{TEST_DATABASE}#{suffix}([-_][0-9]+)?$"
    end

    def test_redis_db(root = ROOT)
      return @test_redis_db ||= resolve_redis_db(ROOT) if root == ROOT

      resolve_redis_db(root)
    end

    # git's administrative directory for a linked worktree, nil for anything else.
    def admin_dir(root)
      dot_git = File.join(root, ".git")
      return unless File.file?(dot_git)

      path = File.read(dot_git)[/\Agitdir:\s*(.+)$/, 1]&.strip
      return unless path

      dir = File.expand_path(path, root)
      dir if File.basename(File.dirname(dir)) == "worktrees"
    end

    def worktree_name(root)
      dir = admin_dir(root)
      File.basename(dir) if dir
    end

    # Parallel test workers add "_0", "_1", ... to the database name. The suffix must not end in
    # "_<digits>" itself, or two worktrees could end up with the same name ("feat" + worker "_1" and
    # "feat_1" + nothing). bin/worktree-remove drops those copies along with the base database.
    def sanitize(name)
      cleaned = name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")[0, MAX_SUFFIX_LENGTH]
      cleaned = cleaned.delete_suffix("_").sub(/_(\d+)\z/, '\1')
      return "worktree" if cleaned.empty?

      cleaned.match?(/\A\d+\z/) ? "wt#{cleaned}" : cleaned
    end

    def resolve_redis_db(root)
      dir = admin_dir(root)
      return MAIN_TEST_REDIS_DB unless dir

      read_claim(dir) || claim(dir)
    end

    def claim(dir)
      # The lock sits in the common .git directory: git would prune a stray file in .git/worktrees/.
      File.open(File.join(dir, "..", "..", LOCK_FILE), File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        claimed = read_claim(dir)
        return claimed if claimed

        taken = live_claims(File.dirname(dir), except: dir)
        free = WORKTREE_REDIS_DBS.find { |db| !taken.include?(db) }
        return fallback(dir, "all of #{WORKTREE_REDIS_DBS} are claimed") unless free

        File.write(File.join(dir, CLAIM_FILE), "#{free}\n")
        free
      end
    rescue SystemCallError => e
      fallback(dir, "cannot record the claim (#{e.class})")
    end

    def read_claim(dir)
      value = File.read(File.join(dir, CLAIM_FILE)).strip
      db = Integer(value, exception: false)
      db if WORKTREE_REDIS_DBS.cover?(db)
    rescue Errno::ENOENT
      nil
    end

    # Slots held by other worktrees whose directory still exists.
    def live_claims(worktrees_dir, except:)
      Dir.glob(File.join(worktrees_dir, "*", CLAIM_FILE)).filter_map do |file|
        other = File.dirname(file)
        next if other == except || !live?(other)

        read_claim(other)
      end
    end

    # git records the path of the worktree's .git file in <admin dir>/gitdir.
    def live?(dir)
      path = File.read(File.join(dir, "gitdir")).strip
      File.exist?(File.expand_path(path, dir))
    rescue Errno::ENOENT
      false
    end

    def fallback(dir, reason)
      db = WORKTREE_REDIS_DBS.first + (Zlib.crc32(File.basename(dir)) % WORKTREE_REDIS_DBS.size)
      warn "WorktreeIsolation: #{reason}; test Redis database #{db} may be shared with another worktree"
      db
    end
  end
end

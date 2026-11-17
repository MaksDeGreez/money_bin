require "test_helper"
require "open3"

# bin/leak-check and the pre-push hook (.githooks/pre-push), driven through real pushes from a throwaway
# repository to a bare one, both in a temp directory. The terms are invented words, never real data.
# Commits use --no-verify, so the pre-commit hook (gitleaks) does not run here; it has its own test.
class LeakCheckTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/leak-check").to_s
  HOOKS = Rails.root.join(".githooks").to_s
  TERMS = "# invented terms for the tests\n\nZorblax\n  Quuxwidget  \n# Plumbofrost\nЗорбласт\n"
  WORDS = /zorblax|quuxwidget|зорбласт/i

  setup do
    @dir = Dir.mktmpdir("leak-check")
    @terms_file = File.join(@dir, "leak_terms.txt")
    File.write(@terms_file, TERMS)
    @work = File.join(@dir, "work")
    git("init", "-q", "--bare", "remote.git", chdir: @dir)
    git("init", "-q", "-b", "main", "work", chdir: @dir)
    git("config", "core.hooksPath", HOOKS)
    git("remote", "add", "origin", "../remote.git")
    commit({ "README.md" => "Hello\n" }, "Start")
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "without a terms file it warns and lets the push pass" do
    File.delete(@terms_file)
    git("switch", "-q", "-c", "feature")
    commit({ "notes.txt" => "Zorblax\n" }, "Add notes")

    output, status = push("feature")

    assert status.success?, output
    assert_match(/WARNING no terms file at #{Regexp.escape(@terms_file)}; nothing was checked/, output)
  end

  test "a terms file with only comments and blank lines checks nothing and passes" do
    File.write(@terms_file, "# nothing yet\n\n")
    git("switch", "-q", "-c", "feature")
    commit({ "notes.txt" => "Zorblax\n" }, "Add notes")

    output, status = push("feature")

    assert status.success?, output
    assert_match(/has no terms; nothing was checked/, output)
  end

  test "a clean push passes" do
    git("switch", "-q", "-c", "feature")
    commit({ "notes.txt" => "Plumbofrost is only a comment in the terms file\n" }, "Add notes")

    output, status = push("feature")

    assert status.success?, output
    assert_match(/no forbidden terms in the commits being pushed \(3 terms checked\)/, output)
  end

  test "matching ignores case outside ASCII too" do
    git("switch", "-q", "-c", "feature")
    sha = commit({ "notes.txt" => "Рахунок від ЗОРБЛАСТ\n" }, "Add notes")

    output, status = push("feature")

    assert_blocked output, status
    assert_includes output, "commit #{sha[0, 12]} notes.txt line 1: term on line 6 of the terms file"
  end

  test "a term in an added line blocks the push, ignoring case, and names the commit, file and line" do
    git("switch", "-q", "-c", "feature")
    sha = commit({ "docs/notes.txt" => "first\nsecond with zORBLAx inside\n" }, "Add notes")

    output, status = push("feature")

    assert_blocked output, status
    assert_includes output, "commit #{sha[0, 12]} docs/notes.txt line 2: term on line 3 of the terms file"
    assert_includes output, "1 forbidden term found in the commits being pushed"
  end

  test "a term in the path of an added or renamed file blocks the push and is masked in the report" do
    git("switch", "-q", "-c", "feature")
    added = commit({ "QUUXWIDGET/a.txt" => "plain\n", "b.txt" => "plain\n" }, "Add files")
    git("mv", "b.txt", "old-quuxwidget.txt")
    renamed = commit({}, "Rename a file")

    output, status = push("feature")

    assert_blocked output, status
    assert_includes output, "commit #{added[0, 12]} added file <term 4>/a.txt: term on line 4 of the terms file"
    assert_includes output, "commit #{renamed[0, 12]} added file old-<term 4>.txt: term on line 4 of the terms file"
  end

  test "a term in a commit message blocks the push" do
    git("switch", "-q", "-c", "feature")
    sha = commit({ "a.txt" => "plain\n" }, "Add a file\n\nAsked for by Zorblax.")

    output, status = push("feature")

    assert_blocked output, status
    assert_includes output, "commit #{sha[0, 12]} message line 3: term on line 3 of the terms file"
  end

  test "a term in the name of the pushed branch blocks the push" do
    git("switch", "-q", "-c", "fix/zorblax-report")
    commit({ "a.txt" => "plain\n" }, "Add a file")

    output, status = push("fix/zorblax-report")

    assert_blocked output, status
    assert_includes output, "ref refs/heads/fix/<term 3>-report: term on line 3 of the terms file"
  end

  test "a new branch is compared with what the remote already has" do
    # main on the remote already holds a term (pushed past the hooks): that is not the new branch's doing.
    git("switch", "-q", "main")
    commit({ "old.txt" => "zorblax\n" }, "Old commit")
    git("push", "-q", "--no-verify", "origin", "main")
    git("switch", "-q", "-c", "feature")
    commit({ "a.txt" => "plain\n" }, "Clean work")

    output, status = push("feature")
    assert status.success?, output

    git("switch", "-q", "-c", "feature-two", "main")
    sha = commit({ "b.txt" => "quuxwidget\n" }, "New leak")

    output, status = push("feature-two")
    assert_blocked output, status
    assert_equal 1, output.scan(/term on line/).size, output
    assert_includes output, "commit #{sha[0, 12]} b.txt line 1"
  end

  test "an existing branch is checked from its old remote value only" do
    git("switch", "-q", "-c", "feature")
    first = commit({ "a.txt" => "plain\n" }, "First")
    output, status = push("feature")
    assert status.success?, output

    second = commit({ "b.txt" => "Quuxwidget\n" }, "Second")
    output, status = push("feature")
    assert_blocked output, status
    assert_includes output, "commit #{second[0, 12]} b.txt line 1"
    assert_not_includes output, first[0, 12]

    git("reset", "-q", "--hard", first)
    commit({ "b.txt" => "plain\n" }, "Second, clean")
    output, status = push("feature")
    assert status.success?, output
  end

  test "a line a merge adds is checked, lines from its parents are not checked twice" do
    git("switch", "-q", "-c", "side")
    commit({ "side.txt" => "plain side\n" }, "Side")
    git("switch", "-q", "-c", "feature", "main")
    commit({ "own.txt" => "plain own\n" }, "Own")
    git("merge", "-q", "--no-ff", "--no-commit", "side")
    File.write(File.join(@work, "side.txt"), "plain side\nzorblax from the merge\n")
    merge = commit({}, "Merge side")

    output, status = push("feature")

    assert_blocked output, status
    assert_equal [ "commit #{merge[0, 12]} side.txt line 2: term on line 3 of the terms file" ],
      output.lines.grep(/term on line/).map(&:strip)
  end

  test "an annotated tag is checked: its message and its new commits" do
    git("tag", "-a", "v1", "-m", "Release for Zorblax")

    output, status = push("v1")

    assert_blocked output, status
    assert_includes output, "tag refs/tags/v1 message line 1: term on line 3 of the terms file"

    git("tag", "-a", "v2", "-m", "Plain release")
    output, status = push("v2")
    assert status.success?, output
  end

  test "a term inside a binary file or a file marked -diff blocks the push" do
    git("switch", "-q", "-c", "feature")
    File.binwrite(File.join(@work, "photo.bin"), "\x89PNG\0\x01 zorblax \0\xFF".b)
    sha = commit({ ".gitattributes" => "notes.dat -diff\n", "notes.dat" => "one\nQuuxwidget\n" }, "Add files")

    output, status = push("feature")

    assert_blocked output, status
    assert_includes output, "commit #{sha[0, 12]} photo.bin line 1: term on line 3 of the terms file"
    assert_includes output, "commit #{sha[0, 12]} notes.dat line 2: term on line 4 of the terms file"
  end

  test "a tag that points at a blob or a tree is checked" do
    blob = git("hash-object", "-w", "--stdin", stdin: "plain\nzorblax\n").strip
    git("tag", "blob-tag", blob)

    output, status = push("blob-tag")
    assert_blocked output, status
    assert_includes output, "tag refs/tags/blob-tag line 2: term on line 3 of the terms file"

    commit({ "quuxwidget.txt" => "plain\n" }, "Add file")
    git("tag", "-a", "-m", "A tree", "tree-tag", "HEAD^{tree}")
    output, status = push("tree-tag")
    assert_blocked output, status
    assert_includes output, "tag refs/tags/tree-tag path <term 4>.txt: term on line 4 of the terms file"
  end

  test "--history checks tags that point at a blob, and tag messages" do
    blob = git("hash-object", "-w", "--stdin", stdin: "Zorblax\n").strip
    git("tag", "blob-tag", blob)
    git("tag", "-a", "-m", "Release for quuxwidget", "v1")

    output, status = leak_check("--history")

    assert_blocked output, status
    assert_includes output, "tag refs/tags/blob-tag line 1: term on line 3 of the terms file"
    assert_includes output, "tag refs/tags/v1 message line 1: term on line 4 of the terms file"
  end

  test "a term matches whether it is written composed or decomposed" do
    composed = "Квойдрик" # an invented word; "й" as one code point
    decomposed = composed.unicode_normalize(:nfd) # "и" followed by a combining breve
    assert_not_equal composed, decomposed

    File.write(@terms_file, "#{decomposed}\n")
    git("switch", "-q", "-c", "feature")
    commit({ "a.txt" => "Чек: #{composed.upcase}\n" }, "Add a")
    output, status = push("feature")
    assert_blocked output, status
    assert_includes output, "a.txt line 1: term on line 1 of the terms file"

    File.write(@terms_file, "#{composed}\n")
    commit({ "b.txt" => "#{decomposed}\n" }, "Add b")
    output, status = leak_check("--tree")
    assert_blocked output, status
    assert_includes output, "b.txt line 1: term on line 1 of the terms file"
    assert_no_match(/квойдрик/i, output.unicode_normalize(:nfc))
  end

  test "deleting a remote branch passes" do
    git("push", "-q", "--no-verify", "origin", "main:refs/heads/zorblax-old")

    output, status = push(":zorblax-old")

    assert status.success?, output
  end

  test "a push to main is refused, even through another local branch name" do
    commit({ "a.txt" => "plain\n" }, "Direct change")

    output, status = push("main")
    assert_equal 1, status.exitstatus
    assert_match(/refusing to update main on the remote/, output)
    assert_match(/ALLOW_PUSH_TO_MAIN=1/, output)

    git("switch", "-q", "-c", "other")
    output, status = push("other:main")
    assert_equal 1, status.exitstatus
    assert_match(/refusing to update main on the remote/, output)
  end

  test "ALLOW_PUSH_TO_MAIN=1 lets a push to main through, but the leak check still runs" do
    commit({ "a.txt" => "plain\n" }, "Emergency fix")

    output, status = push("main", "ALLOW_PUSH_TO_MAIN" => "1")
    assert status.success?, output

    commit({ "b.txt" => "zorblax\n" }, "Emergency leak")
    output, status = push("main", "ALLOW_PUSH_TO_MAIN" => "1")
    assert_blocked output, status
  end

  test "--tree checks the paths and lines of tracked and new files, but not ignored ones" do
    File.write(File.join(@work, ".gitignore"), "secret.txt\n")
    File.write(File.join(@work, "secret.txt"), "zorblax\n")
    commit({ "a.txt" => "plain\n" }, "Ignore a file")

    output, status = leak_check("--tree")
    assert status.success?, output
    assert_match(/no forbidden terms in the tracked files/, output)

    File.write(File.join(@work, "new-quuxwidget.txt"), "one\nZORBLAX\n")
    output, status = leak_check("--tree")
    assert_blocked output, status
    assert_includes output, "path new-<term 4>.txt: term on line 4 of the terms file"
    assert_includes output, "new-<term 4>.txt line 2: term on line 3 of the terms file"
  end

  test "--tree checks the content of binary files too" do
    File.binwrite(File.join(@work, "photo.bin"), "\x89PNG\0\x01 zorblax \0\xFF".b)

    output, status = leak_check("--tree")

    assert_blocked output, status
    assert_includes output, "photo.bin line 1: term on line 3 of the terms file"
  end

  test "--history checks every commit of the local branches" do
    git("switch", "-q", "-c", "feature")
    sha = commit({ "a.txt" => "plain\n" }, "Mention quuxwidget")
    git("switch", "-q", "main")

    output, status = leak_check("--history")

    assert_blocked output, status
    assert_includes output, "commit #{sha[0, 12]} message line 1: term on line 4 of the terms file"
  end

  test "a wrong argument is a usage error" do
    output, status = leak_check("--everything")

    assert_equal 2, status.exitstatus
    assert_match(/usage: bin\/leak-check/, output)
  end

  private

  # An isolated git (no global or system config, a fixed author) and this Ruby first on the PATH, so the
  # hook's `env ruby` skips a version manager's shim.
  def env(extra = {})
    {
      "PATH" => [ RbConfig::CONFIG["bindir"], ENV.fetch("PATH") ].join(File::PATH_SEPARATOR),
      "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
      "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com",
      "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil,
      "ALLOW_PUSH_TO_MAIN" => nil, "LEAK_TERMS_FILE" => @terms_file
    }.merge(extra)
  end

  def git(*args, chdir: @work, stdin: "")
    output, status = Open3.capture2e(env, "git", *args, chdir:, stdin_data: stdin)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output
  end

  # Writes the files, stages everything and commits; returns the new commit's sha.
  def commit(files, message)
    files.each do |path, content|
      full = File.join(@work, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    git("add", "-A")
    git("commit", "-q", "--no-verify", "-m", message)
    git("rev-parse", "HEAD").strip
  end

  def push(refspec, extra_env = {})
    Open3.capture2e(env(extra_env), "git", "push", "-q", "origin", refspec, chdir: @work)
  end

  def leak_check(*args)
    Open3.capture2e(env, RbConfig.ruby, SCRIPT, *args, chdir: @work)
  end

  def assert_blocked(output, status)
    assert_equal 1, status.exitstatus, output
    assert_match(/forbidden terms? found/, output)
    assert_no_match WORDS, output, "the report must never print a term"
  end
end

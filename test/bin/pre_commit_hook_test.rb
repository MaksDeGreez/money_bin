require "test_helper"
require "open3"
require "securerandom"

# .githooks/pre-commit in a throwaway repository: gitleaks blocks a staged secret, and a machine without
# gitleaks blocks every commit. The fake token is built at run time, so this file holds no secret.
class PreCommitHookTest < ActiveSupport::TestCase
  HOOK = Rails.root.join(".githooks/pre-commit").to_s

  setup do
    @dir = Dir.mktmpdir("pre-commit")
    git("init", "-q", "-b", "main", ".")
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "a staged secret is blocked and printed redacted, a clean change passes" do
    skip "gitleaks is not installed" unless system("command -v gitleaks > /dev/null 2>&1")

    token = "ghp_#{SecureRandom.alphanumeric(36)}"
    stage("config.txt", "token = \"#{token}\"\n")
    output, status = run_hook

    assert_equal 1, status.exitstatus, output
    assert_match(/gitleaks found a secret in the staged changes/, output)
    assert_not_includes output, token

    stage("config.txt", "token = ENV.fetch(\"TOKEN\")\n")
    output, status = run_hook

    assert status.success?, output
  end

  test "without gitleaks every commit is blocked, with the install command" do
    stage("notes.txt", "plain\n")
    output, status = run_hook("PATH" => "/usr/bin:/bin")

    assert_equal 1, status.exitstatus, output
    assert_match(/gitleaks is not installed/, output)
    assert_match(/brew install gitleaks/, output)
  end

  private

  def env
    { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_DIR" => nil, "GIT_INDEX_FILE" => nil }
  end

  def git(*args)
    output, status = Open3.capture2e(env, "git", *args, chdir: @dir)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
  end

  def stage(path, content)
    File.write(File.join(@dir, path), content)
    git("add", path)
  end

  def run_hook(extra_env = {})
    Open3.capture2e(env.merge(extra_env), HOOK, chdir: @dir)
  end
end

require "test_helper"
require "open3"

# Test runs read no .env file (config/application.rb). A REDIS_URL or DATABASE_URL meant for development
# must never point the tests, which delete Redis keys and reload tables, at the development data. Real
# environment variables (CI sets both) still apply, because they are read from ENV directly.
class DotenvTest < ActiveSupport::TestCase
  # An empty list would not do: with no file names dotenv reads `.env` in the working directory.
  test "the test environment loads only the null device, never a .env file" do
    assert_equal [ File::NULL ], Dotenv::Rails.files
  end

  # The files are written where dotenv would look for them in both ways: under the application root and in
  # the working directory (its fallback when it is given no file names).
  test "a setting in a .env file does not reach the tests" do
    Dir.mktmpdir do |root|
      %w[ .env .env.test .env.test.local .env.local ].each do |name|
        File.write(File.join(root, name),
          "REDIS_URL=redis://localhost:6379/5\nDATABASE_URL=postgres://localhost/dev\nMONEY_BIN_DOTENV_PROBE=loaded\n")
      end

      with_env("REDIS_URL" => nil, "DATABASE_URL" => nil, "MONEY_BIN_DOTENV_PROBE" => nil) do
        Dir.chdir(root) do
          with_singleton_method(Dotenv::Rails.instance, :root, -> { Pathname.new(root) }) do
            Dotenv::Rails.load
          end
        end

        assert_nil ENV["REDIS_URL"]
        assert_nil ENV["DATABASE_URL"]
        assert_nil ENV["MONEY_BIN_DOTENV_PROBE"]
      end
    end
  end

  # Booted from scratch, as `bin/rails test` boots it, in a folder whose .env sets a variable.
  test "booting the app in the test environment reads no .env file of the working directory" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".env"), "MONEY_BIN_DOTENV_PROBE=loaded\n")
      script = "require #{Rails.root.join('config/application').to_s.inspect}; print ENV['MONEY_BIN_DOTENV_PROBE'].inspect"
      env = { "RAILS_ENV" => "test", "MONEY_BIN_DOTENV_PROBE" => nil, "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s }
      output, status = Open3.capture2e(env, RbConfig.ruby, "-e", script, chdir: dir)

      assert status.success?, output
      assert_equal "nil", output.lines.last
    end
  end

  test "a real REDIS_URL still applies to the tests" do
    with_env("REDIS_URL" => "redis://example.test:6380/9") do
      assert_equal "redis://example.test:6380/9", MoneyBin::RedisUrl.for("test")
    end
  end

  private
    def with_env(changes)
      saved = changes.keys.to_h { |key| [ key, ENV[key] ] }
      changes.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
end

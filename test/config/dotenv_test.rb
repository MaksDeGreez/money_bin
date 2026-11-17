require "test_helper"

# Test runs read no .env file (config/application.rb). A REDIS_URL or DATABASE_URL meant for development
# must never point the tests, which delete Redis keys and reload tables, at the development data. Real
# environment variables (CI sets both) still apply, because they are read from ENV directly.
class DotenvTest < ActiveSupport::TestCase
  test "the test environment loads no .env file" do
    assert_empty Dotenv::Rails.files
  end

  test "a REDIS_URL or DATABASE_URL in a .env file does not reach the tests" do
    Dir.mktmpdir do |root|
      %w[ .env .env.test .env.test.local .env.local ].each do |name|
        File.write(File.join(root, name), "REDIS_URL=redis://localhost:6379/5\nDATABASE_URL=postgres://localhost/dev\n")
      end

      with_env("REDIS_URL" => nil, "DATABASE_URL" => nil) do
        with_singleton_method(Dotenv::Rails.instance, :root, -> { Pathname.new(root) }) do
          Dotenv::Rails.load
        end

        assert_nil ENV["REDIS_URL"]
        assert_nil ENV["DATABASE_URL"]
      end
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

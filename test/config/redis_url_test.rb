require "test_helper"

class RedisUrlTest < ActiveSupport::TestCase
  test "each environment has its own Redis database" do
    without_redis_url do
      assert_equal "redis://localhost:6379/4", MoneyBin::RedisUrl.for("production")
      assert_equal "redis://localhost:6379/5", MoneyBin::RedisUrl.for(:development)
      assert_equal "redis://localhost:6379/#{MoneyBin::WorktreeIsolation.test_redis_db}", MoneyBin::RedisUrl.for("test")
    end
  end

  test "an unknown environment uses the development database" do
    without_redis_url do
      assert_equal "redis://localhost:6379/5", MoneyBin::RedisUrl.for("staging")
    end
  end

  test "the test database is 6 in the main checkout or one of the worktree pool" do
    assert_includes [ 6, *MoneyBin::WorktreeIsolation::WORKTREE_REDIS_DBS ], MoneyBin::RedisUrl.database_for("test")
  end

  test "REDIS_URL overrides every environment" do
    with_env("REDIS_URL" => "redis://example.test:6380/9") do
      assert_equal "redis://example.test:6380/9", MoneyBin::RedisUrl.for("production")
      assert_equal "redis://example.test:6380/9", MoneyBin::RedisUrl.for("test")
    end
  end

  private

  def without_redis_url(&block)
    with_env("REDIS_URL" => nil, &block)
  end

  def with_env(changes)
    saved = changes.keys.to_h { |key| [ key, ENV[key] ] }
    changes.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end

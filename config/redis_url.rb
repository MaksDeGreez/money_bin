# The one place that decides which Redis database each environment uses.
#
# Required from config/application.rb, so it is ready for the environment files (they load before
# the initializers) and for the ERB in config/cable.yml.
#
# One local Redis can serve several apps, so this app keeps to its own databases:
# 4 for production, 5 for development, 6 for tests in the main checkout and one of 7..15 for tests in
# a linked git worktree (config/worktree_isolation.rb). Cache entries and Sidekiq queues of one
# environment are never seen by another. REDIS_URL overrides everything.
#
# Another local app on the same Redis uses 0, 1 and 2, and its git worktrees take test databases from 3
# upward, lowest free first. The two apps only meet when that app runs tests in several worktrees at once
# (its second worktree would take 4). That is a known and accepted limit: that app is no longer developed.
# If it ever matters, point REDIS_URL at another Redis instance.
require_relative "worktree_isolation"

module MoneyBin
  module RedisUrl
    DATABASES = {
      "production" => 4,
      "development" => 5
    }.freeze

    def self.for(env)
      ENV.fetch("REDIS_URL") { "redis://localhost:6379/#{database_for(env.to_s)}" }
    end

    def self.database_for(env)
      env == "test" ? WorktreeIsolation.test_redis_db : DATABASES.fetch(env, DATABASES["development"])
    end
  end
end

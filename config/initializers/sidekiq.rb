# Sidekiq's server (the worker process) and client (the app that enqueues jobs) use the same Redis
# database: see config/redis_url.rb.
redis_config = { url: MoneyBin::RedisUrl.for(Rails.env) }

Sidekiq.configure_server do |config|
  config.redis = redis_config
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end

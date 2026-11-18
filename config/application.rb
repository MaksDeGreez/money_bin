require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# dotenv loads .env files when the application class below is defined. Test runs read none of them: a
# REDIS_URL or DATABASE_URL written there for development would point the tests, which delete Redis keys
# and reload tables, at the development data, and any other setting of the owner's machine (which model
# reads receipts, an API key) would change what the tests do. Real environment variables still apply (CI
# sets both).
#
# The list must not be empty: with no file names dotenv falls back to `.env` in the working directory.
# The null device is a file that is always there and always empty.
Dotenv::Rails.files = [ File::NULL ] if Dotenv::Rails.env.test?

require_relative "redis_url"

module MoneyBin
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Slim is the only template language. Generators write .slim views, no system tests,
    # no helper files and no stylesheets.
    config.generators do |g|
      g.template_engine :slim
      g.system_tests nil
      g.helper false
      g.stylesheets false
    end

    # Everything is shown in Kyiv time. Timestamps stay UTC in the database (the Active Record default);
    # Time.zone converts them on read, so Date.current is today in Kyiv.
    config.time_zone = "Europe/Kyiv"

    # Sidekiq runs every Active Job. The test environment uses the :test adapter instead.
    config.active_job.queue_adapter = :sidekiq

    # Rails' own Active Storage routes (direct uploads, the disk service, blob and representation links) do
    # not go through ApplicationController, so they would serve and accept receipt photos without a
    # signed-in session, and signed blob links never expire. They are not drawn. Ruby code still attaches
    # and reads files; a page that uploads or shows a photo must be an app controller behind the
    # Authentication concern (docs/decisions/0002-authentication-and-api-tokens.md).
    config.active_storage.draw_routes = false
  end
end

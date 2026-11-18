ENV["RAILS_ENV"] ||= "test"
# Coverage starts before the app loads, so every app file is measured.
require_relative "support/coverage"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
require_relative "support/session_test_helper"
require_relative "support/api_token_test_helper"
require_relative "support/openapi_test_helper"
require_relative "support/api_request_test_helper"
require_relative "support/mcp_test_helper"
require_relative "support/legacy_export_files"

# Load every app file, so a file that no test touches still counts in the coverage report. This cannot
# be config.eager_load: `bin/rails test` boots the app in its test:prepare step, before this file runs.
Rails.application.eager_load!

# No test reaches the network. Stub HTTP calls with WebMock.
WebMock.disable_net_connect!

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Each worker saves its coverage under its own name; the main process merges them
    # (test/support/coverage.rb).
    parallelize_setup { |worker| SimpleCov.command_name "#{SimpleCov.command_name}-#{worker}" }
    parallelize_teardown { SimpleCov.result }

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Replaces `object.name` with `implementation` for the duration of the block and restores it
    # afterwards (minitest/mock is not bundled with Minitest 6).
    def with_singleton_method(object, name, implementation)
      klass = object.singleton_class
      original = klass.instance_method(name) if klass.method_defined?(name, false)
      klass.define_method(name, implementation)
      yield
    ensure
      original ? klass.define_method(name, original) : klass.remove_method(name)
    end
  end
end

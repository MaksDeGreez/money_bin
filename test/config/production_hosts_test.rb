require "test_helper"
require "open3"

# Production answers only to localhost names and to APP_HOST, so a DNS rebinding page cannot reach it
# through a name of its own (config/environments/production.rb). Checked by booting the production
# configuration in a child process; it needs no database.
class ProductionHostsTest < ActiveSupport::TestCase
  SCRIPT = <<~RUBY
    request = ->(host) { ActionDispatch::Request.new(Rack::MockRequest.env_for("http://\#{host}/")) }
    permissions = ActionDispatch::HostAuthorization::Permissions.new(Rails.application.config.hosts)
    puts "checked \#{!permissions.empty?}" # an empty list would let every host through
    %w[ localhost 127.0.0.1 [::1] money.example.test evil.example.test ].each do |host|
      puts "\#{host} \#{permissions.allows?(request.(host).host)}"
    end
  RUBY

  test "production allows the localhost names and APP_HOST, and nothing else" do
    answers = production_answers("APP_HOST" => "money.example.test")

    assert_equal({ "checked" => "true", "localhost" => "true", "127.0.0.1" => "true", "[::1]" => "true",
                   "money.example.test" => "true", "evil.example.test" => "false" }, answers)
  end

  test "without APP_HOST only the localhost names are allowed" do
    answers = production_answers("APP_HOST" => "") # blank counts as unset, and wins over a .env file

    assert_equal "true", answers["localhost"]
    assert_equal "false", answers["money.example.test"]
  end

  private
    def production_answers(env)
      env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "DATABASE_URL" => nil }.merge(env)
      out, err, status = Open3.capture3(env, RbConfig.ruby, "bin/rails", "runner", SCRIPT, chdir: Rails.root.to_s)
      assert status.success?, err

      out.lines(chomp: true).grep(/\A\S+ (true|false)\z/).to_h(&:split)
    end
end
